CREATE SCHEMA IF NOT EXISTS agent_api;

CREATE OR REPLACE VIEW agent_api.incident_summary AS
SELECT shipment.tracking_number,
       shipment.customer_name,
       shipment.status,
       shipment.priority,
       shipment.cargo_profile ->> 'cargo' AS cargo,
       latest_event.event_type AS latest_event_type,
       latest_event.event_time,
      latest_event.facility_code AS latest_event_facility,
      latest_temperature.event_time AS temperature_event_time,
      latest_temperature.details ->> 'temperature_c' AS temperature_c,
      latest_temperature.details ->> 'threshold_c' AS threshold_c,
      latest_temperature.facility_code AS temperature_facility
FROM shipment
JOIN LATERAL (
    SELECT shipment_event.event_type,
           shipment_event.event_time,
           shipment_event.details,
           facility.facility_code
    FROM shipment_event
    LEFT JOIN facility
      ON facility.facility_id = shipment_event.facility_id
    WHERE shipment_event.shipment_id = shipment.shipment_id
    ORDER BY shipment_event.event_time DESC
    LIMIT 1
) AS latest_event ON true
LEFT JOIN LATERAL (
    SELECT shipment_event.event_time,
           shipment_event.details,
           facility.facility_code
    FROM shipment_event
    LEFT JOIN facility
      ON facility.facility_id = shipment_event.facility_id
    WHERE shipment_event.shipment_id = shipment.shipment_id
      AND shipment_event.details ? 'temperature_c'
    ORDER BY shipment_event.event_time DESC
    LIMIT 1
) AS latest_temperature ON true
WHERE shipment.status = 'Delayed';

CREATE OR REPLACE VIEW agent_api.candidate_facility AS
SELECT facility_code,
       facility_name,
       city,
       region,
       (capabilities ->> 'cold_storage')::boolean AS cold_storage,
       (capabilities ->> 'maintenance')::boolean AS maintenance,
       (capabilities ->> 'cross_dock')::boolean AS cross_dock
FROM facility
WHERE (capabilities ->> 'cold_storage')::boolean;

CREATE OR REPLACE VIEW agent_api.handling_guide AS
SELECT guide_id,
       title,
       summary,
       content,
       category
FROM operations_guide
WHERE category IN ('Cold Chain', 'Exceptions', 'Platform');

CREATE TABLE IF NOT EXISTS agent_api.recovery_plan (
  plan_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tracking_number text NOT NULL REFERENCES public.shipment(tracking_number),
  target_facility_code text NOT NULL REFERENCES public.facility(facility_code),
  guidance_id bigint NOT NULL REFERENCES public.operations_guide(guide_id),
  rationale text NOT NULL,
  status text NOT NULL DEFAULT 'Proposed'
    CHECK (status IN ('Proposed', 'Approved', 'Executed')),
  approval_token uuid,
  proposed_at timestamptz NOT NULL DEFAULT now(),
  approved_at timestamptz,
  approved_by text,
  executed_at timestamptz,
  execution_result jsonb,
  UNIQUE (tracking_number, target_facility_code, guidance_id)
);

CREATE TABLE IF NOT EXISTS agent_api.recovery_transfer_task (
  transfer_task_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  plan_id uuid NOT NULL UNIQUE REFERENCES agent_api.recovery_plan(plan_id),
  tracking_number text NOT NULL,
  target_facility_code text NOT NULL,
  status text NOT NULL DEFAULT 'Ready',
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS agent_api.notification_outbox (
  notification_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  plan_id uuid NOT NULL UNIQUE REFERENCES agent_api.recovery_plan(plan_id),
  audience text[] NOT NULL,
  payload jsonb NOT NULL,
  status text NOT NULL DEFAULT 'Queued',
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS agent_api.recovery_action_audit (
  audit_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  plan_id uuid NOT NULL REFERENCES agent_api.recovery_plan(plan_id),
  action text NOT NULL,
  actor text NOT NULL,
  detail jsonb NOT NULL DEFAULT '{}'::jsonb,
  occurred_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE VIEW agent_api.recovery_plan_status AS
SELECT plan.plan_id,
     plan.tracking_number,
     plan.target_facility_code,
     facility.facility_name AS target_facility_name,
     plan.guidance_id,
     guide.title AS guidance_title,
     plan.rationale,
     plan.status,
     plan.proposed_at,
     plan.approved_at,
     plan.approved_by,
     plan.executed_at,
     plan.execution_result,
     transfer.status AS transfer_status,
     notification.status AS notification_status
FROM agent_api.recovery_plan plan
JOIN public.facility facility
  ON facility.facility_code = plan.target_facility_code
JOIN public.operations_guide guide
  ON guide.guide_id = plan.guidance_id
LEFT JOIN agent_api.recovery_transfer_task transfer
  ON transfer.plan_id = plan.plan_id
LEFT JOIN agent_api.notification_outbox notification
  ON notification.plan_id = plan.plan_id;

CREATE OR REPLACE FUNCTION agent_api.propose_recovery_plan(
  p_tracking_number text,
  p_target_facility_code text,
  p_guidance_id bigint,
  p_rationale text
)
RETURNS TABLE (
  plan_id uuid,
  tracking_number text,
  target_facility_code text,
  guidance_id bigint,
  status text,
  rationale text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  IF length(trim(p_rationale)) < 10 THEN
    RAISE EXCEPTION 'Recovery rationale is required';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.shipment shipment
    WHERE shipment.tracking_number = p_tracking_number
      AND shipment.status = 'Delayed'
  ) THEN
    RAISE EXCEPTION 'Delayed shipment % was not found', p_tracking_number;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.facility facility
    WHERE facility.facility_code = p_target_facility_code
      AND (facility.capabilities ->> 'cold_storage')::boolean
  ) THEN
    RAISE EXCEPTION 'Facility % is not approved for cold storage', p_target_facility_code;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.operations_guide guide
    WHERE guide.guide_id = p_guidance_id
      AND guide.category IN ('Cold Chain', 'Exceptions')
  ) THEN
    RAISE EXCEPTION 'Approved handling guide % was not found', p_guidance_id;
  END IF;

  INSERT INTO agent_api.recovery_plan (
    tracking_number,
    target_facility_code,
    guidance_id,
    rationale
  )
  VALUES (
    p_tracking_number,
    upper(p_target_facility_code),
    p_guidance_id,
    p_rationale
  )
  ON CONFLICT DO NOTHING;

  UPDATE agent_api.recovery_plan plan
  SET rationale = p_rationale
  WHERE plan.tracking_number = p_tracking_number
    AND plan.target_facility_code = upper(p_target_facility_code)
    AND plan.guidance_id = p_guidance_id
    AND plan.status = 'Proposed';

  INSERT INTO agent_api.recovery_action_audit (plan_id, action, actor, detail)
  SELECT plan.plan_id,
       'PlanProposed',
       session_user,
       jsonb_build_object('rationale', p_rationale)
  FROM agent_api.recovery_plan plan
  WHERE plan.tracking_number = p_tracking_number
    AND plan.target_facility_code = upper(p_target_facility_code)
    AND plan.guidance_id = p_guidance_id;

  RETURN QUERY
  SELECT plan.plan_id,
       plan.tracking_number,
       plan.target_facility_code,
       plan.guidance_id,
       plan.status,
       plan.rationale
  FROM agent_api.recovery_plan plan
  WHERE plan.tracking_number = p_tracking_number
    AND plan.target_facility_code = upper(p_target_facility_code)
    AND plan.guidance_id = p_guidance_id;
END;
$$;

CREATE OR REPLACE FUNCTION agent_api.approve_recovery_plan(
  p_plan_id uuid,
  p_approved_by text
)
RETURNS TABLE (
  plan_id uuid,
  approval_token uuid,
  status text,
  approved_by text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  current_plan agent_api.recovery_plan%ROWTYPE;
BEGIN
  IF length(trim(p_approved_by)) < 2 THEN
    RAISE EXCEPTION 'Approver identity is required';
  END IF;

  SELECT * INTO current_plan
  FROM agent_api.recovery_plan plan
  WHERE plan.plan_id = p_plan_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Recovery plan % was not found', p_plan_id;
  END IF;

  IF current_plan.status = 'Proposed' THEN
    UPDATE agent_api.recovery_plan plan
    SET status = 'Approved',
      approval_token = gen_random_uuid(),
      approved_at = now(),
      approved_by = p_approved_by
    WHERE plan.plan_id = p_plan_id;

    INSERT INTO agent_api.recovery_action_audit (plan_id, action, actor)
    VALUES (p_plan_id, 'PlanApproved', p_approved_by);
  END IF;

  RETURN QUERY
  SELECT plan.plan_id,
       plan.approval_token,
       plan.status,
       plan.approved_by
  FROM agent_api.recovery_plan plan
  WHERE plan.plan_id = p_plan_id;
END;
$$;

CREATE OR REPLACE FUNCTION agent_api.execute_approved_recovery_plan(
  p_plan_id uuid,
  p_approval_token uuid
)
RETURNS TABLE (
  plan_id uuid,
  tracking_number text,
  target_facility_code text,
  status text,
  transfer_status text,
  notification_status text,
  execution_result jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  current_plan agent_api.recovery_plan%ROWTYPE;
  v_shipment_id bigint;
  v_facility_id bigint;
  result jsonb;
BEGIN
  SELECT * INTO current_plan
  FROM agent_api.recovery_plan plan
  WHERE plan.plan_id = p_plan_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Recovery plan % was not found', p_plan_id;
  END IF;

  IF current_plan.approval_token IS NULL
     OR current_plan.approval_token <> p_approval_token THEN
    RAISE EXCEPTION USING
      ERRCODE = '42501',
      MESSAGE = 'Valid operator approval is required';
  END IF;

  IF current_plan.status = 'Executed' THEN
    RETURN QUERY
    SELECT status.plan_id,
         status.tracking_number,
         status.target_facility_code,
         status.status,
         status.transfer_status,
         status.notification_status,
         status.execution_result
    FROM agent_api.recovery_plan_status status
    WHERE status.plan_id = p_plan_id;
    RETURN;
  END IF;

  IF current_plan.status <> 'Approved' THEN
    RAISE EXCEPTION 'Recovery plan % is not approved', p_plan_id;
  END IF;

  SELECT shipment.shipment_id INTO v_shipment_id
  FROM public.shipment shipment
  WHERE shipment.tracking_number = current_plan.tracking_number;

  SELECT facility.facility_id INTO v_facility_id
  FROM public.facility facility
  WHERE facility.facility_code = current_plan.target_facility_code;

  INSERT INTO agent_api.recovery_transfer_task (
    plan_id,
    tracking_number,
    target_facility_code
  )
  VALUES (
    p_plan_id,
    current_plan.tracking_number,
    current_plan.target_facility_code
  )
  ON CONFLICT DO NOTHING;

  INSERT INTO agent_api.notification_outbox (plan_id, audience, payload)
  VALUES (
    p_plan_id,
    ARRAY['Quality Assurance', 'Shipper'],
    jsonb_build_object(
      'tracking_number', current_plan.tracking_number,
      'action', 'Quality hold and cold-storage transfer',
      'target_facility', current_plan.target_facility_code,
      'guidance_id', current_plan.guidance_id
    )
  )
  ON CONFLICT DO NOTHING;

  INSERT INTO public.shipment_event (
    shipment_id,
    facility_id,
    event_type,
    details
  )
      SELECT v_shipment_id,
        v_facility_id,
       'QualityHoldPlaced',
       jsonb_build_object(
         'plan_id', p_plan_id,
         'guidance_id', current_plan.guidance_id,
         'approved_by', current_plan.approved_by,
         'target_facility', current_plan.target_facility_code
       )
  WHERE NOT EXISTS (
    SELECT 1
    FROM public.shipment_event event
    WHERE event.shipment_id = v_shipment_id
      AND event.details ->> 'plan_id' = p_plan_id::text
  );

  result = jsonb_build_object(
    'quality_hold', 'Placed',
    'transfer_task', 'Ready',
    'target_facility', current_plan.target_facility_code,
    'notification', 'Queued'
  );

  UPDATE agent_api.recovery_plan plan
  SET status = 'Executed',
    executed_at = now(),
    execution_result = result
  WHERE plan.plan_id = p_plan_id;

  INSERT INTO agent_api.recovery_action_audit (plan_id, action, actor, detail)
  VALUES (p_plan_id, 'PlanExecuted', session_user, result);

  RETURN QUERY
  SELECT status.plan_id,
       status.tracking_number,
       status.target_facility_code,
       status.status,
       status.transfer_status,
       status.notification_status,
       status.execution_result
  FROM agent_api.recovery_plan_status status
  WHERE status.plan_id = p_plan_id;
END;
$$;

CREATE OR REPLACE FUNCTION agent_api.reset_recovery_demo(p_tracking_number text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  plan_ids uuid[];
BEGIN
  SELECT array_agg(plan.plan_id) INTO plan_ids
  FROM agent_api.recovery_plan plan
  WHERE plan.tracking_number = p_tracking_number;

  IF plan_ids IS NULL THEN
    RETURN;
  END IF;

  DELETE FROM public.shipment_event event
  WHERE event.details ->> 'plan_id' = ANY (
    SELECT ids.plan_id::text FROM unnest(plan_ids) AS ids(plan_id)
  );
  DELETE FROM agent_api.recovery_action_audit audit
  WHERE audit.plan_id = ANY (plan_ids);
  DELETE FROM agent_api.notification_outbox notification
  WHERE notification.plan_id = ANY (plan_ids);
  DELETE FROM agent_api.recovery_transfer_task transfer
  WHERE transfer.plan_id = ANY (plan_ids);
  DELETE FROM agent_api.recovery_plan plan
  WHERE plan.plan_id = ANY (plan_ids);
END;
$$;

REVOKE ALL ON agent_api.recovery_plan FROM PUBLIC;
REVOKE ALL ON agent_api.recovery_transfer_task FROM PUBLIC;
REVOKE ALL ON agent_api.notification_outbox FROM PUBLIC;
REVOKE ALL ON agent_api.recovery_action_audit FROM PUBLIC;
REVOKE ALL ON FUNCTION agent_api.propose_recovery_plan(text, text, bigint, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION agent_api.approve_recovery_plan(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION agent_api.execute_approved_recovery_plan(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION agent_api.reset_recovery_demo(text) FROM PUBLIC;

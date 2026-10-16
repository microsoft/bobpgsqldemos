-- A pg_durable workflow that keeps the pipeline self-healing.
-- Every 10 seconds it re-queues edits the on_change trigger skipped and
-- removes vectors no current article uses. It runs inside HorizonDB as the
-- submitting role and resumes after restarts or failover, so the app needs no
-- background worker. It stops after p_duration to bound durable history.
CREATE OR REPLACE FUNCTION knowledge_hub.ensure_reconciler(p_duration interval DEFAULT interval '12 hours')
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
    instance_id text;
BEGIN
    SELECT id INTO instance_id
    FROM df.instances
    WHERE label = 'knowledge-hub-reconciler' AND status = 'running'
    ORDER BY created_at DESC
    LIMIT 1;
    IF instance_id IS NOT NULL THEN
        RETURN instance_id;
    END IF;

    RETURN df.start(
        df.loop(
            df.seq(
                df.sleep(10),
                'SELECT knowledge_hub.reconcile()'
            ),
            format('SELECT clock_timestamp() < %L::timestamptz', clock_timestamp() + p_duration)
        ),
        'knowledge-hub-reconciler'
    );
END;
$$;

REVOKE ALL ON FUNCTION knowledge_hub.ensure_reconciler(interval) FROM PUBLIC;

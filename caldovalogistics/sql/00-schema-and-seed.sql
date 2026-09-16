DROP TABLE IF EXISTS shipment_event;
DROP TABLE IF EXISTS shipment;
DROP TABLE IF EXISTS operations_guide;
DROP TABLE IF EXISTS facility;

CREATE TABLE facility (
    facility_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    facility_code text NOT NULL UNIQUE,
    facility_name text NOT NULL,
    city text NOT NULL,
    region text NOT NULL,
    capabilities jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE TABLE shipment (
    shipment_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tracking_number text NOT NULL UNIQUE,
    customer_name text NOT NULL,
    origin_facility_id bigint NOT NULL REFERENCES facility(facility_id),
    destination_facility_id bigint NOT NULL REFERENCES facility(facility_id),
    status text NOT NULL DEFAULT 'Booked'
        CHECK (status IN ('Booked', 'In Transit', 'Delayed', 'Delivered')),
    priority text NOT NULL DEFAULT 'Standard'
        CHECK (priority IN ('Standard', 'Expedited', 'Critical')),
    cargo_profile jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE shipment_event (
    event_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    shipment_id bigint NOT NULL REFERENCES shipment(shipment_id),
    facility_id bigint REFERENCES facility(facility_id),
    event_type text NOT NULL,
    event_time timestamptz NOT NULL DEFAULT now(),
    details jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE TABLE operations_guide (
    guide_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    title text NOT NULL,
    summary text NOT NULL,
    content text NOT NULL,
    category text NOT NULL,
    tags jsonb NOT NULL DEFAULT '[]'::jsonb,
    search_document tsvector GENERATED ALWAYS AS (
        setweight(to_tsvector('english', coalesce(title, '')), 'A') ||
        setweight(to_tsvector('english', coalesce(summary, '')), 'B') ||
        setweight(to_tsvector('english', coalesce(content, '')), 'C')
    ) STORED
);

CREATE INDEX operations_guide_search_idx
    ON operations_guide USING gin (search_document);
CREATE INDEX shipment_status_idx ON shipment (status, created_at DESC);
CREATE INDEX shipment_event_shipment_idx ON shipment_event (shipment_id, event_time DESC);

INSERT INTO facility (facility_code, facility_name, city, region, capabilities) VALUES
('SEA1', 'Puget Sound Gateway', 'Seattle', 'Northwest', '{"cold_storage": true, "customs": true, "cross_dock": true}'),
('DEN1', 'Rocky Mountain Hub', 'Denver', 'Mountain', '{"cold_storage": true, "maintenance": true, "cross_dock": true}'),
('DFW1', 'North Texas Distribution Center', 'Fort Worth', 'South Central', '{"cold_storage": false, "customs": true, "cross_dock": true}'),
('ATL1', 'Southeast Transfer Hub', 'Atlanta', 'Southeast', '{"cold_storage": true, "maintenance": false, "cross_dock": true}'),
('BOS1', 'New England Delivery Center', 'Boston', 'Northeast', '{"cold_storage": true, "customs": false, "cross_dock": false}');

INSERT INTO operations_guide (title, summary, content, category, tags) VALUES
('Temperature excursion response for refrigerated freight',
 'Quarantine temperature-sensitive cargo and preserve telemetry before disposition.',
 'When sensor readings exceed the approved range, place the shipment on quality hold, move it to validated cold storage, preserve the complete sensor history, and notify the shipper before release or disposal.',
 'Cold Chain', '["temperature", "refrigerated", "quality-hold"]'),
('Reefer equipment failure at an intermediate hub',
 'Transfer cargo to qualified equipment and record chain-of-custody details.',
 'If refrigeration equipment becomes unavailable, select a facility with cold-storage capability, document seal changes, record transfer times, and attach replacement equipment identifiers to the shipment event.',
 'Cold Chain', '["reefer", "equipment", "transfer"]'),
('Carrier delay escalation procedure',
 'Escalate delayed critical shipments using the regional operations matrix.',
 'For critical shipments delayed more than thirty minutes, contact the regional controller, validate the next connection, and record the recovery plan and estimated arrival time.',
 'Exceptions', '["delay", "carrier", "escalation"]'),
('Customs documentation mismatch',
 'Hold international freight when manifest and commercial invoice details disagree.',
 'Do not release freight when commodity codes, declared value, or consignee details conflict. Preserve submitted documents and route the case to the customs desk.',
 'Compliance', '["customs", "manifest", "documentation"]'),
('Read-after-write behavior for shipment tracking',
 'Use the primary endpoint when a workflow must immediately observe its own write.',
 'Tracking dashboards can use the reader endpoint. Confirmation screens that must display a newly recorded event immediately should query the primary endpoint.',
 'Platform', '["consistency", "endpoints", "tracking"]'),
('Recover database connections after a service interruption',
 'Reconnect through the stable service endpoint using bounded exponential backoff.',
 'Applications should retry transient connection failures, reopen connections through the cluster endpoint, and make commands idempotent before retrying them.',
 'Platform', '["retry", "failover", "connections"]'),
('Damaged cargo evidence collection',
 'Capture photographs, seal condition, packaging state, and handling history.',
 'Before freight is moved, record visible damage, packaging condition, seal identifiers, facility, timestamp, and responsible operator. Keep evidence with the shipment record.',
 'Claims', '["damage", "evidence", "claims"]'),
('Severe weather route disruption',
 'Evaluate alternate hubs and protect service commitments during a regional closure.',
 'Identify reachable facilities with required cargo capabilities, compare alternate connection times, notify the customer, and record the approved diversion plan.',
 'Exceptions', '["weather", "route", "diversion"]');

INSERT INTO shipment (
    tracking_number,
    customer_name,
    origin_facility_id,
    destination_facility_id,
    status,
    priority,
    cargo_profile
)
SELECT 'CLD-2026-0911-001', 'Fabrikam Foods', origin.facility_id, destination.facility_id,
       'Delayed', 'Critical',
       '{"cargo":"vaccines","temperature_min_c":2,"temperature_max_c":8,"sensor_id":"TEMP-4471"}'::jsonb
FROM facility origin, facility destination
WHERE origin.facility_code = 'SEA1' AND destination.facility_code = 'BOS1';

INSERT INTO shipment (
    tracking_number,
    customer_name,
    origin_facility_id,
    destination_facility_id,
    status,
    priority,
    cargo_profile
)
SELECT 'CLD-2026-0911-002', 'Adventure Works', origin.facility_id, destination.facility_id,
       'In Transit', 'Standard',
       '{"cargo":"bicycle components","pieces":48}'::jsonb
FROM facility origin, facility destination
WHERE origin.facility_code = 'DFW1' AND destination.facility_code = 'ATL1';

INSERT INTO shipment_event (shipment_id, facility_id, event_type, event_time, details)
SELECT shipment.shipment_id, facility.facility_id, 'TemperatureAlert', now() - interval '18 minutes',
       '{"temperature_c":11.4,"threshold_c":8,"device":"TEMP-4471"}'::jsonb
FROM shipment, facility
WHERE shipment.tracking_number = 'CLD-2026-0911-001'
  AND facility.facility_code = 'DEN1';

INSERT INTO shipment_event (shipment_id, facility_id, event_type, event_time, details)
SELECT shipment.shipment_id, facility.facility_id, 'Arrived', now() - interval '12 minutes',
       '{"dock":"C14","seal_intact":true}'::jsonb
FROM shipment, facility
WHERE shipment.tracking_number = 'CLD-2026-0911-001'
  AND facility.facility_code = 'DEN1';

SELECT count(*) AS facilities FROM facility;
SELECT count(*) AS shipments FROM shipment;
SELECT count(*) AS guides FROM operations_guide;

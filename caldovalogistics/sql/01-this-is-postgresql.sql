SELECT version();
SELECT current_database(), current_user;

SELECT tracking_number,
       customer_name,
       status,
       cargo_profile ->> 'cargo' AS cargo,
       cargo_profile ->> 'sensor_id' AS sensor_id
FROM shipment
ORDER BY created_at DESC;

SELECT facility_code,
       facility_name,
       capabilities ->> 'cold_storage' AS cold_storage
FROM facility
WHERE (capabilities ->> 'cold_storage')::boolean
ORDER BY facility_code;

INSERT INTO shipment (
    tracking_number,
    customer_name,
    origin_facility_id,
    destination_facility_id,
    priority,
    cargo_profile
)
SELECT 'CLD-2026-DEMO-003',
       'Contoso Outdoor',
       origin.facility_id,
       destination.facility_id,
       'Expedited',
       '{"cargo":"navigation devices","pieces":24}'::jsonb
FROM facility origin, facility destination
WHERE origin.facility_code = 'SEA1'
  AND destination.facility_code = 'ATL1'
ON CONFLICT (tracking_number) DO UPDATE
SET priority = EXCLUDED.priority
RETURNING shipment_id, tracking_number, status, created_at;

SELECT guide_id,
       title,
       ts_rank(search_document, websearch_to_tsquery('english', 'refrigeration failure')) AS rank
FROM operations_guide
WHERE search_document @@ websearch_to_tsquery('english', 'refrigeration failure')
ORDER BY rank DESC;

EXPLAIN (ANALYZE, BUFFERS)
SELECT guide_id, title
FROM operations_guide
WHERE search_document @@ websearch_to_tsquery('english', 'refrigeration failure');

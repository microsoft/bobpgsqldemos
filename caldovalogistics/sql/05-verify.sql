SELECT current_database() AS database_name,
       current_user AS login_name,
       version() AS postgres_version;

SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_name IN ('facility', 'shipment', 'shipment_event', 'operations_guide')
ORDER BY table_name;

SELECT 'facility' AS object_name, count(*) AS row_count FROM facility
UNION ALL
SELECT 'shipment', count(*) FROM shipment
UNION ALL
SELECT 'shipment_event', count(*) FROM shipment_event
UNION ALL
SELECT 'operations_guide', count(*) FROM operations_guide
ORDER BY object_name;

SELECT extname, extversion
FROM pg_extension
WHERE extname IN ('vector', 'pg_diskann', 'pg_textsearch', 'azure_ai')
ORDER BY extname;

SELECT indexname, indexdef
FROM pg_indexes
WHERE schemaname = 'public'
  AND tablename = 'operations_guide'
ORDER BY indexname;
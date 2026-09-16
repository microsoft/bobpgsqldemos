-- Reset only the derived pipeline sink. Source guides remain authoritative.
TRUNCATE TABLE operations_guide_chunk;

-- Reprocess every source guide through chunk -> embed -> sink.
SELECT ai.backfill('caldova-guide-pipeline');

-- The run is asynchronous. Watch it in Pipelines & Workflows or query status.
SELECT *
FROM ai.status('caldova-guide-pipeline');

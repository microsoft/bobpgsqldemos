SELECT ai.run('caldova-guide-pipeline');

SELECT *
FROM ai.status('caldova-guide-pipeline');

SELECT count(*) AS chunks,
       count(embedding) AS embeddings_written,
       count(DISTINCT doc_id) AS source_documents
FROM operations_guide_chunk;

SELECT doc_id,
       chunk_index,
       left(chunk_text, 100) AS chunk_preview,
       vector_dims(embedding) AS dimensions
FROM operations_guide_chunk
ORDER BY doc_id, chunk_index
LIMIT 12;

-- Prerequisites performed at the HorizonDB instance level:
--   1. Allow vector, pg_diskann, pg_textsearch, and azure_ai.
--   2. Enable AI Model Management, or register an embedding model manually.
-- Verify the allowlist before creating extensions.
SHOW azure.extensions;

CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_diskann CASCADE;
CREATE EXTENSION IF NOT EXISTS pg_textsearch;
CREATE EXTENSION IF NOT EXISTS azure_ai;

ALTER TABLE operations_guide
    ADD COLUMN IF NOT EXISTS embedding public.vector(1536);

UPDATE operations_guide
SET embedding = azure_openai.create_embeddings(
    input => title || ' ' || summary || ' ' || content
)::vector
WHERE embedding IS NULL;

CREATE INDEX IF NOT EXISTS operations_guide_bm25_idx
    ON operations_guide
    USING bm25 (content)
    WITH (text_config = 'english');

CREATE INDEX IF NOT EXISTS operations_guide_embedding_diskann_idx
    ON operations_guide
    USING diskann (embedding vector_cosine_ops);

SELECT count(*) AS embedded_guides
FROM operations_guide
WHERE embedding IS NOT NULL;

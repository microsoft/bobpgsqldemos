CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_diskann CASCADE;
CREATE EXTENSION IF NOT EXISTS azure_ai;
CREATE EXTENSION IF NOT EXISTS pg_durable;

CREATE TABLE IF NOT EXISTS operations_guide_chunk (
    doc_id integer,
    chunk_index integer,
    chunk_text text,
    embedding vector(1536),
    metadata jsonb
);

CREATE INDEX IF NOT EXISTS operations_guide_chunk_diskann_idx
    ON operations_guide_chunk
    USING diskann (embedding vector_cosine_ops)
    WITH (spherical_quantized = true);

SELECT ai.create_pipeline(
    name => 'caldova-guide-pipeline',
    source => ai.table_source(
        table_name => 'operations_guide',
        incremental_column => 'guide_id',
        schema_name => 'public'
    ),
    steps => ARRAY[
        ai.chunk(
            input => 'content',
            chunk_size => 256,
            overlap => 32
        ),
        ai.embed(
            input => 'chunk_text',
            model => 'caldova-embedding',
            batch_size => 8,
            dimensions => 1536
        )
    ],
    sink => ai.table_sink(
        table_name => 'operations_guide_chunk',
        schema_name => 'public'
    ),
    trigger => 'manual'
);

SELECT ai.explain('caldova-guide-pipeline');

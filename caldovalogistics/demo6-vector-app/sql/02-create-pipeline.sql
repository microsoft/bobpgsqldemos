-- The AI pipeline that keeps Knowledge Hub vectors current.
-- on_change: every INSERT or UPDATE statement on the source starts a run.
-- incremental_column: each run processes only rows changed since the checkpoint.
SELECT ai.create_pipeline(
    name => 'knowledge-hub-pipeline',
    source => ai.table_source(
        table_name => 'article',
        schema_name => 'knowledge_hub',
        incremental_column => 'updated_at'
    ),
    steps => ARRAY[
        ai.chunk(
            input => 'embedding_text',
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
        table_name => 'chunk_embedding',
        schema_name => 'knowledge_hub',
        on_conflict => ARRAY['chunk_hash'],
        on_conflict_action => 'DO UPDATE SET embedding = EXCLUDED.embedding, doc_id = EXCLUDED.doc_id, chunk_index = EXCLUDED.chunk_index, embedded_at = clock_timestamp()'
    ),
    trigger => 'on_change'
);

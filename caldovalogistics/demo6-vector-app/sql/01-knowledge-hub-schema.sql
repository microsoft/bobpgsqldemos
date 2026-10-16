-- Caldova Knowledge Hub: source data, pipeline sink, and a least-privilege app API.
-- Idempotent. Run as the HorizonDB administrator with azure_ai 2.3.2 or later.

CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_diskann CASCADE;
CREATE EXTENSION IF NOT EXISTS pg_textsearch;
CREATE EXTENSION IF NOT EXISTS azure_ai;
CREATE EXTENSION IF NOT EXISTS pg_durable;

CREATE SCHEMA IF NOT EXISTS knowledge_hub;

-- Source of truth. The pipeline chunks and embeds embedding_text.
CREATE TABLE IF NOT EXISTS knowledge_hub.article (
    article_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    title text NOT NULL CHECK (length(btrim(title)) BETWEEN 3 AND 160),
    category text NOT NULL CHECK (category IN ('Handling procedure', 'Carrier note', 'Facility runbook')),
    content text NOT NULL CHECK (length(btrim(content)) BETWEEN 20 AND 20000),
    author text NOT NULL DEFAULT 'Caldova Operations',
    embedding_text text GENERATED ALWAYS AS (title || E'\n\n' || content) STORED,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

-- Pipeline sink. Rows are content-addressed by chunk_hash because, during
-- preview, the sink doc_id is a batch row number rather than the source key.
CREATE TABLE IF NOT EXISTS knowledge_hub.chunk_embedding (
    doc_id integer,
    chunk_index integer,
    chunk_text text NOT NULL,
    embedding public.vector(1536),
    metadata jsonb,
    chunk_hash text GENERATED ALWAYS AS (md5(chunk_text)) STORED,
    embedded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT chunk_embedding_chunk_hash_key UNIQUE (chunk_hash)
);

-- The chunks each current article should have, computed with the same
-- azure_ai.chunk call the pipeline makes. Joins sink vectors back to articles.
CREATE TABLE IF NOT EXISTS knowledge_hub.article_chunk_map (
    article_id integer NOT NULL REFERENCES knowledge_hub.article (article_id) ON DELETE CASCADE,
    chunk_index integer NOT NULL,
    chunk_hash text NOT NULL,
    PRIMARY KEY (article_id, chunk_index)
);
CREATE INDEX IF NOT EXISTS article_chunk_map_hash_idx ON knowledge_hub.article_chunk_map (chunk_hash);

CREATE TABLE IF NOT EXISTS knowledge_hub.seed_article (
    title text PRIMARY KEY,
    category text NOT NULL,
    content text NOT NULL
);

CREATE INDEX IF NOT EXISTS chunk_embedding_diskann_idx
    ON knowledge_hub.chunk_embedding
    USING diskann (embedding vector_cosine_ops)
    WITH (spherical_quantized = true);

CREATE INDEX IF NOT EXISTS article_bm25_idx
    ON knowledge_hub.article
    USING bm25 (embedding_text)
    WITH (text_config = 'english');

-- An edit to embedded text gets a new timestamp, which the pipeline's
-- incremental_column uses to select changed rows.
CREATE OR REPLACE FUNCTION knowledge_hub.touch_article()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $$
BEGIN
    IF NEW.title IS DISTINCT FROM OLD.title OR NEW.content IS DISTINCT FROM OLD.content THEN
        NEW.updated_at := clock_timestamp();
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS article_touch ON knowledge_hub.article;
CREATE TRIGGER article_touch
    BEFORE UPDATE ON knowledge_hub.article
    FOR EACH ROW EXECUTE FUNCTION knowledge_hub.touch_article();

-- Chunk settings come from the live pipeline definition, so the map always
-- matches what the pipeline writes.
CREATE OR REPLACE FUNCTION knowledge_hub.chunk_settings(
    OUT method text,
    OUT chunk_size integer,
    OUT overlap integer
)
LANGUAGE sql
STABLE
SET search_path = pg_catalog
AS $$
    SELECT method, chunk_size, overlap
    FROM (
        SELECT 1 AS priority,
               coalesce(step ->> 'method', 'recursive') AS method,
               coalesce((step ->> 'chunk_size')::integer, 512) AS chunk_size,
               coalesce((step ->> 'overlap')::integer, 64) AS overlap
        FROM ai.pipelines pipeline
        CROSS JOIN LATERAL unnest(pipeline.steps) AS step
        WHERE pipeline.name = 'knowledge-hub-pipeline'
          AND step ->> 'step' = 'chunk'
        UNION ALL
        SELECT 2, 'recursive', 256, 32
    ) settings
    ORDER BY priority
    LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION knowledge_hub.refresh_chunk_map(p_article_id integer)
RETURNS void
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $$
DECLARE
    settings record;
BEGIN
    SELECT * INTO settings FROM knowledge_hub.chunk_settings();
    DELETE FROM knowledge_hub.article_chunk_map WHERE article_id = p_article_id;
    INSERT INTO knowledge_hub.article_chunk_map (article_id, chunk_index, chunk_hash)
    SELECT article.article_id, chunk.chunk_index, md5(chunk.chunk_text)
    FROM knowledge_hub.article article
    CROSS JOIN LATERAL azure_ai.chunk(
        article.embedding_text,
        settings.method,
        settings.chunk_size,
        settings.overlap
    ) AS chunk(chunk_index, chunk_text)
    WHERE article.article_id = p_article_id;
END;
$$;

CREATE OR REPLACE FUNCTION knowledge_hub.map_article_chunks()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $$
BEGIN
    PERFORM knowledge_hub.refresh_chunk_map(NEW.article_id);
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS article_chunk_map_sync ON knowledge_hub.article;
CREATE TRIGGER article_chunk_map_sync
    AFTER INSERT OR UPDATE OF title, content ON knowledge_hub.article
    FOR EACH ROW EXECUTE FUNCTION knowledge_hub.map_article_chunks();

-- Recompute every article's expected chunks, for example after changing the
-- pipeline's chunk settings. The reconciler then embeds anything missing.
CREATE OR REPLACE FUNCTION knowledge_hub.rebuild_chunk_map()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
    article_count integer := 0;
    current_article integer;
BEGIN
    FOR current_article IN SELECT article_id FROM knowledge_hub.article LOOP
        PERFORM knowledge_hub.refresh_chunk_map(current_article);
        article_count := article_count + 1;
    END LOOP;
    RETURN article_count;
END;
$$;

CREATE OR REPLACE VIEW knowledge_hub.article_freshness AS
SELECT article.article_id,
       article.title,
       article.category,
       article.content,
       article.author,
       article.updated_at,
       count(map.chunk_hash)::integer AS expected_chunks,
       count(embedding.chunk_hash)::integer AS embedded_chunks,
       (count(map.chunk_hash) > 0 AND count(map.chunk_hash) = count(embedding.chunk_hash)) AS searchable
FROM knowledge_hub.article article
LEFT JOIN knowledge_hub.article_chunk_map map ON map.article_id = article.article_id
LEFT JOIN knowledge_hub.chunk_embedding embedding
       ON embedding.chunk_hash = map.chunk_hash
      AND embedding.embedding IS NOT NULL
GROUP BY article.article_id;

-- App write API. Running as the owner means the app role never writes
-- tables, starts pipelines, or touches df.* directly; pipeline triggers keep
-- the owner's privileges. Note: azure_ai grants PUBLIC read access to
-- ai.pipelines and EXECUTE on azure_openai.create_embeddings by default.
CREATE OR REPLACE FUNCTION knowledge_hub.save_article(
    p_article_id integer,
    p_title text,
    p_category text,
    p_content text,
    p_author text DEFAULT 'Caldova Operations'
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
    saved_id integer;
BEGIN
    IF p_article_id IS NULL THEN
        INSERT INTO knowledge_hub.article (title, category, content, author)
        VALUES (
            btrim(p_title),
            p_category,
            btrim(p_content),
            coalesce(nullif(btrim(p_author), ''), 'Caldova Operations')
        )
        RETURNING article_id INTO saved_id;
    ELSE
        UPDATE knowledge_hub.article
        SET title = btrim(p_title),
            category = p_category,
            content = btrim(p_content),
            author = coalesce(nullif(btrim(p_author), ''), author)
        WHERE article_id = p_article_id
        RETURNING article_id INTO saved_id;
        IF saved_id IS NULL THEN
            RAISE EXCEPTION 'Article % was not found', p_article_id USING ERRCODE = 'no_data_found';
        END IF;
    END IF;
    RETURN saved_id;
END;
$$;

CREATE OR REPLACE FUNCTION knowledge_hub.delete_article(p_article_id integer)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
    DELETE FROM knowledge_hub.article WHERE article_id = p_article_id;
    RETURN FOUND;
END;
$$;

CREATE OR REPLACE FUNCTION knowledge_hub.embed_query(p_query text)
RETURNS public.vector
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
    SELECT azure_openai.create_embeddings('caldova-embedding', p_query)::public.vector(1536);
$$;

-- The on_change trigger skips changes made while a run is active, and its
-- checkpoint can advance past them. Re-touch articles still missing vectors
-- once the pipeline is idle, then remove vectors no current article uses.
CREATE OR REPLACE FUNCTION knowledge_hub.reconcile(p_grace interval DEFAULT interval '6 seconds')
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
    touched integer := 0;
    stale_articles integer[];
BEGIN
    IF NOT EXISTS (SELECT 1 FROM ai.pipelines WHERE name = 'knowledge-hub-pipeline' AND NOT paused) THEN
        RETURN 0;
    END IF;
    IF EXISTS (
        SELECT 1 FROM ai.pipeline_runs
        WHERE pipeline_name = 'knowledge-hub-pipeline' AND status = 'running'
    ) THEN
        RETURN 0;
    END IF;

    SELECT array_agg(article.article_id) INTO stale_articles
    FROM knowledge_hub.article article
    WHERE article.updated_at < clock_timestamp() - p_grace
      AND EXISTS (
          SELECT 1
          FROM knowledge_hub.article_chunk_map map
          LEFT JOIN knowledge_hub.chunk_embedding embedding
                 ON embedding.chunk_hash = map.chunk_hash
                AND embedding.embedding IS NOT NULL
          WHERE map.article_id = article.article_id
            AND embedding.chunk_hash IS NULL
      );

    -- Only issue the UPDATE when needed: the on_change trigger is
    -- statement-level, so even a zero-row UPDATE would start a pipeline run.
    IF stale_articles IS NOT NULL THEN
        UPDATE knowledge_hub.article
        SET updated_at = clock_timestamp()
        WHERE article_id = ANY (stale_articles);
        GET DIAGNOSTICS touched = ROW_COUNT;
    END IF;

    DELETE FROM knowledge_hub.chunk_embedding embedding
    WHERE embedding.embedded_at < clock_timestamp() - interval '10 minutes'
      AND NOT EXISTS (
          SELECT 1 FROM knowledge_hub.article_chunk_map map
          WHERE map.chunk_hash = embedding.chunk_hash
      );

    RETURN touched;
END;
$$;

-- One JSON snapshot for the live pipeline view: definition, recent runs, the
-- latest run's pg_durable steps, the reconciler workflow, and freshness.
CREATE OR REPLACE FUNCTION knowledge_hub.pipeline_status()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
    WITH pipeline AS (
        SELECT name, source_config, steps, sink_config, trigger_type, paused, updated_at
        FROM ai.pipelines
        WHERE name = 'knowledge-hub-pipeline'
    ),
    runs AS (
        SELECT id, status, rows_processed, error, started_at, completed_at, instance_id
        FROM ai.pipeline_runs
        WHERE pipeline_name = 'knowledge-hub-pipeline'
        ORDER BY id DESC
        LIMIT 8
    ),
    latest AS (
        SELECT * FROM runs ORDER BY id DESC LIMIT 1
    ),
    nodes AS (
        SELECT node.id, node.query, node.status, node.created_at, node.updated_at
        FROM df.nodes node
        JOIN latest ON latest.instance_id = node.instance_id
        WHERE node.node_type = 'SQL'
    ),
    reconciler AS (
        SELECT instance.id, instance.status, instance.created_at,
               execution.execution_id AS iteration,
               execution.started_at AS last_tick
        FROM df.instances instance
        LEFT JOIN LATERAL (
            SELECT executions.execution_id, executions.started_at
            FROM _duroxide.executions executions
            WHERE executions.instance_id = instance.id
            ORDER BY executions.execution_id DESC
            LIMIT 1
        ) execution ON true
        WHERE instance.label = 'knowledge-hub-reconciler'
        ORDER BY instance.created_at DESC
        LIMIT 1
    ),
    freshness AS (
        SELECT count(*)::integer AS articles,
               count(*) FILTER (WHERE searchable)::integer AS searchable_articles,
               coalesce(sum(expected_chunks), 0)::integer AS expected_chunks,
               coalesce(sum(embedded_chunks), 0)::integer AS embedded_chunks
        FROM knowledge_hub.article_freshness
    )
    SELECT jsonb_build_object(
        'checked_at', clock_timestamp(),
        'pipeline', (SELECT to_jsonb(pipeline) FROM pipeline),
        'checkpoint', (
            SELECT jsonb_build_object(
                'last_value', last_value,
                'last_run_at', last_run_at,
                'total_processed', total_processed
            )
            FROM ai.pipeline_checkpoints
            WHERE pipeline_name = 'knowledge-hub-pipeline'
        ),
        'runs', coalesce((SELECT jsonb_agg(to_jsonb(runs) ORDER BY id DESC) FROM runs), '[]'::jsonb),
        'nodes', coalesce((SELECT jsonb_agg(to_jsonb(nodes) ORDER BY created_at, updated_at, id) FROM nodes), '[]'::jsonb),
        'reconciler', (SELECT to_jsonb(reconciler) FROM reconciler),
        'freshness', (SELECT to_jsonb(freshness) FROM freshness),
        'sink_rows', (SELECT count(*) FROM knowledge_hub.chunk_embedding)
    );
$$;

-- Restore the seed articles for a repeatable demo. Only changed rows are re-embedded.
CREATE OR REPLACE FUNCTION knowledge_hub.reset_demo()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
    restored integer;
BEGIN
    -- Serialize resets so concurrent clicks cannot insert duplicate seeds.
    PERFORM pg_advisory_xact_lock(hashtext('knowledge_hub.reset_demo'));

    DELETE FROM knowledge_hub.article article
    WHERE NOT EXISTS (SELECT 1 FROM knowledge_hub.seed_article seed WHERE seed.title = article.title);

    IF EXISTS (
        SELECT 1
        FROM knowledge_hub.article article
        JOIN knowledge_hub.seed_article seed ON seed.title = article.title
        WHERE (article.category, article.content, article.author)
              IS DISTINCT FROM (seed.category, seed.content, 'Caldova Operations')
    ) THEN
        UPDATE knowledge_hub.article article
        SET category = seed.category,
            content = seed.content,
            author = 'Caldova Operations'
        FROM knowledge_hub.seed_article seed
        WHERE seed.title = article.title
          AND (article.category, article.content, article.author)
              IS DISTINCT FROM (seed.category, seed.content, 'Caldova Operations');
    END IF;

    INSERT INTO knowledge_hub.article (title, category, content)
    SELECT seed.title, seed.category, seed.content
    FROM knowledge_hub.seed_article seed
    WHERE NOT EXISTS (SELECT 1 FROM knowledge_hub.article article WHERE article.title = seed.title);

    SELECT count(*) INTO restored FROM knowledge_hub.article;
    RETURN restored;
END;
$$;

REVOKE ALL ON SCHEMA knowledge_hub FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA knowledge_hub FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA knowledge_hub FROM PUBLIC;

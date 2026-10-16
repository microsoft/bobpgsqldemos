-- Least-privilege grants for the Knowledge Hub app role. The setup script
-- creates knowledge_hub_app with a password from pwd.env before running this.
GRANT CONNECT ON DATABASE postgres TO knowledge_hub_app;
GRANT USAGE ON SCHEMA knowledge_hub TO knowledge_hub_app;
GRANT USAGE ON SCHEMA public TO knowledge_hub_app;

REVOKE ALL ON ALL TABLES IN SCHEMA knowledge_hub FROM knowledge_hub_app;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA knowledge_hub FROM knowledge_hub_app;

-- Read paths for search and status.
GRANT SELECT ON knowledge_hub.article,
                knowledge_hub.article_chunk_map,
                knowledge_hub.chunk_embedding,
                knowledge_hub.article_freshness
TO knowledge_hub_app;

-- Writes and AI calls only through owner-run functions.
GRANT EXECUTE ON FUNCTION knowledge_hub.save_article(integer, text, text, text, text),
                          knowledge_hub.delete_article(integer),
                          knowledge_hub.embed_query(text),
                          knowledge_hub.pipeline_status(),
                          knowledge_hub.reset_demo()
TO knowledge_hub_app;

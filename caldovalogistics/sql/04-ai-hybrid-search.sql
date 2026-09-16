-- This wording deliberately differs from the operations guide terminology.
-- Keyword-only search is weak; semantic and hybrid retrieval find the procedure.
WITH query AS (
    SELECT 'cooling equipment stopped keeping cargo cold'::text AS query_text,
           azure_openai.create_embeddings(
               input => 'cooling equipment stopped keeping cargo cold'
           )::vector AS query_vector
),
keyword_results AS (
    SELECT guide.guide_id,
           row_number() OVER (
               ORDER BY guide.content <@> to_bm25query(query.query_text, 'operations_guide_bm25_idx')
           ) AS keyword_rank
    FROM operations_guide guide, query
    ORDER BY guide.content <@> to_bm25query(query.query_text, 'operations_guide_bm25_idx')
    LIMIT 20
),
vector_results AS (
    SELECT guide.guide_id,
           row_number() OVER (
               ORDER BY guide.embedding <=> query.query_vector
           ) AS vector_rank
    FROM operations_guide guide, query
    ORDER BY guide.embedding <=> query.query_vector
    LIMIT 20
)
SELECT guide.guide_id,
       guide.title,
       guide.category,
       (1.0 / (60 + coalesce(keyword_results.keyword_rank, 1000))) +
       (1.0 / (60 + coalesce(vector_results.vector_rank, 1000))) AS rrf_score
FROM operations_guide guide
LEFT JOIN keyword_results ON keyword_results.guide_id = guide.guide_id
LEFT JOIN vector_results ON vector_results.guide_id = guide.guide_id
WHERE keyword_results.guide_id IS NOT NULL
   OR vector_results.guide_id IS NOT NULL
ORDER BY rrf_score DESC
LIMIT 5;

-- Produce a grounded operational briefing from the retrieved source material.
WITH query AS (
    SELECT azure_openai.create_embeddings(
        input => 'cooling equipment stopped keeping cargo cold'
    )::vector AS query_vector
),
evidence AS (
    SELECT guide_id, title, content
    FROM operations_guide, query
    ORDER BY embedding <=> query.query_vector
    LIMIT 3
)
SELECT azure_ai.generate(
    prompt =>
        'Write a concise logistics incident briefing. Use only the evidence below. ' ||
        'Cite each recommendation as [Guide <id>]. Incident: shipment CLD-2026-0911-001 ' ||
        'reported 11.4 C against an 8 C maximum at DEN1.' || E'\n\nEvidence:\n' ||
        string_agg('[Guide ' || guide_id || '] ' || title || ': ' || content, E'\n'),
    system_prompt =>
        'You assist logistics operators. Do not invent shipment facts or procedures.'
) AS grounded_briefing
FROM evidence;

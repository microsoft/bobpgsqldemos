SELECT guide_id, title, category
FROM operations_guide
WHERE search_document @@ websearch_to_tsquery('english', 'temperature excursion')
ORDER BY guide_id;

\sleep 100 ms
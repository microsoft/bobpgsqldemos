from __future__ import annotations

from typing import Any

from knowledge_hub.database import Database
from knowledge_hub.models import Article, SearchResult

ARTICLE_COLUMNS = """
    article_id, title, category, content, author, updated_at,
    expected_chunks, embedded_chunks, searchable
"""

# Nearest chunks by cosine distance (DiskANN), mapped back to the current
# articles that contain them. Vectors for old or deleted text never match.
VECTOR_CANDIDATES = """
    nearest AS (
        SELECT embedding.chunk_hash,
               embedding.chunk_text,
               embedding.embedding <=> query.vector AS distance
        FROM knowledge_hub.chunk_embedding embedding, query
        ORDER BY embedding.embedding <=> query.vector
        LIMIT 60
    ),
    vector_hits AS (
        SELECT DISTINCT ON (map.article_id)
               map.article_id, nearest.chunk_text, nearest.distance
        FROM nearest
        JOIN knowledge_hub.article_chunk_map map ON map.chunk_hash = nearest.chunk_hash
        ORDER BY map.article_id, nearest.distance
    ),
    vector_ranked AS (
        SELECT vector_hits.*, row_number() OVER (ORDER BY distance) AS vector_rank
        FROM vector_hits
    )
"""

KEYWORD_CANDIDATES = """
    keyword_ranked AS (
        SELECT article.article_id,
               (article.embedding_text <@> to_bm25query(%(query)s, 'knowledge_hub.article_bm25_idx'))::float AS bm25,
               row_number() OVER (
                   ORDER BY article.embedding_text <@> to_bm25query(%(query)s, 'knowledge_hub.article_bm25_idx')
               ) AS keyword_rank
        FROM knowledge_hub.article article
        ORDER BY article.embedding_text <@> to_bm25query(%(query)s, 'knowledge_hub.article_bm25_idx')
        LIMIT 20
    )
"""

VECTOR_SQL = f"""
    WITH query AS (SELECT knowledge_hub.embed_query(%(query)s) AS vector),
    {VECTOR_CANDIDATES}
    SELECT article.article_id, article.title, article.category,
           vector_ranked.chunk_text AS snippet,
           (1 - vector_ranked.distance)::float AS score,
           vector_ranked.vector_rank
    FROM vector_ranked
    JOIN knowledge_hub.article article ON article.article_id = vector_ranked.article_id
    ORDER BY vector_ranked.vector_rank
    LIMIT 8
"""

KEYWORD_SQL = f"""
    WITH {KEYWORD_CANDIDATES}
    SELECT article.article_id, article.title, article.category,
           left(article.content, 260) AS snippet,
           (-keyword_ranked.bm25)::float AS score,
           keyword_ranked.keyword_rank
    FROM keyword_ranked
    JOIN knowledge_hub.article article ON article.article_id = keyword_ranked.article_id
    ORDER BY keyword_ranked.keyword_rank
    LIMIT 8
"""

# Reciprocal rank fusion (k = 60) of the vector and BM25 rankings.
HYBRID_SQL = f"""
    WITH query AS (SELECT knowledge_hub.embed_query(%(query)s) AS vector),
    {VECTOR_CANDIDATES},
    {KEYWORD_CANDIDATES}
    SELECT article.article_id, article.title, article.category,
           coalesce(vector_ranked.chunk_text, left(article.content, 260)) AS snippet,
           (coalesce(1.0 / (60 + vector_ranked.vector_rank), 0)
            + coalesce(1.0 / (60 + keyword_ranked.keyword_rank), 0))::float AS score,
           vector_ranked.vector_rank,
           keyword_ranked.keyword_rank
    FROM knowledge_hub.article article
    LEFT JOIN vector_ranked ON vector_ranked.article_id = article.article_id
    LEFT JOIN keyword_ranked ON keyword_ranked.article_id = article.article_id
    WHERE vector_ranked.article_id IS NOT NULL OR keyword_ranked.article_id IS NOT NULL
    ORDER BY score DESC
    LIMIT 8
"""

SCORE_LABELS = {"vector": "cosine similarity", "keyword": "BM25 score", "hybrid": "RRF score"}
SEARCH_SQL = {"vector": VECTOR_SQL, "keyword": KEYWORD_SQL, "hybrid": HYBRID_SQL}


class KnowledgeHubRepository:
    def __init__(self, database: Database) -> None:
        self._database = database

    def list_articles(self) -> list[Article]:
        with self._database.primary() as connection:
            rows = connection.execute(
                f"SELECT {ARTICLE_COLUMNS} FROM knowledge_hub.article_freshness ORDER BY category, title"
            ).fetchall()
        return [Article(**row) for row in rows]

    def get_article(self, article_id: int) -> Article | None:
        with self._database.primary() as connection:
            row = connection.execute(
                f"SELECT {ARTICLE_COLUMNS} FROM knowledge_hub.article_freshness WHERE article_id = %s",
                (article_id,),
            ).fetchone()
        return Article(**row) if row else None

    def save_article(
        self,
        article_id: int | None,
        title: str,
        category: str,
        content: str,
        author: str,
    ) -> int:
        with self._database.primary() as connection:
            row = connection.execute(
                "SELECT knowledge_hub.save_article(%s, %s, %s, %s, %s) AS article_id",
                (article_id, title, category, content, author),
            ).fetchone()
        return int(row["article_id"])

    def delete_article(self, article_id: int) -> bool:
        with self._database.primary() as connection:
            row = connection.execute(
                "SELECT knowledge_hub.delete_article(%s) AS deleted", (article_id,)
            ).fetchone()
        return bool(row["deleted"])

    def reset_demo(self) -> None:
        with self._database.primary() as connection:
            connection.execute("SELECT knowledge_hub.reset_demo()")

    def search(self, query: str, mode: str) -> list[SearchResult]:
        with self._database.reader() as connection:
            rows = connection.execute(SEARCH_SQL[mode], {"query": query}).fetchall()
        return [
            SearchResult(
                article_id=row["article_id"],
                title=row["title"],
                category=row["category"],
                snippet=row["snippet"],
                score=float(row["score"]),
                score_label=SCORE_LABELS[mode],
                vector_rank=row.get("vector_rank"),
                keyword_rank=row.get("keyword_rank"),
            )
            for row in rows
        ]

    def pipeline_status(self) -> dict[str, Any]:
        with self._database.primary() as connection:
            row = connection.execute("SELECT knowledge_hub.pipeline_status() AS status").fetchone()
        return row["status"]

    def freshness(self) -> list[dict[str, Any]]:
        with self._database.primary() as connection:
            return connection.execute(
                """
                SELECT article_id, expected_chunks, embedded_chunks, searchable
                FROM knowledge_hub.article_freshness
                """
            ).fetchall()

    def vector_index_definition(self) -> str | None:
        with self._database.primary() as connection:
            row = connection.execute(
                """
                SELECT pg_get_indexdef(index_class.oid) AS definition
                FROM pg_class index_class
                JOIN pg_namespace namespace ON namespace.oid = index_class.relnamespace
                WHERE namespace.nspname = 'knowledge_hub'
                  AND index_class.relname = 'chunk_embedding_diskann_idx'
                """
            ).fetchone()
        return row["definition"] if row else None

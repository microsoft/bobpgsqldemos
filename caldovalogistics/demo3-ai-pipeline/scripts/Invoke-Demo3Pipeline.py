from __future__ import annotations

import argparse
import json
import os
import time
from pathlib import Path

import psycopg
from psycopg.conninfo import make_conninfo
from psycopg.rows import dict_row


PIPELINE_NAME = "caldova-guide-pipeline"
MODEL_ALIAS = "caldova-embedding"
REQUIRED_EXTENSIONS = {"vector", "pg_diskann", "azure_ai", "pg_durable"}


def load_config(path: Path) -> dict[str, object]:
    return json.loads(path.read_text(encoding="utf-8-sig"))


def conninfo(config: dict[str, object]) -> str:
    password = os.environ.get("CALDOVA_DATABASE_PASSWORD")
    if not password:
        raise RuntimeError("CALDOVA_DATABASE_PASSWORD is required.")
    return make_conninfo(
        host=str(config["primaryHost"]),
        port=5432,
        dbname=str(config["database"]),
        user=str(config["user"]),
        password=password,
        sslmode=str(config["sslMode"]),
        connect_timeout=20,
    )


def settings(config: dict[str, object]) -> None:
    with psycopg.connect(conninfo(config), autocommit=True) as connection:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                SELECT current_setting('shared_preload_libraries'),
                       current_setting('azure.extensions', true)
                """
            )
            preload, extensions = cursor.fetchone()
    print(json.dumps({"shared_preload_libraries": preload or "", "azure_extensions": extensions or ""}))


def registry_has_alias(rows: list[dict[str, object]], alias: str) -> bool:
    return any(alias in {str(value) for value in row.values() if value is not None} for row in rows)


def pipeline_exists(cursor: psycopg.Cursor, name: str) -> bool:
    cursor.execute("SELECT * FROM ai.list_pipelines()")
    return any(
        name in {str(value) for value in row.values() if value is not None}
        for row in cursor.fetchall()
    )


def pipeline_status(cursor: psycopg.Cursor, name: str) -> dict[str, object] | None:
    cursor.execute("SELECT * FROM ai.status(%s)", (name,))
    rows = cursor.fetchall()
    return rows[0] if rows else None


def wait_for_pipeline(cursor: psycopg.Cursor, name: str) -> None:
    for _ in range(60):
        status = pipeline_status(cursor, name)
        run_status = str((status or {}).get("last_run_status", "")).lower()
        if run_status == "completed":
            return
        if run_status == "failed":
            raise RuntimeError(f"Pipeline failed: {status}")
        time.sleep(5)
    raise TimeoutError(f"Pipeline '{name}' did not complete within five minutes.")


def setup(config: dict[str, object], script_path: Path) -> None:
    endpoint = os.environ.get("CALDOVA_FOUNDRY_ENDPOINT")
    endpoint_key = os.environ.get("CALDOVA_FOUNDRY_KEY")
    deployment = os.environ.get("CALDOVA_EMBEDDING_DEPLOYMENT", MODEL_ALIAS)
    if not endpoint or not endpoint_key:
        raise RuntimeError("Foundry endpoint and key are required in process environment.")

    with psycopg.connect(conninfo(config), autocommit=True, row_factory=dict_row) as connection:
        with connection.cursor() as cursor:
            for extension in ("vector", "pg_diskann", "azure_ai", "pg_durable"):
                cursor.execute(f"CREATE EXTENSION IF NOT EXISTS {extension} CASCADE")

            cursor.execute("SELECT * FROM model_registry.model_list_all()")
            models = cursor.fetchall()
            if not registry_has_alias(models, MODEL_ALIAS):
                cursor.execute(
                    """
                    SELECT model_registry.model_add(
                        %s, %s, %s, %s, NULL, %s, %s
                    )
                    """,
                    (
                        MODEL_ALIAS,
                        endpoint,
                        deployment,
                        "text-embedding-3-small",
                        "subscription-key",
                        endpoint_key,
                    ),
                )

            cursor.execute(
                "SELECT vector_dims(azure_openai.create_embeddings(%s, %s)::vector) AS dimensions",
                (MODEL_ALIAS, "Caldova pipeline connectivity test"),
            )
            dimensions = cursor.fetchone()["dimensions"]
            if dimensions != 1536:
                raise RuntimeError(f"Expected 1536 embedding dimensions, received {dimensions}.")

            created_pipeline = not pipeline_exists(cursor, PIPELINE_NAME)
            if created_pipeline:
                cursor.execute(script_path.read_text(encoding="utf-8"), prepare=False)

            cursor.execute("SELECT count(*) AS chunks FROM operations_guide_chunk")
            sink_is_empty = cursor.fetchone()["chunks"] == 0
            if created_pipeline or sink_is_empty:
                current_status = pipeline_status(cursor, PIPELINE_NAME)
                if str((current_status or {}).get("last_run_status", "")).lower() != "running":
                    for attempt in range(12):
                        try:
                            cursor.execute("SELECT ai.run(%s)", (PIPELINE_NAME,))
                            break
                        except psycopg.InternalError as error:
                            if "background worker not yet initialized" not in str(error) or attempt == 11:
                                raise
                            time.sleep(5)
                wait_for_pipeline(cursor, PIPELINE_NAME)


def status(config: dict[str, object]) -> None:
    with psycopg.connect(conninfo(config), autocommit=True, row_factory=dict_row) as connection:
        with connection.cursor() as cursor:
            cursor.execute("SELECT extname FROM pg_extension")
            extensions = {row["extname"] for row in cursor.fetchall()}
            cursor.execute("SELECT * FROM model_registry.model_list_all()")
            models = cursor.fetchall()
            cursor.execute("SELECT * FROM ai.status(%s)", (PIPELINE_NAME,))
            pipeline_status = cursor.fetchall()
            cursor.execute(
                """
                SELECT count(*) AS chunks,
                       count(embedding) AS embeddings_written,
                       count(DISTINCT doc_id) AS source_documents
                FROM operations_guide_chunk
                """
            )
            counts = cursor.fetchone()
            cursor.execute(
                """
                SELECT count(*) AS index_count
                FROM pg_indexes
                WHERE schemaname = 'public'
                  AND indexname = 'operations_guide_chunk_diskann_idx'
                """
            )
            index_count = cursor.fetchone()["index_count"]

    result = {
        "extensions_ready": REQUIRED_EXTENSIONS.issubset(extensions),
        "installed_extensions": sorted(extensions & REQUIRED_EXTENSIONS),
        "model_registered": registry_has_alias(models, MODEL_ALIAS),
        "pipeline_status": pipeline_status,
        "chunks": counts["chunks"],
        "embeddings_written": counts["embeddings_written"],
        "source_documents": counts["source_documents"],
        "diskann_index": index_count == 1,
    }
    last_run_status = str((pipeline_status[0] if pipeline_status else {}).get("last_run_status", "")).lower()
    result["pipeline_completed"] = last_run_status == "completed"
    result["ready"] = (
        result["extensions_ready"]
        and result["model_registered"]
        and result["pipeline_completed"]
        and result["chunks"] > 0
        and result["chunks"] == result["embeddings_written"]
        and result["source_documents"] == 8
        and result["diskann_index"]
    )
    print(json.dumps(result, default=str))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("settings", "setup", "status"))
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--script", type=Path)
    args = parser.parse_args()
    config = load_config(args.config)
    if args.action == "settings":
        settings(config)
    elif args.action == "setup":
        if args.script is None:
            parser.error("--script is required for setup")
        setup(config, args.script)
    else:
        status(config)


if __name__ == "__main__":
    main()

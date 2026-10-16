"""Set up, verify, reset, and tear down the Caldova Knowledge Hub database objects."""

from __future__ import annotations

import argparse
import json
import os
import time
from pathlib import Path

import psycopg
from psycopg import sql
from psycopg.rows import dict_row

DEMO_ROOT = Path(__file__).resolve().parents[1]
SQL_ROOT = DEMO_ROOT / "sql"
PIPELINE_NAME = "knowledge-hub-pipeline"
APP_ROLE = "knowledge_hub_app"
MODEL_ALIAS = "caldova-embedding"
MINIMUM_AZURE_AI = (2, 3, 2)


def load_config(path: Path) -> dict[str, object]:
    return json.loads(path.read_text(encoding="utf-8-sig"))


def connect(config: dict[str, object]) -> psycopg.Connection:
    password = os.environ.get("CALDOVA_DATABASE_PASSWORD")
    if not password:
        raise RuntimeError("CALDOVA_DATABASE_PASSWORD is required.")
    return psycopg.connect(
        host=str(config["primaryHost"]),
        port=5432,
        dbname=str(config["database"]),
        user=str(config["user"]),
        password=password,
        sslmode=str(config["sslMode"]),
        connect_timeout=20,
        keepalives=1,
        keepalives_idle=20,
        keepalives_interval=10,
        keepalives_count=3,
        autocommit=True,
        row_factory=dict_row,
    )


def run_file(connection: psycopg.Connection, name: str) -> None:
    connection.execute((SQL_ROOT / name).read_text(encoding="utf-8"), prepare=False)


def version_tuple(value: str) -> tuple[int, ...]:
    return tuple(int(part) for part in value.split("."))


def check_prerequisites(connection: psycopg.Connection) -> None:
    row = connection.execute(
        "SELECT installed_version, default_version FROM pg_available_extensions WHERE name = 'azure_ai'"
    ).fetchone()
    if row is None or row["installed_version"] is None:
        raise RuntimeError("azure_ai is not installed. Run demo3-ai-pipeline/scripts/00-preflight.ps1 first.")
    if version_tuple(row["installed_version"]) < MINIMUM_AZURE_AI:
        raise RuntimeError(
            f"azure_ai {row['installed_version']} is installed; 2.3.2 or later is required for "
            f"on_change pipelines. Run: ALTER EXTENSION azure_ai UPDATE TO '{row['default_version']}';"
        )
    models = connection.execute("SELECT * FROM model_registry.model_list_all()").fetchall()
    if not any(MODEL_ALIAS in {str(value) for value in model.values() if value is not None} for model in models):
        raise RuntimeError(
            f"Model alias '{MODEL_ALIAS}' is not registered. Run demo3-ai-pipeline/scripts/00-preflight.ps1 first."
        )
    worker = connection.execute(
        "SELECT extract(epoch FROM now() - max(last_seen_at)) AS age FROM df._worker_epoch"
    ).fetchone()
    if worker is None or worker["age"] is None or worker["age"] > 30:
        raise RuntimeError("The pg_durable worker is not running. Check shared_preload_libraries.")


def pipeline_exists(connection: psycopg.Connection) -> bool:
    return connection.execute("SELECT 1 FROM ai.pipelines WHERE name = %s", (PIPELINE_NAME,)).fetchone() is not None


def ensure_app_role(connection: psycopg.Connection) -> None:
    password = os.environ.get("KNOWLEDGE_HUB_APP_PASSWORD")
    if not password:
        raise RuntimeError("KNOWLEDGE_HUB_APP_PASSWORD is required.")
    exists = connection.execute("SELECT 1 FROM pg_roles WHERE rolname = %s", (APP_ROLE,)).fetchone()
    statement = "ALTER ROLE {} WITH LOGIN PASSWORD {}" if exists else "CREATE ROLE {} LOGIN PASSWORD {}"
    connection.execute(sql.SQL(statement).format(sql.Identifier(APP_ROLE), sql.Literal(password)))
    run_file(connection, "05-app-role-grants.sql")


def freshness(connection: psycopg.Connection) -> dict[str, int]:
    return connection.execute(
        """
        SELECT count(*)::int AS articles,
               count(*) FILTER (WHERE searchable)::int AS searchable,
               coalesce(sum(expected_chunks), 0)::int AS expected_chunks,
               coalesce(sum(embedded_chunks), 0)::int AS embedded_chunks
        FROM knowledge_hub.article_freshness
        """
    ).fetchone()


def wait_until_searchable(connection: psycopg.Connection, timeout_seconds: int = 240) -> dict[str, int]:
    deadline = time.monotonic() + timeout_seconds
    while True:
        state = freshness(connection)
        if state["articles"] and state["articles"] == state["searchable"]:
            return state
        if time.monotonic() > deadline:
            raise TimeoutError(f"Articles did not become searchable: {state}")
        time.sleep(3)


def setup(config: dict[str, object], reset: bool) -> None:
    with connect(config) as connection:
        check_prerequisites(connection)
        run_file(connection, "01-knowledge-hub-schema.sql")
        if not pipeline_exists(connection):
            run_file(connection, "02-create-pipeline.sql")
        connection.execute("SELECT knowledge_hub.rebuild_chunk_map()")
        run_file(connection, "03-durable-reconciler.sql")
        reconciler = connection.execute("SELECT knowledge_hub.ensure_reconciler() AS id").fetchone()["id"]
        run_file(connection, "04-seed-articles.sql")
        article_count = connection.execute("SELECT count(*)::int AS n FROM knowledge_hub.article").fetchone()["n"]
        if reset or article_count == 0:
            connection.execute("SELECT knowledge_hub.reset_demo()")
        ensure_app_role(connection)
        state = wait_until_searchable(connection)
    print(json.dumps({"ready": True, "reconciler": reconciler, **state}))


def status(config: dict[str, object]) -> None:
    with connect(config) as connection:
        snapshot = connection.execute("SELECT knowledge_hub.pipeline_status() AS s").fetchone()["s"]
    print(json.dumps(snapshot, default=str))


def reset(config: dict[str, object]) -> None:
    with connect(config) as connection:
        connection.execute("SELECT knowledge_hub.reset_demo()")
        connection.execute("SELECT knowledge_hub.ensure_reconciler()")
        state = wait_until_searchable(connection)
    print(json.dumps({"ready": True, **state}))


def teardown(config: dict[str, object]) -> None:
    with connect(config) as connection:
        for row in connection.execute(
            "SELECT id FROM df.instances WHERE label = 'knowledge-hub-reconciler' AND status = 'running'"
        ).fetchall():
            connection.execute("SELECT df.cancel(%s, 'Knowledge Hub teardown')", (row["id"],))
        if pipeline_exists(connection):
            connection.execute("SELECT ai.pause(%s)", (PIPELINE_NAME,))
            connection.execute("SELECT ai.drop_pipeline(%s)", (PIPELINE_NAME,))
        connection.execute("DROP SCHEMA IF EXISTS knowledge_hub CASCADE")
        if connection.execute("SELECT 1 FROM pg_roles WHERE rolname = %s", (APP_ROLE,)).fetchone():
            connection.execute(sql.SQL("DROP OWNED BY {}").format(sql.Identifier(APP_ROLE)))
            connection.execute(sql.SQL("DROP ROLE {}").format(sql.Identifier(APP_ROLE)))
    print(json.dumps({"removed": True}))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("setup", "status", "reset", "teardown"))
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--reset", action="store_true")
    args = parser.parse_args()
    config = load_config(args.config)
    if args.action == "setup":
        setup(config, args.reset)
    elif args.action == "status":
        status(config)
    elif args.action == "reset":
        reset(config)
    else:
        teardown(config)


if __name__ == "__main__":
    main()

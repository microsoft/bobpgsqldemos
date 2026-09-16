from __future__ import annotations

import argparse
import json
import os
from pathlib import Path

import psycopg
from psycopg import sql
from psycopg.conninfo import make_conninfo


EXPECTED_COUNTS = {
    "facility": 5,
    "shipment": 2,
    "shipment_event": 2,
    "operations_guide": 8,
}
AI_EXTENSIONS = {"vector", "pg_diskann", "pg_textsearch", "azure_ai"}


def connection_string(config: dict[str, object], host_key: str) -> str:
    password = os.environ.get("CALDOVA_DATABASE_PASSWORD")
    if not password:
        raise RuntimeError("CALDOVA_DATABASE_PASSWORD is required.")
    parameters = {
        "host": str(config[host_key]),
        "port": 5432,
        "dbname": str(config["database"]),
        "user": str(config["user"]),
        "password": password,
        "sslmode": str(config["sslMode"]),
        "connect_timeout": 15,
    }
    return make_conninfo(
        **parameters,
    )


def endpoint_status(config: dict[str, object], host_key: str) -> dict[str, object]:
    with psycopg.connect(connection_string(config, host_key), autocommit=True) as connection:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                SELECT version(),
                       pg_is_in_recovery(),
                       current_setting('transaction_read_only'),
                       current_setting('pg_stat_statements.track'),
                       inet_server_addr()::text,
                       pg_backend_pid()
                """
            )
            version, is_replica, read_only, query_stats_track, address, backend_pid = cursor.fetchone()
    return {
        "postgres_version": version,
        "is_replica": is_replica,
        "transaction_read_only": read_only,
        "query_stats_track": query_stats_track,
        "server_address": address,
        "backend_pid": backend_pid,
    }


def database_status(config: dict[str, object]) -> dict[str, object]:
    primary = endpoint_status(config, "primaryHost")
    reader = endpoint_status(config, "readerHost")
    with psycopg.connect(connection_string(config, "primaryHost"), autocommit=True) as connection:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                SELECT table_name
                FROM information_schema.tables
                WHERE table_schema = 'public'
                  AND table_name = ANY(%s)
                """,
                (list(EXPECTED_COUNTS),),
            )
            tables = {row[0] for row in cursor.fetchall()}
            counts: dict[str, int] = {}
            if tables == set(EXPECTED_COUNTS):
                for table_name in EXPECTED_COUNTS:
                    cursor.execute(sql.SQL("SELECT count(*) FROM {}").format(sql.Identifier(table_name)))
                    counts[table_name] = cursor.fetchone()[0]
            cursor.execute("SELECT extname FROM pg_extension")
            extensions = {row[0] for row in cursor.fetchall()}
            cursor.execute(
                """
                SELECT indexname
                FROM pg_indexes
                WHERE schemaname = 'public'
                  AND tablename = 'operations_guide'
                """
            )
            indexes = {row[0] for row in cursor.fetchall()}

    base_schema_present = bool(tables)
    base_ready = tables == set(EXPECTED_COUNTS) and all(
        counts[table_name] >= minimum_count
        for table_name, minimum_count in EXPECTED_COUNTS.items()
    )
    ai_extensions_ready = AI_EXTENSIONS.issubset(extensions)
    ai_indexes_ready = {
        "operations_guide_bm25_idx",
        "operations_guide_embedding_diskann_idx",
    }.issubset(indexes)
    return {
        "primary": primary,
        "reader": reader,
        "base_schema_present": base_schema_present,
        "base_schema_ready": base_ready,
        "base_summary": f"tables={sorted(tables)}; counts={counts}",
        "ai_ready": ai_extensions_ready and ai_indexes_ready,
        "ai_summary": f"extensions={sorted(extensions & AI_EXTENSIONS)}; indexes={sorted(indexes)}",
        "query_stats_ready": (
            "pg_stat_statements" in extensions
            and primary["query_stats_track"] in {"top", "all"}
            and reader["query_stats_track"] in {"top", "all"}
        ),
    }


def ensure_query_stats(config: dict[str, object]) -> None:
    with psycopg.connect(connection_string(config, "primaryHost"), autocommit=True) as connection:
        with connection.cursor() as cursor:
            cursor.execute("CREATE EXTENSION IF NOT EXISTS pg_stat_statements")


def deploy(config: dict[str, object], script_path: Path) -> None:
    script = script_path.read_text(encoding="utf-8")
    with psycopg.connect(connection_string(config, "primaryHost"), autocommit=True) as connection:
        with connection.cursor() as cursor:
            cursor.execute(script, prepare=False)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("status", "deploy", "ensure-query-stats"))
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--script", type=Path)
    args = parser.parse_args()

    config = json.loads(args.config.read_text(encoding="utf-8-sig"))
    if args.action == "deploy":
        if args.script is None:
            parser.error("--script is required for deploy")
        deploy(config, args.script)
        print(json.dumps({"deployed": str(args.script)}))
        return
    if args.action == "ensure-query-stats":
        ensure_query_stats(config)
        print(json.dumps({"query_stats_ready": True}))
        return
    print(json.dumps(database_status(config)))


if __name__ == "__main__":
    main()

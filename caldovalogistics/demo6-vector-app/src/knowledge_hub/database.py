from __future__ import annotations

import os
from collections.abc import Iterator
from contextlib import contextmanager

from psycopg import Connection
from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool


def _conninfo(host: str) -> dict[str, object]:
    password = os.environ.get("KNOWLEDGE_HUB_DATABASE_PASSWORD")
    if not password:
        raise RuntimeError("KNOWLEDGE_HUB_DATABASE_PASSWORD is required.")
    return {
        "host": host,
        "port": int(os.environ.get("KNOWLEDGE_HUB_DATABASE_PORT", "5432")),
        "dbname": os.environ.get("KNOWLEDGE_HUB_DATABASE_NAME", "postgres"),
        "user": os.environ.get("KNOWLEDGE_HUB_DATABASE_USER", "knowledge_hub_app"),
        "password": password,
        "sslmode": "require",
        "connect_timeout": 10,
        "keepalives": 1,
        "keepalives_idle": 30,
        "keepalives_interval": 10,
        "keepalives_count": 3,
        "application_name": "caldova-knowledge-hub",
        "autocommit": True,
        "row_factory": dict_row,
    }


class Database:
    """Primary pool for writes and pipeline status; reader pool for search."""

    def __init__(self) -> None:
        self._primary_host = os.environ.get("KNOWLEDGE_HUB_DATABASE_HOST", "")
        self._reader_host = os.environ.get("KNOWLEDGE_HUB_READ_HOST") or self._primary_host
        self._primary: ConnectionPool | None = None
        self._reader: ConnectionPool | None = None

    def open(self) -> None:
        if not self._primary_host:
            raise RuntimeError("KNOWLEDGE_HUB_DATABASE_HOST is required.")
        self._primary = self._pool(self._primary_host, "primary")
        self._reader = (
            self._primary
            if self._reader_host == self._primary_host
            else self._pool(self._reader_host, "reader")
        )

    def close(self) -> None:
        if self._reader is not None and self._reader is not self._primary:
            self._reader.close()
        if self._primary is not None:
            self._primary.close()

    @contextmanager
    def primary(self) -> Iterator[Connection]:
        if self._primary is None:
            raise RuntimeError("Database pool is not open.")
        with self._primary.connection() as connection:
            yield connection

    @contextmanager
    def reader(self) -> Iterator[Connection]:
        if self._reader is None:
            raise RuntimeError("Database pool is not open.")
        with self._reader.connection() as connection:
            yield connection

    @staticmethod
    def _pool(host: str, name: str) -> ConnectionPool:
        # Opening without waiting lets App Service start even if the database
        # is briefly unreachable; check_connection discards stale connections.
        pool = ConnectionPool(
            kwargs=_conninfo(host),
            min_size=1,
            max_size=8,
            name=name,
            open=False,
            check=ConnectionPool.check_connection,
        )
        pool.open(wait=False)
        return pool

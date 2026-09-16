from __future__ import annotations

import os
from collections.abc import Iterator
from contextlib import contextmanager

from psycopg import Connection
from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool


class Database:
    def __init__(
        self,
        write_connection_string: str | None = None,
        read_connection_string: str | None = None,
    ) -> None:
        self._write_connection_string = write_connection_string or os.getenv("WRITE_DATABASE_URL")
        self._read_connection_string = read_connection_string or os.getenv("READ_DATABASE_URL")
        self._write_pool: ConnectionPool | None = None
        self._read_pool: ConnectionPool | None = None

    def open(self) -> None:
        if not self._write_connection_string:
            raise RuntimeError("WRITE_DATABASE_URL is required.")

        read_connection_string = self._read_connection_string or self._write_connection_string
        self._write_pool = self._create_pool(self._write_connection_string)
        self._write_pool.open(wait=True)

        if read_connection_string == self._write_connection_string:
            self._read_pool = self._write_pool
        else:
            self._read_pool = self._create_pool(read_connection_string)
            self._read_pool.open(wait=True)

    def close(self) -> None:
        if self._read_pool is not None and self._read_pool is not self._write_pool:
            self._read_pool.close()
        if self._write_pool is not None:
            self._write_pool.close()

    @contextmanager
    def write_connection(self) -> Iterator[Connection]:
        if self._write_pool is None:
            raise RuntimeError("Database pool is not open.")
        with self._write_pool.connection() as connection:
            yield connection

    @contextmanager
    def read_connection(self) -> Iterator[Connection]:
        if self._read_pool is None:
            raise RuntimeError("Database pool is not open.")
        with self._read_pool.connection() as connection:
            yield connection

    @staticmethod
    def _create_pool(connection_string: str) -> ConnectionPool:
        return ConnectionPool(
            conninfo=connection_string,
            min_size=1,
            max_size=10,
            open=False,
            kwargs={"row_factory": dict_row},
        )

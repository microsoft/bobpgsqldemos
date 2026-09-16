from __future__ import annotations

import json
import os
from collections.abc import Callable
from typing import Any, Protocol

import psycopg
from psycopg.rows import dict_row


class QueryConnection(Protocol):
    def execute(self, query: str, parameters: dict[str, Any]) -> Any: ...


ConnectionFactory = Callable[[], QueryConnection]


def connect_from_environment(host_setting: str) -> QueryConnection:
    required = (
        host_setting,
        "CALDOVA_AGENT_DATABASE_NAME",
        "CALDOVA_AGENT_DATABASE_USER",
        "CALDOVA_AGENT_DATABASE_PASSWORD",
    )
    missing = [name for name in required if not os.environ.get(name)]
    if missing:
        raise RuntimeError(f"Missing database settings: {', '.join(missing)}")
    return psycopg.connect(
        host=os.environ[host_setting],
        dbname=os.environ["CALDOVA_AGENT_DATABASE_NAME"],
        user=os.environ["CALDOVA_AGENT_DATABASE_USER"],
        password=os.environ["CALDOVA_AGENT_DATABASE_PASSWORD"],
        sslmode="require",
        connect_timeout=10,
        row_factory=dict_row,
    )


def connect_read_from_environment() -> QueryConnection:
    return connect_from_environment("CALDOVA_AGENT_DATABASE_HOST")


def connect_write_from_environment() -> QueryConnection:
    return connect_from_environment("CALDOVA_AGENT_DATABASE_WRITE_HOST")


class CaldovaTools:
    def __init__(
        self,
        connection_factory: ConnectionFactory = connect_read_from_environment,
        write_connection_factory: ConnectionFactory = connect_write_from_environment,
    ) -> None:
        self._connection_factory = connection_factory
        self._write_connection_factory = write_connection_factory

    def get_cold_chain_incident(self, tracking_number: str) -> str:
        """Return the current delayed cold-chain incident for one tracking number."""
        query = """
            SELECT tracking_number,
                   customer_name,
                   status,
                   priority,
                   cargo,
                   latest_event_type,
                   event_time,
                   latest_event_facility,
                   temperature_event_time,
                   temperature_c,
                   threshold_c,
                   temperature_facility
            FROM agent_api.incident_summary
            WHERE tracking_number = %(tracking_number)s
        """
        rows = self._fetch(query, {"tracking_number": tracking_number})
        return self._result(rows, f"No delayed incident found for {tracking_number}.")

    def find_cold_storage_facilities(self, region: str | None = None) -> str:
        """Return cold-storage facilities, optionally constrained to one region."""
        query = """
            SELECT facility_code,
                   facility_name,
                   city,
                   region,
                   cold_storage,
                   maintenance,
                   cross_dock
            FROM agent_api.candidate_facility
                WHERE %(region)s::text IS NULL
                    OR lower(region) = lower(%(region)s::text)
            ORDER BY region, facility_code
            LIMIT 20
        """
        rows = self._fetch(query, {"region": region})
        return self._result(rows, "No matching cold-storage facilities found.")

    def get_handling_guidance(self, search_text: str) -> str:
        """Return handling guides that match operator-supplied terms."""
        query = """
            SELECT guide_id,
                   title,
                   summary,
                   content,
                   category
            FROM agent_api.handling_guide
            WHERE to_tsvector('english', title || ' ' || summary || ' ' || content)
                  @@ websearch_to_tsquery('english', %(search_text)s)
            ORDER BY guide_id
            LIMIT 5
        """
        rows = self._fetch(query, {"search_text": search_text})
        return self._result(rows, "No matching handling guidance found.")

    def propose_recovery_plan(
        self,
        tracking_number: str,
        target_facility_code: str,
        guidance_id: int,
        rationale: str,
    ) -> str:
        """Create or return an idempotent recovery plan awaiting operator approval."""
        query = """
            SELECT *
            FROM agent_api.propose_recovery_plan(
                %(tracking_number)s,
                %(target_facility_code)s,
                %(guidance_id)s,
                %(rationale)s
            )
        """
        rows = self._fetch_write(
            query,
            {
                "tracking_number": tracking_number,
                "target_facility_code": target_facility_code,
                "guidance_id": guidance_id,
                "rationale": rationale,
            },
        )
        return self._result(rows, "Recovery plan could not be proposed.")

    def execute_approved_recovery_plan(
        self,
        plan_id: str,
        approval_token: str,
    ) -> str:
        """Execute one operator-approved recovery plan and return its verified state."""
        query = """
            SELECT *
            FROM agent_api.execute_approved_recovery_plan(
                %(plan_id)s::uuid,
                %(approval_token)s::uuid
            )
        """
        rows = self._fetch_write(
            query,
            {"plan_id": plan_id, "approval_token": approval_token},
        )
        return self._result(rows, "Approved recovery plan was not found.")

    def _fetch(self, query: str, parameters: dict[str, Any]) -> list[dict[str, Any]]:
        with self._connection_factory() as connection:
            return list(connection.execute(query, parameters).fetchall())

    def _fetch_write(self, query: str, parameters: dict[str, Any]) -> list[dict[str, Any]]:
        with self._write_connection_factory() as connection:
            return list(connection.execute(query, parameters).fetchall())

    @staticmethod
    def _result(rows: list[dict[str, Any]], empty_message: str) -> str:
        if not rows:
            return empty_message
        return json.dumps(rows, default=str, separators=(",", ":"))
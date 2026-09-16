from __future__ import annotations

import json
from typing import Any

from caldova_mcp.tools import CaldovaTools


class FakeResult:
    def __init__(self, rows: list[dict[str, Any]]) -> None:
        self._rows = rows

    def fetchall(self) -> list[dict[str, Any]]:
        return self._rows


class FakeConnection:
    def __init__(self, rows: list[dict[str, Any]]) -> None:
        self.rows = rows
        self.query = ""
        self.parameters: dict[str, Any] = {}

    def __enter__(self) -> FakeConnection:
        return self

    def __exit__(self, *args: object) -> None:
        return None

    def execute(self, query: str, parameters: dict[str, Any]) -> FakeResult:
        self.query = query
        self.parameters = parameters
        return FakeResult(self.rows)


def make_tools(rows: list[dict[str, Any]]) -> tuple[CaldovaTools, FakeConnection]:
    connection = FakeConnection(rows)
    return CaldovaTools(lambda: connection), connection


def make_action_tools(rows: list[dict[str, Any]]) -> tuple[CaldovaTools, FakeConnection]:
    read_connection = FakeConnection([])
    write_connection = FakeConnection(rows)
    return CaldovaTools(lambda: read_connection, lambda: write_connection), write_connection


def test_incident_tool_uses_curated_view_and_parameter() -> None:
    tools, connection = make_tools(
        [{"tracking_number": "CLD-2026-0911-001", "temperature_c": "11.4"}]
    )

    result = json.loads(tools.get_cold_chain_incident("CLD-2026-0911-001"))

    assert result[0]["temperature_c"] == "11.4"
    assert "agent_api.incident_summary" in connection.query
    assert connection.parameters == {"tracking_number": "CLD-2026-0911-001"}


def test_facility_tool_filters_with_parameter() -> None:
    tools, connection = make_tools([{"facility_code": "DEN1", "cold_storage": True}])

    result = json.loads(tools.find_cold_storage_facilities("Mountain"))

    assert result[0]["facility_code"] == "DEN1"
    assert "agent_api.candidate_facility" in connection.query
    assert "%(region)s::text" in connection.query
    assert connection.parameters == {"region": "Mountain"}


def test_guidance_tool_uses_curated_view_and_parameter() -> None:
    tools, connection = make_tools([{"guide_id": 2, "title": "Reefer equipment failure"}])

    result = json.loads(tools.get_handling_guidance("cooling equipment"))

    assert result[0]["guide_id"] == 2
    assert "agent_api.handling_guide" in connection.query
    assert connection.parameters == {"search_text": "cooling equipment"}


def test_tool_returns_explicit_message_when_no_rows_match() -> None:
    tools, _ = make_tools([])

    assert tools.get_cold_chain_incident("missing") == "No delayed incident found for missing."


def test_proposal_uses_guarded_function_on_write_connection() -> None:
    tools, connection = make_action_tools([{"plan_id": "plan-1", "status": "Proposed"}])

    result = json.loads(
        tools.propose_recovery_plan(
            "CLD-2026-0911-001",
            "DEN1",
            1,
            "11.4 C exceeds the 8 C threshold",
        )
    )

    assert result[0]["status"] == "Proposed"
    assert "agent_api.propose_recovery_plan" in connection.query
    assert connection.parameters["target_facility_code"] == "DEN1"


def test_execution_requires_plan_and_approval_token_on_write_connection() -> None:
    tools, connection = make_action_tools([{"plan_id": "plan-1", "status": "Executed"}])

    result = json.loads(tools.execute_approved_recovery_plan("plan-1", "token-1"))

    assert result[0]["status"] == "Executed"
    assert "agent_api.execute_approved_recovery_plan" in connection.query
    assert connection.parameters == {"plan_id": "plan-1", "approval_token": "token-1"}
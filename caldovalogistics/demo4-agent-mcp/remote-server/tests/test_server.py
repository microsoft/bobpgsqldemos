from __future__ import annotations

from collections.abc import Iterator

import pytest
from starlette.testclient import TestClient

from server import mcp


@pytest.fixture(scope="module")
def client() -> Iterator[TestClient]:
    with TestClient(
        mcp.streamable_http_app(), base_url="http://localhost:8000"
    ) as client:
        yield client


def test_health_route_is_ready(client: TestClient) -> None:
    response = client.get("/health")

    assert response.status_code == 200
    assert response.json() == {
        "status": "ready",
        "server": "caldova-logistics",
    }


def test_mcp_initialize_advertises_tools(client: TestClient) -> None:
    payload = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocolVersion": "2025-06-18",
            "capabilities": {},
            "clientInfo": {"name": "test", "version": "1"},
        },
    }

    response = client.post(
        "/mcp",
        json=payload,
        headers={"Accept": "application/json, text/event-stream"},
    )

    assert response.status_code == 200
    assert '"tools":{"listChanged":false}' in response.text
    assert '"name":"Caldova Logistics"' in response.text
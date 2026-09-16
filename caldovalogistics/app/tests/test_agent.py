from __future__ import annotations

from typing import Any

import pytest

from caldova_logistics.agent import AGENT_INSTRUCTIONS, CaldovaAgentService


SETTINGS = {
    "CALDOVA_HOSTED_AGENT_ENDPOINT": "https://foundry.example.test/responses",
}


class FakeToken:
    token = "entra-token"


class FakeCredential:
    def __init__(self) -> None:
        self.scope = ""
        self.closed = False

    def get_token(self, scope: str) -> FakeToken:
        self.scope = scope
        return FakeToken()

    def close(self) -> None:
        self.closed = True


class FakeResponse:
    def raise_for_status(self) -> None:
        return None

    def json(self) -> dict[str, Any]:
        return {
            "output": [
                {"content": [{"type": "output_text", "text": "Measured incident response"}]}
            ]
        }


class FakeClient:
    def __init__(self, captured: dict[str, Any], **kwargs: Any) -> None:
        captured["client"] = kwargs
        self.captured = captured

    async def __aenter__(self) -> FakeClient:
        return self

    async def __aexit__(self, *_: Any) -> None:
        return None

    async def post(self, url: str, **kwargs: Any) -> FakeResponse:
        self.captured["post"] = {"url": url, **kwargs}
        return FakeResponse()


def test_requires_all_remote_agent_settings() -> None:
    with pytest.raises(RuntimeError, match="CALDOVA_HOSTED_AGENT_ENDPOINT"):
        CaldovaAgentService(environment={})


@pytest.mark.anyio
async def test_ask_invokes_hosted_agent_with_entra_token() -> None:
    captured: dict[str, Any] = {}
    credential = FakeCredential()

    def make_client(**kwargs: Any) -> FakeClient:
        return FakeClient(captured, **kwargs)

    service = CaldovaAgentService(
        environment=SETTINGS,
        credential_factory=lambda: credential,
        client_factory=make_client,
    )

    answer = await service.ask("What should I do about CLD-2026-0911-001?")

    assert answer == "Measured incident response"
    assert credential.scope == "https://ai.azure.com/.default"
    assert credential.closed
    assert captured["client"] == {"timeout": 120.0}
    assert captured["post"] == {
        "url": "https://foundry.example.test/responses",
        "headers": {"Authorization": "Bearer entra-token"},
        "json": {
            "input": "What should I do about CLD-2026-0911-001?",
            "stream": False,
        },
    }
    assert "temperature excursion" in AGENT_INSTRUCTIONS
    assert "propose_recovery_plan" in AGENT_INSTRUCTIONS
    assert "operator approval token" in AGENT_INSTRUCTIONS


@pytest.mark.anyio
async def test_execute_approved_plan_keeps_token_out_of_response() -> None:
    captured: dict[str, Any] = {}
    service = CaldovaAgentService(
        environment=SETTINGS,
        credential_factory=FakeCredential,
        client_factory=lambda **kwargs: FakeClient(captured, **kwargs),
    )

    answer = await service.execute_approved_plan("plan-1", "approval-token-1")

    assert answer == "Measured incident response"
    prompt = captured["post"]["json"]["input"]
    assert prompt.count("execute_approved_recovery_plan") == 1
    assert "approval-token-1" in prompt
    assert "Do not include the approval token" in prompt
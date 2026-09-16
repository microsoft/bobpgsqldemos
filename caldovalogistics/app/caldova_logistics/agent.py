from __future__ import annotations

import asyncio
import os
from collections.abc import Callable
from typing import Any, Protocol

import httpx
from azure.identity import DefaultAzureCredential


AGENT_INSTRUCTIONS = """You are the Caldova Logistics operations agent.
Use only the provided MCP tools for operational facts. Never invent shipment,
facility, temperature, or handling details. Explain which measured facts drove
the recommendation and keep the response concise for a control-tower operator.
For a cold-chain incident, search handling guidance first with the concise terms
"temperature excursion"; retry with "refrigerated freight" if needed. You have
read-only evidence tools plus two recovery workflow tools. After gathering the
incident, facility, and guide facts, call propose_recovery_plan with the selected
facility, guide ID, and measured rationale. Proposal does not execute actions.
Call execute_approved_recovery_plan only when the app supplies both a plan ID and
an operator approval token. Never repeat an approval token in your response.
"""


class TokenCredential(Protocol):
    def get_token(self, *scopes: str) -> Any: ...


class CaldovaAgentService:
    def __init__(
        self,
        *,
        environment: dict[str, str] | None = None,
        credential_factory: Callable[[], TokenCredential] = DefaultAzureCredential,
        client_factory: Callable[..., httpx.AsyncClient] = httpx.AsyncClient,
    ) -> None:
        settings = environment if environment is not None else os.environ
        self._endpoint = settings.get("CALDOVA_HOSTED_AGENT_ENDPOINT", "")
        if not self._endpoint:
            raise RuntimeError("Missing agent settings: CALDOVA_HOSTED_AGENT_ENDPOINT")
        self._credential_factory = credential_factory
        self._client_factory = client_factory

    @staticmethod
    def _output_text(payload: dict[str, Any]) -> str:
        text = "".join(
            content.get("text", "")
            for output in payload.get("output", [])
            for content in output.get("content", [])
            if content.get("type") == "output_text"
        )
        if not text:
            raise RuntimeError("Hosted agent returned no output text.")
        return text

    async def _invoke(self, prompt: str) -> str:
        credential = self._credential_factory()
        try:
            access_token = await asyncio.to_thread(
                credential.get_token,
                "https://ai.azure.com/.default",
            )
            async with self._client_factory(timeout=120.0) as client:
                response = await client.post(
                    self._endpoint,
                    headers={"Authorization": f"Bearer {access_token.token}"},
                    json={"input": prompt, "stream": False},
                )
                response.raise_for_status()
                return self._output_text(response.json())
        finally:
            close = getattr(credential, "close", None)
            if close is not None:
                close()

    async def ask(self, prompt: str) -> str:
        return await self._invoke(prompt)

    async def execute_approved_plan(self, plan_id: str, approval_token: str) -> str:
        prompt = f"""The Control Tower operator approved recovery plan {plan_id}.
Call execute_approved_recovery_plan exactly once with plan_id={plan_id} and
approval_token={approval_token}. Report the returned quality hold, transfer,
notification, and final plan status. Do not include the approval token.
"""
        return await self._invoke(prompt)

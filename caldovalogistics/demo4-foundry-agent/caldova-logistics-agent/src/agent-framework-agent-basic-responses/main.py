# Copyright (c) Microsoft. All rights reserved.

import os

from agent_framework import Agent, MCPStreamableHTTPTool
from agent_framework.foundry import FoundryChatClient
from agent_framework_foundry_hosting import ResponsesHostServer
from azure.identity import DefaultAzureCredential
from dotenv import load_dotenv
from httpx import AsyncClient

# Load environment variables from .env file
load_dotenv()

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


def main():
    model_name = os.getenv("AZURE_AI_MODEL_DEPLOYMENT_NAME") or os.getenv("FOUNDRY_MODEL_NAME")
    if not model_name:
        raise RuntimeError(
            "Model deployment name is not configured. Set "
            "AZURE_AI_MODEL_DEPLOYMENT_NAME or FOUNDRY_MODEL_NAME."
        )

    client = FoundryChatClient(
        project_endpoint=os.environ["FOUNDRY_PROJECT_ENDPOINT"],
        model=model_name,
        credential=DefaultAzureCredential(),
    )

    mcp_url = os.environ.get("CALDOVA_MCP_URL")
    mcp_function_key = os.environ.get("CALDOVA_MCP_FUNCTION_KEY")
    if not mcp_url or not mcp_function_key:
        raise RuntimeError(
            "CALDOVA_MCP_URL and CALDOVA_MCP_FUNCTION_KEY are required."
        )

    mcp_tool = MCPStreamableHTTPTool(
        name="caldova-logistics",
        url=mcp_url,
        http_client=AsyncClient(
            headers={"x-functions-key": mcp_function_key},
            follow_redirects=False,
        ),
        allowed_tools={
            "get_cold_chain_incident",
            "find_cold_storage_facilities",
            "get_handling_guidance",
            "propose_recovery_plan",
            "execute_approved_recovery_plan",
        },
        approval_mode="never_require",
    )

    agent = Agent(
        client=client,
        name="CaldovaAgent",
        instructions=AGENT_INSTRUCTIONS,
        tools=[mcp_tool],
        # History will be managed by the hosting infrastructure, thus there
        # is no need to store history by the service. Learn more at:
        # https://developers.openai.com/api/reference/resources/responses/methods/create
        default_options={"store": False},
    )

    server = ResponsesHostServer(agent)
    server.run()


if __name__ == "__main__":
    main()

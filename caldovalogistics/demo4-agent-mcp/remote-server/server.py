from __future__ import annotations

import os

import uvicorn
from mcp.server.fastmcp import FastMCP
from starlette.requests import Request
from starlette.responses import JSONResponse

from caldova_mcp.tools import CaldovaTools


mcp = FastMCP("Caldova Logistics", stateless_http=True)
tools = CaldovaTools()


@mcp.tool()
def get_cold_chain_incident(tracking_number: str) -> str:
    """Get the measured status, event, and temperature facts for a delayed shipment."""
    return tools.get_cold_chain_incident(tracking_number)


@mcp.tool()
def find_cold_storage_facilities(region: str | None = None) -> str:
    """Find facilities with cold-storage capability, optionally within a region."""
    return tools.find_cold_storage_facilities(region)


@mcp.tool()
def get_handling_guidance(search_text: str) -> str:
    """Find approved cold-chain and exception-handling guidance by operational terms."""
    return tools.get_handling_guidance(search_text)


@mcp.tool()
def propose_recovery_plan(
    tracking_number: str,
    target_facility_code: str,
    guidance_id: int,
    rationale: str,
) -> str:
    """Propose a recovery plan for operator approval; this does not execute it."""
    return tools.propose_recovery_plan(
        tracking_number,
        target_facility_code,
        guidance_id,
        rationale,
    )


@mcp.tool()
def execute_approved_recovery_plan(plan_id: str, approval_token: str) -> str:
    """Execute a recovery plan only after the app supplies its operator approval token."""
    return tools.execute_approved_recovery_plan(plan_id, approval_token)


@mcp.custom_route("/health", methods=["GET"])
async def health(_: Request) -> JSONResponse:
    return JSONResponse({"status": "ready", "server": "caldova-logistics"})


if __name__ == "__main__":
    uvicorn.run(
        mcp.streamable_http_app(),
        host="0.0.0.0",
        port=int(os.environ.get("FUNCTIONS_CUSTOMHANDLER_PORT", "8000")),
    )
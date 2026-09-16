from __future__ import annotations

import json
import uuid

from caldova_mcp.tools import CaldovaTools


def main() -> None:
    tools = CaldovaTools()
    proposal = json.loads(
        tools.propose_recovery_plan(
            "CLD-2026-0911-001",
            "DEN1",
            1,
            "Measured 11.4 C exceeds the approved 8 C threshold for critical vaccine cargo.",
        )
    )[0]
    print(json.dumps({"plan_id": proposal["plan_id"], "status": proposal["status"]}))

    denied = False
    try:
        tools.execute_approved_recovery_plan(
            proposal["plan_id"],
            str(uuid.uuid4()),
        )
    except Exception as error:
        denied = "Valid operator approval is required" in str(error)

    print(json.dumps({"unapproved_execution_denied": denied}))
    if not denied:
        raise RuntimeError("Unapproved recovery execution was not denied.")


if __name__ == "__main__":
    main()

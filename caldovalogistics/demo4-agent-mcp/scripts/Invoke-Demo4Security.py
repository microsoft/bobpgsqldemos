from __future__ import annotations

import argparse
import json
import os
from pathlib import Path

import psycopg
from psycopg import sql
from psycopg.conninfo import make_conninfo


AGENT_ROLE = "caldova_agent"


def load_config(path: Path) -> dict[str, object]:
    return json.loads(path.read_text(encoding="utf-8-sig"))


def connection_string(
    config: dict[str, object],
    host_key: str,
    user: str,
    password: str,
) -> str:
    return make_conninfo(
        host=str(config[host_key]),
        port=5432,
        dbname=str(config["database"]),
        user=user,
        password=password,
        sslmode=str(config["sslMode"]),
        connect_timeout=20,
    )


def setup(config: dict[str, object], script_path: Path) -> None:
    admin_password = os.environ.get("CALDOVA_DATABASE_PASSWORD")
    agent_password = os.environ.get("CALDOVA_AGENT_PASSWORD")
    if not admin_password or not agent_password:
        raise RuntimeError("Admin and agent passwords are required in process environment.")

    with psycopg.connect(
        connection_string(config, "primaryHost", str(config["user"]), admin_password),
        autocommit=True,
    ) as connection:
        with connection.cursor() as cursor:
            cursor.execute(script_path.read_text(encoding="utf-8"), prepare=False)
            cursor.execute("SELECT 1 FROM pg_roles WHERE rolname = %s", (AGENT_ROLE,))
            if cursor.fetchone() is None:
                cursor.execute(
                    sql.SQL("CREATE ROLE {} LOGIN PASSWORD {}").format(
                        sql.Identifier(AGENT_ROLE),
                        sql.Literal(agent_password),
                    )
                )
            else:
                cursor.execute(
                    sql.SQL("ALTER ROLE {} WITH LOGIN PASSWORD {}").format(
                        sql.Identifier(AGENT_ROLE),
                        sql.Literal(agent_password),
                    )
                )
            cursor.execute(sql.SQL("GRANT CONNECT ON DATABASE {} TO {}").format(
                sql.Identifier(str(config["database"])), sql.Identifier(AGENT_ROLE)
            ))
            cursor.execute(sql.SQL("GRANT USAGE ON SCHEMA agent_api TO {}").format(sql.Identifier(AGENT_ROLE)))
            cursor.execute(sql.SQL("REVOKE ALL ON ALL TABLES IN SCHEMA agent_api FROM {}").format(sql.Identifier(AGENT_ROLE)))
            cursor.execute(sql.SQL("REVOKE ALL ON ALL FUNCTIONS IN SCHEMA agent_api FROM {}").format(sql.Identifier(AGENT_ROLE)))
            cursor.execute(sql.SQL("GRANT SELECT ON agent_api.incident_summary, agent_api.candidate_facility, agent_api.handling_guide, agent_api.recovery_plan_status TO {}").format(sql.Identifier(AGENT_ROLE)))
            cursor.execute(sql.SQL("GRANT EXECUTE ON FUNCTION agent_api.propose_recovery_plan(text, text, bigint, text) TO {}").format(sql.Identifier(AGENT_ROLE)))
            cursor.execute(sql.SQL("GRANT EXECUTE ON FUNCTION agent_api.execute_approved_recovery_plan(uuid, uuid) TO {}").format(sql.Identifier(AGENT_ROLE)))
            cursor.execute(sql.SQL("REVOKE ALL ON ALL TABLES IN SCHEMA public FROM {}").format(sql.Identifier(AGENT_ROLE)))
            cursor.execute(sql.SQL("REVOKE CREATE ON SCHEMA public FROM {}").format(sql.Identifier(AGENT_ROLE)))
            cursor.execute(
                "SELECT agent_api.reset_recovery_demo(%s)",
                ("CLD-2026-0911-001",),
            )


def expect_denied(cursor: psycopg.Cursor, statement: str) -> bool:
    try:
        cursor.execute(statement)
    except psycopg.errors.InsufficientPrivilege:
        return True
    return False


def verify(config: dict[str, object]) -> dict[str, object]:
    agent_password = os.environ.get("CALDOVA_AGENT_PASSWORD")
    if not agent_password:
        raise RuntimeError("Agent password is required in process environment.")

    with psycopg.connect(
        connection_string(config, "readerHost", AGENT_ROLE, agent_password),
        autocommit=True,
    ) as connection:
        with connection.cursor() as cursor:
            cursor.execute("SELECT count(*) FROM agent_api.incident_summary")
            incidents = cursor.fetchone()[0]
            cursor.execute("SELECT count(*) FROM agent_api.candidate_facility")
            facilities = cursor.fetchone()[0]
            cursor.execute("SELECT count(*) FROM agent_api.handling_guide")
            guides = cursor.fetchone()[0]
            cursor.execute("SELECT count(*) FROM agent_api.recovery_plan_status")
            recovery_plans = cursor.fetchone()[0]
            direct_read_denied = expect_denied(cursor, "SELECT count(*) FROM public.shipment")

    with psycopg.connect(
        connection_string(config, "primaryHost", AGENT_ROLE, agent_password),
        autocommit=True,
    ) as connection:
        with connection.cursor() as cursor:
            direct_write_denied = expect_denied(
                cursor,
                "UPDATE public.shipment SET status = status WHERE false",
            )
            cursor.execute(
                "SELECT has_function_privilege(current_user, %s, 'EXECUTE')",
                ("agent_api.propose_recovery_plan(text,text,bigint,text)",),
            )
            can_propose = cursor.fetchone()[0]
            cursor.execute(
                "SELECT has_function_privilege(current_user, %s, 'EXECUTE')",
                ("agent_api.execute_approved_recovery_plan(uuid,uuid)",),
            )
            can_execute = cursor.fetchone()[0]
            cursor.execute(
                "SELECT has_function_privilege(current_user, %s, 'EXECUTE')",
                ("agent_api.approve_recovery_plan(uuid,text)",),
            )
            can_approve = cursor.fetchone()[0]

    result = {
        "agent_role": AGENT_ROLE,
        "incident_rows": incidents,
        "candidate_facilities": facilities,
        "handling_guides": guides,
        "recovery_plans": recovery_plans,
        "direct_table_read_denied": direct_read_denied,
        "direct_table_write_denied": direct_write_denied,
        "can_propose": can_propose,
        "can_execute": can_execute,
        "can_approve": can_approve,
    }
    result["ready"] = (
        incidents >= 1
        and facilities >= 1
        and guides >= 1
        and direct_read_denied
        and direct_write_denied
        and can_propose
        and can_execute
        and not can_approve
    )
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("setup", "verify"))
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--script", type=Path)
    args = parser.parse_args()
    config = load_config(args.config)
    if args.action == "setup":
        if args.script is None:
            parser.error("--script is required for setup")
        setup(config, args.script)
        print(json.dumps({"configured": AGENT_ROLE}))
        return
    print(json.dumps(verify(config)))


if __name__ == "__main__":
    main()

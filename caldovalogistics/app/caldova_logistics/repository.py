from __future__ import annotations

from typing import Any
from uuid import UUID

from caldova_logistics.database import Database
from caldova_logistics.models import ConnectionPath, GuideResult, IncidentBriefing, RecoveryPlan, Shipment


class LogisticsRepository:
    def __init__(self, database: Database) -> None:
        self._database = database

    def list_shipments(self) -> list[Shipment]:
        sql = """
            SELECT shipment.shipment_id,
                   shipment.tracking_number,
                   shipment.customer_name,
                   origin.facility_code AS origin_code,
                   destination.facility_code AS destination_code,
                   shipment.status,
                   shipment.priority,
                   shipment.cargo_profile,
                   shipment.created_at,
                   latest.event_type AS latest_event_type,
                   latest.event_time AS latest_event_time
            FROM shipment
            JOIN facility origin
              ON origin.facility_id = shipment.origin_facility_id
            JOIN facility destination
              ON destination.facility_id = shipment.destination_facility_id
            LEFT JOIN LATERAL (
                SELECT shipment_event.event_type,
                       shipment_event.event_time
                FROM shipment_event
                WHERE shipment_event.shipment_id = shipment.shipment_id
                ORDER BY shipment_event.event_time DESC
                LIMIT 1
            ) latest ON true
            ORDER BY shipment.created_at DESC
            LIMIT 30
        """
        with self._database.read_connection() as connection:
            rows = connection.execute(sql).fetchall()
        return [Shipment(**row) for row in rows]

    def list_connection_paths(self) -> list[ConnectionPath]:
        sql = """
            SELECT inet_server_addr()::text AS server_address,
                   pg_backend_pid() AS backend_pid
        """
        paths = []
        for name, purpose, connection_factory in (
            ("Primary", "Writes and immediate reads", self._database.write_connection),
            ("Reader", "Active shipments and guidance search", self._database.read_connection),
        ):
            with connection_factory() as connection:
                row = connection.execute(sql).fetchone()
            paths.append(ConnectionPath(name=name, purpose=purpose, **row))
        return paths

    def create_shipment(
        self,
        tracking_number: str,
        customer_name: str,
        origin_code: str,
        destination_code: str,
        priority: str,
        cargo_name: str,
    ) -> Shipment:
        sql = """
            INSERT INTO shipment (
                tracking_number,
                customer_name,
                origin_facility_id,
                destination_facility_id,
                priority,
                cargo_profile
            )
            SELECT %(tracking_number)s,
                   %(customer_name)s,
                   origin.facility_id,
                   destination.facility_id,
                   %(priority)s,
                   jsonb_build_object('cargo', %(cargo_name)s)
            FROM facility origin, facility destination
            WHERE origin.facility_code = %(origin_code)s
              AND destination.facility_code = %(destination_code)s
                        ON CONFLICT (tracking_number) DO UPDATE
                        SET customer_name = EXCLUDED.customer_name,
                                origin_facility_id = EXCLUDED.origin_facility_id,
                                destination_facility_id = EXCLUDED.destination_facility_id,
                                priority = EXCLUDED.priority,
                                cargo_profile = EXCLUDED.cargo_profile
            RETURNING shipment_id,
                      tracking_number,
                      customer_name,
                      %(origin_code)s AS origin_code,
                      %(destination_code)s AS destination_code,
                      status,
                      priority,
                      cargo_profile,
                      created_at,
                      NULL::text AS latest_event_type,
                      NULL::timestamptz AS latest_event_time
        """
        parameters = {
            "tracking_number": tracking_number,
            "customer_name": customer_name,
            "origin_code": origin_code,
            "destination_code": destination_code,
            "priority": priority,
            "cargo_name": cargo_name,
        }
        with self._database.write_connection() as connection:
            row = connection.execute(sql, parameters).fetchone()
        if row is None:
            raise ValueError("Origin or destination facility code was not found.")
        return Shipment(**row)

    def search_guides(self, query: str, mode: str = "keyword") -> list[GuideResult]:
        if mode == "hybrid":
            return self._hybrid_search(query)
        return self._keyword_search(query)

    def generate_incident_briefing(self, query: str) -> IncidentBriefing:
        evidence = self._hybrid_search(query)[:3]
        if not evidence:
            raise ValueError("No operations-guide evidence was found for this incident.")

        evidence_text = "\n".join(
            f"[Guide {guide.guide_id}] {guide.title}: {guide.summary}" for guide in evidence
        )
        sql = """
            SELECT azure_ai.generate(
                prompt =>
                    'Write a concise logistics incident briefing. Use only the evidence below. ' ||
                    'Cite each recommendation as [Guide <id>]. Incident: shipment ' ||
                    'CLD-2026-0911-001 reported 11.4 C against an 8 C maximum at DEN1.' ||
                    E'\n\nEvidence:\n' || %(evidence)s,
                system_prompt =>
                    'You assist logistics operators. Do not invent shipment facts or procedures.'
            ) AS briefing
        """
        with self._database.read_connection() as connection:
            row = connection.execute(sql, {"evidence": evidence_text}).fetchone()
        if row is None or not row["briefing"]:
            raise RuntimeError("HorizonDB did not return an incident briefing.")
        return IncidentBriefing(text=row["briefing"], evidence=evidence)

    def get_recovery_plan(
        self,
        *,
        tracking_number: str | None = None,
        plan_id: UUID | None = None,
    ) -> RecoveryPlan | None:
        if tracking_number is None and plan_id is None:
            raise ValueError("A tracking number or plan ID is required.")

        sql = """
            SELECT plan_id,
                   tracking_number,
                   target_facility_code,
                   target_facility_name,
                   guidance_id,
                   guidance_title,
                   rationale,
                   status,
                   proposed_at,
                   approved_at,
                   approved_by,
                   executed_at,
                   execution_result,
                   transfer_status,
                   notification_status
            FROM agent_api.recovery_plan_status
            WHERE (%(plan_id)s::uuid IS NULL OR plan_id = %(plan_id)s::uuid)
              AND (%(tracking_number)s::text IS NULL OR tracking_number = %(tracking_number)s::text)
            ORDER BY proposed_at DESC
            LIMIT 1
        """
        with self._database.write_connection() as connection:
            row = connection.execute(
                sql,
                {
                    "plan_id": str(plan_id) if plan_id else None,
                    "tracking_number": tracking_number,
                },
            ).fetchone()
        return RecoveryPlan(**row) if row else None

    def approve_recovery_plan(
        self,
        plan_id: UUID,
        approved_by: str,
    ) -> tuple[RecoveryPlan, str]:
        sql = """
            SELECT plan_id, approval_token
            FROM agent_api.approve_recovery_plan(%(plan_id)s::uuid, %(approved_by)s)
        """
        with self._database.write_connection() as connection:
            approval = connection.execute(
                sql,
                {"plan_id": str(plan_id), "approved_by": approved_by},
            ).fetchone()
        if approval is None or approval["approval_token"] is None:
            raise RuntimeError("HorizonDB did not approve the recovery plan.")

        plan = self.get_recovery_plan(plan_id=plan_id)
        if plan is None:
            raise RuntimeError("Approved recovery plan could not be reloaded.")
        return plan, str(approval["approval_token"])

    def reset_recovery_demo(self, tracking_number: str) -> None:
        with self._database.write_connection() as connection:
            connection.execute(
                "SELECT agent_api.reset_recovery_demo(%(tracking_number)s)",
                {"tracking_number": tracking_number},
            )

    def _keyword_search(self, query: str) -> list[GuideResult]:
        sql = """
            SELECT guide_id,
                   title,
                   summary,
                   category,
                   ts_rank(
                       search_document,
                       websearch_to_tsquery('english', %(query)s)
                   )::float AS score
            FROM operations_guide
            WHERE search_document @@ websearch_to_tsquery('english', %(query)s)
            ORDER BY score DESC
            LIMIT 8
        """
        with self._database.read_connection() as connection:
            rows = connection.execute(sql, {"query": query}).fetchall()
        return [GuideResult(**row) for row in rows]

    def _hybrid_search(self, query: str) -> list[GuideResult]:
        sql = """
            WITH query AS (
                SELECT %(query)s::text AS query_text,
                       azure_openai.create_embeddings(input => %(query)s)::vector AS query_vector
            ),
            keyword_results AS (
                SELECT guide.guide_id,
                       row_number() OVER (
                           ORDER BY guide.content <@> to_bm25query(
                               query.query_text,
                               'operations_guide_bm25_idx'
                           )
                       ) AS keyword_rank
                FROM operations_guide guide, query
                ORDER BY guide.content <@> to_bm25query(
                    query.query_text,
                    'operations_guide_bm25_idx'
                )
                LIMIT 30
            ),
            vector_results AS (
                SELECT guide.guide_id,
                       row_number() OVER (
                           ORDER BY guide.embedding <=> query.query_vector
                       ) AS vector_rank
                FROM operations_guide guide, query
                ORDER BY guide.embedding <=> query.query_vector
                LIMIT 30
            )
            SELECT guide.guide_id,
                   guide.title,
                   guide.summary,
                   guide.category,
                   ((1.0 / (60 + coalesce(keyword_results.keyword_rank, 1000))) +
                    (1.0 / (60 + coalesce(vector_results.vector_rank, 1000))))::float AS score
            FROM operations_guide guide
            LEFT JOIN keyword_results ON keyword_results.guide_id = guide.guide_id
            LEFT JOIN vector_results ON vector_results.guide_id = guide.guide_id
            WHERE keyword_results.guide_id IS NOT NULL
               OR vector_results.guide_id IS NOT NULL
            ORDER BY score DESC
            LIMIT 8
        """
        with self._database.read_connection() as connection:
            rows = connection.execute(sql, {"query": query}).fetchall()
        return [GuideResult(**row) for row in rows]

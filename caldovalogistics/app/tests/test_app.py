from dataclasses import replace
from datetime import UTC, datetime
from uuid import UUID

import pytest
from fastapi.testclient import TestClient

from caldova_logistics.main import create_app
from caldova_logistics.models import ConnectionPath, GuideResult, IncidentBriefing, RecoveryPlan, Shipment


class FakeRepository:
    def __init__(self) -> None:
        self.recovery_plan: RecoveryPlan | None = None
        self.approved_plan_id: UUID | None = None
        self.reset_tracking_number = ""
        self.shipments = [
            Shipment(
                shipment_id=1,
                tracking_number="CLD-2026-0911-001",
                customer_name="Fabrikam Foods",
                origin_code="SEA1",
                destination_code="BOS1",
                status="Delayed",
                priority="Critical",
                cargo_profile={"cargo": "vaccines"},
                created_at=datetime(2026, 9, 11, 12, 0, tzinfo=UTC),
                latest_event_type="TemperatureAlert",
                latest_event_time=datetime(2026, 9, 11, 12, 10, tzinfo=UTC),
            )
        ]

    def list_shipments(self) -> list[Shipment]:
        return self.shipments

    def list_connection_paths(self) -> list[ConnectionPath]:
        return [
            ConnectionPath(
                name="Primary",
                purpose="Writes and immediate reads",
                server_address="10.0.0.4",
                backend_pid=4101,
            ),
            ConnectionPath(
                name="Reader",
                purpose="Dashboards and retrieval",
                server_address="10.0.0.5",
                backend_pid=5202,
            ),
        ]

    def create_shipment(
        self,
        tracking_number: str,
        customer_name: str,
        origin_code: str,
        destination_code: str,
        priority: str,
        cargo_name: str,
    ) -> Shipment:
        shipment = Shipment(
            shipment_id=next(
                (
                    existing.shipment_id
                    for existing in self.shipments
                    if existing.tracking_number == tracking_number
                ),
                len(self.shipments) + 1,
            ),
            tracking_number=tracking_number,
            customer_name=customer_name,
            origin_code=origin_code,
            destination_code=destination_code,
            status="Booked",
            priority=priority,
            cargo_profile={"cargo": cargo_name},
            created_at=datetime.now(UTC),
        )
        self.shipments = [
            existing
            for existing in self.shipments
            if existing.tracking_number != tracking_number
        ]
        self.shipments.insert(0, shipment)
        return shipment

    def search_guides(self, query: str, mode: str = "keyword") -> list[GuideResult]:
        return [
            GuideResult(
                guide_id=2,
                title="Reefer equipment failure",
                summary=f"{mode} result for {query}",
                category="Cold Chain",
                score=0.814,
            )
        ]

    def generate_incident_briefing(self, query: str) -> IncidentBriefing:
        evidence = self.search_guides(query, "hybrid")
        return IncidentBriefing(
            text="Move the shipment to validated cold storage [Guide 2].",
            evidence=evidence,
        )

    def get_recovery_plan(
        self,
        *,
        tracking_number: str | None = None,
        plan_id: UUID | None = None,
    ) -> RecoveryPlan | None:
        if self.recovery_plan is None:
            return None
        if plan_id is not None and self.recovery_plan.plan_id != plan_id:
            return None
        if tracking_number is not None and self.recovery_plan.tracking_number != tracking_number:
            return None
        return self.recovery_plan

    def approve_recovery_plan(
        self,
        plan_id: UUID,
        approved_by: str,
    ) -> tuple[RecoveryPlan, str]:
        if self.recovery_plan is None or self.recovery_plan.plan_id != plan_id:
            raise RuntimeError("Recovery plan was not found.")
        self.approved_plan_id = plan_id
        self.recovery_plan = replace(
            self.recovery_plan,
            status="Approved",
            approved_at=datetime.now(UTC),
            approved_by=approved_by,
        )
        return self.recovery_plan, "server-side-approval-token"

    def set_recovery_plan(self, status: str = "Proposed") -> RecoveryPlan:
        self.recovery_plan = RecoveryPlan(
            plan_id=UUID("85a38993-15dd-4aed-9de5-802d0bb641de"),
            tracking_number="CLD-2026-0911-001",
            target_facility_code="DEN1",
            target_facility_name="Rocky Mountain Hub",
            guidance_id=1,
            guidance_title="Temperature excursion response for refrigerated freight",
            rationale="11.4 C exceeds the approved 8 C threshold for critical vaccine cargo.",
            status=status,
            proposed_at=datetime(2026, 9, 14, 12, 0, tzinfo=UTC),
            approved_at=None,
            approved_by=None,
            executed_at=None,
            execution_result=None,
            transfer_status=None,
            notification_status=None,
        )
        return self.recovery_plan

    def reset_recovery_demo(self, tracking_number: str) -> None:
        self.reset_tracking_number = tracking_number
        self.recovery_plan = None


class FakeAgentService:
    def __init__(self, repository: FakeRepository | None = None) -> None:
        self.repository = repository
        self.executed_plan_id = ""
        self.received_token = ""

    async def ask(self, prompt: str) -> str:
        if self.repository is not None:
            self.repository.set_recovery_plan()
        return (
            f"Measured response for {prompt}: 11.4 C exceeds the 8 C maximum. "
            "Move the shipment to validated cold storage at DEN1."
        )

    async def execute_approved_plan(self, plan_id: str, approval_token: str) -> str:
        self.executed_plan_id = plan_id
        self.received_token = approval_token
        if self.repository is not None and self.repository.recovery_plan is not None:
            self.repository.recovery_plan = replace(
                self.repository.recovery_plan,
                status="Executed",
                executed_at=datetime.now(UTC),
                execution_result={"quality_hold": "Placed"},
                transfer_status="Ready",
                notification_status="Queued",
            )
        return "Recovery verified: quality hold placed, transfer ready, notification queued."


class FailingAgentService:
    async def ask(self, prompt: str) -> str:
        raise ValueError("provider details must not reach the browser")


def test_home_lists_shipments() -> None:
    with TestClient(create_app(FakeRepository())) as client:
        response = client.get("/")

    assert response.status_code == 200
    assert "CLD-2026-0911-001" in response.text
    assert "Fabrikam Foods" in response.text
    assert "TemperatureAlert" in response.text
    assert "Cold-chain exception at DEN1" in response.text
    assert "Investigate &amp; propose" in response.text
    assert "Ask agent" in response.text
    assert "Investigating shipment and approved guidance" in response.text
    assert "10.0.0.4" not in response.text
    assert "PID 4101" not in response.text
    assert 'endpoint-badge endpoint-primary">Primary' in response.text
    assert 'endpoint-badge endpoint-reader">Reader' in response.text


def test_hybrid_search_displays_results() -> None:
    with TestClient(create_app(FakeRepository())) as client:
        response = client.get(
            "/",
            params={"q": "cooling equipment stopped", "mode": "hybrid"},
        )

    assert response.status_code == 200
    assert "Reefer equipment failure" in response.text
    assert "matches via hybrid" in response.text
    assert "score 0.8140" in response.text


def test_create_shipment_redirects_and_persists() -> None:
    repository = FakeRepository()
    with TestClient(create_app(repository)) as client:
        response = client.post(
            "/shipments",
            data={
                "tracking_number": "CLD-2026-DEMO-004",
                "customer_name": "Contoso Outdoor",
                "origin_code": "sea1",
                "destination_code": "atl1",
                "priority": "Expedited",
                "cargo_name": "Navigation devices",
            },
            follow_redirects=False,
        )

    assert response.status_code == 303
    assert response.headers["location"] == "/"
    assert repository.shipments[0].origin_code == "SEA1"
    assert repository.shipments[0].cargo_profile["cargo"] == "Navigation devices"


def test_create_shipment_can_be_rehearsed_with_same_tracking_number() -> None:
    repository = FakeRepository()
    with TestClient(create_app(repository)) as client:
        form = {
            "tracking_number": "CLD-2026-DEMO-003",
            "customer_name": "Contoso Outdoor",
            "origin_code": "SEA1",
            "destination_code": "ATL1",
            "priority": "Expedited",
            "cargo_name": "Navigation devices",
        }
        first_response = client.post("/shipments", data=form, follow_redirects=False)
        second_response = client.post("/shipments", data=form, follow_redirects=False)

    assert first_response.status_code == 303
    assert second_response.status_code == 303
    assert sum(
        shipment.tracking_number == form["tracking_number"]
        for shipment in repository.shipments
    ) == 1


def test_generate_briefing_displays_cited_response_and_evidence() -> None:
    with TestClient(create_app(FakeRepository())) as client:
        response = client.post(
            "/briefings",
            data={"query": "cooling equipment stopped keeping cargo cold"},
        )

    assert response.status_code == 200
    assert "Incident briefing" in response.text
    assert "Move the shipment to validated cold storage [Guide 2]." in response.text
    assert "3 cited guides" not in response.text
    assert "1 cited guides" in response.text


def test_health() -> None:
    with TestClient(create_app(FakeRepository())) as client:
        response = client.get("/health")

    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_agent_displays_grounded_response() -> None:
    repository = FakeRepository()
    app = create_app(repository, FakeAgentService(repository))
    with TestClient(app) as client:
        response = client.post(
            "/agent",
            data={"question": "What happened to CLD-2026-0911-001?"},
        )

    assert response.status_code == 200
    assert "Agent response" in response.text
    assert "11.4 C exceeds the 8 C maximum" in response.text
    assert "validated cold storage at DEN1" in response.text
    assert "Recovery plan" in response.text
    assert "Approve &amp; execute" in response.text
    assert "server-side-approval-token" not in response.text


def test_investigate_action_submits_locked_goal_and_creates_proposal() -> None:
    repository = FakeRepository()
    agent = FakeAgentService(repository)
    app = create_app(repository, agent)

    with TestClient(app) as client:
        response = client.post(
            "/agent",
            data={
                "question": (
                    "Investigate shipment CLD-2026-0911-001. Explain the cold-chain "
                    "incident using measured facts, find a capable facility, and "
                    "recommend the approved handling response."
                )
            },
        )

    assert response.status_code == 200
    assert "Recovery plan awaiting approval" in response.text
    assert "Approve &amp; execute" in response.text
    assert "Investigate &amp; propose" not in response.text
    assert "Ask agent" in response.text


def test_agent_reports_missing_configuration_without_breaking_app(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    for name in (
        "CALDOVA_FOUNDRY_ENDPOINT",
        "CALDOVA_FOUNDRY_API_KEY",
        "CALDOVA_MCP_URL",
        "CALDOVA_MCP_FUNCTION_KEY",
    ):
        monkeypatch.delenv(name, raising=False)

    with TestClient(create_app(FakeRepository())) as client:
        response = client.post(
            "/agent",
            data={"question": "What happened to CLD-2026-0911-001?"},
        )

    assert response.status_code == 200
    assert "Missing agent settings" in response.text


def test_agent_reports_provider_failure_without_http_500() -> None:
    app = create_app(FakeRepository(), FailingAgentService())
    with TestClient(app) as client:
        response = client.post(
            "/agent",
            data={"question": "What happened to CLD-2026-0911-001?"},
        )

    assert response.status_code == 200
    assert "temporarily unavailable" in response.text
    assert "provider details" not in response.text


def test_operator_approval_executes_plan_and_renders_verified_state() -> None:
    repository = FakeRepository()
    plan = repository.set_recovery_plan()
    agent = FakeAgentService(repository)
    app = create_app(repository, agent)

    with TestClient(app) as client:
        response = client.post(f"/agent/plans/{plan.plan_id}/approve")

    assert response.status_code == 200
    assert repository.approved_plan_id == plan.plan_id
    assert agent.executed_plan_id == str(plan.plan_id)
    assert agent.received_token == "server-side-approval-token"
    assert "Recovery executed" in response.text
    assert "Transfer Ready" in response.text
    assert "Notification Queued" in response.text
    assert "server-side-approval-token" not in response.text


def test_approved_plan_can_be_retried_safely() -> None:
    repository = FakeRepository()
    plan = repository.set_recovery_plan("Approved")
    agent = FakeAgentService(repository)

    with TestClient(create_app(repository, agent)) as client:
        response = client.post(f"/agent/plans/{plan.plan_id}/approve")

    assert response.status_code == 200
    assert repository.recovery_plan is not None
    assert repository.recovery_plan.status == "Executed"


def test_reset_demo_clears_recovery_plan_and_redirects() -> None:
    repository = FakeRepository()
    repository.set_recovery_plan("Executed")

    with TestClient(create_app(repository, FakeAgentService(repository))) as client:
        response = client.post("/agent/reset", follow_redirects=False)

    assert response.status_code == 303
    assert response.headers["location"] == "/"
    assert repository.reset_tracking_number == "CLD-2026-0911-001"
    assert repository.recovery_plan is None


def test_top_banner_shows_proposed_recovery_without_changing_shipment_status() -> None:
    repository = FakeRepository()
    repository.set_recovery_plan("Proposed")

    with TestClient(create_app(repository, FakeAgentService(repository))) as client:
        response = client.get("/")

    assert "Recovery plan awaiting approval" in response.text
    assert "DEN1 cold storage" in response.text
    assert "Proposed" in response.text
    assert ">Delayed<" in response.text


def test_top_banner_shows_executed_recovery_and_preserves_transport_status() -> None:
    repository = FakeRepository()
    plan = repository.set_recovery_plan("Executed")
    repository.recovery_plan = replace(
        plan,
        execution_result={"quality_hold": "Placed"},
        transfer_status="Ready",
        notification_status="Queued",
    )

    with TestClient(create_app(repository, FakeAgentService(repository))) as client:
        response = client.get("/")

    assert "Quality hold placed at DEN1" in response.text
    assert "Shipment remains Delayed" in response.text
    assert "Transfer Ready" in response.text
    assert "Notification Queued" in response.text
    assert ">Executed<" in response.text
    assert ">Delayed<" in response.text
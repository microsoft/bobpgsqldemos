from __future__ import annotations

import logging
import re
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Protocol
from uuid import UUID

from fastapi import FastAPI, Form, Request
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

from caldova_logistics.agent import CaldovaAgentService
from caldova_logistics.database import Database
from caldova_logistics.models import ConnectionPath, GuideResult, IncidentBriefing, RecoveryPlan, Shipment
from caldova_logistics.repository import LogisticsRepository


class Repository(Protocol):
    def list_connection_paths(self) -> list[ConnectionPath]: ...

    def list_shipments(self) -> list[Shipment]: ...

    def create_shipment(
        self,
        tracking_number: str,
        customer_name: str,
        origin_code: str,
        destination_code: str,
        priority: str,
        cargo_name: str,
    ) -> Shipment: ...

    def search_guides(self, query: str, mode: str = "keyword") -> list[GuideResult]: ...

    def generate_incident_briefing(self, query: str) -> IncidentBriefing: ...

    def get_recovery_plan(
        self,
        *,
        tracking_number: str | None = None,
        plan_id: UUID | None = None,
    ) -> RecoveryPlan | None: ...

    def approve_recovery_plan(
        self,
        plan_id: UUID,
        approved_by: str,
    ) -> tuple[RecoveryPlan, str]: ...

    def reset_recovery_demo(self, tracking_number: str) -> None: ...


class AgentService(Protocol):
    async def ask(self, prompt: str) -> str: ...

    async def execute_approved_plan(self, plan_id: str, approval_token: str) -> str: ...


PACKAGE_ROOT = Path(__file__).parent
templates = Jinja2Templates(directory=PACKAGE_ROOT / "templates")
logger = logging.getLogger(__name__)
tracking_pattern = re.compile(r"\bCLD-[A-Z0-9-]+\b", re.IGNORECASE)


def create_app(
    repository: Repository | None = None,
    agent_service: AgentService | None = None,
) -> FastAPI:
    database = Database() if repository is None else None

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        if database is not None:
            database.open()
            app.state.repository = LogisticsRepository(database)
        else:
            app.state.repository = repository
        yield
        if database is not None:
            database.close()

    app = FastAPI(title="Caldova Control Tower", lifespan=lifespan)
    app.mount("/static", StaticFiles(directory=PACKAGE_ROOT / "static"), name="static")

    def render_home(
        request: Request,
        *,
        query: str = "",
        mode: str = "keyword",
        results: list[GuideResult] | None = None,
        briefing: IncidentBriefing | None = None,
        agent_question: str = "",
        agent_answer: str = "",
        agent_error: str = "",
        recovery_plan: RecoveryPlan | None = None,
    ) -> HTMLResponse:
        current_repository: Repository = request.app.state.repository
        visible_plan = recovery_plan or current_repository.get_recovery_plan(
            tracking_number="CLD-2026-0911-001"
        )
        return templates.TemplateResponse(
            request=request,
            name="index.html",
            context={
                "shipments": current_repository.list_shipments(),
                "connection_paths": current_repository.list_connection_paths(),
                "query": query,
                "mode": mode,
                "results": results or [],
                "briefing": briefing,
                "agent_question": agent_question,
                "agent_answer": agent_answer,
                "agent_error": agent_error,
                "recovery_plan": visible_plan,
            },
        )

    @app.get("/", response_class=HTMLResponse)
    def home(request: Request, q: str = "", mode: str = "keyword") -> HTMLResponse:
        search_mode = mode if mode in {"keyword", "hybrid"} else "keyword"
        current_repository: Repository = request.app.state.repository
        results = current_repository.search_guides(q, search_mode) if q.strip() else []
        return render_home(request, query=q, mode=search_mode, results=results)

    @app.post("/briefings", response_class=HTMLResponse)
    def create_briefing(request: Request, query: str = Form(min_length=3, max_length=500)) -> HTMLResponse:
        current_repository: Repository = request.app.state.repository
        briefing = current_repository.generate_incident_briefing(query)
        return render_home(
            request,
            query=query,
            mode="hybrid",
            results=briefing.evidence,
            briefing=briefing,
        )

    @app.post("/agent", response_class=HTMLResponse)
    async def ask_agent(
        request: Request,
        question: str = Form(min_length=3, max_length=1000),
    ) -> HTMLResponse:
        try:
            service = agent_service or CaldovaAgentService()
            answer = await service.ask(question)
            tracking_match = tracking_pattern.search(question)
            recovery_plan = (
                request.app.state.repository.get_recovery_plan(
                    tracking_number=tracking_match.group(0).upper()
                )
                if tracking_match
                else None
            )
            return render_home(
                request,
                agent_question=question,
                agent_answer=answer,
                recovery_plan=recovery_plan,
            )
        except Exception as error:
            logger.exception("Caldova agent request failed")
            message = (
                str(error)
                if isinstance(error, RuntimeError)
                else "The agent service is temporarily unavailable. Please try again shortly."
            )
            return render_home(
                request,
                agent_question=question,
                agent_error=message,
            )

    @app.post("/agent/plans/{plan_id}/approve", response_class=HTMLResponse)
    async def approve_agent_plan(request: Request, plan_id: UUID) -> HTMLResponse:
        current_repository: Repository = request.app.state.repository
        recovery_plan: RecoveryPlan | None = None
        try:
            recovery_plan, approval_token = current_repository.approve_recovery_plan(
                plan_id,
                "Control Tower Operator",
            )
            service = agent_service or CaldovaAgentService()
            answer = await service.execute_approved_plan(
                str(plan_id),
                approval_token,
            )
            recovery_plan = current_repository.get_recovery_plan(plan_id=plan_id)
            return render_home(
                request,
                agent_answer=answer,
                recovery_plan=recovery_plan,
            )
        except Exception as error:
            logger.exception("Caldova recovery execution failed")
            return render_home(
                request,
                agent_error="Recovery execution did not complete. The approved plan can be retried safely.",
                recovery_plan=recovery_plan,
            )

    @app.post("/agent/reset")
    def reset_agent_demo(request: Request) -> RedirectResponse:
        current_repository: Repository = request.app.state.repository
        current_repository.reset_recovery_demo("CLD-2026-0911-001")
        return RedirectResponse(url="/", status_code=303)

    @app.post("/shipments")
    def create_shipment(
        request: Request,
        tracking_number: str = Form(min_length=6, max_length=40),
        customer_name: str = Form(min_length=2, max_length=120),
        origin_code: str = Form(min_length=3, max_length=10),
        destination_code: str = Form(min_length=3, max_length=10),
        priority: str = Form(pattern="^(Standard|Expedited|Critical)$"),
        cargo_name: str = Form(min_length=2, max_length=120),
    ) -> RedirectResponse:
        current_repository: Repository = request.app.state.repository
        current_repository.create_shipment(
            tracking_number,
            customer_name,
            origin_code.upper(),
            destination_code.upper(),
            priority,
            cargo_name,
        )
        return RedirectResponse(url="/", status_code=303)

    @app.get("/health")
    def health() -> dict[str, str]:
        return {"status": "ok"}

    return app


app = create_app()

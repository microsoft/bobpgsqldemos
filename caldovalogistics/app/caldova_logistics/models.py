from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import Any
from uuid import UUID


@dataclass(frozen=True)
class Shipment:
    shipment_id: int
    tracking_number: str
    customer_name: str
    origin_code: str
    destination_code: str
    status: str
    priority: str
    cargo_profile: dict[str, Any]
    created_at: datetime
    latest_event_type: str | None = None
    latest_event_time: datetime | None = None


@dataclass(frozen=True)
class GuideResult:
    guide_id: int
    title: str
    summary: str
    category: str
    score: float


@dataclass(frozen=True)
class IncidentBriefing:
    text: str
    evidence: list[GuideResult]


@dataclass(frozen=True)
class ConnectionPath:
    name: str
    purpose: str
    server_address: str
    backend_pid: int


@dataclass(frozen=True)
class RecoveryPlan:
    plan_id: UUID
    tracking_number: str
    target_facility_code: str
    target_facility_name: str
    guidance_id: int
    guidance_title: str
    rationale: str
    status: str
    proposed_at: datetime
    approved_at: datetime | None
    approved_by: str | None
    executed_at: datetime | None
    execution_result: dict[str, Any] | None
    transfer_status: str | None
    notification_status: str | None

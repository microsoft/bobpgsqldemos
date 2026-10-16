"""Turn live HorizonDB pipeline metadata into the code view and stage timeline."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import Any

STAGES: tuple[dict[str, str], ...] = (
    {"key": "trigger", "title": "on_change trigger", "detail": "INSERT/UPDATE starts a run"},
    {"key": "source", "title": "Changed rows", "detail": "rows with updated_at > checkpoint"},
    {"key": "chunk", "title": "Chunk", "detail": "azure_ai.chunk"},
    {"key": "embed", "title": "Embed", "detail": "Microsoft Foundry"},
    {"key": "sink", "title": "Upsert vectors", "detail": "chunk_embedding"},
    {"key": "checkpoint", "title": "Checkpoint", "detail": "durable run complete"},
    {"key": "index", "title": "DiskANN", "detail": "searchable"},
)

# Mirrors sql/03-durable-reconciler.sql; tests keep the two in sync.
RECONCILER_SQL = """SELECT df.start(
    df.loop(
        df.seq(
            df.sleep(10),
            'SELECT knowledge_hub.reconcile()'
        ),
        'SELECT clock_timestamp() < <started + 12 hours>'
    ),
    'knowledge-hub-reconciler'
);"""


@dataclass(frozen=True)
class CodeLine:
    number: int
    text: str
    stage: str | None


def _literal(value: object) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return str(value)
    return "'" + str(value).replace("'", "''") + "'"


def _call(name: str, arguments: list[tuple[str, object]], indent: str) -> list[str]:
    lines = [f"{name}("]
    for position, (key, value) in enumerate(arguments):
        rendered = (
            "ARRAY[" + ", ".join(_literal(item) for item in value) + "]"
            if isinstance(value, list)
            else _literal(value)
        )
        suffix = "," if position < len(arguments) - 1 else ""
        lines.append(f"{indent}    {key} => {rendered}{suffix}")
    lines.append(f"{indent})")
    return lines


def render_pipeline_sql(pipeline: dict[str, Any] | None, index_definition: str | None) -> list[CodeLine]:
    """Render ai.create_pipeline SQL from the ai.pipelines catalog row."""
    if not pipeline:
        return [CodeLine(1, "-- knowledge-hub-pipeline is not defined. Run scripts/00-preflight.ps1.", None)]

    raw: list[tuple[str, str | None]] = [
        ("-- Live definition, rendered from ai.pipelines", None),
        ("SELECT ai.create_pipeline(", None),
        (f"    name => {_literal(pipeline['name'])},", None),
    ]

    source = pipeline.get("source_config") or {}
    source_args = [("table_name", source.get("table_name")), ("schema_name", source.get("schema_name"))]
    if source.get("incremental_column"):
        source_args.append(("incremental_column", source["incremental_column"]))
    source_lines = _call("ai.table_source", source_args, "    ")
    raw.append((f"    source => {source_lines[0]}", "source"))
    raw.extend((line, "source") for line in source_lines[1:-1])
    raw.append((source_lines[-1] + ",", "source"))

    raw.append(("    steps => ARRAY[", None))
    steps = pipeline.get("steps") or []
    for position, step in enumerate(steps):
        kind = str(step.get("step", "step"))
        arguments: list[tuple[str, object]] = [("input", step.get("column"))]
        extras = {key: value for key, value in step.items() if key not in {"step", "column"} and value is not None}
        preferred = ("model", "method", "chunk_size", "overlap", "batch_size", "dimensions")
        arguments.extend((key, extras.pop(key)) for key in preferred if key in extras)
        arguments.extend(sorted(extras.items()))
        step_lines = _call(f"ai.{kind}", arguments, "        ")
        stage = kind if kind in {"chunk", "embed"} else None
        raw.append((f"        {step_lines[0]}", stage))
        raw.extend((line, stage) for line in step_lines[1:-1])
        raw.append((step_lines[-1] + ("," if position < len(steps) - 1 else ""), stage))
    raw.append(("    ],", None))

    sink = pipeline.get("sink_config") or {}
    sink_args: list[tuple[str, object]] = [
        ("table_name", sink.get("table_name")),
        ("schema_name", sink.get("schema_name")),
    ]
    if sink.get("on_conflict"):
        sink_args.append(("on_conflict", list(sink["on_conflict"])))
    if sink.get("on_conflict_action"):
        sink_args.append(("on_conflict_action", sink["on_conflict_action"]))
    sink_lines = _call("ai.table_sink", sink_args, "    ")
    raw.append((f"    sink => {sink_lines[0]}", "sink"))
    raw.extend((line, "sink") for line in sink_lines[1:-1])
    raw.append((sink_lines[-1] + ",", "sink"))

    raw.append((f"    trigger => {_literal(pipeline.get('trigger_type', 'manual'))}", "trigger"))
    raw.append((");", None))

    if index_definition:
        raw.append(("", None))
        raw.append(("-- Vector index on the sink, from pg_indexes", "index"))
        raw.append((index_definition + ";", "index"))

    return [CodeLine(number, text, stage) for number, (text, stage) in enumerate(raw, start=1)]


def classify_node(query: str, sink_schema: str, sink_table: str) -> str:
    """Map a pg_durable SQL node generated by ai.run to a pipeline stage."""
    normalized = " ".join(query.split())
    lowered = normalized.lower()
    if "_update_checkpoint" in lowered or "_stamp_rows_processed" in lowered:
        return "checkpoint"
    if lowered.startswith("drop table"):
        return "cleanup"
    if "create_embeddings" in lowered or "add column if not exists embedding" in lowered:
        return "embed"
    if "azure_ai.chunk" in lowered or (lowered.startswith("create table") and "_chunks (" in lowered):
        return "chunk"
    if lowered.startswith(f"insert into {sink_schema}.{sink_table}".lower()):
        return "sink"
    if lowered.startswith("create table") and " as select " in lowered:
        return "source"
    return "other"


def _parse_time(value: object) -> datetime | None:
    if isinstance(value, datetime):
        return value
    if isinstance(value, str) and value:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    return None


def summarize(status: dict[str, Any]) -> dict[str, Any]:
    """Build the JSON the browser animates: latest run, per-stage state, and timings."""
    pipeline = status.get("pipeline") or {}
    sink = pipeline.get("sink_config") or {}
    runs = status.get("runs") or []
    latest = runs[0] if runs else None

    stage_nodes: dict[str, list[dict[str, Any]]] = {}
    for node in status.get("nodes") or []:
        stage = classify_node(node.get("query") or "", sink.get("schema_name", ""), sink.get("table_name", ""))
        stage_nodes.setdefault(stage, []).append(node)

    run_status = (latest or {}).get("status")
    started = _parse_time((latest or {}).get("started_at"))
    stages: dict[str, dict[str, Any]] = {}
    for stage in ("source", "chunk", "embed", "sink", "checkpoint"):
        nodes = stage_nodes.get(stage, [])
        states = {str(node.get("status")) for node in nodes}
        if "failed" in states:
            state = "failed"
        elif "running" in states:
            state = "running"
        elif nodes and states <= {"completed"}:
            state = "completed"
        else:
            state = "pending"
        finished = max(
            (_parse_time(node.get("updated_at")) for node in nodes if node.get("status") == "completed"),
            default=None,
        )
        stages[stage] = {
            "state": state,
            "finished_ms": (
                round((finished - started).total_seconds() * 1000)
                if finished and started and state == "completed"
                else None
            ),
        }

    freshness = status.get("freshness") or {}
    reconciler = status.get("reconciler") or {}
    checked = _parse_time(status.get("checked_at"))
    last_tick = _parse_time(reconciler.get("last_tick"))
    return {
        "run": latest,
        "run_status": run_status,
        "stages": stages,
        "nodes": [
            {
                "stage": classify_node(node.get("query") or "", sink.get("schema_name", ""), sink.get("table_name", "")),
                "status": node.get("status"),
                "query": node.get("query"),
            }
            for node in status.get("nodes") or []
        ],
        "runs": runs,
        "checkpoint": status.get("checkpoint"),
        "freshness": freshness,
        "searchable": bool(freshness.get("articles")) and freshness.get("articles") == freshness.get("searchable_articles"),
        "sink_rows": status.get("sink_rows"),
        "reconciler": {
            "id": reconciler.get("id"),
            "status": reconciler.get("status"),
            "iteration": reconciler.get("iteration"),
            "seconds_since_tick": (
                round((checked - last_tick).total_seconds(), 1) if checked and last_tick else None
            ),
        },
        "trigger": pipeline.get("trigger_type"),
        "paused": pipeline.get("paused"),
    }

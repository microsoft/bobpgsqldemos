from __future__ import annotations

import logging
import os
from dataclasses import dataclass
from pathlib import Path

logger = logging.getLogger(__name__)

PIPELINE_SQL_ENV = "CALDOVA_PIPELINE_SQL"
DEFAULT_PIPELINE_SQL = (
    Path(__file__).resolve().parents[2] / "demo3-ai-pipeline" / "sql" / "01-create-pipeline.sql"
)
DISPLAY_PATH = "demo3-ai-pipeline/sql/01-create-pipeline.sql"

# Each marker starts a block that remains highlighted until its statement or call closes.
STAGE_MARKERS = (
    ("CREATE TABLE IF NOT EXISTS operations_guide_chunk", "sink", "statement"),
    ("CREATE INDEX IF NOT EXISTS operations_guide_chunk_diskann_idx", "index", "statement"),
    ("ai.table_source(", "source", "call"),
    ("ai.chunk(", "chunk", "call"),
    ("ai.embed(", "embed", "call"),
    ("ai.table_sink(", "sink", "call"),
)


@dataclass(frozen=True)
class PipelineCodeLine:
    number: int
    text: str
    stage: str | None


@dataclass(frozen=True)
class PipelineSource:
    display_path: str
    lines: list[PipelineCodeLine]
    error: str = ""


def load_pipeline_source(path: Path | None = None) -> PipelineSource:
    source_path = path or Path(os.environ.get(PIPELINE_SQL_ENV, DEFAULT_PIPELINE_SQL))
    try:
        text = source_path.read_text(encoding="utf-8")
    except OSError:
        logger.warning("Pipeline SQL is unavailable at %s", source_path)
        return PipelineSource(
            display_path=DISPLAY_PATH,
            lines=[],
            error="Pipeline SQL is unavailable. Set CALDOVA_PIPELINE_SQL to the Demo 3 SQL file.",
        )

    lines: list[PipelineCodeLine] = []
    stage: str | None = None
    end_rule = ""
    depth = 0
    for number, line in enumerate(text.splitlines(), start=1):
        if stage is None:
            marker = next((item for item in STAGE_MARKERS if item[0] in line), None)
            if marker is not None:
                _, stage, end_rule = marker
                depth = 0
                if end_rule == "call":
                    line_from_marker = line[line.index(marker[0]) :]
                    depth = line_from_marker.count("(") - line_from_marker.count(")")
        elif end_rule == "call":
            depth += line.count("(") - line.count(")")

        lines.append(PipelineCodeLine(number=number, text=line, stage=stage))

        if stage is not None and (
            (end_rule == "call" and depth <= 0)
            or (end_rule == "statement" and line.rstrip().endswith(";"))
        ):
            stage = None

    return PipelineSource(display_path=DISPLAY_PATH, lines=lines)

"""Progress reporting utilities for IPC with the Swift host process.

All progress goes to stderr (structured JSON, one line per update).
Final results go to stdout (structured JSON, one line).
"""

from __future__ import annotations

import json
import sys

from app.schemas.models import JobResult, ProgressUpdate


def report_progress(
    job_id: str,
    progress: float,
    stage: str,
    segment: int | None = None,
) -> None:
    """Write a ProgressUpdate JSON line to stderr, flushed immediately."""
    update = ProgressUpdate(
        job_id=job_id,
        progress=progress,
        stage=stage,
        current_segment=segment,
    )
    sys.stderr.write(json.dumps(update.model_dump()) + "\n")
    sys.stderr.flush()


def report_result(result: JobResult) -> None:
    """Write a JobResult JSON line to stdout, flushed immediately."""
    sys.stdout.write(json.dumps(result.model_dump()) + "\n")
    sys.stdout.flush()

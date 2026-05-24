"""Transcription engine router: dispatches to local or remote engine."""

from __future__ import annotations

from typing import Callable

from app.schemas.models import JobRequest, TranscriptSegment
from app.transcribe.local_engine import transcribe_local
from app.transcribe.remote_engine import transcribe_remote

ProgressCallback = Callable[[float, str], None]


def transcribe(
    request: JobRequest,
    progress_callback: ProgressCallback | None = None,
) -> list[TranscriptSegment]:
    """Route transcription to the appropriate engine.

    Args:
        request: The job request specifying engine and parameters.
        progress_callback: Optional callback for progress updates.

    Returns:
        List of transcript segments.

    Raises:
        RuntimeError: If transcription fails for any reason.
    """
    return transcribe_path(request.audio_path, request, progress_callback)


def transcribe_path(
    audio_path: str,
    request: JobRequest,
    progress_callback: ProgressCallback | None = None,
) -> list[TranscriptSegment]:
    """Transcribe a specific file with the request's engine settings."""
    try:
        if request.engine == "local_whisper":
            return transcribe_local(
                audio_path=audio_path,
                model=request.whisper_model,
                language=request.language,
                job_id=request.job_id,
            )
        return transcribe_remote(
            audio_path=audio_path,
            provider=request.remote_provider,
            language=request.language,
            job_id=request.job_id,
        )
    except Exception as exc:
        raise RuntimeError(f"Transcription failed ({request.engine}): {exc}") from exc

"""Local whisper transcription engine using pywhispercpp."""

from __future__ import annotations

import sys

from app.schemas.models import TranscriptSegment
from app.utils.progress import report_progress


def _stub_segments() -> list[TranscriptSegment]:
    """Return fake segments for spike testing when whisper is unavailable."""
    sys.stderr.write(
        '{"warning": "pywhispercpp unavailable, returning stub segments"}\n'
    )
    sys.stderr.flush()
    return [
        TranscriptSegment(start=0.0, end=5.0, text="Hello, this is a test.", speaker=None),
        TranscriptSegment(start=5.0, end=10.0, text="Stub transcription segment.", speaker=None),
        TranscriptSegment(start=10.0, end=15.0, text="End of stub transcript.", speaker=None),
    ]


def transcribe_local(
    audio_path: str,
    model: str = "base",
    language: str = "auto",
    job_id: str = "",
) -> list[TranscriptSegment]:
    """Transcribe audio using local whisper model.

    Falls back to stub segments if pywhispercpp is not installed.

    Args:
        audio_path: Path to the audio file.
        model: Whisper model size.
        language: Language code or "auto".
        job_id: Job ID for progress reporting.

    Returns:
        List of transcript segments.
    """
    try:
        from pywhispercpp.model import Model  # type: ignore[import-untyped]
    except ImportError:
        return _stub_segments()

    report_progress(job_id, 0.1, "loading_model")

    lang = language if language != "auto" else ""
    w = Model(model, language=lang if lang else "en")

    report_progress(job_id, 0.2, "transcribing")

    raw_segments = w.transcribe(audio_path)

    results: list[TranscriptSegment] = []
    total = len(raw_segments) if raw_segments else 1

    for i, seg in enumerate(raw_segments):
        progress = 0.2 + 0.7 * ((i + 1) / total)
        report_progress(job_id, progress, "transcribing", segment=i)
        results.append(
            TranscriptSegment(
                start=seg.t0 / 100.0,
                end=seg.t1 / 100.0,
                text=seg.text.strip(),
                speaker=None,
            )
        )

    report_progress(job_id, 0.95, "transcription_complete")
    return results

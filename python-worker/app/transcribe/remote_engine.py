"""Remote transcription engine using OpenAI-compatible APIs."""

from __future__ import annotations

import os
import sys

from app.schemas.models import TranscriptSegment
from app.utils.progress import report_progress

_PROVIDER_CONFIG: dict[str, dict[str, str]] = {
    "groq": {
        "base_url": "https://api.groq.com/openai/v1",
        "env_key": "GROQ_API_KEY",
        "model": "whisper-large-v3",
    },
    "openai": {
        "base_url": "https://api.openai.com/v1",
        "env_key": "OPENAI_API_KEY",
        "model": "whisper-1",
    },
}


def transcribe_remote(
    audio_path: str,
    provider: str = "groq",
    language: str = "auto",
    job_id: str = "",
) -> list[TranscriptSegment]:
    """Transcribe audio using a remote OpenAI-compatible API.

    Args:
        audio_path: Path to the audio file.
        provider: Provider name ("groq" or "openai").
        language: Language code or "auto".
        job_id: Job ID for progress reporting.

    Returns:
        List of transcript segments.

    Raises:
        ValueError: If the provider is unknown or API key is missing.
    """
    config = _PROVIDER_CONFIG.get(provider)
    if config is None:
        raise ValueError(f"Unknown provider: {provider!r}. Supported: {list(_PROVIDER_CONFIG)}")

    api_key = os.environ.get(config["env_key"], "")
    if not api_key:
        raise ValueError(f"Missing environment variable: {config['env_key']}")

    from openai import OpenAI

    report_progress(job_id, 0.1, "uploading_audio")

    client = OpenAI(api_key=api_key, base_url=config["base_url"])

    kwargs: dict[str, str] = {}
    if language != "auto":
        kwargs["language"] = language

    with open(audio_path, "rb") as f:
        report_progress(job_id, 0.2, "transcribing_remote")
        response = client.audio.transcriptions.create(
            model=config["model"],
            file=f,
            response_format="verbose_json",
            timestamp_granularities=["segment"],
            **kwargs,  # type: ignore[arg-type]
        )

    report_progress(job_id, 0.8, "parsing_response")

    segments: list[TranscriptSegment] = []
    raw_segments = getattr(response, "segments", None) or []

    for seg in raw_segments:
        segments.append(
            TranscriptSegment(
                start=float(seg.get("start", 0.0)) if isinstance(seg, dict) else float(getattr(seg, "start", 0.0)),
                end=float(seg.get("end", 0.0)) if isinstance(seg, dict) else float(getattr(seg, "end", 0.0)),
                text=(seg.get("text", "") if isinstance(seg, dict) else getattr(seg, "text", "")).strip(),
                speaker=None,
            )
        )

    if not segments and hasattr(response, "text") and response.text:
        sys.stderr.write('{"warning": "No segments returned, wrapping full text as single segment"}\n')
        sys.stderr.flush()
        segments = [TranscriptSegment(start=0.0, end=0.0, text=response.text.strip(), speaker=None)]

    report_progress(job_id, 0.95, "transcription_complete")
    return segments

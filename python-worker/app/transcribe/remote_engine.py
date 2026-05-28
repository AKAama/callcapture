"""Remote transcription engine.

Two flavours:

* OpenAI-compatible providers (Groq, OpenAI Whisper) — single multipart POST.
* AssemblyAI — upload → submit transcript job → poll. Returns native speaker
  diarization on every utterance, which we map straight into the worker's
  `TranscriptSegment.speaker` slot (no separate diarizer pass needed).
"""

from __future__ import annotations

import os
import sys
import time
from typing import Any

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
    "assemblyai": {
        "base_url": "https://api.assemblyai.com/v2",
        "env_key": "ASSEMBLYAI_API_KEY",
        "model": "best",  # only used in the request payload, not as a model id
    },
}


def transcribe_remote(
    audio_path: str,
    provider: str = "groq",
    language: str = "auto",
    job_id: str = "",
) -> list[TranscriptSegment]:
    """Transcribe audio using a remote provider.

    Args:
        audio_path: Path to the audio file.
        provider: "groq", "openai", or "assemblyai".
        language: Whisper language code or "auto".
        job_id: Job ID for progress reporting.

    Returns:
        List of transcript segments. AssemblyAI segments carry diarized speaker
        labels (`"Speaker A"` / `"Speaker B"` / …); Groq/OpenAI return `None`.

    Raises:
        ValueError: If the provider is unknown or the API key is missing.
        RuntimeError: If the remote job ultimately reports an error status.
    """
    config = _PROVIDER_CONFIG.get(provider)
    if config is None:
        raise ValueError(f"Unknown provider: {provider!r}. Supported: {list(_PROVIDER_CONFIG)}")

    api_key = os.environ.get(config["env_key"], "")
    if not api_key:
        raise ValueError(f"Missing environment variable: {config['env_key']}")

    if provider == "assemblyai":
        return _transcribe_assemblyai(audio_path, language, api_key, job_id)

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


# ---- AssemblyAI -----------------------------------------------------------

_ASSEMBLYAI_POLL_SECONDS = 5.0
_ASSEMBLYAI_UPLOAD_TIMEOUT = 600.0  # 10 minutes — long recordings
_ASSEMBLYAI_REQUEST_TIMEOUT = 60.0


def _transcribe_assemblyai(
    audio_path: str,
    language: str,
    api_key: str,
    job_id: str,
) -> list[TranscriptSegment]:
    """AssemblyAI 3-step transcription with native speaker labels.

    Uses httpx (already a worker dep). The async API is upload → submit job →
    poll until status is "completed" or "error". Speaker labels arrive on every
    utterance and are mapped straight to `TranscriptSegment.speaker` so the
    worker does NOT need its sidecar diarizer pass for this provider.
    """
    import httpx

    base = _PROVIDER_CONFIG["assemblyai"]["base_url"]
    headers = {"authorization": api_key}

    # 1. Upload the audio file.
    report_progress(job_id, 0.15, "uploading_audio")
    with open(audio_path, "rb") as f:
        upload = httpx.post(
            f"{base}/upload",
            headers=headers,
            content=f.read(),
            timeout=_ASSEMBLYAI_UPLOAD_TIMEOUT,
        )
    upload.raise_for_status()
    upload_url = upload.json().get("upload_url")
    if not upload_url:
        raise RuntimeError("AssemblyAI /upload did not return upload_url")

    # 2. Submit the transcription job with analytics turned on.
    report_progress(job_id, 0.25, "submitting_transcript")
    payload: dict[str, Any] = {
        "audio_url": upload_url,
        "speaker_labels": True,
        "sentiment_analysis": True,
        "entity_detection": True,
        "auto_chapters": True,
    }
    if language and language != "auto":
        payload["language_code"] = language
    submit = httpx.post(
        f"{base}/transcript",
        headers=headers,
        json=payload,
        timeout=_ASSEMBLYAI_REQUEST_TIMEOUT,
    )
    submit.raise_for_status()
    transcript_id = submit.json().get("id")
    if not transcript_id:
        raise RuntimeError("AssemblyAI /transcript did not return id")

    # 3. Poll until completed or error.
    poll_url = f"{base}/transcript/{transcript_id}"
    report_progress(job_id, 0.35, "transcribing_remote")
    while True:
        resp = httpx.get(poll_url, headers=headers, timeout=_ASSEMBLYAI_REQUEST_TIMEOUT)
        resp.raise_for_status()
        body = resp.json()
        status = body.get("status")
        if status == "completed":
            break
        if status == "error":
            raise RuntimeError(
                f"AssemblyAI transcription failed: {body.get('error', 'unknown')}"
            )
        time.sleep(_ASSEMBLYAI_POLL_SECONDS)

    report_progress(job_id, 0.9, "parsing_response")
    segments = _assemblyai_segments_from(body)
    report_progress(job_id, 0.95, "transcription_complete")
    return segments


def _assemblyai_segments_from(body: dict[str, Any]) -> list[TranscriptSegment]:
    """Map a completed AssemblyAI transcript body to `TranscriptSegment` list.

    Prefers `utterances` (speaker-diarized) when present; otherwise falls back
    to a single segment carrying the full `text` (so calls without diarization
    still produce something usable).
    """
    utterances = body.get("utterances") or []
    if utterances:
        segments: list[TranscriptSegment] = []
        for u in utterances:
            speaker_id = u.get("speaker")
            speaker = f"Speaker {speaker_id}" if speaker_id is not None else None
            segments.append(
                TranscriptSegment(
                    start=float(u.get("start", 0)) / 1000.0,
                    end=float(u.get("end", 0)) / 1000.0,
                    text=str(u.get("text", "")).strip(),
                    speaker=speaker,
                )
            )
        return segments

    # No diarization → fall back to the flat text.
    text = str(body.get("text", "")).strip()
    if not text:
        return []
    duration = float(body.get("audio_duration", 0))
    return [TranscriptSegment(start=0.0, end=duration, text=text, speaker=None)]

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
        # Model selection lives in `_assemblyai_transcript_payload` via the
        # `speech_models` list; this provider never reads a single "model" key.
    },
    "deepgram": {
        "base_url": "https://api.deepgram.com/v1",
        "env_key": "DEEPGRAM_API_KEY",
        "model": "nova-3",
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

    if provider == "deepgram":
        return _transcribe_deepgram(audio_path, language, api_key, job_id)

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
        upload = _assemblyai_request(
            "POST", f"{base}/upload",
            headers=headers, content=f.read(),
            timeout=_ASSEMBLYAI_UPLOAD_TIMEOUT,
        )
    upload_url = upload.get("upload_url")
    if not upload_url:
        raise RuntimeError("AssemblyAI /upload did not return upload_url")

    # 2. Submit the transcription job.
    report_progress(job_id, 0.25, "submitting_transcript")
    payload = _assemblyai_transcript_payload(upload_url, language)
    submit = _assemblyai_request(
        "POST", f"{base}/transcript",
        headers=headers, json=payload,
        timeout=_ASSEMBLYAI_REQUEST_TIMEOUT,
    )
    transcript_id = submit.get("id")
    if not transcript_id:
        raise RuntimeError("AssemblyAI /transcript did not return id")

    # 3. Poll until completed or error.
    poll_url = f"{base}/transcript/{transcript_id}"
    report_progress(job_id, 0.35, "transcribing_remote")
    while True:
        body = _assemblyai_request(
            "GET", poll_url,
            headers=headers,
            timeout=_ASSEMBLYAI_REQUEST_TIMEOUT,
        )
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


# AssemblyAI speech-model selection.
#
# The singular `speech_model` param and its `best` / `nano` aliases are
# deprecated — sending them returns HTTP 400 "speech model is deprecated".
# The current API uses the `speech_models` priority list: AssemblyAI routes to
# the first model that supports the (declared or detected) language.
#   * universal-3-pro — highest accuracy, 6 languages (en, es, pt, fr, de, it)
#   * universal-2     — ~99 languages
# Both support speaker diarization, so this list gives Pro accuracy where
# available and broad-language coverage (Ukrainian/Russian/etc.) everywhere
# else, all WITH speaker labels.
_ASSEMBLYAI_SPEECH_MODELS = ["universal-3-pro", "universal-2"]


def _assemblyai_transcript_payload(audio_url: str, language: str) -> dict[str, Any]:
    """Build the /transcript request body.

    Always requests the `speech_models` priority list (the deprecated singular
    `speech_model` 400s) and speaker diarization. The English-only analytics
    (sentiment / chapters / entities) are NOT requested — `_assemblyai_segments_from`
    never reads them, and they 400 on non-English audio. The worker derives
    sentiment/insights from its own LLM post-processing instead.

    Language handling:
    * `""` / `auto` → `language_detection: true` (AssemblyAI detects).
    * explicit code → `language_code` (AssemblyAI routes to a model supporting it).
    """
    payload: dict[str, Any] = {
        "audio_url": audio_url,
        "speech_models": _ASSEMBLYAI_SPEECH_MODELS,
        "speaker_labels": True,
    }
    if language in ("", "auto"):
        payload["language_detection"] = True
    else:
        payload["language_code"] = language
    return payload


def _assemblyai_request(
    method: str, url: str, *, headers: dict[str, str], timeout: float,
    content: bytes | None = None, json: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Thin httpx wrapper that surfaces the AssemblyAI error body on non-2xx.

    The default `httpx.HTTPStatusError` only carries the status code, so a 400
    bubbles to Swift as "HTTPStatusError" with no clue why. We pull the
    response body — AssemblyAI returns `{"error": "<reason>"}` — and re-raise
    a clearer `RuntimeError`.
    """
    import httpx

    kwargs: dict[str, Any] = {"headers": headers, "timeout": timeout}
    if content is not None:
        kwargs["content"] = content
    if json is not None:
        kwargs["json"] = json

    resp = httpx.request(method, url, **kwargs)
    if resp.status_code >= 400:
        try:
            body = resp.json()
            detail = body.get("error") or body.get("message") or resp.text
        except ValueError:
            detail = resp.text
        raise RuntimeError(
            f"AssemblyAI {method} {url.rsplit('/', 1)[-1]} -> "
            f"{resp.status_code}: {str(detail)[:300]}"
        )
    try:
        return resp.json()
    except ValueError as exc:
        raise RuntimeError(f"AssemblyAI {method} returned non-JSON: {exc}") from exc


# ---- Deepgram --------------------------------------------------------------

_DEEPGRAM_REQUEST_TIMEOUT = 600.0  # synchronous POST returns when done

# Languages supported by Deepgram's Nova-3 with diarization + sentiment. The
# model itself covers ~36 languages; this set tracks the ones our UI exposes
# (see SpokenLanguage.swift). Anything not in here falls back to `auto`.
_DEEPGRAM_NOVA3_LANGUAGES = {
    "en", "es", "fr", "de", "it", "pt", "nl", "ru", "uk", "pl",
    "cs", "sv", "tr", "ja", "ko", "zh", "ar", "hi",
}


def _transcribe_deepgram(
    audio_path: str,
    language: str,
    api_key: str,
    job_id: str,
) -> list[TranscriptSegment]:
    """Deepgram Nova-3 transcription (single sync POST).

    Deepgram returns words with speaker indices and grouped paragraphs in one
    response — no upload + poll roundtrip. Covers the languages AssemblyAI's
    `best` model can't (notably Ukrainian/Russian/Polish), with native speaker
    diarization and sentiment.
    """
    import httpx

    base = _PROVIDER_CONFIG["deepgram"]["base_url"]
    model = _PROVIDER_CONFIG["deepgram"]["model"]
    params = _deepgram_params(language=language, model=model)

    report_progress(job_id, 0.15, "uploading_audio")
    with open(audio_path, "rb") as f:
        audio = f.read()

    report_progress(job_id, 0.35, "transcribing_remote")
    resp = httpx.post(
        f"{base}/listen",
        params=params,
        headers={
            "Authorization": f"Token {api_key}",
            "Content-Type": "audio/wav",
        },
        content=audio,
        timeout=_DEEPGRAM_REQUEST_TIMEOUT,
    )
    if resp.status_code >= 400:
        try:
            body = resp.json()
            detail = body.get("err_msg") or body.get("error") or resp.text
        except ValueError:
            detail = resp.text
        raise RuntimeError(
            f"Deepgram /listen -> {resp.status_code}: {str(detail)[:300]}"
        )

    report_progress(job_id, 0.9, "parsing_response")
    segments = _deepgram_segments_from(resp.json())
    report_progress(job_id, 0.95, "transcription_complete")
    return segments


def _deepgram_params(*, language: str, model: str) -> dict[str, str]:
    """Build the query-string params for POST /v1/listen.

    `language=multi` is Deepgram's auto-detect/code-switching sentinel. Unknown
    languages also fall back to `multi` so we never send an unsupported code.
    """
    params: dict[str, str] = {
        "model": model,
        "diarize": "true",
        "punctuate": "true",
        "smart_format": "true",
        "sentiment": "true",
    }
    if language in ("", "auto"):
        params["language"] = "multi"
    elif language in _DEEPGRAM_NOVA3_LANGUAGES:
        params["language"] = language
    else:
        params["language"] = "multi"
    return params


def _deepgram_segments_from(body: dict[str, Any]) -> list[TranscriptSegment]:
    """Map a Deepgram /listen response to `TranscriptSegment` list.

    Prefers `paragraphs.paragraphs` (already grouped by speaker turn). Falls
    back to grouping consecutive same-speaker words. Last resort: the flat
    transcript as a single segment.
    """
    try:
        alt = body["results"]["channels"][0]["alternatives"][0]
    except (KeyError, IndexError, TypeError):
        return []

    # Best path: pre-grouped paragraphs.
    paragraphs = (alt.get("paragraphs") or {}).get("paragraphs") or []
    if paragraphs:
        segments: list[TranscriptSegment] = []
        for para in paragraphs:
            speaker_id = para.get("speaker")
            speaker = f"Speaker {speaker_id}" if speaker_id is not None else None
            sentences = para.get("sentences") or []
            text = " ".join(str(s.get("text", "")).strip() for s in sentences).strip()
            if not text:
                continue
            segments.append(
                TranscriptSegment(
                    start=float(para.get("start", 0)),
                    end=float(para.get("end", 0)),
                    text=text,
                    speaker=speaker,
                )
            )
        if segments:
            return segments

    # Mid path: regroup words by speaker.
    words = alt.get("words") or []
    if words:
        segments = []
        current: dict[str, Any] | None = None
        for w in words:
            speaker_id = w.get("speaker")
            text_piece = str(w.get("punctuated_word") or w.get("word", "")).strip()
            if current is None or current["speaker_id"] != speaker_id:
                if current is not None and current["words"]:
                    segments.append(
                        TranscriptSegment(
                            start=current["start"],
                            end=current["end"],
                            text=" ".join(current["words"]).strip(),
                            speaker=(
                                f"Speaker {current['speaker_id']}"
                                if current["speaker_id"] is not None else None
                            ),
                        )
                    )
                current = {
                    "speaker_id": speaker_id,
                    "start": float(w.get("start", 0)),
                    "end": float(w.get("end", 0)),
                    "words": [text_piece] if text_piece else [],
                }
            else:
                current["end"] = float(w.get("end", current["end"]))
                if text_piece:
                    current["words"].append(text_piece)
        if current is not None and current["words"]:
            segments.append(
                TranscriptSegment(
                    start=current["start"],
                    end=current["end"],
                    text=" ".join(current["words"]).strip(),
                    speaker=(
                        f"Speaker {current['speaker_id']}"
                        if current["speaker_id"] is not None else None
                    ),
                )
            )
        if segments:
            return segments

    # Fallback: single segment from the flat transcript.
    text = str(alt.get("transcript", "")).strip()
    if not text:
        return []
    return [TranscriptSegment(start=0.0, end=0.0, text=text, speaker=None)]

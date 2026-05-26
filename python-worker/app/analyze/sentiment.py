"""LLM-based conversation sentiment (Phase 4a: text only).

Reuses the OpenAI-compatible endpoint described by the LLM_* env vars (OpenRouter
or a local server), mirroring app.postprocess.markdown. Never raises into the
pipeline: an unusable endpoint or a failed/garbled call yields a neutral fallback.
"""

from __future__ import annotations

import math

from app.postprocess.llm_client import LLMClient, LLMError
from app.postprocess.llm_env import (
    format_speaker_tone_lines,
    resolve_llm_env,
    transcript_text,
    warn,
)
from app.schemas.models import Sentiment, SpeakerSentiment, TranscriptSegment

_VALID_LABELS = {"positive", "neutral", "negative", "mixed"}

_SYSTEM_PROMPT = (
    "You are a conversation sentiment analyst. Given a speaker-labeled transcript, "
    "judge the emotional sentiment. Output ONLY valid JSON matching this schema:\n"
    '{"overall": "positive|neutral|negative|mixed", '
    '"overall_score": <float between -1 and 1>, '
    '"by_speaker": {"<speaker label>": '
    '{"label": "positive|neutral|negative|mixed", "score": <float between -1 and 1>}}}\n'
    "Use the exact speaker labels that appear in the transcript. Score: -1 very "
    "negative, 0 neutral, 1 very positive. No prose, no invented speakers."
)


def _distinct_speakers(segments: list[TranscriptSegment]) -> list[str]:
    seen: list[str] = []
    for s in segments:
        label = s.speaker or "Speaker 1"
        if label not in seen:
            seen.append(label)
    return seen


def _clamp(value: float) -> float:
    return max(-1.0, min(1.0, value))


def _norm_label(label: object) -> str:
    text = str(label).strip().lower()
    return text if text in _VALID_LABELS else "neutral"


def _to_score(value: object) -> float:
    try:
        score = float(value)
    except (TypeError, ValueError):
        return 0.0
    return _clamp(score) if math.isfinite(score) else 0.0


def _neutral_fallback(segments: list[TranscriptSegment]) -> Sentiment:
    by_speaker = {
        label: SpeakerSentiment(label="neutral", score=0.0)
        for label in _distinct_speakers(segments)
    }
    return Sentiment(overall="neutral", overall_score=0.0, by_speaker=by_speaker)


def _tone_block(emotion: dict | None) -> str:
    """Acoustic-tone context for the prompt, or '' when no emotion is available."""
    tone_lines = format_speaker_tone_lines(emotion)
    if not tone_lines:  # no emotion, or nothing parseable
        return ""
    lines = [
        "Vocal tone (acoustic emotion):",
        *tone_lines,
        "Reconcile the text sentiment with this vocal tone.\n",
    ]
    return "\n".join(lines)


def _build_sentiment(data: dict, segments: list[TranscriptSegment]) -> Sentiment:
    raw_by = data.get("by_speaker")
    if not isinstance(raw_by, dict):
        raw_by = {}
    by_speaker: dict[str, SpeakerSentiment] = {}
    for label in _distinct_speakers(segments):
        entry = raw_by.get(label)
        if not isinstance(entry, dict):
            entry = {}
        by_speaker[label] = SpeakerSentiment(
            label=_norm_label(entry.get("label")),
            score=_to_score(entry.get("score")),
        )
    return Sentiment(
        overall=_norm_label(data.get("overall")),
        overall_score=_to_score(data.get("overall_score")),
        by_speaker=by_speaker,
    )


def analyze_sentiment(
    segments: list[TranscriptSegment],
    *,
    emotion: dict | None = None,  # acoustic-tone context; see _tone_block
) -> Sentiment | None:
    """Judge conversation sentiment from speaker-labeled segments via the LLM.

    Returns None for an empty transcript; otherwise a `Sentiment`. Never raises —
    an unusable endpoint or any failure yields a neutral fallback covering every
    speaker present in `segments`.
    """
    if not segments:
        return None

    env = resolve_llm_env()
    if not env.api_key and not env.is_local:
        warn("no LLM_API_KEY for cloud endpoint, using neutral sentiment")
        return _neutral_fallback(segments)

    try:
        client = LLMClient(api_key=env.api_key, model=env.model, base_url=env.base_url)
        data = client.complete_json(
            system=_SYSTEM_PROMPT,
            user=f"{_tone_block(emotion)}Transcript:\n\n{transcript_text(segments)}",
        )
        return _build_sentiment(data, segments)
    except (LLMError, ValueError, TypeError, AttributeError, KeyError) as exc:
        warn(f"sentiment failed: {exc}, using neutral sentiment")
        return _neutral_fallback(segments)

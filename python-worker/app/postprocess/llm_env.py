"""Shared helpers for the LLM-backed analyzers (markdown, sentiment, insights):
endpoint resolution, stderr warnings, and transcript formatting."""

from __future__ import annotations

import json
import os
import sys
from dataclasses import dataclass

from app.postprocess.llm_client import OPENROUTER_BASE_URL
from app.schemas.models import TranscriptSegment

_DEFAULT_MODEL = "google/gemini-2.5-flash"


@dataclass(frozen=True)
class LlmEnv:
    """Resolved LLM endpoint configuration from the LLM_* environment."""

    base_url: str
    model: str
    api_key: str
    is_local: bool


def resolve_llm_env() -> LlmEnv:
    """Read LLM_BASE_URL / LLM_MODEL / LLM_API_KEY (OpenRouter defaults).

    `is_local` is True when the base URL is not an openrouter.ai endpoint (e.g. a
    local Ollama/LM Studio server), in which case a missing API key is acceptable.
    """
    base_url = os.environ.get("LLM_BASE_URL", OPENROUTER_BASE_URL)
    model = os.environ.get("LLM_MODEL", _DEFAULT_MODEL)
    api_key = os.environ.get("LLM_API_KEY", "")
    is_local = "openrouter.ai" not in base_url
    return LlmEnv(base_url=base_url, model=model, api_key=api_key, is_local=is_local)


def warn(message: str) -> None:
    """Write a `{"warning": ...}` JSON line to stderr and flush."""
    sys.stderr.write(json.dumps({"warning": message}) + "\n")
    sys.stderr.flush()


def format_speaker_tone_lines(emotion: dict | None) -> list[str]:
    """Per-speaker acoustic-tone lines for an LLM prompt.

    Each line reads `- <label> sounded <emotion> (valence X.XX, arousal X.XX).`.
    Entries whose valence/arousal can't be read as floats are skipped; returns []
    for no/empty emotion. Shared by the sentiment and insights analyzers.
    """
    if not emotion:
        return []
    lines: list[str] = []
    for label, e in emotion.items():
        try:
            valence = float(e.get("valence", 0.0))
            arousal = float(e.get("arousal", 0.0))
        except (TypeError, ValueError, AttributeError):
            continue
        dom = e.get("dominant_emotion", "neutral") if isinstance(e, dict) else "neutral"
        lines.append(f"- {label} sounded {dom} (valence {valence:.2f}, arousal {arousal:.2f}).")
    return lines


def transcript_text(segments: list[TranscriptSegment], *, timestamps: bool = False) -> str:
    """Speaker-labeled transcript text for an LLM prompt.

    `timestamps=True` prefixes each line with `[12.3s] ` for time-anchored prompts;
    the default produces plain speaker-labeled lines.
    """
    lines: list[str] = []
    for s in segments:
        speaker = f"[{s.speaker}] " if s.speaker else ""
        if timestamps:
            lines.append(f"[{s.start:.1f}s] {speaker}{s.text}")
        else:
            lines.append(f"{speaker}{s.text}")
    return "\n".join(lines)

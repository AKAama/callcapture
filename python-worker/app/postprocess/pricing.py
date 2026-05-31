"""USD cost estimation for transcription + LLM processing.

Pure functions, no I/O. Default rates ship in code; the Settings UI can
override them per provider via `merge_rates`.
"""
from __future__ import annotations

# USD. Approximate public rates verified 2026-05-29 — VERIFY before relying on
# them. Sources: assemblyai.com, deepgram.com pricing pages.
DEFAULT_STT_RATE_PER_MIN: dict[str, float] = {
    "assemblyai": 0.0035,   # Universal-3 Pro ~$0.21/hr
    "deepgram": 0.0043,     # Nova-3 pre-recorded
    "openai": 0.0060,       # whisper-1
    "groq": 0.0007,         # whisper distil
    "local_whisper": 0.0,   # on-device, free
}

DEFAULT_LLM_FALLBACK_RATE_PER_1M = 3.00  # blended $/1M tokens, fallback only


def merge_rates(overrides: dict[str, float] | None) -> dict[str, float]:
    """Return defaults with valid (non-None, non-negative) overrides applied."""
    rates = dict(DEFAULT_STT_RATE_PER_MIN)
    for key, value in (overrides or {}).items():
        if isinstance(value, (int, float)) and value >= 0:
            rates[key] = float(value)
    return rates


def transcription_cost(
    minutes: float, provider: str, stems: int, rates: dict[str, float]
) -> float:
    """audio_minutes × per-minute rate × number of stems transcribed."""
    rate = rates.get(provider, 0.0)
    return float(minutes) * rate * int(stems)


def processing_cost(
    actual_cost: float | None, tokens: int, fallback_rate_per_1m: float
) -> float:
    """OpenRouter-reported actual cost when present; else tokens × fallback."""
    if actual_cost is not None:
        return float(actual_cost)
    return (int(tokens) / 1_000_000.0) * float(fallback_rate_per_1m)

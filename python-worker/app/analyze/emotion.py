"""Local acoustic emotion (Phase 4b) via the audeering wav2vec2 dimensional model.

Heavy deps (audonnx, audeer, audiofile, onnxruntime) are imported LAZILY inside the
functions that need them, so this module — and the worker that imports it — load fine
with only numpy installed. Unit tests mock `predict_vad` and `_read_audio`.
"""

from __future__ import annotations

import os
from dataclasses import dataclass

import numpy as np

from app.schemas.models import ArcPoint, TranscriptSegment

# Tuning constants (see spec §2, §7).
_TARGET_SR = 16000
_MIN_SEG_SEC = 0.5
_MAX_SEG_SEC = 30.0
_MAX_TOTAL_SEC_PER_SPEAKER = 300.0
_ARC_WINDOW_SEC = 20.0
_ARC_MAX_WINDOWS = 120

_LOW = 0.45
_HIGH = 0.55


def dominant_emotion(valence: float, arousal: float) -> str:
    """Map (valence, arousal) — each ~0..1, 0.5 ≈ neutral — to a coarse label."""
    if valence > _HIGH and arousal > _HIGH:
        return "excited"
    if valence > _HIGH and arousal < _LOW:
        return "content"
    if valence < _LOW and arousal > _HIGH:
        return "frustrated"
    if valence < _LOW and arousal < _LOW:
        return "sad"
    return "neutral"


def slice_signal(
    signal: np.ndarray,
    sampling_rate: int,
    start: float,
    end: float,
    max_sec: float = _MAX_SEG_SEC,
) -> np.ndarray:
    """Return the `[start, end]` span of `signal`, clamped to its bounds and to
    `max_sec` seconds."""
    start_idx = max(0, int(start * sampling_rate))
    end_idx = min(len(signal), int(end * sampling_rate))
    if end_idx <= start_idx:
        return signal[0:0]
    max_len = int(max_sec * sampling_rate)
    end_idx = min(end_idx, start_idx + max_len)
    return signal[start_idx:end_idx]

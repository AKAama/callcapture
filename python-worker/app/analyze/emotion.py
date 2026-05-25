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


@dataclass(frozen=True)
class SpeakerEmotion:
    valence: float
    arousal: float
    dominant_emotion: str

# Tuning constants (see spec §2, §7).
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


def emotion_model_dir() -> str:
    """Where the extracted audeering model lives (shared by prepare + analysis)."""
    base = os.path.expanduser("~/Library/Application Support/CallCapture")
    return os.path.join(base, "models", "emotion-msp-dim")


def is_emotion_model_ready() -> bool:
    """True if the model has been downloaded+extracted. Confirm the marker file
    name against the real Zenodo archive; `model.yaml` is audonnx's loader entry."""
    directory = emotion_model_dir()
    return os.path.isfile(os.path.join(directory, "model.yaml"))


# --- heavy-dep seams (lazy import; not unit-tested) -------------------------

_model = None  # cached audonnx model for this process


def _read_audio(path: str) -> tuple[np.ndarray, int]:
    """Read `path` as float32 mono @ 16 kHz. Lazy-imports audiofile."""
    import audiofile  # lazy

    signal, sampling_rate = audiofile.read(path, always_2d=False)
    signal = np.asarray(signal, dtype=np.float32)
    if signal.ndim > 1:  # downmix to mono
        signal = signal.mean(axis=0)
    return signal, int(sampling_rate)


def predict_vad(signal: np.ndarray, sampling_rate: int) -> tuple[float, float, float]:
    """Return (valence, arousal, dominance) in ~0..1 for a mono 16 kHz signal.

    Lazy-loads the audonnx model once. The model emits logits ordered
    [arousal, dominance, valence]; this reorders to (valence, arousal, dominance).
    """
    global _model
    if _model is None:
        import audonnx  # lazy

        _model = audonnx.load(emotion_model_dir())
    logits = _model(signal, sampling_rate)["logits"][0]
    arousal, dominance, valence = float(logits[0]), float(logits[1]), float(logits[2])
    return valence, arousal, dominance


def _stem_for(speaker: str, audio_path: str) -> str:
    """Audio file holding a speaker's voice: You -> mic stem, others -> system stem,
    falling back to the mixed file when a stem is absent."""
    base = os.path.splitext(audio_path)[0]
    stem = f"{base}_mic.wav" if speaker == "You" else f"{base}_system.wav"
    return stem if os.path.exists(stem) else audio_path


def compute_speaker_emotion(
    segments: list[TranscriptSegment],
    audio_path: str,
) -> dict[str, SpeakerEmotion]:
    """Duration-weighted per-speaker valence/arousal over each speaker's segments.

    Segments < `_MIN_SEG_SEC` are skipped; each is clipped to `_MAX_SEG_SEC`; total
    inferred audio per speaker is capped at `_MAX_TOTAL_SEC_PER_SPEAKER` (longest
    segments first). SER inference and audio reading are the mocked seams.
    """
    by_speaker: dict[str, list[TranscriptSegment]] = {}
    for s in segments:
        if (s.end - s.start) < _MIN_SEG_SEC:
            continue
        by_speaker.setdefault(s.speaker or "Speaker 1", []).append(s)

    result: dict[str, SpeakerEmotion] = {}
    for speaker, segs in by_speaker.items():
        path = _stem_for(speaker, audio_path)
        try:
            signal, sr = _read_audio(path)
        except Exception:  # noqa: BLE001 - degrade per-speaker on read failure
            continue
        # Longest segments first, capped to the per-speaker budget.
        ordered = sorted(segs, key=lambda s: s.end - s.start, reverse=True)
        budget = _MAX_TOTAL_SEC_PER_SPEAKER
        v_sum = a_sum = w_sum = 0.0
        for s in ordered:
            if budget <= 0:
                break
            clip = slice_signal(signal, sr, s.start, s.end, max_sec=min(_MAX_SEG_SEC, budget))
            dur = len(clip) / sr if sr else 0.0
            if dur < _MIN_SEG_SEC:
                continue
            valence, arousal, _ = predict_vad(clip, sr)
            v_sum += valence * dur
            a_sum += arousal * dur
            w_sum += dur
            budget -= dur
        if w_sum <= 0:
            continue
        valence = v_sum / w_sum
        arousal = a_sum / w_sum
        result[speaker] = SpeakerEmotion(
            valence=round(valence, 4),
            arousal=round(arousal, 4),
            dominant_emotion=dominant_emotion(valence, arousal),
        )
    return result


def compute_arc(
    audio_path: str,
    window_sec: float = _ARC_WINDOW_SEC,
    max_windows: int = _ARC_MAX_WINDOWS,
) -> list[ArcPoint]:
    """Acoustic-valence arc over the mixed recording, ≤ `max_windows` windows."""
    try:
        signal, sr = _read_audio(audio_path)
    except Exception:  # noqa: BLE001 - no arc on read failure
        return []
    total_sec = len(signal) / sr if sr else 0.0
    if total_sec <= 0:
        return []
    # Floor division: recordings in (window_sec, 2*window_sec) yield n=1 (first window only).
    # When total > max_windows*window_sec, step > window_sec so t is the nominal (not sampled) window center.
    n = min(max_windows, max(1, int(total_sec // window_sec)))
    step = total_sec / n
    points: list[ArcPoint] = []
    for i in range(n):
        start = i * step
        clip = slice_signal(signal, sr, start, start + step, max_sec=window_sec)
        if len(clip) == 0:
            continue
        valence, _, _ = predict_vad(clip, sr)
        points.append(ArcPoint(t=round(start + step / 2.0, 2), score=round(2.0 * valence - 1.0, 4)))
    return points

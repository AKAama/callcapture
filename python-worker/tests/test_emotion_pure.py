import numpy as np

from app.analyze.emotion import dominant_emotion, slice_signal


def test_dominant_emotion_quadrants():
    assert dominant_emotion(0.8, 0.8) == "excited"
    assert dominant_emotion(0.8, 0.2) == "content"
    assert dominant_emotion(0.2, 0.8) == "frustrated"
    assert dominant_emotion(0.2, 0.2) == "sad"
    assert dominant_emotion(0.5, 0.5) == "neutral"


def test_slice_signal_basic():
    sr = 16000
    sig = np.arange(sr * 4, dtype=np.float32)  # 4 seconds ramp
    out = slice_signal(sig, sr, start=1.0, end=2.0, max_sec=30.0)
    assert len(out) == sr            # 1 second
    assert out[0] == sr              # sample at t=1.0s


def test_slice_signal_clamps_to_max_sec():
    sr = 16000
    sig = np.zeros(sr * 50, dtype=np.float32)  # 50 seconds
    out = slice_signal(sig, sr, start=0.0, end=50.0, max_sec=30.0)
    assert len(out) == sr * 30       # clipped to 30s


def test_slice_signal_clamps_to_bounds():
    sr = 16000
    sig = np.zeros(sr * 2, dtype=np.float32)
    out = slice_signal(sig, sr, start=1.5, end=99.0, max_sec=30.0)
    assert len(out) == int(sr * 0.5)  # only 0.5s of audio remains past 1.5s


import os


def test_emotion_model_dir_under_app_support():
    from app.analyze.emotion import emotion_model_dir
    d = emotion_model_dir()
    assert d.endswith("models/emotion-msp-dim")
    assert "CallCapture" in d


def test_is_emotion_model_ready(tmp_path, monkeypatch):
    from app.analyze import emotion
    monkeypatch.setattr(emotion, "emotion_model_dir", lambda: str(tmp_path))
    assert emotion.is_emotion_model_ready() is False
    (tmp_path / "model.yaml").write_text("meta")
    assert emotion.is_emotion_model_ready() is True


def test_slice_signal_returns_empty_when_start_past_end():
    sr = 16000
    sig = np.zeros(sr * 2, dtype=np.float32)  # 2s
    out = slice_signal(sig, sr, start=5.0, end=6.0)  # start past end of signal
    assert len(out) == 0

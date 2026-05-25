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

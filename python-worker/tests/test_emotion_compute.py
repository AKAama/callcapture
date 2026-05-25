import numpy as np

from app.analyze import emotion as emo
from app.analyze.emotion import SpeakerEmotion, compute_arc, compute_speaker_emotion
from app.schemas.models import TranscriptSegment


def _seg(start, end, speaker):
    return TranscriptSegment(start=start, end=end, text="x", speaker=speaker)


def test_compute_speaker_emotion_duration_weighted(monkeypatch):
    # Two speakers; You has a 2s and a 4s segment, Speaker 1 a 3s segment.
    segs = [_seg(0, 2, "You"), _seg(2, 5, "Speaker 1"), _seg(5, 9, "You")]
    # Stems "exist": map any read to a fixed-length zero signal.
    monkeypatch.setattr(emo.os.path, "exists", lambda p: True)
    monkeypatch.setattr(emo, "_read_audio", lambda path: (np.zeros(16000 * 20, np.float32), 16000))
    # predict_vad returns valence depending on speaker via the (zero) signal length;
    # instead key off a counter to give You vs Speaker 1 different values.
    calls = {"n": 0}

    def fake_predict(signal, sr):
        # You segments -> valence .8/arousal .6 ; Speaker 1 -> .2/.7
        calls["n"] += 1
        return (0.8, 0.6, 0.5)

    monkeypatch.setattr(emo, "predict_vad", fake_predict)

    out = compute_speaker_emotion(segs, "/tmp/sess.wav")
    assert set(out) == {"You", "Speaker 1"}
    assert isinstance(out["You"], SpeakerEmotion)
    assert out["You"].dominant_emotion == "excited"   # 0.8/0.6
    assert 0.0 <= out["You"].valence <= 1.0


def test_compute_speaker_emotion_skips_short_segments(monkeypatch):
    segs = [_seg(0, 0.2, "You")]  # < 0.5s -> skipped, no speakers
    monkeypatch.setattr(emo.os.path, "exists", lambda p: True)
    monkeypatch.setattr(emo, "_read_audio", lambda path: (np.zeros(16000, np.float32), 16000))
    monkeypatch.setattr(emo, "predict_vad", lambda s, sr: (0.5, 0.5, 0.5))
    assert compute_speaker_emotion(segs, "/tmp/sess.wav") == {}


def test_compute_arc_windows(monkeypatch):
    monkeypatch.setattr(emo, "_read_audio", lambda path: (np.zeros(16000 * 60, np.float32), 16000))
    monkeypatch.setattr(emo, "predict_vad", lambda s, sr: (0.75, 0.5, 0.5))  # valence .75 -> score .5
    arc = compute_arc("/tmp/sess.wav", window_sec=20.0, max_windows=120)
    assert len(arc) == 3                     # 60s / 20s
    assert arc[0].t == 10.0                  # first window center
    assert abs(arc[0].score - 0.5) < 1e-6    # 2*0.75 - 1


def test_compute_arc_empty_on_read_failure(monkeypatch):
    def boom(path):
        raise OSError("no file")
    monkeypatch.setattr(emo, "_read_audio", boom)
    assert compute_arc("/tmp/missing.wav") == []

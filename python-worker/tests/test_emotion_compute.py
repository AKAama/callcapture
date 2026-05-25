import numpy as np

from app.analyze import emotion as emo
from app.analyze.emotion import SpeakerEmotion, compute_arc, compute_speaker_emotion
from app.schemas.models import TranscriptSegment


def _seg(start, end, speaker):
    return TranscriptSegment(start=start, end=end, text="x", speaker=speaker)


def test_compute_speaker_emotion_duration_weighted(monkeypatch):
    # You: 2s + 4s segments; Speaker 1: one 3s segment.
    # valence = clip_seconds/10 so the duration-weighted mean is exercised.
    segs = [_seg(0, 2, "You"), _seg(2, 5, "Speaker 1"), _seg(5, 9, "You")]
    monkeypatch.setattr(emo.os.path, "exists", lambda p: True)
    monkeypatch.setattr(emo, "_read_audio", lambda path: (np.zeros(16000 * 20, np.float32), 16000))

    def fake_predict(signal, sr):
        valence = (len(signal) / sr) / 10.0  # 2s->0.2, 4s->0.4, 3s->0.3
        return (valence, 0.6, 0.5)

    monkeypatch.setattr(emo, "predict_vad", fake_predict)
    out = compute_speaker_emotion(segs, "/tmp/sess.wav")
    assert set(out) == {"You", "Speaker 1"}
    # You weighted mean = (0.2*2 + 0.4*4) / 6 = 0.3333
    assert abs(out["You"].valence - 0.3333) < 0.01
    assert abs(out["Speaker 1"].valence - 0.3) < 0.01  # single 3s segment


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


def test_compute_speaker_emotion_budget_cap(monkeypatch):
    # A single 400s segment exceeds the 300s/speaker budget; result still produced.
    segs = [_seg(0, 400, "You")]
    monkeypatch.setattr(emo.os.path, "exists", lambda p: True)
    monkeypatch.setattr(emo, "_read_audio", lambda path: (np.zeros(16000 * 400, np.float32), 16000))
    monkeypatch.setattr(emo, "predict_vad", lambda s, sr: (0.7, 0.6, 0.5))
    out = compute_speaker_emotion(segs, "/tmp/sess.wav")
    assert "You" in out
    assert abs(out["You"].valence - 0.7) < 1e-6


def test_compute_speaker_emotion_read_failure_degrades(monkeypatch):
    segs = [_seg(0, 3, "You"), _seg(3, 6, "Speaker 1")]
    monkeypatch.setattr(emo.os.path, "exists", lambda p: True)

    def flaky_read(path):
        if "mic" in path:
            raise OSError("mic stem missing")
        return (np.zeros(16000 * 10, np.float32), 16000)

    monkeypatch.setattr(emo, "_read_audio", flaky_read)
    monkeypatch.setattr(emo, "predict_vad", lambda s, sr: (0.6, 0.5, 0.5))
    out = compute_speaker_emotion(segs, "/tmp/sess.wav")
    assert "You" not in out      # failed mic read dropped this speaker
    assert "Speaker 1" in out    # other speaker unaffected

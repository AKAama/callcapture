from app.analyze.metrics import compute_speaker_stats
from app.schemas.models import TranscriptSegment


def seg(start, end, text, speaker):
    return TranscriptSegment(start=start, end=end, text=text, speaker=speaker)


def test_two_speakers_basic_metrics():
    segments = [
        seg(0.0, 10.0, "one two three", "You"),       # 10s, 3 words
        seg(10.0, 30.0, "a b c d e f", "Speaker 1"),  # 20s, 6 words
    ]
    stats = compute_speaker_stats(segments)
    by = {s.label: s for s in stats}
    assert by["You"].talk_seconds == 10.0
    assert by["Speaker 1"].talk_seconds == 20.0
    assert abs(by["You"].talk_ratio - (10 / 30)) < 1e-6
    assert by["You"].words == 3
    assert abs(by["You"].words_per_min - (3 / (10 / 60))) < 1e-6
    assert by["You"].turns == 1
    assert by["Speaker 1"].turns == 1
    assert by["You"].longest_monologue_sec == 10.0


def test_turns_count_floor_changes():
    segments = [
        seg(0, 1, "x", "You"),
        seg(1, 2, "x", "Speaker 1"),
        seg(2, 3, "x", "You"),       # You takes the floor again -> 2 turns
    ]
    by = {s.label: s for s in compute_speaker_stats(segments)}
    assert by["You"].turns == 2
    assert by["Speaker 1"].turns == 1


def test_empty_segments():
    assert compute_speaker_stats([]) == []


def test_is_self_flag():
    segments = [seg(0, 1, "x", "You")]
    stats = compute_speaker_stats(segments, self_label="You")
    assert stats[0].is_self is True

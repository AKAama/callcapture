from app.analyze.attribution import attribute_segments
from app.schemas.models import DiarizationTurn, TranscriptSegment


def seg(start, end, text="x"):
    return TranscriptSegment(start=start, end=end, text=text)


def test_mic_segments_are_self():
    mic = [seg(0, 2), seg(3, 4)]
    out = attribute_segments(mic_segments=mic, system_segments=[], turns=None, self_label="You")
    assert all(s.speaker == "You" for s in out)
    assert [s.start for s in out] == [0, 3]


def test_system_without_turns_is_single_speaker():
    syss = [seg(0, 2), seg(2, 4)]
    out = attribute_segments(mic_segments=[], system_segments=syss, turns=None, self_label="You")
    assert all(s.speaker == "Speaker 1" for s in out)


def test_system_attributed_by_max_overlap():
    syss = [seg(0.0, 1.0), seg(1.5, 3.0)]
    turns = [
        DiarizationTurn(speaker="Speaker 1", start=0.0, end=1.2),
        DiarizationTurn(speaker="Speaker 2", start=1.2, end=3.5),
    ]
    out = attribute_segments(mic_segments=[], system_segments=syss, turns=turns, self_label="You")
    assert out[0].speaker == "Speaker 1"
    assert out[1].speaker == "Speaker 2"


def test_merged_output_sorted_by_start():
    mic = [seg(0.0, 1.0, "me")]
    syss = [seg(0.5, 2.0, "them")]
    out = attribute_segments(mic_segments=mic, system_segments=syss, turns=None, self_label="You")
    assert [s.start for s in out] == [0.0, 0.5]
    assert out[0].speaker == "You" and out[1].speaker == "Speaker 1"

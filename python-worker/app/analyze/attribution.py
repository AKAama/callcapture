"""Assigns speaker labels to transcript segments."""

from __future__ import annotations

from app.schemas.models import DiarizationTurn, TranscriptSegment

_DEFAULT_REMOTE_SPEAKER = "Speaker 1"


def _overlap(a_start: float, a_end: float, b_start: float, b_end: float) -> float:
    return max(0.0, min(a_end, b_end) - max(a_start, b_start))


def _label_for(segment: TranscriptSegment, turns: list[DiarizationTurn]) -> str:
    best_label = _DEFAULT_REMOTE_SPEAKER
    best_overlap = 0.0
    for turn in turns:
        ov = _overlap(segment.start, segment.end, turn.start, turn.end)
        if ov > best_overlap:
            best_overlap = ov
            best_label = turn.speaker
    return best_label


def attribute_segments(
    mic_segments: list[TranscriptSegment],
    system_segments: list[TranscriptSegment],
    turns: list[DiarizationTurn] | None,
    self_label: str = "You",
) -> list[TranscriptSegment]:
    """Label mic segments as `self_label` and system segments by diarization
    overlap (or a single remote speaker when no turns), merged and sorted by start.
    """
    labeled: list[TranscriptSegment] = []
    for s in mic_segments:
        labeled.append(s.model_copy(update={"speaker": self_label}))
    for s in system_segments:
        label = _label_for(s, turns) if turns else _DEFAULT_REMOTE_SPEAKER
        labeled.append(s.model_copy(update={"speaker": label}))
    labeled.sort(key=lambda seg: seg.start)
    return labeled

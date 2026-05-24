"""Computes per-speaker talk metrics from attributed transcript segments."""

from __future__ import annotations

from app.schemas.models import SpeakerStats, TranscriptSegment


def compute_speaker_stats(
    segments: list[TranscriptSegment],
    self_label: str = "You",
) -> list[SpeakerStats]:
    """Aggregate per-speaker talk metrics from speaker-attributed segments.

    `segments` should be ordered by start time. Speakers are returned in order of
    first appearance.
    """
    if not segments:
        return []

    total_speech = sum(max(0.0, s.end - s.start) for s in segments) or 1.0

    order: list[str] = []
    seconds: dict[str, float] = {}
    words: dict[str, int] = {}
    longest: dict[str, float] = {}
    turns: dict[str, int] = {}
    prev_speaker: str | None = None

    for s in segments:
        label = s.speaker or "Speaker 1"
        if label not in seconds:
            order.append(label)
            seconds[label] = 0.0
            words[label] = 0
            longest[label] = 0.0
            turns[label] = 0
        dur = max(0.0, s.end - s.start)
        seconds[label] += dur
        words[label] += len(s.text.split())
        longest[label] = max(longest[label], dur)
        if label != prev_speaker:
            turns[label] += 1
        prev_speaker = label

    stats: list[SpeakerStats] = []
    for label in order:
        secs = seconds[label]
        wpm = words[label] / (secs / 60.0) if secs > 0 else 0.0
        stats.append(SpeakerStats(
            label=label,
            is_self=(label == self_label),
            talk_seconds=round(secs, 2),
            talk_ratio=round(secs / total_speech, 6),
            words=words[label],
            words_per_min=round(wpm, 1),
            turns=turns[label],
            longest_monologue_sec=round(longest[label], 2),
        ))
    return stats

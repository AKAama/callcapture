"""Render MarkdownNote into formatted markdown strings."""

from __future__ import annotations

from datetime import datetime, timezone

from app.schemas.models import (
    Insights,
    MarkdownNote,
    Sentiment,
    SpeakerStats,
    TranscriptSegment,
)


def _render_meeting_notes(note: MarkdownNote) -> str:
    """Concise meeting notes format."""
    lines: list[str] = [
        f"# {note.title}",
        "",
        f"**Summary:** {note.summary}",
        "",
    ]

    if note.key_points:
        lines.append("## Key Points")
        for point in note.key_points:
            lines.append(f"- {point}")
        lines.append("")

    if note.decisions:
        lines.append("## Decisions")
        for decision in note.decisions:
            lines.append(f"- {decision}")
        lines.append("")

    if note.action_items:
        lines.append("## Action Items")
        for item in note.action_items:
            lines.append(item if item else "")
        lines.append("")

    return "\n".join(lines)


def _render_full_transcript(note: MarkdownNote) -> str:
    """Full transcript with all segments included."""
    lines: list[str] = [
        f"# {note.title}",
        "",
        f"**Summary:** {note.summary}",
        "",
    ]

    if note.key_points:
        lines.append("## Key Points")
        for point in note.key_points:
            lines.append(f"- {point}")
        lines.append("")

    if note.decisions:
        lines.append("## Decisions")
        for decision in note.decisions:
            lines.append(f"- {decision}")
        lines.append("")

    if note.action_items:
        lines.append("## Action Items")
        for item in note.action_items:
            lines.append(item if item else "")
        lines.append("")

    if note.transcript_segments:
        lines.append("## Full Transcript")
        lines.append("")
        for seg in note.transcript_segments:
            speaker = f"**{seg.speaker}:** " if seg.speaker else ""
            lines.append(f"`[{seg.start:.1f}s - {seg.end:.1f}s]` {speaker}{seg.text}")
            lines.append("")

    return "\n".join(lines)


def _render_obsidian(note: MarkdownNote) -> str:
    """Obsidian format with YAML frontmatter."""
    now = datetime.now(tz=timezone.utc).strftime("%Y-%m-%d")

    duration_min = 0.0
    if note.transcript_segments:
        last = note.transcript_segments[-1]
        duration_min = last.end / 60.0

    frontmatter_lines: list[str] = [
        "---",
        f"title: \"{note.title}\"",
        f"date: {now}",
        "tags:",
        "  - call-notes",
        "  - auto-generated",
        f"duration_min: {duration_min:.1f}",
        "---",
    ]

    body = _render_meeting_notes(note)
    return "\n".join(frontmatter_lines) + "\n\n" + body


_RENDERERS = {
    "meeting_notes": _render_meeting_notes,
    "full_transcript": _render_full_transcript,
    "obsidian": _render_obsidian,
}


def render_markdown(note: MarkdownNote, profile: str = "meeting_notes") -> str:
    """Render a MarkdownNote using the specified profile.

    Args:
        note: The structured note to render.
        profile: One of "meeting_notes", "full_transcript", "obsidian".

    Returns:
        Formatted markdown string.

    Raises:
        ValueError: If the profile is unknown.
    """
    renderer = _RENDERERS.get(profile)
    if renderer is None:
        raise ValueError(f"Unknown profile: {profile!r}. Supported: {list(_RENDERERS)}")
    return renderer(note)


def _bullets(items: list[str]) -> list[str]:
    """Return '- item' lines, skipping empty strings."""
    return [f"- {it}" for it in items if it]


def _checkbox_items(items: list[str]) -> list[str]:
    """Return '- [ ] item' task lines, skipping empty strings."""
    return [f"- [ ] {it}" for it in items if it]


def _section(heading: str, items: list[str]) -> list[str]:
    """A '## Heading' block with its items, or [] when there are no items."""
    if not items:
        return []
    return [heading, "", *items, ""]


def _frontmatter(
    recording_type: str,
    insights: Insights,
    sentiment: Sentiment | None,
    speakers: list[SpeakerStats],
    segments: list[TranscriptSegment],
) -> list[str]:
    """YAML frontmatter lines; `participants` and `sentiment` are omitted when absent."""
    now = datetime.now(tz=timezone.utc).strftime("%Y-%m-%d")
    duration_min = segments[-1].end / 60.0 if segments else 0.0
    safe_title = insights.title.replace('"', '\\"')
    lines = [
        "---",
        f'title: "{safe_title}"',
        f"date: {now}",
        f"recording_type: {recording_type}",
        f"num_speakers: {len(speakers)}",
    ]
    if speakers:
        lines.append("participants:")
        for s in speakers:
            lines.append(f"  - {s.label}")
    if sentiment is not None:
        lines.append(f"sentiment: {sentiment.overall} ({sentiment.overall_score:+.2f})")
    lines += [
        "tags:",
        "  - call-notes",
        "  - auto-generated",
        f"duration_min: {duration_min:.1f}",
        "---",
    ]
    return lines


def _participants_table(speakers: list[SpeakerStats]) -> list[str]:
    if not speakers:
        return []
    show_tone = any(s.dominant_emotion for s in speakers)
    header = "| Speaker | Talk % | Words | WPM | Turns |"
    divider = "|---------|-------:|------:|----:|------:|"
    if show_tone:
        header += " Tone |"
        divider += "------|"
    lines = ["## Participants", "", header, divider]
    for s in speakers:
        row = (
            f"| {s.label} | {s.talk_ratio * 100:.0f}% | {s.words} | "
            f"{s.words_per_min:.0f} | {s.turns} |"
        )
        if show_tone:
            row += f" {s.dominant_emotion or '-'} |"
        lines.append(row)
    lines.append("")
    return lines


def _sentiment_section(sentiment: Sentiment | None) -> list[str]:
    if sentiment is None:
        return []
    lines = [
        "## Sentiment",
        "",
        f"**Overall:** {sentiment.overall} ({sentiment.overall_score:+.2f})",
    ]
    if sentiment.by_speaker:
        lines.append("")
        for label, sp in sentiment.by_speaker.items():
            lines.append(f"- **{label}:** {sp.label} ({sp.score:+.2f})")
    lines.append("")
    return lines


def _transcript_section(segments: list[TranscriptSegment]) -> list[str]:
    if not segments:
        return []
    lines = ["## Transcript", ""]
    for seg in segments:
        speaker = f"**{seg.speaker}:** " if seg.speaker else ""
        lines.append(f"`[{seg.start:.1f}s - {seg.end:.1f}s]` {speaker}{seg.text}")
        lines.append("")
    return lines


def _render_call_body(
    insights: Insights,
    sentiment: Sentiment | None,
    speakers: list[SpeakerStats],
    segments: list[TranscriptSegment],
) -> list[str]:
    body: list[str] = [f"# {insights.title}", ""]
    if insights.summary:
        body += [f"**Summary:** {insights.summary}", ""]
    body += _participants_table(speakers)
    body += _sentiment_section(sentiment)

    insight_lines: list[str] = []
    if insights.dynamics:
        insight_lines += [insights.dynamics, ""]
    insight_lines += _section("### Opportunities", _bullets(insights.opportunities))
    insight_lines += _section("### Recommended Actions", _bullets(insights.recommended_actions))
    insight_lines += _section("### Action Items", _checkbox_items(insights.action_items))
    if insight_lines:
        body += ["## Conversation Insights", "", *insight_lines]

    body += _transcript_section(segments)
    return body


def _render_memo_body(
    insights: Insights,
    _sentiment: Sentiment | None,
    _speakers: list[SpeakerStats],
    _segments: list[TranscriptSegment],
) -> list[str]:
    body: list[str] = [f"# {insights.title}", ""]
    body += _section("## Summary", [insights.summary] if insights.summary else [])
    body += _section("## Key Points", _bullets(insights.key_points))
    body += _section("## Action Items", _checkbox_items(insights.action_items))
    body += _section("## Reflections", _bullets(insights.reflections))
    return body


def _render_lecture_body(
    insights: Insights,
    _sentiment: Sentiment | None,
    _speakers: list[SpeakerStats],
    _segments: list[TranscriptSegment],
) -> list[str]:
    body: list[str] = [f"# {insights.title}", ""]
    body += _section("## Outline", _bullets(insights.outline))
    body += _section("## Key Concepts", _bullets(insights.key_concepts))
    body += _section("## Summary", [insights.summary] if insights.summary else [])
    body += _section("## Q&A", _bullets(insights.qa))
    body += _section("## Takeaways", _bullets(insights.takeaways))
    return body


_NOTE_RENDERERS = {
    "call_meeting": _render_call_body,
    "voice_memo": _render_memo_body,
    "lecture": _render_lecture_body,
}


def render_note(
    recording_type: str,
    insights: Insights | None,
    sentiment: Sentiment | None,
    speakers: list[SpeakerStats],
    segments: list[TranscriptSegment],
) -> str:
    """Render the per-type Markdown note (frontmatter + body).

    Unknown `recording_type` falls back to the call/meeting shape. A None `insights`
    is treated as an empty `Insights` so the note still renders (minimal).
    """
    ins = insights if insights is not None else Insights()
    renderer = _NOTE_RENDERERS.get(recording_type, _render_call_body)
    body = renderer(ins, sentiment, speakers, segments)
    frontmatter = "\n".join(
        _frontmatter(recording_type, ins, sentiment, speakers, segments)
    )
    return f"{frontmatter}\n\n" + "\n".join(body)

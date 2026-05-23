"""Render MarkdownNote into formatted markdown strings."""

from __future__ import annotations

from datetime import datetime, timezone

from app.schemas.models import MarkdownNote


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

"""Tests for markdown rendering across profiles."""

from __future__ import annotations

import pytest

from app.postprocess.formatter import render_markdown
from app.schemas.models import MarkdownNote, TranscriptSegment


@pytest.fixture
def sample_note() -> MarkdownNote:
    """A sample MarkdownNote for rendering tests."""
    return MarkdownNote(
        title="Sprint Planning Call",
        summary="Discussed Q3 priorities and assigned tasks.",
        key_points=["Focus on performance", "Hiring two engineers"],
        decisions=["Ship v2.0 by August"],
        action_items=["- [ ] Draft roadmap", "- [ ] Schedule interviews"],
        transcript_segments=[
            TranscriptSegment(start=0.0, end=5.0, text="Hello everyone.", speaker="Alice"),
            TranscriptSegment(start=5.0, end=12.0, text="Let's review the plan.", speaker="Bob"),
            TranscriptSegment(start=12.0, end=60.0, text="Sounds good.", speaker=None),
        ],
    )


@pytest.fixture
def minimal_note() -> MarkdownNote:
    """A minimal note with no optional fields."""
    return MarkdownNote(title="Quick Call", summary="Brief chat.")


class TestMeetingNotesProfile:
    """Tests for the meeting_notes profile."""

    def test_contains_title(self, sample_note: MarkdownNote) -> None:
        result = render_markdown(sample_note, "meeting_notes")
        assert "# Sprint Planning Call" in result

    def test_contains_summary(self, sample_note: MarkdownNote) -> None:
        result = render_markdown(sample_note, "meeting_notes")
        assert "**Summary:** Discussed Q3" in result

    def test_contains_key_points(self, sample_note: MarkdownNote) -> None:
        result = render_markdown(sample_note, "meeting_notes")
        assert "## Key Points" in result
        assert "- Focus on performance" in result

    def test_contains_action_items(self, sample_note: MarkdownNote) -> None:
        result = render_markdown(sample_note, "meeting_notes")
        assert "## Action Items" in result
        assert "- [ ] Draft roadmap" in result

    def test_no_transcript_in_meeting_notes(self, sample_note: MarkdownNote) -> None:
        result = render_markdown(sample_note, "meeting_notes")
        assert "Full Transcript" not in result

    def test_minimal_note(self, minimal_note: MarkdownNote) -> None:
        result = render_markdown(minimal_note, "meeting_notes")
        assert "# Quick Call" in result
        assert "Key Points" not in result


class TestFullTranscriptProfile:
    """Tests for the full_transcript profile."""

    def test_contains_transcript_section(self, sample_note: MarkdownNote) -> None:
        result = render_markdown(sample_note, "full_transcript")
        assert "## Full Transcript" in result

    def test_contains_speaker_labels(self, sample_note: MarkdownNote) -> None:
        result = render_markdown(sample_note, "full_transcript")
        assert "**Alice:**" in result
        assert "**Bob:**" in result

    def test_contains_timestamps(self, sample_note: MarkdownNote) -> None:
        result = render_markdown(sample_note, "full_transcript")
        assert "`[0.0s - 5.0s]`" in result

    def test_segment_without_speaker(self, sample_note: MarkdownNote) -> None:
        result = render_markdown(sample_note, "full_transcript")
        assert "Sounds good." in result


class TestObsidianProfile:
    """Tests for the obsidian profile with YAML frontmatter."""

    def test_has_frontmatter_delimiters(self, sample_note: MarkdownNote) -> None:
        result = render_markdown(sample_note, "obsidian")
        assert result.startswith("---\n")
        assert "\n---\n" in result

    def test_frontmatter_title(self, sample_note: MarkdownNote) -> None:
        result = render_markdown(sample_note, "obsidian")
        assert 'title: "Sprint Planning Call"' in result

    def test_frontmatter_date(self, sample_note: MarkdownNote) -> None:
        result = render_markdown(sample_note, "obsidian")
        assert "date: " in result

    def test_frontmatter_tags(self, sample_note: MarkdownNote) -> None:
        result = render_markdown(sample_note, "obsidian")
        assert "  - call-notes" in result
        assert "  - auto-generated" in result

    def test_frontmatter_duration(self, sample_note: MarkdownNote) -> None:
        result = render_markdown(sample_note, "obsidian")
        assert "duration_min: 1.0" in result

    def test_body_follows_frontmatter(self, sample_note: MarkdownNote) -> None:
        result = render_markdown(sample_note, "obsidian")
        parts = result.split("---\n")
        body = parts[2]
        assert "# Sprint Planning Call" in body

    def test_minimal_note_duration_zero(self, minimal_note: MarkdownNote) -> None:
        result = render_markdown(minimal_note, "obsidian")
        assert "duration_min: 0.0" in result


class TestUnknownProfile:
    """Tests for unknown profile handling."""

    def test_raises_on_unknown(self, sample_note: MarkdownNote) -> None:
        with pytest.raises(ValueError, match="Unknown profile"):
            render_markdown(sample_note, "unknown_profile")

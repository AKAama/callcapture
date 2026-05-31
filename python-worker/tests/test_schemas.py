"""Tests for Pydantic schema models."""

from __future__ import annotations

import pytest
from pydantic import ValidationError

from app.schemas.models import (
    JobRequest,
    JobResult,
    MarkdownNote,
    ProgressUpdate,
    TranscriptSegment,
)


class TestJobRequest:
    """Tests for JobRequest validation."""

    def test_valid_minimal_request(self) -> None:
        req = JobRequest(
            job_id="abc-123",
            command="transcribe",
            audio_path="/tmp/test.wav",
        )
        assert req.job_id == "abc-123"
        assert req.command == "transcribe"
        assert req.engine == "local_whisper"
        assert req.language == "auto"
        assert req.whisper_model == "base"

    def test_valid_full_request(self) -> None:
        req = JobRequest(
            job_id="def-456",
            command="postprocess",
            audio_path="/tmp/test.wav",
            engine="remote",
            language="en",
            markdown_profile="obsidian",
            whisper_model="large",
            llm_engine="claude",
            remote_provider="openai",
        )
        assert req.engine == "remote"
        assert req.markdown_profile == "obsidian"

    def test_invalid_command(self) -> None:
        with pytest.raises(ValidationError, match="command"):
            JobRequest(
                job_id="x",
                command="invalid",  # type: ignore[arg-type]
                audio_path="/tmp/test.wav",
            )

    def test_invalid_engine(self) -> None:
        with pytest.raises(ValidationError, match="engine"):
            JobRequest(
                job_id="x",
                command="transcribe",
                audio_path="/tmp/test.wav",
                engine="gpu_whisper",  # type: ignore[arg-type]
            )

    def test_frozen(self) -> None:
        req = JobRequest(job_id="x", command="transcribe", audio_path="/tmp/t.wav")
        with pytest.raises(ValidationError):
            req.job_id = "y"  # type: ignore[misc]

    def test_from_json(self) -> None:
        raw = '{"job_id": "j1", "command": "transcribe", "audio_path": "/a.wav"}'
        req = JobRequest.model_validate_json(raw)
        assert req.job_id == "j1"


class TestMarkdownNote:
    """Tests for MarkdownNote validators."""

    def test_valid_note(self) -> None:
        note = MarkdownNote(
            title="Test Call",
            summary="Short summary.",
            key_points=["Point 1"],
            decisions=["Decision 1"],
            action_items=["- [ ] Do something"],
        )
        assert note.title == "Test Call"
        assert len(note.action_items) == 1

    def test_summary_too_long(self) -> None:
        with pytest.raises(ValidationError, match="summary must be <500"):
            MarkdownNote(
                title="Test",
                summary="x" * 501,
            )

    def test_summary_at_limit(self) -> None:
        note = MarkdownNote(title="T", summary="x" * 500)
        assert len(note.summary) == 500

    def test_action_item_valid_pattern(self) -> None:
        note = MarkdownNote(
            title="T",
            summary="s",
            action_items=["- [ ] Task one", "- [ ] Task two"],
        )
        assert len(note.action_items) == 2

    def test_action_item_empty_string_allowed(self) -> None:
        note = MarkdownNote(
            title="T",
            summary="s",
            action_items=["", "- [ ] Real task"],
        )
        assert note.action_items[0] == ""

    def test_action_item_invalid_pattern(self) -> None:
        with pytest.raises(ValidationError, match="action_item must match"):
            MarkdownNote(
                title="T",
                summary="s",
                action_items=["Buy groceries"],
            )

    def test_action_item_wrong_checkbox(self) -> None:
        with pytest.raises(ValidationError, match="action_item must match"):
            MarkdownNote(
                title="T",
                summary="s",
                action_items=["- [x] Already done"],
            )

    def test_frozen(self) -> None:
        note = MarkdownNote(title="T", summary="s")
        with pytest.raises(ValidationError):
            note.title = "New"  # type: ignore[misc]

    def test_with_transcript_segments(self) -> None:
        seg = TranscriptSegment(start=0.0, end=5.0, text="Hello", speaker="Alice")
        note = MarkdownNote(
            title="T",
            summary="s",
            transcript_segments=[seg],
        )
        assert len(note.transcript_segments) == 1
        assert note.transcript_segments[0].speaker == "Alice"


class TestProgressUpdate:
    """Tests for ProgressUpdate validation."""

    def test_valid(self) -> None:
        p = ProgressUpdate(job_id="j1", progress=0.5, stage="transcribing")
        assert p.progress == 0.5

    def test_progress_bounds(self) -> None:
        with pytest.raises(ValidationError):
            ProgressUpdate(job_id="j1", progress=1.5, stage="x")

        with pytest.raises(ValidationError):
            ProgressUpdate(job_id="j1", progress=-0.1, stage="x")


class TestJobResult:
    """Tests for JobResult validation."""

    def test_completed(self) -> None:
        r = JobResult(
            job_id="j1",
            status="completed",
            raw_transcript_path="/tmp/t.json",
            markdown_path="/tmp/n.md",
            duration_sec=120.5,
        )
        assert r.status == "completed"
        assert r.warnings == []

    def test_error(self) -> None:
        r = JobResult(
            job_id="j1",
            status="error",
            error_message="Something broke",
            warnings=["w1"],
        )
        assert r.error_message == "Something broke"


def test_jobrequest_defaults_cost_rate_fields():
    from app.schemas.models import JobRequest
    req = JobRequest(job_id="x", command="transcribe", audio_path="/a.wav")
    assert req.stt_rates_per_min == {}
    assert req.llm_fallback_rate_per_1m is None


def test_jobrequest_accepts_rate_fields():
    from app.schemas.models import JobRequest
    req = JobRequest.model_validate_json(
        '{"job_id":"x","command":"transcribe","audio_path":"/a.wav",'
        '"stt_rates_per_min":{"assemblyai":0.01},"llm_fallback_rate_per_1m":2.5}'
    )
    assert req.stt_rates_per_min["assemblyai"] == 0.01
    assert req.llm_fallback_rate_per_1m == 2.5


def test_jobresult_defaults_cost_fields_none():
    from app.schemas.models import JobResult
    r = JobResult(job_id="x", status="completed")
    assert r.cost_transcription is None
    assert r.cost_processing is None
    assert r.cost_currency == "USD"
    assert r.audio_minutes is None
    assert r.llm_tokens is None

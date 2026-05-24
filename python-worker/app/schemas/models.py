"""Pydantic models for the IPC contract between Swift host and Python worker."""

from __future__ import annotations

import re
from typing import Literal

from pydantic import BaseModel, Field, field_validator


class JobRequest(BaseModel, frozen=True):
    """Incoming job request from the Swift host process."""

    job_id: str = Field(description="UUID string identifying this job")
    command: Literal["transcribe", "postprocess", "export"]
    recording_type: Literal["call_meeting", "voice_memo", "lecture"] = "call_meeting"
    audio_path: str
    engine: Literal["local_whisper", "remote"] = "local_whisper"
    language: str = "auto"
    speaker_diarization: bool = False
    markdown_profile: str = "meeting_notes"
    whisper_model: str = "base"
    llm_engine: str = "claude"
    remote_provider: str = "groq"


class ProgressUpdate(BaseModel, frozen=True):
    """Progress update sent to the Swift host on stderr."""

    job_id: str
    progress: float = Field(ge=0.0, le=1.0)
    stage: str
    current_segment: int | None = None


class JobResult(BaseModel, frozen=True):
    """Final result sent to the Swift host on stdout."""

    job_id: str
    status: Literal["completed", "failed", "error"]
    raw_transcript_path: str | None = None
    markdown_path: str | None = None
    analysis_path: str | None = None
    duration_sec: float | None = None
    warnings: list[str] = Field(default_factory=list)
    error_message: str | None = None


class TranscriptSegment(BaseModel, frozen=True):
    """A single segment of transcribed audio."""

    start: float
    end: float
    text: str
    speaker: str | None = None


class DiarizationTurn(BaseModel, frozen=True):
    """A single speaker turn from the diarization sidecar (system stem)."""

    speaker: str
    start: float
    end: float


class SpeakerStats(BaseModel, frozen=True):
    """Per-speaker talk metrics."""

    label: str
    is_self: bool = False
    talk_seconds: float = 0.0
    talk_ratio: float = 0.0
    words: int = 0
    words_per_min: float = 0.0
    turns: int = 0
    longest_monologue_sec: float = 0.0


class ConversationAnalysis(BaseModel, frozen=True):
    """Per-recording conversation analysis (Phase 3a: speakers + talk metrics)."""

    recording_type: str = "call_meeting"
    num_speakers: int = 0
    speakers: list[SpeakerStats] = Field(default_factory=list)
    warnings: list[str] = Field(default_factory=list)


_ACTION_ITEM_RE = re.compile(r"^- \[ \] .+$")


class MarkdownNote(BaseModel, frozen=True):
    """Structured note extracted from a transcript by the LLM postprocessor."""

    title: str
    summary: str
    key_points: list[str] = Field(default_factory=list)
    decisions: list[str] = Field(default_factory=list)
    action_items: list[str] = Field(default_factory=list)
    transcript_segments: list[TranscriptSegment] = Field(default_factory=list)

    @field_validator("summary")
    @classmethod
    def summary_must_be_short(cls, v: str) -> str:
        if len(v) > 500:
            raise ValueError("summary must be <500 characters")
        return v

    @field_validator("action_items")
    @classmethod
    def action_items_must_match_pattern(cls, v: list[str]) -> list[str]:
        for item in v:
            if item == "":
                continue
            if not _ACTION_ITEM_RE.match(item):
                raise ValueError(
                    f"action_item must match '- [ ] ...' pattern, got: {item!r}"
                )
        return v

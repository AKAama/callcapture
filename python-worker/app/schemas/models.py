"""Pydantic models for the IPC contract between Swift host and Python worker."""

from __future__ import annotations

import re
from typing import Literal

from pydantic import BaseModel, Field, field_validator


class JobRequest(BaseModel, frozen=True):
    """Incoming job request from the Swift host process."""

    job_id: str = Field(description="UUID string identifying this job")
    command: Literal["transcribe", "postprocess", "export", "prepare_emotion"]
    recording_type: Literal["call_meeting", "voice_memo", "lecture"] = "call_meeting"
    audio_path: str
    engine: Literal["local_whisper", "remote"] = "local_whisper"
    language: str = "auto"
    notes_language: str = "auto"
    markdown_profile: str = "meeting_notes"
    whisper_model: str = "base"
    llm_engine: str = "claude"
    remote_provider: str = "groq"
    stt_rates_per_min: dict[str, float] = Field(default_factory=dict)
    llm_fallback_rate_per_1m: float | None = None


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
    cost_transcription: float | None = None
    cost_processing: float | None = None
    cost_currency: str = "USD"
    audio_minutes: float | None = None
    llm_tokens: int | None = None
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
    dominant_emotion: str | None = None
    valence: float | None = None
    arousal: float | None = None


class SpeakerSentiment(BaseModel, frozen=True):
    """Per-speaker sentiment from the LLM."""

    label: str = "neutral"  # positive | neutral | negative | mixed
    score: float = 0.0       # -1.0 (very negative) .. 1.0 (very positive)


class ArcPoint(BaseModel, frozen=True):
    """One point on the conversation emotional arc (acoustic valence over time)."""

    t: float       # window-center seconds
    score: float   # valence centered to -1..1


class Sentiment(BaseModel, frozen=True):
    """Conversation sentiment (Phase 4a: text/LLM; `arc` populated in Phase 4b)."""

    overall: str = "neutral"  # positive | neutral | negative | mixed
    overall_score: float = 0.0
    by_speaker: dict[str, SpeakerSentiment] = Field(default_factory=dict)
    arc: list[ArcPoint] = Field(default_factory=list)


class Insights(BaseModel, frozen=True):
    """Type-tailored conversation insights (Phase 5).

    Flat superset: every field is optional with an empty default. Each recording type
    fills only its relevant subset (call: dynamics/opportunities/recommended_actions/
    action_items; voice_memo: key_points/action_items/reflections; lecture: outline/
    key_concepts/qa/takeaways). `summary` and `title` are shared by all types.
    """

    title: str = "Untitled"
    summary: str = ""
    key_points: list[str] = Field(default_factory=list)
    action_items: list[str] = Field(default_factory=list)
    recommended_actions: list[str] = Field(default_factory=list)
    dynamics: str = ""
    opportunities: list[str] = Field(default_factory=list)
    reflections: list[str] = Field(default_factory=list)
    outline: list[str] = Field(default_factory=list)
    key_concepts: list[str] = Field(default_factory=list)
    qa: list[str] = Field(default_factory=list)
    takeaways: list[str] = Field(default_factory=list)

    @field_validator("summary")
    @classmethod
    def summary_must_be_short(cls, v: str) -> str:
        if len(v) > 500:
            raise ValueError("summary must be <500 characters")
        return v


class ConversationAnalysis(BaseModel, frozen=True):
    """Per-recording conversation analysis (speakers, talk metrics, sentiment, insights)."""

    recording_type: str = "call_meeting"
    num_speakers: int = 0
    speakers: list[SpeakerStats] = Field(default_factory=list)
    warnings: list[str] = Field(default_factory=list)
    sentiment: Sentiment | None = None
    insights: Insights | None = None


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

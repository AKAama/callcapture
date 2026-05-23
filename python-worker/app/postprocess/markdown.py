"""LLM-powered markdown note generation from transcript segments."""

from __future__ import annotations

import json
import os
import sys

from app.postprocess.llm_client import LLMClient, LLMError, OPENROUTER_BASE_URL
from app.schemas.models import MarkdownNote, TranscriptSegment

_SYSTEM_PROMPT = (
    "You are a meeting notes assistant. Given a call transcript, extract structured "
    "information. Output ONLY valid JSON matching this schema:\n"
    '{"title": str, "summary": str (<500 chars), "key_points": [str], '
    '"decisions": [str], "action_items": [str (each starting with "- [ ] " or empty string)]}\n'
    "Rules: No invented facts. Mark unclear text with [unclear]."
)


def _transcript_to_text(segments: list[TranscriptSegment]) -> str:
    """Format transcript segments into plain text for the LLM prompt."""
    lines: list[str] = []
    for seg in segments:
        speaker = f"[{seg.speaker}] " if seg.speaker else ""
        lines.append(f"[{seg.start:.1f}s] {speaker}{seg.text}")
    return "\n".join(lines)


def _fallback_extraction(
    segments: list[TranscriptSegment],
) -> MarkdownNote:
    """Rule-based fallback when no LLM API key is available."""
    texts = [seg.text for seg in segments]
    title = texts[0][:60] if texts else "Untitled Call"
    summary = " ".join(texts)[:499]
    return MarkdownNote(
        title=title,
        summary=summary,
        key_points=texts[:5],
        decisions=[],
        action_items=[],
        transcript_segments=list(segments),
    )


def generate_markdown(
    segments: list[TranscriptSegment],
    profile: str = "meeting_notes",
) -> MarkdownNote:
    """Generate a structured MarkdownNote from transcript segments via the LLM.

    Uses the OpenAI-compatible endpoint described by the LLM_* env vars
    (OpenRouter or a local server). Falls back to rule-based extraction when the
    endpoint is unusable or the call fails.

    Args:
        segments: Transcript segments.
        profile: Markdown profile (used during rendering).
    """
    base_url = os.environ.get("LLM_BASE_URL", OPENROUTER_BASE_URL)
    model = os.environ.get("LLM_MODEL", "google/gemini-2.5-flash")
    api_key = os.environ.get("LLM_API_KEY", "")
    is_local = "openrouter.ai" not in base_url

    if not api_key and not is_local:
        sys.stderr.write(
            json.dumps({"warning": "no LLM_API_KEY for cloud endpoint, using fallback"}) + "\n"
        )
        sys.stderr.flush()
        return _fallback_extraction(segments)

    try:
        client = LLMClient(api_key=api_key, model=model, base_url=base_url)
        transcript_text = _transcript_to_text(segments)
        data = client.complete_json(
            system=_SYSTEM_PROMPT,
            user=f"Transcript:\n\n{transcript_text}",
        )
        return MarkdownNote(
            title=data.get("title", "Untitled"),
            summary=data.get("summary", "")[:499],
            key_points=data.get("key_points", []),
            decisions=data.get("decisions", []),
            action_items=data.get("action_items", []),
            transcript_segments=list(segments),
        )
    except LLMError as exc:
        sys.stderr.write(
            json.dumps({"warning": f"LLM failed: {exc}, using fallback"}) + "\n"
        )
        sys.stderr.flush()
        return _fallback_extraction(segments)

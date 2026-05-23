"""LLM-powered markdown note generation from transcript segments."""

from __future__ import annotations

import json
import os
import sys

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


def _parse_llm_response(raw: str, segments: list[TranscriptSegment]) -> MarkdownNote:
    """Parse LLM JSON response into a MarkdownNote."""
    cleaned = raw.strip()
    if cleaned.startswith("```"):
        lines = cleaned.split("\n")
        lines = [ln for ln in lines if not ln.startswith("```")]
        cleaned = "\n".join(lines)
    data = json.loads(cleaned)
    return MarkdownNote(
        title=data.get("title", "Untitled"),
        summary=data.get("summary", "")[:499],
        key_points=data.get("key_points", []),
        decisions=data.get("decisions", []),
        action_items=data.get("action_items", []),
        transcript_segments=list(segments),
    )


def generate_markdown(
    segments: list[TranscriptSegment],
    profile: str = "meeting_notes",
    llm_engine: str = "claude",
) -> MarkdownNote:
    """Generate a structured MarkdownNote from transcript segments.

    Args:
        segments: List of transcript segments.
        profile: Markdown profile (unused in generation, used in rendering).
        llm_engine: LLM engine to use ("claude" supported).

    Returns:
        A MarkdownNote with extracted information.
    """
    if llm_engine == "claude":
        api_key = os.environ.get("ANTHROPIC_API_KEY", "")
        if not api_key:
            sys.stderr.write('{"warning": "ANTHROPIC_API_KEY not set, using fallback"}\n')
            sys.stderr.flush()
            return _fallback_extraction(segments)

        try:
            import anthropic

            client = anthropic.Anthropic(api_key=api_key)
            transcript_text = _transcript_to_text(segments)

            message = client.messages.create(
                model="claude-sonnet-4-20250514",
                max_tokens=2048,
                system=_SYSTEM_PROMPT,
                messages=[
                    {"role": "user", "content": f"Transcript:\n\n{transcript_text}"},
                ],
            )
            raw_content = message.content[0].text  # type: ignore[union-attr]
            return _parse_llm_response(raw_content, segments)
        except Exception as exc:
            sys.stderr.write(
                json.dumps({"warning": f"LLM call failed: {exc}, using fallback"}) + "\n"
            )
            sys.stderr.flush()
            return _fallback_extraction(segments)

    return _fallback_extraction(segments)

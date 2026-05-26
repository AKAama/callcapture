"""Type-tailored LLM conversation insights (Phase 5).

One LLM pass produces the structured payload that drives both <id>_analysis.json and
the per-type Markdown note. Mirrors app.analyze.sentiment: reuses the shared LLM env
helper and never raises into the pipeline — an unusable endpoint or any failure yields
a rule-based fallback that still renders a (sparse) note.
"""

from __future__ import annotations

from app.postprocess.llm_client import LLMClient, LLMError
from app.postprocess.llm_env import (
    format_speaker_tone_lines,
    resolve_llm_env,
    transcript_text,
    warn,
)
from app.schemas.models import Insights, Sentiment, TranscriptSegment

_CALL_PROMPT = (
    "You are a conversation strategist analyzing a call/meeting transcript. "
    "Output ONLY valid JSON matching this schema:\n"
    '{"title": str, "summary": str (<500 chars), '
    '"dynamics": str (who drove the conversation, momentum shifts, agreement/hesitation), '
    '"opportunities": [str (persuasion openings, unaddressed objections)], '
    '"recommended_actions": [str (next moves)], '
    '"action_items": [str (concrete follow-ups)]}\n'
    "No invented facts. Mark unclear text with [unclear]. No prose outside the JSON."
)

_MEMO_PROMPT = (
    "You are a note-taking assistant for a personal voice memo. "
    "Output ONLY valid JSON matching this schema:\n"
    '{"title": str, "summary": str (<500 chars), '
    '"key_points": [str], "action_items": [str (concrete follow-ups)], '
    '"reflections": [str (open questions, things to revisit)]}\n'
    "No invented facts. Mark unclear text with [unclear]. No prose outside the JSON."
)

_LECTURE_PROMPT = (
    "You are a study assistant summarizing a lecture/talk transcript. "
    "Output ONLY valid JSON matching this schema:\n"
    '{"title": str, "summary": str (<500 chars), '
    '"outline": [str (section headers in order)], '
    '"key_concepts": [str (terms or ideas with a brief gloss)], '
    '"qa": [str (questions raised and their answers, if any)], '
    '"takeaways": [str (what to remember)]}\n'
    "No invented facts. Mark unclear text with [unclear]. No prose outside the JSON."
)

_PROMPTS = {
    "call_meeting": _CALL_PROMPT,
    "voice_memo": _MEMO_PROMPT,
    "lecture": _LECTURE_PROMPT,
}

# Which Insights fields each type may populate; all others keep their defaults.
_FIELDS = {
    "call_meeting": ("dynamics", "opportunities", "recommended_actions", "action_items"),
    "voice_memo": ("key_points", "action_items", "reflections"),
    "lecture": ("outline", "key_concepts", "qa", "takeaways"),
}

# Of the type-specific fields above, which are list[str] (everything except "dynamics").
_LIST_FIELDS = {
    "key_points", "action_items", "recommended_actions", "opportunities",
    "reflections", "outline", "key_concepts", "qa", "takeaways",
}


def _str_list(value: object) -> list[str]:
    if not isinstance(value, list):
        return []
    out: list[str] = []
    for item in value:
        if isinstance(item, str) and item.strip():
            out.append(item.strip())
    return out


def _clean_summary(value: object) -> str:
    return value[:499] if isinstance(value, str) else ""


def _title(value: object, segments: list[TranscriptSegment]) -> str:
    if isinstance(value, str) and value.strip():
        return value.strip()[:120]
    if segments and segments[0].text.strip():
        return segments[0].text.strip()[:60]
    return "Untitled"


def _context_block(sentiment: Sentiment | None, emotion: dict | None) -> str:
    """Optional sentiment + acoustic-tone context so insights reconcile with tone."""
    lines: list[str] = []
    if sentiment is not None:
        lines.append(
            f"Overall sentiment: {sentiment.overall} ({sentiment.overall_score:+.2f})."
        )
    lines.extend(format_speaker_tone_lines(emotion))
    if not lines:
        return ""
    return "Context:\n" + "\n".join(lines) + "\n\n"


def _fallback_insights(segments: list[TranscriptSegment]) -> Insights:
    texts = [s.text for s in segments if s.text.strip()]
    title = (texts[0][:60] if texts else "Untitled") or "Untitled"
    summary = " ".join(texts)[:499]
    return Insights(title=title, summary=summary, key_points=texts[:5])


def _build_insights(
    data: dict, recording_type: str, segments: list[TranscriptSegment]
) -> Insights:
    fields = _FIELDS.get(recording_type, _FIELDS["call_meeting"])
    payload: dict[str, object] = {
        "title": _title(data.get("title"), segments),
        "summary": _clean_summary(data.get("summary")),
    }
    for name in fields:
        raw = data.get(name)
        if name in _LIST_FIELDS:
            payload[name] = _str_list(raw)
        else:  # "dynamics" — the only non-list type-specific field
            payload[name] = raw.strip() if isinstance(raw, str) else ""
    return Insights(**payload)


def analyze_insights(
    segments: list[TranscriptSegment],
    *,
    recording_type: str,
    sentiment: Sentiment | None = None,
    emotion: dict | None = None,
) -> Insights | None:
    """Produce type-tailored Insights from speaker-labeled segments via the LLM.

    Returns None for an empty transcript. Never raises: no API key (cloud) or any
    failure yields a rule-based fallback covering the shared fields.
    """
    if not segments:
        return None

    env = resolve_llm_env()
    if not env.api_key and not env.is_local:
        warn("no LLM_API_KEY for cloud endpoint, using fallback insights")
        return _fallback_insights(segments)

    system = _PROMPTS.get(recording_type, _CALL_PROMPT)
    user = f"{_context_block(sentiment, emotion)}Transcript:\n\n{transcript_text(segments)}"
    try:
        client = LLMClient(api_key=env.api_key, model=env.model, base_url=env.base_url)
        data = client.complete_json(system=system, user=user)
        if not isinstance(data, dict):
            raise LLMError("non-dict JSON from LLM")
        return _build_insights(data, recording_type, segments)
    except (LLMError, ValueError, TypeError, AttributeError, KeyError) as exc:
        warn(f"insights failed: {exc}, using fallback insights")
        return _fallback_insights(segments)

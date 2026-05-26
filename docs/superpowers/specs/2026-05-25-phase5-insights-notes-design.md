# Phase 5 — Type-Tailored Insights + Per-Type Note Shapes (Design)

**Date:** 2026-05-25
**Scope:** Python worker only. No Swift changes. (Phase 6 = Session Detail UI + re-process.)
**Builds on:** Phase 3a (talk metrics), 4a (LLM sentiment), 4b (acoustic emotion). Folds 4a's
minimal `## Sentiment` append into the per-type note.
**Master spec:** `docs/superpowers/specs/2026-05-23-voice-intelligence-design.md` §2, §4(step 6-7), §7, §8.

## 1. Goal

Replace the generic, profile-based Markdown note in the **transcribe pipeline** with a
**recording-type-tailored** note, driven by a single type-aware LLM "insights" pass. The
structured insights are persisted in `<id>_analysis.json` (for the Phase 6 UI) and rendered
into `<id>_notes.md` shaped per type.

Three recording types: `call_meeting`, `voice_memo`, `lecture`.

## 2. Decisions (locked during brainstorming)

1. **Unified type-tailored call.** One LLM pass (`analyze_insights`) produces the full
   per-type payload that drives both `analysis.json` and the note. The legacy generic
   `generate_markdown` / `render_markdown(profile)` path is **retained only for the standalone
   `postprocess` command** (back-compat); the transcribe pipeline no longer uses it. Rationale:
   one LLM call (cost matters — every recording is processed), no conflicting summaries, prompt
   fully tailored per type.
2. **Flat-superset `Insights` schema.** One Pydantic model with every field across all types,
   all optional with empty defaults. The per-type prompt fills its subset; the renderer reads
   only the fields its type needs. Single stable JSON shape for the Phase 6 Swift decoder; strong
   validation; matches the defensive / degrade-gracefully ethos. Cost: a few empty arrays per
   recording.
3. **Extract shared `llm_env.py`.** `markdown.py` and `sentiment.py` currently duplicate the
   LLM env read + `_warn` + transcript formatter; `insights.py` would be a 3rd copy. Extract a
   shared helper now and refactor all three onto it (closes the deferred follow-up).

## 3. Module Layout & Data Flow

```
transcribe pipeline (cli._run_pipeline):
  segments → [emotion if model ready] → sentiment = analyze_sentiment(segments, emotion)
           → insights = analyze_insights(segments, recording_type, sentiment, emotion)
           → ConversationAnalysis{recording_type, speakers, sentiment, insights} → analysis.json
           → render_note(recording_type, insights, sentiment, speakers, segments) → _notes.md

postprocess command: UNCHANGED — generate_markdown + render_markdown(profile)
```

- **New files:** `app/analyze/insights.py`, `app/postprocess/llm_env.py`.
- **Touched:** `app/schemas/models.py`, `app/postprocess/formatter.py`,
  `app/postprocess/markdown.py`, `app/analyze/sentiment.py`, `app/cli.py`.

## 4. Data Model — `Insights`

New, in `app/schemas/models.py`. Frozen; all fields optional with empty defaults.

```python
class Insights(BaseModel, frozen=True):
    title: str = "Untitled"
    summary: str = ""                      # <500 chars (validator)
    key_points: list[str] = []             # memo, lecture
    action_items: list[str] = []           # call, memo — PLAIN text (renderer adds "- [ ] ")
    recommended_actions: list[str] = []    # call
    dynamics: str = ""                     # call: dominance / momentum prose
    opportunities: list[str] = []          # call: persuasion openings / objections
    reflections: list[str] = []            # memo
    outline: list[str] = []                # lecture
    key_concepts: list[str] = []           # lecture
    qa: list[str] = []                     # lecture
    takeaways: list[str] = []              # lecture

    @field_validator("summary")
    @classmethod
    def summary_short(cls, v: str) -> str:
        if len(v) > 500:
            raise ValueError("summary must be <500 characters")
        return v
```

`ConversationAnalysis` gains `insights: Insights | None = None`.

**Note on `action_items`:** stored as plain item text (no `- [ ]` prefix), unlike the existing
`MarkdownNote.action_items` which bakes the checkbox in. The renderer adds the checkbox. This
keeps the data clean and the JSON consumer-friendly.

## 5. `insights.py` Analyzer

```python
def analyze_insights(
    segments: list[TranscriptSegment],
    *,
    recording_type: str,
    sentiment: Sentiment | None = None,
    emotion: dict | None = None,
) -> Insights | None
```

- Empty `segments` → `None`.
- Selects one of **three system prompts** by `recording_type` (default → call). Each prompt asks
  for **only that type's JSON fields**:
  - **call_meeting:** `title, summary, dynamics, opportunities[], recommended_actions[], action_items[]`
  - **voice_memo:** `title, summary, key_points[], action_items[], reflections[]`
  - **lecture:** `title, summary, outline[], key_concepts[], qa[], takeaways[]`
- Builds the user message from `transcript_text(segments)` plus an optional **context block**
  summarizing sentiment + acoustic tone (reuses the `_tone_block` idea from `sentiment.py`) so
  Call dynamics reconcile with how speakers actually sounded. Context is best-effort; absent
  sentiment/emotion just omits it.
- Resolves the endpoint via `resolve_llm_env()`. **No cloud API key (and not local)** →
  rule-based fallback. **`LLMError` / parse / type errors** → rule-based fallback. **Never raises
  into the pipeline.**
- **Defensive parse** (mirrors `sentiment._build_*`): coerce each list field to `list[str]`,
  drop non-str / empty-after-strip entries, clamp `summary` length, default `title`.
- **Rule-based fallback** (`_fallback_insights`): `title` from first segment text (≤60 chars),
  `summary` from joined segment text (≤499), `key_points` = first ~5 segment texts; all
  type-specific extras empty. Produces a sparse but valid note for every type.

## 6. Per-Type Note Rendering — `formatter.render_note`

```python
def render_note(
    recording_type: str,
    insights: Insights | None,
    sentiment: Sentiment | None,
    speakers: list[SpeakerStats],
    segments: list[TranscriptSegment],
) -> str
```

Dispatches on `recording_type` (unknown → call). Empty sections are omitted (as the current
renderer does).

**Frontmatter (all types):**
```yaml
---
title: "<insights.title>"
date: <YYYY-MM-DD>
recording_type: <type>
num_speakers: <n>
participants:
  - <label>
sentiment: <overall> (<+score>)      # omitted if sentiment is None
tags:
  - call-notes
  - auto-generated
duration_min: <from last segment end>
---
```

**Body by type** (empty sections omitted):

| Type | Sections |
|---|---|
| **call_meeting** | `# <title>` → `**Summary:** …` → `## Participants` (talk-ratio table) → `## Sentiment` (overall + per-speaker) → `## Conversation Insights` (`dynamics` prose; `### Opportunities`; `### Recommended Actions`; `### Action Items` as `- [ ]` checkboxes) → `## Transcript` (speaker-labeled, timestamped) |
| **voice_memo** | `# <title>` → `## Summary` → `## Key Points` → `## Action Items` (checkboxes) → `## Reflections` |
| **lecture** | `# <title>` → `## Outline` → `## Key Concepts` → `## Summary` → `## Q&A` → `## Takeaways` |

**Participants table** (call only):

```
| Speaker | Talk % | Words | WPM | Turns | Tone |
|---------|-------:|------:|----:|------:|------|
| You     |   54%  |  812  | 142 |  19   | calm |
```
`Tone` column shown only when `dominant_emotion` is present; otherwise dropped.

**Sentiment section / Transcript section appear in the Call note only** (per master spec §2).
For `voice_memo` / `lecture`, overall sentiment is carried in the **frontmatter only**, and the
full transcript remains available in `<id>_transcript.json` (not duplicated in the note).

## 7. Pipeline Wiring & Cleanup (`cli.py`)

- `_run_pipeline`: after `sentiment` is computed, call
  `insights = analyze_insights(segments, recording_type=request.recording_type, sentiment=sentiment, emotion=emotion_summary or None)`.
- `_write_analysis` gains an `insights` param → `ConversationAnalysis(insights=insights)`.
- Replace `generate_markdown(...)` + `render_markdown(..., profile)` + the
  `render_sentiment_section` append with a single `render_note(...)` call. `arc` continues to be
  merged into `sentiment` before `_write_analysis` (unchanged).
- **Delete `formatter.render_sentiment_section`** (4a placeholder; only caller is the transcribe
  path, now superseded). Its sentiment output is folded into the Call note's `## Sentiment`
  section.
- `JobRequest.markdown_profile` stays (the `postprocess` command still uses it); the transcribe
  path ignores it.
- The `postprocess` command path is untouched.

## 8. `llm_env.py` Extraction

```python
@dataclass(frozen=True)
class LlmEnv:
    base_url: str
    model: str
    api_key: str
    is_local: bool

def resolve_llm_env() -> LlmEnv:
    """Read LLM_BASE_URL / LLM_MODEL / LLM_API_KEY (OpenRouter defaults); is_local = base
    URL is not openrouter.ai."""

def warn(message: str) -> None:
    """Write {"warning": message} JSON line to stderr (the existing _warn behavior)."""

def transcript_text(segments: list[TranscriptSegment], *, timestamps: bool = False) -> str:
    """Speaker-labeled transcript text. timestamps=True prefixes "[12.3s] " (markdown.py's
    format); False is the plain form sentiment.py uses."""
```

- `markdown.py` refactored to use `resolve_llm_env()`, `warn`, `transcript_text(timestamps=True)`.
- `sentiment.py` refactored to use `resolve_llm_env()`, `warn`, `transcript_text()`. Keeps its
  `_tone_block`, `_clamp`, `_norm_label`, `_to_score`, `_build_sentiment` locally.
- `insights.py` uses the shared helpers from the start.
- Existing `markdown` + `sentiment` tests must remain green after the refactor.

## 9. Graceful Degradation

| Failure | Behavior |
|---|---|
| No LLM key (cloud) | `analyze_insights` → rule-based fallback Insights; note still renders per type |
| LLM call / parse error | rule-based fallback; `warn(...)` to stderr |
| Empty transcript | pipeline already returns `failed` before insights (segments guard); `analyze_insights` also returns `None` defensively |
| Emotion model absent | emotion `{}`; insights context block omits tone; Participants `Tone` column dropped |
| Sentiment neutral fallback | unchanged; insights context block omits/uses neutral sentiment |

Insights never hard-fails the job (matches sentiment/emotion).

## 10. Testing (pytest; mock `LLMClient.complete_json`; numpy-only, no network)

- **`Insights` model:** defaults, `summary` length validator, frozen.
- **`analyze_insights`:** per-type prompt selection (assert the right schema keys requested);
  defensive parse (non-str dropped, summary clamped); empty → `None`; no-key → fallback;
  `LLMError` → fallback; sentiment/emotion context present in the user message when provided.
- **`render_note`:** each type's sections present and empty sections omitted; frontmatter fields;
  checkbox rendering for action items; Participants table (with/without Tone); Sentiment +
  Transcript present for call, absent for memo/lecture; unknown type → call shape.
- **`llm_env`:** `resolve_llm_env` reads env + defaults + `is_local` detection;
  `transcript_text` with/without timestamps; `warn` format. Markdown + sentiment regression
  suites stay green.
- **cli pipeline:** insights wired; `analysis.json` carries `insights`; note rendered per
  `recording_type`; job still completes when LLM unavailable.

## 11. Out of Scope

- Swift / SwiftUI changes (Phase 6).
- Two-tier model split (cheap formatter + strong insights model) — documented seam, not built.
- Hierarchical summarization for >30-min transcripts (existing seam; unchanged here).
- Changes to diarization, emotion, metrics, or transcription.

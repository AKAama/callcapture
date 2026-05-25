# Voice Intelligence — Phase 4a: LLM Sentiment (Design)

**Date:** 2026-05-25
**Status:** Approved (pending written-spec review)
**Master spec:** `docs/superpowers/specs/2026-05-23-voice-intelligence-design.md` (§4.5, §7)
**Builds on:** Phase 3a (analysis core: attributed segments + `ConversationAnalysis` + `<id>_analysis.json`) and Phase 3b (real speaker labels), both merged to `main`.

---

## 1. Goal

Add **per-conversation sentiment** to the worker's analysis: an overall sentiment plus
per-speaker sentiment, derived by the LLM from the speaker-labeled transcript, written
into `<id>_analysis.json` and surfaced as a minimal `## Sentiment` section in the note.
Reuses the existing OpenAI-compatible `LLMClient` path (OpenRouter or local) with the
same env contract and graceful fallback as note generation. **Worker-only — no Swift
changes, no new dependencies.**

This is Phase **4a**, the first half of the master spec's Phase 4. Phase **4b**
(acoustic emotion via onnxruntime + the audeering MSP-dim model, per-speaker
valence/arousal, the emotional time `arc`, the model download/consent + reconciliation)
is a separate later cycle. 4a is designed with a forward seam so 4b layers on without
rework.

## 2. Decisions (resolved during brainstorming)

- **Engine:** reuse the `generate_markdown` LLM pattern — read `LLM_BASE_URL` /
  `LLM_MODEL` / `LLM_API_KEY`, call `LLMClient.complete_json`, degrade gracefully. No new
  deps.
- **Split 4a/4b:** ship LLM sentiment now; acoustic emotion is 4b. (User-approved.)
- **`arc` deferred to 4b:** the time arc's natural, cheap source is continuous acoustic
  valence (4b). In 4a the `Sentiment.arc` field exists but stays an empty list. We do
  **not** generate a text-only arc.
- **Sentiment = label + numeric score:** both `overall` and each speaker carry a label
  (`positive`/`neutral`/`negative`/`mixed`) and a score in `-1.0..1.0`.
- **Minimal note section:** append a small `## Sentiment` block (overall + one line per
  speaker) to the rendered note. Full per-type note restructuring is Phase 5; we do not
  touch `MarkdownNote`/`render_markdown` renderers here.
- **Worker-only:** sentiment rides inside `<id>_analysis.json` (Swift already persists
  `analysis_path` from 3a). No Swift/UI work — Session Detail UI is Phase 6.
- **Reconciliation seam:** `analyze_sentiment` takes an optional `emotion=None`
  parameter; 4b will pass per-speaker acoustic emotion so the LLM reconciles tone + text.
  Unused in 4a.

## 3. Schema (`app/schemas/models.py`)

New frozen Pydantic models (after `ConversationAnalysis` or near `SpeakerStats`):

```python
class SpeakerSentiment(BaseModel, frozen=True):
    """Per-speaker sentiment from the LLM."""
    label: str = "neutral"        # positive | neutral | negative | mixed
    score: float = 0.0            # -1.0 (very negative) .. 1.0 (very positive)


class Sentiment(BaseModel, frozen=True):
    """Conversation sentiment (Phase 4a: text/LLM; arc populated in 4b)."""
    overall: str = "neutral"      # positive | neutral | negative | mixed
    overall_score: float = 0.0    # -1.0 .. 1.0
    by_speaker: dict[str, SpeakerSentiment] = Field(default_factory=dict)
    arc: list[float] = Field(default_factory=list)  # empty in 4a; valence arc in 4b
```

`ConversationAnalysis` gains `sentiment: Sentiment | None = None`.

(Note: `arc` is typed `list[float]` for 4a simplicity; if 4b needs `[{t, score}]` points
it will widen the type then. 4a always writes `[]`, so no consumer depends on the shape
yet.)

## 4. `app/analyze/sentiment.py`

```python
def analyze_sentiment(
    segments: list[TranscriptSegment],
    *,
    emotion: dict[str, ...] | None = None,   # reserved for 4b reconciliation; unused now
) -> Sentiment | None:
    ...
```

- Returns `None` if `segments` is empty.
- Builds a speaker-labeled transcript string (reuse the same plain-text formatting idea
  as `markdown._transcript_to_text`).
- Reads `LLM_BASE_URL` / `LLM_MODEL` / `LLM_API_KEY`; if no key on a cloud endpoint,
  return the **neutral fallback** + stderr warning (mirrors `generate_markdown`).
- Calls `LLMClient.complete_json(system=_SENTIMENT_PROMPT, user=transcript)`; validates
  into `Sentiment`. Clamps scores to `[-1, 1]`; coerces unknown labels to `neutral`;
  ignores `by_speaker` keys not present among the transcript's speaker labels.
- On `LLMError` (or any parse/validation failure) → neutral fallback + warning. Never
  raises into the pipeline.

A module-private `_neutral_fallback(segments) -> Sentiment` builds `overall="neutral",
overall_score=0.0` and a neutral `SpeakerSentiment` for each distinct speaker label.

## 5. Sentiment prompt + JSON contract

System prompt (sketch — exact text pinned in the plan): "You are a conversation
sentiment analyst. Given a speaker-labeled transcript, output ONLY JSON:
`{"overall": "positive|neutral|negative|mixed", "overall_score": <float -1..1>,
"by_speaker": {"<speaker label>": {"label": "...", "score": <float -1..1>}}}`. Use the
exact speaker labels from the transcript. No invented content." User message = the
labeled transcript text.

Parsing is defensive: missing fields default to neutral; extra fields ignored; speakers
absent from the LLM output get a neutral entry so every speaker has sentiment.

## 6. Pipeline wiring (`app/cli.py`)

In `_run_pipeline`, after the attributed `segments` exist and **before** `_write_analysis`
writes `<id>_analysis.json` (so sentiment is included in it):
1. `sentiment = analyze_sentiment(segments)`.
2. Pass `sentiment` into `_write_analysis` so the `ConversationAnalysis(...)` it builds
   sets `sentiment=sentiment` (write it to `<id>_analysis.json`).
3. Append a minimal `## Sentiment` section to the rendered note string (a small
   `render_sentiment_section(sentiment) -> str` helper, joined after the existing
   rendered markdown). The section lists the overall label/score and one line per
   speaker; rendered only when `sentiment` is not `None`.

Existing transcription/attribution/metrics behavior is unchanged.

## 7. Error handling / degradation

- No LLM key (cloud) or any LLM/parse error → neutral `Sentiment` + a `{"warning": …}`
  line on stderr; the analysis JSON and note are still written.
- Empty transcript → `analyze_sentiment` returns `None`; no Sentiment section is added.
- Sentiment never blocks or fails the job (mirrors the diarization/emotion
  graceful-degradation principle).

## 8. Testing (`python-worker`, venv pytest, ≥80% on the new module)

All unit tests mock `LLMClient` — no network:
- **Prompt/parse:** a mocked `complete_json` returns well-formed JSON → correct
  `Sentiment` (overall + per-speaker, scores clamped, labels normalized).
- **Defensive parse:** missing `by_speaker` entry → that speaker gets neutral; unknown
  label → `neutral`; out-of-range score → clamped.
- **Fallback:** no `LLM_API_KEY` on a cloud base URL → neutral fallback, no exception;
  `LLMError` from the client → neutral fallback.
- **Empty segments:** returns `None`.
- **Schema:** `Sentiment` / `SpeakerSentiment` round-trip; `ConversationAnalysis` with
  `sentiment` round-trips.
- **CLI integration:** with a mocked LLM, `_run_pipeline` (or the sentiment+write step)
  produces an `<id>_analysis.json` containing `sentiment`, and the note contains a
  `## Sentiment` section.
- **Note section:** `render_sentiment_section` output shape for a 2-speaker sentiment;
  empty/None → no section.

## 9. Out of scope (→ later phases)

- **Phase 4b:** acoustic emotion (onnxruntime + audeering MSP-dim), per-speaker
  `valence`/`arousal`/`dominant_emotion` on `SpeakerStats`, the emotional `arc`, the
  worker model-download/consent + `emotionModelsReady` Settings flow, and feeding emotion
  into `analyze_sentiment(emotion=…)` for reconciliation.
- **Phase 5:** type-tailored insight prompts and full per-type Markdown note shapes
  (the minimal `## Sentiment` section here is a placeholder Phase 5 will restructure).
- **Phase 6:** Session Detail "Conversation Insights" UI.
- No Swift changes in 4a.

# Voice Intelligence — Phase 4a: LLM Sentiment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add LLM-derived conversation sentiment (overall + per-speaker) to the worker's `<id>_analysis.json` and a minimal `## Sentiment` note section, reusing the existing LLM client/env path with graceful fallback.

**Architecture:** A new pure-ish `app/analyze/sentiment.py` calls the existing `LLMClient` (env-driven, like `generate_markdown`) and returns a validated `Sentiment` model, defensively normalized, with a neutral fallback that never raises. `cli._run_pipeline` computes it, includes it in `ConversationAnalysis`, and appends a small rendered section to the note. Worker-only; no new dependencies; no Swift changes.

**Tech Stack:** Python 3.11+, Pydantic, pytest, the `openai` SDK via `LLMClient`. Spec: `docs/superpowers/specs/2026-05-25-phase4a-sentiment-design.md`.

**Branch:** `feature/voice-intelligence-phase4a` (already created).

---

## Conventions for this plan

- **Always use the venv.** Run tests as `cd python-worker && ./.venv/bin/python -m pytest <args>`. Never bare `python`/`pytest`.
- Pyright "could not be resolved" / `frozen=` editor warnings are FALSE POSITIVES — judge by the venv `pytest` run only.
- Commit messages: conventional, and must NOT mention AI/Claude.
- `from __future__ import annotations` is already at the top of `models.py`, `cli.py`, `markdown.py` — keep using it.

## File Structure

- Modify `python-worker/app/schemas/models.py` — add `SpeakerSentiment` + `Sentiment` (before `ConversationAnalysis`), add `sentiment: Sentiment | None = None` to `ConversationAnalysis`.
- Create `python-worker/app/analyze/sentiment.py` — `analyze_sentiment(segments, *, emotion=None) -> Sentiment | None`, neutral fallback, defensive parse.
- Modify `python-worker/app/postprocess/formatter.py` — add `render_sentiment_section(sentiment) -> str`.
- Modify `python-worker/app/cli.py` — compute sentiment, pass into `_write_analysis`, append the note section.
- Tests: `tests/test_sentiment_schema.py`, `tests/test_sentiment.py`, `tests/test_sentiment_section.py`, `tests/test_pipeline_sentiment.py`.

---

## Task 1: Sentiment schemas

**Files:**
- Modify: `python-worker/app/schemas/models.py`
- Test: `python-worker/tests/test_sentiment_schema.py`

- [ ] **Step 1: Write the failing test**

Create `python-worker/tests/test_sentiment_schema.py`:

```python
from app.schemas.models import ConversationAnalysis, Sentiment, SpeakerSentiment


def test_speaker_sentiment_defaults():
    s = SpeakerSentiment()
    assert s.label == "neutral"
    assert s.score == 0.0


def test_sentiment_defaults_and_roundtrip():
    sent = Sentiment(
        overall="positive",
        overall_score=0.5,
        by_speaker={"You": SpeakerSentiment(label="positive", score=0.6)},
    )
    restored = Sentiment.model_validate_json(sent.model_dump_json())
    assert restored.overall == "positive"
    assert restored.overall_score == 0.5
    assert restored.by_speaker["You"].score == 0.6
    assert restored.arc == []


def test_conversation_analysis_carries_sentiment():
    analysis = ConversationAnalysis(
        recording_type="call_meeting",
        num_speakers=1,
        sentiment=Sentiment(overall="neutral"),
    )
    restored = ConversationAnalysis.model_validate_json(analysis.model_dump_json())
    assert restored.sentiment is not None
    assert restored.sentiment.overall == "neutral"


def test_conversation_analysis_sentiment_optional():
    analysis = ConversationAnalysis()
    assert analysis.sentiment is None
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd python-worker && ./.venv/bin/python -m pytest tests/test_sentiment_schema.py -v`
Expected: FAIL — `cannot import name 'Sentiment'`.

- [ ] **Step 3: Add the models**

In `python-worker/app/schemas/models.py`, **immediately before** the `class ConversationAnalysis` definition, add:

```python
class SpeakerSentiment(BaseModel, frozen=True):
    """Per-speaker sentiment from the LLM."""

    label: str = "neutral"  # positive | neutral | negative | mixed
    score: float = 0.0       # -1.0 (very negative) .. 1.0 (very positive)


class Sentiment(BaseModel, frozen=True):
    """Conversation sentiment (Phase 4a: text/LLM; `arc` populated in Phase 4b)."""

    overall: str = "neutral"  # positive | neutral | negative | mixed
    overall_score: float = 0.0
    by_speaker: dict[str, SpeakerSentiment] = Field(default_factory=dict)
    arc: list[float] = Field(default_factory=list)
```

Then in `class ConversationAnalysis`, add this field after `speakers`:

```python
    sentiment: Sentiment | None = None
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd python-worker && ./.venv/bin/python -m pytest tests/test_sentiment_schema.py -v`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add python-worker/app/schemas/models.py python-worker/tests/test_sentiment_schema.py
git commit -m "feat(worker): add Sentiment and SpeakerSentiment schemas"
```

---

## Task 2: `analyze_sentiment` (LLM + defensive parse + neutral fallback)

**Files:**
- Create: `python-worker/app/analyze/sentiment.py`
- Test: `python-worker/tests/test_sentiment.py`

Mirrors `app/postprocess/markdown.py`'s env handling and fallback. All tests mock `LLMClient` — no network.

- [ ] **Step 1: Write the failing test**

Create `python-worker/tests/test_sentiment.py`:

```python
from unittest.mock import MagicMock, patch

from app.analyze.sentiment import analyze_sentiment
from app.postprocess.llm_client import LLMError
from app.schemas.models import TranscriptSegment


def _segs():
    return [
        TranscriptSegment(start=0.0, end=2.0, text="great, thanks!", speaker="You"),
        TranscriptSegment(start=2.0, end=4.0, text="not sure about that", speaker="Speaker 1"),
    ]


def test_empty_segments_returns_none():
    assert analyze_sentiment([]) is None


def test_happy_path_parses_llm_json(monkeypatch):
    monkeypatch.setenv("LLM_API_KEY", "k")
    monkeypatch.setenv("LLM_BASE_URL", "https://openrouter.ai/api/v1")
    fake = MagicMock()
    fake.complete_json.return_value = {
        "overall": "positive",
        "overall_score": 0.7,
        "by_speaker": {
            "You": {"label": "positive", "score": 0.8},
            "Speaker 1": {"label": "negative", "score": -0.4},
        },
    }
    with patch("app.analyze.sentiment.LLMClient", return_value=fake):
        sent = analyze_sentiment(_segs())
    assert sent is not None
    assert sent.overall == "positive"
    assert sent.overall_score == 0.7
    assert sent.by_speaker["You"].label == "positive"
    assert sent.by_speaker["Speaker 1"].score == -0.4


def test_scores_clamped_and_labels_normalized(monkeypatch):
    monkeypatch.setenv("LLM_API_KEY", "k")
    monkeypatch.setenv("LLM_BASE_URL", "https://openrouter.ai/api/v1")
    fake = MagicMock()
    fake.complete_json.return_value = {
        "overall": "ecstatic",            # unknown -> neutral
        "overall_score": 5.0,             # clamp -> 1.0
        "by_speaker": {"You": {"label": "positive", "score": -9.0}},  # clamp -> -1.0
    }
    with patch("app.analyze.sentiment.LLMClient", return_value=fake):
        sent = analyze_sentiment(_segs())
    assert sent.overall == "neutral"
    assert sent.overall_score == 1.0
    assert sent.by_speaker["You"].score == -1.0
    # Speaker 1 absent from output -> filled neutral
    assert sent.by_speaker["Speaker 1"].label == "neutral"
    assert sent.by_speaker["Speaker 1"].score == 0.0


def test_no_key_on_cloud_returns_neutral_fallback(monkeypatch):
    monkeypatch.delenv("LLM_API_KEY", raising=False)
    monkeypatch.setenv("LLM_BASE_URL", "https://openrouter.ai/api/v1")
    sent = analyze_sentiment(_segs())
    assert sent.overall == "neutral"
    assert sent.overall_score == 0.0
    assert set(sent.by_speaker) == {"You", "Speaker 1"}
    assert all(s.label == "neutral" for s in sent.by_speaker.values())


def test_llm_error_returns_neutral_fallback(monkeypatch):
    monkeypatch.setenv("LLM_API_KEY", "k")
    monkeypatch.setenv("LLM_BASE_URL", "https://openrouter.ai/api/v1")
    fake = MagicMock()
    fake.complete_json.side_effect = LLMError("boom")
    with patch("app.analyze.sentiment.LLMClient", return_value=fake):
        sent = analyze_sentiment(_segs())
    assert sent.overall == "neutral"
    assert set(sent.by_speaker) == {"You", "Speaker 1"}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd python-worker && ./.venv/bin/python -m pytest tests/test_sentiment.py -v`
Expected: FAIL — module `app.analyze.sentiment` missing.

- [ ] **Step 3: Implement**

Create `python-worker/app/analyze/sentiment.py`:

```python
"""LLM-based conversation sentiment (Phase 4a: text only).

Reuses the OpenAI-compatible endpoint described by the LLM_* env vars (OpenRouter
or a local server), mirroring app.postprocess.markdown. Never raises into the
pipeline: an unusable endpoint or a failed/garbled call yields a neutral fallback.
"""

from __future__ import annotations

import json
import os
import sys

from app.postprocess.llm_client import LLMClient, LLMError, OPENROUTER_BASE_URL
from app.schemas.models import Sentiment, SpeakerSentiment, TranscriptSegment

_VALID_LABELS = {"positive", "neutral", "negative", "mixed"}

_SYSTEM_PROMPT = (
    "You are a conversation sentiment analyst. Given a speaker-labeled transcript, "
    "judge the emotional sentiment. Output ONLY valid JSON matching this schema:\n"
    '{"overall": "positive|neutral|negative|mixed", '
    '"overall_score": <float between -1 and 1>, '
    '"by_speaker": {"<speaker label>": '
    '{"label": "positive|neutral|negative|mixed", "score": <float between -1 and 1>}}}\n'
    "Use the exact speaker labels that appear in the transcript. Score: -1 very "
    "negative, 0 neutral, 1 very positive. No prose, no invented speakers."
)


def _distinct_speakers(segments: list[TranscriptSegment]) -> list[str]:
    seen: list[str] = []
    for s in segments:
        label = s.speaker or "Speaker 1"
        if label not in seen:
            seen.append(label)
    return seen


def _transcript_text(segments: list[TranscriptSegment]) -> str:
    lines: list[str] = []
    for s in segments:
        speaker = f"[{s.speaker}] " if s.speaker else ""
        lines.append(f"{speaker}{s.text}")
    return "\n".join(lines)


def _clamp(value: float) -> float:
    return max(-1.0, min(1.0, value))


def _norm_label(label: object) -> str:
    text = str(label).strip().lower()
    return text if text in _VALID_LABELS else "neutral"


def _to_score(value: object) -> float:
    try:
        return _clamp(float(value))
    except (TypeError, ValueError):
        return 0.0


def _neutral_fallback(segments: list[TranscriptSegment]) -> Sentiment:
    by_speaker = {
        label: SpeakerSentiment(label="neutral", score=0.0)
        for label in _distinct_speakers(segments)
    }
    return Sentiment(overall="neutral", overall_score=0.0, by_speaker=by_speaker)


def _warn(message: str) -> None:
    sys.stderr.write(json.dumps({"warning": message}) + "\n")
    sys.stderr.flush()


def _build_sentiment(data: dict, segments: list[TranscriptSegment]) -> Sentiment:
    raw_by = data.get("by_speaker") or {}
    by_speaker: dict[str, SpeakerSentiment] = {}
    for label in _distinct_speakers(segments):
        entry = raw_by.get(label) or {}
        by_speaker[label] = SpeakerSentiment(
            label=_norm_label(entry.get("label")),
            score=_to_score(entry.get("score")),
        )
    return Sentiment(
        overall=_norm_label(data.get("overall")),
        overall_score=_to_score(data.get("overall_score")),
        by_speaker=by_speaker,
    )


def analyze_sentiment(
    segments: list[TranscriptSegment],
    *,
    emotion: dict | None = None,  # reserved for Phase 4b reconciliation; unused here
) -> Sentiment | None:
    """Judge conversation sentiment from speaker-labeled segments via the LLM.

    Returns None for an empty transcript; otherwise a `Sentiment`. Never raises —
    an unusable endpoint or any failure yields a neutral fallback covering every
    speaker present in `segments`.
    """
    if not segments:
        return None

    base_url = os.environ.get("LLM_BASE_URL", OPENROUTER_BASE_URL)
    model = os.environ.get("LLM_MODEL", "google/gemini-2.5-flash")
    api_key = os.environ.get("LLM_API_KEY", "")
    is_local = "openrouter.ai" not in base_url

    if not api_key and not is_local:
        _warn("no LLM_API_KEY for cloud endpoint, using neutral sentiment")
        return _neutral_fallback(segments)

    try:
        client = LLMClient(api_key=api_key, model=model, base_url=base_url)
        data = client.complete_json(
            system=_SYSTEM_PROMPT,
            user=f"Transcript:\n\n{_transcript_text(segments)}",
        )
        return _build_sentiment(data, segments)
    except (LLMError, ValueError, TypeError) as exc:
        _warn(f"sentiment failed: {exc}, using neutral sentiment")
        return _neutral_fallback(segments)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd python-worker && ./.venv/bin/python -m pytest tests/test_sentiment.py -v`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add python-worker/app/analyze/sentiment.py python-worker/tests/test_sentiment.py
git commit -m "feat(worker): LLM conversation sentiment with neutral fallback"
```

---

## Task 3: Render the minimal Sentiment note section

**Files:**
- Modify: `python-worker/app/postprocess/formatter.py`
- Test: `python-worker/tests/test_sentiment_section.py`

- [ ] **Step 1: Write the failing test**

Create `python-worker/tests/test_sentiment_section.py`:

```python
from app.postprocess.formatter import render_sentiment_section
from app.schemas.models import Sentiment, SpeakerSentiment


def test_none_renders_empty_string():
    assert render_sentiment_section(None) == ""


def test_renders_overall_and_speakers():
    sent = Sentiment(
        overall="positive",
        overall_score=0.5,
        by_speaker={
            "You": SpeakerSentiment(label="positive", score=0.6),
            "Speaker 1": SpeakerSentiment(label="neutral", score=0.0),
        },
    )
    out = render_sentiment_section(sent)
    assert "## Sentiment" in out
    assert "**Overall:** positive (+0.50)" in out
    assert "- **You:** positive (+0.60)" in out
    assert "- **Speaker 1:** neutral (+0.00)" in out


def test_renders_without_speakers():
    sent = Sentiment(overall="negative", overall_score=-0.3)
    out = render_sentiment_section(sent)
    assert "## Sentiment" in out
    assert "**Overall:** negative (-0.30)" in out
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd python-worker && ./.venv/bin/python -m pytest tests/test_sentiment_section.py -v`
Expected: FAIL — `cannot import name 'render_sentiment_section'`.

- [ ] **Step 3: Implement**

In `python-worker/app/postprocess/formatter.py`, update the import line:

```python
from app.schemas.models import MarkdownNote, Sentiment
```

and add this function at the end of the file:

```python
def render_sentiment_section(sentiment: Sentiment | None) -> str:
    """Render a minimal '## Sentiment' markdown block, or '' when sentiment is absent.

    Phase 4a placeholder; Phase 5 folds sentiment into the per-type note shapes.
    """
    if sentiment is None:
        return ""

    lines: list[str] = [
        "## Sentiment",
        "",
        f"**Overall:** {sentiment.overall} ({sentiment.overall_score:+.2f})",
    ]
    if sentiment.by_speaker:
        lines.append("")
        for label, sp in sentiment.by_speaker.items():
            lines.append(f"- **{label}:** {sp.label} ({sp.score:+.2f})")
    lines.append("")
    return "\n".join(lines)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd python-worker && ./.venv/bin/python -m pytest tests/test_sentiment_section.py -v`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add python-worker/app/postprocess/formatter.py python-worker/tests/test_sentiment_section.py
git commit -m "feat(worker): render minimal Sentiment note section"
```

---

## Task 4: Wire sentiment into the pipeline

**Files:**
- Modify: `python-worker/app/cli.py`
- Test: `python-worker/tests/test_pipeline_sentiment.py`

- [ ] **Step 1: Add imports**

In `python-worker/app/cli.py`, add to the imports near the top:

```python
from app.analyze.sentiment import analyze_sentiment
```

and change the existing formatter import to also import the section renderer:

```python
from app.postprocess.formatter import render_markdown, render_sentiment_section
```

- [ ] **Step 2: Thread `sentiment` through `_write_analysis`**

In `python-worker/app/cli.py`, change the `_write_analysis` signature and the
`ConversationAnalysis(...)` it builds. Replace:

```python
def _write_analysis(request: JobRequest, segments: list[TranscriptSegment]) -> str:
    """Build and write `<base>_analysis.json`; return its path."""
    speakers = compute_speaker_stats(segments, self_label="You")
    analysis = ConversationAnalysis(
        recording_type=request.recording_type,
        num_speakers=len(speakers),
        speakers=speakers,
    )
```

with:

```python
def _write_analysis(
    request: JobRequest,
    segments: list[TranscriptSegment],
    sentiment: Sentiment | None = None,
) -> str:
    """Build and write `<base>_analysis.json`; return its path."""
    speakers = compute_speaker_stats(segments, self_label="You")
    analysis = ConversationAnalysis(
        recording_type=request.recording_type,
        num_speakers=len(speakers),
        speakers=speakers,
        sentiment=sentiment,
    )
```

and add `Sentiment` to the existing schema import in `cli.py` (the line importing from
`app.schemas.models`) so the annotation resolves — change it to include `Sentiment`:

```python
from app.schemas.models import (
    ConversationAnalysis,
    JobRequest,
    JobResult,
    Sentiment,
    TranscriptSegment,
)
```

- [ ] **Step 3: Compute sentiment and append the note section in `_run_pipeline`**

In `_run_pipeline`, replace this block:

```python
    analysis_path = _write_analysis(request, segments)

    report_progress(request.job_id, 0.5, "postprocessing")

    note = generate_markdown(segments, profile=request.markdown_profile)

    rendered = render_markdown(note, profile=request.markdown_profile)
```

with:

```python
    sentiment = analyze_sentiment(segments)
    analysis_path = _write_analysis(request, segments, sentiment)

    report_progress(request.job_id, 0.5, "postprocessing")

    note = generate_markdown(segments, profile=request.markdown_profile)

    rendered = render_markdown(note, profile=request.markdown_profile)
    section = render_sentiment_section(sentiment)
    if section:
        rendered = f"{rendered}\n{section}"
```

- [ ] **Step 4: Write the integration test**

Create `python-worker/tests/test_pipeline_sentiment.py`:

```python
import json
from unittest.mock import patch

from app import cli
from app.schemas.models import (
    JobRequest,
    Sentiment,
    SpeakerSentiment,
    TranscriptSegment,
)


def _segs():
    return [
        TranscriptSegment(start=0.0, end=2.0, text="hi there", speaker="You"),
        TranscriptSegment(start=2.0, end=4.0, text="hello back", speaker="Speaker 1"),
    ]


def test_pipeline_writes_sentiment_to_analysis_and_note(tmp_path, monkeypatch):
    # Ensure generate_markdown uses its offline rule-based fallback (no network),
    # regardless of the runner's environment.
    monkeypatch.delenv("LLM_API_KEY", raising=False)
    monkeypatch.delenv("LLM_BASE_URL", raising=False)

    audio = tmp_path / "sess.wav"
    audio.write_bytes(b"")
    request = JobRequest(job_id="j", command="transcribe", audio_path=str(audio))

    sent = Sentiment(
        overall="positive",
        overall_score=0.5,
        by_speaker={
            "You": SpeakerSentiment(label="positive", score=0.6),
            "Speaker 1": SpeakerSentiment(label="neutral", score=0.0),
        },
    )

    # Mock transcription + sentiment so no audio decode or network is needed.
    # generate_markdown runs with no LLM key -> its own rule-based fallback.
    with patch("app.cli._transcribe_and_attribute", return_value=_segs()), \
         patch("app.cli.analyze_sentiment", return_value=sent):
        result = cli._run_pipeline(request)

    assert result.status == "completed"

    analysis = json.loads((tmp_path / "sess_analysis.json").read_text())
    assert analysis["sentiment"]["overall"] == "positive"
    assert analysis["sentiment"]["by_speaker"]["You"]["label"] == "positive"

    notes = (tmp_path / "sess_notes.md").read_text()
    assert "## Sentiment" in notes
    assert "**Overall:** positive (+0.50)" in notes
```

- [ ] **Step 5: Run the test, then the full suite**

Run: `cd python-worker && ./.venv/bin/python -m pytest tests/test_pipeline_sentiment.py -v`
Expected: PASS (1 test).

Run: `cd python-worker && ./.venv/bin/python -m pytest -q`
Expected: all tests pass (the prior suite + the new sentiment tests).

- [ ] **Step 6: Commit**

```bash
git add python-worker/app/cli.py python-worker/tests/test_pipeline_sentiment.py
git commit -m "feat(worker): write sentiment to analysis JSON and note section"
```

---

## Final verification

- [ ] **Full worker suite:** `cd python-worker && ./.venv/bin/python -m pytest -q` — all pass.
- [ ] **No Swift changes:** `git diff --name-only main...HEAD -- macos-app/` is empty (Phase 4a is worker-only).
- [ ] **Human live check (needs an LLM key/endpoint — cannot be done by an agent):** with `LLM_API_KEY` set (OpenRouter) or a local Ollama endpoint, process a real multi-speaker recording and confirm `<id>_analysis.json` has a populated `sentiment` (overall + per-speaker) and `<id>_notes.md` shows a `## Sentiment` section. Without a key, confirm it degrades to neutral sentiment and the note/analysis still write.

## Notes for Phase 4b

- 4b computes per-speaker acoustic emotion (onnxruntime + audeering MSP-dim) and passes it into `analyze_sentiment(segments, emotion=…)` so the LLM reconciles tone + text; it also populates `Sentiment.arc` (the field already exists, currently always `[]`) with the acoustic-valence arc, widening the `arc` element type if it needs `{t, score}` points.
- The model download/consent (`emotionModelsReady`) + Settings wiring is a 4b concern.

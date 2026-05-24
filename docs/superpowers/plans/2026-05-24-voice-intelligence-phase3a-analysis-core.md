# Voice Intelligence — Phase 3a: Analysis Core (stem transcription + attribution + talk metrics)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Produce a per-speaker conversation analysis with **zero new heavy dependencies**. The worker transcribes the mic/system stems separately (mic → "You"), attributes each transcript segment to a speaker (using a diarization turns sidecar if present, else a single "Speaker 1"), computes talk metrics, and writes `<id>_analysis.json`. This sets up everything around diarization so Phase 3b only has to drop in the real multi-speaker diarizer (FluidAudio) that writes the sidecar.

**Architecture:** Pure, unit-tested Python functions for the diarization-sidecar reader, speaker attribution, and talk metrics; a stem-aware pipeline in `cli.py` that transcribes `<id>_mic.wav` + `<id>_system.wav` when present (falling back to the single mixed file otherwise); a new `ConversationAnalysis` schema and `<id>_analysis.json` output; `analysis_path` added to `JobResult`. Swift stores `analysis_path` on the session.

**Tech Stack:** Python 3.11+, Pydantic, pytest (worker); Swift/GRDB (app). Spec: `docs/superpowers/specs/2026-05-23-voice-intelligence-design.md` §3, §4, §6, §7.

This phase does NOT add a real diarizer, acoustic emotion, sentiment, or insights — those are 3b / Phase 4–5. With no `<id>_diarization.json` sidecar present (none is produced yet), every remote segment is labeled "Speaker 1"; the mic stem is always "You".

---

## Conventions used by this phase

- Audio file: `<dir>/<id>.wav`. Stems (Phase 2): `<dir>/<id>_mic.wav`, `<dir>/<id>_system.wav`.
- Diarization sidecar (consumed here, produced in 3b): `<dir>/<id>_diarization.json`, shape:
  `{"turns": [{"speaker": "Speaker 1", "start": 0.0, "end": 3.2}, ...]}` — covering the **system** stem timeline.
- Analysis output: `<dir>/<id>_analysis.json`.
- Helper to derive sibling paths from `audio_path`: `base = os.path.splitext(audio_path)[0]` → `f"{base}_mic.wav"`, `f"{base}_system.wav"`, `f"{base}_diarization.json"`, `f"{base}_analysis.json"`.

---

## File Structure

- Create `python-worker/app/analyze/__init__.py`
- Create `python-worker/app/analyze/diarization.py` — sidecar reader.
- Create `python-worker/app/analyze/attribution.py` — assign speaker labels to segments.
- Create `python-worker/app/analyze/metrics.py` — talk metrics.
- Modify `python-worker/app/schemas/models.py` — `DiarizationTurn`, `SpeakerStats`, `ConversationAnalysis`; add `analysis_path` to `JobResult`.
- Modify `python-worker/app/cli.py` — stem-aware transcription + analysis in `_run_pipeline`.
- Modify `python-worker/app/transcribe/engine.py` — add a `transcribe_path(...)` helper that transcribes an explicit file.
- Create tests: `tests/test_diarization_sidecar.py`, `tests/test_attribution.py`, `tests/test_metrics.py`, `tests/test_pipeline_stems.py`.
- Modify `macos-app/Sources/Bridge/Models.swift` — `JobResult.analysisPath`.
- Modify `macos-app/Sources/App/CallCaptureApp.swift` + `macos-app/Sources/Session/SessionManager.swift` — store `analysisPath` on the session.

---

## Task 1: Analysis schemas

**Files:**
- Modify: `python-worker/app/schemas/models.py`
- Test: `python-worker/tests/test_analysis_schema.py`

- [ ] **Step 1: Write the failing test**

Create `python-worker/tests/test_analysis_schema.py`:

```python
from app.schemas.models import ConversationAnalysis, DiarizationTurn, SpeakerStats


def test_speaker_stats_defaults():
    s = SpeakerStats(label="You", is_self=True)
    assert s.talk_seconds == 0.0
    assert s.talk_ratio == 0.0
    assert s.words == 0
    assert s.words_per_min == 0.0
    assert s.turns == 0
    assert s.longest_monologue_sec == 0.0


def test_conversation_analysis_roundtrip():
    analysis = ConversationAnalysis(
        recording_type="call_meeting",
        num_speakers=2,
        speakers=[
            SpeakerStats(label="You", is_self=True, talk_seconds=10, talk_ratio=0.4, words=30),
            SpeakerStats(label="Speaker 1", is_self=False, talk_seconds=15, talk_ratio=0.6, words=50),
        ],
    )
    dumped = analysis.model_dump_json()
    restored = ConversationAnalysis.model_validate_json(dumped)
    assert restored.num_speakers == 2
    assert restored.speakers[0].label == "You"


def test_diarization_turn():
    t = DiarizationTurn(speaker="Speaker 1", start=0.0, end=2.5)
    assert t.end == 2.5
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd python-worker && ./.venv/bin/python -m pytest tests/test_analysis_schema.py -v`
Expected: FAIL — models don't exist.

- [ ] **Step 3: Add the models**

In `python-worker/app/schemas/models.py`, after the `TranscriptSegment` class, add:

```python
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
```

- [ ] **Step 4: Add `analysis_path` to `JobResult`**

In the `JobResult` class, add after `markdown_path`:

```python
    analysis_path: str | None = None
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd python-worker && ./.venv/bin/python -m pytest tests/test_analysis_schema.py -v`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add python-worker/app/schemas/models.py python-worker/tests/test_analysis_schema.py
git commit -m "feat(worker): add conversation-analysis schemas and analysis_path"
```

---

## Task 2: Diarization sidecar reader

**Files:**
- Create: `python-worker/app/analyze/__init__.py` (empty)
- Create: `python-worker/app/analyze/diarization.py`
- Test: `python-worker/tests/test_diarization_sidecar.py`

- [ ] **Step 1: Write the failing test**

Create `python-worker/tests/test_diarization_sidecar.py`:

```python
import json
from pathlib import Path

from app.analyze.diarization import load_diarization_turns


def test_missing_sidecar_returns_none(tmp_path):
    audio = tmp_path / "abc.wav"
    audio.write_bytes(b"")
    assert load_diarization_turns(str(audio)) is None


def test_valid_sidecar_parsed(tmp_path):
    audio = tmp_path / "abc.wav"
    audio.write_bytes(b"")
    side = tmp_path / "abc_diarization.json"
    side.write_text(json.dumps({"turns": [
        {"speaker": "Speaker 1", "start": 0.0, "end": 2.0},
        {"speaker": "Speaker 2", "start": 2.0, "end": 5.0},
    ]}))
    turns = load_diarization_turns(str(audio))
    assert turns is not None
    assert len(turns) == 2
    assert turns[1].speaker == "Speaker 2"


def test_malformed_sidecar_returns_none(tmp_path):
    audio = tmp_path / "abc.wav"
    audio.write_bytes(b"")
    (tmp_path / "abc_diarization.json").write_text("not json")
    assert load_diarization_turns(str(audio)) is None
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd python-worker && ./.venv/bin/python -m pytest tests/test_diarization_sidecar.py -v`
Expected: FAIL — module missing.

- [ ] **Step 3: Implement**

Create `python-worker/app/analyze/__init__.py` (empty file).

Create `python-worker/app/analyze/diarization.py`:

```python
"""Reads the optional diarization turns sidecar written by a diarization provider."""

from __future__ import annotations

import json
import os

from app.schemas.models import DiarizationTurn


def sidecar_path(audio_path: str) -> str:
    """Path of the diarization sidecar for a given audio file."""
    base = os.path.splitext(audio_path)[0]
    return f"{base}_diarization.json"


def load_diarization_turns(audio_path: str) -> list[DiarizationTurn] | None:
    """Load speaker turns from `<base>_diarization.json`, or None if absent/invalid.

    The sidecar is produced by the diarization provider (Phase 3b). Its absence
    means "not diarized" — callers fall back to a single speaker.
    """
    path = sidecar_path(audio_path)
    if not os.path.exists(path):
        return None
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        return [DiarizationTurn.model_validate(t) for t in data.get("turns", [])]
    except Exception:
        return None
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd python-worker && ./.venv/bin/python -m pytest tests/test_diarization_sidecar.py -v`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add python-worker/app/analyze/__init__.py python-worker/app/analyze/diarization.py python-worker/tests/test_diarization_sidecar.py
git commit -m "feat(worker): read optional diarization turns sidecar"
```

---

## Task 3: Speaker attribution

**Files:**
- Create: `python-worker/app/analyze/attribution.py`
- Test: `python-worker/tests/test_attribution.py`

Assign a speaker label to each transcript segment. Mic segments are always the
self label ("You"). System segments map to the diarization turn with the greatest
time overlap; with no turns they all become "Speaker 1".

- [ ] **Step 1: Write the failing test**

Create `python-worker/tests/test_attribution.py`:

```python
from app.analyze.attribution import attribute_segments
from app.schemas.models import DiarizationTurn, TranscriptSegment


def seg(start, end, text="x"):
    return TranscriptSegment(start=start, end=end, text=text)


def test_mic_segments_are_self():
    mic = [seg(0, 2), seg(3, 4)]
    out = attribute_segments(mic_segments=mic, system_segments=[], turns=None, self_label="You")
    assert all(s.speaker == "You" for s in out)
    assert [s.start for s in out] == [0, 3]


def test_system_without_turns_is_single_speaker():
    syss = [seg(0, 2), seg(2, 4)]
    out = attribute_segments(mic_segments=[], system_segments=syss, turns=None, self_label="You")
    assert all(s.speaker == "Speaker 1" for s in out)


def test_system_attributed_by_max_overlap():
    syss = [seg(0.0, 1.0), seg(1.5, 3.0)]
    turns = [
        DiarizationTurn(speaker="Speaker 1", start=0.0, end=1.2),
        DiarizationTurn(speaker="Speaker 2", start=1.2, end=3.5),
    ]
    out = attribute_segments(mic_segments=[], system_segments=syss, turns=turns, self_label="You")
    assert out[0].speaker == "Speaker 1"
    assert out[1].speaker == "Speaker 2"


def test_merged_output_sorted_by_start():
    mic = [seg(0.0, 1.0, "me")]
    syss = [seg(0.5, 2.0, "them")]
    out = attribute_segments(mic_segments=mic, system_segments=syss, turns=None, self_label="You")
    assert [s.start for s in out] == [0.0, 0.5]
    assert out[0].speaker == "You" and out[1].speaker == "Speaker 1"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd python-worker && ./.venv/bin/python -m pytest tests/test_attribution.py -v`
Expected: FAIL — module missing.

- [ ] **Step 3: Implement**

Create `python-worker/app/analyze/attribution.py`:

```python
"""Assigns speaker labels to transcript segments."""

from __future__ import annotations

from app.schemas.models import DiarizationTurn, TranscriptSegment

_DEFAULT_REMOTE_SPEAKER = "Speaker 1"


def _overlap(a_start: float, a_end: float, b_start: float, b_end: float) -> float:
    return max(0.0, min(a_end, b_end) - max(a_start, b_start))


def _label_for(segment: TranscriptSegment, turns: list[DiarizationTurn]) -> str:
    best_label = _DEFAULT_REMOTE_SPEAKER
    best_overlap = 0.0
    for turn in turns:
        ov = _overlap(segment.start, segment.end, turn.start, turn.end)
        if ov > best_overlap:
            best_overlap = ov
            best_label = turn.speaker
    return best_label


def attribute_segments(
    mic_segments: list[TranscriptSegment],
    system_segments: list[TranscriptSegment],
    turns: list[DiarizationTurn] | None,
    self_label: str = "You",
) -> list[TranscriptSegment]:
    """Label mic segments as `self_label` and system segments by diarization
    overlap (or a single remote speaker when no turns), merged and sorted by start.
    """
    labeled: list[TranscriptSegment] = []
    for s in mic_segments:
        labeled.append(s.model_copy(update={"speaker": self_label}))
    for s in system_segments:
        label = _label_for(s, turns) if turns else _DEFAULT_REMOTE_SPEAKER
        labeled.append(s.model_copy(update={"speaker": label}))
    labeled.sort(key=lambda seg: seg.start)
    return labeled
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd python-worker && ./.venv/bin/python -m pytest tests/test_attribution.py -v`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add python-worker/app/analyze/attribution.py python-worker/tests/test_attribution.py
git commit -m "feat(worker): attribute transcript segments to speakers"
```

---

## Task 4: Talk metrics

**Files:**
- Create: `python-worker/app/analyze/metrics.py`
- Test: `python-worker/tests/test_metrics.py`

- [ ] **Step 1: Write the failing test**

Create `python-worker/tests/test_metrics.py`:

```python
from app.analyze.metrics import compute_speaker_stats
from app.schemas.models import TranscriptSegment


def seg(start, end, text, speaker):
    return TranscriptSegment(start=start, end=end, text=text, speaker=speaker)


def test_two_speakers_basic_metrics():
    segments = [
        seg(0.0, 10.0, "one two three", "You"),       # 10s, 3 words
        seg(10.0, 30.0, "a b c d e f", "Speaker 1"),  # 20s, 6 words
    ]
    stats = compute_speaker_stats(segments)
    by = {s.label: s for s in stats}
    assert by["You"].talk_seconds == 10.0
    assert by["Speaker 1"].talk_seconds == 20.0
    assert abs(by["You"].talk_ratio - (10 / 30)) < 1e-6
    assert by["You"].words == 3
    assert abs(by["You"].words_per_min - (3 / (10 / 60))) < 1e-6
    assert by["You"].turns == 1
    assert by["Speaker 1"].turns == 1
    assert by["You"].longest_monologue_sec == 10.0


def test_turns_count_floor_changes():
    segments = [
        seg(0, 1, "x", "You"),
        seg(1, 2, "x", "Speaker 1"),
        seg(2, 3, "x", "You"),       # You takes the floor again -> 2 turns
    ]
    by = {s.label: s for s in compute_speaker_stats(segments)}
    assert by["You"].turns == 2
    assert by["Speaker 1"].turns == 1


def test_empty_segments():
    assert compute_speaker_stats([]) == []


def test_is_self_flag():
    segments = [seg(0, 1, "x", "You")]
    stats = compute_speaker_stats(segments, self_label="You")
    assert stats[0].is_self is True
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd python-worker && ./.venv/bin/python -m pytest tests/test_metrics.py -v`
Expected: FAIL — module missing.

- [ ] **Step 3: Implement**

Create `python-worker/app/analyze/metrics.py`:

```python
"""Computes per-speaker talk metrics from attributed transcript segments."""

from __future__ import annotations

from app.schemas.models import SpeakerStats, TranscriptSegment


def compute_speaker_stats(
    segments: list[TranscriptSegment],
    self_label: str = "You",
) -> list[SpeakerStats]:
    """Aggregate per-speaker talk metrics from speaker-attributed segments.

    `segments` should be ordered by start time. Speakers are returned in order of
    first appearance.
    """
    if not segments:
        return []

    total_speech = sum(max(0.0, s.end - s.start) for s in segments) or 1.0

    order: list[str] = []
    seconds: dict[str, float] = {}
    words: dict[str, int] = {}
    longest: dict[str, float] = {}
    turns: dict[str, int] = {}
    prev_speaker: str | None = None

    for s in segments:
        label = s.speaker or "Speaker 1"
        if label not in seconds:
            order.append(label)
            seconds[label] = 0.0
            words[label] = 0
            longest[label] = 0.0
            turns[label] = 0
        dur = max(0.0, s.end - s.start)
        seconds[label] += dur
        words[label] += len(s.text.split())
        longest[label] = max(longest[label], dur)
        if label != prev_speaker:
            turns[label] += 1
        prev_speaker = label

    stats: list[SpeakerStats] = []
    for label in order:
        secs = seconds[label]
        wpm = words[label] / (secs / 60.0) if secs > 0 else 0.0
        stats.append(SpeakerStats(
            label=label,
            is_self=(label == self_label),
            talk_seconds=round(secs, 2),
            talk_ratio=round(secs / total_speech, 4),
            words=words[label],
            words_per_min=round(wpm, 1),
            turns=turns[label],
            longest_monologue_sec=round(longest[label], 2),
        ))
    return stats
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd python-worker && ./.venv/bin/python -m pytest tests/test_metrics.py -v`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add python-worker/app/analyze/metrics.py python-worker/tests/test_metrics.py
git commit -m "feat(worker): compute per-speaker talk metrics"
```

---

## Task 5: Stem-aware transcription + analysis in the pipeline

**Files:**
- Modify: `python-worker/app/transcribe/engine.py`
- Modify: `python-worker/app/cli.py`
- Test: `python-worker/tests/test_pipeline_stems.py`

- [ ] **Step 1: Add a path-based transcription helper**

In `python-worker/app/transcribe/engine.py`, add (it lets us transcribe a specific stem file rather than `request.audio_path`):

```python
def transcribe_path(
    audio_path: str,
    request: JobRequest,
    progress_callback: ProgressCallback | None = None,
) -> list[TranscriptSegment]:
    """Transcribe a specific file with the request's engine settings."""
    try:
        if request.engine == "local_whisper":
            return transcribe_local(
                audio_path=audio_path,
                model=request.whisper_model,
                language=request.language,
                job_id=request.job_id,
            )
        return transcribe_remote(
            audio_path=audio_path,
            provider=request.remote_provider,
            language=request.language,
            job_id=request.job_id,
        )
    except Exception as exc:
        raise RuntimeError(f"Transcription failed ({request.engine}): {exc}") from exc
```

- [ ] **Step 2: Add an analysis builder + stem-aware transcription to `cli.py`**

In `python-worker/app/cli.py`, add imports near the top:

```python
import json as _json
from app.analyze.attribution import attribute_segments
from app.analyze.diarization import load_diarization_turns
from app.analyze.metrics import compute_speaker_stats
from app.schemas.models import ConversationAnalysis
from app.transcribe.engine import transcribe_path
```

Add this helper function (above `_run_pipeline`):

```python
def _transcribe_and_attribute(request: JobRequest) -> list[TranscriptSegment]:
    """Transcribe stems when present (mic = You, system = remote, attributed by
    the diarization sidecar), else transcribe the single mixed file as remote."""
    base = os.path.splitext(request.audio_path)[0]
    mic_path = f"{base}_mic.wav"
    system_path = f"{base}_system.wav"

    if os.path.exists(mic_path) and os.path.exists(system_path):
        mic_segments = transcribe_path(mic_path, request)
        system_segments = transcribe_path(system_path, request)
        turns = load_diarization_turns(system_path)
        return attribute_segments(mic_segments, system_segments, turns, self_label="You")

    # No stems: transcribe the mixed file; attribute remote via sidecar if any.
    segments = transcribe(request)
    turns = load_diarization_turns(request.audio_path)
    return attribute_segments([], segments, turns, self_label="You")


def _write_analysis(request: JobRequest, segments: list[TranscriptSegment]) -> str:
    """Build and write `<base>_analysis.json`; return its path."""
    speakers = compute_speaker_stats(segments, self_label="You")
    analysis = ConversationAnalysis(
        recording_type=request.recording_type,
        num_speakers=len(speakers),
        speakers=speakers,
    )
    base = os.path.splitext(request.audio_path)[0]
    analysis_path = f"{base}_analysis.json"
    tmp = analysis_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(analysis.model_dump_json(indent=2))
    os.replace(tmp, analysis_path)
    return analysis_path
```

- [ ] **Step 3: Wire them into `_run_pipeline`**

In `_run_pipeline`, replace the line `segments = transcribe(request)` with:

```python
    segments = _transcribe_and_attribute(request)
```

After the `if not segments:` guard and before `report_progress(request.job_id, 0.5, "postprocessing")`, add:

```python
    analysis_path = _write_analysis(request, segments)
```

Then add `analysis_path=analysis_path,` to the `JobResult(...)` constructor in the success return of `_run_pipeline`.

- [ ] **Step 4: Write the integration test**

Create `python-worker/tests/test_pipeline_stems.py`:

```python
import json
import os
from unittest.mock import patch

from app.schemas.models import JobRequest, TranscriptSegment


def _seg(start, end, text):
    return TranscriptSegment(start=start, end=end, text=text)


def test_stem_pipeline_attributes_and_writes_analysis(tmp_path):
    from app import cli

    audio = tmp_path / "sess.wav"
    audio.write_bytes(b"")
    (tmp_path / "sess_mic.wav").write_bytes(b"")
    (tmp_path / "sess_system.wav").write_bytes(b"")

    request = JobRequest(job_id="j", command="transcribe", audio_path=str(audio))

    def fake_transcribe_path(path, req, progress_callback=None):
        if path.endswith("_mic.wav"):
            return [_seg(0.0, 2.0, "hello from me")]
        return [_seg(2.0, 6.0, "reply from them")]

    with patch("app.cli.transcribe_path", side_effect=fake_transcribe_path):
        segments = cli._transcribe_and_attribute(request)
        analysis_path = cli._write_analysis(request, segments)

    assert [s.speaker for s in segments] == ["You", "Speaker 1"]
    assert os.path.exists(analysis_path)
    data = json.loads(open(analysis_path).read())
    assert data["num_speakers"] == 2
    labels = {s["label"] for s in data["speakers"]}
    assert labels == {"You", "Speaker 1"}


def test_no_stems_falls_back_to_single_file(tmp_path):
    from app import cli

    audio = tmp_path / "sess.wav"
    audio.write_bytes(b"")
    request = JobRequest(job_id="j", command="transcribe", audio_path=str(audio))

    with patch("app.cli.transcribe", return_value=[_seg(0.0, 3.0, "only system")]):
        segments = cli._transcribe_and_attribute(request)

    assert segments[0].speaker == "Speaker 1"
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd python-worker && ./.venv/bin/python -m pytest tests/test_pipeline_stems.py -v`
Expected: PASS (2 tests). If `_run_pipeline` references fail, ensure `os` and `TranscriptSegment` are imported in `cli.py` (add `from app.schemas.models import TranscriptSegment` if not already present).

- [ ] **Step 6: Run the full worker suite**

Run: `cd python-worker && ./.venv/bin/python -m pytest -q`
Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add python-worker/app/transcribe/engine.py python-worker/app/cli.py python-worker/tests/test_pipeline_stems.py
git commit -m "feat(worker): stem-aware transcription, attribution, and analysis output"
```

---

## Task 6: Swift — store `analysis_path` on the session

**Files:**
- Modify: `macos-app/Sources/Bridge/Models.swift`
- Modify: `macos-app/Sources/Session/SessionManager.swift`
- Modify: `macos-app/Sources/App/CallCaptureApp.swift`

- [ ] **Step 1: Add `analysisPath` to the Swift `JobResult`**

In `macos-app/Sources/Bridge/Models.swift`, in the `JobResult` struct add `let analysisPath: String?` near `markdownPath`, and in its `CodingKeys` add `case analysisPath = "analysis_path"`. If `JobResult` has any manual initializer (e.g. an `error(...)` factory), pass `analysisPath: nil` there.

- [ ] **Step 2: Add a setter on `SessionManager`**

In `macos-app/Sources/Session/SessionManager.swift`, add a method:

```swift
    /// Persists the analysis JSON path for a session.
    func updateAnalysisPath(id: String, analysisPath: String?) {
        do {
            try database.dbPool.write { db in
                guard var record = try SessionRecord.fetchOne(db, key: id) else { return }
                record.analysisPath = analysisPath
                try record.update(db)
            }
        } catch {
            Self.logger.error("Failed to update analysis path for \(id): \(error)")
        }
    }
```

- [ ] **Step 3: Call it after a successful transcription**

In `macos-app/Sources/App/CallCaptureApp.swift` `transcribeSession`, in the success branch where `sessionManager.updateSessionPaths(...)` is called, add right after it:

```swift
            sessionManager.updateAnalysisPath(
                id: session.id,
                analysisPath: result.analysisPath
            )
```

- [ ] **Step 4: Verify it builds and tests pass**

Run: `cd macos-app && swift build && swift test`
Expected: `Build complete!` and 9 tests pass.

- [ ] **Step 5: Commit**

```bash
git add macos-app/Sources/Bridge/Models.swift macos-app/Sources/Session/SessionManager.swift macos-app/Sources/App/CallCaptureApp.swift
git commit -m "feat(app): persist analysis_path returned by the worker"
```

---

## Task 7: End-to-end verification

- [ ] **Step 1: Full suites**

Run: `cd python-worker && ./.venv/bin/python -m pytest -q` (all pass) and `cd macos-app && swift build && swift test` (9 pass).

- [ ] **Step 2: Record + inspect analysis**

`./run-dev.sh`, set an LLM provider, pick **Call/Meeting** with a **Mic**, record ~15s talking + playing audio, stop, let it transcribe.

```bash
DIR="$HOME/Library/Application Support/CallCapture/audio"
ID=$(sqlite3 "$HOME/Library/Application Support/CallCapture/callcapture.db" "SELECT id FROM session ORDER BY started_at DESC LIMIT 1;")
cat "$DIR/${ID}_analysis.json"
sqlite3 "$HOME/Library/Application Support/CallCapture/callcapture.db" "SELECT analysis_path FROM session WHERE id='$ID';"
```

Expected: `<id>_analysis.json` exists with `num_speakers: 2` and two speakers (`You`, `Speaker 1`) with non-zero `talk_seconds`/`words`; the DB `analysis_path` is populated. (Only one remote speaker for now — Phase 3b adds real multi-speaker separation.) The transcript in the Markdown note shows `You` / `Speaker 1` labels.

---

## Notes for Phase 3b

- 3b adds a Swift `DiarizationProvider` protocol + a `FluidAudioDiarizer` that runs FluidAudio on `<id>_system.wav` and writes `<id>_diarization.json` (the sidecar this phase already consumes) **before** invoking transcription. Swapping to a pyannote (Python) provider, or a cloud one, only changes who writes the sidecar — this phase's worker code is unchanged.
- Interruptions and silence-ratio metrics, acoustic emotion, sentiment, and insights are later phases.

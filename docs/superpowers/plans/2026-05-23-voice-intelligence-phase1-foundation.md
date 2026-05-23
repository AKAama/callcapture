# Voice Intelligence — Phase 1: Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add recording types (Call/Meeting, Voice memo, Lecture) end-to-end and migrate all LLM post-processing to OpenRouter (default Gemini 2.5 Flash), so later phases can branch processing by type and call any model.

**Architecture:** A `RecordingType` is chosen in the menu popover, stored on the session (new DB columns), and sent to the Python worker in the `JobRequest`. The worker's Markdown generation calls OpenRouter via a small OpenAI-compatible client instead of the Anthropic SDK. The Swift host passes the OpenRouter key/model to the worker process environment.

**Tech Stack:** Swift 5.9 / SwiftUI / GRDB (macOS app); Python 3.11+ / Pydantic / `openai` SDK / pytest (worker). Reference spec: `docs/superpowers/specs/2026-05-23-voice-intelligence-design.md`.

This phase is foundation only. It does NOT add diarization, metrics, sentiment, emotion, insights, or separate-stem capture — those are later phases. After this phase, recordings carry a type and notes are generated through OpenRouter.

---

## File Structure

**Python worker (`python-worker/`):**
- Modify `app/schemas/models.py` — add `recording_type` to `JobRequest`.
- Create `app/postprocess/openrouter_client.py` — OpenAI-compatible chat client for OpenRouter.
- Modify `app/postprocess/markdown.py` — call OpenRouter instead of Anthropic.
- Modify `pyproject.toml` — add `openai` dependency.
- Create `tests/test_openrouter_client.py`, `tests/test_recording_type_schema.py`.
- Modify `tests/test_schemas.py` if it asserts `JobRequest` fields.

**macOS app (`macos-app/`):**
- Create `Sources/Session/RecordingType.swift` — enum + per-type profile.
- Modify `Sources/Persistence/Database.swift` — v2 migration (`recording_type`, `analysis_path`).
- Modify `Sources/Persistence/SessionRecord.swift` — new columns + conversion.
- Modify `Sources/Session/SessionManager.swift` — `Session.recordingType`/`analysisPath`; `createSession(sourceApp:recordingType:)`.
- Modify `Sources/Settings/SettingsManager.swift` — `openRouterApiKey`, `llmModel`.
- Modify `Sources/Bridge/Models.swift` — `recordingType` in `JobRequest`.
- Modify `Sources/Bridge/PythonBridge.swift` — pass `OPENROUTER_API_KEY` + `OPENROUTER_MODEL` to the worker env.
- Modify `Sources/App/CallCaptureApp.swift` — `AppModel.selectedRecordingType`; thread into `createSession` + `JobRequest`.
- Modify `Sources/App/ContentView.swift` — recording-type picker in popover.
- Modify `Package.swift` + create `Tests/CallCaptureTests/RecordingTypeTests.swift` — add a test target for pure-logic Swift tests.

---

## Task 1: Add `recording_type` to the worker JobRequest

**Files:**
- Modify: `python-worker/app/schemas/models.py`
- Test: `python-worker/tests/test_recording_type_schema.py`

- [ ] **Step 1: Write the failing test**

Create `python-worker/tests/test_recording_type_schema.py`:

```python
from app.schemas.models import JobRequest


def test_jobrequest_defaults_recording_type_to_call_meeting():
    req = JobRequest(job_id="j1", command="transcribe", audio_path="/tmp/a.wav")
    assert req.recording_type == "call_meeting"


def test_jobrequest_accepts_known_recording_types():
    for value in ("call_meeting", "voice_memo", "lecture"):
        req = JobRequest(
            job_id="j", command="transcribe", audio_path="/tmp/a.wav",
            recording_type=value,
        )
        assert req.recording_type == value
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd python-worker && ./.venv/bin/python -m pytest tests/test_recording_type_schema.py -v`
Expected: FAIL — `JobRequest` has no field `recording_type` (or default mismatch).

- [ ] **Step 3: Add the field**

In `python-worker/app/schemas/models.py`, inside `class JobRequest`, add after the `command` field (keep alphabetical-ish grouping with other options):

```python
    recording_type: Literal["call_meeting", "voice_memo", "lecture"] = "call_meeting"
```

(`Literal` is already imported in this file.)

- [ ] **Step 4: Run test to verify it passes**

Run: `cd python-worker && ./.venv/bin/python -m pytest tests/test_recording_type_schema.py -v`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add python-worker/app/schemas/models.py python-worker/tests/test_recording_type_schema.py
git commit -m "feat(worker): add recording_type to JobRequest schema"
```

---

## Task 2: OpenRouter client

**Files:**
- Create: `python-worker/app/postprocess/openrouter_client.py`
- Test: `python-worker/tests/test_openrouter_client.py`
- Modify: `python-worker/pyproject.toml`

- [ ] **Step 1: Add the `openai` dependency**

In `python-worker/pyproject.toml`, in `dependencies`, add `"openai"` (the OpenAI SDK is OpenRouter-compatible). Result:

```toml
dependencies = [
    "pydantic>=2.0",
    "pywhispercpp",
    "anthropic",
    "openai",
    "click",
]
```

Then install: `cd python-worker && ./.venv/bin/pip install -e .`

- [ ] **Step 2: Write the failing test**

Create `python-worker/tests/test_openrouter_client.py`:

```python
from unittest.mock import MagicMock, patch

from app.postprocess.openrouter_client import OpenRouterClient, OpenRouterError


def _fake_completion(content: str):
    msg = MagicMock()
    msg.message.content = content
    resp = MagicMock()
    resp.choices = [msg]
    return resp


def test_complete_json_returns_parsed_dict():
    client = OpenRouterClient(api_key="k", model="google/gemini-2.5-flash")
    with patch.object(client._client.chat.completions, "create",
                      return_value=_fake_completion('{"a": 1}')):
        result = client.complete_json(system="sys", user="usr")
    assert result == {"a": 1}


def test_complete_json_strips_code_fences():
    client = OpenRouterClient(api_key="k", model="m")
    fenced = "```json\n{\"b\": 2}\n```"
    with patch.object(client._client.chat.completions, "create",
                      return_value=_fake_completion(fenced)):
        result = client.complete_json(system="s", user="u")
    assert result == {"b": 2}


def test_missing_api_key_raises():
    import pytest
    with pytest.raises(OpenRouterError):
        OpenRouterClient(api_key="", model="m")
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd python-worker && ./.venv/bin/python -m pytest tests/test_openrouter_client.py -v`
Expected: FAIL — module `openrouter_client` does not exist.

- [ ] **Step 4: Implement the client**

Create `python-worker/app/postprocess/openrouter_client.py`:

```python
"""Thin OpenAI-compatible client for the OpenRouter API."""

from __future__ import annotations

import json
from typing import Any

from openai import OpenAI

OPENROUTER_BASE_URL = "https://openrouter.ai/api/v1"


class OpenRouterError(Exception):
    """Raised when OpenRouter is misconfigured or returns an unusable response."""


class OpenRouterClient:
    """Calls chat-completion models hosted by OpenRouter.

    Args:
        api_key: OpenRouter API key.
        model: Model slug, e.g. ``google/gemini-2.5-flash``.
    """

    def __init__(self, api_key: str, model: str) -> None:
        if not api_key:
            raise OpenRouterError("OpenRouter API key is missing")
        self.model = model
        self._client = OpenAI(api_key=api_key, base_url=OPENROUTER_BASE_URL)

    def complete_json(
        self, system: str, user: str, max_tokens: int = 2048
    ) -> dict[str, Any]:
        """Send a system+user prompt and parse the reply as JSON.

        Raises:
            OpenRouterError: on API failure or unparseable JSON.
        """
        try:
            resp = self._client.chat.completions.create(
                model=self.model,
                max_tokens=max_tokens,
                messages=[
                    {"role": "system", "content": system},
                    {"role": "user", "content": user},
                ],
            )
            raw = resp.choices[0].message.content or ""
        except Exception as exc:  # noqa: BLE001 - surface as our error type
            raise OpenRouterError(f"OpenRouter request failed: {exc}") from exc

        return self._parse_json(raw)

    @staticmethod
    def _parse_json(raw: str) -> dict[str, Any]:
        cleaned = raw.strip()
        if cleaned.startswith("```"):
            lines = [ln for ln in cleaned.split("\n") if not ln.startswith("```")]
            cleaned = "\n".join(lines)
        try:
            data = json.loads(cleaned)
        except json.JSONDecodeError as exc:
            raise OpenRouterError(f"Invalid JSON from model: {exc}") from exc
        if not isinstance(data, dict):
            raise OpenRouterError("Model JSON was not an object")
        return data
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd python-worker && ./.venv/bin/python -m pytest tests/test_openrouter_client.py -v`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add python-worker/app/postprocess/openrouter_client.py python-worker/tests/test_openrouter_client.py python-worker/pyproject.toml
git commit -m "feat(worker): add OpenRouter chat client"
```

---

## Task 3: Route markdown generation through OpenRouter

**Files:**
- Modify: `python-worker/app/postprocess/markdown.py`
- Test: `python-worker/tests/test_markdown_openrouter.py`

- [ ] **Step 1: Write the failing test**

Create `python-worker/tests/test_markdown_openrouter.py`:

```python
from unittest.mock import MagicMock, patch

from app.postprocess.markdown import generate_markdown
from app.schemas.models import TranscriptSegment


def _segments():
    return [TranscriptSegment(start=0.0, end=2.0, text="Hello there", speaker=None)]


def test_uses_openrouter_when_key_present(monkeypatch):
    monkeypatch.setenv("OPENROUTER_API_KEY", "key")
    monkeypatch.setenv("OPENROUTER_MODEL", "google/gemini-2.5-flash")
    fake = MagicMock()
    fake.complete_json.return_value = {
        "title": "T", "summary": "S", "key_points": ["k"],
        "decisions": [], "action_items": [],
    }
    with patch("app.postprocess.markdown.OpenRouterClient", return_value=fake):
        note = generate_markdown(_segments())
    assert note.title == "T"
    assert note.summary == "S"
    fake.complete_json.assert_called_once()


def test_falls_back_when_no_key(monkeypatch):
    monkeypatch.delenv("OPENROUTER_API_KEY", raising=False)
    note = generate_markdown(_segments())
    assert note.title  # fallback still produces a note
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd python-worker && ./.venv/bin/python -m pytest tests/test_markdown_openrouter.py -v`
Expected: FAIL — `markdown` module does not import `OpenRouterClient`.

- [ ] **Step 3: Rewrite the LLM path in `markdown.py`**

In `python-worker/app/postprocess/markdown.py`, replace the import block and the `generate_markdown` function body. Replace the top import:

```python
from app.postprocess.openrouter_client import OpenRouterClient, OpenRouterError
from app.schemas.models import MarkdownNote, TranscriptSegment
```

Replace the entire `generate_markdown` function with:

```python
def generate_markdown(
    segments: list[TranscriptSegment],
    profile: str = "meeting_notes",
    llm_engine: str = "openrouter",
) -> MarkdownNote:
    """Generate a structured MarkdownNote from transcript segments via OpenRouter.

    Falls back to rule-based extraction when no API key is configured or the
    model call fails.

    Args:
        segments: Transcript segments.
        profile: Markdown profile (used during rendering).
        llm_engine: Retained for compatibility; OpenRouter is always used.
    """
    api_key = os.environ.get("OPENROUTER_API_KEY", "")
    model = os.environ.get("OPENROUTER_MODEL", "google/gemini-2.5-flash")
    if not api_key:
        sys.stderr.write('{"warning": "OPENROUTER_API_KEY not set, using fallback"}\n')
        sys.stderr.flush()
        return _fallback_extraction(segments)

    try:
        client = OpenRouterClient(api_key=api_key, model=model)
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
    except OpenRouterError as exc:
        sys.stderr.write(
            json.dumps({"warning": f"OpenRouter failed: {exc}, using fallback"}) + "\n"
        )
        sys.stderr.flush()
        return _fallback_extraction(segments)
```

The existing `_parse_llm_response` helper is now unused — delete it.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd python-worker && ./.venv/bin/python -m pytest tests/test_markdown_openrouter.py -v`
Expected: PASS (2 tests).

- [ ] **Step 5: Run the full worker test suite**

Run: `cd python-worker && ./.venv/bin/python -m pytest -q`
Expected: all tests pass (existing + new).

- [ ] **Step 6: Commit**

```bash
git add python-worker/app/postprocess/markdown.py python-worker/tests/test_markdown_openrouter.py
git commit -m "feat(worker): generate markdown via OpenRouter with fallback"
```

---

## Task 4: Swift `RecordingType` enum + profile (with test target)

**Files:**
- Create: `macos-app/Sources/Session/RecordingType.swift`
- Modify: `macos-app/Package.swift`
- Create: `macos-app/Tests/CallCaptureTests/RecordingTypeTests.swift`

- [ ] **Step 1: Create the enum + profile**

Create `macos-app/Sources/Session/RecordingType.swift`:

```swift
import Foundation

/// The kind of audio a session captured. Determines which processing runs
/// (diarization on/off) and which note template/insight prompt is used.
/// Metrics, sentiment, acoustic emotion, and insights run for every type.
enum RecordingType: String, Codable, CaseIterable, Sendable, Identifiable {
    case callMeeting = "call_meeting"
    case voiceMemo = "voice_memo"
    case lecture

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .callMeeting: "Call / Meeting"
        case .voiceMemo: "Voice Memo"
        case .lecture: "Lecture"
        }
    }

    /// Whether speaker diarization runs for this type.
    var diarize: Bool {
        switch self {
        case .callMeeting: true
        case .voiceMemo: false
        case .lecture: false
        }
    }

    /// Identifier for the note template / LLM prompt template used downstream.
    var noteTemplate: String {
        switch self {
        case .callMeeting: "call_meeting"
        case .voiceMemo: "voice_memo"
        case .lecture: "lecture"
        }
    }
}
```

- [ ] **Step 2: Add a test target to `Package.swift`**

In `macos-app/Package.swift`, add a test target after the executable target (inside `targets:`):

```swift
        .testTarget(
            name: "CallCaptureTests",
            dependencies: ["CallCapture"],
            path: "Tests/CallCaptureTests"
        )
```

- [ ] **Step 3: Write the failing test**

Create `macos-app/Tests/CallCaptureTests/RecordingTypeTests.swift`:

```swift
import Testing
@testable import CallCapture

@Suite("RecordingType")
struct RecordingTypeTests {
    @Test("call/meeting diarizes, others do not")
    func diarizeFlags() {
        #expect(RecordingType.callMeeting.diarize == true)
        #expect(RecordingType.voiceMemo.diarize == false)
        #expect(RecordingType.lecture.diarize == false)
    }

    @Test("raw values are stable for persistence")
    func rawValues() {
        #expect(RecordingType.callMeeting.rawValue == "call_meeting")
        #expect(RecordingType.voiceMemo.rawValue == "voice_memo")
        #expect(RecordingType.lecture.rawValue == "lecture")
    }

    @Test("all cases have non-empty display names")
    func displayNames() {
        for type in RecordingType.allCases {
            #expect(!type.displayName.isEmpty)
        }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd macos-app && swift test --filter RecordingTypeTests`
Expected: PASS (3 tests). If the executable target cannot be imported, confirm `@testable import CallCapture` resolves; the executable target name is `CallCapture`.

- [ ] **Step 5: Commit**

```bash
git add macos-app/Sources/Session/RecordingType.swift macos-app/Package.swift macos-app/Tests/CallCaptureTests/RecordingTypeTests.swift
git commit -m "feat(app): add RecordingType enum and Swift test target"
```

---

## Task 5: DB migration v2 — `recording_type` + `analysis_path`

**Files:**
- Modify: `macos-app/Sources/Persistence/Database.swift:60-100`
- Test: `macos-app/Tests/CallCaptureTests/DatabaseMigrationTests.swift`

- [ ] **Step 1: Write the failing test**

Create `macos-app/Tests/CallCaptureTests/DatabaseMigrationTests.swift`:

```swift
import Testing
import GRDB
@testable import CallCapture

@Suite("Database migration")
struct DatabaseMigrationTests {
    @Test("session table has recording_type and analysis_path columns")
    func newColumnsExist() throws {
        let dir = NSTemporaryDirectory()
        let path = dir + "cc-test-\(UUID().uuidString).db"
        let db = try AppDatabase(path: path)
        let columns = try db.dbPool.read { database in
            try database.columns(in: "session").map(\.name)
        }
        #expect(columns.contains("recording_type"))
        #expect(columns.contains("analysis_path"))
        try? FileManager.default.removeItem(atPath: path)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd macos-app && swift test --filter DatabaseMigrationTests`
Expected: FAIL — columns not present.

- [ ] **Step 3: Add migration v2**

In `macos-app/Sources/Persistence/Database.swift`, inside the `migrator` computed property, after the `registerMigration("v1_createTables")` block and before `return migrator`, add:

```swift
        migrator.registerMigration("v2_recordingTypeAndAnalysis") { db in
            try db.alter(table: "session") { table in
                table.add(column: "recording_type", .text)
                    .notNull()
                    .defaults(to: "call_meeting")
                table.add(column: "analysis_path", .text)
            }
        }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd macos-app && swift test --filter DatabaseMigrationTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add macos-app/Sources/Persistence/Database.swift macos-app/Tests/CallCaptureTests/DatabaseMigrationTests.swift
git commit -m "feat(app): migrate session table with recording_type and analysis_path"
```

---

## Task 6: Thread recording type + analysis path through `SessionRecord` and `Session`

**Files:**
- Modify: `macos-app/Sources/Persistence/SessionRecord.swift`
- Modify: `macos-app/Sources/Session/SessionManager.swift`

- [ ] **Step 1: Add columns to `SessionRecord`**

In `macos-app/Sources/Persistence/SessionRecord.swift`, add stored properties after `audioPath`:

```swift
    var recordingType: String
    var analysisPath: String?
```

Add to `CodingKeys`:

```swift
        case recordingType = "recording_type"
        case analysisPath = "analysis_path"
```

- [ ] **Step 2: Add fields to the domain `Session`**

In `macos-app/Sources/Session/SessionManager.swift`, in `struct Session`, add after `transcriptMarkdownPath`:

```swift
    var recordingType: String = "call_meeting"
    var analysisPath: String? = nil
```

Add to its `CodingKeys`:

```swift
        case recordingType = "recording_type"
        case analysisPath = "analysis_path"
```

- [ ] **Step 3: Update `SessionRecord` conversions**

In `SessionRecord.toSession()`, pass the new fields:

```swift
            transcriptMarkdownPath: transcriptMarkdownPath,
            recordingType: recordingType,
            analysisPath: analysisPath,
            status: status
```

In `SessionRecord.init(from:)`, set:

```swift
        self.recordingType = session.recordingType
        self.analysisPath = session.analysisPath
```

- [ ] **Step 4: Accept `recordingType` in `createSession`**

In `SessionManager.createSession`, change the signature and the `Session(...)` construction:

```swift
    @discardableResult
    func createSession(
        sourceApp: String,
        recordingType: RecordingType = .callMeeting
    ) -> Session {
```

and in the `Session(` initializer add `recordingType: recordingType.rawValue,` before `status:`.

- [ ] **Step 5: Verify it builds**

Run: `cd macos-app && swift build`
Expected: `Build complete!` with no errors. (`finalizeSession`/`updateSessionStatus` reconstruct `Session` with default `recordingType`; preserve it by reading from `currentSession` — verify the finalized session keeps `session.recordingType`: in `finalizeSession`, add `recordingType: session.recordingType, analysisPath: session.analysisPath,` to the `Session(` it builds.)

- [ ] **Step 6: Commit**

```bash
git add macos-app/Sources/Persistence/SessionRecord.swift macos-app/Sources/Session/SessionManager.swift
git commit -m "feat(app): carry recording_type and analysis_path on sessions"
```

---

## Task 7: Settings — OpenRouter key + model

**Files:**
- Modify: `macos-app/Sources/Settings/SettingsManager.swift`

- [ ] **Step 1: Add settings properties**

In `macos-app/Sources/Settings/SettingsManager.swift`, after the `llmApiKey` block, add:

```swift
    var openRouterApiKey: String = "" {
        didSet {
            KeychainHelper.save(openRouterApiKey, for: "openrouter_api_key")
            persist("openrouter_api_key", "keychain")
        }
    }

    var llmModel: String = "google/gemini-2.5-flash" {
        didSet { persist("llm_model", llmModel) }
    }
```

- [ ] **Step 2: Load them in `loadAll()`**

In `loadAll()`, after the `markdown_profile` line, add:

```swift
        if let raw = rows["llm_model"], !raw.isEmpty { llmModel = raw }
```

and after the existing keychain loads, add:

```swift
        openRouterApiKey = KeychainHelper.load(for: "openrouter_api_key")
```

- [ ] **Step 3: Verify it builds**

Run: `cd macos-app && swift build`
Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add macos-app/Sources/Settings/SettingsManager.swift
git commit -m "feat(app): add OpenRouter API key and model settings"
```

---

## Task 8: Send `recordingType` in the JobRequest

**Files:**
- Modify: `macos-app/Sources/Bridge/Models.swift`
- Modify: `macos-app/Sources/App/CallCaptureApp.swift`

- [ ] **Step 1: Add `recordingType` to the Swift `JobRequest`**

In `macos-app/Sources/Bridge/Models.swift`, in `struct JobRequest`, add `let recordingType: String` after `remoteProvider`, and to its `CodingKeys` add `case recordingType = "recording_type"`. In the `transcribe(session:settings:)` factory, add `recordingType: session.recordingType,` to the `JobRequest(` initializer. In the other (`transcribe(audioPath:...)`) factory, add `recordingType: "call_meeting",`.

- [ ] **Step 2: Verify it builds**

Run: `cd macos-app && swift build`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add macos-app/Sources/Bridge/Models.swift
git commit -m "feat(app): include recording_type in worker JobRequest"
```

---

## Task 9: Pass OpenRouter env into the worker process

**Files:**
- Modify: `macos-app/Sources/Bridge/PythonBridge.swift`
- Modify: `macos-app/Sources/App/CallCaptureApp.swift`

- [ ] **Step 1: Let the bridge accept LLM env**

In `macos-app/Sources/Bridge/PythonBridge.swift`, add a stored property near the top of the class:

```swift
    /// Extra environment passed to the worker process (e.g. OpenRouter creds).
    var llmEnvironment: [String: String] = [:]
```

In `executeWorker(request:)`, after `let process = Process()` and before `try process.run()` (specifically right after the dev/prod `if devMode { … } else { … }` block that sets `executableURL`), set the environment:

```swift
        var env = ProcessInfo.processInfo.environment
        for (key, value) in llmEnvironment where !value.isEmpty {
            env[key] = value
        }
        process.environment = env
```

- [ ] **Step 2: Populate it from settings before transcribing**

In `macos-app/Sources/App/CallCaptureApp.swift`, in `transcribeSession(_:)`, immediately before `let result = try await pythonBridge.runJob(request: request)`, add:

```swift
        pythonBridge.llmEnvironment = [
            "OPENROUTER_API_KEY": settingsManager.openRouterApiKey,
            "OPENROUTER_MODEL": settingsManager.llmModel,
        ]
```

- [ ] **Step 3: Verify it builds**

Run: `cd macos-app && swift build`
Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add macos-app/Sources/Bridge/PythonBridge.swift macos-app/Sources/App/CallCaptureApp.swift
git commit -m "feat(app): pass OpenRouter credentials to the worker process"
```

---

## Task 10: Recording-type picker in the popover

**Files:**
- Modify: `macos-app/Sources/App/CallCaptureApp.swift`
- Modify: `macos-app/Sources/App/ContentView.swift`

- [ ] **Step 1: Add selection state to `AppModel`**

In `macos-app/Sources/App/CallCaptureApp.swift`, in `AppModel`, add after `selectedMicUID`:

```swift
    var selectedRecordingType: RecordingType = .callMeeting
```

In `startRecording()`, pass it into `createSession`:

```swift
            let session = sessionManager.createSession(
                sourceApp: "System Audio",
                recordingType: selectedRecordingType
            )
```

- [ ] **Step 2: Add the picker to the popover**

In `macos-app/Sources/App/ContentView.swift`, inside `devicePickers(appModel:)` `VStack`, add as the first control (above the Output picker):

```swift
            Picker("Type", selection: $appModel.selectedRecordingType) {
                ForEach(RecordingType.allCases) { type in
                    Text(type.displayName).tag(type)
                }
            }
```

- [ ] **Step 3: Verify it builds**

Run: `cd macos-app && swift build`
Expected: `Build complete!`

- [ ] **Step 4: Manual verification**

Run: `./run-dev.sh`. Open the menu popover. Confirm a **Type** picker (Call / Meeting, Voice Memo, Lecture) appears above the Output/Mic pickers and defaults to Call / Meeting.

- [ ] **Step 5: Commit**

```bash
git add macos-app/Sources/App/CallCaptureApp.swift macos-app/Sources/App/ContentView.swift
git commit -m "feat(app): recording-type picker in the menu popover"
```

---

## Task 11: End-to-end verification

- [ ] **Step 1: Build the worker + app**

Run: `cd python-worker && ./.venv/bin/python -m pytest -q` → all pass.
Run: `cd macos-app && swift build && swift test` → build + tests pass.

- [ ] **Step 2: Set the OpenRouter key**

Launch via `./run-dev.sh`, open Settings, paste the OpenRouter API key, confirm `llm_model` shows `google/gemini-2.5-flash`.

- [ ] **Step 3: Record + transcribe**

Pick a recording type, record ~10s with audio, stop. After transcription completes, open the session in Session Detail and confirm the Markdown note rendered (now produced via OpenRouter). Check the OSLog stream (`scripts/debug-logstream.sh`) shows no `OPENROUTER_API_KEY not set` warning.

- [ ] **Step 4: Confirm persistence**

Run: `sqlite3 "$HOME/Library/Application Support/CallCapture/callcapture.db" "SELECT recording_type FROM session ORDER BY started_at DESC LIMIT 1;"`
Expected: the type you selected (e.g. `voice_memo`).

---

## Notes for later phases (not in this plan)

- **Phase 2:** separate-stem capture (`_mic.wav` / `_system.wav`) in `AudioCaptureManager`.
- **Phase 3:** local pyannote diarization + speaker attribution + talk metrics.
- **Phase 4:** acoustic emotion (SER) + sentiment via OpenRouter.
- **Phase 5:** type-tailored insight prompts + per-type Markdown note shapes.
- **Phase 6:** Session Detail "Conversation Insights" UI + type re-process action.

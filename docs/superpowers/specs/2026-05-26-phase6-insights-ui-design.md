# Phase 6 — Conversation Insights UI + Type Selector + Re-process (Design)

**Date:** 2026-05-26
**Scope:** macOS Swift app only (`macos-app/`). No Python worker changes.
**Builds on:** Phase 5 (worker writes `<id>_analysis.json` with `ConversationAnalysis{recording_type, num_speakers, speakers, warnings, sentiment, insights}`).
**Master spec:** `docs/superpowers/specs/2026-05-23-voice-intelligence-design.md` §8 (Session Detail: Conversation Insights GroupBox + recording-type selector + Re-process).

## 1. Goal

Surface the worker's conversation analysis in the Session Detail screen as a structured
**Conversation Insights** panel, make the **recording type editable** after recording, and
add an explicit **Re-process** action that re-runs the pipeline with the corrected type.

## 2. Decisions (locked during brainstorming)

1. **Panel scope = metrics + sentiment/emotion + actions.** The structured panel renders
   per-speaker talk-ratio bars, per-speaker sentiment + acoustic emotion, overall sentiment, and
   the actionable insight fields (`recommended_actions`, `action_items`). The rich per-type prose
   (summary, dynamics, opportunities, outline, key concepts, Q&A, takeaways, reflections) stays in
   the existing Markdown-note preview — no duplicate per-type rendering in SwiftUI.
2. **Recording-type Picker persists immediately; Re-process is explicit.** Changing the Picker
   persists the new type at once; re-running the (expensive) pipeline is a deliberate button press,
   never automatic.

## 3. Current State (what exists)

- `Sources/UI/SessionDetailView.swift`: sections — header, Details (metadata grid), Audio, Raw
  Transcript, Markdown Note (preview + Open), error, action buttons (Transcribe / Re-transcribe /
  Save to Vault / Export). Reads `current.transcriptRawPath` / `transcriptMarkdownPath`. **Does not
  read `analysisPath`. Does not show or edit `recordingType`.**
- `Sources/Session/SessionManager.swift`: `session(id:)`, `updateSessionPaths`, `updateSessionStatus`,
  `updateAnalysisPath`. **No `updateRecordingType`.** Persists to the `session` SQLite table (which
  already has the `recording_type` column) and keeps an in-memory `recentSessions` array.
- `Sources/Session/RecordingType.swift`: enum `callMeeting` / `voiceMemo` / `lecture`, `String`
  raw values `call_meeting` / `voice_memo` / `lecture`, with `displayName`.
- `Sources/App/CallCaptureApp.swift`: `AppModel.transcribeSession(session)` builds
  `JobRequest.transcribe(session:settings:)` (which reads `session.recordingType`), sets
  `pythonBridge.llmEnvironment`, diarizes, runs the worker, then `updateSessionPaths` +
  `updateAnalysisPath`. The existing Re-transcribe button already re-runs this flow.
- `Sources/Bridge/Models.swift`: `JobRequest`, `ProgressUpdate`, `JobResult` (carries
  `analysisPath`). **No Decodable mirror of `ConversationAnalysis`.**
- Tests live in `macos-app/Tests/CallCaptureTests/` (XCTest; `DatabaseMigrationTests` shows the
  temp-DB pattern; `RecordingTypeTests` exists).

## 4. New / Changed Components

### 4.1 `Sources/Bridge/AnalysisModels.swift` (new)

Decodable mirror of the worker's `<id>_analysis.json`. All structs `Decodable`; **every field
decoded with `decodeIfPresent` + a default** so a partial, older, or future-extended JSON never
throws.

```swift
struct ConversationAnalysis: Decodable, Sendable {
    let recordingType: String          // "recording_type"; default "call_meeting"
    let numSpeakers: Int               // "num_speakers"; default 0
    let speakers: [SpeakerStats]       // default []
    let warnings: [String]             // default []
    let sentiment: Sentiment?          // default nil
    let insights: Insights?            // default nil
}

struct SpeakerStats: Decodable, Sendable {
    let label: String                  // default ""
    let isSelf: Bool                   // "is_self"; default false
    let talkSeconds: Double            // "talk_seconds"; default 0
    let talkRatio: Double              // "talk_ratio" (0..1); default 0
    let words: Int                     // default 0
    let wordsPerMin: Double            // "words_per_min"; default 0
    let turns: Int                     // default 0
    let longestMonologueSec: Double    // "longest_monologue_sec"; default 0
    let dominantEmotion: String?       // "dominant_emotion"; default nil
    let valence: Double?               // default nil
    let arousal: Double?               // default nil
}

struct SpeakerSentiment: Decodable, Sendable {
    let label: String                  // default "neutral"
    let score: Double                  // default 0
}

struct ArcPoint: Decodable, Sendable {
    let t: Double                      // default 0
    let score: Double                  // default 0
}

struct Sentiment: Decodable, Sendable {
    let overall: String                // default "neutral"
    let overallScore: Double           // "overall_score"; default 0
    let bySpeaker: [String: SpeakerSentiment]  // "by_speaker"; default [:]
    let arc: [ArcPoint]                // default []  (decoded, not drawn in v1)
}

struct Insights: Decodable, Sendable {
    let title: String                  // default ""
    let summary: String                // default ""
    let keyPoints: [String]            // "key_points"; default []
    let actionItems: [String]          // "action_items"; default []
    let recommendedActions: [String]   // "recommended_actions"; default []
    let dynamics: String               // default ""
    let opportunities: [String]        // default []
    let reflections: [String]          // default []
    let outline: [String]              // default []
    let keyConcepts: [String]          // "key_concepts"; default []
    let qa: [String]                   // default []
    let takeaways: [String]            // default []
}

extension ConversationAnalysis {
    /// Decode the analysis sidecar; returns nil on missing file or unparseable JSON.
    static func load(fromPath path: String) -> ConversationAnalysis?
}
```

Each type implements `init(from:)` using `decodeIfPresent(...) ?? default` for every field (manual
inits, snake_case `CodingKeys`). `load` reads the file via `FileManager`, returns `nil` on
missing-file / read / `JSONDecoder` error (logged, not thrown).

### 4.2 `Sources/UI/ConversationInsightsView.swift` (new)

A focused subview rendering a decoded `ConversationAnalysis`. Pure presentation; no I/O.

- **Overall row:** `sentiment.overall (±score)` + `num_speakers` — only when `sentiment != nil`.
- **Per-speaker rows** (one per `speakers`): `label` (bold when `isSelf`), a **talk-ratio bar**
  (horizontal bar whose width = `talkRatio`, with a `NN%` label), and — when present —
  `dominantEmotion` + signed `valence`. Bar implemented with a simple `GeometryReader`/overlay or
  capsule fill (no external chart lib).
- **Recommended actions:** `insights.recommendedActions` as `•` bullets — omitted when empty.
- **Action items:** `insights.actionItems` as display-only `☐` rows — omitted when empty.
- The whole view returns empty (renders nothing) when there are no speakers, no sentiment, and no
  insight actions.

### 4.3 `SessionDetailView.swift` (edit)

- Add `@State private var analysis: ConversationAnalysis?`. In `reload()`, set it from
  `current.analysisPath.flatMap(ConversationAnalysis.load(fromPath:))`.
- Add an **`insightsSection`**: `GroupBox("Conversation Insights") { ConversationInsightsView(analysis: analysis) }`
  rendered only when `analysis` is non-nil and has content. Placed after `markdownSection`.
- Add a **recording-type Picker** to `metadataSection` (Details): a `Picker` over
  `RecordingType.allCases` (display `displayName`), selection bound to a local `@State` seeded from
  `current.recordingType`. `onChange` → `appModel.sessionManager.updateRecordingType(id: session.id, recordingType: newValue.rawValue)` then `reload()`.
- **Re-process:** rename the `status == "transcribed"` button label to **"Re-process"** (same
  `transcribe()` → `appModel.transcribeSession` flow; it reads the now-updated `session.recordingType`).
  After it completes, `reload()` already refreshes `liveSession`; ensure it also refreshes `analysis`.

`RecordingType` gains `CaseIterable` (for the Picker) and an `init?(rawValue:)` is already provided
by the `String` raw-value enum.

### 4.4 `SessionManager.swift` (edit)

Add, mirroring `updateAnalysisPath`:

```swift
func updateRecordingType(id: String, recordingType: String) {
    // UPDATE session SET recording_type = ? WHERE id = ?
    // then update the matching entry in the in-memory recentSessions array
}
```

## 5. Data Flow

```
SessionDetailView.onAppear/reload
  ├─ liveSession = sessionManager.session(id:)
  └─ analysis    = ConversationAnalysis.load(current.analysisPath)   // nil-safe

Picker(type) change → sessionManager.updateRecordingType(id:, rawValue) → reload()
Re-process tap      → appModel.transcribeSession(session)  // reads session.recordingType
                     → worker rewrites _notes.md + _analysis.json
                     → reload() re-loads liveSession + re-decodes analysis
```

## 6. Error Handling / Degradation

- Missing / pre-Phase-5 / partial / future `analysis.json` → `load` returns a best-effort value or
  `nil`; the panel hides or shows only the fields that decoded. Never crashes.
- `updateRecordingType` on a missing id is a no-op (consistent with the other update methods).
- Re-process failures surface through the existing `appModel.state == .error` / `lastError` path
  already handled in `transcribe()`.

## 7. Testing (XCTest, `Tests/CallCaptureTests/`)

- **`AnalysisModelsTests`:** decode a full analysis.json fixture → all fields correct (incl.
  `by_speaker`, nested `insights`); decode a minimal `{}` / partial JSON → defaults, no throw;
  `load(fromPath:)` on a nonexistent path → `nil`; malformed JSON → `nil`.
- **`SessionManagerTests` (new or extended):** `updateRecordingType` writes the `recording_type`
  column and updates the in-memory session (temp-DB pattern from `DatabaseMigrationTests`).
- **`RecordingTypeTests` (extend):** `CaseIterable` covers all three; `rawValue` round-trips the
  worker strings.
- SwiftUI views are not unit-tested (no ViewInspector dependency); presentation logic is kept thin
  and any non-trivial formatting (percent, signed score) lives in small testable helpers on the
  models or `ConversationInsightsView`.

## 8. Out of Scope

- Emotional **arc** visualization (the `arc` array is decoded but not drawn in v1 — deferred seam).
- Any Python worker changes.
- New analysis fields or a separate "analyze-only" worker command (re-process re-runs the full
  transcribe pipeline, matching today's monolithic job).
- Live/streaming insights; multi-session comparison.

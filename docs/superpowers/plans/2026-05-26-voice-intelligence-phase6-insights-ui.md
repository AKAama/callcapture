# Phase 6 — Conversation Insights UI + Type Selector + Re-process Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show the worker's `<id>_analysis.json` as a structured "Conversation Insights" panel in Session Detail, make the recording type editable, and add an explicit Re-process action that re-runs the pipeline with the corrected type.

**Architecture:** A new `Decodable` mirror of the worker's `ConversationAnalysis` (tolerant of missing/partial fields, never throws to the caller) is loaded from the session's `analysisPath` and rendered by a focused `ConversationInsightsView` (talk-ratio bars + per-speaker sentiment/emotion + recommended actions / action items). `SessionDetailView` gains the panel, an editable recording-type `Picker` (persisted via a new `SessionManager.updateRecordingType`), and a relabeled "Re-process" button reusing the existing `transcribeSession` flow.

**Tech Stack:** Swift 5.9, SwiftUI (macOS 14+), GRDB (SQLite), Swift Testing (`import Testing`, `@Suite`/`@Test`/`#expect`). Build/test from `macos-app/`: `swift build` and `swift test`. Baseline: 22 tests in 7 suites pass.

**Spec:** `docs/superpowers/specs/2026-05-26-phase6-insights-ui-design.md`

---

## File Structure

- **Create** `macos-app/Sources/Bridge/AnalysisModels.swift` — `Decodable` mirror of `<id>_analysis.json` (`ConversationAnalysis` + `SpeakerStats`/`Sentiment`/`SpeakerSentiment`/`ArcPoint`/`Insights`), `hasContent`, and `load(fromPath:)`. Plus `InsightsFormat` (pure percent/signed string helpers).
- **Create** `macos-app/Sources/UI/ConversationInsightsView.swift` — presentation subview rendering a decoded `ConversationAnalysis`.
- **Modify** `macos-app/Sources/Session/SessionManager.swift` — add `updateRecordingType(id:recordingType:)`.
- **Modify** `macos-app/Sources/UI/SessionDetailView.swift` — load analysis, add insights GroupBox, recording-type Picker, relabel Re-process.
- **Create tests** `macos-app/Tests/CallCaptureTests/AnalysisModelsTests.swift`, `macos-app/Tests/CallCaptureTests/SessionManagerRecordingTypeTests.swift`, `macos-app/Tests/CallCaptureTests/InsightsFormatTests.swift`.

Existing facts the tasks rely on (verified):
- `RecordingType` (`Sources/Session/RecordingType.swift`) is `enum RecordingType: String, Codable, CaseIterable, Sendable, Identifiable` with cases `callMeeting="call_meeting"`, `voiceMemo="voice_memo"`, `lecture` (raw `"lecture"`), `var id { rawValue }`, `var displayName`.
- `Session` (`Sources/Session/SessionManager.swift`) has `var recordingType: String`, `var analysisPath: String?`, `transcriptMarkdownPath`, `status`.
- `SessionManager.session(id:)` reads from the DB (`SessionRecord.fetchOne → toSession()`), so `SessionDetailView.reload()` always sees fresh persisted state.
- `SessionManager.updateAnalysisPath(id:analysisPath:)` is the closest sibling: `dbPool.write { fetchOne → mutate record → record.update(db) }`. `SessionRecord` has a mutable `recordingType`.
- `SessionManager(database: AppDatabase)` + `@discardableResult func createSession(sourceApp:recordingType:) -> Session` (persists a row) are usable in tests. `AppDatabase(path:)` makes a temp DB (see `DatabaseMigrationTests`).
- `SessionDetailView` sections: `headerSection, metadataSection, audioSection, transcriptSection, markdownSection, errorSection, actionButtons`; `private var current: Session { liveSession ?? session }`; `reload()` sets `liveSession`. Action buttons show "Transcribe" when `status=="completed"` and "Re-transcribe" when `status=="transcribed"`, both via `transcribe()` → `appModel.transcribeSession(session)`.

---

## Task 1: Analysis Decodable models + load + formatting helpers

**Files:**
- Create: `macos-app/Sources/Bridge/AnalysisModels.swift`
- Test: `macos-app/Tests/CallCaptureTests/AnalysisModelsTests.swift`

- [ ] **Step 1: Write the failing test** — `macos-app/Tests/CallCaptureTests/AnalysisModelsTests.swift`

```swift
import Foundation
import Testing
@testable import CallCapture

@Suite("ConversationAnalysis decoding")
struct AnalysisModelsTests {
    private func decode(_ json: String) -> ConversationAnalysis? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ConversationAnalysis.self, from: data)
    }

    @Test("decodes a full analysis payload")
    func full() throws {
        let json = #"""
        {
          "recording_type": "call_meeting",
          "num_speakers": 2,
          "speakers": [
            {"label":"You","is_self":true,"talk_seconds":30,"talk_ratio":0.6,"words":100,"words_per_min":140,"turns":5,"longest_monologue_sec":12,"dominant_emotion":"calm","valence":0.6,"arousal":0.2},
            {"label":"Speaker 1","is_self":false,"talk_ratio":0.4,"words":60,"words_per_min":120,"turns":4}
          ],
          "warnings": [],
          "sentiment": {"overall":"positive","overall_score":0.5,"by_speaker":{"You":{"label":"positive","score":0.6}},"arc":[{"t":10,"score":0.2}]},
          "insights": {"title":"Deal","summary":"Closed.","recommended_actions":["send proposal"],"action_items":["follow up Monday"],"dynamics":"You led."}
        }
        """#
        let a = decode(json)
        #expect(a != nil)
        #expect(a?.recordingType == "call_meeting")
        #expect(a?.numSpeakers == 2)
        #expect(a?.speakers.count == 2)
        #expect(a?.speakers.first?.isSelf == true)
        #expect(a?.speakers.first?.talkRatio == 0.6)
        #expect(a?.speakers.first?.dominantEmotion == "calm")
        #expect(a?.speakers[1].dominantEmotion == nil)      // absent -> nil
        #expect(a?.sentiment?.overall == "positive")
        #expect(a?.sentiment?.overallScore == 0.5)
        #expect(a?.sentiment?.bySpeaker["You"]?.score == 0.6)
        #expect(a?.sentiment?.arc.first?.t == 10)
        #expect(a?.insights?.recommendedActions == ["send proposal"])
        #expect(a?.insights?.actionItems == ["follow up Monday"])
        #expect(a?.hasContent == true)
    }

    @Test("partial payload falls back to defaults without throwing")
    func partial() throws {
        let a = decode("{}")
        #expect(a != nil)
        #expect(a?.recordingType == "call_meeting")
        #expect(a?.numSpeakers == 0)
        #expect(a?.speakers.isEmpty == true)
        #expect(a?.sentiment == nil)
        #expect(a?.insights == nil)
        #expect(a?.hasContent == false)
    }

    @Test("hasContent is true when only speakers are present")
    func hasContentSpeakers() throws {
        let a = decode(#"{"speakers":[{"label":"You","talk_ratio":1.0}]}"#)
        #expect(a?.hasContent == true)
    }

    @Test("load returns nil for a missing file")
    func missingFile() {
        let path = NSTemporaryDirectory() + "cc-missing-\(UUID().uuidString).json"
        #expect(ConversationAnalysis.load(fromPath: path) == nil)
    }

    @Test("load returns nil for malformed json")
    func malformed() throws {
        let path = NSTemporaryDirectory() + "cc-bad-\(UUID().uuidString).json"
        try "not json".data(using: .utf8)!.write(to: URL(fileURLWithPath: path))
        #expect(ConversationAnalysis.load(fromPath: path) == nil)
        try? FileManager.default.removeItem(atPath: path)
    }

    @Test("load decodes a written file")
    func loadFile() throws {
        let path = NSTemporaryDirectory() + "cc-ana-\(UUID().uuidString).json"
        try #"{"num_speakers":1,"speakers":[{"label":"You","talk_ratio":1.0}]}"#
            .data(using: .utf8)!.write(to: URL(fileURLWithPath: path))
        let a = ConversationAnalysis.load(fromPath: path)
        #expect(a?.numSpeakers == 1)
        #expect(a?.speakers.first?.label == "You")
        try? FileManager.default.removeItem(atPath: path)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd macos-app && swift test --filter AnalysisModelsTests`
Expected: FAIL — `cannot find 'ConversationAnalysis' in scope` (compile error).

- [ ] **Step 3: Create `macos-app/Sources/Bridge/AnalysisModels.swift`**

```swift
import Foundation
import OSLog

/// Decodable mirror of the worker's `<id>_analysis.json`. Every field is decoded
/// defensively (`decodeIfPresent` + default) so a partial, older, or future-extended
/// payload never throws; `load(fromPath:)` returns nil on any file/parse failure.

struct SpeakerSentiment: Decodable, Sendable {
    let label: String
    let score: Double

    enum CodingKeys: String, CodingKey { case label, score }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? "neutral"
        score = try c.decodeIfPresent(Double.self, forKey: .score) ?? 0
    }
}

struct ArcPoint: Decodable, Sendable {
    let t: Double
    let score: Double

    enum CodingKeys: String, CodingKey { case t, score }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        t = try c.decodeIfPresent(Double.self, forKey: .t) ?? 0
        score = try c.decodeIfPresent(Double.self, forKey: .score) ?? 0
    }
}

struct Sentiment: Decodable, Sendable {
    let overall: String
    let overallScore: Double
    let bySpeaker: [String: SpeakerSentiment]
    let arc: [ArcPoint]

    enum CodingKeys: String, CodingKey {
        case overall
        case overallScore = "overall_score"
        case bySpeaker = "by_speaker"
        case arc
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        overall = try c.decodeIfPresent(String.self, forKey: .overall) ?? "neutral"
        overallScore = try c.decodeIfPresent(Double.self, forKey: .overallScore) ?? 0
        bySpeaker = try c.decodeIfPresent([String: SpeakerSentiment].self, forKey: .bySpeaker) ?? [:]
        arc = try c.decodeIfPresent([ArcPoint].self, forKey: .arc) ?? []
    }
}

struct SpeakerStats: Decodable, Sendable {
    let label: String
    let isSelf: Bool
    let talkSeconds: Double
    let talkRatio: Double
    let words: Int
    let wordsPerMin: Double
    let turns: Int
    let longestMonologueSec: Double
    let dominantEmotion: String?
    let valence: Double?
    let arousal: Double?

    enum CodingKeys: String, CodingKey {
        case label
        case isSelf = "is_self"
        case talkSeconds = "talk_seconds"
        case talkRatio = "talk_ratio"
        case words
        case wordsPerMin = "words_per_min"
        case turns
        case longestMonologueSec = "longest_monologue_sec"
        case dominantEmotion = "dominant_emotion"
        case valence
        case arousal
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        isSelf = try c.decodeIfPresent(Bool.self, forKey: .isSelf) ?? false
        talkSeconds = try c.decodeIfPresent(Double.self, forKey: .talkSeconds) ?? 0
        talkRatio = try c.decodeIfPresent(Double.self, forKey: .talkRatio) ?? 0
        words = try c.decodeIfPresent(Int.self, forKey: .words) ?? 0
        wordsPerMin = try c.decodeIfPresent(Double.self, forKey: .wordsPerMin) ?? 0
        turns = try c.decodeIfPresent(Int.self, forKey: .turns) ?? 0
        longestMonologueSec = try c.decodeIfPresent(Double.self, forKey: .longestMonologueSec) ?? 0
        dominantEmotion = try c.decodeIfPresent(String.self, forKey: .dominantEmotion)
        valence = try c.decodeIfPresent(Double.self, forKey: .valence)
        arousal = try c.decodeIfPresent(Double.self, forKey: .arousal)
    }
}

struct Insights: Decodable, Sendable {
    let title: String
    let summary: String
    let keyPoints: [String]
    let actionItems: [String]
    let recommendedActions: [String]
    let dynamics: String
    let opportunities: [String]
    let reflections: [String]
    let outline: [String]
    let keyConcepts: [String]
    let qa: [String]
    let takeaways: [String]

    enum CodingKeys: String, CodingKey {
        case title, summary
        case keyPoints = "key_points"
        case actionItems = "action_items"
        case recommendedActions = "recommended_actions"
        case dynamics, opportunities, reflections, outline
        case keyConcepts = "key_concepts"
        case qa, takeaways
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        keyPoints = try c.decodeIfPresent([String].self, forKey: .keyPoints) ?? []
        actionItems = try c.decodeIfPresent([String].self, forKey: .actionItems) ?? []
        recommendedActions = try c.decodeIfPresent([String].self, forKey: .recommendedActions) ?? []
        dynamics = try c.decodeIfPresent(String.self, forKey: .dynamics) ?? ""
        opportunities = try c.decodeIfPresent([String].self, forKey: .opportunities) ?? []
        reflections = try c.decodeIfPresent([String].self, forKey: .reflections) ?? []
        outline = try c.decodeIfPresent([String].self, forKey: .outline) ?? []
        keyConcepts = try c.decodeIfPresent([String].self, forKey: .keyConcepts) ?? []
        qa = try c.decodeIfPresent([String].self, forKey: .qa) ?? []
        takeaways = try c.decodeIfPresent([String].self, forKey: .takeaways) ?? []
    }
}

struct ConversationAnalysis: Decodable, Sendable {
    let recordingType: String
    let numSpeakers: Int
    let speakers: [SpeakerStats]
    let warnings: [String]
    let sentiment: Sentiment?
    let insights: Insights?

    enum CodingKeys: String, CodingKey {
        case recordingType = "recording_type"
        case numSpeakers = "num_speakers"
        case speakers, warnings, sentiment, insights
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        recordingType = try c.decodeIfPresent(String.self, forKey: .recordingType) ?? "call_meeting"
        numSpeakers = try c.decodeIfPresent(Int.self, forKey: .numSpeakers) ?? 0
        speakers = try c.decodeIfPresent([SpeakerStats].self, forKey: .speakers) ?? []
        warnings = try c.decodeIfPresent([String].self, forKey: .warnings) ?? []
        sentiment = try c.decodeIfPresent(Sentiment.self, forKey: .sentiment)
        insights = try c.decodeIfPresent(Insights.self, forKey: .insights)
    }

    /// True when there is anything worth showing in the insights panel.
    var hasContent: Bool {
        !speakers.isEmpty
            || sentiment != nil
            || !(insights?.recommendedActions.isEmpty ?? true)
            || !(insights?.actionItems.isEmpty ?? true)
    }

    /// Loads and decodes the analysis sidecar; returns nil on a missing file or
    /// unparseable JSON (logged, never thrown).
    static func load(fromPath path: String) -> ConversationAnalysis? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        do {
            return try JSONDecoder().decode(ConversationAnalysis.self, from: data)
        } catch {
            Logger(subsystem: "com.callcapture.app", category: "Analysis")
                .error("Failed to decode analysis at \(path): \(error.localizedDescription)")
            return nil
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd macos-app && swift test --filter AnalysisModelsTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add macos-app/Sources/Bridge/AnalysisModels.swift macos-app/Tests/CallCaptureTests/AnalysisModelsTests.swift
git commit -m "feat(app): Decodable mirror of conversation analysis sidecar"
```

---

## Task 2: `SessionManager.updateRecordingType`

**Files:**
- Modify: `macos-app/Sources/Session/SessionManager.swift`
- Test: `macos-app/Tests/CallCaptureTests/SessionManagerRecordingTypeTests.swift`

- [ ] **Step 1: Write the failing test** — `macos-app/Tests/CallCaptureTests/SessionManagerRecordingTypeTests.swift`

```swift
import Foundation
import Testing
@testable import CallCapture

@Suite("SessionManager.updateRecordingType")
struct SessionManagerRecordingTypeTests {
    @Test("persists a new recording type to the database")
    func persists() throws {
        let path = NSTemporaryDirectory() + "cc-sm-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let db = try AppDatabase(path: path)
        let manager = SessionManager(database: db)

        let session = manager.createSession(sourceApp: "Test", recordingType: .callMeeting)
        #expect(manager.session(id: session.id)?.recordingType == "call_meeting")

        manager.updateRecordingType(id: session.id, recordingType: "lecture")
        #expect(manager.session(id: session.id)?.recordingType == "lecture")
    }

    @Test("unknown id is a no-op and does not crash")
    func unknownId() throws {
        let path = NSTemporaryDirectory() + "cc-sm-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let db = try AppDatabase(path: path)
        let manager = SessionManager(database: db)

        manager.updateRecordingType(id: "does-not-exist", recordingType: "lecture")
        #expect(manager.session(id: "does-not-exist") == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd macos-app && swift test --filter SessionManagerRecordingTypeTests`
Expected: FAIL — `value of type 'SessionManager' has no member 'updateRecordingType'`.

- [ ] **Step 3: Add `updateRecordingType` to `SessionManager`**

Insert this method immediately after the existing `updateAnalysisPath(id:analysisPath:)` method (around line 258) in `macos-app/Sources/Session/SessionManager.swift`:

```swift
    /// Persists a corrected recording type for a session.
    ///
    /// - Parameters:
    ///   - id: Session identifier.
    ///   - recordingType: New recording-type raw value (e.g. "lecture").
    func updateRecordingType(id: String, recordingType: String) {
        do {
            try database.dbPool.write { db in
                guard var record = try SessionRecord.fetchOne(db, key: id) else {
                    Self.logger.warning("Session not found for recording type update: \(id)")
                    return
                }
                record.recordingType = recordingType
                try record.update(db)
            }
        } catch {
            Self.logger.error("Failed to update recording type for \(id): \(error)")
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd macos-app && swift test --filter SessionManagerRecordingTypeTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add macos-app/Sources/Session/SessionManager.swift macos-app/Tests/CallCaptureTests/SessionManagerRecordingTypeTests.swift
git commit -m "feat(app): persist edited recording type"
```

---

## Task 3: `InsightsFormat` helpers + `ConversationInsightsView`

**Files:**
- Modify: `macos-app/Sources/Bridge/AnalysisModels.swift` (append `InsightsFormat`)
- Create: `macos-app/Sources/UI/ConversationInsightsView.swift`
- Test: `macos-app/Tests/CallCaptureTests/InsightsFormatTests.swift`

- [ ] **Step 1: Write the failing test** — `macos-app/Tests/CallCaptureTests/InsightsFormatTests.swift`

```swift
import Foundation
import Testing
@testable import CallCapture

@Suite("InsightsFormat")
struct InsightsFormatTests {
    @Test("percent rounds and clamps to 0...100")
    func percent() {
        #expect(InsightsFormat.percent(0.6) == "60%")
        #expect(InsightsFormat.percent(1.0) == "100%")
        #expect(InsightsFormat.percent(0.404) == "40%")
        #expect(InsightsFormat.percent(1.5) == "100%")
        #expect(InsightsFormat.percent(-0.2) == "0%")
    }

    @Test("signed formats with an explicit sign")
    func signed() {
        #expect(InsightsFormat.signed(0.5) == "+0.50")
        #expect(InsightsFormat.signed(-0.2, fractionDigits: 1) == "-0.2")
        #expect(InsightsFormat.signed(0.6, fractionDigits: 1) == "+0.6")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd macos-app && swift test --filter InsightsFormatTests`
Expected: FAIL — `cannot find 'InsightsFormat' in scope`.

- [ ] **Step 3: Append `InsightsFormat` to `macos-app/Sources/Bridge/AnalysisModels.swift`**

Add at the end of the file:

```swift
/// Pure string formatting for the insights panel (kept out of the View so it is
/// unit-testable without SwiftUI/availability gymnastics).
enum InsightsFormat {
    /// A clamped, rounded percentage label, e.g. 0.6 -> "60%".
    static func percent(_ ratio: Double) -> String {
        let clamped = max(0, min(1, ratio))
        return "\(Int((clamped * 100).rounded()))%"
    }

    /// A signed fixed-point label, e.g. 0.5 -> "+0.50", -0.2 (1 digit) -> "-0.2".
    static func signed(_ value: Double, fractionDigits: Int = 2) -> String {
        String(format: "%+.\(fractionDigits)f", value)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd macos-app && swift test --filter InsightsFormatTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Create `macos-app/Sources/UI/ConversationInsightsView.swift`**

```swift
import SwiftUI

/// Structured rendering of a decoded `ConversationAnalysis`: per-speaker talk-ratio
/// bars with sentiment/emotion, plus recommended actions and action items. The rich
/// per-type prose stays in the Markdown note preview.
@available(macOS 14.2, *)
struct ConversationInsightsView: View {
    let analysis: ConversationAnalysis

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let sentiment = analysis.sentiment {
                HStack {
                    Text("Overall: \(sentiment.overall) (\(InsightsFormat.signed(sentiment.overallScore)))")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Spacer()
                    Text("\(analysis.numSpeakers) speaker\(analysis.numSpeakers == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(analysis.speakers, id: \.label) { speaker in
                speakerRow(speaker)
            }

            if let insights = analysis.insights {
                if !insights.recommendedActions.isEmpty {
                    actionBlock("Recommended actions", insights.recommendedActions, checkbox: false)
                }
                if !insights.actionItems.isEmpty {
                    actionBlock("Action items", insights.actionItems, checkbox: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func speakerRow(_ speaker: SpeakerStats) -> some View {
        HStack(spacing: 8) {
            Text(speaker.label)
                .font(.caption)
                .fontWeight(speaker.isSelf ? .semibold : .regular)
                .frame(width: 90, alignment: .leading)
                .lineLimit(1)

            ProgressView(value: max(0, min(1, speaker.talkRatio)))
                .progressViewStyle(.linear)
                .frame(maxWidth: .infinity)

            Text(InsightsFormat.percent(speaker.talkRatio))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)

            if let emotion = speaker.dominantEmotion {
                Text(emotion)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .leading)
                    .lineLimit(1)
                if let valence = speaker.valence {
                    Text(InsightsFormat.signed(valence, fractionDigits: 1))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func actionBlock(_ title: String, _ items: [String], checkbox: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Label {
                    Text(item).font(.caption)
                } icon: {
                    Image(systemName: checkbox ? "square" : "circle.fill")
                        .font(.system(size: checkbox ? 10 : 6))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
```

- [ ] **Step 6: Build to verify the view compiles**

Run: `cd macos-app && swift build`
Expected: `Build complete!` (no errors).

- [ ] **Step 7: Commit**

```bash
git add macos-app/Sources/Bridge/AnalysisModels.swift macos-app/Sources/UI/ConversationInsightsView.swift macos-app/Tests/CallCaptureTests/InsightsFormatTests.swift
git commit -m "feat(app): conversation insights panel view and formatting helpers"
```

---

## Task 4: Wire panel, type Picker, and Re-process into Session Detail

**Files:**
- Modify: `macos-app/Sources/UI/SessionDetailView.swift`

This task has no new unit test (SwiftUI view wiring); it is verified by `swift build` + the full `swift test` suite staying green. Make the four edits below exactly.

- [ ] **Step 1: Add analysis state and load it in `reload()`**

In `SessionDetailView`, add a state property next to the existing `@State private var liveSession: Session?` (around line 17):

```swift
    /// Decoded conversation analysis sidecar for the insights panel.
    @State private var analysis: ConversationAnalysis?
```

Replace the existing `reload()` (lines 48-50):

```swift
    private func reload() {
        liveSession = appModel.sessionManager.session(id: session.id)
    }
```

with:

```swift
    private func reload() {
        liveSession = appModel.sessionManager.session(id: session.id)
        analysis = current.analysisPath.flatMap(ConversationAnalysis.load(fromPath:))
    }
```

(`current` reads `liveSession ?? session`, so it reflects the just-set `liveSession`.)

- [ ] **Step 2: Add the insights section to the body and define it**

In `body`, add `insightsSection` immediately after `markdownSection` (line 34):

```swift
                markdownSection
                insightsSection
                errorSection
```

Add this section builder after the `markdownSection` computed property (after line 136):

```swift
    @ViewBuilder
    private var insightsSection: some View {
        if let analysis, analysis.hasContent {
            GroupBox("Conversation Insights") {
                ConversationInsightsView(analysis: analysis)
                    .padding(.vertical, 4)
            }
        }
    }
```

- [ ] **Step 3: Add the recording-type Picker to the Details grid**

In `metadataSection` (lines 68-83), add a `GridRow` with a recording-type Picker as the first row inside the `Grid`, before the `detailRow("Source App", ...)` line:

```swift
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text("Type")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Picker("", selection: Binding(
                        get: { RecordingType(rawValue: current.recordingType) ?? .callMeeting },
                        set: { newType in
                            appModel.sessionManager.updateRecordingType(
                                id: session.id,
                                recordingType: newType.rawValue
                            )
                            reload()
                        }
                    )) {
                        ForEach(RecordingType.allCases) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                detailRow("Source App", session.sourceApp)
```

(The custom `Binding` persists only on a real user selection and reads from the DB-backed `current`, so there is no on-appear write loop. Leave the remaining `detailRow(...)` lines unchanged.)

- [ ] **Step 4: Relabel the transcribed-state button to "Re-process"**

In `actionButtons` (lines 168-173), change:

```swift
            if current.status == "transcribed" {
                transcribeButton(label: "Re-transcribe", engine: "local_whisper")
            }
```

to:

```swift
            if current.status == "transcribed" {
                transcribeButton(label: "Re-process", engine: "local_whisper")
            }
```

(The `transcribe()` flow already calls `appModel.transcribeSession(session)`, which reads `session.recordingType`, and ends with `reload()` — now also re-decoding `analysis`.)

- [ ] **Step 5: Build and run the full suite**

Run: `cd macos-app && swift build`
Expected: `Build complete!`

Run: `cd macos-app && swift test`
Expected: all tests pass (22 baseline + Task 1/2/3 additions; no regressions).

- [ ] **Step 6: Commit**

```bash
git add macos-app/Sources/UI/SessionDetailView.swift
git commit -m "feat(app): show conversation insights, editable type, and re-process in session detail"
```

---

## Task 5: Full build/test green + verification

**Files:** none (verification only)

- [ ] **Step 1: Build the whole app**

Run: `cd macos-app && swift build`
Expected: `Build complete!` with no warnings introduced by Phase 6 files.

- [ ] **Step 2: Run the whole test suite**

Run: `cd macos-app && swift test`
Expected: all suites pass. Confirm the new suites appear: `ConversationAnalysis decoding`, `SessionManager.updateRecordingType`, `InsightsFormat`.

- [ ] **Step 3: Manual-check checklist (record for the human — GUI not runnable headless)**

Document these steps in the final report for the user to run in the app:
1. Open a session that was transcribed by the Phase 5 worker (has `<id>_analysis.json`) → a "Conversation Insights" GroupBox shows overall sentiment, per-speaker talk-ratio bars, emotion/valence (if the emotion model ran), and recommended actions / action items.
2. Open an older session with no `analysis.json` → no insights panel, no crash.
3. Change the "Type" picker in Details → it persists (reopen the session: the new type sticks).
4. Press "Re-process" → the pipeline re-runs with the new type and the note + insights panel refresh.

- [ ] **Step 4: Update the roadmap memory**

Edit `/Users/bodharma/.claude/projects/-Users-bodharma-dev-repos-personal-call-capture-macos/memory/voice-intelligence-roadmap.md`: mark Phase 6 DONE (insights panel, editable type, re-process; `ConversationAnalysis` Decodable mirror; `SessionManager.updateRecordingType`) and note the voice-intelligence roadmap is complete through Phase 6. This is a memory file, not committed to the repo.

- [ ] **Step 5: Final commit (only if any verification fixups were made)**

```bash
git add -A
git commit -m "chore(app): Phase 6 build/test verification"
```

---

## Self-Review

**Spec coverage:**
- §4.1 `ConversationAnalysis` Decodable mirror (+ `SpeakerStats`/`Sentiment`/`SpeakerSentiment`/`ArcPoint`/`Insights`, defensive decode, `load`) → Task 1. ✓
- §4.2 `ConversationInsightsView` (overall row, per-speaker bars + emotion, recommended/action blocks, empty-omission) → Task 3. ✓
- §4.3 SessionDetailView edits (analysis state + load, insights GroupBox, type Picker, Re-process relabel) → Task 4. ✓
- §4.4 `SessionManager.updateRecordingType` → Task 2. ✓
- §5 data flow (reload loads analysis; Picker persists+reload; Re-process re-runs + refreshes) → Tasks 2 + 4. ✓
- §6 degradation (missing/partial/old JSON → nil/defaults, no crash; unknown-id no-op) → Tasks 1 + 2 tests. ✓
- §7 testing (AnalysisModels decode/partial/load; updateRecordingType; format helpers) → Tasks 1/2/3 test files. ✓
- §8 out of scope (arc not drawn; no worker change) → `arc` decoded but unused; no worker files touched. ✓

**Placeholder scan:** No "TBD"/"add error handling"/"similar to" — every code step shows complete code. ✓

**Type consistency:** `ConversationAnalysis.load(fromPath:)`, `.hasContent`, field names (`talkRatio`, `dominantEmotion`, `recommendedActions`, `actionItems`, `overallScore`, `bySpeaker`) are identical across Tasks 1, 3, 4. `InsightsFormat.percent`/`signed(_,fractionDigits:)` signatures match between Task 3's helper and its uses in `ConversationInsightsView`. `SessionManager.updateRecordingType(id:recordingType:)` signature matches its call in SessionDetailView (Task 4). `RecordingType(rawValue:)` / `.allCases` / `.displayName` / `.rawValue` all exist on the verified enum. ✓

# Voice Intelligence — Phase 3b: FluidAudio Diarizer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run the FluidAudio Swift SDK in the macOS app to produce a real multi-speaker `*_diarization.json` turns sidecar on the remote audio **before** the Python worker transcribes, behind a swappable `DiarizationProvider` protocol.

**Architecture:** A `DiarizationProvider` protocol returns normalized `[DiarizationTurn]`; a pure `SpeakerLabelNormalizer` maps engine cluster ids to `Speaker N`; a pure `DiarizationSidecar` writes the worker-contract JSON; a `DiarizationService` gates (recording-type + models-ready), picks the remote audio (`_system.wav` else mixed), calls the provider, writes the sidecar, and swallows errors (graceful degrade). `FluidAudioDiarizer` (an `actor`) is the only type importing the SDK. Settings gets an explicit "Download diarization models" action. The Python worker is unchanged.

**Tech Stack:** Swift 5.9 / SwiftUI / Swift Testing; FluidAudio SPM (`from: 0.12.4`, CoreML/ANE); GRDB.

**Spec:** `docs/superpowers/specs/2026-05-24-phase3b-diarizer-design.md`. **Branch:** `feature/voice-intelligence-phase3b` (already created).

---

## Conventions for this plan

- All commands run from `macos-app/`: `swift build`, `swift test`.
- Tests use Swift Testing: `import Testing`, `@testable import CallCapture`; every `@Test` func is marked `@available(macOS 14.2, *)`.
- New source files live in `macos-app/Sources/Diarization/`; new test files in `macos-app/Tests/CallCaptureTests/`.
- Editor/SourceKit errors like "No such module 'Testing'" / "Cannot find type X" are false positives — judge only by real `swift build` / `swift test` output.
- Commit messages are conventional and must not mention AI/Claude.

## File Structure

- Create `macos-app/Sources/Diarization/DiarizationProvider.swift` — `DiarizationTurn` struct + `DiarizationProvider` protocol.
- Create `macos-app/Sources/Diarization/SpeakerLabelNormalizer.swift` — `RawSpeakerTurn` + pure `normalizeTurns`.
- Create `macos-app/Sources/Diarization/DiarizationSidecar.swift` — sidecar path rule + atomic write.
- Create `macos-app/Sources/Diarization/DiarizationService.swift` — gating + orchestration.
- Create `macos-app/Sources/Diarization/FluidAudioDiarizer.swift` — FluidAudio SDK wrapper (`actor`).
- Modify `macos-app/Package.swift` — add the FluidAudio dependency.
- Modify `macos-app/Sources/Settings/SettingsManager.swift` — persisted `diarizationModelsReady`.
- Modify `macos-app/Sources/Settings/SettingsView.swift` — replace the placeholder diarization toggle with the download UI.
- Modify `macos-app/Sources/App/CallCaptureApp.swift` — construct `DiarizationService`; run it before `runJob`.
- Tests: `DiarizationTurnTests.swift`, `SpeakerLabelNormalizerTests.swift`, `DiarizationSidecarTests.swift`, `DiarizationServiceTests.swift`.

---

## Task 1: DiarizationProvider protocol + DiarizationTurn

**Files:**
- Create: `macos-app/Sources/Diarization/DiarizationProvider.swift`
- Test: `macos-app/Tests/CallCaptureTests/DiarizationTurnTests.swift`

- [ ] **Step 1: Write the failing test**

Create `macos-app/Tests/CallCaptureTests/DiarizationTurnTests.swift`:

```swift
import Testing
import Foundation
@testable import CallCapture

struct DiarizationTurnTests {
    @Test @available(macOS 14.2, *)
    func encodesExactlyTheWorkerContractKeys() throws {
        let turn = DiarizationTurn(speaker: "Speaker 1", start: 0.0, end: 2.5)
        let data = try JSONEncoder().encode(turn)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(obj["speaker"] as? String == "Speaker 1")
        #expect(obj["start"] as? Double == 0.0)
        #expect(obj["end"] as? Double == 2.5)
        #expect(obj.keys.count == 3) // no extra / snake_cased keys
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd macos-app && swift test --filter DiarizationTurnTests`
Expected: FAIL — `Cannot find 'DiarizationTurn' in scope`.

- [ ] **Step 3: Write the implementation**

Create `macos-app/Sources/Diarization/DiarizationProvider.swift`:

```swift
import Foundation

/// A single speaker turn over the remote-audio timeline. Encodes to the Python
/// worker's diarization-sidecar contract: `{"speaker","start","end"}`.
struct DiarizationTurn: Codable, Equatable, Sendable {
    let speaker: String
    let start: Double
    let end: Double
}

/// A swappable speaker-diarization engine. FluidAudio is the default provider;
/// pyannote is the documented fallback. Implementations own their model lifecycle.
protocol DiarizationProvider: Sendable {
    /// Downloads (if needed) and loads diarization models. Called from the
    /// Settings download action; safe to call repeatedly.
    func prepareModels() async throws

    /// Diarizes the audio at `audioPath` into normalized speaker turns
    /// ("Speaker 1", "Speaker 2", … by order of first appearance).
    func diarize(audioPath: URL) async throws -> [DiarizationTurn]
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd macos-app && swift test --filter DiarizationTurnTests`
Expected: PASS (1 test).

- [ ] **Step 5: Commit**

```bash
git add macos-app/Sources/Diarization/DiarizationProvider.swift macos-app/Tests/CallCaptureTests/DiarizationTurnTests.swift
git commit -m "feat(app): add DiarizationProvider protocol and DiarizationTurn"
```

---

## Task 2: SpeakerLabelNormalizer

**Files:**
- Create: `macos-app/Sources/Diarization/SpeakerLabelNormalizer.swift`
- Test: `macos-app/Tests/CallCaptureTests/SpeakerLabelNormalizerTests.swift`

Maps the opaque cluster ids an engine emits to friendly 1-based `"Speaker N"` labels by order of first appearance.

- [ ] **Step 1: Write the failing test**

Create `macos-app/Tests/CallCaptureTests/SpeakerLabelNormalizerTests.swift`:

```swift
import Testing
@testable import CallCapture

struct SpeakerLabelNormalizerTests {
    @Test @available(macOS 14.2, *)
    func mapsClusterIdsByFirstAppearance() {
        let raw = [
            RawSpeakerTurn(clusterId: "7", start: 0.0, end: 1.0),
            RawSpeakerTurn(clusterId: "3", start: 1.0, end: 2.0),
            RawSpeakerTurn(clusterId: "7", start: 2.0, end: 3.0),
            RawSpeakerTurn(clusterId: "3", start: 3.0, end: 4.0),
        ]
        let turns = normalizeTurns(raw)
        #expect(turns.map(\.speaker) == ["Speaker 1", "Speaker 2", "Speaker 1", "Speaker 2"])
        #expect(turns.map(\.start) == [0.0, 1.0, 2.0, 3.0])
        #expect(turns.map(\.end) == [1.0, 2.0, 3.0, 4.0])
    }

    @Test @available(macOS 14.2, *)
    func emptyInputProducesEmptyOutput() {
        #expect(normalizeTurns([]).isEmpty)
    }

    @Test @available(macOS 14.2, *)
    func singleSpeakerIsSpeakerOne() {
        let raw = [RawSpeakerTurn(clusterId: "x", start: 0, end: 5)]
        #expect(normalizeTurns(raw).map(\.speaker) == ["Speaker 1"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd macos-app && swift test --filter SpeakerLabelNormalizerTests`
Expected: FAIL — `Cannot find 'RawSpeakerTurn' in scope`.

- [ ] **Step 3: Write the implementation**

Create `macos-app/Sources/Diarization/SpeakerLabelNormalizer.swift`:

```swift
import Foundation

/// A diarization turn as emitted by an engine, keyed by an opaque cluster id.
/// Engines use Int or String ids; both are carried here as `String`.
struct RawSpeakerTurn: Equatable {
    let clusterId: String
    let start: Double
    let end: Double
}

/// Maps opaque cluster ids to "Speaker 1", "Speaker 2", … by order of first
/// appearance, preserving turn order and timings.
func normalizeTurns(_ raw: [RawSpeakerTurn]) -> [DiarizationTurn] {
    var labelForCluster: [String: String] = [:]
    var nextIndex = 1
    var result: [DiarizationTurn] = []
    for turn in raw {
        let label: String
        if let existing = labelForCluster[turn.clusterId] {
            label = existing
        } else {
            label = "Speaker \(nextIndex)"
            labelForCluster[turn.clusterId] = label
            nextIndex += 1
        }
        result.append(DiarizationTurn(speaker: label, start: turn.start, end: turn.end))
    }
    return result
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd macos-app && swift test --filter SpeakerLabelNormalizerTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add macos-app/Sources/Diarization/SpeakerLabelNormalizer.swift macos-app/Tests/CallCaptureTests/SpeakerLabelNormalizerTests.swift
git commit -m "feat(app): normalize diarization cluster ids to Speaker N labels"
```

---

## Task 3: DiarizationSidecar (path rule + atomic write)

**Files:**
- Create: `macos-app/Sources/Diarization/DiarizationSidecar.swift`
- Test: `macos-app/Tests/CallCaptureTests/DiarizationSidecarTests.swift`

The sidecar path must mirror the worker's rule exactly: strip the extension of whichever audio file was diarized and append `_diarization.json` (so `<id>_system.wav` → `<id>_system_diarization.json`, and `<id>.wav` → `<id>_diarization.json`).

- [ ] **Step 1: Write the failing test**

Create `macos-app/Tests/CallCaptureTests/DiarizationSidecarTests.swift`:

```swift
import Testing
import Foundation
@testable import CallCapture

struct DiarizationSidecarTests {
    @Test @available(macOS 14.2, *)
    func sidecarPathForMixedFile() {
        let audio = URL(fileURLWithPath: "/tmp/x/abc.wav")
        let side = DiarizationSidecar.sidecarPath(forAudioAt: audio)
        #expect(side.lastPathComponent == "abc_diarization.json")
        #expect(side.deletingLastPathComponent().path == "/tmp/x")
    }

    @Test @available(macOS 14.2, *)
    func sidecarPathForSystemStem() {
        let audio = URL(fileURLWithPath: "/tmp/x/abc_system.wav")
        #expect(DiarizationSidecar.sidecarPath(forAudioAt: audio).lastPathComponent
                == "abc_system_diarization.json")
    }

    @Test @available(macOS 14.2, *)
    func writeProducesWorkerCompatibleJSON() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let audio = dir.appendingPathComponent("abc_system.wav")
        let turns = [
            DiarizationTurn(speaker: "Speaker 1", start: 0.0, end: 2.5),
            DiarizationTurn(speaker: "Speaker 2", start: 2.5, end: 5.0),
        ]
        try DiarizationSidecar.write(turns, forAudioAt: audio)

        let side = dir.appendingPathComponent("abc_system_diarization.json")
        #expect(FileManager.default.fileExists(atPath: side.path))
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: side)) as! [String: Any]
        let arr = obj["turns"] as! [[String: Any]]
        #expect(arr.count == 2)
        #expect(arr[0]["speaker"] as? String == "Speaker 1")
        #expect(arr[0]["start"] as? Double == 0.0)
        #expect(arr[1]["end"] as? Double == 5.0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd macos-app && swift test --filter DiarizationSidecarTests`
Expected: FAIL — `Cannot find 'DiarizationSidecar' in scope`.

- [ ] **Step 3: Write the implementation**

Create `macos-app/Sources/Diarization/DiarizationSidecar.swift`:

```swift
import Foundation

/// Reads/writes the diarization turns sidecar consumed by the Python worker.
/// The sidecar is named after the audio file that was diarized, matching the
/// worker's `splitext(path)[0] + "_diarization.json"` rule.
enum DiarizationSidecar {
    private struct Payload: Codable {
        let turns: [DiarizationTurn]
    }

    /// Sidecar path for a given diarized audio file.
    static func sidecarPath(forAudioAt audioPath: URL) -> URL {
        let dir = audioPath.deletingLastPathComponent()
        let stem = audioPath.deletingPathExtension().lastPathComponent
        return dir.appendingPathComponent("\(stem)_diarization.json")
    }

    /// Atomically writes `{"turns":[…]}` next to the diarized audio file.
    static func write(_ turns: [DiarizationTurn], forAudioAt audioPath: URL) throws {
        let url = sidecarPath(forAudioAt: audioPath)
        let data = try JSONEncoder().encode(Payload(turns: turns))
        try data.write(to: url, options: .atomic) // temp file + rename under the hood
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd macos-app && swift test --filter DiarizationSidecarTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add macos-app/Sources/Diarization/DiarizationSidecar.swift macos-app/Tests/CallCaptureTests/DiarizationSidecarTests.swift
git commit -m "feat(app): write diarization turns sidecar at worker-compatible path"
```

---

## Task 4: DiarizationService (gating + orchestration)

**Files:**
- Create: `macos-app/Sources/Diarization/DiarizationService.swift`
- Test: `macos-app/Tests/CallCaptureTests/DiarizationServiceTests.swift`

Gates on recording type + models-ready, picks the remote audio file (`_system.wav` if present, else the session's mixed file), calls the provider, writes the sidecar, and swallows any error so transcription is never blocked. The provider is injected (no FluidAudio dependency here).

- [ ] **Step 1: Write the failing test**

Create `macos-app/Tests/CallCaptureTests/DiarizationServiceTests.swift`:

```swift
import Testing
import Foundation
@testable import CallCapture

/// Test double that records calls and returns/throws on demand. Test-only;
/// single-threaded use, hence @unchecked Sendable.
final class FakeDiarizationProvider: DiarizationProvider, @unchecked Sendable {
    var prepareCount = 0
    var diarizeCalls: [URL] = []
    var turnsToReturn: [DiarizationTurn] = []
    var diarizeError: Error?

    func prepareModels() async throws { prepareCount += 1 }

    func diarize(audioPath: URL) async throws -> [DiarizationTurn] {
        diarizeCalls.append(audioPath)
        if let diarizeError { throw diarizeError }
        return turnsToReturn
    }
}

struct DiarizationServiceErr: Error {}

@available(macOS 14.2, *)
struct DiarizationServiceTests {
    /// Fresh temp dir + a session whose audio lives in it.
    private func makeFixture(type: String) throws -> (URL, Session) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let session = Session(
            id: "sess", title: "t", sourceApp: "s", startedAt: Date(),
            audioPath: dir.appendingPathComponent("sess.wav").path,
            recordingType: type, status: "completed"
        )
        return (dir, session)
    }

    @Test func skipsWhenTypeDoesNotDiarize() async throws {
        let (dir, session) = try makeFixture(type: "voice_memo")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = FakeDiarizationProvider()
        fake.turnsToReturn = [DiarizationTurn(speaker: "Speaker 1", start: 0, end: 1)]
        let service = DiarizationService(provider: fake)

        await service.diarizeIfNeeded(session: session, modelsReady: true)

        #expect(fake.diarizeCalls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("sess_diarization.json").path))
    }

    @Test func skipsWhenModelsNotReady() async throws {
        let (dir, session) = try makeFixture(type: "call_meeting")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = FakeDiarizationProvider()
        let service = DiarizationService(provider: fake)

        await service.diarizeIfNeeded(session: session, modelsReady: false)

        #expect(fake.diarizeCalls.isEmpty)
    }

    @Test func diarizesSystemStemWhenPresent() async throws {
        let (dir, session) = try makeFixture(type: "call_meeting")
        defer { try? FileManager.default.removeItem(at: dir) }
        let systemURL = dir.appendingPathComponent("sess_system.wav")
        try Data().write(to: systemURL)
        let fake = FakeDiarizationProvider()
        fake.turnsToReturn = [DiarizationTurn(speaker: "Speaker 1", start: 0, end: 2)]
        let service = DiarizationService(provider: fake)

        await service.diarizeIfNeeded(session: session, modelsReady: true)

        #expect(fake.diarizeCalls == [systemURL])
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("sess_system_diarization.json").path))
    }

    @Test func diarizesMixedFileWhenNoStem() async throws {
        let (dir, session) = try makeFixture(type: "call_meeting")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = FakeDiarizationProvider()
        fake.turnsToReturn = [DiarizationTurn(speaker: "Speaker 1", start: 0, end: 2)]
        let service = DiarizationService(provider: fake)

        await service.diarizeIfNeeded(session: session, modelsReady: true)

        #expect(fake.diarizeCalls == [URL(fileURLWithPath: session.audioPath)])
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("sess_diarization.json").path))
    }

    @Test func swallowsProviderErrorAndWritesNoSidecar() async throws {
        let (dir, session) = try makeFixture(type: "call_meeting")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = FakeDiarizationProvider()
        fake.diarizeError = DiarizationServiceErr()
        let service = DiarizationService(provider: fake)

        await service.diarizeIfNeeded(session: session, modelsReady: true)

        #expect(fake.diarizeCalls.count == 1)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("sess_diarization.json").path))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd macos-app && swift test --filter DiarizationServiceTests`
Expected: FAIL — `Cannot find 'DiarizationService' in scope`.

- [ ] **Step 3: Write the implementation**

Create `macos-app/Sources/Diarization/DiarizationService.swift`:

```swift
import Foundation
import OSLog

/// Orchestrates speaker diarization for a session: decides whether to run,
/// picks the remote-audio file, invokes the provider, and writes the turns
/// sidecar the Python worker reads. Any failure is logged and swallowed so
/// transcription is never blocked.
final class DiarizationService {
    private let provider: any DiarizationProvider
    private static let logger = Logger(
        subsystem: "com.callcapture.app",
        category: "Diarization"
    )

    init(provider: any DiarizationProvider) {
        self.provider = provider
    }

    /// Downloads/loads diarization models. Surfaced to the Settings download UI.
    func prepareModels() async throws {
        try await provider.prepareModels()
    }

    /// Diarizes the session's remote audio and writes the sidecar, if the
    /// recording type diarizes and models are ready. No-op / graceful-degrade
    /// otherwise.
    func diarizeIfNeeded(session: Session, modelsReady: Bool) async {
        guard let type = RecordingType(rawValue: session.recordingType), type.diarize else {
            return
        }
        guard modelsReady else {
            Self.logger.info("Diarization skipped for \(session.id): models not downloaded")
            return
        }

        let remoteURL = Self.remoteAudioURL(for: session)
        do {
            let turns = try await provider.diarize(audioPath: remoteURL)
            try DiarizationSidecar.write(turns, forAudioAt: remoteURL)
            Self.logger.info("Diarization wrote \(turns.count) turns for \(session.id)")
        } catch {
            Self.logger.error("Diarization failed for \(session.id): \(error)")
        }
    }

    /// The remote-audio file to diarize: the system stem when it exists (a mic
    /// was selected), otherwise the mixed/single recording (output-only = remote).
    static func remoteAudioURL(for session: Session) -> URL {
        let audio = URL(fileURLWithPath: session.audioPath)
        let dir = audio.deletingLastPathComponent()
        let stem = audio.deletingPathExtension().lastPathComponent
        let systemURL = dir.appendingPathComponent("\(stem)_system.wav")
        return FileManager.default.fileExists(atPath: systemURL.path) ? systemURL : audio
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd macos-app && swift test --filter DiarizationServiceTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Run the full suite (no regressions)**

Run: `cd macos-app && swift test`
Expected: all tests pass (the 9 pre-existing + 12 new from Tasks 1–4).

- [ ] **Step 6: Commit**

```bash
git add macos-app/Sources/Diarization/DiarizationService.swift macos-app/Tests/CallCaptureTests/DiarizationServiceTests.swift
git commit -m "feat(app): gate and orchestrate diarization via DiarizationService"
```

---

## Task 5: FluidAudio provider + SPM dependency

**Files:**
- Modify: `macos-app/Package.swift`
- Create: `macos-app/Sources/Diarization/FluidAudioDiarizer.swift`

This is the only task that touches the SDK. It is **not** unit-tested (model download + ANE inference need the human). Verify by compiling and keeping the existing suite green.

> **API note:** The FluidAudio symbol names below come from the project README and may differ in `0.12.4`. After `swift build` fetches the package, confirm the real API in `macos-app/.build/checkouts/FluidAudio/Sources/` (look for the offline diarizer manager, its config, `prepareModels`, the process entry point, and segment fields), and adjust `FluidAudioDiarizer.swift` to match. Keep all SDK usage inside this one file.

- [ ] **Step 1: Add the dependency to `Package.swift`**

In `macos-app/Package.swift`, change the `dependencies` array to:

```swift
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4")
    ],
```

and the `CallCapture` target's `dependencies` to:

```swift
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
```

- [ ] **Step 2: Create the provider**

Create `macos-app/Sources/Diarization/FluidAudioDiarizer.swift`:

```swift
import Foundation
import FluidAudio
import OSLog

/// FluidAudio-backed diarizer: runs the offline CoreML diarization pipeline on
/// the Apple Neural Engine and maps results to normalized speaker turns. An actor
/// so its lazily-loaded model state is safely shared across calls. The only type
/// that imports FluidAudio — swap by providing another DiarizationProvider.
actor FluidAudioDiarizer: DiarizationProvider {
    private var manager: OfflineDiarizerManager?
    private static let logger = Logger(
        subsystem: "com.callcapture.app",
        category: "FluidAudioDiarizer"
    )

    func prepareModels() async throws {
        _ = try await loadedManager()
    }

    func diarize(audioPath: URL) async throws -> [DiarizationTurn] {
        let manager = try await loadedManager()
        let result = try await manager.process(audioPath)
        let raw = result.segments.map { segment in
            RawSpeakerTurn(
                clusterId: String(describing: segment.speakerId),
                start: segment.startTimeSeconds,
                end: segment.endTimeSeconds
            )
        }
        return normalizeTurns(raw)
    }

    /// Creates and prepares the manager once per process. `prepareModels()` loads
    /// models from the local cache, downloading only if absent.
    private func loadedManager() async throws -> OfflineDiarizerManager {
        if let manager { return manager }
        let created = OfflineDiarizerManager(config: OfflineDiarizerConfig())
        try await created.prepareModels()
        manager = created
        return created
    }
}
```

- [ ] **Step 3: Build (fetches FluidAudio; adjust API if needed)**

Run: `cd macos-app && swift build`
Expected: `Build complete!`. If it fails on FluidAudio symbol names, inspect `.build/checkouts/FluidAudio/Sources/` and correct the manager/config/process/segment names in `FluidAudioDiarizer.swift` only, then rebuild.

- [ ] **Step 4: Confirm tests still pass**

Run: `cd macos-app && swift test`
Expected: all tests pass (unchanged count; no tests exercise this file).

- [ ] **Step 5: Commit**

```bash
git add macos-app/Package.swift macos-app/Sources/Diarization/FluidAudioDiarizer.swift
git add macos-app/Package.resolved 2>/dev/null || true   # commit the lockfile if not gitignored
git commit -m "feat(app): add FluidAudio offline diarizer provider"
```

---

## Task 6: Persist the diarization-models-ready setting

**Files:**
- Modify: `macos-app/Sources/Settings/SettingsManager.swift`

Mirrors the existing boolean-setting pattern exactly (stored as a string in the `settings` table). Settings persistence has no test harness in this repo, so verify by build; the change is a 1:1 copy of established lines.

- [ ] **Step 1: Add the stored property**

In `macos-app/Sources/Settings/SettingsManager.swift`, after the `keepSeparateMicTrack` line (currently line 55), add:

```swift
    var diarizationModelsReady: Bool = false { didSet { persist("diarization_models_ready", String(diarizationModelsReady)) } }
```

- [ ] **Step 2: Load it on startup**

In the `loadAll()` method, after the `keep_separate_mic_track` load line, add:

```swift
        if let raw = rows["diarization_models_ready"] { diarizationModelsReady = raw == "true" }
```

- [ ] **Step 3: Verify it builds and tests pass**

Run: `cd macos-app && swift build && swift test`
Expected: `Build complete!` and all tests pass.

- [ ] **Step 4: Commit**

```bash
git add macos-app/Sources/Settings/SettingsManager.swift
git commit -m "feat(app): persist diarization-models-ready setting"
```

---

## Task 7: Run diarization before transcription + Settings download UI

**Files:**
- Modify: `macos-app/Sources/App/CallCaptureApp.swift`
- Modify: `macos-app/Sources/Settings/SettingsView.swift`

Wires the service into the transcription flow and replaces the placeholder "Coming in v1.1" diarization toggle with the real download UI. UI is verified by build + the human (§11 of the spec); existing unit tests must stay green.

- [ ] **Step 1: Add the service to `AppModel`**

In `macos-app/Sources/App/CallCaptureApp.swift`, after the line `let pythonBridge = PythonBridge()` (currently line 81), add:

```swift
    let diarizationService = DiarizationService(provider: FluidAudioDiarizer())
```

- [ ] **Step 2: Run diarization before the worker**

In `transcribeSession`, immediately after the `pythonBridge.llmEnvironment = [ ... ]` assignment (which ends at the line `]`) and before `do {`, add:

```swift
        // Diarize the remote audio and write the turns sidecar the worker reads,
        // before transcription. No-ops unless the recording type diarizes and
        // models are downloaded; never blocks or fails transcription.
        await diarizationService.diarizeIfNeeded(
            session: session,
            modelsReady: settingsManager.diarizationModelsReady
        )

```

- [ ] **Step 3: Replace the placeholder diarization UI**

In `macos-app/Sources/Settings/SettingsView.swift`, replace the entire `speakerSection(settings:)` method:

```swift
    @ViewBuilder
    private func speakerSection(settings: SettingsManager) -> some View {
        @Bindable var settings = settings
        Section("Speaker Options") {
            HStack {
                Toggle("Speaker diarization", isOn: .constant(false))
                    .disabled(true)
                Text("Coming in v1.1")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("Keep separate mic track", isOn: $settings.keepSeparateMicTrack)
        }
    }
```

with:

```swift
    @ViewBuilder
    private func speakerSection(settings: SettingsManager) -> some View {
        @Bindable var settings = settings
        Section("Speaker Diarization") {
            DiarizationModelsRow(
                service: appModel.diarizationService,
                modelsReady: $settings.diarizationModelsReady
            )
            Toggle("Keep separate mic track", isOn: $settings.keepSeparateMicTrack)
        }
    }
```

- [ ] **Step 4: Add the download row view**

In `macos-app/Sources/Settings/SettingsView.swift`, after the `DirectoryPickerRow` struct (end of file), add:

```swift
/// Shows diarization-model status and an explicit download button. Diarization
/// only runs once models are downloaded (see DiarizationService gating).
@available(macOS 14.2, *)
private struct DiarizationModelsRow: View {
    let service: DiarizationService
    @Binding var modelsReady: Bool

    @State private var isDownloading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Models")
                Spacer()
                statusLabel
            }
            Button(isDownloading ? "Downloading…" : "Download diarization models") {
                download()
            }
            .disabled(isDownloading || modelsReady)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Text("Required to separate speakers in Call/Meeting recordings. Downloads once (~tens of MB); recordings still produce notes without it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        if isDownloading {
            Text("Downloading…").font(.caption).foregroundStyle(.secondary)
        } else if modelsReady {
            Text("Ready").font(.caption).foregroundStyle(.green)
        } else {
            Text("Not downloaded").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func download() {
        isDownloading = true
        errorMessage = nil
        Task {
            do {
                try await service.prepareModels()
                modelsReady = true
            } catch {
                errorMessage = error.localizedDescription
            }
            isDownloading = false
        }
    }
}
```

- [ ] **Step 5: Verify it builds and tests pass**

Run: `cd macos-app && swift build && swift test`
Expected: `Build complete!` and all tests pass (21 total: 9 pre-existing + 12 new).

- [ ] **Step 6: Commit**

```bash
git add macos-app/Sources/App/CallCaptureApp.swift macos-app/Sources/Settings/SettingsView.swift
git commit -m "feat(app): run diarization before transcription and add models download UI"
```

---

## Final verification

- [ ] **Full Swift suite:** `cd macos-app && swift build && swift test` — `Build complete!`, all tests pass.
- [ ] **Worker untouched:** confirm no files under `python-worker/` changed in this phase (`git diff --name-only main...HEAD -- python-worker/` is empty).
- [ ] **Human end-to-end (cannot be done by an agent):** follow spec §11 — download models in Settings, record a Call/Meeting with a mic and ≥2 remote speakers, confirm `<id>_system_diarization.json` has multiple `Speaker N` and `<id>_analysis.json` shows the extra speakers + labeled transcript. Report results back; do not claim end-to-end success from unit tests alone.

## Notes for later phases

- Phase 4 (acoustic emotion + sentiment) and Phase 5 (insight prompts + per-type note shapes) build on the speaker labels this phase produces.
- The pyannote (Python) provider remains a documented fallback: implement `DiarizationProvider` in a second type; nothing else changes.
- An active in-app hint for the "type wants diarization but models not downloaded" case is a deferred UX option (currently silent-degrade + passive Settings status).

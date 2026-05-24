# Voice Intelligence — Phase 3b: FluidAudio Diarizer (Design)

**Date:** 2026-05-24
**Status:** Approved (pending written-spec review)
**Master spec:** `docs/superpowers/specs/2026-05-23-voice-intelligence-design.md` (§4, §6)
**Builds on:** Phase 2 (separate stems) and Phase 3a (worker analysis core that already
consumes the diarization sidecar). Both merged to `main`.

---

## 1. Goal

Produce **real multi-speaker** turns for the remote audio of a recording by running
the **FluidAudio** Swift SDK (CoreML / Apple Neural Engine) in the macOS app, and
writing a `*_diarization.json` turns sidecar **before** the Python worker transcribes.
The worker (Phase 3a) already reads this sidecar and attributes/labels segments — this
phase does **not** change any worker code. The diarization engine sits behind a
`DiarizationProvider` protocol so it can be swapped (pyannote is the documented
fallback) without touching callers.

This is the only new piece needed to turn Phase 3a's single `"Speaker 1"` remote
fallback into A/B/C… speaker separation.

## 2. Decisions (resolved during brainstorming)

- **Model download is an explicit Settings action.** FluidAudio auto-downloads its
  models (~tens of MB) from HuggingFace (no token) on first use. We do **not** download
  silently mid-recording. A "Download diarization models" button in Settings triggers
  the download and records a persisted `diarizationModelsReady` flag.
- **Diarize the remote audio either way.** Run on `<id>_system.wav` when it exists (a
  mic was selected), otherwise on the mixed `<id>.wav` (no-mic recordings are
  output-only = remote). A no-mic Call/Meeting still gets speaker separation.
- **Gating is type-based only.** Diarization runs iff
  `RecordingType(rawValue: session.recordingType)?.diarize == true` **and**
  `diarizationModelsReady == true`. No separate "enable diarization" toggle.
  (`call_meeting` → yes; `voice_memo` → no; `lecture` → off by default — unchanged.)
- **Failure degrades silently + passively.** Any failure (models not ready, download
  error, SDK throw, unreadable audio) logs via OSLog, writes **no** sidecar, and
  returns; the worker then falls back to single `"Speaker 1"` and the note is still
  produced. Discovery of the missing-models case is passive: the Settings section shows
  the model status. (An active in-app hint is a documented future option, not built
  here.)
- **Speaker labels are 1-based `"Speaker N"`** by order of first appearance, matching
  the worker's single-speaker fallback label `"Speaker 1"`.
- **Engine: FluidAudio offline diarizer** (`OfflineDiarizerManager`) — best accuracy and
  variable speaker count for post-call batch work. Streaming engines (LS-EEND,
  Sortformer) are live-mode seams, out of scope.

## 3. Architecture

New Swift group `macos-app/Sources/Diarization/`:

### `DiarizationProvider.swift`
```swift
/// A diarization turn for one speaker over the remote-audio timeline.
struct DiarizationTurn: Codable, Equatable, Sendable {
    let speaker: String   // "Speaker 1", "Speaker 2", …
    let start: Double      // seconds
    let end: Double        // seconds
}

/// A swappable speaker-diarization engine. FluidAudio is the default; pyannote is
/// the documented fallback. Implementations own their own model lifecycle.
protocol DiarizationProvider: Sendable {
    /// Downloads (if needed) and loads models. Called from the Settings download
    /// action; safe to call repeatedly.
    func prepareModels() async throws

    /// Diarizes the audio at `audioPath` into normalized speaker turns.
    func diarize(audioPath: URL) async throws -> [DiarizationTurn]
}
```

### `FluidAudioDiarizer.swift`
Conforms to `DiarizationProvider`, wrapping `OfflineDiarizerManager`:
- `prepareModels()` → `try await manager.prepareModels()` (download-if-needed + load).
- `diarize(audioPath:)` → ensures models are loaded **in this process** (lazily, once),
  resamples the file to 16 kHz mono via the SDK's converter (our stems are already
  16 kHz mono), runs the SDK's process call, then maps the SDK segments through the
  label normalizer.
- Holds an in-process "loaded this session" guard separate from the persisted
  "downloaded to disk" flag (per-process loading is required even when models are
  already on disk).

> **Exact FluidAudio symbol names** (`OfflineDiarizerManager`, `OfflineDiarizerConfig`,
> `prepareModels`, the process entry point, and the segment fields `speakerId` /
> `startTimeSeconds` / `endTimeSeconds`) are taken from the project README and **must be
> confirmed against the resolved `from: 0.12.4` package** during implementation; adjust
> to the real API if they differ. Only `FluidAudioDiarizer.swift` is affected.

### `SpeakerLabelNormalizer.swift` (pure)
```swift
/// Maps arbitrary engine cluster ids to "Speaker 1", "Speaker 2", … by order of
/// first appearance. Pure and unit-tested.
func normalizeTurns(_ raw: [(speakerId: Int, start: Double, end: Double)]) -> [DiarizationTurn]
```

### `DiarizationSidecar.swift` (pure)
- `sidecarPath(forAudioAt audioPath: URL) -> URL` — mirrors the worker's rule exactly:
  strip the extension and append `_diarization.json`
  (`…/<name>.wav` → `…/<name>_diarization.json`).
- `write(_ turns: [DiarizationTurn], forAudioAt:) throws` — atomic write of
  `{"turns":[{"speaker","start","end"},…]}` (temp file + rename).

### `DiarizationService.swift` (orchestration)
Holds `private let provider: any DiarizationProvider` (defaults to `FluidAudioDiarizer`,
injected as a fake in tests) and a reference to settings for the readiness flag.
```swift
func diarizeIfNeeded(session: Session) async
```
1. Resolve `RecordingType(rawValue: session.recordingType)`; return unless `.diarize`.
2. Return unless `settings.diarizationModelsReady`.
3. Pick the remote audio URL: `<id>_system.wav` if it exists on disk, else the session
   `audioPath` (`<id>.wav`).
4. `let turns = try await provider.diarize(audioPath: remoteURL)`.
5. `try DiarizationSidecar.write(turns, forAudioAt: remoteURL)`.
6. Any thrown error → OSLog `error`, return (graceful degrade; no sidecar).

## 4. Sidecar path contract (verified against the merged worker)

The Phase 3a worker reads the sidecar via
`load_diarization_turns(<remote_file>)` →
`os.path.splitext(<remote_file>)[0] + "_diarization.json"`:

| Case | Worker reads (remote file) | Sidecar path the worker computes |
|---|---|---|
| Mic selected (stems) | `<id>_system.wav` | `<id>_system_diarization.json` |
| No mic (mixed only)  | `<id>.wav`        | `<id>_diarization.json` |

Therefore the Swift writer **must name the sidecar after the exact file it diarized**,
using the same strip-extension-and-append rule. Because `DiarizationService` diarizes
the same file the worker treats as remote (system stem if present, else mixed) and uses
the identical naming rule, the two always agree. (Note: the Phase 3b task brief's
"`<id>_diarization.json`" is only correct for the no-mic path; the mic path is
`<id>_system_diarization.json`.)

## 5. Invocation & data flow

In `AppModel.transcribeSession(_:)` (`CallCaptureApp.swift`), **before**
`pythonBridge.runJob(request:)` and after the LLM-env setup:

```swift
await diarizationService.diarizeIfNeeded(session: session)
let result = try await pythonBridge.runJob(request: request)
```

Diarization is awaited (must finish before the worker reads the sidecar) and never
throws to the caller. `AppModel` owns a `let diarizationService = DiarizationService(...)`.

Ordering recap: capture → stems on disk → **diarize remote → write sidecar** → worker
transcribes stems and reads sidecar → attribution/metrics → analysis JSON + note.

## 6. Model lifecycle

Two distinct states, deliberately separated:
- **Downloaded to disk** — persisted `diarizationModelsReady` in `SettingsManager`
  (UserDefaults-backed, like existing settings). Set `true` after the Settings button's
  `prepareModels()` succeeds. This is what `DiarizationService` gates on and what the
  Settings UI reflects.
- **Loaded into memory this process** — internal to `FluidAudioDiarizer`; CoreML models
  must be loaded once per app launch before processing. The provider does this lazily on
  first `diarize` via the SDK's prepare/load entry point. Because the service only calls
  `diarize` when `diarizationModelsReady` is `true` (models already on disk), the normal
  path loads from the local cache without a network download. The rare edge where the
  on-disk cache was cleared after the flag was set may cause a re-download (or a load
  error → degrade); this is an accepted edge, not a correctness concern.

## 7. Settings UX

A "Speaker Diarization" section in `SettingsView.swift`:
- Status line: **Not downloaded** / **Downloading…** / **Ready** / **Failed: <reason>**.
- **Download models** button → calls `provider.prepareModels()` in a `Task`; on success
  sets `settings.diarizationModelsReady = true`; on failure shows the error and leaves
  the flag false. Disabled while downloading and when already ready.

`SettingsManager` gains `var diarizationModelsReady: Bool` persisted to UserDefaults
(default `false`), following the existing settings pattern.

## 8. Error handling

- Provider/SDK errors are typed where practical and surfaced to the Settings UI on the
  download path (the only user-facing path).
- On the diarization path, all errors are caught by `DiarizationService`, logged, and
  swallowed — transcription must never be blocked or failed by diarization.
- Missing remote file (shouldn't happen post-capture) → log + return.

## 9. Testing

Swift Testing, `@testable import CallCapture`, `@Test` funcs marked
`@available(macOS 14.2, *)`. All unit tests use a **fake** `DiarizationProvider` and
temp directories — no SDK, no model download, no real audio:
- **`SpeakerLabelNormalizer`**: arbitrary/duplicate/out-of-order cluster ids → stable
  1-based `"Speaker N"` by first appearance.
- **`DiarizationSidecar`**: path rule for `<id>.wav` and `<id>_system.wav`; atomic write
  round-trips to the documented JSON shape; the JSON is byte-compatible with the
  worker's `load_diarization_turns` (validated by shape).
- **`DiarizationService`**: runs when type diarizes + models ready; skips when type
  doesn't diarize; skips when models not ready; selects the system stem when present and
  the mixed file otherwise; writes the sidecar at the correct path; swallows a throwing
  provider (degrade) and writes nothing.

The real `FluidAudioDiarizer` (network model download + ANE inference on real audio) is
**verified manually by the human** — it cannot be exercised in unit tests or by an
agent. See §11.

## 10. Dependencies

Add to `macos-app/Package.swift`:
```swift
.package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4")
```
and the `FluidAudio` product to the `CallCapture` target. `swift build`/`swift test`
stay hermetic — FluidAudio downloads **models** at runtime (via `prepareModels`), not at
build time. `import FluidAudio` is confined to `FluidAudioDiarizer.swift`.

## 11. Manual verification (human)

1. `cd macos-app && swift build && swift test` — build succeeds (fetches FluidAudio),
   all tests pass.
2. `./run-dev.sh`, open Settings → **Download diarization models** → status reaches
   **Ready**.
3. Record a Call/Meeting with a **mic** selected and **two or more remote speakers**
   playing; stop; let it process.
4. Inspect the sidecar and analysis:
   ```bash
   DIR="$HOME/Library/Application Support/CallCapture/audio"
   ID=$(sqlite3 "$HOME/Library/Application Support/CallCapture/callcapture.db" \
     "SELECT id FROM session ORDER BY started_at DESC LIMIT 1;")
   cat "$DIR/${ID}_system_diarization.json"   # turns with Speaker 1, Speaker 2, …
   cat "$DIR/${ID}_analysis.json"             # num_speakers ≥ 3 (You + ≥2 remote)
   ```
   Expected: the sidecar has multiple speakers; the note's transcript shows
   `You` / `Speaker 1` / `Speaker 2` labels.

## 12. Out of scope

- Streaming/live diarization (LS-EEND / Sortformer) — live-mode seams only.
- The pyannote (Python) provider implementation — the seam exists; impl is deferred.
- Acoustic emotion, sentiment, type-tailored insight prompts, per-type note shapes,
  Session Detail insights UI — Phases 4–6.
- Bundling/packaging the FluidAudio models for distribution — a packaging milestone.

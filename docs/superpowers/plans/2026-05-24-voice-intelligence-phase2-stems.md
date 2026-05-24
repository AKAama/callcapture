# Voice Intelligence — Phase 2: Separate-Stem Capture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a microphone is selected, additionally write two separate 16 kHz mono WAV stems next to the mixed recording — `<id>_mic.wav` (your voice) and `<id>_system.wav` (remote audio) — so Phase 3 can diarize the system stem and attribute the mic stem to "You". The existing mixed `<id>.wav` keeps being produced unchanged.

**Architecture:** The IO proc on the private aggregate device already receives the mic and tap as separate float buffers in one `AudioBufferList` (sub-device buffers first, then tap buffers). We read the tap's channel count at setup; in the callback we partition the buffer list — trailing buffers summing to the tap channel count are the system stem, the rest are the mic stem — and downmix each subset to its own mono writer, in addition to the full mix. No mic selected ⇒ no stems (the mixed file is already system-only).

**Tech Stack:** Swift 5.9, Core Audio (`AudioObjectGetPropertyData`, `kAudioTapPropertyFormat`), AVFoundation (`AVAudioConverter`, `AVAudioPCMBuffer`), Swift Testing. Reference spec: `docs/superpowers/specs/2026-05-23-voice-intelligence-design.md` §3.

This phase changes **capture only**. It does NOT change the Python worker, transcription, or the `JobRequest` — Phase 3 will consume the stems (found by naming convention `<base>_mic.wav` / `<base>_system.wav`).

---

## File Structure

- Modify `macos-app/Sources/Capture/AudioCaptureManager.swift`:
  - new stored state for the two stem writers, their converters, and the tap channel count;
  - read tap channel count at setup; create stem writers when a mic is present;
  - extract a pure `Self.systemBufferSplit(channelCounts:systemChannels:)` helper;
  - extract a `downmix(...)` helper used for mix + each stem;
  - rewrite `handleIO` to write the mix plus (when present) the two stems;
  - finalize/clear the stem writers in `stopCapture` and `emergencyStop`.
- Create `macos-app/Tests/CallCaptureTests/BufferSplitTests.swift` — unit tests for the pure split helper.

The real-time file-writing path is verified by a manual recording (it can't be unit-tested); the partition math is covered by the pure-function tests.

---

## Task 1: Pure buffer-split helper (TDD)

**Files:**
- Modify: `macos-app/Sources/Capture/AudioCaptureManager.swift`
- Test: `macos-app/Tests/CallCaptureTests/BufferSplitTests.swift`

The aggregate's `AudioBufferList` lists the mic sub-device buffer(s) first, then the tap buffer(s). Given each buffer's channel count and the known tap (system) channel count, return the index at which the system buffers begin: the smallest split where the trailing buffers' channels sum to exactly the system channel count.

- [ ] **Step 1: Write the failing test**

Create `macos-app/Tests/CallCaptureTests/BufferSplitTests.swift`:

```swift
import Testing
@testable import CallCapture

@Suite("System/mic buffer split")
struct BufferSplitTests {
    @Test("mic 1ch + tap 2ch as two buffers")
    func micThenTap() {
        // buffers: [mic 1ch, tap 2ch], system=2 -> system starts at index 1
        #expect(AudioCaptureManager.systemBufferSplit(channelCounts: [1, 2], systemChannels: 2) == 1)
    }

    @Test("per-channel layout: 1ch mic + 2x1ch tap")
    func perChannel() {
        // buffers: [1,1,1], system=2 -> trailing two buffers sum to 2 -> index 1
        #expect(AudioCaptureManager.systemBufferSplit(channelCounts: [1, 1, 1], systemChannels: 2) == 1)
    }

    @Test("no mic: all buffers are system")
    func noMic() {
        #expect(AudioCaptureManager.systemBufferSplit(channelCounts: [2], systemChannels: 2) == 0)
    }

    @Test("stereo mic + stereo tap")
    func stereoBoth() {
        #expect(AudioCaptureManager.systemBufferSplit(channelCounts: [2, 2], systemChannels: 2) == 1)
    }

    @Test("returns nil when trailing channels cannot sum to systemChannels")
    func unsplittable() {
        // trailing sums: 2, then 2+1=3 — never exactly 3 from a clean buffer boundary for system=3
        #expect(AudioCaptureManager.systemBufferSplit(channelCounts: [1, 2], systemChannels: 3) == 0)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd macos-app && swift test --filter BufferSplitTests`
Expected: FAIL — `systemBufferSplit` does not exist.

- [ ] **Step 3: Implement the helper**

In `macos-app/Sources/Capture/AudioCaptureManager.swift`, add this `static` method (place it in the `// MARK: - Private Helpers` section, e.g. just above `handleIO`):

```swift
    /// Index into a buffer list at which the system (tap) buffers begin.
    ///
    /// The aggregate device lists mic sub-device buffers first, then tap
    /// buffers. The trailing buffers whose channels sum to `systemChannels`
    /// are the system stem; everything before them is the mic stem.
    ///
    /// - Returns: The split index (system buffers are `index..<count`). Returns
    ///   `0` (treat everything as system) if no clean split sums to
    ///   `systemChannels`, which is the safe default for the no-mic case.
    static func systemBufferSplit(channelCounts: [Int], systemChannels: Int) -> Int {
        var trailing = 0
        var index = channelCounts.count
        while index > 0 {
            trailing += channelCounts[index - 1]
            index -= 1
            if trailing == systemChannels { return index }
            if trailing > systemChannels { break }
        }
        return 0
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd macos-app && swift test --filter BufferSplitTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add macos-app/Sources/Capture/AudioCaptureManager.swift macos-app/Tests/CallCaptureTests/BufferSplitTests.swift
git commit -m "feat(app): add pure mic/system buffer-split helper for stems"
```

---

## Task 2: Stem state, tap channel count, and writers

**Files:**
- Modify: `macos-app/Sources/Capture/AudioCaptureManager.swift`

- [ ] **Step 1: Add stored properties**

In `AudioCaptureManager`, after the existing `private var converter: AVAudioConverter?` line, add:

```swift
    /// Separate-stem writers, created only when a mic is selected.
    private var micWriter: AudioFileWriter?
    private var systemWriter: AudioFileWriter?
    private var micConverter: AVAudioConverter?
    private var systemConverter: AVAudioConverter?
    /// Channel count of the system tap, used to split the IO buffer list.
    private var systemTapChannels: Int = 0
```

- [ ] **Step 2: Add a tap-channel-count reader**

Add this `static` helper near `deviceInputFormat`:

```swift
    /// Reads the channel count of a process tap's stream format.
    private static func tapChannelCount(tapID: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr, asbd.mChannelsPerFrame > 0 else { return 2 }
        return Int(asbd.mChannelsPerFrame)
    }
```

- [ ] **Step 3: Create stem writers in `startCapture` when a mic is present**

In `startCapture`, right after the block that sets `self.mixFormat = mixFormat`, `self.targetFormat = outputFormat`, `self.converter = converter`, `self.fileWriter = writer`, `self.bufferCount = 0`, add:

```swift
        // Record the tap channel count so the IO proc can split mic vs system.
        self.systemTapChannels = Self.tapChannelCount(tapID: self.tapID)

        // When a mic is mixed in, also write separate mic/system stems for
        // later diarization. Named alongside the mixed file.
        if micDeviceUID != nil {
            let dir = outputPath.deletingLastPathComponent()
            let stem = outputPath.deletingPathExtension().lastPathComponent  // "<id>"
            let micURL = dir.appendingPathComponent("\(stem)_mic.wav")
            let systemURL = dir.appendingPathComponent("\(stem)_system.wav")
            // Both filenames end in `.wav` so AVAudioFile writes RIFF/WAV (a
            // non-`.wav` extension would silently produce CAF).
            self.micWriter = try AudioFileWriter(outputPath: micURL, format: outputFormat)
            self.systemWriter = try AudioFileWriter(outputPath: systemURL, format: outputFormat)
            self.micConverter = AVAudioConverter(from: mixFormat, to: outputFormat)
            self.systemConverter = AVAudioConverter(from: mixFormat, to: outputFormat)
            Self.logger.info("startCapture: writing mic+system stems (tapCh=\(self.systemTapChannels))")
        }
```

Note: `outputPath` is `<dir>/<id>.wav`; this produces `<dir>/<id>_mic.wav` and `<dir>/<id>_system.wav` (both end in `.wav`, so AVAudioFile writes WAV). Phase 3 looks for `<id>_mic.wav` / `<id>_system.wav`.

- [ ] **Step 4: Verify it builds**

Run: `cd macos-app && swift build`
Expected: `Build complete!`

- [ ] **Step 5: Commit**

```bash
git add macos-app/Sources/Capture/AudioCaptureManager.swift
git commit -m "feat(app): set up mic/system stem writers when a mic is selected"
```

---

## Task 3: Write the stems in the IO callback

**Files:**
- Modify: `macos-app/Sources/Capture/AudioCaptureManager.swift`

- [ ] **Step 1: Extract a downmix helper**

In `AudioCaptureManager`, add this instance method just above `handleIO`:

```swift
    /// Sums the given buffer-index range of an aggregate buffer list into a
    /// freshly allocated mono buffer (channel-averaged per stream, then averaged
    /// across streams). Returns nil if the range is empty or invalid.
    private func downmix(
        _ abl: UnsafeMutableAudioBufferListPointer,
        indices: Range<Int>,
        frameCount: Int,
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        guard !indices.isEmpty, frameCount > 0 else { return nil }
        guard let out = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ), let dst = out.floatChannelData?[0] else { return nil }
        out.frameLength = AVAudioFrameCount(frameCount)
        for i in 0..<frameCount { dst[i] = 0 }

        var streams = 0
        for bufferIndex in indices {
            let buffer = abl[bufferIndex]
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0, let raw = buffer.mData else { continue }
            let src = raw.assumingMemoryBound(to: Float.self)
            let bufFrames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            let n = min(bufFrames, frameCount)
            for f in 0..<n {
                var sum: Float = 0
                for c in 0..<channels { sum += src[f * channels + c] }
                dst[f] += sum / Float(channels)
            }
            streams += 1
        }
        if streams > 1 {
            let scale = 1.0 / Float(streams)
            for i in 0..<frameCount { dst[i] *= scale }
        }
        return out
    }
```

- [ ] **Step 2: Rewrite `handleIO` to use the helper and write stems**

Replace the entire body of `handleIO` (from `let abl = ...` through `return noErr`, keeping the `guard let mixFormat, ...` at the top) with:

```swift
        let abl = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inInputData)
        )
        guard abl.count > 0 else { return noErr }

        let first = abl[0]
        let firstChannels = Int(first.mNumberChannels)
        guard firstChannels > 0, first.mDataByteSize > 0 else { return noErr }
        let frameCount = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * firstChannels)
        guard frameCount > 0 else { return noErr }

        bufferCount += 1
        if bufferCount == 1 {
            let shapes = abl.map { "\($0.mNumberChannels)ch/\($0.mDataByteSize)B" }
                .joined(separator: ", ")
            Self.logger.info("IO buffers: count=\(abl.count) [\(shapes)] frames=\(frameCount) tapCh=\(self.systemTapChannels)")
        }

        // Full mix (all buffers) -> main writer (unchanged behavior).
        if let mix = downmix(abl, indices: 0..<abl.count, frameCount: frameCount, format: mixFormat) {
            handleAudioBuffer(mix, converter: converter, outputFormat: targetFormat, writer: writer)
        }

        // Separate stems (only when mic writers were created).
        if let micWriter, let systemWriter,
           let micConverter, let systemConverter {
            let channelCounts = abl.map { Int($0.mNumberChannels) }
            let split = Self.systemBufferSplit(
                channelCounts: channelCounts, systemChannels: systemTapChannels
            )
            if split > 0, let micBuf = downmix(abl, indices: 0..<split, frameCount: frameCount, format: mixFormat) {
                handleAudioBuffer(micBuf, converter: micConverter, outputFormat: targetFormat, writer: micWriter)
            }
            if let sysBuf = downmix(abl, indices: split..<abl.count, frameCount: frameCount, format: mixFormat) {
                handleAudioBuffer(sysBuf, converter: systemConverter, outputFormat: targetFormat, writer: systemWriter)
            }
        }
        return noErr
```

- [ ] **Step 3: Verify it builds**

Run: `cd macos-app && swift build`
Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add macos-app/Sources/Capture/AudioCaptureManager.swift
git commit -m "feat(app): write mic and system stems in the IO callback"
```

---

## Task 4: Finalize/clear stem writers on stop

**Files:**
- Modify: `macos-app/Sources/Capture/AudioCaptureManager.swift`

- [ ] **Step 1: Finalize stems in `stopCapture`**

In `stopCapture()`, after `stopIOProc()` and before the existing `do { try fileWriter?.finalize() } ...` block, add:

```swift
        try? micWriter?.finalize()
        try? systemWriter?.finalize()
```

And in the same method, where `fileWriter = nil` / `converter = nil` are set at the end (both the success path and the catch path), also clear the stem state. Add after each `converter = nil`:

```swift
        micWriter = nil
        systemWriter = nil
        micConverter = nil
        systemConverter = nil
```

- [ ] **Step 2: Finalize stems in `emergencyStop`**

In `emergencyStop()`, after `try? fileWriter?.finalize()` and before `fileWriter = nil`, add:

```swift
        try? micWriter?.finalize()
        try? systemWriter?.finalize()
```

And after `converter = nil` in that method add:

```swift
        micWriter = nil
        systemWriter = nil
        micConverter = nil
        systemConverter = nil
```

- [ ] **Step 3: Verify it builds and tests pass**

Run: `cd macos-app && swift build && swift test`
Expected: `Build complete!` and all tests pass (RecordingType 3, Database migration 1, BufferSplit 5 = 9 tests).

- [ ] **Step 4: Commit**

```bash
git add macos-app/Sources/Capture/AudioCaptureManager.swift
git commit -m "feat(app): finalize mic/system stems on stop and teardown"
```

---

## Task 5: Manual end-to-end verification

- [ ] **Step 1: Build + run**

Run: `./run-dev.sh`. In the popover pick a **Mic** + **Output**, choose a recording type, record ~10s while **both** talking into the mic and playing system audio, then stop.

- [ ] **Step 2: Inspect the three files**

```bash
DIR="$HOME/Library/Application Support/CallCapture/audio"
ID=$(sqlite3 "$HOME/Library/Application Support/CallCapture/callcapture.db" "SELECT id FROM session ORDER BY started_at DESC LIMIT 1;")
ls -la "$DIR/$ID.wav" "$DIR/${ID}_mic.wav" "$DIR/${ID}_system.wav"
for f in "$ID.wav" "${ID}_mic.wav" "${ID}_system.wav"; do
  echo "== $f =="; file "$DIR/$f"
done
```

Expected: all three exist and are `RIFF (little-endian) data, WAVE audio`.

- [ ] **Step 3: Confirm each stem has the right content**

Play each (`afplay "$DIR/${ID}_mic.wav"`, `afplay "$DIR/${ID}_system.wav"`). Expected: `_mic.wav` contains your voice only; `_system.wav` contains the system audio only; `<id>.wav` contains both. Also check the OSLog (`scripts/debug-logstream.sh`) `IO buffers:` line shows the expected layout and `tapCh`, and `Finalized: N frames written` (N > 0) appears for all three writers.

- [ ] **Step 4: Confirm no-mic path is unchanged**

Record again with **Mic = None**. Expected: only `<id>.wav` is produced (no `_mic.wav` / `_system.wav`), and it still contains system audio.

---

## Notes for later phases

- **Phase 3** consumes these stems by convention: `<id>_mic.wav` (= "You", single speaker) and `<id>_system.wav` (remote → diarize). It will transcribe each stem and merge by timestamp.
- Stem attribution assumes the aggregate orders sub-device (mic) buffers before tap buffers; the `IO buffers:` log line plus the manual check in Task 5 verify this on real hardware. If a future macOS reverses the order, only `systemBufferSplit` + its callers need adjusting.

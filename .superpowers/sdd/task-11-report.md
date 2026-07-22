# Task 11 Report: Production Realtime Integration

## Result

Status: `DONE_WITH_MANUAL_GAPS`

The realtime meeting flow is reachable from the menu bar and owns its complete
runtime lifecycle. Production compilation, source/test syntax parsing, focused
runtime smoke, diff checks, privacy scans, and an independent code review are
complete. The permanent Swift Testing suite remains blocked by this host's
missing `Testing` module, as authorized for build-only execution. Real Tencent
Meeting, Zoom, and Feishu desktop validation was not performed and remains an
explicit manual checklist.

## Production Integration

- `AppModel` retains `SubtitlePanelController`, `MeetingAssistant`,
  `AssistantPanelController`, and a `GlobalShortcutManaging` production owner.
- `ContentView` now contains only the realtime application picker, start/stop,
  coordinator status, subtitle panel, assistant, settings, external subtitle
  mouse-passthrough unlock, and quit actions.
- The main menu has no call sites for legacy microphone selection, recording,
  session creation/listing, Python transcription, or post-processing. Those
  legacy modules remain compiled for compatibility.
- Starting capture clears prior assistant state, unlocks/reuses the subtitle
  panel, and starts `LiveMeetingCoordinator` with the exact selected process.
- Stopping enters coordinator review mode. Subtitle clear/close also clears
  assistant memory. App exit unregisters the shortcut, clears/closes both
  panels and assistant state, and synchronously shuts down/clears the
  coordinator.
- The assistant continues to have no coordinator dependency. LLM 401, 429,
  timeout, cancellation, or stream failure therefore cannot stop capture/ASR.
- Tencent App ID, Secret ID, and Secret Key are reachable in Settings and use
  dedicated Keychain accounts.
- The assistant context is fixed to exactly 30 seconds in production. The
  Settings UI displays the fixed boundary rather than allowing the approved
  privacy promise to become inaccurate.

## Shortcut and Panel Reachability

- `AppDelegate.applicationDidFinishLaunching` installs the saved global
  shortcut after AppKit launch.
- The default is Option-Space. Settings offers deterministic replacement
  presets and an enable/disable switch.
- Reconfiguration unregisters first; disable and teardown unregister; the
  Carbon manager also unregisters before its own registration and during
  deinitialization.
- Both the shortcut and menu action open the retained assistant panel.
- Locking the subtitle panel publishes state back to `AppModel`; the menu-bar
  UI then exposes `解锁字幕窗口鼠标操作`, which remains clickable while the panel
  ignores mouse events.

## Privacy Review

The exact approved copy is shared by the preflight menu and Settings and is
also documented in README/development guidance:

> 所选应用音频会发送到腾讯云 ASR；只有手动提交时，最近 30 秒字幕才会发送到所配置的 LLM；内容不会保存到本地

- Realtime path scan found no meeting-content file writes.
- Realtime path scan found no sensitive-content logging calls.
- Menu-flow scan found no legacy recording, microphone, session, worker, or
  post-processing call sites.
- Credential values load/save through Keychain; only non-sensitive shortcut
  and provider preferences use the settings database.
- Documentation warns that desktop validation must use a bundled, signed app;
  bare `swift run` lacks the required Info.plist and entitlements.

## Tests and Verification Evidence

1. Focused integration tests were written before production integration for
   coordinator-state presentation, exact privacy copy, shortcut defaults,
   Keychain-backed Tencent settings, and shortcut persistence.
2. The initial focused `swift test --filter 'Realtime app integration'`
   attempt reached test-target compilation and stopped at the known host error
   `no such module 'Testing'`; no permanent test case executed.
3. Review-driven coverage added a real `AppModel` lifecycle regression with an
   injected shortcut seam. It verifies default registration, replacement,
   disable/unregister, and teardown clearing of the real transcript store and
   assistant state.
4. The final full `swift test` attempt again stopped only at
   `no such module 'Testing'`; this is an environment/toolchain gap, not a
   reported assertion failure.
5. Final `swift build` completed successfully. It emitted only the existing
   unrelated `HeartbeatPing.action` Codable warning in `Bridge/Models.swift`.
6. `swiftc -frontend -parse Tests/CallCaptureTests/*.swift` completed with exit
   code 0.
7. Syntax parsing for the modified App, Assistant, Settings, and UI sources
   completed with exit code 0.
8. A standalone runtime smoke compiled the real transcript store,
   `MeetingAssistant`, LLM configuration, and shortcut sources. It verified
   the fixed 30-second boundary, memory clearing, and default shortcut values,
   then printed `task11-runtime-smoke-pass`.
9. `git diff --check` and `git diff --cached --check` completed with no output.
10. Focused scans returned no realtime meeting-content writes, sensitive
    logging, or legacy menu-flow calls.
11. Independent read-only review found no Critical defect. Its Important
    findings were fixed: context is fixed to 30 seconds, launch no longer
    enumerates microphones, AppModel lifecycle coverage was added, and source
    launch documentation now uses the signed app bundle.

## Commit

- `da262af feat: ship realtime meeting overlay assistant`

The commit contains only the focused integration sources, tests, README, and
development guide. Existing untracked SDD artifacts were not staged.

## Remaining Manual Gaps

The complete pending checklist is in `docs/DEVELOPMENT.md`. No claim is made
that these checks have run:

- Tencent Meeting, Zoom, and Feishu capture on a real macOS desktop.
- Proof that unrelated system audio is excluded and the microphone stays off.
- Mixed Chinese/English speech and at least two remote speakers.
- Disconnect/reconnect, meeting-app exit, permission denial/revocation, and ASR
  retry exhaustion.
- LLM 401, 429, timeout, cancellation, retry, and malformed stream while live
  subtitles continue.
- AppKit focus, dragging, resize, opacity, font size, passthrough unlock,
  multiple displays, Spaces, and full-screen behavior.
- Post-close filesystem inspection under
  `~/Library/Application Support/CallCapture` proving no meeting audio,
  subtitle, prompt, or reply file was created.
- Full Swift Testing execution on a matching Xcode/SDK toolchain.

## Follow-up: Bundle Build Portability

Two review findings were addressed without removing the legacy worker bundle:

- `README.md` now states that a clean source checkout needs Xcode/Swift and a
  Python 3.11 `python-worker/.venv`, then gives the exact
  `.[packaging]` installation command required for `build-app.sh` to freeze
  the worker. `docs/DEVELOPMENT.md` documents the complete `.[dev,packaging]`
  developer setup and explains which extra supplies PyInstaller.
- `build-app.sh` now requires that project virtual environment when a worker
  rebuild is needed and runs its `PyInstaller` module directly. It no longer
  silently falls back to an unrelated system `pyinstaller` executable.
- `build-app.sh` obtains the active SwiftPM output directory with
  `swift build --show-bin-path`; `assemble-app.sh` receives the resolved
  executable path instead of reconstructing an Apple-Silicon-specific path.
- `macos-app/Scripts/smoke-swift-binary-path.sh` checks that neither bundle
  script contains an architecture-specific SwiftPM product path and, in its
  normal mode, verifies that SwiftPM produced an executable `CallCapture`
  product. Its `--syntax-only` mode is safe when a host toolchain cannot
  compile.

### Follow-up verification evidence

1. `bash -n macos-app/Scripts/build-app.sh macos-app/Scripts/assemble-app.sh
   macos-app/Scripts/smoke-swift-binary-path.sh` completed with exit code 0.
2. `bash macos-app/Scripts/smoke-swift-binary-path.sh --syntax-only` printed
   `swift-binary-path-static-smoke-pass`.
3. With the compiler module cache directed to a writable temporary directory,
   `bash macos-app/Scripts/smoke-swift-binary-path.sh` printed
   `swift-binary-path-smoke-pass` and resolved the current arm64 SwiftPM
   executable. The script itself does not encode that architecture.
4. `cd macos-app && swift build` completed successfully (the same temporary
   module-cache setting was needed by this sandboxed host).
5. `git diff --check` completed with no output. A documentation consistency
   scan confirmed matching Python/PyInstaller worker prerequisites and
   `--show-bin-path` usage, with no hard-coded arm64/x86_64 product path in
   either bundle script.

## Follow-up: Release Workflow Assembler Interface

The release workflow previously still invoked `assemble-app.sh` with the old
`release` configuration argument. It now builds the release product first,
uses `swift build -c release --show-bin-path` to locate the active SwiftPM
output directory, verifies the `CallCapture` executable, and exports that
path as `CALLCAPTURE_SWIFT_BINARY` for the assembly step. This keeps the
workflow architecture-independent and matches the current assembler contract.

The safe `smoke-swift-binary-path.sh --syntax-only` check now also validates
that the release workflow orders release build, binary resolution, and
assembly correctly, and that assembly receives the exported binary path.

### Release workflow verification evidence

1. The new workflow-interface static smoke failed before the workflow update
   with `release workflow must build, resolve, then assemble with
   CALLCAPTURE_SWIFT_BINARY`, then passed after the update.
2. `bash -n` completed for the bundle and smoke scripts, and the static smoke
   printed `swift-binary-path-static-smoke-pass`.
3. Ruby parsed `.github/workflows/release.yml` successfully.
4. `swift build -c release --product CallCapture` completed successfully, and
   `swift build -c release --show-bin-path` resolved an executable release
   `CallCapture` binary. This sandboxed host required a writable temporary
   compiler module-cache location.
5. `git diff --check` completed with no output.

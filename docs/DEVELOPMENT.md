# Development Guide

Architecture, build, and verification guidance for CallCapture's production realtime meeting flow.

## Repository layout

```text
callcapture/
├── macos-app/
│   ├── Sources/
│   │   ├── App/          # menu flow, AppModel ownership, process lifecycle
│   │   ├── Capture/      # process enumeration and Core Audio process tap
│   │   ├── Live/         # bounded PCM queue, Tencent ASR, transcript store/coordinator
│   │   ├── Assistant/    # LLM configuration/client, assistant state, global shortcut
│   │   ├── Settings/     # Keychain-backed credentials and realtime settings UI
│   │   └── UI/           # native subtitle and assistant panels
│   └── Tests/CallCaptureTests/
├── python-worker/        # legacy post-meeting worker still bundled by build-app.sh
└── docs/superpowers/     # approved design and implementation plan
```

Legacy recording, session, Python-worker, and post-processing modules remain in the package so existing source compatibility is preserved. `ContentView` and the realtime `AppModel` entry points do not call them.

`macos-app/Scripts/build-app.sh` still packages the legacy worker into every
desktop bundle. A clean source checkout therefore needs the worker's Python
environment even when validating only the realtime UI.

## Production data flow

```text
AudioProcessEnumerator
  → user selects one AudioProcessInfo
  → AppModel.startLiveMeeting(process:)
      → clears prior transcript and assistant memory
      → LiveMeetingCoordinator
          ├─ AudioCaptureManager.startLiveCapture(processObjectID:onPCM:)
          ├─ PCMChunkBuffer (bounded, memory-only)
          └─ TencentLiveTranscriber
                → LiveTranscriptStore (memory-only)
                    ├─ SubtitlePanelController / LiveSubtitleView
                    └─ MeetingAssistant (confirmed 30-second context)
                          → explicit submit only
                          → OpenAICompatibleClient
```

The coordinator owns capture and ASR teardown. `MeetingAssistant` deliberately has no coordinator dependency, so LLM errors and cancellation cannot mutate the realtime subtitle lifecycle.

`AppModel` retains the four native runtime owners for the lifetime of the app:

- `SubtitlePanelController`
- `MeetingAssistant`
- `AssistantPanelController`
- `GlobalShortcutManager`

`AppDelegate.applicationDidFinishLaunching` installs the saved shortcut. The default is ⌥Space. A settings change first unregisters the prior Carbon hot key, then registers the replacement; disabling it or exiting unregisters it. The shortcut opens the same retained assistant panel as the menu action.

## Lifecycle and memory clearing

- Starting a meeting clears the previous transcript, assistant draft, context, reply, error, and in-flight LLM task.
- Stopping capture enters transcript review without persisting content.
- Clearing/closing the subtitle panel cancels live work and clears both transcript and assistant memory.
- Closing the assistant panel clears assistant memory without interrupting an active meeting.
- App termination unregisters the shortcut, closes both panels, cancels assistant work, shuts down the coordinator, and clears its store.
- A selected meeting process exit triggers coordinator stop and review mode.

The subtitle panel can lock itself into mouse-passthrough mode. Because it then cannot receive clicks, the menu-bar UI exposes an external **解锁字幕窗口鼠标操作** action.

## Settings and credentials

The realtime Settings window exposes:

- Tencent Cloud ASR App ID, Secret ID, and Secret Key;
- LLM provider preset, base URL, model, API key, timeout, output limit, temperature, fixed 30-second transcript context, and memory-only system prompt;
- assistant shortcut enablement and replacement presets.

Tencent and LLM credentials use macOS Keychain accounts. The SQLite settings table stores only non-sensitive configuration and Keychain reference markers. Meeting audio, subtitles, assistant requests, and replies must never enter Settings, SQLite, files, logs, diagnostics, or crash text.

The approved preflight copy is intentionally shared by the menu and Settings:

> 所选应用音频会发送到腾讯云 ASR；只有手动提交时，最近 30 秒字幕才会发送到所配置的 LLM；内容不会保存到本地

## Build and automated verification

### Source-build prerequisites

Install Xcode Command Line Tools (or a full Xcode toolchain with Swift 5.9 or
later), then create the Python 3.11 virtual environment used to freeze the
legacy worker:

```bash
cd python-worker
python3.11 -m venv .venv
.venv/bin/python -m pip install --upgrade pip
.venv/bin/python -m pip install -e ".[dev,packaging]"
cd ..
```

`.[packaging]` supplies PyInstaller, which `build-app.sh` invokes whenever the
frozen worker is absent, forced, or older than its sources. `.[dev]` adds the
worker test tools. The script deliberately fails with these setup instructions
instead of falling back to an unrelated system `pyinstaller` executable.

```bash
cd macos-app
swift test
swift build
cd ..
git diff --check
```

`swift build` verifies compilation but does not create a permission-capable desktop app. For actual desktop checks, assemble and sign the bundle from the repository root:

```bash
./macos-app/Scripts/build-app.sh
open macos-app/.build/CallCapture.app
```

The bundle scripts ask SwiftPM for its active build directory with
`swift build --show-bin-path`; they do not assume an Apple-Silicon or Intel
output path. Check that resolution without assembling, signing, launching, or
replacing an app bundle:

```bash
bash macos-app/Scripts/smoke-swift-binary-path.sh
```

If the active Swift toolchain cannot compile (for example, its compiler and
macOS SDK versions do not match), run the static-only portion while fixing the
toolchain selection:

```bash
bash macos-app/Scripts/smoke-swift-binary-path.sh --syntax-only
```

After the first bundle exists, `./run-dev.sh` refreshes its Swift binary, re-signs it with the audio entitlement, and relaunches it. Never use `swift run` for process-tap validation.

Tests use Apple's Swift `Testing` module. If the active Command Line Tools installation reports `no such module 'Testing'`, use a matching full Xcode/SDK toolchain before treating the suite as verified. A production `swift build` is still required, together with test-source syntax parsing, focused runtime smokes for pure behavior, diff checks, and source privacy scans.

Useful privacy scans should confirm that the production realtime path contains no calls to legacy recording/session/post-processing entry points, meeting-content file writes, or content logging. Keychain-backed settings and the legacy compatibility modules are expected to reference databases or files; those are not evidence that the realtime meeting content is persisted.

## Manual macOS validation — pending

No headless build or smoke test substitutes for this checklist. Record each result on a real macOS desktop; do not claim completion until all items have been exercised:

- [ ] Tencent Meeting: select its process, start/stop, confirm remote speech appears.
- [ ] Zoom: select its process, start/stop, confirm remote speech appears.
- [ ] Feishu: select its process, start/stop, confirm remote speech appears.
- [ ] While unrelated system audio plays, confirm only the selected application is transcribed.
- [ ] Confirm the realtime flow never opens or captures a microphone.
- [ ] Exercise mixed Chinese/English speech and at least two remote speakers.
- [ ] Exercise short utterances, overlapping speech, silence, disconnect, reconnect, and retry exhaustion.
- [ ] Quit the selected meeting application and confirm capture stops into review mode.
- [ ] Exercise LLM HTTP 401, HTTP 429, timeout, cancellation, retry, and malformed stream handling; confirm live subtitles continue.
- [ ] Verify subtitle focus, dragging, resizing, opacity, type size, mouse-passthrough unlock, multiple displays, Spaces, and full-screen meeting windows.
- [ ] Deny and revoke process-audio permission and verify the UI reports a non-running error state.
- [ ] Clear the meeting and quit, then run `find ~/Library/Application\ Support/CallCapture -type f`; inspect the results and confirm no audio, subtitle, prompt, or reply file from the meeting exists.

The final filesystem check may still list the settings/session database from legacy-compatible app initialization. Inspect content and timestamps rather than assuming any file under the directory is meeting content.

## Conventions

- Follow the approved design in `docs/superpowers/specs/2026-07-20-realtime-overlay-assistant-design.md` and plan in `docs/superpowers/plans/2026-07-20-realtime-overlay-assistant.md`.
- Prefer red-green-refactor for pure behavior and lifecycle state changes.
- Keep Core Audio callbacks non-blocking and free of network, file IO, UI work, and explicit lock waits.
- Never log audio, subtitles, prompt text, replies, credentials, signatures, or signed URLs.
- Use Conventional Commits.

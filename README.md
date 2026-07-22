# CallCapture

[![CI](https://github.com/bodharma/callcapture/actions/workflows/ci.yml/badge.svg)](https://github.com/bodharma/callcapture/actions/workflows/ci.yml)
[![License: AGPL v3](https://img.shields.io/badge/License-AGPL_v3-blue.svg)](LICENSE)
[![Platform: macOS 14.2+](https://img.shields.io/badge/platform-macOS%2014.2%2B-lightgrey)](https://www.apple.com/macos/)

**A realtime meeting subtitle overlay and opt-in 30-second assistant for macOS.** Choose one running meeting app, see its remote audio as live speaker-labelled subtitles, and manually ask an OpenAI-compatible LLM for concise meeting help.

CallCapture uses a Core Audio process tap, so it captures only the application the user selects. It does not join the meeting as a bot and the realtime flow never opens the microphone.

## Realtime flow

1. Open CallCapture from the menu bar and choose the meeting application.
2. Configure Tencent Cloud realtime ASR credentials in **Settings**.
3. Start realtime subtitles. A non-activating overlay follows the ASR connection state and remains available in review mode after stopping.
4. Open the meeting assistant from the menu or with **⌥Space**. Choose an instruction, inspect or edit the selected context, then explicitly send it.
5. Clear the subtitle window, start another meeting, or quit the app to erase transcript and assistant memory.

The subtitle overlay can be resized, moved, adjusted for type size and opacity, or locked into mouse-passthrough mode. When locked, reopen the menu-bar popover and choose **解锁字幕窗口鼠标操作**.

## Features

- **Application-scoped capture** — captures one selected process rather than system-wide audio.
- **No microphone** — the realtime path never requests or mixes microphone input.
- **Live bilingual ASR** — streams 16 kHz mono PCM to Tencent Cloud's Chinese/English speaker-mode WebSocket API.
- **Speaker-labelled overlay** — shows recent confirmed and partial subtitles without taking meeting focus.
- **Review mode** — stops capture while keeping confirmed subtitles in memory for copying or assistant use.
- **Manual meeting assistant** — selects confirmed subtitles from the latest 30-second window, then lets the user edit the exact text before sending.
- **Configurable OpenAI-compatible LLM** — OpenAI, OpenRouter, DeepSeek, Ollama, and custom endpoint presets with streaming replies.
- **Global shortcut** — defaults to ⌥Space and can be replaced or disabled in Settings.

## Architecture

The production menu flow is memory-only:

```text
Selected meeting process
  → Core Audio process tap
  → bounded in-memory PCM queue
  → Tencent realtime ASR
  → LiveTranscriptStore
      ├─ floating subtitle panel
      └─ explicit 30-second assistant composition
           → configured OpenAI-compatible LLM
```

Capture, ASR, subtitles, and LLM generation have separate lifecycles. An LLM cancellation, timeout, authentication failure, rate limit, or malformed stream updates only the assistant panel; it cannot stop capture or ASR.

See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for implementation details, verification commands, and the pending desktop-validation checklist.

## Requirements

- macOS **14.2** or later
- Xcode Command Line Tools (or full Xcode) with Swift 5.9 or later
- Python **3.11** for the legacy worker bundled by the source-build script
- Tencent Cloud realtime ASR App ID, Secret ID, and Secret Key
- An API key for cloud LLM presets; keyless loopback Ollama/custom endpoints are supported

Credentials are stored in the macOS Keychain. Non-sensitive endpoint, model, timeout, and shortcut preferences are stored in the app settings database.

## Build from source

```bash
git clone https://github.com/bodharma/callcapture.git
cd callcapture

# build-app.sh still bundles the legacy post-meeting worker. On a clean clone,
# create its Python 3.11 environment and install PyInstaller first.
cd python-worker
python3.11 -m venv .venv
.venv/bin/python -m pip install --upgrade pip
.venv/bin/python -m pip install -e ".[packaging]"
cd ..

# First bundle build (includes Info.plist, signing entitlements, and the frozen worker)
./macos-app/Scripts/build-app.sh
open macos-app/.build/CallCapture.app

# After later Swift-only edits, rebuild/re-sign/relaunch the existing bundle
./run-dev.sh
```

Do not use the bare `swift run` executable for desktop validation: it is not an app bundle and does not carry the process-audio usage description or signing entitlements. The bundled app appears in the macOS menu bar; grant the process-audio capture permission requested by macOS, then select the running meeting application.

## Privacy

> 所选应用音频会发送到腾讯云 ASR；只有手动提交时，最近 30 秒字幕才会发送到所配置的 LLM；内容不会保存到本地

- Audio is held in a bounded memory queue and is not written to a recording file.
- Partial and confirmed subtitles, editable requests, and replies remain in memory only.
- The LLM receives nothing when the assistant opens or composes; network access begins only after the user clicks send.
- Starting a new meeting, clearing the subtitle window, or quitting clears transcript and assistant content.
- Logs must not contain audio, transcript text, prompts, replies, credentials, or signed request URLs.

## License

[GNU AGPL-3.0](LICENSE) © bodharma. If you run a modified version as a network service, you must release your source.

## Contributing

Issues and PRs are welcome. Start with [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for architecture, build, testing, and manual verification guidance.

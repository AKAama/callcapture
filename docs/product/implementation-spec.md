# Call Capture for macOS — Implementation Spec

**Version:** v1.1-draft
**Created:** 2026-04-18
**Updated:** 2026-04-18
**Status:** Draft — gaps from research review incorporated

---

## 1. Product Definition

**Goal:** Record and transcribe calls from FaceTime and other macOS apps, with user-selectable local or remote transcription, then output structured Markdown notes.

**Primary users:**
- Solo professionals
- Researchers/students
- Founders
- Developers
- Obsidian / PKM users

**Core user promises:**
- Works across many call apps, not just one
- Keeps audio locally by default
- Lets user choose privacy vs convenience
- Produces usable notes, not just raw text

---

## 2. Non-goals for v1

- No iPhone/iPad support
- No team collaboration
- No live bot joining calls
- No cross-device sync
- No full CRM/meeting assistant
- No App Store-first packaging
- No guaranteed diarization perfection
- No real-time translation

---

## 3. v1 Feature Set

### Must Have
- macOS menu bar app
- Start/stop recording
- Capture system output audio on macOS 14.2+ via Core Audio taps
- Optional mic capture
- Save audio file per session
- Local transcription option
- Remote transcription option
- Markdown output generation
- Session history
- Settings page
- Error and permissions diagnostics

### Should Have
- Per-app capture selection
- Auto-title sessions from app name + date/time
- Export `.md`, `.txt`, `.json`
- Obsidian vault export folder
- Basic speaker segmentation labels where possible

### Could Have
- Live partial transcript
- Hotkeys
- Apple SpeechTranscriber backend (experimental, macOS Tahoe+)

---

## 4. Architecture

### System Layers

| Layer | Tech | Responsibility |
|---|---|---|
| macOS app | Swift + SwiftUI/AppKit | Menu bar app, permissions, device/app capture, session control, local file storage |
| Capture engine | Swift | Core Audio taps, mic capture, muxing, buffering, chunk writing |
| Worker bridge | Swift + Python subprocess | Start/stop jobs, pass file paths and JSON metadata, progress streaming |
| Transcription engine | Python | Local Whisper / whisper.cpp wrapper, remote Whisper API, segmentation |
| Post-processing | Python | Speaker cleanup, LLM-powered Markdown formatting, summaries/action items |
| Storage | Local filesystem + SQLite | Sessions, settings, transcript metadata, job state |
| Export | Swift/Python | Markdown files, raw transcript, optional JSON |

### Python Worker Bundling

Python worker ships inside app bundle via PyInstaller `--onedir`:
- Location: `.app/Contents/Resources/worker/`
- Includes: frozen Python runtime, all dependencies, vendored whisper.cpp binary
- Size: ~100MB (without models)
- No user Python installation required
- Whisper models download on first use to `~/Library/Application Support/CallCapture/models/`

**Model defaults:**
| Model | Params | Size | Use Case |
|---|---|---|---|
| `base` | 80M | ~150MB | **Default** — good accuracy on call audio, fast on M1+ |
| `small` | 244M | ~500MB | User upgrade — better accuracy, still <2s/min on M3+ |
| `medium`+ | 769M+ | >1.5GB | Not recommended for call audio — diminishing returns on VoIP |

### Swift <-> Python Contract

**Channel separation:**
- **stdout** — final JSON result only (one JSON object per job)
- **stderr** — progress updates as newline-delimited JSON
- **exit codes** — `0`=success, `1`=transcribe_fail, `2`=no_model, `3`=disk_full, `4`=api_error

**Swift sends (stdin):**
```json
{
  "job_id": "uuid",
  "command": "transcribe",
  "audio_path": "/path/file.wav",
  "engine": "local_whisper",
  "language": "auto",
  "speaker_diarization": false,
  "markdown_profile": "meeting_notes",
  "whisper_model": "base",
  "llm_engine": "claude"
}
```

**Python streams on stderr:**
```json
{"job_id": "uuid", "progress": 0.45, "stage": "transcribe", "current_segment": 150}
{"job_id": "uuid", "progress": 0.90, "stage": "postprocess", "current_segment": null}
```

**Python returns on stdout:**
```json
{
  "job_id": "uuid",
  "status": "completed",
  "raw_transcript_path": "/path/raw.json",
  "markdown_path": "/path/note.md",
  "duration_sec": 812.1,
  "warnings": []
}
```

**Rules:**
- All worker responses must be machine-parseable JSON
- No plain-text logs on stdout — logs go to stderr/file
- Swift owns orchestration and retries
- Python is stateless per job in v1
- Swift reads stderr async for real-time progress updates in menu bar
- Atomic file writes: Python writes to temp file, renames on completion (prevents corrupt output on crash)

**Heartbeat protocol (jobs >5 min):**
- Swift sends `{"action": "ping"}` on stdin every 30s
- Python responds `{"pong": true}` on stderr
- No response within 30s → Swift kills process, increments retry count
- Max retries: 3, with exponential backoff

---

## 5. Functional Requirements

### Recording
- Record system/app audio to local file immediately on session start
- Optionally record microphone to separate track or mixed track
- Preserve original WAV for processing; optionally compress archival copy to M4A
- Session metadata: source app, start time, end time, duration, capture mode

### Capture Modes
- Mode A: default output capture
- Mode B: selected process/app capture
- Mode C: output + mic mixed
- Mode D: output + mic separate stems

**Core Audio Tap Safety:**
- Must verify target PID is producing audio before attaching tap — tapping silent PID causes process exit
- Check `NSAudioCaptureUsageDescription` in Info.plist + `com.apple.security.device.audio-input` entitlement
- First launch triggers system "System Audio Recording" permission prompt
- Diagnostics must detect and report tap attachment failures with recovery instructions

### Recording Format
- Processing master: 16 kHz mono WAV for ASR pipeline
- Archive master: 48 kHz AAC/M4A or original PCM WAV
- Keep conversion deterministic and logged

### Audio Preprocessing Pipeline
Before sending to Whisper:
1. **Normalize amplitude** — consistent signal level
2. **Resample** — 16 kHz, 16-bit PCM mono (Whisper training distribution)
3. **Trim silence** — remove leading/trailing dead air
4. **Chunk** — split at 30-min boundaries for long recordings
5. **Neural noise reduction** — apply Demucs only when SNR <10dB (over-processing clean audio hurts Whisper accuracy)

### Design Principle
Record first, transcribe second. Durable capture must never depend on ASR availability.

### Transcription
- Engine options:
  - **Local (default):** whisper.cpp with CoreML acceleration on Apple Silicon (3x+ speedup via Neural Engine). Python bindings via `pywhispercpp`. Default model: `base` (80M params).
  - **Remote:** Groq Whisper API (default — 9x cheaper than OpenAI, same Whisper weights, 164-299x realtime). OpenAI Whisper API as fallback. Deepgram Nova-3 for future streaming support.
  - **Experimental:** Apple SpeechTranscriber (macOS Tahoe+, feature-flagged). **Swift-only API** — transcription runs in Swift layer, results passed to Python for post-processing only. 55% faster than whisper.cpp large-v3-turbo on supported hardware.
- User can choose engine globally and per-session retry
- Retry failed transcriptions without re-recording
- Remote provider configurable in settings (`groq` | `openai` | `deepgram`)

### Markdown Processing

**Raw transcript output:**
```text
[00:00:03] Speaker 1: ...
[00:00:07] Speaker 2: ...
```

**Processed Markdown output:**
```md
# Session title

## Summary

## Key points

## Decisions

## Action items

## Transcript
- [00:00:03] Speaker 1: ...
```

**Post-processing stages:**
1. Clean transcript text
2. Restore punctuation/casing if needed
3. Merge short fragments
4. Optional speaker labeling
5. LLM formatting into deterministic Markdown schema
6. Validate Markdown output (see validation rules below)
7. Save `.md`

**LLM engine for post-processing:**
- **Default:** Claude API (Anthropic SDK) — best structured output, large context window
- **Alternative:** OpenAI GPT-4o
- **Experimental:** Local LLM (llama.cpp/MLX) — 7B models insufficient for reliable structured extraction; defer to v2
- **Cost:** ~$0.05-0.15 per 1-hour call with Claude API
- Configurable in settings: `llm_engine` = `claude` | `openai` | `local_experimental`

**Long transcript strategy (>30 min):**
- Transcripts <30 min: send full context to LLM in single pass
- Transcripts 30-120 min: hierarchical summarization — chunk at speaker turns or 10-min intervals, summarize per chunk, synthesize final note
- Transcripts >120 min: mandatory chunking + hierarchical synthesis

**Markdown prompt contract:**
- No invented facts
- Preserve uncertain text with `[unclear]` markers
- Action items only when explicitly stated in transcript
- Timestamps preserved when available
- Cross-check names/facts against raw transcript to catch hallucination
- Separate prompt templates per `markdown_profile`

**Markdown output validation (Pydantic):**
- Required sections present: Summary, Key points, Decisions, Action items, Transcript
- Action items in `- [ ]` checkbox format
- Timestamps preserved in transcript section (`[HH:MM:SS]`)
- Summary <500 characters
- No empty required sections (use "None discussed" placeholder)
- Title present and non-empty

**Output variants:**
- Concise meeting notes
- Full structured transcript
- Obsidian note template

### Obsidian Export Format

Exported notes use YAML frontmatter for Obsidian compatibility:

```yaml
---
title: "Call with X — 2026-04-18"
date: 2026-04-18T14:00:00Z
tags: [meeting, call-capture]
callapp: FaceTime
duration_min: 45
participants: [Speaker 1, Speaker 2]
engine: local_whisper
model: base
---
```

Default folder structure in vault: `_meetings/{YYYY-MM}/{title}.md`

### Session Library
- List sessions
- Search by title/text/date/app
- Open audio/transcript/Markdown
- Re-run processing with different prompt/settings

---

## 6. Speaker Diarization

Best-effort, not guaranteed in v1.

- v1: basic `Speaker 1`, `Speaker 2` where feasible, or no speaker labeling
- v1.1: add optional diarization pipeline (pyannote)
- Keep diarization off by default if it hurts latency or install size

---

## 7. Data Model

### Session
| Field | Type |
|---|---|
| id | UUID |
| title | String |
| source_app | String |
| capture_mode | Enum |
| started_at | DateTime |
| ended_at | DateTime |
| duration_sec | Float |
| audio_path | String |
| transcript_raw_path | String? |
| transcript_markdown_path | String? |
| engine_used | String? |
| status | Enum |
| error_message | String? |

### Settings
| Field | Type | Notes |
|---|---|---|
| default_engine | Enum | `local_whisper` \| `remote` |
| whisper_model | String | `base` (default), `small`, `medium` |
| remote_provider | Enum | `groq` (default) \| `openai` \| `deepgram` |
| remote_api_base | String? | Custom API endpoint |
| remote_api_key_ref | String? | Keychain reference |
| llm_engine | Enum | `claude` (default) \| `openai` \| `local_experimental` |
| llm_api_key_ref | String? | Keychain reference |
| output_directory | String | Default: `~/Library/Application Support/CallCapture/` |
| obsidian_export_directory | String? | Vault path |
| obsidian_folder_pattern | String | Default: `_meetings/{YYYY-MM}/` |
| enable_diarization | Bool | Default: false |
| auto_process_on_stop | Bool | Default: true |
| keep_separate_mic_track | Bool | Default: false |
| markdown_profile | String | `meeting_notes` \| `full_transcript` \| `obsidian` |

### Job
| Field | Type |
|---|---|
| id | UUID |
| session_id | UUID |
| type | Enum |
| status | Enum |
| started_at | DateTime |
| ended_at | DateTime? |
| attempt_count | Int |
| warnings_json | String? |

---

## 8. UX Requirements

### Menu Bar States
- Idle
- Recording
- Transcribing
- Error

### Main Screens
- Session list
- Session detail
- Settings
- Diagnostics

### Diagnostics Page
- macOS version
- Chip type
- Permission states
- Available audio devices
- Tap API support check
- Python worker health
- Local model availability
- Last error logs

---

## 9. Technical Requirements

### Swift App
- SwiftUI for most UI
- AppKit bridging for menu bar, permissions, audio integration
- Target macOS 14.2 minimum
- SQLite via GRDB or similar
- Unified logging with OSLog

### Python Worker
- Python 3.11+
- Bundled via PyInstaller `--onedir` inside `.app/Contents/Resources/worker/`
- Structured CLI: `transcribe`, `postprocess`, `export`
- JSON stdin/stdout contract + stderr progress streaming
- `pywhispercpp` for local whisper.cpp bindings
- `anthropic` SDK for Claude LLM post-processing
- `openai`-compatible client for remote transcription (Groq/OpenAI)
- `pydantic` for job schemas + Markdown output validation

### Repository Structure
```text
call-capture-macos/
  macos-app/
    CallCapture.xcodeproj
    Sources/
      App/
      UI/
      Capture/
      Session/
      Settings/
      Diagnostics/
      Bridge/
      Persistence/
  python-worker/
    app/
      cli.py
      transcribe/
      postprocess/
      export/
      schemas/
      utils/
    tests/
    pyproject.toml
  docs/
    architecture/
    product/
    prompts/
```

### Storage Structure
```text
~/Library/Application Support/CallCapture/
  audio/
  transcripts/raw/
  transcripts/markdown/
  exports/
  logs/
  models/              # Whisper models downloaded on first use
    ggml-base.bin
    ggml-small.bin
  prompts/             # Markdown profile prompt templates
    meeting_notes.txt
    full_transcript.txt
    obsidian.txt
  callcapture.db
```

---

## 10. Permissions and Distribution

### Required Entitlements
- `com.apple.security.device.audio-input` — microphone + system audio capture
- `NSAudioCaptureUsageDescription` in Info.plist — user-facing permission description

### Permission Flow
1. First launch: system prompts for "System Audio Recording" permission
2. App checks permission status on each launch
3. If denied: show diagnostics with instructions to grant in System Settings
4. Diagnostics page shows all permission states

### Distribution
- Outside-App-Store distribution with Developer ID signing + notarization
- Hardened runtime required for notarization
- Plan for: code signing, notarization CI, entitlement audit
- Sandboxed apps CAN use Core Audio taps with proper entitlement

### macOS Version Notes
- **14.2**: Core Audio taps introduced — minimum supported
- **14.4**: Refined API (`AudioHardwareCreateProcessTap`)
- **15 (Sequoia)**: Had low sample rate regression (fixed in later updates)
- **26 (Tahoe)**: Removed low-pass filter on taps (quality improvement), audio bugs in 26.0 fixed in 26.1+

---

## 11. Engineering Milestones

### Milestone 0: Technical Spike
**Goal:** Prove end-to-end feasibility

**Deliverables:**
- Swift prototype captures default output audio to WAV
- Python script transcribes sample WAV locally
- Swift launches Python worker successfully
- Markdown file generated from transcript

**Exit criteria:**
- FaceTime or browser-call audio captured on one test Mac
- One successful local transcript
- One successful remote transcript

### Milestone 1: Capture Foundation
**Deliverables:**
- Menu bar app
- Session lifecycle
- Audio file persistence
- Diagnostics screen
- Error logging

**Exit criteria:**
- Stable 30-minute capture
- No data loss on app close/crash
- Resume-safe session metadata

### Milestone 2: ASR Integration
**Deliverables:**
- Local backend
- Remote backend
- Engine setting selector
- Retry logic
- Progress UI

**Exit criteria:**
- Same recording transcribed by both engines
- Failures surface meaningful recovery steps

### Milestone 3: Markdown Intelligence
**Deliverables:**
- Structured Markdown profiles
- Raw + processed transcript views
- Export pipeline
- Obsidian export folder support

**Exit criteria:**
- Session note readable without manual cleanup
- Markdown output stable across 20+ recordings

### Milestone 4: Beta Hardening
**Deliverables:**
- Packaging
- Signing/notarization
- Crash handling
- Performance tuning
- Compatibility matrix

**Exit criteria:**
- 5 external beta users
- Tested on Apple Silicon (and Intel if supported)
- Installation works on clean machine

---

## 12. Priority Backlog

### P0
- Capture pipeline works
- Session persistence
- Local transcription
- Remote transcription
- Markdown generation
- Diagnostics and logs

### P1
- Per-app capture
- Searchable history
- Export variants
- Hotkeys
- Auto-start/stop rules

### P2
- Diarization
- Real-time partial transcript
- Apple native STT backend
- Summaries by template
- Calendar-linked note titles

---

## 13. Risks and Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Core Audio tap edge cases | Capture may fail on some setups | Diagnostics, OS gating, fallback modes, verbose logs |
| Tapping silent PID causes crash | Process exit when target app not producing audio | Verify audio activity before attaching tap, graceful recovery |
| macOS version fragmentation | Tap API requires 14.2+; Tahoe had audio bugs | Set minimum OS to 14.2, test matrix across versions |
| Local model performance | Large models slow on some Macs | Default to `base` model (80M), allow user upgrade to `small` |
| Diarization complexity | Heavy deps, lower reliability | Make optional, defer to v1.1 |
| Packaging Python | Shipping Python adds complexity | PyInstaller `--onedir` bundle inside .app, ~100MB |
| Permissions confusion | Users may not understand failures | Onboarding flow + diagnostics + fix instructions |
| App Store restrictions | Could block release | Start with direct distribution + notarization |
| LLM API dependency | Post-processing fails if API down | Queue failed jobs for retry, show raw transcript as fallback |
| LLM hallucination in notes | Invented facts in meeting notes | Cross-check against raw transcript, strict prompt contract |
| Long transcript cost | >1hr calls cost more with LLM API | Hierarchical summarization reduces tokens, show cost estimate |

---

## 14. v1 Acceptance Criteria

Release candidate ready when ALL true:
- [ ] Records 15-minute FaceTime or browser call, saves audio reliably
- [ ] Produces transcript from local engine (whisper.cpp + base model)
- [ ] Produces transcript from remote engine (Groq or OpenAI)
- [ ] Exports valid Markdown note with all required sections
- [ ] Markdown output passes Pydantic validation
- [ ] Session remains accessible after app restart
- [ ] Progress updates visible in menu bar during transcription
- [ ] Worker crash during transcription triggers retry, not data loss
- [ ] User can understand why failed capture/transcription failed
- [ ] Diagnostics page shows all permission states + system info
- [ ] Install/build docs work on clean machine (no manual Python install)
- [ ] Obsidian export produces valid frontmatter + note in configured vault

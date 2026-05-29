# Development Guide

Architecture, build, and test workflows for CallCapture. For the product overview see the [root README](../README.md).

## Repository layout

```
callcapture/
├── macos-app/            # Swift menu-bar app (SwiftUI + Core Audio + GRDB)
│   ├── Sources/
│   │   ├── App/          # App entry, AppModel, lifecycle
│   │   ├── Capture/      # Core Audio process-tap capture, stem writers
│   │   ├── Bridge/       # PythonBridge: spawns worker, JobRequest/JobResult
│   │   ├── Session/      # Session model, SessionManager (GRDB), migrations
│   │   ├── Settings/     # SettingsManager, Keychain, enums
│   │   └── UI/           # SessionListView, SessionDetailView, insights
│   ├── Tests/            # XCTest (logic/model tests)
│   ├── Scripts/          # build-app.sh, sign-app.sh, entitlements
│   └── Package.swift     # SPM: GRDB, FluidAudio
├── python-worker/        # Transcription + analysis pipeline
│   └── app/
│       ├── cli.py        # Click CLI; `transcribe` reads JobRequest on stdin
│       ├── transcribe/   # engine (local Whisper) + remote_engine (AssemblyAI/Deepgram/OpenAI)
│       ├── analyze/      # diarization load, attribution, metrics, sentiment, emotion, insights
│       ├── postprocess/  # llm_client, formatter, markdown rendering, pricing
│       ├── export/       # markdown + raw transcript writers
│       └── schemas/      # Pydantic models (JobRequest, JobResult, TranscriptSegment, ...)
├── docs/                 # design specs & implementation plans
└── run-dev.sh            # build Swift → bundle → launch in dev mode
```

## Data flow

```
User records → Capture (Core Audio process tap)
   writes <id>.wav, and when a mic is selected also <id>_mic.wav + <id>_system.wav
        │
        ▼
On-device diarization (FluidAudio) → <id>_system_diarization.json  (speaker turns)
        │
PythonBridge spawns:  python3 -m app.cli transcribe   (JobRequest as JSON on stdin)
        │
   Worker pipeline (app/cli.py _run_pipeline):
     1. transcribe stems (mic = "You", system = remote) or the single mix
     2. attribute system segments to speakers via the diarization sidecar
     3. analyze: sentiment, acoustic emotion, insights (LLM)
     4. render Markdown note + write <id>_transcript.json / <id>_notes.md
        │
   ProgressUpdate (stderr) + JobResult (stdout, JSON)
        ▼
SessionManager persists paths/status to the GRDB session database
        ▼
SessionListView / SessionDetailView render
```

The worker is **stateless per job**: all configuration arrives in the `JobRequest`
(engine, language, notes language, remote provider, model, etc.). The app is the
source of truth for settings and the session database.

## Prerequisites

- macOS 14.2+ (Apple Silicon recommended)
- Xcode command-line tools / Swift 5.9+
- Python 3.11+

## Python worker

```bash
cd python-worker
python3 -m venv .venv && source .venv/bin/activate
pip install -e ".[dev]"

# Run the test suite (pytest, with coverage per pyproject.toml)
pytest

# Invoke the CLI directly (JobRequest JSON on stdin)
echo '{"job_id":"x","command":"transcribe","audio_path":"/path/to.wav","engine":"local_whisper"}' \
  | python -m app.cli transcribe
```

Key worker modules:

- `transcribe/remote_engine.py` — cloud STT. AssemblyAI uses the `speech_models`
  priority list (`universal-3-pro` → `universal-2`); Deepgram uses Nova-3.
- `analyze/attribution.py` — merges mic ("You") + system segments using the
  diarization turns; falls back gracefully when stems/turns are absent.
- `postprocess/llm_client.py` — OpenAI-compatible client (OpenRouter or local).

## macOS app

```bash
cd macos-app
swift build                 # compile
swift test                  # run XCTest suite

# Or build + bundle + launch the whole thing in dev mode from repo root:
./run-dev.sh
```

`run-dev.sh` builds the Swift binary, copies it into `CallCapture.app`, kills any
running instance, and launches with:

- `CALLCAPTURE_DEV_MODE=1`
- `CALLCAPTURE_WORKER_DIR=<repo>/python-worker` — so the app runs your live
  worker code (no reinstall needed for Python changes).

### Database

Sessions/jobs/settings live in a GRDB SQLite database at
`~/Library/Application Support/CallCapture/callcapture.db`. Schema changes are
applied via numbered migrations (see `Sources/Session/`); add a new migration
rather than mutating an existing one. Migration tests live in
`Tests/CallCaptureTests/DatabaseMigrationTests.swift`.

## Testing conventions

- **Python:** `pytest` under `python-worker/`. Pure functions (parsing, routing,
  attribution, pricing) are unit-tested; cloud HTTP flows are tested at the
  response-mapping layer. Prefer TDD — write the failing test first.
- **Swift:** XCTest under `macos-app/Tests/`. Logic and model behavior
  (migrations, routing, parsing, formatting) are covered; SwiftUI view-lifecycle
  behavior is verified manually (no ViewInspector/snapshot harness).
- Some Python tests need `numpy`/`openai` installed — run them inside the
  worker's `.venv`, not a bare system Python.

## Design docs

`docs/superpowers/specs/` holds design specs and `docs/superpowers/plans/` holds
the phased implementation plans the project was built from. New features follow
the same flow: spec → plan → TDD implementation.

## Conventions

- Conventional Commits (`feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `chore:`).
- Small, focused files; immutable data where practical.
- Never commit secrets — API keys go in the macOS Keychain. Recordings and the
  session DB are git-ignored.

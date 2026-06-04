# Pending Work

Open threads / parked items. Last updated 2026-06-04.

## Features

### Live transcript (next up — spec done, needs plan)
- **Status:** design **approved**, no implementation plan yet.
- **Spec:** [`docs/superpowers/specs/2026-06-01-live-transcript-design.md`](superpowers/specs/2026-06-01-live-transcript-design.md)
- **Gist:** optional real-time transcript via **AssemblyAI streaming** of the **system audio**, toggle per call (default in Settings). **Preview only** — batch pipeline stays authoritative. Live is **best-effort + fully isolated** (a stream failure must never affect capture/batch). Streaming cost (`live_minutes × rate`, editable in Pricing) is added to the session's transcription cost.
- **Resume:** review the spec → run `superpowers:writing-plans` → subagent-driven implementation. New Swift: `LiveTranscriber` (WebSocket), `LiveTranscriptView`; tee 16 kHz mono system buffers from `AudioCaptureManager`'s IO proc; Settings toggle + streaming rate; guards (AssemblyAI key present, language ∈ en/es/de/fr/pt/it).

## Bugs / cleanups

### Re-process hardcodes `local_whisper`
- `SessionDetailView.transcribeButton` (Re-process / Retry) passes `engine: "local_whisper"` regardless of the session's original engine. So re-processing a remote session uses local Whisper → wrong quality **and** `$0.00` transcription cost.
- **Fix:** reuse the session's original engine (persist/derive it) on re-process.

### Cost: OpenAI/Groq STT rates not exercised by `.auto`
- The `.auto` provider router only picks AssemblyAI/Deepgram, so the editable OpenAI/Groq `$/min` rates only matter if the user explicitly selects those providers. By design; noted so it isn't "fixed" by mistake.

## Ideas (not committed to)
- **Speaker identity** (biggest product gap): calendar (EventKit) attendee names → map `Speaker N → Name`; manual speaker rename in the detail view; voiceprint enrollment for auto-naming. See [`memory: fathom-attribution-analysis`].
- Audio playback synced to transcript (click a line → jump); full-text search across sessions; export to Notion/Slack/Reminders; cost spend dashboard + budget alerts.

## Recently shipped (for context)
- v0.2.1 — **notarized** brew release + **per-session cost tracking** (merged to main).
- `run-dev.sh` re-signs the bundle after copying the binary (fixed "failed to create audiotap" — the dev bundle was losing its `audio-input` entitlement). The intermittent second-recording failure resolved with the properly-entitled build.
- Release CI (`.github/workflows/release.yml`) is **enabled**; tagged releases auto build → sign → notarize → upload (cask bump runs only if `HOMEBREW_TAP_TOKEN` is set — currently bumped manually).
- Signing material lives in `signing/` (git-ignored) with a `README.txt` index.

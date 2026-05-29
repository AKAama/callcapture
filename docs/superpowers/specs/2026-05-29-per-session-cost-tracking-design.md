# Per-Session Cost Tracking — Design

**Date:** 2026-05-29
**Status:** Approved (design), pending implementation plan
**Scope:** Show the dollar cost of transcription and LLM processing for each recorded session, with user-editable rates.

---

## 1. Goal

Each session should display what it cost to produce:

- **Transcription cost** — the speech-to-text API spend.
- **Processing cost** — the LLM post-processing spend (sentiment, insights, markdown notes).
- **Total** — the sum, in USD.

Rates are **editable in a Settings UI**. The app ships with sensible defaults so it works out of the box. Costs are computed for **new sessions only** (no backfill).

---

## 2. Cost Model

```
transcription_cost = audio_minutes × stt_rate_per_min[provider] × stems_transcribed
processing_cost    = Σ over LLM calls ( actual_cost  ||  tokens × llm_fallback_rate )
total              = transcription_cost + processing_cost           (USD)
```

Key facts driving the model:

- **Stems double transcription.** When a mic is selected, the worker transcribes BOTH `_mic.wav` and `_system.wav` (`_transcribe_and_attribute` in `app/cli.py`). Each is full-length, so a remote provider bills ~2× the audio minutes. The calc multiplies by the number of stems actually sent (1 for the single-file path, 2 for the stem path).
- **Local engines are free.** `local_whisper` rate = `$0.00`. `llm_engine = local_experimental` → processing cost `$0.00`.
- **OpenRouter reports actual cost.** The LLM path is OpenAI-compatible (`chat.completions.create`); OpenRouter returns real spend in the usage payload. Use it directly when present; fall back to `tokens × llm_fallback_rate_per_1m` only when it is absent (e.g. a local server).
- **Precision/currency.** USD, displayed to 4 decimals (sub-cent calls are common), e.g. `$0.0123`. Values rounded for display only; raw values stored full-precision.

---

## 3. Rates: defaults in code, authoritative values in Settings

### Defaults — `app/postprocess/pricing.py` (new)

```python
# USD. Approximate public rates verified 2026-05-29 — VERIFY before relying on them.
# Sources: assemblyai.com, deepgram.com pricing pages.
DEFAULT_STT_RATE_PER_MIN = {
    "assemblyai": 0.0035,   # Universal-3 Pro ~$0.21/hr
    "deepgram":   0.0043,   # Nova-3 pre-recorded
    "openai":     0.0060,   # whisper-1
    "groq":       0.0007,   # whisper distil
    "local_whisper": 0.0,   # on-device, free
}
DEFAULT_LLM_FALLBACK_RATE_PER_1M = 3.00  # blended $/1M tokens, fallback only
```

`pricing.py` exposes pure, unit-tested functions:

```python
def transcription_cost(minutes: float, provider: str, stems: int, rates: dict) -> float
def processing_cost(actual_cost: float | None, tokens: int, fallback_rate_per_1m: float) -> float
```

`rates` merges Settings overrides over the defaults, so a missing/blank override falls back to the shipped default and never breaks.

### Authoritative values — Settings (`settings` k/v table)

Rates are persisted in the existing `settings` table (same mechanism as `remote_provider`, `whisper_model`) and surfaced in a new **Pricing** section of `SettingsView`:

```
Pricing (USD)
  Transcription $/min
    AssemblyAI      [0.0035]
    Deepgram        [0.0043]
    OpenAI          [0.0060]
    Groq            [0.0007]
    Local Whisper    $0.00     (fixed, not editable)
  Processing
    LLM fallback $/1M tokens   [3.00]
    └ note: OpenRouter reports actual cost; this rate is used only when it can't.
  [Reset to defaults]
```

- `SettingsManager` gains rate fields, persisted via the existing `persist(key, value)` `didSet` pattern, seeded from the defaults on first run.
- "Reset to defaults" rewrites the fields to the shipped default values.
- Input validation: non-negative decimals; blank reverts to default.

---

## 4. Data Flow

```
Settings UI (rates)
   │ persisted in settings table
   ▼
Swift builds JobRequest  ── injects rate dict + fallback ──►  Worker
   │                                                            │
   │                                                  pipeline computes:
   │                                                  - audio_minutes
   │                                                  - llm_tokens, llm actual cost
   │                                                  - transcription_cost
   │                                                  - processing_cost
   │                                                            │
   ◄──────────── JobResult (JSON stdout) with cost fields ──────┘
   │
Swift persists → session row (migration v5)
   │
   ▼
UI: SessionDetailView breakdown  +  session-list total badge
```

### JobRequest (worker input) — new fields

```python
stt_rates_per_min: dict[str, float] = {}    # from Settings; merged over defaults
llm_fallback_rate_per_1m: float | None = None
```

### JobResult (worker output) — new fields

```python
cost_transcription: float | None = None      # USD
cost_processing: float | None = None          # USD
cost_currency: str = "USD"
audio_minutes: float | None = None            # raw usage, for transparency / recompute
llm_tokens: int | None = None                  # raw usage
```

Raw usage (`audio_minutes`, `llm_tokens`) is stored so a wrong rate can be recomputed later without re-running the pipeline. (Stored in JobResult → optionally persisted; see §6 note.)

---

## 5. Worker Changes (Python)

1. **`app/postprocess/pricing.py`** (new) — default rate table + pure cost functions. Fully unit-tested (stem doubling, local = $0, fallback vs actual, currency).
2. **`app/postprocess/llm_client.py`** — `complete_json` currently discards `resp.usage`. Capture token usage and OpenRouter-reported cost. Mechanism (shared client accumulator vs returning usage) decided in the implementation plan; requirement: the pipeline can read **total** tokens and total actual cost across all three post-processing calls.
3. **`app/transcribe/engine.py` / `remote_engine.py`** — surface which provider was used and the billable minutes per call (so the single-file vs stem path reports the right stem count and provider).
4. **`app/cli.py` `_run_pipeline`** — after transcription + post-processing, compute `cost_transcription` and `cost_processing` from `pricing.py` using the request's merged rates, attach to `JobResult` along with raw usage.
5. **`app/schemas/models.py`** — add the JobRequest and JobResult fields above.

---

## 6. Swift Changes

1. **Migration v5** — add nullable columns to `session`:
   `cost_transcription REAL, cost_processing REAL, cost_currency TEXT`.
   (Raw usage `audio_minutes`/`llm_tokens` are returned by the worker; persist them too only if cheap — otherwise display-time values come from the two cost columns. Decision deferred to the plan; default is to persist the two cost columns + currency.)
2. **`SettingsManager`** — rate fields (4 STT + 1 LLM fallback), persisted, seeded with defaults, with a reset action.
3. **`SettingsView`** — new Pricing section per the mockup in §3.
4. **`Models.swift`** — JobRequest builder injects `stt_rates_per_min` + `llm_fallback_rate_per_1m` from settings; JobResult decoder reads the new cost fields.
5. **`SessionManager` / `Session`** — persist cost fields from JobResult to the session row.
6. **`SessionDetailView`** — cost breakdown row: `Transcription $X · Processing $Y · Total $Z`.
7. **Session list row** — small total badge (`$Z`). Sessions without cost (old / local-only $0) render `—` or `$0.00` respectively.

---

## 7. Testing

**Python (pytest):**
- `pricing.py`: stem doubling (1 vs 2), local provider = $0, actual-cost-present path, fallback-rate path, zero/empty rates, currency string.
- `llm_client`: usage extraction when OpenRouter cost present; fallback to token count when absent.
- `_run_pipeline`: JobResult carries correct cost fields for (a) remote stems, (b) single file, (c) local engine = $0.
- JobRequest: rate dict round-trips, missing keys fall back to defaults.

**Swift:**
- Migration v5 applies cleanly on an existing DB; columns nullable.
- SettingsManager: rate persistence round-trip; reset-to-defaults restores shipped values; blank input reverts to default.
- JobRequest encodes rate fields; JobResult decodes cost fields.
- Cost formatting ($0.0123, `—` for null).

---

## 8. YAGNI / Out of Scope

- No multi-currency conversion (USD only).
- No backfill of historical sessions.
- No per-model LLM rate matrix (single blended fallback; actual cost covers the real case).
- No cost charts / aggregate spend dashboards.
- No alerting/budgets.

---

## 9. Open Decisions Resolved

- **Rates editable in Settings UI** (defaults live in `pricing.py`, overrides in `settings` table, flow via JobRequest). ✅
- **Hybrid accuracy**: LLM actual cost from OpenRouter, transcription computed from rate × minutes. ✅
- **Display**: SessionDetailView breakdown + session-list total badge. ✅
- **New sessions only** (no backfill). ✅
- **Raw usage stored** for later recompute. ✅

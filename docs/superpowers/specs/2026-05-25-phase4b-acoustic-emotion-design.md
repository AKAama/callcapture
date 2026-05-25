# Voice Intelligence — Phase 4b: Acoustic Emotion (Design)

**Date:** 2026-05-25
**Status:** Approved (pending written-spec review)
**Master spec:** `docs/superpowers/specs/2026-05-23-voice-intelligence-design.md` (§4.4, §6, §7)
**Builds on:** Phase 3a (attributed segments + `ConversationAnalysis`), 3b (real speaker labels + stems), 4a (LLM sentiment + the `analyze_sentiment(emotion=…)` seam). All merged to `main`.

---

## 1. Goal

Add **local acoustic emotion** to the worker: a wav2vec2 dimensional speech-emotion model
(audeering MSP-dim, ONNX) over each speaker's audio spans yields per-speaker
**valence/arousal** and a **dominant emotion** label; a windowed pass over the recording
yields an **emotional arc**. The per-speaker emotion is fed into the Phase 4a sentiment
LLM pass so text sentiment is **reconciled with vocal tone**. The heavy model downloads
**on demand**, gated by an explicit Settings action (mirroring Phase 3b), and everything
degrades gracefully when the model isn't present.

## 2. Decisions (from brainstorming)

- **Engine:** Python + `onnxruntime` via the audeering **`audonnx`** stack (no PyTorch).
- **Model:** `audeering/wav2vec2-large-robust-12-ft-emotion-msp-dim` (Zenodo zip
  `w2v2-L-robust-12.6bc4a7fd-1.1.0`, doi:10.5281/zenodo.6221127). CC BY-NC-SA
  (non-commercial — fine for personal use). Output `logits = [arousal, dominance,
  valence]`, ~0..1; input raw 16 kHz mono float32.
- **Download/consent:** a new worker `prepare_emotion` command, triggered by a Settings
  "Download emotion model" button via `PythonBridge`; on success Swift persists
  `emotionModelsReady`. The analysis gates on the **model existing on disk** (the worker
  checks the cache dir directly, like FluidAudio); the download never happens inside a
  normal transcribe job.
- **Slicing/perf:** per-segment inference with caps (skip segments < 0.5 s, clip each to
  ≤ 30 s, cap total inferred audio per speaker to ≤ ~300 s by taking longest segments
  first); per-speaker = duration-weighted mean. Emotion noticeably slows processing when
  enabled — accepted (it's opt-in via download).
- **dominant_emotion:** quadrant mapping of (valence, arousal).
- **Arc:** windowed valence over the **mixed `<id>.wav`** timeline → `[{t, score}]`;
  `Sentiment.arc` is widened from the 4a `list[float]` placeholder to `list[ArcPoint]`.
- **Reconciliation:** per-speaker emotion summary injected into the sentiment prompt.
- **dominance** is computed by the model but **not stored** (spec lists only
  valence/arousal/dominant_emotion). YAGNI.

## 3. Dependencies (worker)

Add to `python-worker/pyproject.toml`: `audonnx`, `audeer`, `audiofile`, `onnxruntime`,
`numpy`. These bring `audresample`/`audobject` (audeering stack) — no PyTorch. They must
be installed into the venv. (`import` of these is confined to `app/analyze/emotion.py`
and the prepare command so the rest of the worker stays importable without them where
practical; see §10 on test isolation.)

## 4. Model download & on-disk gating

- **Cache dir:** `~/Library/Application Support/CallCapture/models/emotion-msp-dim/`
  (the worker derives it from the home dir; both `prepare_emotion` and analysis use the
  same path). A module helper `emotion_model_dir()` returns it; `is_emotion_model_ready()`
  checks the extracted model is present.
- **`prepare_emotion` worker command:** reads a `JobRequest` from stdin (audio_path
  unused), downloads the Zenodo zip via `audeer` into a temp cache, extracts to the model
  dir, reports progress on stderr (`ProgressUpdate`), and returns
  `JobResult{status:"completed"}` (or `"error"` with a message). Idempotent: if the model
  dir already looks complete, it returns immediately. `JobRequest.command` gains
  `"prepare_emotion"` (Literal) on both the Python and Swift sides.
- **Swift Settings:** a new row (modeled on Phase 3b's `DiarizationModelsRow`) with a
  "Download emotion model" button that builds a `JobRequest(command: .prepareEmotion)`
  and runs it via `pythonBridge.runJob`, showing progress and Ready/Failed; on success
  sets `settingsManager.emotionModelsReady = true` (a persisted bool mirroring
  `diarizationModelsReady`). Status: Not downloaded / Downloading… / Ready / Failed.
- **Gating:** the analysis runs emotion iff `is_emotion_model_ready()` is true on disk.
  The Swift flag is consent/UI state; the worker is the source of truth via the disk
  check (so a present model works even across reinstalls, and a deleted cache degrades).

## 5. SER inference + per-speaker aggregation

`app/analyze/emotion.py`:
- An internal value `@dataclass(frozen=True) class SpeakerEmotion { valence: float;
  arousal: float; dominant_emotion: str }` (NOT a serialized schema — its scalars are
  merged into `SpeakerStats`).
- A thin seam `predict_vad(signal: np.ndarray, sampling_rate: int) -> tuple[float, float,
  float]` returning `(valence, arousal, dominance)`. **Ordering note (correctness):** the
  audonnx model emits `logits = [arousal, dominance, valence]`; `predict_vad` reorders to
  `(valence, arousal, dominance)`. The model is loaded once and cached at module level.
  This function is the unit-test seam (mocked).
- `compute_speaker_emotion(segments, audio_path) -> dict[str, SpeakerEmotion]`: derives
  the stem paths from the mixed `audio_path` (`base = splitext(audio_path)[0]` →
  `f"{base}_mic.wav"`, `f"{base}_system.wav"`); for each attributed segment, reads its
  `[start, end]` span from the speaker's stem (`You` → `_mic.wav`; remote labels →
  `_system.wav`; if that stem is absent, fall back to the mixed `audio_path`) as 16 kHz
  mono float32 via `audiofile`, applies the caps (§2), calls `predict_vad`, and
  accumulates a duration-weighted mean of valence/arousal per speaker. Returns
  `{speaker_label -> SpeakerEmotion}` with `dominant_emotion` from §6.
- Audio reading + span slicing is a small pure helper (`slice_signal(signal, sr, start,
  end, max_sec)`) — unit-testable with a synthetic array, no model.

## 6. dominant_emotion mapping

Pure `dominant_emotion(valence: float, arousal: float) -> str` with model outputs ~0..1
(0.5 ≈ neutral). Thresholds (low < 0.45, high > 0.55):
- high valence + high arousal → `"excited"`
- high valence + low arousal → `"content"`
- low valence + high arousal → `"frustrated"`
- low valence + low arousal → `"sad"`
- otherwise → `"neutral"`

## 7. Emotional arc

`compute_arc(mixed_audio_path, window_sec=20.0, max_windows=120) -> list[ArcPoint]`: read
the mixed `<id>.wav`, step fixed `window_sec` windows over the timeline (cap at
`max_windows`; for longer recordings, widen the effective step so the whole timeline is
still covered by ≤ `max_windows` windows), run `predict_vad` per window, emit
`ArcPoint(t=window_center, score=2*valence-1)` (valence centered to [-1, 1]). Empty when
no model / read failure.

## 8. Schema (`app/schemas/models.py`)

- `SpeakerStats` gains: `dominant_emotion: str | None = None`, `valence: float | None =
  None`, `arousal: float | None = None`.
- New `ArcPoint(BaseModel, frozen=True){ t: float; score: float }`.
- `Sentiment.arc`: change type from `list[float]` (4a placeholder) to
  `list[ArcPoint] = Field(default_factory=list)`. Safe — 4a always wrote `[]`.

## 9. Reconciliation (`app/analyze/sentiment.py`)

`analyze_sentiment(segments, *, emotion=None)` already accepts `emotion`. 4b passes a
`dict[str, SpeakerEmotion]` (or a compact summary). When present, the prompt gains an
**acoustic-tone** block, e.g. "Vocal tone (acoustic): You sounded content (valence 0.70,
arousal 0.48); Speaker 1 sounded frustrated (valence 0.30, arousal 0.72). Reconcile the
text sentiment with this tone." When `emotion` is None/empty, behavior is identical to
4a. The neutral-fallback paths are unchanged.

## 10. Pipeline wiring & degradation (`app/cli.py`)

In `_run_pipeline`, after speaker stats and before/around `analyze_sentiment`:
1. If `is_emotion_model_ready()`: `emotion = compute_speaker_emotion(segments, …)` and
   `arc = compute_arc(mixed_path)`; merge each speaker's `valence/arousal/dominant_emotion`
   into its `SpeakerStats`; else `emotion = {}`, `arc = []`.
2. `sentiment = analyze_sentiment(segments, emotion=emotion or None)`; then attach the
   arc to the frozen result via `sentiment = sentiment.model_copy(update={"arc": arc})`
   (guard for `sentiment is None` — empty transcript — in which case skip).
3. `_write_analysis` writes the emotion-enriched `SpeakerStats` + `sentiment` (with arc).
- Any SER/read/model error → log on stderr, skip emotion (fields `None`, arc `[]`),
  sentiment runs without tone. Never fails the job.

## 11. Testing

Unit (venv pytest, ≥80% on new modules), **SER inference mocked** (patch `predict_vad`)
— no model download, no real audio decode:
- `dominant_emotion` quadrant mapping (all five regions + boundaries).
- `compute_speaker_emotion` duration-weighted aggregation across multiple segments per
  speaker, with `predict_vad` mocked; caps (skip < 0.5 s, clip > 30 s) honored.
- `slice_signal` pure helper on a synthetic numpy array (offsets, clamping, max length).
- `compute_arc` windowing on a synthetic signal with `predict_vad` mocked (window count,
  `t`/`score` mapping, centering).
- Reconciliation prompt: the acoustic-tone block appears when emotion is passed and is
  absent otherwise (mock the LLM client; assert on the constructed user/system text).
- Gating: model dir absent → pipeline skips emotion, `SpeakerStats` emotion fields `None`,
  `arc == []`, sentiment still computed.
- Schema: `SpeakerStats` with emotion fields, `ArcPoint`, widened `Sentiment.arc`
  round-trip.
- `prepare_emotion` command: with `audeer` download/extract mocked, it writes to the
  model dir and returns `completed`; idempotent when already present.

The **real audonnx model + audio decode** path is **human-verified** (needs the ~1 GB
download). Swift Settings UI + the `prepare_emotion` round-trip are build-verified +
human-verified.

## 12. Out of scope

- Per-type insight prompts + per-type note shapes (Phase 5 — which also folds emotion
  into the per-type notes; 4b only enriches `analysis.json` + the existing minimal
  Sentiment section via reconciled sentiment).
- Session Detail "Conversation Insights" UI (Phase 6).
- Storing `dominance`; live/streaming emotion.

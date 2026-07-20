# Real-Time Meeting Overlay Assistant Design

**Date:** 2026-07-20  
**Status:** Approved for planning

## 1. Purpose

Build a macOS-only meeting companion that captures audio from one user-selected
meeting application, transcribes other participants in real time, distinguishes
remote speakers with generic labels, and displays the conversation in a native
floating overlay. The user can manually invoke an LLM assistant using only the
most recent 30 seconds of confirmed transcript to get ideas or a concise answer
they can use during the meeting.

The first version is a real-time aid, not a meeting recorder or post-meeting
analysis product.

## 2. Product Scope

### In scope

- macOS 14.2 or later.
- User selection of one currently running meeting application.
- Capture only the selected application's output audio.
- Do not capture or transcribe microphone audio.
- Real-time Chinese and English mixed-language transcription.
- Real-time generic speaker separation, such as `Speaker 1` and `Speaker 2`.
- A native, frameless, always-on-top subtitle overlay.
- Transcript held only in memory during and immediately after a meeting.
- Copying the full in-memory transcript after capture stops.
- Clearing all transcript and assistant content when the overlay closes or a
  new meeting starts.
- A manually triggered LLM assistant using the most recent 30 seconds of
  confirmed transcript.
- Configurable OpenAI-compatible LLM endpoints and models.

### Out of scope

- Capturing or displaying the local user's microphone speech.
- Persisting recordings, transcripts, meeting history, or LLM responses.
- Meeting summaries, action items, sentiment, emotion, or post-processing.
- Batch retranscription after the meeting.
- Identifying speakers by real name or voiceprint.
- Windows or Linux support.
- Automatic detection of questions or automatic LLM invocation.
- Native Anthropic, Gemini, or other non-OpenAI-compatible protocols.

## 3. Recommended Foundation

Implement the feature by adapting CallCapture rather than starting a Tauri
application. Reuse its macOS process-audio capture, application selection,
permissions, settings, signing, and packaging foundations. Remove or leave
disabled the Python worker, persistent session database, batch transcription,
recording export, and analysis UI for this product mode.

Use Swift and SwiftUI for the application and AppKit `NSPanel` for the floating
overlay. This avoids a WebView, preserves native macOS focus behavior, and does
not introduce Rust or cross-platform abstractions that the first version does
not need.

## 4. Architecture

```text
Selected meeting application
        |
        v
Core Audio process tap
        |
        v
Audio converter and bounded buffer
(16 kHz, mono, signed PCM 16-bit)
        |
        v
LiveTranscriber protocol
        |
        +--> TencentLiveTranscriber (initial implementation)
        |       WebSocket + zh/en speaker-separation model
        |
        v
LiveTranscriptStore (memory only)
        |
        +--> SubtitlePanel (NSPanel + SwiftUI)
        |
        +--> 30-second context selector
                    |
                    v
              MeetingAssistant
                    |
                    v
        Configurable OpenAI-compatible LLM
                    |
                    v
              AssistantPanel
```

The audio capture, ASR connection, transcript state, and LLM request are
independent components. Failure or cancellation in the LLM path must never
interrupt audio capture or live transcription.

## 5. Components

### 5.1 Meeting application selection

Present currently running applications that can be targeted by the process
audio tap. The user must explicitly select one before starting. The selected
process is the only audio source; notification sounds, music, and other system
audio must not be included.

If the process exits during capture, stop audio capture automatically and move
the session to the ended state while retaining the transcript in memory.

### 5.2 Audio capture and conversion

Reuse CallCapture's Core Audio process-tap implementation. Tee captured buffers
directly into a bounded in-memory converter and do not create WAV or temporary
audio files.

The ASR stream receives 16 kHz, mono, signed 16-bit PCM. The converter must not
perform network work on the Core Audio real-time callback. A bounded queue
decouples capture from WebSocket transmission. If the consumer falls behind,
report degraded service and discard the oldest unsent audio rather than grow
memory without limit or block the audio callback.

### 5.3 Live transcription provider

Define a provider-neutral interface so the initial ASR vendor can be replaced:

```swift
protocol LiveTranscriber {
    func connect(configuration: ASRConfiguration) async throws
    func send(_ pcm: Data) async throws
    func events() -> AsyncThrowingStream<TranscriptEvent, Error>
    func finish() async
    func cancel() async
}
```

The initial implementation uses Tencent Cloud's real-time Chinese/English
speaker-separation WebSocket API. Credentials are stored in macOS Keychain.
The application must not write credentials, request signatures, audio, or
transcript text to logs.

The normalized event model contains:

- utterance identifier;
- speaker identifier;
- start and end timestamps;
- transcript text;
- provisional or final status.

Provider-specific speaker IDs are mapped to stable, user-facing labels within
the current in-memory session. The UI must tolerate unknown speakers and labels
that change early in a streaming session.

### 5.4 Transcript state

`LiveTranscriptStore` is the single in-memory source of truth. It maintains:

- the current provisional utterance;
- ordered confirmed utterances;
- speaker-label mappings;
- connection and capture state;
- meeting start and stop timestamps.

Provisional results replace previous provisional text for the same utterance.
Final results are appended once and are not subsequently edited by the client.
The store exposes read-only views to the subtitle and assistant components.

No transcript data is written to preferences, SQLite, files, analytics, crash
metadata, or application logs.

## 6. Floating Subtitle Experience

Use an AppKit `NSPanel` hosting SwiftUI content. During capture the panel:

- is frameless, translucent, and always on top;
- does not activate the application or steal focus from the meeting app;
- appears near the bottom center of the active display by default;
- can be dragged and resized;
- supports adjustable font size and opacity;
- can be locked into a mouse-pass-through mode;
- can appear across macOS Spaces;
- shows the latest three confirmed utterances and one provisional utterance.

Confirmed text uses normal emphasis. Provisional text is visually muted so the
user understands that it may change. Generic labels appear as localized names
such as `Speaker 1`, `Speaker 2`, and `Unknown speaker`.

When capture stops, the panel enters review mode. Review mode displays the full
in-memory transcript in a scrollable view and offers:

- **Copy full transcript**;
- **Clear and close**.

Closing the panel or starting another meeting clears all transcript and LLM
content. Window position and appearance preferences may persist, but meeting
content may not.

## 7. LLM Meeting Assistant

### 7.1 Invocation

The assistant is invoked manually through a configurable global keyboard
shortcut or an overlay button. It never runs automatically.

At invocation time, select confirmed utterances whose time ranges intersect the
30 seconds preceding the trigger. If the first selected utterance crosses the
30-second boundary, include the complete utterance. Do not include provisional
text. If no confirmed text is available, show a non-blocking message and do not
make an LLM request.

Before sending, show the selected context in an editable composer. The user can
remove transcript content and add a request. Provide lightweight presets:

- Suggest several feasible ideas.
- Draft something I can say directly.
- Analyze risks in the proposed approach.
- Suggest useful follow-up questions.
- Custom instruction.

### 7.2 Response

Stream the response into a separate assistant panel. Default prompts ask for
concise, meeting-ready output, including a small set of ideas and an optional
short statement the user can say directly. The user can cancel, retry, copy, or
close the response.

Only one assistant generation may be active at a time. Starting a new request
cancels and clears the previous request. Cancellation, timeout, or provider
failure has no effect on ASR or the subtitle panel.

### 7.3 Configurable provider

Support OpenAI-compatible chat-completions streaming in the first version.
Configuration includes:

- provider preset;
- base URL;
- model identifier;
- API key;
- request timeout;
- maximum output tokens;
- temperature;
- default system prompt;
- context window duration, defaulting to 30 seconds.

Provide presets for OpenAI, OpenRouter, DeepSeek, Ollama, and a custom endpoint.
Presets populate editable defaults and never include credentials. Store the API
key in macOS Keychain; store non-secret configuration in application
preferences. Provide a connection test that sends no meeting transcript.

Local OpenAI-compatible endpoints work without an API key when the endpoint
allows it.

## 8. Lifecycle

```text
Idle
  -> user selects application and starts
Connecting
  -> audio tap and ASR connected
Live
  -> user stops or selected application exits
Review
  -> user may copy transcript or invoke assistant
  -> panel closes or a new meeting starts
Cleared / Idle
```

Starting a new meeting from Review first clears the previous transcript,
assistant context, active response, and speaker mappings. Application
termination performs the same clearing operation.

## 9. Failure Handling

### Permissions

If process-audio permission is unavailable, do not start a partial session.
Explain which macOS permission is required and provide an action that opens the
appropriate System Settings location.

### ASR connection

- Show explicit `connecting`, `live`, `reconnecting`, and `paused` states.
- Retry transient connection failures with bounded exponential backoff.
- Keep already confirmed subtitles in memory during reconnection.
- Do not replay audio older than the bounded queue permits.
- After retries are exhausted, stop capture and enter Review with an error
  banner and the transcript collected so far.

### Audio overload

Never block the Core Audio callback. When the queue reaches its fixed limit,
discard the oldest unsent buffers, increment an in-memory diagnostic counter,
and show a degraded-quality indicator. Do not log audio data.

### LLM failures

Timeout, authentication failure, rate limiting, cancellation, or malformed
streaming data produces an error inside the assistant panel with retry and
configuration actions. It must not change ASR, capture, or transcript state.

## 10. Privacy and Security

- The product captures only the application explicitly selected by the user.
- Microphone input is never opened by this feature.
- Audio is streamed to the configured ASR provider and is never written locally.
- Only the editable, most recent 30 seconds of confirmed transcript is sent to
  the configured LLM provider when the user manually submits it.
- Transcript and LLM content are memory-only and cleared on close, new session,
  or application termination.
- ASR and LLM credentials are stored in macOS Keychain.
- UI copy must clearly state when audio or text leaves the Mac.
- Logs and crash metadata must exclude audio, transcript text, prompts, model
  responses, credentials, and signed request URLs.

## 11. Testing Strategy

### Unit tests

- PCM conversion, chunk sizing, and bounded-buffer overflow behavior.
- Provider response normalization for provisional, final, unknown-speaker, and
  reordered events.
- Deduplication and replacement behavior in `LiveTranscriptStore`.
- Stable speaker-label mapping within a session.
- Exact 30-second context selection, including boundary-crossing utterances.
- Prompt construction and transcript redaction after user edits.
- State transitions and clearing behavior.
- LLM configuration validation and Keychain references.

### Integration tests

- Mock ASR WebSocket reconnect, malformed events, authentication failure, and
  normal completion.
- Mock OpenAI-compatible streaming, cancellation, timeout, and rate limiting.
- Verify that LLM failure cannot terminate or mutate the ASR session.
- Verify that closing or starting a new meeting releases all content stores.

### Manual macOS verification

- Capture from Tencent Meeting, Zoom, and Feishu while unrelated audio plays.
- Permission grant, denial, and revocation flows.
- Mixed Chinese/English speech and two or more remote speakers.
- Short utterances, overlapping speech, silence, and changing network quality.
- Focus behavior, mouse pass-through, multiple displays, Spaces, and full-screen
  meeting applications.
- Confirm that no audio, transcript, or assistant content remains on disk after
  a session.

## 12. Acceptance Criteria

The first version is complete when:

1. The user can select a running meeting application and capture only its audio.
2. Chinese/English mixed speech appears incrementally in the overlay with
   generic speaker labels.
3. The overlay does not steal focus and can be positioned, resized, and locked.
4. Stopping capture retains the transcript in memory for copying.
5. Closing the panel or starting a new meeting removes all meeting content.
6. The user can manually send the most recent 30 seconds of confirmed transcript
   to a configured OpenAI-compatible model and receive a streaming response.
7. ASR continues normally when the LLM request fails or is cancelled.
8. No audio, transcript, prompt, or model response is persisted locally.


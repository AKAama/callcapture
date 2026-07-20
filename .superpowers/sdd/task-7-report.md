# Task 7 Report: Live Meeting Coordinator and Lifecycle

## Implementation

- Added `LiveMeetingCoordinator`, an observable main-actor lifecycle owner with
  `start(process:)`, `stop()`, `clearAndClose()`, and synchronous `shutdown()`.
- Added narrow injected seams for selected-process audio capture and process
  exit observation. Production uses `AudioCaptureManager.startLiveCapture` and
  a `DispatchSourceProcess`; tests use deterministic fakes and the public
  `processDidExit(pid:)` lifecycle entry point.
- A fresh `LiveTranscriber` is created for each meeting. Production creates
  `TencentLiveTranscriber` and loads Tencent configuration from fixed Keychain
  account names without logging any value or signed URL.
- Marked the provider-neutral `LiveTranscriber` contract `Sendable`, matching
  its cross-task use and Tencent's actor implementation.
- Added provider-neutral connection-state reporting so Tencent `reconnecting`
  and recovered `live` states are reflected by the coordinator and the
  `LiveTranscriptStore`.
- Standardized the user-visible lifecycle states as `idle`, `connecting`,
  `live`, `reconnecting`, `review`, and `error`.

## Ordering and Privacy

- The Core Audio PCM callback performs exactly one operation:
  `PCMChunkBuffer.push(_:)`. It performs no network, file, UI, logging, or
  blocking lock work.
- A dedicated sender task drains the bounded FIFO queue and calls ASR; a
  separate event task applies transcript events to the in-memory store.
- Graceful stop order is capture stop, queue finish and complete drain, ASR
  finish, then `review` (or `error` for a terminal failure).
- The buffer now maintains an atomic in-memory discard count covering oldest
  eviction, finished-buffer rejection, and incoming drops on lock contention.
- No audio, transcript, prompt, response, credential, or signed URL is logged
  or persisted. LLM/assistant work is deliberately absent from coordinator
  dependencies, so later assistant failures cannot change capture/ASR state.
- Starting another meeting clears the prior transcript and speaker mapping
  before requesting ASR configuration. `clearAndClose()` and `shutdown()` clear
  the transcript and PCM buffer; shutdown does so synchronously before its
  best-effort asynchronous socket cancellation.

## Lifecycle Failure Handling

- Selected-process exit automatically follows the same ordered stop path and
  retains confirmed transcript content for review.
- ASR stream or sender failure stops capture, preserves existing transcript
  content, and enters `error` with a fixed non-sensitive message.
- A capture cleanup failure leaves the PCM queue finished, retains the cleanup
  obligation, and prevents a new overlapping session. A later clear retries
  cleanup; process exit still invokes the capture manager's emergency stop.
- Session generations prevent late events or completions from a cleared
  meeting from repopulating the store or changing a newer meeting's state.

## Tests Added

`LiveMeetingCoordinatorTests` covers:

- selected-process start and `live` transition;
- manual stop ordering and accepted-PCM drain;
- selected-process exit with transcript retention;
- reconnecting/recovered state reflection;
- exhausted ASR retries and sender-task failure;
- independence from an unrelated failing assistant task;
- previous-meeting clearing before new ASR configuration;
- bounded-buffer discard reporting;
- failed capture cleanup keeping the queue closed and blocking overlap; and
- synchronous exit clearing plus provider cancellation.

## Verification

- Focused Swift Testing was attempted with writable compiler caches. The host
  still stops before executing tests because its Command Line Tools installation
  has no `Testing` module (`no such module 'Testing'`).
- The permanent coordinator test source passes Swift frontend syntax parsing.
- A direct deterministic runtime smoke compiled the production transcript,
  queue, transcriber protocol, process model, and coordinator sources with
  in-memory fakes. It exercised start, overflow, reconnect/recovery, ordered
  stop, process exit, retry exhaustion, next-session clearing, and shutdown;
  it exited `0` with `task7-smoke-pass`.
- The same focused production sources and smoke harness compile cleanly under
  complete strict-concurrency checking with concurrency warnings enabled.
- Production `swift build` with writable module caches exited `0` with
  `Build complete! (4.17s)` after the final lifecycle changes.
- `git diff --check` reported no whitespace errors.

## Self-Review Fixes

- Removed a sender-failure self-await deadlock by scheduling terminal cleanup
  only after the sender task returns.
- Prevented a stop request during an in-flight connect/capture start from being
  overwritten by a late start failure.
- Preserved the Core Audio cleanup obligation when HAL cannot destroy its IO
  callback, keeping the buffer closed so residual callbacks cannot retain new
  audio and preventing an overlapping new capture.
- Replaced application-only termination observation with exact PID monitoring,
  which also works when the selected Core Audio process is not represented by
  `NSRunningApplication`.
- Confirmed coordinator errors are fixed strings and never interpolate
  provider errors, transcript text, configuration, or PCM.

## Remaining Environment Concern

The permanent Swift Testing suite must be run under a matching Xcode/Swift
toolchain that supplies the `Testing` module. Real Core Audio permission/device
behavior and a credentialed Tencent session remain end-to-end validation work;
this task intentionally uses no real credentials or network access.

## Review Fix Wave

- Replaced coordinator-wide mutable task/transcriber state with a captured
  `LiveMeetingSession` per generation. Each session owns one joinable teardown
  operation, so overlapping `stop`, `clearAndClose`, and `start` calls await the
  same cleanup instead of starting a new capture while an old stop is pending.
- Guarded all post-await transcript and lifecycle state changes by exact session
  identity. A completed teardown may only mutate its captured session; it
  cannot clear or transition a newer active meeting.
- Added `AudioCaptureManager.hasPendingCaptureResources`, which includes a
  retained HAL `ioProcID` even when `isRecording` is false. Failed starts now
  attempt cleanup immediately, retain the cleanup obligation after a failed
  cleanup, remain in `error`, and allow a later clear to retry safely.
- Added `PCMChunkBuffer.discardAndFinish()` to atomically discard queued PCM and
  permanently reject subsequent callback writes. Both clear and synchronous
  shutdown close the queue before touching HAL resources, so residual callbacks
  cannot retain meeting audio.
- Added four coordinator race/failure tests and one atomic-buffer test. The
  exact permanent counts are 15 `LiveMeetingCoordinatorTests` and 3
  `PCMChunkBufferTests`.

## Review Fix Verification

- Production `swift build` completed successfully after the lifecycle rewrite:
  `Build complete! (7.39s)`.
- The focused command
  `swift test --filter 'LiveMeetingCoordinatorTests|PCMChunkBufferTests'` reached
  test-target compilation but could not execute because this host toolchain has
  no `Testing` module; the exact blocking diagnostic remains
  `error: no such module 'Testing'`.
- Both changed test files passed Swift frontend syntax parsing. A direct count
  reported exactly 15 coordinator tests and 3 buffer tests.
- The strict-concurrency deterministic runtime smoke compiled with
  `-strict-concurrency=complete -warn-concurrency` and exercised delayed
  teardown joining, old/new-session isolation, retained-resource cleanup retry,
  atomic callback rejection, plus the original lifecycle scenarios. It exited
  `0` with the exact output `task7-smoke-pass`.
- `git diff --check` exited `0` with no output.

# Final Branch Review Fix Report

Date: 2026-07-22
Branch: `codex/realtime-overlay-assistant`

## Scope

This coordinated wave resolves all four findings from the final full-branch
review without adding persistence, transcript logging, callback-side UI work,
or network work to the Core Audio path.

1. Tencent transcript identity and time are now scoped to each successful
   connection generation. Sentence and speaker IDs are generation-prefixed;
   provider-relative timestamps are offset by the larger of monotonic session
   elapsed time and the prior transcript endpoint. A reconnect can therefore
   reuse provider sentence `0` without replacing the earlier connection's
   sentence `0`, while partial/final replacement remains stable within the new
   connection.
2. The meeting assistant now uses a meeting-relative monotonic session clock,
   installed by `LiveMeetingCoordinator`, read by `LiveTranscriptStore`, and
   consumed at the actual manual compose call. The clock factory is injectable
   for deterministic tests and a fresh origin is installed for every meeting.
   Silence now advances the last-30-second boundary.
3. The OpenAI-compatible SSE parser now treats EOF as an error unless it has
   received `[DONE]` or a supported explicit `finish_reason` (`stop`, `length`,
   or `content_filter`). A residual EOF event is parsed deliberately, allowing
   an explicit terminal frame without a trailing blank delimiter while still
   rejecting a delta-only premature EOF.
4. PCM discard totals are mirrored into observable coordinator state by a
   session monitor task. The Core Audio callback remains limited to a single
   nonblocking `PCMChunkBuffer.push`; it performs no UI update, network IO,
   file IO, or explicit lock wait. Direct reads retain the atomic buffer count
   so teardown/emergency ordering remains observable.

## TDD evidence

The permanent Swift Testing regressions were added before production changes.
This host cannot load the package's `Testing` module, so focused strict-
concurrency runtime harnesses were used to establish RED before implementation:

- Reconnect harness: `RED: reconnect sentence 0 replaced old sentence 0; count=1`
  (exit 1).
- Session-time harness: `RED: meeting time stayed pinned at subtitle endpoint 1.0`
  (exit 1).
- SSE harness: `RED: premature EOF incorrectly completed with 1 delta`
  (exit 1).
- Observation harness: `RED: droppedChunkCount changed without an observation notification`
  (exit 1).

Permanent coverage now includes:

- old-connection sentence `0` plus reconnect sentence `0`, generation-scoped
  speakers, monotonic ordering, and same-generation partial/final replacement;
- production composition before and after 40 seconds of silence plus a fresh
  injected clock for each new coordinator session;
- one valid delta followed by premature EOF and a residual `finish_reason=stop`
  terminal event;
- an observation notification while the coordinator remains stably `live`.

## Verification

- Baseline `swift build`: passed (`Build complete! (7.81s)`).
- Focused `swift test` baseline and post-fix attempts: blocked before executing
  tests by the environment's existing `error: no such module 'Testing'`.
- Strict-concurrency reconnect runtime smoke: passed with
  `reconnect-runtime-smoke-pass`; it exercises generation identity, timestamp
  offsets, both confirmed sentences surviving, and replacement of only the new
  connection's partial.
- Strict-concurrency session-clock/assistant runtime smoke: passed with
  `clock-runtime-smoke-pass`; it exercises selection at 100 seconds and expiry
  after silence advances the same session clock to 140 seconds.
- Strict-concurrency SSE runtime smoke: passed with
  `sse-runtime-smoke-pass`; it rejects delta-only EOF and accepts an explicit
  residual `finish_reason=stop` event.
- Strict-concurrency dropped-count runtime smoke: passed with
  `drop-observation-runtime-smoke-pass` while the sender is suspended and the
  coordinator remains live.
- Full `swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency`:
  passed. It reports only the pre-existing concurrency warning for
  `SessionRecord.iso8601Formatter`, outside this diff.
- `swiftc -frontend -parse` over all production and test Swift sources: passed.
- `git diff --check`: passed.
- Changed-source privacy/log scan: no transcript, prompt, reply, credential,
  audio, or signed-URL content is logged; the existing LLM client logs only HTTP
  status and sanitized error category.

## Remaining concerns

- The permanent Swift Testing suites still need execution on an Xcode/Swift
  toolchain that supplies the `Testing` module.
- Real Tencent reconnect timing, actual Core Audio overload observation, and
  AppKit/manual meeting validation still require the desktop/provider checks
  already listed in the implementation plan. No external endpoint or real
  credential was used in this fix wave.

## Follow-up review fixes: reconnect PCM isolation and publication throttling

The follow-up full-branch review found that a delayed pre-outage PCM frame was
retried on the recovered Tencent connection. Because that connection's
provider timestamps are offset to reconnect time, stale speech could otherwise
be shifted into a later assistant context window.

The transport and coordinator now use an explicit, sequence-numbered reconnect
discard barrier:

- Tencent clears provider-pending PCM when recovery starts and never retries a
  frame after its connection generation changes.
- A sender that crosses the reconnect boundary returns a discard barrier. The
  coordinator atomically clears all queued outage PCM, acknowledges the
  barrier, and only then resumes with fresh capture data.
- The coordinator tracks its one in-flight PCM send so the connection-state
  task cannot acknowledge a barrier ahead of an older popped chunk. Barrier
  sequence numbers make the state and sender paths idempotent.
- Provider-pending/in-flight and coordinator-queued losses are added to the
  same degradation count. Teardown also reconciles any barrier that has no
  later PCM send.
- The Core Audio callback remains push-only (`PCMChunkBuffer.push`). It does no
  actor hop, UI mutation, network/file IO, or blocking lock acquisition.

Dropped-count publication now polls at 250 ms by default instead of 20 ms and
assigns observable state only when the count changes. Direct reads still see
the atomic buffer total immediately.

### Follow-up TDD evidence

Permanent regressions were written before the production changes. The
pre-fix production snapshot failed the strict-concurrency reconnect runtime
regression with:

`RED: stale PCM replayed on recovered connection: 2 frames`

The permanent suites now cover:

- a 40-second outage where the delayed old frame is absent from the recovered
  socket, fresh PCM continues normally, and the later 30-second context
  contains only the fresh utterance;
- provider-internal sub-frame PCM being discarded and counted on reconnect;
- coordinator in-flight plus queued outage PCM being discarded and counted,
  followed by successful fresh PCM transmission;
- reconnect queue discard accounting in `PCMChunkBuffer`; and
- a 250 ms production publication interval with no observation notification
  for unchanged counts.

### Follow-up verification

- Full `swift build`: passed (`Build complete!`).
- Full strict-concurrency build command exited successfully:
  `swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency`.
- Fresh strict-concurrency production reconnect runtime smoke: passed with
  `reconnect-discard-runtime-smoke-pass`. It uses the real Tencent transcriber
  and verifies socket payloads plus the post-outage 30-second window.
- Fresh strict-concurrency PCM barrier runtime smoke: passed with
  `pcm-discard-runtime-smoke-pass`.
- `swift test` still cannot compile this repository's test target on the host
  because the installed toolchain has no `Testing` module.
- `swiftc -frontend -parse` over all production and test Swift sources: passed.
- `git diff --check`: passed.
- Changed-source privacy/log scan found no added logging of PCM, transcript,
  credentials, signed URLs, prompts, or replies.

## Final-gate fixes: exact provider loss and cancel-first teardown

Provider discard accounting is now defined as the number of capture-source
chunks that still contain at least one byte not accepted by the old transport.
Tencent tracks each source chunk's remaining byte count while 6,400-byte
provider frames consume data across callback boundaries. If an old-socket send
finishes successfully after recovery has begun, those accepted bytes are
subtracted from the quarantine before its count is reported. A reconnect
barrier is retained through terminal failure/cancellation until the coordinator
reconciles and acknowledges it during teardown, including when the sender task
has already exited with an error.

Discard teardown now cancels the event task and transcriber before joining the
sender. Tencent reconnect waiters are explicitly resumed by cancellation, so a
sender blocked behind a reconnect scheduler/backoff does not rely on cooperative
task cancellation from that scheduler. Graceful stop retains the finish-only
path and does not call cancel.

### Final-gate TDD evidence

The production accounting runtime regression failed before the change with:

`RED: expected 1 unsent source chunk, reported 2`

It uses non-divisible 9,000-byte and 5,400-byte callbacks, consumes a
cross-boundary 6,400-byte frame, and lets that old-socket send complete after
recovery begins. The standalone teardown-order regression also failed before
the change with:

`RED: cancel teardown awaited sender before transcriber cancellation`

Permanent tests now cover exact source-boundary accounting, terminal reconnect
failure reconciliation, cancel teardown with a send blocked behind reconnect,
and the graceful finish-versus-cancel distinction.

### Final-gate verification

- Fresh production exact-accounting smoke: passed with
  `exact-discard-accounting-runtime-smoke-pass`.
- Fresh production stuck-reconnect cancellation smoke: passed with
  `stuck-reconnect-cancel-runtime-smoke-pass`.
- Fresh cancel-first teardown-order smoke: passed with
  `cancel-first-teardown-runtime-smoke-pass`.
- Fresh full strict-concurrency build with warning diagnostics: passed
  (`Build complete! (9.82s)`). Reported warnings are pre-existing and outside
  the changed live-transcription sources.
- `swiftc -frontend -parse` over all production and test Swift sources: passed.
- `git diff --check`: passed.
- Changed-source privacy/log scan found no added logging calls or credential,
  secret, or signed-URL logging.
- Focused `swift test` remains host-blocked before test execution by
  `error: no such module 'Testing'`; no product or test compile failure was
  observed beyond that missing toolchain module.

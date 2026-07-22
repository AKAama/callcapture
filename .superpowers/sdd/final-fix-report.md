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

---
phase: 20-video-storage-retention
plan: 04
subsystem: recording
tags: [video, screencapturekit, avassetwriter, finalize, d-13, test-double]

# Dependency graph
requires:
  - phase: 18-screen-capture-engine
    provides: "WriterSink.finalizeOnQueue idempotency guard and its two terminal exits (writer-not-writing return, finishWriting completion)"
  - phase: 19-recording-lifecycle-integration
    provides: "ScreenRecording seam, MockScreenRecorder + MockScreenRecorderFactory with lock-guarded knobs"
provides:
  - "ScreenRecorder.onFinalized: (@Sendable () -> Void)? - fires exactly once after finishWriting completes, or on the writer-not-writing exit"
  - "ScreenRecording.onFinalized { get set } - seam requirement (assign before start, never fires on a failed start)"
  - "MockScreenRecorder: onFinalized + finalizeDelay / neverFinalize / createsFileOnStart knobs + simulateFinalize(), exactly-once guarded"
  - "MockScreenRecorderFactory: mirrors and copies all three new knobs"
affects: [20-06 coordinator finalize/verify funnel (listens to onFinalized, drives D-05/D-06/D-07 through the mock knobs), 20-08 phase verification + kill-9 gate re-run]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Engine callbacks are captured into WriterSink at start() by value; a new callback threads through the same four places as onStreamStopped"
    - "Exactly-once comes from the existing finalize state guard; no second flag in the engine"
    - "WriterSink is testable without SCStream: build it directly over a real AVAssetWriter in a temp dir"

key-files:
  created:
    - Tests/WriterSinkFinalizeTests.swift
  modified:
    - Sources/Recording/ScreenRecorder.swift
    - Sources/Recording/ScreenRecording.swift
    - Tests/Mocks/MockScreenRecorder.swift
    - Tests/ProtocolDITests.swift

key-decisions:
  - "20-04: onFinalized fires inside the finishWriting completion and on the writer-not-writing early return, gated only by the existing finalizeOnQueue idempotency guard; stop() still does not await finishWriting (D-13 additive-only, 3 changed lines in the hardware-verified engine)"
  - "20-04: MockScreenRecorder.stop() finalizes only after a successful start, mirroring the engine's stop() no-op without a running writer, so a 20-06 test can never pass on a finalize that production would not deliver"

patterns-established:
  - "Mock exactly-once: a lock-guarded _didFinalize flipped in fireFinalizedOnce(); the callback runs outside the lock"
  - "Late signals in mocks use the existing test-only Task { try? await Task.sleep } idiom"

requirements-completed: []  # STOR-01 finalize-signal leg delivered here; the link is written and verified by 20-06, so completion is marked there / in 20-08 (same as 20-01, 20-03)

# Metrics
duration: 8min
completed: 2026-11-19
---

# Phase 20 Plan 04: Engine Finalize Signal Summary

**The Phase 18 engine now has an additive `onFinalized` callback. `WriterSink` fires it exactly once, after `finishWriting` completes or on the writer-not-writing exit. It is exposed through the `ScreenRecording` seam and mirrored by a mock that can finalize on stop, late, never, or on demand.**

## Performance

- **Duration:** ~8 min
- **Started:** 2026-11-19T13:36:56Z
- **Completed:** 2026-11-19T13:44:28Z
- **Tasks:** 2 (each RED + GREEN commit)
- **Files modified:** 5 (1 created, 4 modified)

## Accomplishments
- `ScreenRecorder.onFinalized` is threaded into `WriterSink` at `start()` exactly like `onStreamStopped`. `finalizeOnQueue` calls `onFinalized?()` before the not-writing `return` and as the last statement of the `finishWriting` completion (capture list `[logger, writer, onFinalized]`)
- Engine diff: 3 changed lines (the sink-construction argument, the init signature, and the `finishWriting` capture list). Everything else is added. Timing, ordering, log text, the state machine, the keepalive, and `stop()` are unchanged
- `ScreenRecording.onFinalized { get set }` is documented with the assign-before-start trap (Pitfall 8), "stop() returns before this", and "never fires when start throws". The type doc now says "three callbacks"
- `MockScreenRecorder` gains `onFinalized`, the knobs `finalizeDelay`, `neverFinalize`, and `createsFileOnStart`, and `simulateFinalize()`, with a lock-guarded exactly-once `fireFinalizedOnce()`. `MockScreenRecorderFactory` mirrors and copies all three knobs
- 5 `WriterSinkFinalizeTests` (real `AVAssetWriter`, no SCStream, temp dir) and 8 new `ProtocolDITests` under `// MARK: - Finalize contract (Phase 20)`

## Task Commits

1. **Task 1: additive onFinalized in WriterSink** - `ebab829` (test, RED), `643e39d` (feat, GREEN)
2. **Task 2: seam requirement + mock knobs** - `bcf57a7` (test, RED), `2a28a94` (feat, GREEN)

## Files Created/Modified
- `Sources/Recording/ScreenRecorder.swift` - `onFinalized` property, sink argument, `WriterSink` stored `let` + init param, two fire points
- `Sources/Recording/ScreenRecording.swift` - `onFinalized` requirement + doc updates
- `Tests/WriterSinkFinalizeTests.swift` - exactly-once tests: stopped (asserts `writer.status != .writing` at fire), stream error, stop/stop/streamError burst, writer never started, nil callback
- `Tests/Mocks/MockScreenRecorder.swift` - finalize knobs, `simulateFinalize()`, factory mirrors
- `Tests/ProtocolDITests.swift` - seam test + 7 mock-contract tests; class-level temp dir for the file-creating test (D-15)

## Verification
- RED confirmed for both tasks: compile failures on the missing `onFinalized:` init parameter, then on the missing seam member and mock knobs
- Task 1 command (`WriterSinkFinalizeTests` + `ScreenRecorderConfigTests` + `ScreenRecorderStateTests` + `ScreenRecorderFilterTests`): 31 tests, `** TEST SUCCEEDED **`
- Task 2 command (`ProtocolDITests` + `RecordingCoordinatorScreenCaptureTests` + `RecordingCoordinatorScreenCaptureTeardownTests` + `WriterSinkFinalizeTests`): 39 tests, `** TEST SUCCEEDED **`
- `make test`: **391 tests, 0 failures**, `** TEST SUCCEEDED **` (378 baseline + 13 new)
- All acceptance greps pass: removed-line count is 3, `onFinalized?()` appears 2 times, `audioDirectory` appears 0 times in the new test file, and `git diff --stat -- Sources/Coordinator/RecordingCoordinator.swift` is empty

## Decisions Made
- The engine init parameter is explicit with no default, matching the other two callbacks
- The 4 `ScreenRecorder finishWriting error` log lines in `WriterSinkFinalizeTests` are expected. Those writers started writing but never started a session, which is the production "stopped before the first frame" path. The completion still runs, `onFinalized` still fires, and the writer status is `.failed`. That file is the D-07 "no usable video" case that 20-06 deletes

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 2 - Mock fidelity] Mock `stop()` finalizes only after a successful `start`**
- **Found during:** Task 2
- **Issue:** The plan's `stop()` steps (delay, count, then `neverFinalize` / `finalizeDelay` / fire) would fire `onFinalized` when `stop()` follows a failed start. The real engine's `stop()` is a no-op without a running writer, and the behavior spec says "startError set: onFinalized never fires". A mock that finalizes where production never does could let a 20-06 test pass on a signal that never arrives in production
- **Fix:** A lock-guarded `_didStartSuccessfully` is set in `start` and checked in `stop()` before firing. `testMockFailedStartNeverFinalizes` calls `stop()` after the failed start to pin this. `simulateFinalize()` stays unconditional, because the test drives it
- **Files modified:** Tests/Mocks/MockScreenRecorder.swift, Tests/ProtocolDITests.swift
- **Commit:** bcf57a7, 2a28a94

## Issues Encountered
None. The kill-9 gate re-run on hardware stays with 20-08, as planned.

## TDD Gate Compliance
Both tasks have a `test(20-04)` RED commit followed by a `feat(20-04)` GREEN commit. No refactor commit was needed.

## Next Phase Readiness
- 20-06 can assign `recorder.onFinalized` BEFORE `start` (yield `.finalized` and finish the per-meeting stream) and drive every D-05/D-06/D-07 path with the factory knobs. Use `finalizeDelay` for a late finalize after a timed-out stop, `neverFinalize` for quit or a wedged finalize, `latest?.simulateFinalize()` for a finalize mid-meeting after stream death, and `createsFileOnStart` + `startError` for the defensive cleanup after a failed start
- No blockers

## Self-Check: PASSED
- FOUND: Tests/WriterSinkFinalizeTests.swift, Sources/Recording/ScreenRecorder.swift, Sources/Recording/ScreenRecording.swift, Tests/Mocks/MockScreenRecorder.swift, Tests/ProtocolDITests.swift
- FOUND commits: ebab829, 643e39d, bcf57a7, 2a28a94

---
*Phase: 20-video-storage-retention*
*Completed: 2026-11-19*

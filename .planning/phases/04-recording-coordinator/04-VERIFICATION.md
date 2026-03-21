---
phase: 04-recording-coordinator
verified: 2026-03-21T23:01:18Z
status: gaps_found
score: 6/7 must-haves verified
gaps:
  - truth: "State transitions in coordinator use synchronous reduce, async side effects dispatched after"
    status: partial
    reason: >
      The reduce + async-effect pattern is correctly implemented inside the coordinator.
      However, the pipeline (TranscriptionPipeline.enqueue) has no callback to the coordinator.
      After enqueue(), the pipeline runs to completion autonomously and updates the DB directly.
      The coordinator's state never receives .transcriptionComplete or .transcriptionFailed events
      from the pipeline, so the state machine is permanently stuck in .transcribing after a meeting ends.
      The notifyComplete and notifyError side-effect handlers (executeNotifyComplete,
      executeNotifyError) are unreachable from normal pipeline execution flow.
    artifacts:
      - path: "Sources/Transcription/TranscriptionPipeline.swift"
        issue: >
          No completion callback. enqueue() fires-and-forgets. Pipeline updates DB status to
          .done or .error internally without notifying the coordinator actor.
      - path: "Sources/Coordinator/RecordingCoordinator.swift"
        issue: >
          executeStopAndTranscribe() calls pipeline.enqueue() but does not pass a completion
          handler. State remains .transcribing indefinitely after a real transcription.
    missing:
      - "TranscriptionPipeline.enqueue() needs a completion callback parameter: onComplete: ((String, Result<Void, Error>) -> Void)? or equivalent"
      - "RecordingCoordinator.executeStopAndTranscribe() must pass a callback that calls handle(.transcriptionComplete) on success and handle(.transcriptionFailed) on failure"
      - "Same wiring needed in executeRetryTranscription()"
---

# Phase 04: Recording Coordinator Verification Report

**Phase Goal:** Recording lifecycle is managed by a single actor with explicit state machine -- not scattered across AppState
**Verified:** 2026-03-21T23:01:18Z
**Status:** gaps_found
**Re-verification:** No -- initial verification

## Goal Achievement

### Observable Truths

Plan 01 must-haves:

| # | Truth | Status | Evidence |
|---|-------|--------|---------|
| 1 | RecordingState enum has exactly four cases: idle, recording, transcribing, error | VERIFIED | RecordingState.swift:6-9 -- exactly four cases with associated values |
| 2 | Every valid state transition returns the new state via reduce() | VERIFIED | 7 valid transition tests in RecordingStateTests.swift:15-154, all with XCTAssertNotNil |
| 3 | Every invalid state transition returns nil and does not mutate state | VERIFIED | 11 invalid transition tests in RecordingStateTests.swift:158-241, all with XCTAssertNil |
| 4 | State machine is pure synchronous logic with no async, no side effects | VERIFIED | RecordingState.swift imports only Foundation; reduce() is a static func with no async, no actors, no side effects |

Plan 02 must-haves:

| # | Truth | Status | Evidence |
|---|-------|--------|---------|
| 5 | RecordingCoordinator actor is the single owner of recording lifecycle state | VERIFIED | AppState.swift has zero recording lifecycle fields (no detector, recorder, pipeline, currentMeetingId). All owned by coordinator |
| 6 | AppState contains zero recording lifecycle logic -- only observable properties for UI | VERIFIED | AppState.swift is 131 lines; stopRecording/retryTranscription/shutdown all delegate to coordinator |
| 7 | Pipeline is guaranteed initialized before MeetingDetector starts -- no init race | VERIFIED | AppState.initialize(): pipeline created at line 73, coordinator created with non-optional pipeline at line 77-82, coordinator.start() called at line 105 (after setOnStateChange). Structural guarantee. |
| 8 | Starting a recording while pipeline is initializing does not crash or lose data | VERIFIED | Coordinator cannot be constructed without a non-optional pipeline. Race is structurally impossible -- coordinator.start() only called after pipeline init completes |
| 9 | State transitions in coordinator use synchronous reduce, async side effects dispatched after | PARTIAL | handle() calls RecordingState.reduce() synchronously then awaits execute(). BUT: pipeline.enqueue() has no completion callback, so coordinator never receives .transcriptionComplete or .transcriptionFailed. State is stuck in .transcribing after pipeline finishes. |

**Score:** 8/9 truths verified (6/7 unique goals -- partial credit on truth #9)

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `Sources/Coordinator/RecordingState.swift` | State enum, Event enum, SideEffect enum, reduce function | VERIFIED | 127 lines, all four enums + reduce, pure synchronous |
| `Tests/RecordingStateTests.swift` | Exhaustive transition tests for valid and invalid paths | VERIFIED | 22 test functions (7 valid + 11 invalid + 3 equality + 1 uniqueness) |
| `project.yml` | Coordinator source group added to target | VERIFIED | project.yml uses `Sources` glob with `createIntermediateGroups: true`. xcodeproj confirms RecordingCoordinator.swift and RecordingState.swift are in build targets |
| `Sources/Coordinator/RecordingCoordinator.swift` | Actor-based coordinator calling reduce synchronously, executing side effects async | VERIFIED (with gap) | actor RecordingCoordinator exists, handle() calls reduce synchronously, dispatches execute() async. Gap: no pipeline completion callback |
| `Sources/App/AppState.swift` | Thin @Observable wrapper subscribing to coordinator state | VERIFIED | 131 lines, no lifecycle fields, delegates to coordinator via setOnStateChange |
| `Sources/App/CaddieApp.swift` | Coordinator created and injected into AppState | VERIFIED | CaddieApp creates AppState; coordinator is created inside AppState.initialize() which is the correct encapsulation. CaddieApp doesn't need to reference RecordingCoordinator directly |
| `Tests/RecordingCoordinatorTests.swift` | Integration tests for coordinator handle() with mocked services | VERIFIED | 8 tests: initial state, meetingDetected transitions, DB record creation, double-detected guard, idle meetingEnded guard, state callback, retry convenience, stopRecording convenience |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| Tests/RecordingStateTests.swift | Sources/Coordinator/RecordingState.swift | @testable import | WIRED | Line 3: `@testable import Caddie` |
| Sources/Coordinator/RecordingCoordinator.swift | Sources/Coordinator/RecordingState.swift | reduce() call in handle() | WIRED | Line 50: `guard let result = RecordingState.reduce(state: state, event: event)` (2 grep matches total) |
| Sources/Coordinator/RecordingCoordinator.swift | Sources/Recording/AudioRecorder.swift | start/stop recording side effects | WIRED | Lines 149, 158, 82: `recorder.start()`, `recorder.stop()` |
| Sources/Coordinator/RecordingCoordinator.swift | Sources/Transcription/TranscriptionPipeline.swift | enqueue transcription side effect | PARTIAL | Lines 180, 206: `pipeline.enqueue()` called. But no completion callback -- pipeline does not signal coordinator on finish. State machine stuck in .transcribing. |
| Sources/App/AppState.swift | Sources/Coordinator/RecordingCoordinator.swift | delegates lifecycle methods to coordinator | WIRED | Lines 32, 77, 85, 105, 106, 119, 123, 127 |
| Sources/App/CaddieApp.swift | Sources/Coordinator/RecordingCoordinator.swift | creates coordinator instance | WIRED (indirect) | CaddieApp creates AppState which creates coordinator in initialize(). Correct architecture -- CaddieApp does not need to know about coordinator. |

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|-------------|-------------|--------|----------|
| REC-03 | 04-01-PLAN.md, 04-02-PLAN.md | Recording lifecycle managed by RecordingCoordinator actor with explicit state machine (idle -> recording -> transcribing -> done/error) | PARTIAL | Actor exists with state machine. idle -> recording -> transcribing transitions work. transcribing -> done/error BLOCKED because pipeline has no completion callback. The full lifecycle (idle -> recording -> transcribing -> done/error) is not reachable in production. |
| REC-04 | 04-02-PLAN.md | AppState initialization race condition eliminated (pipeline guaranteed ready before meeting lifecycle events fire) | SATISFIED | Pipeline created before coordinator constructed. Coordinator.start() called after coordinator.setOnStateChange(). Detector only starts when coordinator.start() is called. Structurally impossible to race. AppState.initialize() line 73 (pipeline) -> line 77 (coordinator) -> line 105 (start). |

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| Sources/Transcription/TranscriptionPipeline.swift | 112 | `try? FileManager.default.removeItem(at: wavURL)` | Info (existing) | WAV deletion silently fails -- pre-existing issue, not introduced in Phase 04 |
| Sources/Transcription/TranscriptionPipeline.swift | 27 | `Task { await processNext() }` | Info (existing) | Unstructured task, pre-existing. Not introduced in Phase 04. |

No anti-patterns found in Phase 04 files (RecordingState.swift, RecordingCoordinator.swift, AppState.swift changes, test files).

### Human Verification Required

None -- all meaningful behaviors are verifiable programmatically given the gap above is a structural code issue, not a visual/UX concern.

### Gaps Summary

**Root cause: Pipeline -> Coordinator feedback loop is missing.**

The `TranscriptionPipeline` was not refactored to accept a completion callback. It runs autonomously and updates the DB directly on success/error, but never informs the coordinator. As a result:

1. After `handle(.meetingEnded)` fires, the coordinator correctly transitions to `.transcribing` and calls `pipeline.enqueue()`.
2. The pipeline processes the job, writes DB status to `.done` or `.error`, and exits.
3. The coordinator's state remains `.transcribing` forever -- it never receives `.transcriptionComplete` or `.transcriptionFailed`.
4. `executeNotifyComplete` and `executeNotifyError` (the side effects for those events) are therefore dead code in the normal path.
5. UI status remains `.transcribing` permanently after every meeting ends.

This directly blocks REC-03 ("idle -> recording -> transcribing -> **done/error**") -- the terminal states of the lifecycle are unreachable.

The fix requires:
- Adding a completion callback to `TranscriptionPipeline.enqueue()` (or an `onComplete` property on the actor)
- `RecordingCoordinator.executeStopAndTranscribe()` passes a closure that calls `await handle(.transcriptionComplete(meetingId:))` or `await handle(.transcriptionFailed(meetingId:, error))` when the pipeline finishes
- Same for `executeRetryTranscription()`

This was acknowledged in the SUMMARY under "Next Phase Readiness" ("Pipeline completion callback not yet wired") but was not flagged as a gap -- it is a gap because it breaks the observable truth that the state machine manages the full lifecycle.

---

_Verified: 2026-03-21T23:01:18Z_
_Verifier: Claude (gsd-verifier)_

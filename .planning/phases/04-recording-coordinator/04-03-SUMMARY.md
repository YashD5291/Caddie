---
phase: 04-recording-coordinator
plan: 03
subsystem: transcription, coordinator
tags: [swift, actor, callback, state-machine, pipeline, lifecycle]

# Dependency graph
requires:
  - phase: 04-recording-coordinator
    provides: "RecordingCoordinator actor with state machine (04-01), TranscriptionPipeline with enqueue (04-02)"
provides:
  - "Pipeline-to-coordinator completion callback closing the REC-03 lifecycle gap"
  - "Full state lifecycle: idle -> recording -> transcribing -> done/error"
affects: [05-appstate-slim, 06-error-handling]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "@Sendable closure callback from actor pipeline to actor coordinator"
    - "Trailing closure with [self] capture for actor-to-actor communication"
    - "Task {} wrapper for async dispatch from synchronous callback"

key-files:
  created: []
  modified:
    - Sources/Transcription/TranscriptionPipeline.swift
    - Sources/Coordinator/RecordingCoordinator.swift
    - Tests/TranscriptionPipelineTests.swift
    - Tests/RecordingCoordinatorTests.swift

key-decisions:
  - "onComplete callback with @Sendable and Result<Void, Error> for cross-actor closure passing"
  - "[self] capture in actor closures (actors don't support weak references)"

patterns-established:
  - "Pipeline completion callback pattern: onComplete?(meetingId, .success(())) / .failure(error)"
  - "Coordinator callback wiring: trailing closure dispatching state events via Task { await self.handle() }"

requirements-completed: [REC-03]

# Metrics
duration: 22min
completed: 2026-03-22
---

# Phase 04 Plan 03: Pipeline Completion Callback Summary

**TranscriptionPipeline.enqueue() onComplete callback wired to RecordingCoordinator state machine, closing the transcribing-to-done/error lifecycle gap**

## Performance

- **Duration:** 22 min
- **Started:** 2026-03-21T23:08:58Z
- **Completed:** 2026-03-21T23:31:09Z
- **Tasks:** 2
- **Files modified:** 4

## Accomplishments
- TranscriptionPipeline.enqueue() accepts optional @Sendable onComplete callback (default nil for backward compat)
- Pipeline calls onComplete with (meetingId, .success) on successful transcription and (meetingId, .failure(error)) on any failure
- RecordingCoordinator wires callback in both executeStopAndTranscribe and executeRetryTranscription
- Full lifecycle idle -> recording -> transcribing -> done/error is now reachable (was stuck at .transcribing)
- 6 new tests (3 pipeline callback + 3 coordinator lifecycle transition)

## Task Commits

Each task was committed atomically:

1. **Task 1: Add onComplete callback to TranscriptionPipeline.enqueue** - `d83897b` (feat)
2. **Task 2: Wire coordinator to pass completion callback and test lifecycle** - `e4c0e6d` (feat)

_Both tasks used TDD: RED (failing tests) -> GREEN (implementation) -> verified_

## Files Created/Modified
- `Sources/Transcription/TranscriptionPipeline.swift` - Added onComplete parameter to enqueue(), queue type, success/error callback invocations
- `Sources/Coordinator/RecordingCoordinator.swift` - Wired onComplete in executeStopAndTranscribe and executeRetryTranscription
- `Tests/TranscriptionPipelineTests.swift` - 3 new tests: success callback, ASR failure callback, missing WAV callback + CallbackResultBox helper
- `Tests/RecordingCoordinatorTests.swift` - 3 new tests: transcriptionComplete -> idle, transcriptionFailed -> error, retry exits .transcribing

## Decisions Made
- Used `@Sendable (String, Result<Void, Error>) -> Void` type for cross-actor callback safety
- Used `[self]` capture (not `[weak self]`) in actor closures since actors don't support weak references
- Callback dispatches events via `Task { await self.handle(...) }` for correct cross-actor communication
- Retry test accepts either .idle or .error as valid post-callback states (both prove callback fired)

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
- Initial coordinator tests failed because `executeStartRecording` creates real WAV files (via AudioRecorder.start), so the pipeline succeeded instead of failing as expected. Fixed by stubbing ASR to error for the failure path test and accepting success as valid for the retry test.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- REC-03 lifecycle complete: coordinator state machine fully wired from detection through transcription completion
- Pipeline-to-coordinator feedback loop closed -- no more stuck .transcribing states
- Ready for Phase 05 (AppState slim wrapper) which will delegate to this coordinator

## Self-Check: PASSED

All 4 files verified present. Both commit hashes (d83897b, e4c0e6d) found in git log. 20 tests pass (9 pipeline + 11 coordinator).

---
*Phase: 04-recording-coordinator*
*Completed: 2026-03-22*

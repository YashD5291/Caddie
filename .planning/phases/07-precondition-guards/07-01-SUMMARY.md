---
phase: 07-precondition-guards
plan: 01
subsystem: recording, models
tags: [disk-space, timeout, preconditions, error-handling, task-group]

requires:
  - phase: 04-recording-coordinator
    provides: RecordingCoordinator actor with state machine and side effects

provides:
  - Disk space precondition guard (500MB threshold) before recording starts
  - Model download 5-minute timeout with user-facing retry guidance
  - CoordinatorError.insufficientDiskSpace error type
  - ModelDownloadError.timedOut error type
  - withTimeout() generic task group helper on ModelManager

affects: [08-resource-cleanup, 09-observability]

tech-stack:
  added: []
  patterns:
    - "Precondition check pattern: fail-fast guard before expensive operation"
    - "Task group timeout: race operation vs sleep, first to finish wins"
    - "volumeAvailableCapacityForImportantUsage for accurate macOS disk space"

key-files:
  created:
    - Tests/ModelManagerTests.swift
  modified:
    - Sources/Coordinator/RecordingCoordinator.swift
    - Sources/Models/ModelManager.swift
    - Tests/RecordingCoordinatorTests.swift

key-decisions:
  - "volumeAvailableCapacityForImportantUsage over volumeAvailableCapacity -- accounts for purgeable space macOS can reclaim"
  - "withThrowingTaskGroup for timeout -- cancels loser automatically, no manual timer management"
  - "Disk check before DB insert -- fail fast before any side effects"
  - "withTimeout is internal (not private) to enable direct testing without mocking downloads"

patterns-established:
  - "Precondition guard: check resource availability as first line of side effect execution"
  - "Timeout wrapper: withThrowingTaskGroup race pattern for async operation deadlines"

requirements-completed: [ERR-05, ERR-06]

duration: 21min
completed: 2026-03-22
---

# Phase 7 Plan 1: Precondition Guards Summary

**Disk space guard (500MB) blocks recording pre-start; model download times out at 5min with retry via task group race**

## Performance

- **Duration:** 21 min
- **Started:** 2026-03-21T23:50:40Z
- **Completed:** 2026-03-22T00:11:59Z
- **Tasks:** 2
- **Files modified:** 4

## Accomplishments
- Recording refuses to start if disk space < 500MB, transitions to error state with human-readable message
- Model download wrapped in 5-minute timeout using withThrowingTaskGroup race pattern
- Both failures are recoverable: user can free space (recording) or tap Retry (download)
- 5 new tests: 2 for disk space guard, 3 for timeout mechanism

## Task Commits

Each task was committed atomically:

1. **Task 1: Disk space guard in RecordingCoordinator** - `00e01df` (feat)
2. **Task 2: Model download timeout with retry** - `156148b` (feat)

_Both tasks followed TDD: RED (compile failure) -> GREEN (tests pass)._

## Files Created/Modified
- `Sources/Coordinator/RecordingCoordinator.swift` - Added checkDiskSpace(), minimumDiskSpaceBytes constant, insufficientDiskSpace error case
- `Sources/Models/ModelManager.swift` - Added ModelDownloadError enum, withTimeout() helper, wrapped download in 5min timeout
- `Tests/RecordingCoordinatorTests.swift` - Added testInsufficientDiskSpaceBlocksRecording, testInsufficientDiskSpaceErrorDescription
- `Tests/ModelManagerTests.swift` - Created: testDownloadTimesOutAfterDeadline, testTimeoutErrorMessageContainsRetryGuidance, testTimeoutConstantIsFiveMinutes

## Decisions Made
- Used `volumeAvailableCapacityForImportantUsage` (not `volumeAvailableCapacity`) for accurate macOS disk reporting including purgeable space
- Made `withTimeout` internal access (not private) so tests can exercise the timeout mechanism directly without needing to mock FluidAudio downloads
- Made `downloadTimeoutSeconds` a static `let` (not private) for test assertion of the 5-minute constant
- Placed disk check before DB insert in executeStartRecording to avoid orphaned DB records on failure

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Branch switch required**
- **Found during:** Task 1 (initial file reads)
- **Issue:** Executor started on `phase-05-pipeline-data-integrity` branch which lacked Coordinator files from phase 04
- **Fix:** Switched to `phase-06-error-discipline` branch and created `phase-07-precondition-guards` from it
- **Verification:** All source files present, all prior tests still pass

---

**Total deviations:** 1 auto-fixed (1 blocking)
**Impact on plan:** Branch fix was necessary to access prior phase artifacts. No scope creep.

## Issues Encountered
- Pre-existing flaky test `testTranscriptionCompleteTransitionsToIdle` occasionally fails when run alongside other tests (timing-sensitive). Passes in isolation. Not caused by this plan's changes -- the disk space guard touches `executeStartRecording` only, not the transcription path.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- Precondition guards shipped; both error paths are recoverable by user action
- OnboardingView retry button already handles timeout errors via existing downloadError display
- Ready for phase 08 (resource-cleanup) and phase 09 (observability)

## Self-Check: PASSED

- All 4 source/test files exist on disk
- Both task commits (00e01df, 156148b) found in git log
- SUMMARY.md created at expected path

---
*Phase: 07-precondition-guards*
*Completed: 2026-03-22*

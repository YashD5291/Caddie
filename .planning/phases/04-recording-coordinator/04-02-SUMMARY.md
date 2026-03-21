---
phase: 04-recording-coordinator
plan: 02
subsystem: coordinator
tags: [actor, state-machine, appstate-refactor, init-race-fix, sendable]

requires:
  - phase: 04-recording-coordinator
    provides: RecordingState enum with reduce function (Plan 01)
  - phase: 02-protocol-di
    provides: Protocol-based engine injection for TranscriptionPipeline
provides:
  - RecordingCoordinator actor owning all recording lifecycle
  - Thin AppState with zero recording logic
  - Init race condition structurally eliminated
  - State change callback for UI updates
affects: [05-error-handling, recording-coordinator, app-state]

tech-stack:
  added: []
  patterns: [actor-coordinator, synchronous-reduce-async-effects, thin-observable-wrapper, nonisolated-unsafe-sendable-bridge]

key-files:
  created:
    - Sources/Coordinator/RecordingCoordinator.swift
    - Tests/RecordingCoordinatorTests.swift
  modified:
    - Sources/App/AppState.swift

key-decisions:
  - "Coordinator deps all non-optional: database, recorder, pipeline, detector injected at init -- fail fast"
  - "onStateChange callback uses @Sendable closure with weak self to bridge actor to MainActor"
  - "nonisolated(unsafe) used for detector callback wiring (actor self reference in non-isolated context)"

patterns-established:
  - "Coordinator pattern: actor owns lifecycle, AppState is thin @Observable wrapper subscribing to state changes"
  - "Async GRDB writes from actor: try await database.dbWriter.write (not synchronous try)"

requirements-completed: [REC-03, REC-04]

duration: 23min
completed: 2026-03-22
---

# Phase 04 Plan 02: RecordingCoordinator + AppState Refactor Summary

**Actor-based RecordingCoordinator owning full recording lifecycle with synchronous reduce and async side effects, AppState reduced to thin observable wrapper**

## Performance

- **Duration:** 23 min
- **Started:** 2026-03-21T22:29:00Z
- **Completed:** 2026-03-21T22:52:00Z
- **Tasks:** 2
- **Files modified:** 4

## Accomplishments
- RecordingCoordinator actor uses RecordingState.reduce() synchronously then dispatches async side effects
- AppState stripped of all recording lifecycle logic (detector, recorder, pipeline, startRecording, currentMeetingId removed)
- Init race condition (REC-04) structurally impossible: coordinator requires non-optional pipeline at init, detector starts after pipeline
- 8 coordinator-specific tests plus all 108 tests pass with zero failures
- UI views continue working unchanged -- same AppState API surface (status, currentMeetingTitle, recordingDuration, stopRecording, retryTranscription, database, modelManager)

## Task Commits

Each task was committed atomically:

1. **Task 1: RecordingCoordinator actor with tests** - `4e71ffe` (feat)
2. **Task 2: AppState thin wrapper refactor** - `0ec6669` (refactor)

## Files Created/Modified
- `Sources/Coordinator/RecordingCoordinator.swift` - Actor with handle(), execute(), start(), stop(), convenience methods
- `Tests/RecordingCoordinatorTests.swift` - 8 tests: state transitions, DB records, invalid transitions, callbacks, convenience methods
- `Sources/App/AppState.swift` - Stripped to thin @Observable wrapper, delegates all recording lifecycle to coordinator

## Decisions Made
- All coordinator dependencies non-optional (database, recorder, pipeline, detector) -- fail fast pattern from ARCHITECTURE.md
- Used `nonisolated(unsafe) let coordinator = self` in start() for detector callback wiring -- safe because actor serializes access
- GRDB writes from actor context must use `try await` (not `try`) -- GRDB 7 async write interface from Swift actor context

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] GRDB async write calls from actor context**
- **Found during:** Task 1 (coordinator implementation)
- **Issue:** `database.dbWriter.write` is async when called from actor context but was called without await
- **Fix:** Changed all `try database.dbWriter.write` to `try await database.dbWriter.write`
- **Files modified:** Sources/Coordinator/RecordingCoordinator.swift
- **Verification:** Build succeeds, all tests pass
- **Committed in:** 4e71ffe

**2. [Rule 1 - Bug] Captured mutable var in concurrent closure**
- **Found during:** Task 1 (coordinator implementation)
- **Issue:** `var record` mutated inside GRDB write closure -- Swift 6 strict concurrency violation
- **Fix:** Moved record creation inside the write closure to avoid capture of mutable var
- **Files modified:** Sources/Coordinator/RecordingCoordinator.swift
- **Verification:** Builds with SWIFT_STRICT_CONCURRENCY: complete
- **Committed in:** 4e71ffe

**3. [Rule 1 - Bug] Test sendability for state callback**
- **Found during:** Task 1 (coordinator tests)
- **Issue:** `var receivedState` captured in @Sendable closure -- Swift 6 violation
- **Fix:** Created StateBox class with @unchecked Sendable for test state capture
- **Files modified:** Tests/RecordingCoordinatorTests.swift
- **Verification:** Tests compile and pass
- **Committed in:** 4e71ffe

---

**Total deviations:** 3 auto-fixed (3 bugs -- all Swift 6 strict concurrency)
**Impact on plan:** All fixes necessary for compilation under Swift 6. No scope creep.

## Issues Encountered
- XcodeGen regeneration needed after creating new source files in Sources/Coordinator/
- GRDB 7 write interface is async from actor context (unlike from @MainActor classes) -- required updating all write calls

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- Coordinator pattern established for all future recording lifecycle changes
- Error handling hardening (Phase 05) can add precondition checks into coordinator's execute() methods
- Pipeline completion callback not yet wired (future: coordinator should receive transcriptionComplete/transcriptionFailed from pipeline)

## Self-Check: PASSED

All created files verified present. All commit hashes verified in git log.

---
*Phase: 04-recording-coordinator*
*Completed: 2026-03-22*

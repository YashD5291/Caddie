---
phase: 09-recording-resilience
plan: 02
subsystem: recording
tags: [coreaudio, device-disconnect, state-machine, property-listener]

requires:
  - phase: 04-coordinator
    provides: RecordingState reduce function and RecordingCoordinator actor
  - phase: 09-recording-resilience
    provides: Plan 01 SystemAudioCapture with file-level logger
provides:
  - deviceDisconnected event in RecordingState machine
  - kAudioDevicePropertyDeviceIsAlive listener on aggregate device
  - End-to-end disconnect propagation: SystemAudioCapture -> AudioRecorder -> RecordingCoordinator
affects: [recording, coordinator]

tech-stack:
  added: []
  patterns: [CoreAudio property listener with Unmanaged.passUnretained for lifecycle safety, callback chain propagation pattern]

key-files:
  created: []
  modified: [Sources/Coordinator/RecordingState.swift, Sources/Recording/SystemAudioCapture.swift, Sources/Recording/AudioRecorder.swift, Sources/Coordinator/RecordingCoordinator.swift, Tests/RecordingStateTests.swift]

key-decisions:
  - "deviceDisconnected reuses stopAndTranscribe side effect -- same outcome as meetingEnded, preserves recorded audio"
  - "Unmanaged.passUnretained(self) for property listener is safe because removeDeviceAliveListener is synchronous"
  - "@Sendable on onDeviceDisconnected callback for Swift 6 strict concurrency compliance"
  - "Capture callback reference before DispatchQueue.main.async to avoid sending non-Sendable self across isolation"

patterns-established:
  - "CoreAudio property listener pattern: register on create, remove in stop/cleanup before device destruction"
  - "Disconnect callback chain: hardware listener -> capture -> recorder -> coordinator -> state machine"

requirements-completed: [REC-05]

duration: 9min
completed: 2026-03-22
---

# Phase 09 Plan 02: Device Disconnection Handling Summary

**CoreAudio device alive listener detects mid-recording disconnect, propagates through AudioRecorder to RecordingCoordinator for graceful stop and transcription**

## Performance

- **Duration:** 9 min
- **Started:** 2026-03-22T11:45:00Z
- **Completed:** 2026-03-22T11:54:19Z
- **Tasks:** 2
- **Files modified:** 5

## Accomplishments
- State machine handles deviceDisconnected during recording with graceful stop (transitions to transcribing)
- CoreAudio kAudioDevicePropertyDeviceIsAlive listener on aggregate device detects hardware disconnect
- End-to-end callback chain from hardware event to state machine transition
- Listener properly removed during intentional stop to prevent re-entrant events
- All 137 tests pass including 4 new deviceDisconnected state tests

## Task Commits

Each task was committed atomically:

1. **Task 1: Add deviceDisconnected event to state machine with tests** - `b8a6cb7` (feat) -- TDD: tests + implementation
2. **Task 2: Device alive listener + wiring through AudioRecorder to Coordinator** - `3e03a59` (feat)

## Files Created/Modified
- `Sources/Coordinator/RecordingState.swift` - Added .deviceDisconnected event case and reduce handler
- `Sources/Recording/SystemAudioCapture.swift` - Added onDisconnect callback, registerDeviceAliveListener, removeDeviceAliveListener
- `Sources/Recording/AudioRecorder.swift` - Added @Sendable onDeviceDisconnected callback, wired systemCapture.onDisconnect
- `Sources/Coordinator/RecordingCoordinator.swift` - Wired recorder.onDeviceDisconnected to handle(.deviceDisconnected), clear on stop
- `Tests/RecordingStateTests.swift` - 4 new tests for deviceDisconnected in all state combinations

## Decisions Made
- deviceDisconnected reuses the existing stopAndTranscribe side effect -- same outcome as meetingEnded, preserves recorded audio and enqueues transcription
- Unmanaged.passUnretained(self) for the property listener (vs retained context pattern used by render callback) because removeDeviceAliveListener is synchronous -- no in-flight callbacks after removal
- @Sendable annotation on onDeviceDisconnected to satisfy Swift 6 strict concurrency when the callback crosses DispatchQueue.main.async boundary
- Capture callback reference before DispatchQueue.main.async to avoid sending non-Sendable AudioRecorder across isolation boundaries

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Swift 6 Sendability error on disconnect callback**
- **Found during:** Task 2 (wiring AudioRecorder disconnect callback)
- **Issue:** `self.onDeviceDisconnected?()` inside DispatchQueue.main.async sends non-Sendable AudioRecorder across isolation boundary
- **Fix:** Made onDeviceDisconnected `@Sendable`, capture callback reference before dispatch
- **Files modified:** Sources/Recording/AudioRecorder.swift
- **Verification:** Build succeeds, all 137 tests pass
- **Committed in:** `3e03a59` (Task 2 commit)

---

**Total deviations:** 1 auto-fixed (1 blocking)
**Impact on plan:** Swift 6 strict concurrency requirement -- fix was necessary for compilation. No scope creep.

## Issues Encountered
None beyond the auto-fixed Sendability issue above.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- Device disconnect handling is complete end-to-end
- After disconnect, state transitions to transcribing -> idle, allowing next meeting to record normally
- No stale state remains after disconnection

---
*Phase: 09-recording-resilience*
*Completed: 2026-03-22*

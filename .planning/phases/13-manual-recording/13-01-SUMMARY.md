---
phase: 13-manual-recording
plan: 01
subsystem: recording
tags: [state-machine, menu-bar, manual-recording, swiftui, tdd]

# Dependency graph
requires:
  - phase: 12-audio-capture-engine
    provides: AudioDeviceManager and device-aware AudioRecorder
provides:
  - manualStart/manualStop events in RecordingState machine
  - startManualRecording/stopManualRecording on RecordingCoordinator and AppState
  - Start Recording button in MenuBarView idle state
affects: [phase-16-calendar-triggered-recording, phase-17-calendar-ui]

# Tech tracking
tech-stack:
  added: []
  patterns: [manual recording reuses existing DetectedMeeting with app=Manual and processId=nil]

key-files:
  created: []
  modified:
    - Sources/Coordinator/RecordingState.swift
    - Sources/Coordinator/RecordingCoordinator.swift
    - Sources/App/AppState.swift
    - Sources/UI/MenuBar/MenuBarView.swift
    - Tests/RecordingStateTests.swift
    - Tests/RecordingCoordinatorTests.swift

key-decisions:
  - "manualStart creates DetectedMeeting(app: Manual, processId: nil) -- reuses entire existing pipeline with zero changes"
  - "Stop button reuses existing stopRecording/meetingEnded path -- manualStop and meetingEnded do identical transitions"

patterns-established:
  - "Manual recording pattern: new event types + DetectedMeeting facade, no pipeline changes needed"

requirements-completed: [REC-01, REC-02, REC-03]

# Metrics
duration: 26min
completed: 2026-03-24
---

# Phase 13 Plan 01: Manual Recording Summary

**Manual start/stop recording via menu bar using new RecordingState events and DetectedMeeting(app: "Manual", processId: nil) facade**

## Performance

- **Duration:** 26 min
- **Started:** 2026-03-24T12:26:11Z
- **Completed:** 2026-03-24T12:53:00Z
- **Tasks:** 2
- **Files modified:** 6

## Accomplishments
- manualStart(title:) and manualStop events added to RecordingEvent with full state machine transitions
- Manual recordings flow through existing pipeline (DB insert, recording, transcription) with zero changes to existing code paths
- Menu bar shows "Start Recording" button with record.circle icon when idle
- 6 new tests (4 state machine + 2 coordinator) all pass

## Task Commits

Each task was committed atomically:

1. **Task 1: Manual recording state machine + coordinator method (TDD)** - `1449f99` (test: RED) + `53f9fac` (feat: GREEN)
2. **Task 2: Menu bar Start/Stop Recording UI** - `188cc12` (feat)

## Files Created/Modified
- `Sources/Coordinator/RecordingState.swift` - Added manualStart/manualStop events and reduce transitions
- `Sources/Coordinator/RecordingCoordinator.swift` - Added startManualRecording/stopManualRecording convenience methods
- `Sources/App/AppState.swift` - Added startManualRecording/stopManualRecording UI actions with title setting
- `Sources/UI/MenuBar/MenuBarView.swift` - Added Start Recording button in idle state
- `Tests/RecordingStateTests.swift` - 4 new tests for manual recording state transitions
- `Tests/RecordingCoordinatorTests.swift` - 2 new tests for coordinator manual recording

## Decisions Made
- manualStart creates DetectedMeeting with app="Manual", title from parameter, processId=nil -- this reuses the entire existing executeStartRecording pipeline (DB insert, recorder.start, notifications) with zero changes
- Stop button uses existing stopRecording() path (sends .meetingEnded) since manualStop and meetingEnded produce identical transitions -- simpler, no behavioral difference
- AppState.startManualRecording() sets currentMeetingTitle eagerly before async coordinator call so menu bar immediately shows "Manual Recording"

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
- Worktree was behind origin/main and missing Phase 11-12 changes (AudioDeviceManager, DiarizationEngine API fix) -- merged worktree branches to get required dependencies
- Pre-existing test failure in testTranscriptionCompleteTransitionsToIdle (duplicate enqueue guard) unrelated to manual recording changes

## Known Stubs

None - all data flows are wired end-to-end through existing pipeline.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- Manual recording fully functional through existing pipeline
- Calendar-triggered recording (Phase 16) can reuse the same DetectedMeeting pattern with app="Calendar"
- No blockers

## Self-Check: PASSED

All 6 modified files verified present. All 3 task commits verified in git log (1449f99, 53f9fac, 188cc12).

---
*Phase: 13-manual-recording*
*Completed: 2026-03-24*

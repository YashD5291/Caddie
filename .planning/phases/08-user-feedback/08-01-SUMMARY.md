---
phase: 08-user-feedback
plan: 01
subsystem: data-model
tags: [observable, swiftui, actor, callback, recording-mode, pipeline-step]

requires:
  - phase: 04-coordinator
    provides: RecordingCoordinator actor with onStateChange callback pattern
provides:
  - RecordingMode enum (systemAndMic, micOnly) surfaced from AudioRecorder
  - PipelineStep enum (idle, mixdown, transcribing, diarizing, compressing) surfaced from TranscriptionPipeline
  - AppState observable properties for recordingMode and pipelineStep
  - Callback wiring pattern for threading data from deep components to AppState
affects: [08-02, ui, menu-bar]

tech-stack:
  added: []
  patterns: [separate-callback-per-concern, step-change-reporting]

key-files:
  created: []
  modified:
    - Sources/Recording/AudioRecorder.swift
    - Sources/App/AppState.swift
    - Sources/Coordinator/RecordingCoordinator.swift
    - Sources/Transcription/TranscriptionPipeline.swift

key-decisions:
  - "Separate callbacks (onRecordingModeChange, onPipelineStepChange) instead of modifying onStateChange signature -- simpler, no breaking changes"
  - "nonisolated(unsafe) let for capturing callback in actor's start() -- avoids Sendable complexity for callback forwarding"

patterns-established:
  - "Step change callback: pipeline reports current step via @Sendable closure, coordinator forwards to AppState"
  - "Recording mode propagation: AudioRecorder sets mode based on system audio capture success/failure"

requirements-completed: [UX-01, UX-02, UX-04]

duration: 5min
completed: 2026-03-22
---

# Phase 08 Plan 01: Data Model Summary

**RecordingMode and PipelineStep enums threaded from AudioRecorder/TranscriptionPipeline through RecordingCoordinator to AppState as observable properties**

## Performance

- **Duration:** 5 min
- **Started:** 2026-03-22T11:40:25Z
- **Completed:** 2026-03-22T11:45:00Z
- **Tasks:** 2
- **Files modified:** 4

## Accomplishments
- RecordingMode enum with systemAndMic/micOnly cases, set based on system audio capture outcome
- PipelineStep enum with idle/mixdown/transcribing/diarizing/compressing cases, reported before each pipeline step
- Full callback wiring: AudioRecorder -> RecordingCoordinator -> AppState (recordingMode) and TranscriptionPipeline -> RecordingCoordinator -> AppState (pipelineStep)
- All values reset to defaults on idle transition

## Task Commits

Each task was committed atomically:

1. **Task 1: Add RecordingMode enum and surface from AudioRecorder** - `5e794f6` (feat)
2. **Task 2: Thread recording mode and pipeline step through coordinator to AppState** - `bd2bc75` (feat)

## Files Created/Modified
- `Sources/Recording/AudioRecorder.swift` - RecordingMode enum, private(set) property set on system audio success/failure, reset on stop
- `Sources/App/AppState.swift` - PipelineStep enum, observable recordingMode and pipelineStep properties, reset on idle
- `Sources/Coordinator/RecordingCoordinator.swift` - onRecordingModeChange and onPipelineStepChange callbacks, pipeline step wiring in start()
- `Sources/Transcription/TranscriptionPipeline.swift` - onStepChange callback, step reporting before each major pipeline step

## Decisions Made
- Used separate callbacks (onRecordingModeChange, onPipelineStepChange) instead of modifying onStateChange signature to avoid breaking the existing API
- Used nonisolated(unsafe) for capturing the step callback in the actor's start() method -- the callback is set before start() and not mutated after

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Data model complete, Plan 02 can now read recordingMode and pipelineStep from AppState
- All callback wiring tested via successful build

---
*Phase: 08-user-feedback*
*Completed: 2026-03-22*

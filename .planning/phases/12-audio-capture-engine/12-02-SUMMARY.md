---
phase: 12-audio-capture-engine
plan: 02
subsystem: recording
tags: [CoreAudio, HAL AudioUnit, device-routing, process-tap, SystemAudioCapture, AudioRecorder, RecordingCoordinator]

# Dependency graph
requires:
  - phase: 12-01
    provides: MicrophoneCapture HAL AudioUnit path with start(deviceUID:onBuffer:)
  - phase: 11-01
    provides: AudioDeviceManager with selectedDeviceUID
provides:
  - SystemAudioCapture direct device capture via start(deviceUID:onBuffer:)
  - AudioRecorder device UID routing with default nil backward compatibility
  - RecordingCoordinator AudioDeviceManager integration for device passthrough
affects: [Settings device picker now flows through to actual audio capture]

# Tech tracking
tech-stack:
  added: []
  patterns: [dual-start-path via overload on SystemAudioCapture, device UID routing with default nil params]

key-files:
  created:
    - Tests/SystemAudioCaptureDeviceTests.swift
    - Tests/AudioRecorderDeviceRoutingTests.swift
  modified:
    - Sources/Recording/SystemAudioCapture.swift
    - Sources/Recording/AudioRecorder.swift
    - Sources/Coordinator/RecordingCoordinator.swift
    - Sources/App/AppState.swift
    - Tests/RecordingCoordinatorTests.swift

key-decisions:
  - "Raw CoreAudio AudioValueTranslation for UID resolution (same approach as MicrophoneCapture in 12-01) instead of SimplyCoreAudio AudioDevice.lookup"
  - "Default nil parameters on AudioRecorder.start() ensure all existing callers compile without changes"
  - "processID + systemDeviceUID conflict throws RecorderError.conflictingAudioSources rather than silently preferring one"
  - "RecordingCoordinator reads selectedDeviceUID via MainActor.run since AudioDeviceManager is @MainActor"
  - "When auto-detected meeting has processId, system audio keeps process tap (more accurate); only mic uses device UID"

patterns-established:
  - "Dual start path on SystemAudioCapture mirrors MicrophoneCapture pattern from 12-01"
  - "Device alive listener for direct devices (not just aggregate devices)"

requirements-completed: [AUD-03]

# Metrics
duration: 35min
completed: 2026-03-24
---

# Phase 12 Plan 02: SystemAudioCapture Device Path + Device UID Routing Summary

**Direct device capture for SystemAudioCapture, device UID routing through AudioRecorder and RecordingCoordinator completing the full device selection pipeline**

## Performance

- **Duration:** 35 min
- **Started:** 2026-03-24T11:28:44Z
- **Completed:** 2026-03-24T12:04:13Z
- **Tasks:** 2 (Task 1: TDD RED+GREEN, Task 2: auto)
- **Files modified:** 7 (2 created, 5 modified)

## Accomplishments
- SystemAudioCapture with dual start paths: `start(processID:onBuffer:)` for v1.0 process tap, `start(deviceUID:onBuffer:)` for direct HAL AudioUnit device capture
- Raw CoreAudio UID-to-AudioDeviceID resolution via AudioValueTranslation (no SimplyCoreAudio dependency)
- Device alive listener registered on direct devices for disconnect detection
- AudioRecorder accepts optional systemDeviceUID/micDeviceUID parameters with nil defaults for backward compatibility
- Conflicting processID + systemDeviceUID validated and rejected with clear error
- RecordingCoordinator reads AudioDeviceManager selection and routes UIDs to AudioRecorder
- AppState passes AudioDeviceManager to RecordingCoordinator
- Full pipeline: Settings device picker -> AudioDeviceManager -> RecordingCoordinator -> AudioRecorder -> SystemAudioCapture/MicrophoneCapture
- 9 new tests (4 SystemAudioCapture, 3 AudioRecorder, 2 RecordingCoordinator), 160 total tests (159 pass, 1 pre-existing failure)

## Task Commits

Each task was committed atomically:

1. **Task 1 RED: SystemAudioCapture + AudioRecorder tests** - `b17485c` (test)
2. **Task 1 GREEN: SystemAudioCapture device path + AudioRecorder routing** - `e8917b5` (feat)
3. **Task 2: RecordingCoordinator device UID passthrough** - `2f745df` (feat)

## Files Created/Modified
- `Tests/SystemAudioCaptureDeviceTests.swift` - 4 tests: invalid UID error, cleanup safety, error description, v1.0 regression
- `Tests/AudioRecorderDeviceRoutingTests.swift` - 3 tests: new signature, default params, conflicting sources
- `Sources/Recording/SystemAudioCapture.swift` - Added direct device capture path, UID resolution, device alive listener, CaptureError.deviceNotFound
- `Sources/Recording/AudioRecorder.swift` - Added systemDeviceUID/micDeviceUID params, routing logic, RecorderError.conflictingAudioSources
- `Sources/Coordinator/RecordingCoordinator.swift` - Added AudioDeviceManager dependency, device UID passthrough in executeStartRecording
- `Sources/App/AppState.swift` - Passes audioDeviceManager to RecordingCoordinator init
- `Tests/RecordingCoordinatorTests.swift` - 2 new tests: audioDeviceManager acceptance, default init compilation

## Decisions Made
- Used raw CoreAudio `kAudioHardwarePropertyDeviceForUID` with `AudioValueTranslation` for UID resolution, consistent with MicrophoneCapture's approach from Plan 12-01.
- Default nil parameters on AudioRecorder.start() preserve full backward compatibility -- zero changes needed in existing callers.
- processID + systemDeviceUID conflict throws explicitly rather than silently preferring one, preventing user confusion about which audio source is active.
- When auto-detected meetings have a processId, system audio still uses process tap (more accurate for app-specific audio) while microphone uses the selected device. This gives the best audio quality for each channel.

## Deviations from Plan

None -- plan executed exactly as written.

## Issues Encountered
- `testTranscriptionCompleteTransitionsToIdle` has a pre-existing failure from DATA-07 duplicate enqueue guard. Not related to this plan's changes. 0 unexpected failures.

## User Setup Required
None - no external service configuration required.

## Known Stubs
None - all code paths are fully wired from AudioDeviceManager through to actual audio capture.

## Self-Check: PASSED

- Files: All 8 key files exist (2 new test files, 4 modified source files, 1 modified test file, SUMMARY)
- Commits: All 3 commits found (b17485c RED, e8917b5 GREEN, 2f745df feat)
- Tests: 160/160 executed, 159 pass (1 pre-existing failure unrelated to this plan)

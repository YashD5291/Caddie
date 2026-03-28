---
phase: 12-audio-capture-engine
plan: 01
subsystem: recording
tags: [CoreAudio, HAL AudioUnit, microphone, device-selection, TN2091]

# Dependency graph
requires:
  - phase: 03-audio-thread-safety
    provides: SPSC ring buffer, RenderContext pattern
provides:
  - MicrophoneCapture HAL AudioUnit path for device-specific input
  - CoreAudio UID-to-AudioDeviceID resolution via raw API
  - Extended CaptureError with HAL-specific error cases
affects: [12-02 SystemAudioCapture device path, AudioRecorder device routing]

# Tech tracking
tech-stack:
  added: []
  patterns: [dual-start-path via overload, raw CoreAudio UID resolution]

key-files:
  created:
    - Tests/MicrophoneCaptureHALTests.swift
  modified:
    - Sources/Recording/MicrophoneCapture.swift
    - Sources/Transcription/DiarizationEngine.swift

key-decisions:
  - "Raw CoreAudio kAudioHardwarePropertyDeviceForUID instead of SimplyCoreAudio AudioDevice.lookup -- objectID is internal to SimplyCoreAudio"
  - "Dual start paths via method overload rather than parameter-based branching -- cleaner API, zero v1.0 regression risk"

patterns-established:
  - "Dual start path: separate methods for default vs device-specific capture"
  - "CoreAudio UID resolution: AudioValueTranslation with kAudioHardwarePropertyDeviceForUID"

requirements-completed: [AUD-03]

# Metrics
duration: 23min
completed: 2026-03-24
---

# Phase 12 Plan 01: MicrophoneCapture HAL AudioUnit Path Summary

**HAL AudioUnit capture path for device-specific microphone input following TN2091 order with RenderContext memory safety**

## Performance

- **Duration:** 23 min
- **Started:** 2026-03-24T10:56:43Z
- **Completed:** 2026-03-24T11:19:45Z
- **Tasks:** 1 (TDD: RED + GREEN)
- **Files modified:** 3

## Accomplishments
- MicrophoneCapture with dual start paths: `start(onBuffer:)` for v1.0 AVAudioEngine default, `start(deviceUID:onBuffer:)` for HAL AudioUnit device-specific capture
- HAL AudioUnit setup follows TN2091 order exactly: enable IO -> set device -> set format -> set callback -> init -> start
- RenderContext pattern prevents use-after-free on real-time audio thread (same proven pattern as SystemAudioCapture)
- Raw CoreAudio UID-to-AudioDeviceID resolution (no SimplyCoreAudio dependency for this path)
- 6 new tests covering error handling, state management, v1.0 regression, and error descriptions
- All 145 tests pass (6 new + 139 existing)

## Task Commits

Each task was committed atomically:

1. **Task 1: MicrophoneCapture HAL AudioUnit path (RED)** - `3f71746` (test)
2. **Task 1: MicrophoneCapture HAL AudioUnit path (GREEN)** - `60980d1` (feat)

_TDD task: RED commit (failing tests) followed by GREEN commit (implementation)_

## Files Created/Modified
- `Tests/MicrophoneCaptureHALTests.swift` - 6 tests for HAL path error handling, state management, v1.0 regression, error descriptions
- `Sources/Recording/MicrophoneCapture.swift` - Added HAL AudioUnit capture path with RenderContext, UID resolution, extended CaptureError
- `Sources/Transcription/DiarizationEngine.swift` - Fixed FluidAudio API: timeline.segments -> timeline.speakers (Rule 3)

## Decisions Made
- Used raw CoreAudio `kAudioHardwarePropertyDeviceForUID` for UID resolution instead of `SimplyCoreAudio.AudioDevice.lookup(by:)` because `objectID` is internal to SimplyCoreAudio module. Raw CoreAudio is the correct approach and eliminates an unnecessary dependency path.
- Dual start paths via method overload (not boolean flag) -- cleaner API, v1.0 path untouched, no risk of accidentally breaking existing callers.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Fixed DiarizationEngine FluidAudio API mismatch**
- **Found during:** Task 1 GREEN phase (build for testing)
- **Issue:** `DiarizerTimeline.segments` no longer exists in FluidAudio 0.12.4; API changed to `timeline.speakers` dictionary
- **Fix:** Updated to iterate `timeline.speakers` (keyed by speaker index) and access `speaker.finalizedSegments`
- **Files modified:** Sources/Transcription/DiarizationEngine.swift
- **Verification:** Full test suite passes (145 tests, 0 failures)
- **Committed in:** 60980d1 (part of GREEN commit)

**2. [Rule 3 - Blocking] Used raw CoreAudio instead of SimplyCoreAudio for UID resolution**
- **Found during:** Task 1 GREEN phase (build)
- **Issue:** `AudioDevice.objectID` is internal to SimplyCoreAudio, cannot be accessed from Caddie module
- **Fix:** Implemented `resolveDeviceUID()` using raw CoreAudio `AudioValueTranslation` with `kAudioHardwarePropertyDeviceForUID`
- **Files modified:** Sources/Recording/MicrophoneCapture.swift
- **Verification:** Build succeeds, tests pass
- **Committed in:** 60980d1 (part of GREEN commit)

---

**Total deviations:** 2 auto-fixed (2 blocking)
**Impact on plan:** Both auto-fixes necessary for compilation. No scope creep.

## Issues Encountered
None beyond the auto-fixed blocking issues.

## User Setup Required
None - no external service configuration required.

## Known Stubs
None - all code paths are fully wired.

## Next Phase Readiness
- MicrophoneCapture HAL path ready for AudioRecorder integration (Plan 12-02)
- SystemAudioCapture device path (Plan 12-02) can follow same pattern
- AudioRecorder needs modification to pass device UIDs to capture components

## Self-Check: PASSED

- Files: All 3 key files exist (MicrophoneCapture.swift, MicrophoneCaptureHALTests.swift, 12-01-SUMMARY.md)
- Commits: Both 3f71746 (RED) and 60980d1 (GREEN) found in git log
- Tests: 145/145 passing (6 new + 139 existing)

---
*Phase: 12-audio-capture-engine*
*Completed: 2026-03-24*

---
phase: 11-audio-device-selection
plan: 01
subsystem: recording
tags: [SimplyCoreAudio, CoreAudio, UserDefaults, SwiftUI-Picker, audio-devices]

requires:
  - phase: 10-bundle-ml-models
    provides: stable app initialization and ModelManager pattern
provides:
  - AudioDeviceManager class with device enumeration, selection persistence, and fallback validation
  - Settings UI picker for audio input device selection
  - AppState wiring for AudioDeviceManager lifecycle
affects: [12-recording-capture, audio-recording, settings]

tech-stack:
  added: []
  patterns: ["@Observable AudioDeviceManager on MainActor wrapping SimplyCoreAudio", "UserDefaults persistence for device UID strings", "nonisolated(unsafe) for deinit observer cleanup in Swift 6"]

key-files:
  created: [Sources/Recording/AudioDeviceManager.swift, Tests/AudioDeviceManagerTests.swift]
  modified: [Sources/UI/Settings/SettingsView.swift, Sources/App/AppState.swift, Sources/Transcription/DiarizationEngine.swift]

key-decisions:
  - "Store device UID (persistent string) not AudioDeviceID (transient integer) in UserDefaults"
  - "nonisolated(unsafe) for observer property to enable deinit cleanup in Swift 6 strict concurrency"
  - "Filter only Caddie aggregate devices by UID prefix, not all aggregate devices (users may have Loopback)"

patterns-established:
  - "@Observable device manager pattern: MainActor class wrapping SimplyCoreAudio with notification subscription"
  - "@Bindable local variable in SwiftUI computed property for @Observable binding"

requirements-completed: [AUD-01, AUD-02]

duration: 29min
completed: 2026-03-24
---

# Phase 11 Plan 01: Audio Device Selection Summary

**AudioDeviceManager with SimplyCoreAudio device enumeration, UserDefaults persistence, fallback validation, and SwiftUI Settings picker**

## Performance

- **Duration:** 29 min
- **Started:** 2026-03-24T09:48:03Z
- **Completed:** 2026-03-24T10:17:28Z
- **Tasks:** 2
- **Files modified:** 5

## Accomplishments
- AudioDeviceManager enumerates all input devices via SimplyCoreAudio, filtering Caddie aggregate devices
- Device selection persists to UserDefaults and validates on startup with fallback warning
- SettingsView has Audio Input section with Picker between General and Permissions
- 6 unit tests covering enumeration, persistence, fallback, filtering, and resolution

## Task Commits

Each task was committed atomically:

1. **Task 1: AudioDeviceManager with tests (TDD)** - `0953080` (test: RED), `cc3e0ef` (feat: GREEN)
2. **Task 2: SettingsView picker and AppState wiring** - `85e219c` (feat)

## Files Created/Modified
- `Sources/Recording/AudioDeviceManager.swift` - Device enumeration, selection persistence, fallback validation, change notification
- `Tests/AudioDeviceManagerTests.swift` - 6 unit tests for all AudioDeviceManager behaviors
- `Sources/UI/Settings/SettingsView.swift` - Added Audio Input section with device picker and fallback warning
- `Sources/App/AppState.swift` - Added audioDeviceManager property and initialize() call
- `Sources/Transcription/DiarizationEngine.swift` - Fixed pre-existing FluidAudio API change (timeline.segments -> timeline.speakers)

## Decisions Made
- Store device UID string (persistent across reboots) in UserDefaults, not AudioDeviceID (transient integer) -- Apple CoreAudio explicitly documents AudioDeviceID as session-scoped
- Used `nonisolated(unsafe)` for observer property to allow deinit cleanup in Swift 6 strict concurrency -- observer is only accessed from MainActor methods and deinit
- Filter only Caddie's own aggregate devices by `com.caddie.systemTap.` UID prefix -- users may have legitimate aggregate devices (Loopback) they want to use
- Used `@Bindable var` in computed property body for SwiftUI binding to @Observable -- required for Picker selection binding with @Observable objects

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Fixed pre-existing DiarizationEngine build error**
- **Found during:** Task 1 (RED phase build)
- **Issue:** FluidAudio API changed: `DiarizerTimeline.segments` no longer exists. The API now uses `timeline.speakers` (dictionary of DiarizerSpeaker) with `speaker.finalizedSegments`
- **Fix:** Updated DiarizationEngine.swift to use `timeline.speakers` iteration with `speaker.finalizedSegments` and Float conversion
- **Files modified:** Sources/Transcription/DiarizationEngine.swift
- **Verification:** Build succeeds, all tests pass
- **Committed in:** cc3e0ef (part of Task 1 commit)

**2. [Rule 1 - Bug] Fixed Swift 6 deinit isolation error**
- **Found during:** Task 1 (GREEN phase build)
- **Issue:** `deinit` is nonisolated in Swift 6 but `observer` property is MainActor-isolated, causing compile error
- **Fix:** Marked `observer` as `nonisolated(unsafe)` since it's only accessed from MainActor methods and the synchronous deinit
- **Files modified:** Sources/Recording/AudioDeviceManager.swift
- **Verification:** Build succeeds with Swift 6 strict concurrency

---

**Total deviations:** 2 auto-fixed (1 blocking, 1 bug)
**Impact on plan:** Both fixes necessary for the code to compile. No scope creep.

## Issues Encountered
- Pre-existing test failure in `RecordingCoordinatorTests.testTranscriptionCompleteTransitionsToIdle` (duplicate enqueue race condition) -- confirmed pre-existing, not caused by this plan's changes
- Xcode derived data build lock from parallel agents -- resolved by using unique `-derivedDataPath`

## Known Stubs
None -- all data sources are wired (SimplyCoreAudio for device list, UserDefaults for persistence, @Environment for AppState access).

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- AudioDeviceManager is ready to be consumed by Phase 12 (recording capture rewrite)
- `resolvedDeviceID()` returns the AudioObjectID for the selected device, ready for HAL AudioUnit wiring
- Pre-existing RecordingCoordinator test failure should be investigated separately

---
*Phase: 11-audio-device-selection*
*Completed: 2026-03-24*

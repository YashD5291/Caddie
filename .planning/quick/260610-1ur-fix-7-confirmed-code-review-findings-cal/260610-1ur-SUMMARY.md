---
phase: quick-260610-1ur
plan: 01
subsystem: [calendar, recording, ui]
tags: [google-calendar, notifications, coreaudio, avaudioconverter, swiftui, state-machine]

requires:
  - phase: v2.0 Google Calendar + Remote Meeting Recording
    provides: GoogleCalendarService, NotificationManager prompt flow, AudioRecorder switchDevice, RecordingState reducer, LoadingOverlay
provides:
  - Lost calendar signal recovery when onSignal is wired late (model-load window)
  - End-to-end dismiss mechanism for meeting prompts with stable per-event notification identifier
  - Title preservation through the Record notification action
  - WAV finalization on switchDevice double-failure (no lost samples / orphaned timer)
  - Realtime-thread allocation removal in both render callbacks (reused PCM buffers)
  - User-surfaced recording errors and absorbed terminal events in .error state
  - Cancellable LoadingOverlay phrase-cycling task
affects: [calendar, notifications, recording, audio-capture, recording-state-machine, ui]

tech-stack:
  added: []
  patterns:
    - "Preallocated realtime-audio buffers on a retained RenderContext with oversized-frame fallback"
    - "State-machine absorption of unconditional terminal-failure callback events"
    - "SwiftUI .task(id:) for self-cancelling animation loops instead of orphaned Task"

key-files:
  created: []
  modified:
    - Sources/Calendar/GoogleCalendarService.swift
    - Sources/Utilities/NotificationManager.swift
    - Sources/App/CaddieApp.swift
    - Sources/App/AppState.swift
    - Sources/Detection/MeetingPatterns.swift
    - Sources/Detection/MeetingDetector.swift
    - Sources/Coordinator/RecordingCoordinator.swift
    - Sources/Coordinator/RecordingState.swift
    - Sources/Recording/AudioRecorder.swift
    - Sources/Recording/MicrophoneCapture.swift
    - Sources/Recording/SystemAudioCapture.swift
    - Sources/UI/MenuBar/MenuBarView.swift
    - Sources/UI/MainWindow/LoadingOverlay.swift
    - Tests/GoogleCalendarServiceTests.swift
    - Tests/NotificationManagerTests.swift
    - Tests/AudioRecorderDeviceRoutingTests.swift
    - Tests/SystemAudioCaptureTests.swift
    - Tests/RecordingStateTests.swift

key-decisions:
  - "checkActiveEvents only consumes lastActiveEventID when onSignal is non-nil, so an event active during the model-load startup window re-fires exactly once after wiring"
  - "Threaded calendarEventID through DetectionSignal -> MeetingDetector.onMeetingPrompt rather than restructuring the prompt, keeping the dismiss key (event.id) available end-to-end"
  - "Absorbed terminal-failure events in .error preserve the ORIGINAL error (first failure wins) and emit no side effect"
  - "Preallocated PCM buffers sized via a shared, unit-tested SystemAudioCapture.outputCapacity helper; oversized slices fall back to a one-off allocation rather than dropping audio"

patterns-established:
  - "Realtime callback buffer reuse: RenderContext holds inputPCM/outputPCM preallocated at maxFrames (4096); callbacks reset frameLength and reuse, allocating only on the rare oversized slice"
  - "Reducer absorption: events that can legitimately arrive in a terminal state return (state, nil) instead of nil to suppress spurious Invalid-transition logs"

requirements-completed: [CR-01, CR-02, CR-03, CR-04, CR-05, CR-06, CR-07]

duration: 13min
completed: 2026-06-10
---

# Quick 260610-1ur: Fix 7 Confirmed Code-Review Findings Summary

**Eliminated silent failures across calendar/notifications, recording/audio, and UI/state: recovered a lost calendar signal, finalized WAVs on a device double-failure, removed realtime-thread allocations, surfaced masked recording errors, killed a leaked overlay task, and wired the dead dismiss mechanism end-to-end.**

## Performance

- **Duration:** ~13 min
- **Tasks:** 3 / 3
- **Files modified:** 18 (13 source, 5 test)
- **Commits:** 3 (one per task), no Co-Authored-By lines

## Accomplishments

### Task 1 — Calendar signal loss, notification title drop, dead dismiss (commit 0862b5a)
- **Finding 1 (signal loss):** `GoogleCalendarService.checkActiveEvents` now guards on `onSignal != nil` before recording `lastActiveEventID`. An event active during the model-load window no longer gets silently consumed; once `setOnSignal` wires the callback, it fires exactly once.
- **Finding 7 (dismiss + stacking):** `checkActiveEvents` skips events in `dismissedEventIDs`. `NotificationManager.promptToRecord(eventTitle:eventID:)` now sets `userInfo["eventID"]` and uses a deterministic `promptIdentifier(eventID:)` (`com.caddie.meeting-prompt-<eventID>`) so re-fired prompts replace rather than stack. `CaddieApp` `dismissAction` reads the eventID and calls `dismissEvent`.
- **Finding 3 (title drop):** `CaddieApp` `recordAction` now calls `startManualRecording(title:)` (which sets `currentMeetingTitle` itself); the redundant manual assignment was removed.
- Added `calendarEventID` to `DetectionSignal` (with a back-compatible default-nil init) and threaded it through `MeetingDetector.onMeetingPrompt` and `RecordingCoordinator.setOnMeetingPrompt`.

### Task 2 — WAV finalization + realtime allocations (commit 42eec43)
- **Finding 2 (switchDevice double-failure):** Extracted `AudioRecorder.finalizeRecording()` shared by `stop()` and the double-failure branch. The double-failure path now cancels the flush timer, drains the ring buffer, and disposes the WAV before firing `onDeviceDisconnected`; the coordinator's later `stop()` safely no-ops via the `isRecording` guard.
- **Finding 6 (realtime allocations):** Both `RenderContext`s preallocate reusable `inputPCM`/`outputPCM` buffers (sized at `maxFrames = 4096` via the new `SystemAudioCapture.outputCapacity` helper). The mic and system render callbacks reuse them, only allocating on the rare oversized-frame fallback (never dropping audio).

### Task 3 — Error surfacing, terminal absorption, overlay task (commit cfc4cad)
- **Finding 4 (masked error + reducer gaps):** Added `AppState.lastRecordingError`, set from the `.error` state's associated error and surfaced in `MenuBarView` (idle status) with a dismiss button; cleared on the next successful recording start. The idle UX gate is preserved. `RecordingState.reduce` now absorbs `(.error, deviceDisconnected/transcriptionFailed/recordingFailed)`, returning the original error and no side effect — ending spurious "Invalid transition" logs.
- **Finding 5 (leaked overlay task):** Moved `LoadingOverlay`'s phrase-cycling loop from an orphaned unstructured `Task` to a `.task(id:)` modifier so it is cancelled on overlay removal; corrected the stale "DispatchQueue rather than a Timer" comment.

## Tests

- 11 new/updated tests across `GoogleCalendarServiceTests`, `NotificationManagerTests`, `AudioRecorderDeviceRoutingTests`, `SystemAudioCaptureTests`, `RecordingStateTests`.
- TDD: failing tests written before each implementation. One existing test (`testErrorDeviceDisconnectedIsInvalid`) was replaced by `testErrorDeviceDisconnectedIsAbsorbed` to reflect the corrected behavior.
- Full suite green: `** TEST SUCCEEDED **` after every task.

## Deviations from Plan

### Auto-added critical functionality

**1. [Rule 2 - Missing functionality] Threaded `calendarEventID` through the detection layer**
- **Found during:** Task 1.
- **Issue:** The plan's Finding 7 requires the eventID to reach `promptToRecord`/`dismissEvent`, but `DetectionSignal` and `MeetingDetector.onMeetingPrompt` only carried the display title — the event.id (the dismiss key) was unavailable at the prompt call site. Files `MeetingPatterns.swift`, `MeetingDetector.swift`, and `RecordingCoordinator.swift` were not in `files_modified`.
- **Fix:** Added an optional `calendarEventID` field to `DetectionSignal` (with a default-nil memberwise-equivalent init so all existing call sites compile unchanged), emitted it from `checkActiveEvents`, and widened `onMeetingPrompt`/`setOnMeetingPrompt` to `(_ title: String, _ eventID: String?)`. `AppState` passes the eventID into `promptToRecord` (falling back to the title only if a future non-calendar source ever drives the path).
- **Files modified:** Sources/Detection/MeetingPatterns.swift, Sources/Detection/MeetingDetector.swift, Sources/Coordinator/RecordingCoordinator.swift
- **Commit:** 0862b5a

**2. [Rule 2 - Test support] Added `injectCachedEvents`/`isDismissed` to GoogleCalendarService**
- **Found during:** Task 1.
- **Issue:** Unit-testing `checkActiveEvents` (an actor method reading the in-memory cache) without a live network fetch required a seam.
- **Fix:** Added small actor methods `injectCachedEvents(_:)` and `isDismissed(_:)` for tests; no production behavior change.
- **Commit:** 0862b5a

### Pre-existing uncommitted work folded into commits

Per the task constraints, several touched source files already carried uncommitted branch modifications (`AudioRecorder.swift`, `MicrophoneCapture.swift`, `SystemAudioCapture.swift`, `AppState.swift`, `CaddieApp.swift`, `NotificationManager.swift`, `GoogleCalendarService.swift`, `RecordingCoordinator.swift`, `RecordingState.swift`, `MeetingDetector.swift`, `MenuBarView.swift`, and the five test files). Those pre-existing changes were necessarily included in the per-task commits for those files. No unrelated files were staged, reverted, or stashed; the remaining branch work (GoogleAuthManager, ASREngine, Settings/Onboarding views, project.yml, scripts, etc.) is untouched and still uncommitted.

## Known Stubs

None. The `promptToRecord` title-fallback for a non-calendar source is a defensive default, not a stub — the only current driver (calendar) always supplies an eventID.

## Deferred Issues

Pre-existing `variable 'native' was never mutated` warnings in `SystemAudioCaptureTests` (in unmodified test code) are out of scope and were left untouched.

## Self-Check: PASSED

- SUMMARY.md created at the required path.
- Commits verified: 0862b5a, 42eec43, cfc4cad all present in `git log`.
- All modified source/test files present on disk and committed.
- `make test` reports `** TEST SUCCEEDED **`.
- Spot-checks: no per-callback `AVAudioPCMBuffer(` allocation outside fallback paths; `meeting-prompt-` stable identifier present; `startManualRecording(title:)` used in `recordAction`.

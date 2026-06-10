---
phase: quick-260610-p4w
plan: 01
subsystem: calendar-detection + ui
tags: [calendar, notifications, detection, sign-in, ui-scoping]
requires:
  - GoogleCalendarService.onSignal -> RecordingCoordinator.forwardSignal -> MeetingDetector.handleSignal
provides:
  - "Live calendar->notification prompt path (lone .googleCalendar signal fires onMeetingPrompt)"
  - "Per-event prompt de-dup with sign-out teardown"
  - "Signed-out access to local recordings; scoped sidebar sign-in card"
affects:
  - Sources/Detection/MeetingDetector.swift
  - Sources/Calendar/GoogleCalendarService.swift
  - Sources/Utilities/NotificationManager.swift
  - Sources/App/CaddieApp.swift
  - Sources/Coordinator/RecordingCoordinator.swift
  - Sources/UI/MainWindow/ContentView.swift
  - Sources/UI/MainWindow/MeetingListView.swift
tech-stack:
  added: []
  patterns:
    - "Special-case bypass of DecisionEngine for single-source calendar signals"
    - "Deactivating-signal teardown to clear cross-actor detector state on sign-out"
key-files:
  created: []
  modified:
    - Sources/Detection/MeetingDetector.swift
    - Tests/MeetingDetectorTests.swift
    - Sources/Calendar/GoogleCalendarService.swift
    - Sources/Utilities/NotificationManager.swift
    - Sources/App/CaddieApp.swift
    - Sources/Coordinator/RecordingCoordinator.swift
    - Sources/UI/MainWindow/ContentView.swift
    - Sources/UI/MainWindow/MeetingListView.swift
    - README.md
    - project.yml
decisions:
  - "Calendar signals bypass the >=2-signal DecisionEngine entirely; DecisionEngine left untouched for the dormant multi-signal path"
  - "Debug-only CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION to work around immovable provenance xattr; Release keeps strict packaging"
metrics:
  tasks: 2
  files: 10
  duration: ~15m
  completed: 2026-06-10
requirements: [CAL-02, ONB-01]
---

# Phase quick-260610-p4w: Fix broken calendar notification prompt + scope sign-in gate Summary

Restored the only working calendar-trigger path (a lone Google Calendar event now fires the record-or-dismiss notification) and stopped locking signed-out users out of their local recordings, surfacing the sign-in requirement only in the sidebar's schedule region.

## What Was Built

**Task 1 — CAL-02, calendar prompt path (TDD).** `MeetingDetector.handleSignal` now special-cases `.googleCalendar` signals before the `DecisionEngine.evaluate` block. A single active calendar signal fires `onMeetingPrompt(title, eventID)` directly (the engine's `>= 2` active-signal gate previously made this unreachable because the audio/mic/window monitors never run in production). Prompts are de-duped per `calendarEventID` via a new `promptedEventIDs` set; the entry is dropped when the event deactivates so a re-occurrence can prompt again, a nil-ID deactivating signal (sign-out teardown) clears the whole set, and `stop()` resets it. No prompt fires while `currentMeeting != nil`. `NotificationManager.promptToRecord` now carries the title in `userInfo`; the `CaddieApp` Record handler reads it from `userInfo` and falls back to stripping the banner prefix. `GoogleCalendarService.stop()` emits a deactivating signal so the detector drops the lingering calendar signal on sign-out. The misleading `RecordingCoordinator` comment was corrected.

**Task 2 — scope the Google sign-in gate.** Removed the full-screen `googleSignInGate` (and the now-unused `isSignedInToGoogle` property) from `ContentView`; post-onboarding the app renders `mainContent` regardless of Google auth state, so signed-out users reach the recordings list, playback, and manual recording. `MeetingListView` now renders a compact `signInPromptCard` (with signingIn / error / signedOut states) in a "Calendar" section when signed out, and `TodayScheduleView` when signed in. Onboarding (ONB-01) is untouched — `OnboardingView` only shows "Get Started" in the `.signedIn` case, so sign-in is still required to finish onboarding. README clarified to state sign-in is required for onboarding/calendar features while local recording/playback work signed out.

## Tests

New `MeetingDetectorTests` (replacing `testGoogleCalendarAloneDoesNotTrigger`), all passing after implementation:
- `testGoogleCalendarAloneFiresPrompt` — lone calendar signal fires once with correct title + eventID
- `testSameCalendarEventDoesNotRePrompt` — same eventID does not re-prompt
- `testCalendarSignalWhileMeetingCurrentDoesNotPrompt` — no prompt while a meeting is current

TDD confirmed: the two new positive tests FAILED on the original code (prompt count 0) before the fix, then passed after. Existing DecisionEngine tests remained green. `make test` prints `** TEST SUCCEEDED **` after each task.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Fixed "Entitlements file was modified during the build" failure**
- **Found during:** Task 1 RED (first `make test`)
- **Issue:** `xcodebuild` aborted with `error: Entitlements file "CaddieDebug.entitlements" was modified during the build`. Root cause: `Resources/CaddieDebug.entitlements` carries an immovable `com.apple.provenance` system xattr (cannot be stripped with `xattr -c`) that Xcode's `ProcessProductPackaging` step perceives as an in-build modification. This blocked all test runs, so the TDD RED step could not even execute.
- **Fix:** Added `CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION: YES` to the Debug config only (Release keeps strict packaging for notarized builds) and excluded `*.entitlements` from the `Resources` resource-copy phase so the file is no longer bundled as an app resource.
- **Files modified:** project.yml
- **Commit:** caa4c2d

## Verification

- `make test` -> `** TEST SUCCEEDED **` after both tasks.
- A lone active `.googleCalendar` signal fires `onMeetingPrompt` exactly once; same-event re-signal does not re-prompt; no prompt while a meeting is current.
- Sign-out emits a deactivating signal clearing the detector's calendar state and prompted-event set.
- `CaddieApp` Record handler reads the title from `userInfo`.
- Signed-out users reach `mainContent` (recordings, playback, manual recording); the sidebar shows a compact sign-in card.
- Onboarding still requires Google sign-in (ONB-01 intact).
- CAL-03 (pre-meeting timing) intentionally NOT implemented (out of scope).
- No Co-Authored-By lines in commits.

## Known Stubs

None — both behaviors are fully wired (calendar signal -> notification -> record handler; signed-out UI -> live sign-in button).

## Commits

- caa4c2d: fix(calendar): repair dead notification prompt path (CAL-02)
- e398bc3: feat(ui): scope Google sign-in gate to calendar features, keep local recordings accessible

## Self-Check: PASSED
- Commit caa4c2d: FOUND
- Commit e398bc3: FOUND
- MeetingDetector.swift contains `promptedEventIDs`: FOUND
- MeetingListView.swift contains `signInPromptCard`: FOUND
- ContentView.swift `googleSignInGate`: REMOVED

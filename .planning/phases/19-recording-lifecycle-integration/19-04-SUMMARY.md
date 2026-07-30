---
phase: 19-recording-lifecycle-integration
plan: 04
subsystem: app
tags: [appstate, menubar, opt-in, vid-04, feature-gate, tdd, readme]

# Dependency graph
requires:
  - phase: 19-01
    provides: ScreenRecordingSettings.isEnabled, ScreenRecorderFactory, ScreenRecorder conformance
  - phase: 19-02
    provides: RecordingCoordinator.init(screenRecorderFactory:), setOnVideoError channel
  - phase: 19-03
    provides: async stop(), bounded video teardown that feeds the same error channel
provides:
  - AppState.lastVideoError — dedicated non-fatal video observable
  - AppState.applyVideoError / clearVideoError — MainActor mutators (unit-testable)
  - Gated ScreenRecorder factory construction (the ONLY production path that makes video reachable)
  - MenuBarView.videoErrorRow — orange, dismissible, rendered in idle AND recording
  - README screen-recording section (enablement, .mov layout, degrade behavior, Phase-20 gaps)
affects: [20 video deletion + disk guard, 21 Settings toggle replaces the defaults-write recipe]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Feature-gated dependency construction: the factory exists only inside the opt-in branch, so the whole subsystem is inert by absence rather than by runtime flag checks"
    - "Dedicated non-fatal user surface alongside the fatal one, with copy that names what survived"

key-files:
  created:
    - Tests/AppStateVideoErrorTests.swift
  modified:
    - Sources/App/AppState.swift
    - Sources/UI/MenuBar/MenuBarView.swift
    - README.md

key-decisions:
  - "Permission status is logged but never gates construction — Permissions.screenRecording is a window-name inference, so a false negative would silently disable video with no error; a denied TCC grant is better handled as a real start() throw on the surfaced non-fatal channel"
  - "videoErrorRow renders in the .recording branch too — the existing error surface is idle-only, which is precisely when a still-running degraded capture is invisible"
  - "Orange, not red, and the copy names the survivor ('audio was saved') — the message must not read as a lost recording"

patterns-established:
  - "Pattern: inert-by-absence feature gate — an opt-in subsystem's dependency is not constructed at all when off, so no downstream code path needs to re-check the flag"

requirements-completed: [VID-04]

# Metrics
duration: 12 min
completed: 2026-07-31
---

# Phase 19 Plan 04: AppState Gate + Menu Bar Video Surface Summary

**Screen recording is now reachable in production for the first time — but only behind the opt-in key — and when a capture degrades the user sees an orange, dismissible "Screen recording stopped — audio was saved" line in the menu bar while the meeting keeps recording and transcribing.**

## Performance

- **Duration:** 12 min
- **Started:** 2026-07-31T01:48 (local +05:30)
- **Completed:** 2026-07-31T01:56 (local +05:30)
- **Tasks:** 2 (Task 1 TDD, RED → GREEN, no REFACTOR needed)
- **Files modified:** 4 (1 created, 3 modified)

## Accomplishments

- **The feature gate is structural, not conditional.** `screenRecorderFactory` is declared as an optional and assigned only inside `if ScreenRecordingSettings.isEnabled`. With the key absent the coordinator receives `nil`, and every video path built in 19-02/19-03 stays inert by construction — nothing downstream re-checks the flag, so there is no second place for the gate to drift out of sync. `defaults read com.caddie.app screenRecordingEnabled` still reports the key does not exist after the full suite runs (T-19-12).
- **TCC denial is a degrade, not a silent disable.** `Permissions.screenRecording` is logged with the enablement line for diagnostics and deliberately never gates anything — the acceptance gate `grep -c 'guard Permissions.screenRecording'` returns 0. It infers permission by probing foreign window names, so a false negative would have turned video off with no error at all; letting a denied grant come back as a real `start()` throw routes it through the VID-04 path with a real message.
- **The three video failure modes from 19-02/19-03 now reach a human.** Start throw, mid-meeting stream death, and the 5-second bounded stop timeout all call `surfaceVideoError` → `setOnVideoError` → a `Task { @MainActor in }` hop → `applyVideoError`. That was the last unwired channel in the phase; `setOnVideoError` has a production caller for the first time.
- **The warning is visible during the meeting, not only after it.** The pre-existing `lastRecordingError` row lives only in the `.idle` branch. A capture that dies 40 minutes into a meeting would have been invisible for those 40 minutes, so `videoErrorRow` renders in `.recording` too — the moment the user could still do something about it.
- **The copy is honest about what survived.** Orange rather than red, and the string names the outcome: "⚠️ Screen recording stopped — audio was saved: \(message)". Reusing `lastRecordingError` would have rendered "Last recording failed" for a meeting whose audio and transcript are intact (Pitfall 7 / T-19-13). `grep -c 'lastRecordingError'` in the new code path: it is untouched, and a test asserts `applyVideoError` leaves it nil.
- **Full suite green: 341 tests, 0 failures** (19-03 baseline 336 — 5 net new tests, no regressions). `project.yml` has a zero diff, so no package install occurred (T-19-SC).

## Task Commits

1. **Task 1: Gated factory construction + `lastVideoError` observable** — `f1e0ae7` (test, RED) → `0e2ff45` (feat, GREEN)
2. **Task 2: Menu bar surface + README** — `21743b9` (feat)

Task 1's RED was genuine: 10 `value of type 'AppState' has no member` errors across `lastVideoError`, `applyVideoError`, and `clearVideoError`, and `** TEST FAILED **`.

## Files Created/Modified

- `Sources/App/AppState.swift` (modified) — `lastVideoError` declared next to `lastRecordingError` with the separation rationale doc-commented; `applyVideoError(_:)` / `clearVideoError()`; the gated factory block (step 5b) before the `RecordingCoordinator(...)` call with `screenRecorderFactory:` passed as the trailing argument; `setOnVideoError` wiring after `setOnPipelineStepChange`; `self.lastVideoError = nil` in the `.recording` branch.
- `Sources/UI/MenuBar/MenuBarView.swift` (modified) — `@ViewBuilder private var videoErrorRow` plus its two render sites (`.idle` above the recording-error row, `.recording` above the running-meeting rows). The `.transcribing` branch is untouched.
- `Tests/AppStateVideoErrorTests.swift` (new) — 5 tests: default nil, set, clear, overwrite-not-append, and the cross-channel guard that `lastRecordingError` stays nil.
- `README.md` (modified) — "Screen" row under What It Does; Screen Recording permission row clarified to cover both system-audio and video capture; a new "Screen recording (opt-in, in progress)" subsection under How It Works.

`AppState.shutdown()` was not touched, as the plan specified — `Task { await coordinator?.stop() }` already awaits 19-03's now-async `stop()`.

## Decisions Made

- **Inert by absence rather than by flag.** The plan's shape (construct the factory only inside the `if`) was followed verbatim because it makes the gate un-bypassable: there is no runtime flag for a later code path to forget to check, and the coordinator's existing `guard screenRecorderFactory != nil else { return }` becomes the single enforcement point. The cost is that toggling the key requires a relaunch — acceptable, and documented in the README.
- **A fifth test beyond the four the plan named.** `testApplyVideoErrorLeavesRecordingErrorUntouched` locks down the actual point of the separate channel. The four specified tests all pass with a hypothetical implementation that also sets `lastRecordingError`; this one does not, so the property that Pitfall 7 is about is now enforced by test rather than by review.
- **Orange, and the message leads with the good news.** Red is the existing vocabulary for a lost recording. A degraded capture is a different severity and needed a different colour so the two rows are distinguishable when both happen to be present.

## Deviations from Plan

None beyond the one addition noted above (an extra test). Every symbol, grep gate, and render site the plan specified exists as written; no auto-fix rules were triggered and no build or test failure occurred outside the intended RED.

## Issues Encountered

None. Both tasks compiled first try after the RED, and no fix cycles were needed.

## Known Stubs

None in this plan's code. Two carried-forward gaps, both owned by Phase 20 and now documented in the README rather than only in planning notes:

- `AudioFileManager.deleteAudio(meetingId:)` still ignores `.mov`, so deleting a meeting orphans its video file.
- The 500 MB pre-recording disk guard has not been raised for video (~0.5–1.3 GB/hour).

One carried-forward gap owned by Phase 21: there is no Settings toggle, so enablement is `defaults write com.caddie.app screenRecordingEnabled -bool true` plus a relaunch. The README says so explicitly rather than implying the feature is fully shipped, and no Roadmap entry claims Settings or playback landed.

## Threat Flags

None. No network endpoint, auth path, or schema change. The plan's threat-register dispositions landed as specified:

- **T-19-12 (Information disclosure):** the factory exists only inside the opt-in branch; with the key absent the coordinator's dependency is nil and no capture engine is ever constructed. Verified by `defaults read` still reporting the key absent after the suite.
- **T-19-13 (Repudiation):** dedicated `lastVideoError` with "audio was saved" copy, rendered in the `.recording` branch too, with a test proving the fatal channel is untouched.
- **T-19-14 (Elevation of privilege, accepted):** permission status logged only; `grep -c 'guard Permissions.screenRecording'` returns 0. TCC remains the sole authority.
- **T-19-SC (accepted):** `git diff --stat -- project.yml` is empty — no package installs.

## Verification

| Check | Result |
|-------|--------|
| `make test` full suite | `** TEST SUCCEEDED **` — 341 tests, 0 failures (baseline 336, +5, no regressions) |
| `-only-testing:CaddieTests/AppStateVideoErrorTests` | `** TEST SUCCEEDED **` — 5/5 |
| `grep -c 'var lastVideoError: String?'` (AppState) | 1 |
| `grep -c 'func applyVideoError'` / `'func clearVideoError'` | 1 / 1 |
| `grep -c 'ScreenRecordingSettings.isEnabled'` | 1 |
| `grep -c 'screenRecorderFactory'` (AppState) | 3 |
| `grep -c 'setOnVideoError'` (AppState) | 1 |
| `grep -c 'self.lastVideoError = nil'` | 1 |
| `grep -c 'guard Permissions.screenRecording'` | 0 (permission is never a gate) |
| `grep -c 'appState.lastVideoError'` (MenuBarView) | 1 |
| `grep -c 'clearVideoError'` / `'videoErrorRow'` / `'audio was saved'` (MenuBarView) | 1 / 3 / 1 |
| `grep -c 'screenRecordingEnabled'` / `'\.mov'` (README) | 1 / 2 |
| `grep -ci 'deleting a meeting does not yet remove'` (README) | 1 |
| `git diff --stat -- project.yml` | empty (packages block unchanged) |
| `defaults read com.caddie.app screenRecordingEnabled` | "does not exist" — the suite never writes the key |

## Success Criteria

- With the key unset the app behaves exactly as before — **proven** by the 341-test suite (which never sets the key) plus the empty-diff gate on the factory being nil-by-default
- A video failure is visible during and after the meeting and is dismissible — **proven** by `videoErrorRow` rendering in both branches with a `Dismiss Video Warning` action, over the tested `applyVideoError`/`clearVideoError` mutators
- README documents enablement, file layout, degradation, and the Phase-20 deletion gap — **proven** by the four README grep gates

## User Setup Required

To exercise screen recording on a real machine: quit Caddie, run `defaults write com.caddie.app screenRecordingEnabled -bool true`, relaunch, and grant Screen Recording in System Settings if prompted. Note 18-04's finding that a Debug build must be added to the Screen Recording list via "+" from DerivedData, and that launching via `open` is required for TCC to attribute the capture to Caddie.

## Next Phase Readiness

VID-04 is complete end to end: contained in the coordinator (19-02), bounded on teardown (19-03), and surfaced to the user (this plan). Phase 19's remaining plan and Phase 20 inherit:

- A production-reachable video path — this is the first plan after which enabling the key actually records video, which makes the Phase-20 gaps (deletion, disk guard) real rather than theoretical.
- `AppState.lastVideoError` as the single UI-facing video channel, should a later phase want to surface it in the main window as well as the menu bar.

**Carried-forward concern (unchanged):** coordinator tests inject a real `AudioRecorder` and therefore depend on dev-Mac audio hardware. The video seam remains mock-only by construction, and the new `AppState` tests touch no hardware at all.

## Self-Check: PASSED

All 4 files verified present on disk. All 3 task commits verified in `git log`.

---
*Phase: 19-recording-lifecycle-integration*
*Completed: 2026-07-31*

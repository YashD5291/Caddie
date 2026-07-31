---
phase: quick-260731-5nv
plan: 01
subsystem: ui
tags: [swiftui, menubar, nsalert, audio-drain, data-loss]

# Dependency graph
requires:
  - phase: 19-recording-lifecycle-integration
    provides: 19-VALIDATION.md Finding F1 — the measured evidence (304 s meeting -> 63.2 s of audio) that the Stop-confirm modal starves the main-queue drain timer
provides:
  - Menu bar Stop Recording stops immediately with no confirmation dialog and no main-thread block
  - RES-04 backlog requirement for the root-cause fix (drain timer off the main queue)
  - STATE.md Blockers/Concerns entry keeping the deferred drain hardening visible
affects: [audio-drain, recording-lifecycle, resilience, RES-04]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "No blocking modal on any path that runs during an active audio drain — the drain DispatchSourceTimer is main-queue-bound, so a modal is silent data loss"

key-files:
  created: []
  modified:
    - Sources/UI/MenuBar/MenuBarView.swift
    - .planning/REQUIREMENTS.md
    - .planning/STATE.md

key-decisions:
  - "The confirm modal is removed outright, not replaced with a non-blocking sheet — stopping is non-destructive (meeting is saved and transcribed), so no guard justifies the data-loss hazard"
  - "Call target stays appState.stopRecording() (not stopManualRecording()) — semantics unchanged, only the dialog goes away"
  - "Main-queue drain timer rework deferred to RES-04; this task ships the mitigation, not the root fix"
  - "No unit test fabricated — confirmStopRecording() was a private SwiftUI View helper with no test seam; verification is source-level greps plus a green full suite (same shape as the 19-04-T2 build+grep gate)"

patterns-established:
  - "Comment the ABSENCE of a confirmation guard where its absence looks like an oversight — the comment cites Finding F1 so nobody reintroduces the modal"

requirements-completed: [F1, RES-04]

# Metrics
duration: 6min
completed: 2026-07-31
---

# Quick Task 260731-5nv: Remove Blocking Stop-Confirm Modal Summary

**Menu bar Stop Recording now calls `appState.stopRecording()` directly — the `NSAlert.runModal()` confirm dialog that blocked the main thread (starving the main-queue audio drain timer and silently discarding ring-buffer samples) is deleted, with the root-cause drain hardening filed as RES-04.**

## Performance

- **Duration:** ~6 min
- **Started:** 2026-07-31T04:08:00Z
- **Completed:** 2026-07-31T04:14:00Z
- **Tasks:** 2
- **Files modified:** 3

## Accomplishments

- Deleted `MenuBarView.confirmStopRecording()` in full — the `NSAlert`, both `addButton` calls, `NSApp.activate(ignoringOtherApps:)`, the `DispatchQueue.main.async` wrapper, and the `runModal()` branch. No dead code, no commented-out remnant.
- Stop button action is now a direct `appState.stopRecording()` call, which already spawns a `Task` and is safe to invoke from a main-actor SwiftUI Button action — no dispatch wrapper needed.
- Added a 4-line comment above the button explaining why there is deliberately no confirmation, citing Finding F1, so the modal is not reintroduced by a future reviewer who reads its absence as an oversight.
- Filed RES-04 in REQUIREMENTS.md Future → Resilience and mirrored the concern in STATE.md Blockers/Concerns: the drain `DispatchSourceTimer` still runs on the main queue, so ANY main-thread stall reintroduces silent audio loss.
- Full suite green: 341 tests, 0 failures, `** TEST SUCCEEDED **`.

## Task Commits

1. **Task 1: Delete confirmStopRecording() and stop directly from the menu** — `d08e329` (fix)
2. **Task 2: Record RES-04 backlog + STATE concern, confirm README needs no change** — `6e565d1` (docs)

## Files Created/Modified

- `Sources/UI/MenuBar/MenuBarView.swift` — Stop button calls `appState.stopRecording()` directly; `confirmStopRecording()` removed (net −12 lines). `videoErrorRow`, `actionsSection`, and `pipelineStepLabel` untouched; `// MARK: - Helpers` kept (still accurate for `pipelineStepLabel`).
- `.planning/REQUIREMENTS.md` — RES-04 appended under Future → Resilience after RES-03. RES-01…RES-03 unchanged; RES-04 deliberately NOT added to the v3 checklist (deferred backlog, not current-milestone scope).
- `.planning/STATE.md` — Blockers/Concerns bullet for the deferred drain hardening, with the F1 measurement (304 s → 63.2 s) recorded inline.

## Verification

Task 1 source-level gates (all pass):

| Gate | Expected | Actual |
|------|----------|--------|
| `grep -c 'runModal' Sources/UI/MenuBar/MenuBarView.swift` | 0 | 0 |
| `grep -c 'NSAlert' Sources/UI/MenuBar/MenuBarView.swift` | 0 | 0 |
| `grep -c 'confirmStopRecording' Sources/UI/MenuBar/MenuBarView.swift` | 0 | 0 |
| `grep -rc 'confirmStopRecording' Sources/` | no matches | no matches |
| `grep -c 'appState.stopRecording()' Sources/UI/MenuBar/MenuBarView.swift` | 1 | 1 |
| `grep -c 'DispatchQueue.main.async' Sources/UI/MenuBar/MenuBarView.swift` | 0 | 0 |
| `grep -c 'runModal' Sources/App/AppState.swift` (out of scope, untouched) | 1 | 1 |
| `grep -c 'runModal' Sources/UI/MainWindow/ExportSheet.swift` (out of scope, untouched) | 1 | 1 |
| `make test` | `** TEST SUCCEEDED **` | `** TEST SUCCEEDED **` (341 tests, 0 failures) |

Task 2 gates (all pass): `RES-04` appears once in REQUIREMENTS.md and once in STATE.md; `RES-01` still present and still first under `### Resilience` (appended, not prepended); README no-op proven — `stop recording?`, `are you sure`, and `confirmation dialog` all return 0, and `grep -ni 'confirm' README.md` returns nothing at all, so README is unmodified and absent from `git diff --name-only`.

## Decisions Made

None beyond the plan's locked decisions — executed as specified.

## Deviations from Plan

None — plan executed exactly as written. No auto-fixes were needed; the modal removal compiled and the suite stayed green on the first run.

## Issues Encountered

None.

## User Setup Required

None — no external service configuration required.

## Known Stubs

None — this task is a net deletion.

## Remaining Manual Verification

The human smoke check from the plan's verification section is still open (optional before merge, cannot be automated — this project has no UI-automation harness):

1. Launch the built app, start a manual recording, let it run ~30 s.
2. Menu bar → Stop Recording.
3. Expect: recording stops instantly with NO dialog, the meeting transcribes, and the resulting `.m4a` duration is within a second or two of wall-clock. The F1 symptom was a duration far shorter than elapsed.

## Next Phase Readiness

- The immediate data-loss hazard on the Stop path is closed; Phase 20 (storage/retention) is unblocked and unaffected by this change.
- **Open concern:** RES-04. The drain timer is still main-queue-bound. Any future main-thread modal, alert, or long synchronous work on the main actor during an active recording will silently discard audio again. The two remaining `runModal()` sites (`AppState.showPermissionAlert`, `ExportSheet` `NSSavePanel`) were left untouched because neither runs during an active drain — that reasoning must be re-checked if either is ever moved onto a recording-active path.

## Self-Check: PASSED

- `Sources/UI/MenuBar/MenuBarView.swift` — FOUND
- `.planning/REQUIREMENTS.md` — FOUND
- `.planning/STATE.md` — FOUND
- Commit `d08e329` — FOUND
- Commit `6e565d1` — FOUND

---
*Quick task: 260731-5nv*
*Completed: 2026-07-31*

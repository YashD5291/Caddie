---
phase: 20-video-storage-retention
plan: 07
subsystem: docs
tags: [readme, settings, traceability, stor-02, stor-03, stor-04, d-01, d-08, d-12, d-16]

# Dependency graph
requires:
  - phase: 20-video-storage-retention
    provides: "20-02 deleteMedia + launch orphan-video sweep; 20-05 two-tier disk guard and lowDiskVideoMessage; 20-06 persisted video link + video_start_offset"
provides:
  - "README 'Screen recording (opt-in, in progress)' section that describes shipped deletion, launch cleanup, and the low-disk audio-only fallback"
  - "Settings 'Storage used' label (the total already counts .mov)"
  - "STOR-03 wording and ROADMAP Phase 20 criterion 3 that match the D-01 two-tier guard"
  - "STOR-04 traced to Phase 18 (engine anchor) and Phase 20 (persisted with the meeting), listed on Phase 20 with a storage-leg success criterion"
affects: [20-08 phase verification, 21 settings/playback docs]

# Tech tracking
tech-stack:
  added: []
  patterns: []

key-files:
  created: []
  modified:
    - README.md
    - Sources/UI/Settings/SettingsView.swift
    - .planning/REQUIREMENTS.md
    - .planning/ROADMAP.md

key-decisions:
  - "20-07: STOR-03 and STOR-04 stay checked and Complete. The plan said to uncheck them, but it was written before 20-05 and 20-06 shipped. Only the wording and traceability changed"
  - "20-07: The README gives the default-preset video threshold as 'about 2.8 GB' (2,774,288,000 bytes) and the floor as '500 MB', which matches the existing error copy"

patterns-established: []

requirements-completed: [STOR-02, STOR-03, STOR-04]

# Metrics
duration: 4min
completed: 2026-11-19
---

# Phase 20 Plan 07: Docs, Settings label, and STOR traceability Summary

**The README now says what Phase 20 does: deleting a meeting deletes its video, Caddie removes stray videos at launch, and low disk space records audio only. Settings now reads "Storage used". STOR-03 and ROADMAP criterion 3 describe the two-tier guard. STOR-04 is traced to Phase 18 for the engine anchor and Phase 20 for persistence.**

## Performance

- **Duration:** ~4 min
- **Started:** 2026-11-19T14:30:32Z
- **Completed:** 2026-11-19T14:34:43Z
- **Tasks:** 2
- **Files modified:** 4

## Accomplishments
- README: removed the "Known gaps" bullet. Added "Deleting a meeting deletes its video." (covers the `deleteMedia` by-id removal, the launch sweep, and the rule that the sweep never runs on a DB read error or an empty meetings table) and "Low disk space records audio only." (blocked below 500 MB, about 2.8 GB wanted at the default quality, the menu bar says why). The numbers come from `RecordingCoordinator.minimumDiskSpaceBytes`, `videoDiskThreshold(for: .balanced)` = 2,774,288,000 bytes, and `lowDiskVideoMessage`
- Settings: changed one line, `Text("Audio storage used")` to `Text("Storage used")`. `AudioFileManager.totalStorageUsed()` already sums every file in the media directory, so the total includes `.mov`. The "Clean Up Orphaned Files" button is unchanged (D-16)
- REQUIREMENTS.md: rewrote STOR-03 for D-01. Added the Phase 18 / Phase 20 split to the STOR-04 text. Moved the STOR-04 traceability row after STOR-03 with the new phase text. There are still 15 rows, and the 15/15 coverage line is still accurate
- ROADMAP.md, Phase 20 only: the requirements line now lists STOR-04, criterion 3 now describes the two-tier guard, and a new criterion 5 covers the STOR-04 storage leg. The Phase 18 block and the Phase 20 `**Plans**:` list are unchanged

## Task Commits

1. **Task 1: README screen-recording section + Settings "Storage used" label** - `6b4f65f` (docs)
2. **Task 2: STOR-03 wording, STOR-04 traceability, ROADMAP Phase 20 criteria** - `d993bcd` (docs)

## Files Created/Modified
- `README.md` - screen-recording section: the "Known gaps" bullet is replaced by two bullets on deletion and low disk space
- `Sources/UI/Settings/SettingsView.swift` - storage row label
- `.planning/REQUIREMENTS.md` - STOR-03 and STOR-04 text, STOR-04 traceability row
- `.planning/ROADMAP.md` - Phase 20 requirements line, criterion 3, new criterion 5

## Verification
- `make build`: `** BUILD SUCCEEDED **`
- `make test`: **426 tests, 0 failures**, `** TEST SUCCEEDED **` (same as the 20-06 baseline; this plan adds no tests)
- Task 1 greps: `Known gaps` 0, `Deleting a meeting deletes its video` 1, `Low disk space records audio only` 1, `records audio only` 1, `Text("Storage used")` 1, `Audio storage used` 0, SettingsView diff exactly 2 changed lines
- Task 2 greps: new STOR-03 phrase 1, old STOR-03 phrase 0, old STOR-04 row 0, new STOR-04 row 1, Phase 20 requirements line 1, criterion 3 phrase 1, `STOR-04 storage leg` 1, Phase 18 requirements line 1 (unchanged)

## Decisions Made
- STOR-03 and STOR-04 keep `[x]` / Complete (see Deviations)
- The README says "the database is empty" for the sweep's empty-meetings guard. That is plain language for the same `knownMeetingIds.isEmpty` skip

## Deviations from Plan

### Status overrides (orchestrator instruction, the plan predates shipped work)

**1. STOR-04 stays `[x]` and its traceability row stays `Complete`, not `[ ]` / `Pending`**
- **Found during:** Task 2
- **Issue:** The plan unchecks STOR-04 because "it is not complete until 20-06 ships". 20-06 has shipped (`f543a66`, `cde75f8`): it persists `video_file` and `video_start_offset`, and 20-06-SUMMARY lists STOR-04 under requirements-completed
- **Fix:** Applied the new STOR-04 text and the new traceability phase text, and kept the status Complete. The two acceptance greps that expect `[ ]` / `Pending` therefore return 0. The matching `[x]` / `Complete` forms each return 1
- **Files modified:** .planning/REQUIREMENTS.md
- **Commit:** d993bcd

**2. STOR-03 keeps `[x]`**
- **Found during:** Task 2
- **Issue:** The plan's replacement line starts with `- [ ]`, but 20-05 shipped the two-tier guard and already marked STOR-03 complete
- **Fix:** Replaced the wording and kept `[x]`
- **Files modified:** .planning/REQUIREMENTS.md
- **Commit:** d993bcd

No other deviations.

## TDD Note
This plan has no `tdd="true"` tasks. The only code change is a static SwiftUI label. The project has no view-inspection test tooling, so the build is the gate, as the plan specifies. The full suite stays green.

## Issues Encountered
None.

## Known Stubs
None.

## Next Phase Readiness
- 20-08 hardware verification can check what the README now promises: deleting a meeting removes its `.mov`, the launch sweep removes stray videos, and a low-disk start records audio only and shows the menu bar message
- No blockers

## Self-Check: PASSED
- FOUND: README.md, Sources/UI/Settings/SettingsView.swift, .planning/REQUIREMENTS.md, .planning/ROADMAP.md
- FOUND commits: 6b4f65f, d993bcd

---
*Phase: 20-video-storage-retention*
*Completed: 2026-11-19*

---
phase: 20-video-storage-retention
plan: 08
subsystem: verification
tags: [hardware-gate, stor-01, stor-02, stor-03, stor-04, d-05, d-06, d-08, d-10, d-13, vid-07]

# Dependency graph
requires:
  - phase: 20-video-storage-retention
    provides: "20-01..20-07: v2 migration, deleteMedia + orphan sweep, VideoFileInspector, onFinalized engine signal, two-tier disk guard, per-meeting video link/verify, docs"
provides:
  - "Measured hardware-gate results for every Phase 20 manual check (20-VALIDATION.md `## Manual Gate Results`)"
  - "Follow-ups D-1..D-5 in deferred-items.md"
affects: [phase 20 verification, phase 21 playback (offset semantics confirmed on real capture), v3.0 milestone close (14.2 kill-9 re-run)]

# Tech tracking
tech-stack:
  added: []
  patterns: []

key-files:
  created:
    - .planning/phases/20-video-storage-retention/20-08-SUMMARY.md
  modified:
    - .planning/phases/20-video-storage-retention/20-VALIDATION.md
    - .planning/phases/20-video-storage-retention/deferred-items.md

key-decisions:
  - "20-08: the agent drove the whole gate under the developer's standing 'do everything, don't wait' instruction. The developer did the one human-only step (Screen Recording TCC). Menu clicks and the main-window delete were done through AX, and each was verified with read-only sqlite3 and ls before and after"
  - "20-08: check 7 ran the kill9-recovery-gate.sh steps through `open -n --stdout/--stderr … --args`, because the script's direct-exec launch gets TCC attributed to the terminal (D-5). The engine, binary and pass criterion are unchanged"
  - "20-08: meeting cab32fda-e3d (check 4 partial) was left in the library as live D-06 evidence, not deleted by the agent"

patterns-established:
  - "Gate menu automation: `osascript` System Events `click menu item \"…\" of menu 1 of menu bar item 1 of menu bar 2` on the Caddie pid; main-window rows found via `entire contents` and selected with `set selected`; destructive sheet buttons pressed only after the detail pane was read back and matched"

requirements-completed: [STOR-01, STOR-02, STOR-03, STOR-04]

# Metrics
duration: ~25min active (gate), plus wait for the TCC grant
completed: 2026-11-19
---

# Phase 20 Plan 08: Hardware Verification Gate Summary

**Phase 20 works on real hardware with real data. The real library is at v2 with all 17 meetings intact, and the launch sweep kept every real video. A real capture was linked to its row on the first frame (offset 0.289 s), verified after finalize, and is playable (50.5 s). A quit mid-recording left a linked, playable 30.2 s partial. Deleting from the main window removed the `.mov` and `.m4a`. A planted orphan was swept on relaunch. The kill-9 crash-safety gate still passes after the `onFinalized` engine edit.**

## Performance

- **Gate window:** 21:53–23:12 IST, 2026-11-19 (the gap at 22:06–23:10 was the wait for the developer)
- **Tasks:** 2 (Task 1 prep `ceef3c0`, Task 2 gate)
- **Files modified:** 2 planning docs (no source changes)

## Results (full values in 20-VALIDATION.md)

| # | Check | Result |
|---|-------|--------|
| 0 | TCC re-grant | Developer granted it; launch log `Screen recording enabled` |
| 1 | Migration on real data | `v1_create_meetings`, `v2_add_video_columns`; 17 meetings; 15 columns; 0 pre-existing rows with video columns set; FTS search works and `video_file` is not searchable. Observed as end-state only (P-1) |
| 2 | Sweep kept real videos | All 3 pre-state `.mov` kept, same sizes; no orphan-video log line |
| 3 | Real capture link | `f4ec2fee-1a8.mov`, `video_start_offset` 0.288628833339317 s, linked while still `recording`. `Video verified … 50.5s, 1 track(s)` after finalize, without blocking transcription. `VALIDATE isPlayable=true duration=50.533` |
| 4 | Quit mid-recording | `cab32fda-e3d.mov` linked (offset 0.151 s) before and after relaunch; `VALIDATE isPlayable=true duration=30.2` (~2.3 s tail loss) |
| 5 | UI delete | Row gone; `.mov` and `.m4a` gone; other videos untouched; only a debug "No … to delete" line for the already-compressed `.wav` |
| 6 | Planted orphan | `zz-phase20-orphan-test.mov` removed (`Cleaned up 1 orphaned video file(s)`); all 4 row-backed `.mov` kept |
| 7 | Kill-9 | Run 1: script TCC attribution failure (D-5). Run 2 via LaunchServices: `VALIDATE isPlayable=true duration=30.167`, ≥ 20 s → PASS |
| 8 | Low disk | Unit-verified only |

## Deviations from Plan

1. **Check 1 could not observe the migration live.** `make test` had already migrated the real DB through the hosted app (P-1 / D-1). The end-state was verified instead. Search was checked with an FTS query that uses the same subquery as `Meeting.swift:107`, not by typing in the UI.
2. **Human steps were automated.** Start, stop, quit and delete were driven through AX instead of being clicked by the developer, under the standing "don't wait for me" instruction. The delete was pressed only after the detail pane read back "9:55 PM – 9:56 PM / 0:50", and the row and files were verified afterwards.
3. **Check 7 launch method.** See key-decisions and D-5.
4. **Log text.** The shipped sweep line is `Removing orphaned video <file>` (plan: `Removed orphaned video …`), and the unified log redacts meeting ids and filenames as `<private>` (D-4). Results were correlated through the public ScreenRecorder lines, timestamps, the DB and `ls`.

## Follow-ups (deferred-items.md)

- **D-1** `make test` initializes the app against the real library (migration + sweep on real data)
- **D-2** tests leave ~1791 row-less `.wav`/`.m4a` stems in the real `audio/` directory
- **D-3** quitting mid-recording leaves the row in `recording`, untranscribed (pre-existing; conflicts with the core value)
- **D-4** coordinator log lines redact meeting ids
- **D-5** the kill-9 gate script needs Screen Recording on the launching terminal
- Still open from earlier phases: macOS 14.2 kill-9 re-run at milestone close; the Settings "Clean Up Orphaned Files" `.wav` hazard (D-16)

## Cleanup

`screenRecordingEnabled` default deleted (back to opt-in). Caddie was quit, the log stream stopped and the kill-9 temp output removed. DB backups stay in the scratchpad until the developer confirms.

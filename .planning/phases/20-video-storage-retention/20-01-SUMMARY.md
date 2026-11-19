---
phase: 20-video-storage-retention
plan: 01
subsystem: database
tags: [grdb, sqlite, migration, fts5, video, schema]

# Dependency graph
requires:
  - phase: 19-recording-lifecycle-integration
    provides: in-memory video anchor pair (audioStartTicks / firstFrameTicks) and `<meetingId>.mov` placement that this schema will persist
provides:
  - "v2_add_video_columns GRDB migration: nullable video_file (TEXT) + video_start_offset (DOUBLE) on meetings"
  - "Meeting.videoFile / Meeting.videoStartOffset fields with snake_case CodingKeys, defaulted init params"
  - "Tests proving v1 -> v2 in-place upgrade, FTS isolation of video_file, and FTS consistency on video-column UPDATE/DELETE"
affects: [20-06 coordinator link/verify writes, 20-08 phase verification, 21 playback (reads video_start_offset)]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Additive migration: new registerMigration after v1, ADD COLUMN only via db.alter(table:), v1 closure byte-identical"
    - "Upgrade-path test: own DatabaseQueue + DatabaseMigrator, migrate(upTo: v1), seed raw SQL, migrate fully, assert rows + FTS"

key-files:
  created: []
  modified:
    - Sources/Storage/Migrations.swift
    - Sources/Storage/Meeting.swift
    - Tests/MigrationTests.swift
    - Tests/MeetingModelTests.swift

key-decisions:
  - "20-01: Anchor persisted as a single video_start_offset DOUBLE (seconds, first video frame minus audio start); video time = transcript time - offset. Raw host ticks not stored (D-08 discretion)"
  - "20-01: Migration named v2_add_video_columns; ADD COLUMN only so meetings_fts and its three triggers stay untouched and never index the new columns"

patterns-established:
  - "Schema change = new registered migration; never edit v1_create_meetings"
  - "FTS isolation is proven by a negative search test plus an exact meetings_fts column-list assertion"

requirements-completed: []  # STOR-01 / STOR-04 storage legs (schema + model) delivered here; values are first written by 20-06, so completion is marked there / in 20-08

# Metrics
duration: 7min
completed: 2026-11-19
---

# Phase 20 Plan 01: Video Storage Schema Summary

**GRDB migration `v2_add_video_columns` adds nullable `video_file` + `video_start_offset` to `meetings` (FTS5 untouched), threaded through `Meeting` with snake_case mapping and proven by upgrade-path and not-searchable tests.**

## Performance

- **Duration:** ~7 min
- **Started:** 2026-11-19T13:02:45Z
- **Completed:** 2026-11-19T13:09:30Z
- **Tasks:** 2 (each RED + GREEN commit)
- **Files modified:** 4

## Accomplishments
- Fresh and upgraded databases both have 15 columns; `video_file` is TEXT, `video_start_offset` is DOUBLE, both nullable with no default
- A v1 database upgrades in place: the seeded row survives, both new columns read NULL, `Meeting.search("budget")` still finds it
- `video_file` is provably absent from full-text search (zero hits for a filename token, positive control passes, `meetings_fts` columns are exactly `title, transcript, app`); updating the video columns keeps the row indexed and deleting it de-indexes it
- `Meeting` round-trips `videoFile` / `videoStartOffset` (default nil), and `Meeting.search` decodes them; every existing `Meeting(...)` call site compiles unchanged

## Task Commits

1. **Task 1: v2_add_video_columns migration with FTS isolation** - `051d1f9` (test, RED), `9c9d88f` (feat, GREEN)
2. **Task 2: Meeting.videoFile / videoStartOffset round-trip** - `da8ac25` (test, RED), `efd62e5` (feat, GREEN)

## Files Created/Modified
- `Sources/Storage/Migrations.swift` - second registered migration `v2_add_video_columns` (pure addition; zero removed lines in the diff)
- `Sources/Storage/Meeting.swift` - `videoFile` / `videoStartOffset` stored properties, defaulted init params, assignments, CodingKeys
- `Tests/MigrationTests.swift` - 15-column assertion + 5 new tests (nullable/no-default, registration order, v1 upgrade, never-searchable, FTS consistency)
- `Tests/MeetingModelTests.swift` - 3 new tests (default nil, round-trip, search decoding)

## Verification
- RED confirmed for both tasks (Task 1: 6 assertion/SQL failures on missing columns and migration; Task 2: compile failure on unknown members/labels)
- `-only-testing:CaddieTests/MigrationTests` -> 14 tests, `** TEST SUCCEEDED **`
- `-only-testing:` MeetingModelTests + MigrationTests + ExportTests -> 27 tests, `** TEST SUCCEEDED **`
- `make test` -> 349 tests, 0 failures, `** TEST SUCCEEDED **`
- All acceptance greps pass, including `git diff -U0 -- Sources/Storage/Migrations.swift` removed-line count 0 and no `.update(dbConn)` / `.update(db)` in `Sources/`

## Decisions Made
- Anchor stored as one `video_start_offset` DOUBLE in seconds (the form Phase 21 playback needs), not raw host ticks, per the plan's D-08 discretion choice.

## Deviations from Plan

None in the code. One process note: the plan frontmatter lists `requirements: [STOR-01, STOR-04]`, but this plan ships only schema and model; nothing writes the columns until 20-06. The requirements were intentionally **not** marked complete in REQUIREMENTS.md, so traceability does not claim a link that does not exist yet.

## Issues Encountered
None. The `[Calendar] Failed to decode calendar events` lines in the `make test` log come from existing malformed-input tests and are expected.

## TDD Gate Compliance
Both tasks have a `test(20-01)` RED commit followed by a `feat(20-01)` GREEN commit. No refactor commit was needed.

## Next Phase Readiness
- 20-06 can write `UPDATE meetings SET video_file = ?, video_start_offset = ? WHERE meeting_id = ?` directly; the columns and model fields exist
- No blockers

## Self-Check: PASSED
- FOUND: Sources/Storage/Migrations.swift, Sources/Storage/Meeting.swift, Tests/MigrationTests.swift, Tests/MeetingModelTests.swift
- FOUND commits: 051d1f9, 9c9d88f, da8ac25, efd62e5

---
*Phase: 20-video-storage-retention*
*Completed: 2026-11-19*

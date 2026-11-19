---
phase: 20-video-storage-retention
plan: 02
subsystem: storage
tags: [deletion, orphan-cleanup, video, filesystem, launch]

# Dependency graph
requires:
  - phase: 19-recording-lifecycle-integration
    provides: "`<meetingId>.mov` placement beside the audio files via `AudioFileManager.videoPath(for:)`, and the row-inserted-before-capture ordering in RecordingCoordinator"
provides:
  - "AudioFileManager.deleteMedia(meetingId:in:) - removes .wav, .m4a and .mov by meeting id (renamed from deleteAudio)"
  - "AudioFileManager.removeFileIfPresent(at:) - shared delete primitive; missing file logs at debug"
  - "AudioFileManager.cleanupOrphanedVideos(in:knownMeetingIds:) - list-then-read launch sweep with DB-error and empty-set guards"
  - "AudioFileManager.videoPath(for:in:) - defaulted directory parameter for temp-dir targeting"
  - "AppDatabase.meetingIds() - Set of every meeting_id"
  - "Launch sweep wired in AppState.initialize() before RecordingCoordinator is constructed"
affects: [20-06 coordinator finalize/verify (D-07 delete can reuse removeFileIfPresent), 20-07 README known-gaps removal, 20-08 phase verification, 21 playback]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "File operations take `in directory: URL = audioDirectory` so tests inject a temp dir (D-15)"
    - "Expected-missing branch: `catch let error as CocoaError where error.code == .fileNoSuchFile` logs debug, other errors warn"
    - "Destructive sweep = list files first, read ids second, skip on throw or empty set"

key-files:
  created:
    - Tests/MediaFileTests.swift
  modified:
    - Sources/Storage/AudioFileManager.swift
    - Sources/Storage/Database.swift
    - Sources/App/AppState.swift
    - Sources/UI/MainWindow/MeetingDetailView.swift

key-decisions:
  - "20-02: Media deletion is keyed on meeting id, never on video_file, so Phase-19-era and unverified videos (NULL column) are still removed with their meeting"
  - "20-02: The launch orphan sweep lists .mov regular files before reading meeting ids and skips entirely on an ID read failure or an empty meeting set; it runs synchronously in initialize() before RecordingCoordinator exists"

patterns-established:
  - "removeFileIfPresent is the single delete primitive for media; a missing file is expected, not a failure"
  - "Any sweep that deletes by 'no matching row' must list before it reads and treat a failed or empty read as 'unknown'"

requirements-completed: [STOR-02]

# Metrics
duration: 7min
completed: 2026-11-19
---

# Phase 20 Plan 02: Media Deletion and Orphan Video Sweep Summary

**Deleting a meeting now removes its `.wav`, `.m4a` and `.mov` by meeting id through one helper, and a list-then-read launch sweep deletes row-less `.mov` files but skips entirely on a DB read error or an empty meetings table.**

## Performance

- **Duration:** ~7 min
- **Started:** 2026-11-19T13:14:42Z
- **Completed:** 2026-11-19T13:21:11Z
- **Tasks:** 2 (each RED + GREEN commit)
- **Files modified:** 5 (1 created, 4 modified)

## Accomplishments
- `deleteAudio(meetingId:)` renamed to `deleteMedia(meetingId:in:)` and extended to `.mov` (D-09). The only call site, `MeetingDetailView.deleteMeeting()`, keeps its row-first, files-second order
- `removeFileIfPresent(at:)` logs a missing file at `.debug` (D-11). Before this change every normal delete logged a warning for the WAV that ALAC conversion had already removed
- `isSafeMeetingId` rejects empty ids and ids containing `/` or `..` before any path is built (T-20-05)
- `cleanupOrphanedVideos(in:knownMeetingIds:)` lists regular `.mov` files (case-insensitive, non-recursive), reads ids only when videos exist, skips on a throw (D-10) or an empty set (D-14), and removes only files whose stem has no row
- `AppDatabase.meetingIds()` runs `SELECT meeting_id FROM meetings` through `String.fetchSet`
- `AppState.initialize()` runs the sweep right after the DATA-05 temp cleanup (line 106), above `RecordingCoordinator(` (line 170)
- 17 new `MediaFileTests`, all run in a per-test temp directory. `audioDirectory` appears once, in the default-path equality assertion only

## Task Commits

1. **Task 1: deleteMedia + removeFileIfPresent** - `a3b2b25` (test, RED), `9e92637` (feat, GREEN)
2. **Task 2: list-then-read launch orphan sweep** - `bee5143` (test, RED), `0cc049f` (feat, GREEN)

## Files Created/Modified
- `Tests/MediaFileTests.swift` - 8 deletion/path tests + 8 sweep tests + 1 `meetingIds` test, temp-dir lifecycle via `setUpWithError`/`tearDownWithError`
- `Sources/Storage/AudioFileManager.swift` - `videoPath(for:in:)`, `// MARK: - Media Deletion` (`deleteMedia`, `removeFileIfPresent`, `isSafeMeetingId`), `cleanupOrphanedVideos` + `isRegularMovFile`
- `Sources/Storage/Database.swift` - `meetingIds()`
- `Sources/App/AppState.swift` - local `appDatabase` binding + sweep call
- `Sources/UI/MainWindow/MeetingDetailView.swift` - one-line call rename

## Verification
- RED confirmed for both tasks (compile failures on the missing members)
- `-only-testing:CaddieTests/MediaFileTests`: 8 tests after Task 1, 17 after Task 2, `** TEST SUCCEEDED **`
- `make test`: **366 tests, 0 failures**, `** TEST SUCCEEDED **` (baseline 349 + 17 new). The test host runs `AppState.initialize`, so the launch sweep ran against the real directory without crashing
- Real data check: the dev machine's 3 `.mov` files all have meeting rows (confirmed with a read-only sqlite query before running), and all 3 still exist after `make test`
- Every acceptance grep passes: `deleteAudio` count 0 in Sources/Tests, `findOrphanedWAVs` count 1 (the untouched definition), `SettingsView.swift` diff empty (D-16), the sweep line number is below the coordinator construction line number

## Decisions Made
- Deletion keyed on meeting id, never on `video_file` (D-09, T-20-04)
- Sweep ordering and guards as above (D-10, D-14, T-20-06, T-20-07)

## Deviations from Plan

None in behavior. One wording change: the plan asked the sweep's doc comment to contrast it with `findOrphanedWAVs`, but the acceptance grep requires `findOrphanedWAVs` to appear exactly once in the file. The comment says "the Settings orphaned-WAV finder" instead, so the grep gate holds.

## Issues Encountered
None. The `[Calendar] Failed to decode calendar events` and `Notification auth failed` lines in the test log come from existing tests and the headless host, and are expected.

## TDD Gate Compliance
Both tasks have a `test(20-02)` RED commit followed by a `feat(20-02)` GREEN commit. No refactor commit was needed.

## Next Phase Readiness
- 20-06 can call `AudioFileManager.removeFileIfPresent(at:)` for the D-07 "unusable video" delete
- 20-07 owns the README "Known gaps" bullet (D-12); the deletion half of that gap is closed by this plan
- No blockers

## Self-Check: PASSED
- FOUND: Tests/MediaFileTests.swift, Sources/Storage/AudioFileManager.swift, Sources/Storage/Database.swift, Sources/App/AppState.swift, Sources/UI/MainWindow/MeetingDetailView.swift
- FOUND commits: a3b2b25, 9e92637, bee5143, 0cc049f

---
*Phase: 20-video-storage-retention*
*Completed: 2026-11-19*

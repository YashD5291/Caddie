---
phase: 20-video-storage-retention
plan: 03
subsystem: storage
tags: [video, avfoundation, inspection, d-07, test-double]

# Dependency graph
requires:
  - phase: 18-screen-capture-engine
    provides: "The `AVURLAsset.load(.isPlayable, .duration)` core in `ScreenRecorderHarness.runValidateMode` (copied, not called)"
provides:
  - "VideoInspection (isPlayable, durationSeconds, videoTrackCount) with `isUsable` encoding D-07"
  - "VideoInspectionResult: .missing / .inspected(VideoInspection) / .unreadable(String)"
  - "protocol VideoFileInspecting: Sendable - the coordinator's injection seam"
  - "AVAssetVideoInspector - production conformer (load isPlayable + duration, loadTracks(.video))"
  - "MockVideoInspector (Tests/Mocks) - lock-guarded scripted inspector for 20-06 coordinator tests"
affects: [20-06 coordinator finalize/verify (injects VideoFileInspecting, acts on the verdict), 20-08 phase verification, milestone-close A2 re-run on macOS 14.2]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Synthetic .mov fixtures: AVAssetWriter + AVAssetWriterInputPixelBufferAdaptor (32BGRA pool buffers) written only under a per-test temp dir"
    - "Bounded isReadyForMoreMediaData wait (~2 s) that fails the test instead of hanging it"
    - "AVFoundation errors become a typed verdict (`.unreadable(\"domain code: description\")`), never a silent catch"

key-files:
  created:
    - Sources/Storage/VideoFileInspector.swift
    - Tests/Mocks/MockVideoInspector.swift
    - Tests/VideoFileInspectorTests.swift
  modified: []

key-decisions:
  - "20-03: D-07 usability is a new production inspector (AVAssetVideoInspector) that copies the Phase 18 harness load core plus a video-track count; the DEBUG harness stays untouched so the kill-9 gate keeps its validated path"
  - "20-03: A missing path short-circuits to .missing before any AVFoundation load, so the caller can tell 'nothing to delete' from 'unreadable, delete it'; a non-finite duration reads as 0"

patterns-established:
  - "Inspector never mutates the inspected file; deletion is the caller's decision"
  - "Test doubles reached from an actor guard every field with one NSLock (no unguarded counters)"

requirements-completed: []  # STOR-01 verification leg delivered here; the link is written and verified by 20-06, so completion is marked there / in 20-08 (same as 20-01)

# Metrics
duration: 6min
completed: 2026-11-19
---

# Phase 20 Plan 03: Video File Inspector Summary

**A `Sendable` inspection contract and an AVFoundation inspector that judge a finalized `.mov` usable only when it is playable, longer than 0 s, and has a video track, with `.missing` kept separate from `.unreadable`. Both are proven against synthetic temp-dir fixtures, and a lock-guarded mock is ready for 20-06.**

## Performance

- **Duration:** ~6 min
- **Started:** 2026-11-19T13:24:46Z
- **Completed:** 2026-11-19T13:30:20Z
- **Tasks:** 2 (each RED + GREEN commit)
- **Files modified:** 3 (3 created)

## Accomplishments
- `VideoInspection.isUsable` holds the D-07 rule `isPlayable && durationSeconds > 0 && videoTrackCount > 0`. A one-frame file (0.067 s, RESEARCH B3) stays usable
- `VideoInspectionResult` separates `.missing` (nothing on disk, nothing to delete) from `.unreadable(String)` (a file AVFoundation cannot open, so the caller deletes it)
- `AVAssetVideoInspector` checks `fileExists` first, then `load(.isPlayable, .duration)` and `loadTracks(withMediaType: .video)` on a local `AVURLAsset`. Errors become `"<domain> <code>: <description>"`. The file has no `try?` and no force-unwrap. A NaN duration reads as 0
- `MockVideoInspector`: `defaultResult` (default `.inspected(usable)`), `setResult(_:for:)` keyed by `lastPathComponent`, `inspectedURLs` in call order, and `inspectCallCount`. One `NSLock` guards every field
- 12 `VideoFileInspectorTests`. 6 cover the rule and the mock. 6 run real AVFoundation against fixtures: a missing path, a 15-frame 15 fps H.264 320x240 movie (≈1.0 s, 1 track, usable), a 0-byte file, a sessionless writer's output, 4 KB of random bytes, and a check that inspection leaves existence and size unchanged

## Task Commits

1. **Task 1: inspection contract, usability rule, lock-guarded mock** - `087b855` (test, RED), `ed1ee66` (feat, GREEN)
2. **Task 2: AVFoundation inspection on synthetic .mov fixtures** - `9f2e15b` (test, RED), `2f0ab5d` (feat, GREEN)

## Files Created/Modified
- `Sources/Storage/VideoFileInspector.swift` - `VideoInspection`, `VideoInspectionResult`, `VideoFileInspecting`, `AVAssetVideoInspector`
- `Tests/Mocks/MockVideoInspector.swift` - scripted, lock-guarded test double (Tests only. `grep MockVideoInspector Sources` = 0)
- `Tests/VideoFileInspectorTests.swift` - rule, mock, and fixture tests. Fixtures live under `// MARK: - Fixtures` and write only to `temporaryDirectory/<UUID>`

## Verification
- RED confirmed for both tasks: compile failures on the missing `VideoInspection` / `MockVideoInspector`, then on `AVAssetVideoInspector`
- `-only-testing:CaddieTests/VideoFileInspectorTests`: 6 tests after Task 1, 12 after Task 2, `** TEST SUCCEEDED **`
- `make test`: **378 tests, 0 failures**, `** TEST SUCCEEDED **` (baseline 366 + 12 new)
- All acceptance greps pass. `try?` count is 0 in the inspector. `audioDirectory` count is 0 in the test file. `git diff --stat -- Sources/Recording/ScreenRecorderHarness.swift` is empty. All 6 Task 2 test names are present
- No new compiler warnings in the three files under Swift 6 strict concurrency

## Decisions Made
- A new production inspector instead of calling the harness. The harness is `#if DEBUG`, returns `Never`, and calls `exit()`
- `.missing` is decided before any AVFoundation load (RESEARCH F: the load would otherwise throw -11800 and look like "unreadable")
- STOR-01 is not marked complete here. This plan builds only the verification half. 20-06 writes and verifies the link (same choice 20-01 made)

## Deviations from Plan

None. Plan executed exactly as written. One naming note: PATTERNS sketched the mock knob as `scriptedResult`, but the plan's interfaces block (the contract 20-06 consumes) names it `defaultResult` and adds per-file `setResult(_:for:)`. The interfaces block was followed.

## Issues Encountered
None. RESEARCH A2 (14.2 parity of the -11829 verdicts and the one-frame result) is still unverified on this 26.5 machine. It is already queued for the milestone-close 14.2 re-run.

## TDD Gate Compliance
Both tasks have a `test(20-03)` RED commit followed by a `feat(20-03)` GREEN commit. No refactor commit was needed.

## Next Phase Readiness
- 20-06 can inject `videoInspector: VideoFileInspecting = AVAssetVideoInspector()` into `RecordingCoordinator` and drive tests with `MockVideoInspector` (`setResult(.unreadable(...), for: videoURL)` to force the D-07 delete)
- No blockers

## Self-Check: PASSED
- FOUND: Sources/Storage/VideoFileInspector.swift, Tests/Mocks/MockVideoInspector.swift, Tests/VideoFileInspectorTests.swift
- FOUND commits: 087b855, ed1ee66, 9f2e15b, 2f0ab5d

---
*Phase: 20-video-storage-retention*
*Completed: 2026-11-19*

---
phase: 20-video-storage-retention
fixed_at: 2026-11-20T00:10:00+05:30
review_path: .planning/phases/20-video-storage-retention/20-REVIEW.md
iteration: 1
findings_in_scope: 10
fixed: 10
skipped: 0
status: all_fixed
committed: true
commit_gate: approved (commits 213464c..b9edb92)
---

# Phase 20: Code Review Fix Report

**Fixed at:** 2026-11-20T00:10:00+05:30
**Source review:** .planning/phases/20-video-storage-retention/20-REVIEW.md
**Iteration:** 1

**Summary:**
- Findings in scope: 10 (fix_scope: all)
- Fixed: 10
- Skipped: 0
- Committed: none yet. The user's global rule says to ask before every commit, even when another agent asks for one. So every fix is ready as a verified per-finding patch, but nothing has been committed.
- Final gate: `make test` reported `** TEST SUCCEEDED **` with 435 tests and 0 failures (baseline 426, plus 9 new tests).

## Commit status (read first)

All 10 fixes were built and tested in an isolated worktree, one finding at a time, with TDD (red, then green). Each finding was saved as a patch:

`/private/tmp/claude-501/-Users-yashdesai-Codebase-Fun-Caddie/bf261333-25c1-4294-950d-fba816e2e076/scratchpad/patches/NN-<ID>.patch`

Applied in order onto HEAD `6033e27`, the patches reproduce the tested tree exactly (tree `229b55f`). The main checkout has not been touched.

After the user approves, run:

`/private/tmp/claude-501/-Users-yashdesai-Codebase-Fun-Caddie/bf261333-25c1-4294-950d-fba816e2e076/scratchpad/patches/apply-and-commit.sh`

The script makes the 10 atomic `fix(20): ...` commits, each with a what-and-why body and no Co-Authored-By line. It refuses to run if:
- the current branch is not `feature/20-video-storage-retention`
- HEAD is no longer `6033e27`
- the index already has staged changes

It never stages `.planning/config.json` or `appcast.xml`, and it does not push. The scratchpad does not survive a reboot, so apply the patches in this session.

## Fixed Issues

### CR-01: Orphan sweep permanently deletes older videos once a recreated or stale-restored database has even one row

**Status:** fixed: requires human verification (logic change)
**Files modified:** `Sources/Storage/AudioFileManager.swift`, `Tests/MediaFileTests.swift`, `README.md`
**Commit:** pending user approval (patch `01-CR-01.patch`)
**Applied fix:**
- **Behavior:** `cleanupOrphanedVideos` now deletes a row-less `.mov` only when it has no sibling `.m4a` or `.wav`. Otherwise it logs a warning and keeps the file. The zero-row D-14 guard is unchanged.
- **New test:** `testSweepKeepsRowlessMovThatStillHasAudio` failed on the old code.
- **Existing test:** the fixture in `testSweepDeletesOnlyRowlessMovFiles` now uses `stray.wav` and `stray.m4a` instead of `orphan.wav` and `orphan.m4a`, so the `.mov` under test is still a real orphan. Its intent is unchanged.
- **README:** the orphan bullet now says the sweep also skips a video while the meeting's audio is still there.

### WR-01: Any AVFoundation load error deletes the video, including transient I/O and service failures

**Status:** fixed: requires human verification (logic change)
**Files modified:** `Sources/Storage/VideoFileInspector.swift`, `Sources/Coordinator/RecordingCoordinator.swift`, `Tests/Mocks/MockVideoInspector.swift`, `Tests/VideoFileInspectorTests.swift`, `Tests/RecordingCoordinatorVideoStorageTests.swift`
**Commit:** pending user approval (patch `02-WR-01.patch`)
**Applied fix:**
- **Measured first.** On this macOS host, a standalone probe gave:
  - A 0-byte file, 4 KB of random bytes, 4 KB of zeros, and a sessionless `AVAssetWriter` output (which is 0 bytes) all fail with `AVFoundationErrorDomain -11829` (`fileFailedToParse`, underlying `-12848`).
  - A file with mode `000` fails with `NSCocoaErrorDomain 257`.
- **New verdict:** `VideoInspectionResult` has a new `.inconclusive(String)` case.
- **Inspector changes:**
  - `AVAssetVideoInspector` treats a 0-byte file as `.unreadable` up front.
  - A new `static func classify(_:)` maps only `AVFoundationErrorDomain` `-11828` and `-11829` to `.unreadable`. Everything else is `.inconclusive`, including I/O, permission errors, `-11819` media services reset, unknown errors, and cancellation.
- **Coordinator:** on `.inconclusive`, it keeps the file, the link, and the anchor, and logs an error.
- **Mock:** `MockVideoInspector` already returns any scripted verdict. Only its doc comment changed.
- **Tests:**
  - New: a permission-denied real-file case, the two classification tables, and a coordinator test that checks an inconclusive probe keeps the video and its link.
  - Existing: the 0-byte, sessionless, and garbage-file tests still pass as `.unreadable`.
  - The red run was a compile failure, because the new API did not exist yet. The probe had already shown that the old code classified the permission error as `.unreadable`.

### WR-02: `linkVideo` reports success when the meeting row is gone, so a deleted meeting's usable video stays on disk

**Status:** fixed: requires human verification (logic change)
**Files modified:** `Sources/Coordinator/RecordingCoordinator.swift`, `Tests/RecordingCoordinatorVideoStorageTests.swift`
**Commit:** pending user approval (patch `03-WR-02.patch`)
**Applied fix:**
- **`linkVideo`:** returns `db.changesCount` from the write. When 0 rows changed, it logs a warning and returns `false`.
- **Row check:** after inspection, `reconcileFinalizedVideo` checks whether the meeting row still exists, using a new `isMeetingDeleted`. If the row is gone, it removes the file whatever the verdict. A failed read logs an error and keeps the current behavior, so it never deletes.
- **Why the check runs after inspection:** the existing `testMeetingDeletedMidRecordingDoesNotCrash` keeps its "still inspected" assertion, and the check sits closer to the keep decision.
- **New test:** `testUsableVideoOfDeletedMeetingIsRemovedOnFinalize` failed on the old code.
- **Untested part:** the `changesCount` change only affects logging and the return value. In these paths the row check is what removes the file, so it has no separate test.
- **Not done:** the optional "disable Delete while recording" UI change, which the review lists as a separate quick task.

### WR-03: The new init defaults made the Phase 19 screen-capture suites depend on the host's free disk space and the real media directory

**Status:** fixed
**Files modified:** `Tests/RecordingCoordinatorScreenCaptureTests.swift`, `Tests/RecordingCoordinatorScreenCaptureTeardownTests.swift`, `Tests/RecordingCoordinatorDiskGuardTests.swift`
**Commit:** pending user approval (patch `04-WR-03.patch`)
**Applied fix:**
- **Phase 19 helpers:** both `makeCoordinator` helpers now inject:
  - `availableDiskSpace: { Int64.max }`
  - `MockVideoInspector()`
  - a per-test temp `videoDir`, created in `setUp` and removed in `tearDown`
- **Path test:** `testVideoOutputPathIsMeetingMov` now compares against `AudioFileManager.videoPath(for:in: videoDir)`.
- **Also fixed (same D-15 defect, not named in the finding):** `RecordingCoordinatorDiskGuardTests` already injected capacity. Its video-enabled starts still used the real inspector and the real media directory, so it now gets the same inspector and temp-directory seams.
- **Not changed:** `makeCoordinatorWithoutVideo` has no video path, and its 500 MB floor dependency predates Phase 20.

### WR-04: A timing race in `testLateFinalizeAcrossSecondMeetingTargetsOwnRow` can make the test flaky

**Status:** fixed
**Files modified:** `Tests/RecordingCoordinatorVideoStorageTests.swift`
**Commit:** pending user approval (patch `05-WR-04.patch`)
**Applied fix:**
- The 800 ms `finalizeDelay` is gone.
- `factory.neverFinalize = true` is set before meeting #1 and reset to `false` before meeting #2 is vended.
- After meeting #2 links, the test calls `factory.instances.first.simulateFinalize()` and then asserts meeting #1's reconcile.
- The test passed 5 of 5 runs with `-test-iterations 5`.

### IN-01: The low-disk message appears under a contradictory menu bar prefix

**Status:** fixed
**Files modified:** `Sources/Coordinator/RecordingCoordinator.swift`, `Sources/UI/MenuBar/MenuBarView.swift`, `Tests/RecordingCoordinatorDiskGuardTests.swift`, `Tests/RecordingCoordinatorScreenCaptureTests.swift`
**Commit:** pending user approval (patch `06-IN-01.patch`)
**Applied fix:**
- **Where the headline comes from:** only the coordinator knows whether video was skipped or stopped, so it now composes the whole warning line.
  - `surfaceVideoError` takes a `headline` argument. It defaults to `videoStoppedHeadline`, which is "Screen recording stopped — audio was saved".
  - The low-disk skip passes `videoSkippedHeadline`, which is "Screen recording".
- **Menu bar:** `MenuBarView` renders "⚠️ \(videoError)" verbatim.
- **What the user sees:**
  - Every stop-after-start warning reads exactly as before.
  - The low-disk skip now reads "⚠️ Screen recording: Not enough free disk space for video (…) — this meeting is recording audio only".
- **README:** no change needed. "the menu bar says why" is still accurate.
- **Tests:**
  - New: `testLowDiskMessageUsesNeutralHeadline`.
  - Added headline assertions to the existing start-failure and stream-death tests.
  - All three failed on the old code.
- **Alternative not taken:** a one-line neutral prefix for every message. It was rejected because it would change the stop-after-start copy.

### IN-02: The README orphan example is wrong, and the automatic deletion of unusable videos is undocumented

**Status:** fixed
**Files modified:** `README.md`
**Commit:** pending user approval (patch `07-IN-02.patch`)
**Applied fix:**
- The example now reads "for example, from a meeting deleted in an earlier version".
- A new bullet, "Unplayable videos are removed", says that an empty or unplayable video is deleted and the meeting is kept as audio-only. It also says a video Caddie cannot check is kept, which matches WR-01.

### IN-03: `discardUnusableVideo` deletes before it unlinks and reports success either way

**Status:** fixed: requires human verification (ordering and state change)
**Files modified:** `Sources/Coordinator/RecordingCoordinator.swift`, `Tests/RecordingCoordinatorVideoStorageTests.swift`
**Commit:** pending user approval (patch `08-IN-03.patch`)
**Applied fix:**
- **`unlinkVideo`:** returns `Bool`.
- **`discardUnusableVideo`:** unlinks first.
  - If the unlink fails, it keeps the file, logs "Kept unusable video … because unlinking it failed", and returns `true` (still linked).
  - Otherwise it deletes the file and logs what actually happened.
- **`.missing` branch:** now reports whether the row is still linked.
- **New test:** `testFailedUnlinkKeepsUnusableVideoFile` uses a test-only SQLite trigger that aborts clearing `video_file`. It failed on the old code.

### IN-04: The disk guard measures the audio directory's volume, not the injected video directory

**Status:** fixed: requires human verification (wiring change)
**Files modified:** `Sources/Coordinator/RecordingCoordinator.swift`, `Tests/RecordingCoordinatorDiskGuardTests.swift`
**Commit:** pending user approval (patch `09-IN-04.patch`)
**Applied fix:**
- **Init:** `availableDiskSpace` is now `DiskSpaceProvider? = nil`. When it is nil, `init` builds the provider from `videoDirectory` through `systemAvailableDiskSpace(at:)`.
- **Production:** no change, because `videoDirectory` is the audio directory there.
- **New test:** `testDefaultCapacityProviderMeasuresTheVideoDirectory` failed on the old code. The old code ignored the injected directory and started the meeting.
- **Trade-off:** one capacity snapshot still decides both tiers. A video directory that cannot be measured therefore blocks the start, just as an unmeasurable audio directory did before.

### IN-05: `VideoContext.firstFrameTicks` is write-only state in release builds

**Status:** fixed
**Files modified:** `Sources/Coordinator/RecordingCoordinator.swift`
**Commit:** pending user approval (patch `10-IN-05.patch`)
**Applied fix:** The doc comment now marks the field as test-only state. Its only reader is the DEBUG `videoAnchorPair`, and the persisted offset comes from the funnel's own copy. This is a comment-only change, per the orchestrator's classification.

## Verification

- **Per-finding gates:** each finding was gated with `-only-testing` runs of the classes it touched. Behavioral fixes were confirmed red before the fix and green after.
- **Final run:** `make test` in the worktree reported `** TEST SUCCEEDED **`, 435 tests, 0 failures.
- **New tests (9):**
  - CR-01: 1
  - WR-01: 4
  - WR-02: 1
  - IN-01: 1
  - IN-03: 1
  - IN-04: 1
- **XcodeGen:** no test files were added, so no new files needed registering.
- **Pre-existing leak:** each coordinator-suite run still writes row-less WAVs to the real `audio/` directory, through the real `AudioRecorder` (known deferred item D-1/D-2). That includes the IN-04 red run, which started one real recording. This fix pass does not change that.

---

_Fixed: 2026-11-20T00:10:00+05:30_
_Fixer: Claude (gsd-code-fixer)_
_Iteration: 1_

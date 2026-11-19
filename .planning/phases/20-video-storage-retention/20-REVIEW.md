---
phase: 20-video-storage-retention
reviewed: 2026-11-19T17:57:35Z
depth: standard
files_reviewed: 23
files_reviewed_list:
  - README.md
  - Sources/App/AppState.swift
  - Sources/Coordinator/RecordingCoordinator.swift
  - Sources/Recording/ScreenRecorder.swift
  - Sources/Recording/ScreenRecording.swift
  - Sources/Storage/AudioFileManager.swift
  - Sources/Storage/Database.swift
  - Sources/Storage/Meeting.swift
  - Sources/Storage/Migrations.swift
  - Sources/Storage/VideoFileInspector.swift
  - Sources/UI/MainWindow/MeetingDetailView.swift
  - Sources/UI/Settings/SettingsView.swift
  - Tests/DiskSpaceTierTests.swift
  - Tests/MediaFileTests.swift
  - Tests/MeetingModelTests.swift
  - Tests/MigrationTests.swift
  - Tests/Mocks/MockScreenRecorder.swift
  - Tests/Mocks/MockVideoInspector.swift
  - Tests/ProtocolDITests.swift
  - Tests/RecordingCoordinatorDiskGuardTests.swift
  - Tests/RecordingCoordinatorVideoStorageTests.swift
  - Tests/VideoFileInspectorTests.swift
  - Tests/WriterSinkFinalizeTests.swift
findings:
  critical: 1
  warning: 4
  info: 5
  total: 10
status: issues_found
---

# Phase 20: Code Review Report

**Reviewed:** 2026-11-19T17:57:35Z
**Depth:** standard
**Files Reviewed:** 23
**Status:** issues_found

## Summary

I reviewed the Phase 20 diff (`a0302b9..HEAD`) for all 23 listed files. I checked it against D-01..D-16 and the research pitfalls. I also traced the callers and callees that the new code depends on: `TranscriptionPipeline.enqueue`, `MenuBarView`, every writer to the `meetings` table, and the Phase 19 coordinator test suites, which pick up the new init defaults.

The core mechanics are sound:
- **Migration:** v2 is ADD COLUMN only, and FTS isolation is proven by a test.
- **Engine signal:** the `onFinalized` contract is exactly-once on every engine path (stop, stream error, writer not writing, double finalize).
- **Event stream:** the per-meeting `AsyncStream` keeps link-before-verdict ordering and attributes late finalizes to the right meeting.
- **Database writes:** all of them are targeted `UPDATE`s, so nothing can clobber the new columns.
- **Disk guard:** the two-tier decision reads capacity once and is published after `.recording`.

Main concerns:
- The orphan sweep's D-14 guard only covers a database with zero rows. A recreated database with one row, or a stale backup, still deletes videos permanently (CR-01).
- Any AVFoundation load error is treated as "unusable" and the video is deleted (WR-01).
- Finalize does not notice that the meeting row was deleted (WR-02).
- The new init defaults quietly made the Phase 19 suites depend on the host's real free space and on the real media directory (WR-03).

Not re-reported (known or deferred): D-16 Settings `.wav` cleanup hazard; D-1/D-2 test host opening the real DB and tests leaving row-less audio in the real `audio/` directory; D-3 quit mid-recording leaves rows in `recording`; D-4 log id redaction.

## Narrative Findings (AI reviewer)

## Critical Issues

### CR-01: Orphan sweep permanently deletes older videos once a recreated or stale-restored database has even one row

**File:** `Sources/Storage/AudioFileManager.swift:371-380` (called from `Sources/App/AppState.swift:106`)
**Issue:** The only protection against a lost database is `guard !ids.isEmpty`. Research Pitfall 5 describes the failure as a read that succeeds "with 0 **or few** rows (user deleted it, restored a stale backup)". The implementation handles only the zero-row case. Two realistic paths still delete user recordings for good:

1. `caddie.db` is lost or deleted. On launch N, `DatabasePool` creates an empty database and the sweep correctly skips. The user records one meeting. On launch N+1, `ids == {newId}`, so every historical `.mov` is "orphaned" and deleted.
2. The user restores an older `caddie.db` (Time Machine). Every `.mov` recorded after the backup has no row and is deleted at the next launch. Its `.m4a` survives, which leaves the inconsistent state Pitfall 5 warns about.

Both paths break D-14's stated rationale ("A lost or recreated DB must never wipe every video") and the core value ("no lost recordings"). The deletion is irreversible and runs with no prompt.

**Fix:** A real orphan never has sibling audio. Phase 19's `deleteAudio` removed `.wav`/`.m4a` and left only the `.mov`, and `deleteMedia` removes all three. A lost or stale database, by contrast, leaves the meeting's audio in place. So only delete a row-less `.mov` when it also has no sibling audio:

```swift
let fm = FileManager.default
let orphans = videos.filter { url in
    let stem = url.deletingPathExtension().lastPathComponent
    guard !ids.contains(stem) else { return false }
    let hasSiblingAudio = ["m4a", "wav"].contains { ext in
        fm.fileExists(atPath: directory.appendingPathComponent("\(stem).\(ext)").path)
    }
    if hasSiblingAudio {
        logger.warning("Keeping row-less video \(url.lastPathComponent): its audio still exists, so the database may be stale")
    }
    return !hasSiblingAudio
}
```

Add a `MediaFileTests` case where a row-less `x.mov` plus `x.m4a` survives the sweep while a row-less `y.mov` with no audio is removed.

## Warnings

### WR-01: Any AVFoundation load error deletes the video, including transient I/O and service failures

**File:** `Sources/Storage/VideoFileInspector.swift:45-49`, `Sources/Coordinator/RecordingCoordinator.swift:715-717`
**Issue:** The catch-all turns every thrown error into `.unreadable`, and the coordinator handles `.unreadable` as a D-07 "no usable video" verdict by calling `removeFileIfPresent`. D-07 is a verdict about content ("not playable, or zero duration"). An error that says nothing about the file's content is not that verdict. Examples:
- `AVError.mediaServicesWereReset`
- `NSPOSIXErrorDomain` EIO or EACCES
- memory pressure
- a cancellation

One failed probe, with no retry, can permanently delete a 2-hour recording or a D-06 partial that should be kept. Research assumption A6 ("a local-file open failure is deterministic") does not cover these failure classes.

**Fix:** Delete only on content verdicts. For anything else, keep the file and the link, and log an error. One option is to add an `inconclusive` case:

```swift
} catch {
    let ns = error as NSError
    let contentCodes: Set<Int> = [AVError.Code.fileFormatNotRecognized.rawValue,
                                  AVError.Code.fileFailedToParse.rawValue]
    let detail = "\(ns.domain) \(ns.code): \(ns.localizedDescription)"
    if ns.domain == AVFoundationErrorDomain && contentCodes.contains(ns.code) {
        return .unreadable(detail)      // caller deletes (D-07)
    }
    return .inconclusive(detail)        // caller keeps file + link and logs an error
}
```

Also treat a 0-byte file as `.unreadable` explicitly, so the sessionless or 0-byte case still gets cleaned up.

### WR-02: `linkVideo` reports success when the meeting row is gone, so a deleted meeting's usable video stays on disk

**File:** `Sources/Coordinator/RecordingCoordinator.swift:663-677`, `698-708`; `Sources/UI/MainWindow/MeetingDetailView.swift:36-46`, `293-303`
**Issue:** An `UPDATE` that matches 0 rows does not throw. `linkVideo` therefore logs "Linked video … to meeting …" and returns `true`. The funnel then treats the meeting as linked, and `reconcileFinalizedVideo` logs "Video verified" and keeps the file.

Delete is enabled at every status, and `stop()` returns before `finishWriting` on every path (D-13). So the window is not only "still recording" (research Pitfall 9). It also covers every post-stop finalize, and the 5 s timed-out stop. If the finalize writes the file back after `deleteMedia` removed it, a screen recording the user explicitly deleted stays on disk until the next launch sweep. For a menu bar app that can be weeks. Meanwhile the log claims the file is linked and verified, which breaks the "no silent failures" rule.

**Fix:** Check `changesCount`, and on finalize confirm the row still exists before keeping the file:

```swift
let changed = try await database.dbWriter.write { db -> Int in
    try db.execute(sql: "UPDATE meetings SET video_file = ?, video_start_offset = ? WHERE meeting_id = ?",
                   arguments: [fileName, offset, meetingId])
    return db.changesCount
}
guard changed > 0 else {
    logger.warning("Meeting \(meetingId) no longer exists; video not linked")
    return false
}
```

In the `.finalized` branch, run `SELECT 1 FROM meetings WHERE meeting_id = ?` first. If there is no row, call `AudioFileManager.removeFileIfPresent(at: url)` and return. Optionally, as a separate quick task, disable Delete while `meeting.status == .recording`.

### WR-03: The new init defaults made the Phase 19 screen-capture suites depend on the host's free disk space and the real media directory

**File:** `Sources/Coordinator/RecordingCoordinator.swift:146-148` (affects `Tests/RecordingCoordinatorScreenCaptureTests.swift:31-41` and `Tests/RecordingCoordinatorScreenCaptureTeardownTests.swift:33-43`)
**Issue:** Those helpers pass a mock factory but do not pass `availableDiskSpace`, `videoInspector` or `videoDirectory`, so they now get the production defaults. Two consequences:

- **Free-space dependency.** They now need at least 2,774,288,000 bytes of real free space; before this phase they needed 524,288,000. Below that, every start takes the low-disk branch:
  - `factory.makeCallCount == 1` and `totalStartCount` assertions fail.
  - The message-count assertions see an unexpected "disk space" message.

  These failures depend on the host and look like video regressions.
- **Real media directory.** Their finalize funnel runs the real `AVAssetVideoInspector` and `removeFileIfPresent` against `~/Library/Application Support/Caddie/audio/<id>.mov`, which D-15 forbids. It is harmless today only because the ids are random and the mock writes no file there.

**Fix:** Inject the same seams that `RecordingCoordinatorVideoStorageTests` uses in both helpers: `availableDiskSpace: { Int64.max }`, a per-test temp `videoDirectory`, and `MockVideoInspector()`. If `testVideoOutputPathIsMeetingMov` should keep asserting the canonical path, update it to compare against `AudioFileManager.videoPath(for:in:)` with the temp directory.

### WR-04: A timing race in `testLateFinalizeAcrossSecondMeetingTargetsOwnRow` can make the test flaky

**File:** `Tests/RecordingCoordinatorVideoStorageTests.swift:377-399`
**Issue:** Meeting #1's finalize fires 800 ms after its stop. Before the `inspectCallCount == 0` assertion at line 398, the test has to do all of this:
- handle `.transcriptionComplete`
- start a real `AudioRecorder` (HAL and aggregate-device setup)
- sleep 150 ms inside `startMeeting`
- poll until meeting #2 is linked

On a loaded or cold host this can take longer than 800 ms. The test then fails with "Meeting #2 must have started before meeting #1's finalize landed" even though the production code is correct.

**Fix:** Trigger meeting #1's finalize by hand instead of with a timer:
1. Set `factory.neverFinalize = true` before meeting #1, and set it back to `false` before meeting #2 is vended.
2. Start meeting #2 and wait for its link.
3. Call `factory.instances[0].simulateFinalize()`.
4. Assert the reconcile of meeting #1.

## Info

### IN-01: The low-disk message appears under a contradictory menu bar prefix

**File:** `Sources/Coordinator/RecordingCoordinator.swift:359-363`, `Sources/UI/MenuBar/MenuBarView.swift:75`, `README.md:66`
**Issue:** The user sees "⚠️ Screen recording stopped — audio was saved: Not enough free disk space for video (…) — this meeting is recording audio only". Video never started, and the meeting is still recording. The code comment defers the prefix to Phase 21, but the README already says "the menu bar says why".
**Fix:** Use a neutral prefix now (for example "Screen recording:"), or soften the README wording until Phase 21.

### IN-02: The README orphan example is wrong, and the automatic deletion of unusable videos is undocumented

**File:** `README.md:65`
**Issue:**
- **Wrong example.** "(for example, after a crash)" does not describe a case the sweep handles. A crash-recovered video always has its row, because the row is inserted before capture (D-10), and it is kept (D-06). The real orphans are videos of meetings deleted before this release.
- **Missing behavior.** The README never says that a finalized video that is unplayable or zero-length is deleted automatically (D-07). That is a user-visible removal of data.

**Fix:** Replace the example with "for example, from a meeting deleted in an earlier version". Add one sentence saying that a video that cannot be played is removed and the meeting is kept as audio-only.

### IN-03: `discardUnusableVideo` deletes before it unlinks and reports success either way

**File:** `Sources/Coordinator/RecordingCoordinator.swift:679-690`, `730-738`
**Issue:** `unlinkVideo` swallows its failure. The file is already deleted at that point, so a failed unlink leaves `video_file` pointing at a missing file, which Phase 21 playback will trip over. The log still says "and unlinked it".
**Fix:** Have `unlinkVideo` return `Bool`. Unlink first, then delete the file, and log what actually happened. Leaving an orphan file behind is a safer failure than a dangling link.

### IN-04: The disk guard measures the audio directory's volume, not the injected video directory

**File:** `Sources/Coordinator/RecordingCoordinator.swift:372-376`
**Issue:** `systemAvailableDiskSpace` always reads `AudioFileManager.audioDirectory`, while video is written to the injectable `videoDirectory`. In production they are the same, but the seam lets the video threshold be checked against a different volume than the one being written.
**Fix:** Build the default provider from `videoDirectory` in `init`, or document that the two must share a volume.

### IN-05: `VideoContext.firstFrameTicks` is write-only state in release builds

**File:** `Sources/Coordinator/RecordingCoordinator.swift:120-121`, `263-265`, `627-632`
**Issue:** The only reader is the `#if DEBUG` `videoAnchorPair`. The persisted offset comes from the funnel's own local copy, so in release builds the field is written and never read.
**Fix:** Either mark it as test-only state in its doc comment, or drop it and let `testAnchorPairCapturedInMemory` assert the persisted `video_start_offset` instead.

---

_Reviewed: 2026-11-19T17:57:35Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_

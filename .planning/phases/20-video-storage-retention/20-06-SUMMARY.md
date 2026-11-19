---
phase: 20-video-storage-retention
plan: 06
subsystem: coordinator
tags: [stor-01, stor-04, d-05, d-06, d-07, d-08, d-11, d-13, video, asyncstream, coordinator, finalize]

# Dependency graph
requires:
  - phase: 20-video-storage-retention
    provides: "20-01 video_file / video_start_offset columns; 20-02 videoPath(for:in:) + removeFileIfPresent(at:); 20-03 VideoFileInspecting / AVAssetVideoInspector / MockVideoInspector; 20-04 ScreenRecording.onFinalized + mock finalize knobs; 20-05 availableDiskSpace seam + videoPreset"
  - phase: 19-recording-lifecycle-integration
    provides: "ScreenRecorderFactory, startVideoInner / stopVideo / stopEngineBounded, in-memory anchor pair, non-fatal video channel"
provides:
  - "Per-meeting AsyncStream<VideoEvent> funnel in startVideoInner: onFirstFrameHostTime and onFinalized yield into it, both assigned before start"
  - "persistVideoLifecycle consumer: .firstFrame links video_file + video_start_offset in one targeted UPDATE; .finalized runs the inspector once and keeps, discards, or unlinks"
  - "RecordingCoordinator.videoStartOffset(audioStartTicks:firstFrameTicks:timebase:) - first-frame seconds minus audio-start seconds, reusing ScreenRecorder.hostTicksToSeconds"
  - "Trailing init seams videoInspector (default AVAssetVideoInspector()) and videoDirectory (default AudioFileManager.audioDirectory)"
  - "Start-failure cleanup: the stream is finished and any partial .mov removed"
  - "RecordingCoordinatorVideoStorageTests (17 tests): link, verify, discard, start failure, audio-only, late finalize, meeting #2, stream death, never finalize, missing, wedged stop, row deleted mid-recording"
affects: [20-07 docs/traceability (STOR-04 storage leg now shipped), 20-08 phase verification (hardware row check), 21 playback (reads video_file and video_start_offset)]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Ordered per-meeting event funnel: engine callbacks only yield into an AsyncStream made before start; one actor-isolated consumer Task handles events in order and is never awaited by teardown"
    - "Late-callback handlers take the captured meetingId/url and never read in-flight actor state, so a callback that lands after meeting #2 started still targets its own row"
    - "Mutation check for a by-construction guarantee: temporarily key the handler on the in-flight context, confirm the cross-meeting test fails, revert"

key-files:
  created:
    - Tests/RecordingCoordinatorVideoStorageTests.swift
  modified:
    - Sources/Coordinator/RecordingCoordinator.swift

key-decisions:
  - "20-06: Link early, verify on finalize through one AsyncStream per meeting. The consumer Task is unstructured and unstored, so pipeline.enqueue never waits on finalize or inspection; a quit or wedge simply leaves the consumer waiting with only its own meeting's context"
  - "20-06: A usable verdict on an already-linked row writes nothing (meetings_au re-indexes FTS on every UPDATE); a usable verdict with a failed first link retries the link"
  - "20-06: D-07 discards are logged (error when a linked video is lost, warning when nothing was linked), never surfaced on the video channel, because a late finalize can land during a later meeting"

patterns-established:
  - "waitUntil(timeout:_:) polling helper (25 ms) for positive asynchronous assertions; a fixed 300 ms settle only before negative count assertions"
  - "Coordinator video tests inject a per-test temp videoDirectory and a deterministic availableDiskSpace { Int64.max }"

requirements-completed: [STOR-01, STOR-04]

# Metrics
duration: 16min
completed: 2026-11-19
---

# Phase 20 Plan 06: Per-meeting video link and finalize verification Summary

**Each meeting's `.mov` is linked to its row with its timing offset as soon as the first frame lands. After the engine's finalize signal the file is inspected once: a usable file is kept, an unusable one is deleted and unlinked. All of it runs through one ordered `AsyncStream` per meeting, keyed by meeting id, so late finalizes and meeting #2 cannot cross wires and transcription never waits on it.**

## Performance

- **Duration:** ~16 min
- **Started:** 2026-11-19T14:06:49Z
- **Completed:** 2026-11-19T14:23:08Z
- **Tasks:** 2 (Task 1 RED + GREEN, Task 2 test commit)
- **Files modified:** 2 (1 created, 1 modified)

## Accomplishments
- `startVideoInner` creates `AsyncStream.makeStream(of: VideoEvent.self)` and assigns `onFirstFrameHostTime`, `onFinalized`, and the unchanged `onStreamStopped`, all before `recorder.start(target:)`. The `.mov` path comes from the injected `videoDirectory`
- `persistVideoLifecycle` handles `.firstFrame` by computing `videoStartOffset`, updating the in-memory anchor (now guarded on `meetingId`), and running `UPDATE meetings SET video_file = ?, video_start_offset = ? WHERE meeting_id = ?`. It handles `.finalized` with `reconcileFinalizedVideo`
- `reconcileFinalizedVideo` calls `videoInspector.inspect(url)` once. Usable + linked logs "Video verified" and writes nothing. Usable + not linked retries the link. Unusable or unreadable goes to `discardUnusableVideo` (remove file, unlink, log with the reason). Missing logs a warning and unlinks
- A start failure keeps the existing log, surface, and `videoContext = nil`, then finishes the stream and calls `AudioFileManager.removeFileIfPresent(at: url)`
- `stopVideo`, `stopEngineBounded`, `handleVideoStreamStopped`, `stop()`, and the teardown order are unchanged. `AppState`, `ScreenRecorder`, and `RecordingState` have zero diff, and every existing construction site compiles unchanged through the defaulted seams
- 17 `RecordingCoordinatorVideoStorageTests`: 10 for link/verify/discard (Task 1) and 7 for D-06 finalize paths (Task 2)

## Task Commits

1. **Task 1: per-meeting event funnel, link on first frame, verify or discard on finalize** - `edc2c23` (test, RED), `f543a66` (feat, GREEN)
2. **Task 2: per-meeting reconciliation on every finalize path** - `cde75f8` (test)

## Files Created/Modified
- `Sources/Coordinator/RecordingCoordinator.swift` - `videoInspector` / `videoDirectory` seams, `VideoEvent`, stream wiring and start-failure cleanup in `startVideoInner`, `videoStartOffset`, `hostTimebase`, meeting-keyed `recordFirstFrameAnchor`, `persistVideoLifecycle`, `linkVideo`, `unlinkVideo`, `reconcileFinalizedVideo`, `discardUnusableVideo`
- `Tests/RecordingCoordinatorVideoStorageTests.swift` - temp `videoDir` rig, `waitUntil` / `fetchMeeting` helpers, `StorageErrorCollector`, 17 tests

## Verification
- RED (Task 1): compile failures on the extra `videoInspector` / `videoDirectory` arguments and the missing `videoStartOffset`
- Task 1 command (`RecordingCoordinatorVideoStorageTests`): 10 tests, `** TEST SUCCEEDED **`
- Task 2: all 7 new tests passed on the first run against Task 1's code. Per the plan, `reconcileFinalizedVideo` was temporarily called with `videoContext?.meetingId ?? meetingId`. `testLateFinalizeAcrossSecondMeetingTargetsOwnRow` then failed on 3 assertions: meeting #1 not unlinked, meeting #2 wrongly unlinked, and meeting #2 not linked at the end. The mutation was reverted with `git checkout` of the file, and a grep confirmed it was gone
- Task 2 command (storage + both screen-capture suites + disk guard + `RecordingCoordinatorTests` + live transcription): **68 tests, 0 failures**, `** TEST SUCCEEDED **`
- `make test`: **426 tests, 0 failures**, `** TEST SUCCEEDED **` (409 baseline + 17 new)
- Every acceptance grep passes: makeStream 1, `onFinalized =` 1 (lines 554/555 come before `start(target:` at 584), link UPDATE 1, unlink UPDATE 1, `videoInspector.inspect(` 1, `removeFileIfPresent(at: url)` 2, both seam defaults 1, `videoStartOffset` signature 1, `audioDirectory` in the test file 0, the awk `videoContext` check 0, production `Task.sleep|asyncAfter` 2 (the existing pair in `stopEngineBounded`), and an empty diff on AppState, ScreenRecorder, and RecordingState
- No new compiler warnings in the coordinator. The test file shows the same `setUpWithError` main-actor mutation warnings that every existing `@MainActor` coordinator suite already has

## Decisions Made
- The consumer `Task` captures `self` strongly and is not stored. In the never-finalize case (quit, wedge) it waits indefinitely with only this meeting's id, url, and stream. That is the "harmless" end state RESEARCH Pattern 2 describes, and it needs no stored-task bookkeeping
- `recordFirstFrameAnchor` guards `videoContext?.meetingId == meetingId` and skips its log line when the guard fails, as the old no-context guard did. The persisted link does not depend on that guard
- `linkVideo` takes `offset: Double?` so the usable-but-unlinked retry can run when no first frame was recorded. On the first-frame path the offset is always non-nil

## Deviations from Plan

None. Plan executed exactly as written.

## Issues Encountered
- The rig uses a real `AudioRecorder`, so tests that reach `.recording` still write a WAV into the real audio directory. Every existing coordinator suite already does this (noted in 20-05). All video files and deletions in this suite go through the injected temp `videoDir`, so D-15 holds for video and deletion assertions

## Known Stubs
None.

## TDD Gate Compliance
Task 1 has a `test(20-06)` RED commit (`edc2c23`) followed by a `feat(20-06)` GREEN commit (`f543a66`). Task 2 exercises guarantees that hold by construction, so its tests passed against Task 1's code. The plan anticipates that. The suite's ability to catch the bug was shown with the temporary cross-meeting mutation, which failed it, and the mutation was reverted. No refactor commit was needed.

## Next Phase Readiness
- STOR-01 and the STOR-04 storage leg are delivered. **20-07 note:** its Task 2 sets STOR-04 to `[ ]` / Pending on the premise that "it is not complete until 20-06 ships". 20-06 has now shipped, so 20-07 should keep the new traceability text but mark STOR-04 complete
- 20-08 hardware gate: a real recording should end with `video_file = <id>.mov` and `video_start_offset` near 0.27 s. A stop before the first frame should leave both NULL and no file
- No blockers

## Self-Check: PASSED
- FOUND: Sources/Coordinator/RecordingCoordinator.swift, Tests/RecordingCoordinatorVideoStorageTests.swift
- FOUND commits: edc2c23, f543a66, cde75f8

---
*Phase: 20-video-storage-retention*
*Completed: 2026-11-19*

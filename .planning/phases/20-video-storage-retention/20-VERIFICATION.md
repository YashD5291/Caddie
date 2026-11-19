---
phase: 20-video-storage-retention
verified: 2026-11-19T18:55:27Z
status: passed
score: 52/52 must-haves verified (5 roadmap success criteria + 47 plan truths)
overrides_applied: 0
human_verification:
  - test: "Post-review-fix smoke on HEAD 67d6db9: enable screenRecordingEnabled, record a ~30 s manual meeting, stop, wait for transcription, then delete it from the main window"
    expected: "While recording, the row has video_file = <id>.mov and video_start_offset ~0.1-1.5 s. After stop, the log shows 'Video verified for <id>' (not 'Unlinked and discarded', 'Could not verify', or 'was deleted before its video finalized'). The .mov stays on disk and --validate-mov reports isPlayable=true. After Delete, the <id>.mov and <id>.m4a are gone from the audio directory."
    why_human: "The hardware gate (20-08) ran before the 10 review-fix commits. WR-01 (0-byte pre-check + error classification), WR-02 (row-exists check before keeping) and IN-03 (unlink-then-delete) changed the code that decides whether a finished recording is kept or deleted. Unit tests cover that code with mocks and synthetic AVAssetWriter fixtures, but no real ScreenCaptureKit .mov has gone through the post-fix path. A regression here would delete a user's recording with no prompt. It needs Screen Recording TCC and a real capture, so it cannot be run by the verifier."
---

# Phase 20: Video Storage & Retention Verification Report

**Phase Goal:** Video files are linked to their meeting, cleaned up on deletion, and guarded against disk exhaustion — no orphans, no FTS5 contamination.
**Verified:** 2026-11-19T18:55:27Z (HEAD `67d6db9`, branch `feature/20-video-storage-retention`)
**Status:** passed. All automated checks pass, and the post-fix hardware smoke passed on 2026-11-20 (see the result under Human Verification)
**Re-verification:** No, this is the initial verification

## Goal Achievement

### Observable Truths (Roadmap Success Criteria, as amended by 20-07 for D-01)

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | A recorded meeting's row references its video via a nullable `video_file` column that is absent from the FTS5 index | VERIFIED | `Migrations.swift:71-76` adds `v2_add_video_columns` with ADD COLUMN only. `git diff a0302b9..HEAD` shows `v1_create_meetings` unchanged. FTS table and all 3 triggers name `title, transcript, app` explicitly. `Meeting.swift:25-26,80-81` adds the fields and CodingKeys. Wired: `linkVideo` runs a targeted `UPDATE meetings SET video_file = ?, video_start_offset = ? WHERE meeting_id = ?` on the first frame (`RecordingCoordinator.swift:678-694`). Real DB (read-only): v2 applied, 15 columns, `meetings_fts` = title/transcript/app. Linked row `cab32fda-e3d` is not matched by `MATCH 'cab32fda' OR mov OR "cab32fda-e3d.mov"` (0 rows). Tests: `testVideoFileIsNeverSearchable`, `testVideoColumnUpdateKeepsFTSConsistent`, `testV1DatabaseUpgradesInPlaceAndStaysSearchable`. Hardware check 3: `f4ec2fee-1a8.mov` linked while still recording |
| 2 | Deleting a meeting removes both its audio and video files from disk | VERIFIED | `MeetingDetailView.deleteMeeting()` (line 293-303), the only delete entry point (grep of `Sources/UI`), calls `AudioFileManager.deleteMedia(meetingId:)` after the row delete. `deleteMedia` (`AudioFileManager.swift:259-267`) removes `.wav`, `.m4a` and `.mov` by id, not by column, so unlinked Phase 19 videos are covered too. `deleteAudio` no longer exists. WR-02 also removes a video whose meeting was deleted before its finalize landed (`reconcileFinalizedVideo` → `isMeetingDeleted`). Tests: `testDeleteMediaRemovesWavM4aAndMov`, `testUsableVideoOfDeletedMeetingIsRemovedOnFinalize`. Hardware check 5: UI delete removed `f4ec2fee-1a8.mov` (8.5 MB) and `.m4a`. The real audio directory now has no `f4ec2fee*` files |
| 3 | With screen recording on, starting a recording checks free space against the raised video threshold: below 500 MB it is blocked pre-start as before; below the threshold the video leg is blocked pre-start and the meeting records audio only, with the reason shown | VERIFIED | `evaluateDiskSpace()` reads capacity once (`RecordingCoordinator.swift:395-408`). Only `.belowAudioFloor` throws, and the message is the same `insufficientDiskSpace` as the pre-phase `checkDiskSpace()` (compared against `a0302b9`). The threshold is `minimumDiskSpaceBytes + Int64(preset.bitrate) * 7200 / 8`. Independently recomputed: 1,874,288,000 / 2,774,288,000 / 4,124,288,000 bytes. `Self.videoPreset` is the same constant capture uses (line 598). The video tier applies only when `screenRecorderFactory != nil` (D-03). `belowVideoThreshold` → `skipVideoForLowDisk` runs after audio has started and after `.recording` was published, then calls `surfaceVideoError(..., headline: "Screen recording")` → `AppState.applyVideoError` → `MenuBarView.videoErrorRow`, which renders in both idle and recording. Tests: `DiskSpaceTierTests` (9) and `RecordingCoordinatorDiskGuardTests` (11), all green. Hardware: unit-only by design (20-08 objective: a real full disk is unsafe to produce) |
| 4 | Meetings recorded audio-only leave `video_file` null with no storage side effects | VERIFIED | With no factory, `startVideo` returns at its guard: no engine, no stream, no inspection. The low-disk skip only logs and surfaces; it writes no DB row and touches no file. A missing `.mov` on delete is logged at debug level only (`removeFileIfPresent` catches `.fileNoSuchFile`). Test: `testAudioOnlyMeetingHasNoVideoStorage` asserts columns NULL, 0 engines, 0 inspections, no messages, and an empty video directory. Hardware check 5: only a debug line `No <private> to delete` |
| 5 | A meeting with a usable video stores its video start offset (host-clock anchor) on its row (STOR-04 storage leg) | VERIFIED | `persistVideoLifecycle` computes `videoStartOffset` as first-frame seconds minus audio-start seconds and writes it with `video_file` in one UPDATE. A usable finalize keeps both (`reconcileFinalizedVideo`). Unusable and missing files clear both. Tests: `testVideoStartOffsetIsFirstFrameMinusAudioStart` (Apple Silicon timebase) and `testFirstFrameLinksVideoFileAndOffset`. Hardware: 0.2886 s (check 3) and 0.1511 s (check 4). The real DB still holds `cab32fda-e3d \| cab32fda-e3d.mov \| 0.151108833320905` |

**Score:** 5/5 roadmap success criteria verified

### Plan Must-Have Truths (47)

| Plan | Truths | Status | Notes |
|------|--------|--------|-------|
| 20-01 | 5 | 5 VERIFIED | Schema (TEXT and DOUBLE, nullable, no default) and in-place upgrade are checked by tests and by the real DB (18 rows, 15 columns). v1 is unchanged per the diff. The `Meeting` round-trip is tested |
| 20-02 | 7 | 7 VERIFIED | **The sweep truth was narrowed by CR-01.** The literal "every `.mov` whose meeting id has no row is deleted" no longer holds: a row-less `.mov` that still has `.m4a`/`.wav` is now kept. This is intentional and consistent with D-14 ("a lost or recreated DB must never wipe every video"). Real orphans (Phase 19 `deleteAudio` removed the audio and left the `.mov`) have no sibling audio, so D-10's cleanup purpose still holds. Documented in README and 20-REVIEW-FIX.md, and the commit `213464c` exists. Throw → no delete, empty set → no delete, list-then-read, and the D-16 button and `findOrphanedWAVs` are untouched (diff shows only the label change) |
| 20-03 | 5 | 5 VERIFIED | `isUsable` = playable && duration > 0 && ≥1 video track. A 0-byte file is checked explicitly. Only AVFoundation -11828/-11829 count as `.unreadable`. Everything else is `.inconclusive`, which keeps the file (WR-01). Production uses `AVAssetVideoInspector()` by default. The mock exists only under `Tests/Mocks`. Fixtures live in `temporaryDirectory` |
| 20-04 | 5 | 5 VERIFIED | `onFinalized?()` fires in the not-writing early return (line 587) and in the `finishWriting` completion (line 597). It is idempotent through the existing `transition` guard. The diff is additive only. `WriterSinkFinalizeTests` (5) and the Phase 18 suites are green. Kill-9: run 2 PASS (30.17 s) |
| 20-05 | 6 | 6 VERIFIED | See SC3. The default provider now measures `videoDirectory` (IN-04), which is the audio directory in production. `testCapacityIsReadOncePerStart` and `testLowDiskMessageArrivesAfterRecordingState` pass |
| 20-06 | 8 | 8 VERIFIED | One `AsyncStream` per meeting, with callbacks assigned before `start()` (lines 568-575). The handlers take an explicit `meetingId`/`url` and never read `videoContext`. The consumer Task is never awaited, so `pipeline.enqueue` follows the bounded stop (gate: transcription started at 21:56:45.237, verified at .350). A start failure finishes the stream and removes the file. 20 coordinator storage tests are green |
| 20-07 | 5 | 5 VERIFIED | README "Known gaps" bullet removed; delete, unplayable-removal and low-disk bullets added. STOR-03 wording follows D-01. STOR-04 traceability shows Phase 18 plus Phase 20. ROADMAP SC3/SC5 and the requirements line are updated. `Text("Storage used")` |
| 20-08 | 6 | 6 VERIFIED | Measured in 20-VALIDATION.md checks 1-7. Check 1 was observed as end-state only (P-1 / D-1). Check 7 passed through LaunchServices (D-5) |

### Do the review fixes invalidate the hardware gate?

The gate ran on `898e1d5`. The fixes are `213464c..b9edb92`, and `git diff 6033e27..b9edb92 -- Sources` was checked against each gate check:

| Gate check | Fixes that touch its path | Still valid? |
|------------|---------------------------|--------------|
| 1 Migration | none (`Migrations.swift` untouched) | Yes |
| 2 Sweep keeps real videos | CR-01 makes the sweep strictly more conservative | Yes |
| 3 Link + verify + keep | WR-01: a 0-byte pre-check runs first, which a non-empty file passes, and the catch now classifies errors. WR-02: a row-exists read happens before the keep, and it returns false for a live row. IN-03 affects only the unusable branch. IN-04: production `videoDirectory == audioDirectory` | Yes by analysis. The happy path makes the same decision. **Not re-run on hardware** (see the human item) |
| 4 Quit partial stays linked | none on the no-finalize path | Yes |
| 5 UI delete | none (`deleteMedia` untouched) | Yes |
| 6 Planted orphan swept | CR-01: `zz-phase20-orphan-test.mov` had no `.m4a`/`.wav` sibling, so it still passes the new filter | Yes |
| 7 Kill-9 | none (`ScreenRecorder.swift` untouched by the fixes) | Yes |
| 8 Low disk | IN-01 changed only the headline string. IN-04 changed only the provider's directory | Unit-only; the updated tests are green |

The real library after the post-fix `make test` (which runs the sweep on real data, D-1) still has all 4 row-backed `.mov` files at their gate sizes.

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `Sources/Storage/Migrations.swift` | v2 ADD COLUMN migration | VERIFIED | Exists, substantive, registered in `Migrations.run` |
| `Sources/Storage/Meeting.swift` | `videoFile` / `videoStartOffset` + CodingKeys | VERIFIED | Decoded by `Meeting.search` (`testSearchDecodesVideoFields`) |
| `Sources/Storage/AudioFileManager.swift` | `deleteMedia`, `removeFileIfPresent`, `cleanupOrphanedVideos`, `videoPath(for:in:)` | VERIFIED | Called from MeetingDetailView, AppState and RecordingCoordinator |
| `Sources/Storage/Database.swift` | `meetingIds() throws -> Set<String>` | VERIFIED | Passed as the sweep's id source in `AppState.swift:106` |
| `Sources/App/AppState.swift` | Launch sweep after DB open, before the coordinator exists | VERIFIED | Line 106 runs before `RecordingCoordinator(...)` at line 170 |
| `Sources/Storage/VideoFileInspector.swift` | Protocol + AVFoundation inspector | VERIFIED | Default `videoInspector` in coordinator init |
| `Sources/Recording/ScreenRecorder.swift` / `ScreenRecording.swift` | `onFinalized` | VERIFIED | Assigned at `RecordingCoordinator.swift:569` |
| `Sources/Coordinator/RecordingCoordinator.swift` | Two-tier guard, event funnel, link/verify/discard | VERIFIED | Data flows: engine → stream → targeted UPDATE → real DB row (hardware) |
| `Sources/UI/Settings/SettingsView.swift` | "Storage used" | VERIFIED | Only the label changed |
| `README.md` | D-12 docs | VERIFIED | Lines 65-67 |
| Test files (8 new or extended) and `Tests/Mocks/MockVideoInspector.swift` | Coverage | VERIFIED | All suites passed in the post-fix log |

### Key Link Verification

The `gsd-sdk verify.key-links` tool reported false negatives for symbol-named endpoints and a double-escaped regex, so every link was re-checked by grep.

| From | To | Via | Status |
|------|----|-----|--------|
| Migrations.swift | meetings table | `t.add(column: "video_file"` | WIRED |
| Meeting.swift | video columns | `case videoFile = "video_file"` (line 80) | WIRED |
| MeetingDetailView.deleteMeeting | AudioFileManager.deleteMedia | line 299, after the row delete | WIRED |
| AppState.initialize | AppDatabase.meetingIds | `cleanupOrphanedVideos(knownMeetingIds: appDatabase.meetingIds)` | WIRED |
| VideoFileInspector | AVURLAsset | `loadTracks(withMediaType: .video)` (line 51) | WIRED |
| ScreenRecorder.start | WriterSink.init | `onFinalized: onFinalized` | WIRED |
| WriterSink.finalizeOnQueue | onFinalized | lines 587 and 597 | WIRED |
| executeStartRecording | availableDiskSpace | `evaluateDiskSpace()` (line 434) | WIRED |
| low-disk skip | surfaceVideoError | `lowDiskVideoMessage` (line 549) | WIRED |
| startVideoInner | Self.videoPreset | `preset: Self.videoPreset` (line 598) | WIRED |
| startVideoInner | onFinalized / onFirstFrameHostTime | `recorder.onFinalized = ` before start (line 569) | WIRED |
| persistVideoLifecycle | meetings.video_file / offset | targeted UPDATE (line 682) | WIRED |
| finalize handler | VideoFileInspecting.inspect | line 727, only on `.finalized` | WIRED |
| discard path | AudioFileManager.removeFileIfPresent | lines 786 and 790 | WIRED |

### Data-Flow Trace (Level 4)

| Artifact | Data | Source | Produces real data | Status |
|----------|------|--------|--------------------|--------|
| `meetings.video_file` / `video_start_offset` | file name + offset | `onFirstFrameHostTime` ticks → `videoStartOffset` → UPDATE | Yes: real DB row `cab32fda-e3d.mov` / 0.1511 | FLOWING |
| `AppState.lastVideoError` (low-disk) | message line | `skipVideoForLowDisk` → `onVideoError` → `applyVideoError` | Yes in unit tests with injected capacity. The UI render path is shared with the Phase 19 hardware-verified warning | FLOWING (unit) |
| Launch sweep id set | `Set<String>` | `SELECT meeting_id FROM meetings` | Yes: real run kept 4 row-backed files and removed the planted orphan | FLOWING |

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| Real DB is at v2 with video columns and an unpolluted FTS | `sqlite3 -readonly caddie.db` (migrations, `pragma_table_info`, `meetings_fts` columns) | `v1_create_meetings`, `v2_add_video_columns`; 15 columns; FTS = title, transcript, app | PASS |
| Video filename is not searchable on real data | `MATCH '"cab32fda" OR mov OR "cab32fda-e3d.mov"'` joined to rows with `video_file NOT NULL` | 0 | PASS |
| Threshold arithmetic | `python3 -I -c` recompute | `[1874288000, 2774288000, 4124288000]` | PASS |
| Real media state after the post-fix test run | `ls audio/*.mov` | 4 `.mov`, all with rows, same sizes as the gate | PASS |
| Full suite on HEAD | existing `maketest-postfix.log` (run 00:10 IST, after the fix commits at 00:09:46) | `Executed 435 tests, with 0 failures`, `** TEST SUCCEEDED **`; all 11 Phase 19/20 suites listed as passed | PASS |

`make test` was not re-run because it writes into the real audio directory (D-1/D-2).

### Probe Execution

No `scripts/*/tests/probe-*.sh` exist and no plan declares one. `scripts/kill9-recovery-gate.sh` needs Screen Recording TCC and an app launch, so it was not re-run. Its result is recorded in gate check 7, and `ScreenRecorder.swift` has not changed since.

### Requirements Coverage

| Requirement | Source Plans | Description | Status | Evidence |
|-------------|--------------|-------------|--------|----------|
| STOR-01 | 20-01, 03, 04, 06, 08 | Video stored beside the audio and linked through a nullable `video_file`, never in FTS5 | SATISFIED | SC1 |
| STOR-02 | 20-02, 07, 08 | Deleting a meeting deletes its video along with the audio | SATISFIED | SC2 |
| STOR-03 | 20-05, 07, 08 | Two-tier disk guard (D-01 wording) | SATISFIED | SC3 (low-disk tier unit-verified) |
| STOR-04 | 20-01, 06, 07, 08 | Host-clock anchor persisted with the meeting (storage leg) | SATISFIED | SC5. Traceability fixed to "Phase 18 (engine anchor), Phase 20 (persisted with the meeting)" |

No orphaned requirement IDs: REQUIREMENTS.md maps exactly STOR-01..04 to Phase 20, and every one is claimed by at least one plan.

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| All 26 phase-modified files | — | TBD / FIXME / XXX / TODO / HACK / placeholder | None found | — |
| `Sources/Coordinator/RecordingCoordinator.swift` | 893 | `try? await Task.sleep` | Info | Pre-existing (Phase 19). Timeout sleep, intentional |
| `Sources/App/AppState.swift` (test host) | 106 | Destructive sweep runs on the real `audio/` directory during every `make test` (D-1) | Warning | Breaks the spirit of D-15. Deferred as D-1. CR-01 reduces the blast radius. Not a Phase 20 SC failure |
| `Sources/Coordinator/RecordingCoordinator.swift` | 678-694, 753-775 | Error paths without tests: `isMeetingDeleted` read failure (keeps the file), `linkVideo` 0-row return, `.missing` unlink failure | Warning | All log explicitly and fail toward keeping data. Coverage gap only |
| `Tests/RecordingCoordinatorDiskGuardTests.swift` | 265 | `testLowDiskMessageArrivesAfterRecordingState` checks the coordinator's callback order, not AppState's two `Task { @MainActor }` hops | Info | Ordering is safe by construction: the `await MainActor.run` device lookup in `executeStartRecording` drains the `.recording` hop before the skip fires |

### Disconfirmation Pass

- **Partially met:** the "no orphans" part of the goal is met for video under CR-01's definition (row-less and audio-less). A row-less `.mov` that still has audio is kept indefinitely by design. Separately, the 3 pre-Phase-20 dev videos (`24204cea-ff5`, `68d4c389-96d`, `884dbf89-a39`) have rows but `video_file = NULL`. D-05 chose no backfill. Deletion still removes them by id, but Phase 21 playback will not see them.
- **Test that under-tests its claim:** see the low-disk ordering row above.
- **Uncovered error paths:** see the warning row above.

### Human Verification Required

#### 1. Post-review-fix hardware smoke of the keep/delete decision

**Test:**
1. Run `defaults write com.caddie.app screenRecordingEnabled -bool true`, then launch the HEAD build.
2. Record a ~30 s manual meeting and stop it.
3. Wait for `done`, then delete the meeting from the main window.
4. Restore the default afterwards with `defaults delete com.caddie.app screenRecordingEnabled`.

**Expected:**
- While recording, the row is linked with an offset of about 0.1–1.5 s.
- After the stop, the log shows `Video verified for <id>`. It must not show `Unlinked and discarded`, `Could not verify`, or `was deleted before its video finalized`.
- `--validate-mov` reports `isPlayable=true`.
- After the delete, `<id>.mov` and `<id>.m4a` are gone.

**Why human:**
- The only end-to-end run of a real SCK `.mov` through the reconcile path predates WR-01, WR-02 and IN-03.
- A wrong verdict deletes the user's recording permanently.
- The test needs TCC and a real capture.
- Gate checks 3 and 5 repeated on the current build are enough. If the developer accepts the analysis in the table above, this can be waived.

**Result (2026-11-20, agent-driven on the 00:10:18 build of HEAD `67d6db9`): PASSED**
- **Launch:** `open -n` at 00:28:48 IST (PID 64396). Log: `Screen recording enabled`. No orphan-video line.
- **Start (AX menu, 00:29:08):** `ScreenRecorder started … -> 323f5742-61f.mov`, then `Video anchor for <id>: … offset=0.193s` and `Linked video <id> to meeting <id>`. `sqlite3 -readonly` while recording: `323f5742-61f | 323f5742-61f.mov | 0.193064874998527 | recording`.
- **Stop (00:29:28):** `ScreenRecorder writer finalized` at 00:29:29.008, then `Video verified for <id>: 20.3s, 1 track(s)` at 00:29:29.026. None of `Unlinked and discarded`, `Could not verify` or `was deleted before its video finalized` appeared. Row after transcription: `… | 0.193064874998527 | done`. Files: `.mov` 5,789,242 B, `.m4a` 13,812 B. `--validate-mov`: `VALIDATE isPlayable=true duration=20.298333333333332`, exit 0. The recording was about 20 s rather than 30 s, which is still a real SCK `.mov` through the post-fix reconcile path.
- **Delete (main window via AX, 00:31:01):** the row was matched by the detail pane ("12:29 AM – 12:29 AM", "0:20") before Delete was pressed. After: the row count for `323f5742-61f` is 0 (total 18), `ls | grep -c 323f5742` = 0, and the other 4 `.mov` are unchanged. Log: only a debug `No <private> to delete` (the compressed `.wav`).
- **Cleanup:** Caddie quit, `screenRecordingEnabled` deleted (`does not exist`), and the log stream stopped.

### Accepted Limitations (not gaps)

- **Low-disk tier (SC3) is unit-verified only.** Plan 20-08 decided this, because a real full disk is unsafe to produce. The menu bar row is the Phase 19 hardware-verified `videoErrorRow`, and only its text differs.
- **Deferred items are logged and not counted as Phase 20 gaps.** None of them breaks a Phase 20 success criterion:
  - D-1: the test host touches the real library.
  - D-2: row-less test audio is left in the real audio directory.
  - D-3: a quit mid-recording leaves the row in `recording`. The video side is correct.
  - D-4: log id redaction.
  - D-5: kill-9 script TCC attribution.
  - D-16: the Settings `.wav` cleanup hazard.
  - macOS 14.2 kill-9 re-run at milestone close.
- **Doc hygiene:**
  - The 20-VALIDATION.md frontmatter is still `status: draft`, with per-task rows marked pending.
  - The 20-REVIEW-FIX.md frontmatter says `committed: false`, but the fix commits are on the branch.

### Gaps Summary

No blocking gaps. All 5 roadmap success criteria and all 47 plan must-have truths are backed by code, wiring, passing tests (435/0 on HEAD), the real-library state, and the hardware gate. No review fix logically invalidates a gate result. One human item remains: a short hardware smoke of the keep/delete decision on the post-fix build. The gate's end-to-end evidence predates the fixes to that destructive code path.

---

_Verified: 2026-11-19T18:55:27Z_
_Verifier: Claude (gsd-verifier)_

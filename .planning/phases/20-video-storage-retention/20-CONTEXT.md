# Phase 20: Video Storage & Retention - Context

**Gathered:** 2026-11-19
**Status:** Ready for planning

<domain>
## Phase Boundary

Each meeting's `.mov` is linked to its meeting row, deleted along with the meeting, and protected by a disk guard that accounts for video. The phase also saves the video/transcript timing anchor that Phase 19 currently holds only in memory. No user-facing playback, Settings toggle, or export: those belong to Phase 21.

</domain>

<decisions>
## Implementation Decisions

The user had no preference on the gray areas, so every decision below is Claude's recommended default. **D-01 reinterprets STOR-03 and must be surfaced to the user at plan approval.**

### Disk guard with video enabled (STOR-03)
- **D-01 (reinterprets STOR-03):** The guard has two tiers. Below the existing 500 MB audio floor, recording is **blocked**, exactly as today. Between 500 MB and the video threshold, the meeting **records audio-only**: video is skipped and the reason ("low disk space") is shown through the existing non-fatal video warning channel (`setOnVideoError` / `lastVideoError`). Rationale: the core value says every meeting must be captured, and VID-04 / Phase 19 make audio the senior partner, so video headroom must never prevent an audio recording. The roadmap wording "recording is blocked pre-start" is satisfied for the video leg, since video is blocked before it starts. Update the STOR-03 and ROADMAP success-criterion wording to match.
- **D-02:** Video threshold = 500 MB audio floor + headroom for roughly 2 hours of video at the active preset's bitrate cap (compact 1.5 / balanced 2.5 / high 4.0 Mbps, which is about 1.9 / 2.75 / 4.1 GB in total). The threshold comes from the preset, not a magic number. The planner picks the exact formula.
- **D-03:** The video tier is checked only when screen recording is enabled (the factory is present). Audio-only users see no behavior change and keep the 500 MB guard.

### Linking video to the meeting (STOR-01)
- **D-04:** Add a nullable `video_file` column (filename only, e.g. `<meetingId>.mov`, mirroring `audio_file`) via a new GRDB migration. Do not touch the FTS5 table or its triggers. They list columns explicitly, so the new column stays out of the index automatically. A test must prove it is not searchable.
- **D-05 (amended after research):** Link early, verify after finalize. When the first frame lands, write `video_file` + anchor to the row. When the engine reports finalization (D-13), validate the file: if usable, keep the link; if not, apply D-07. This is the only design that keeps quit/crash partials linked (D-06) without a launch reconciliation pass. A start failure (e.g. TCC denied) or video disabled leaves it null with no file on disk.
- **D-06:** Partial videos (SCK stopped mid-meeting, crash-recovered fragment) are **kept and linked**. A partial recording is still the user's data.
- **D-07:** A `.mov` that finalized with no usable video (not playable, or zero duration, e.g. stopped before the first frame) is **deleted**, `video_file` stays null, and the event is logged with context.

### Timing anchor persistence (STOR-04 storage leg, deferred here by Phase 19)
- **D-08:** Persist the anchor pair (`audioStartTicks`, `firstFrameTicks` from `RecordingCoordinator.videoAnchorPair`) to the meeting row in the same migration. Store it in whatever form Phase 21 playback needs to map transcript time to video time, e.g. a video start offset in seconds and/or the raw host ticks. The planner decides the exact columns. Nullable, and null whenever `video_file` is null. Note: REQUIREMENTS.md marks STOR-04 complete (Phase 18), but persistence was explicitly deferred to Phase 20 by 19-CONTEXT.md and 19-05-SUMMARY.md. Fix the traceability.

### Deletion and orphans (STOR-02)
- **D-09:** Deleting a meeting removes its `.mov` along with its WAV/M4A. Extend the existing file-deletion helper (`AudioFileManager.deleteAudio`, likely renamed to cover all media) rather than adding a parallel path.
- **D-10:** One-time and ongoing orphan cleanup: at launch, delete `.mov` files whose meeting ID has no row. This mirrors the DATA-05 `cleanupOrphanedTempFiles()` launch pattern and clears the videos left behind by meetings deleted since Phase 19 shipped. Safety: the meeting row is inserted before audio/video start (`RecordingCoordinator` ~L363), so every live or crash-recovered `.mov` has a row. **If the DB query fails, skip cleanup entirely.** It must never treat "couldn't read the DB" as "no meetings".
- **D-11:** Audio-only meetings leave `video_file` null and trigger no video file operations or warnings on delete (a missing `.mov` is expected, not an error to log as a failure).

### Decisions resolved after research (user: "best recommended approach, don't wait")
- **D-13:** Add an `onFinalized` completion callback to the Phase 18 `ScreenRecorder` engine. Research proved `stop()` returns before `finishWriting` completes on every path and finalization rewrites the file in place, so there is no other correct signal. Keep the change minimal and additive. Re-run the existing Phase 18 tests, plus the kill-9 harness if feasible, to keep the hardware verification valid.
- **D-14:** Orphan cleanup also skips when the DB has zero meeting rows but `.mov` files exist. A lost or recreated DB must never wipe every video.
- **D-15:** Tests must never touch the real `~/Library/Application Support/Caddie/audio/` directory. Cleanup and deletion tests use injected temp directories. The dev machine already has ~1297 file stems vs 17 rows from earlier test leakage.
- **D-16:** The Settings "Clean Up Orphaned Files" button is **not** extended in this phase. Research found it already deletes every `.wav`, including an in-progress recording's file. That pre-existing hazard is logged as a separate follow-up (see Deferred), not widened here.

### Docs
- **D-12:** README "Screen recording (opt-in, in progress)" section: remove the "Known gaps" bullet about deletion and the disk guard, and document the audio-only fallback when disk is low.

### Claude's Discretion
- Exact migration name and anchor column shape.
- Whether "Audio storage used" is relabeled "Storage used". The total already includes `.mov` because video lives in the audio directory.
- Playability check mechanism for D-07 (AVAsset `isPlayable`/duration vs. reusing the Phase 18 `--validate-mov` logic).
- Where the D-01 tier decision lives (coordinator precondition vs. inside the video start path).

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Scope & requirements
- `.planning/ROADMAP.md` — Phase 20 goal + 4 success criteria
- `.planning/REQUIREMENTS.md` — STOR-01, STOR-02, STOR-03, STOR-04 (traceability fix per D-08); RES-03 (out of scope, see Deferred)

### Prior phase decisions this phase builds on
- `.planning/phases/19-recording-lifecycle-integration/19-CONTEXT.md` — file placement (`videoPath(for:)`), anchor plumbing, non-fatal video error channel, "Phase 20 owns deletion"
- `.planning/phases/19-recording-lifecycle-integration/19-05-SUMMARY.md` — hardware-gate results; anchor offset ~0.27 s; partial `.mov` on quit is playable
- `.planning/phases/19-recording-lifecycle-integration/19-VALIDATION.md` — Finding F1 (context only; RES-04 is not this phase)
- `.planning/phases/18-screen-capture-engine/18-CONTEXT.md` — engine facts (fragmented `.mov`, finalize paths, presets)

### Code
- `Sources/Storage/Migrations.swift` — only `v1_create_meetings` exists; FTS5 table + triggers list columns explicitly
- `Sources/Storage/Meeting.swift` — record + CodingKeys (snake_case mapping)
- `Sources/Storage/AudioFileManager.swift` — `videoPath(for:)`, `deleteAudio(meetingId:)`, `findOrphanedWAVs()`, `cleanupOrphanedTempFiles()`, `totalStorageUsed()`
- `Sources/Coordinator/RecordingCoordinator.swift` — `checkDiskSpace()` / `minimumDiskSpaceBytes` (~L301), meeting insert (~L363), `videoAnchorPair` (~L239), video start/stop paths
- `Sources/Recording/ScreenRecorder.swift` — `Preset.bitrate` (~L255) for the D-02 threshold
- `Sources/Recording/ScreenRecordingSettings.swift` — enablement gate
- `Sources/UI/MainWindow/MeetingDetailView.swift` — `deleteMeeting()` (~L293), the only delete call site
- `Sources/UI/Settings/SettingsView.swift` — storage section + orphan button (~L195)
- `Sources/App/AppState.swift` — launch cleanup call site (~L104), factory construction (~L163)
- `README.md` — "Screen recording (opt-in, in progress)" section (~L59)

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `AudioFileManager.videoPath(for:)`: canonical `.mov` path, already used by Phase 19.
- `AudioFileManager.deleteAudio(meetingId:)`: extend it for video (D-09).
- `AudioFileManager.cleanupOrphanedTempFiles()`: launch-time cleanup pattern to mirror (D-10).
- `RecordingCoordinator.videoAnchorPair`: the in-memory anchor to persist (D-08).
- `ScreenRecorder.Preset.bitrate`: source for the preset-aware threshold (D-02).
- Non-fatal video warning channel (`setOnVideoError` → `lastVideoError` → menu bar orange row): reuse for the low-disk skip message (D-01).

### Established Patterns
- GRDB migrations registered in `Migrations.run`. This is the first migration since v1, so add a new `registerMigration` and never edit v1.
- `Meeting` uses CodingKeys snake_case mapping; new fields follow it.
- "Inert by absence": video code paths run only when the factory exists (Phase 19-04). The disk tier must follow the same gate.
- TDD mandatory; Swift 6 strict concurrency; no silent failures; XcodeGen regen for new files; `make test` gates.

### Integration Points
- Video stop/finalize completion in the coordinator → write `video_file` + anchor to the row.
- `executeStartRecording` precondition → two-tier disk check.
- `MeetingDetailView.deleteMeeting()` → media deletion.
- `AppState.initialize()` → orphan `.mov` cleanup after the DB is open.

</code_context>

<specifics>
## Specific Ideas

No specific references from the user. Standard approaches apply within the decisions above.

</specifics>

<deferred>
## Deferred Ideas

- RES-03: proactive disk monitoring *during* recording (stop video mid-meeting when disk runs low) → backlog / future milestone
- RES-04: move the audio drain timer off the main queue (F1 root cause) → backlog
- Automatic retention policy (e.g. expire videos older than N days) or "delete video only, keep transcript" → not in v3.0 scope; candidate for a future phase
- Storage breakdown UI (audio vs video sizes) → Phase 21 or later
- **Pre-existing data-loss hazard:** Settings "Clean Up Orphaned Files" deletes every `.wav`, including the in-progress recording and retry-retained files (`SettingsView.swift` ~L213 + `AudioFileManager.findOrphanedWAVs`) → separate quick task

</deferred>

---

*Phase: 20-video-storage-retention*
*Context gathered: 2026-11-19*

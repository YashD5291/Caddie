# Phase 20: Video Storage & Retention - Research

**Researched:** 2026-11-19
**Domain:** GRDB/SQLite schema migration alongside FTS5, AVFoundation finalize/playability, Swift 6 actor lifecycle, file retention
**Confidence:** HIGH (codebase read in full, plus local empirical probes for AVFoundation, FTS5, and Swift 6 compile shapes). The probes ran on macOS 26.5; the 14.2 floor was not available locally.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

The user had no preference on the gray areas, so every decision below is Claude's recommended default. **D-01 reinterprets STOR-03 and must be surfaced to the user at plan approval.**

#### Disk guard with video enabled (STOR-03)
- **D-01 (reinterprets STOR-03):** The guard has two tiers. Below the existing 500 MB audio floor, recording is **blocked**, exactly as today. Between 500 MB and the video threshold, the meeting **records audio-only**: video is skipped and the reason ("low disk space") is shown through the existing non-fatal video warning channel (`setOnVideoError` / `lastVideoError`). Rationale: the core value says every meeting must be captured, and VID-04 / Phase 19 make audio the senior partner, so video headroom must never prevent an audio recording. The roadmap wording "recording is blocked pre-start" is satisfied for the video leg, since video is blocked before it starts. Update the STOR-03 and ROADMAP success-criterion wording to match.
- **D-02:** Video threshold = 500 MB audio floor + headroom for roughly 2 hours of video at the active preset's bitrate cap (compact 1.5 / balanced 2.5 / high 4.0 Mbps, which is about 1.9 / 2.75 / 4.1 GB in total). The threshold comes from the preset, not a magic number. The planner picks the exact formula.
- **D-03:** The video tier is checked only when screen recording is enabled (the factory is present). Audio-only users see no behavior change and keep the 500 MB guard.

#### Linking video to the meeting (STOR-01)
- **D-04:** Add a nullable `video_file` column (filename only, e.g. `<meetingId>.mov`, mirroring `audio_file`) via a new GRDB migration. Do not touch the FTS5 table or its triggers. They list columns explicitly, so the new column stays out of the index automatically. A test must prove it is not searchable.
- **D-05:** `video_file` is set only when a playable `.mov` exists after video stop/finalize. A start failure (e.g. TCC denied) or video disabled leaves it null with no file on disk.
- **D-06:** Partial videos (SCK stopped mid-meeting, crash-recovered fragment) are **kept and linked**. A partial recording is still the user's data.
- **D-07:** A `.mov` that finalized with no usable video (not playable, or zero duration, e.g. stopped before the first frame) is **deleted**, `video_file` stays null, and the event is logged with context.

#### Timing anchor persistence (STOR-04 storage leg, deferred here by Phase 19)
- **D-08:** Persist the anchor pair (`audioStartTicks`, `firstFrameTicks` from `RecordingCoordinator.videoAnchorPair`) to the meeting row in the same migration. Store it in whatever form Phase 21 playback needs to map transcript time to video time, e.g. a video start offset in seconds and/or the raw host ticks. The planner decides the exact columns. Nullable, and null whenever `video_file` is null. Note: REQUIREMENTS.md marks STOR-04 complete (Phase 18), but persistence was explicitly deferred to Phase 20 by 19-CONTEXT.md and 19-05-SUMMARY.md. Fix the traceability.

#### Deletion and orphans (STOR-02)
- **D-09:** Deleting a meeting removes its `.mov` along with its WAV/M4A. Extend the existing file-deletion helper (`AudioFileManager.deleteAudio`, likely renamed to cover all media) rather than adding a parallel path.
- **D-10:** One-time and ongoing orphan cleanup: at launch, delete `.mov` files whose meeting ID has no row. This mirrors the DATA-05 `cleanupOrphanedTempFiles()` launch pattern and clears the videos left behind by meetings deleted since Phase 19 shipped. Safety: the meeting row is inserted before audio/video start (`RecordingCoordinator` ~L363), so every live or crash-recovered `.mov` has a row. **If the DB query fails, skip cleanup entirely.** It must never treat "couldn't read the DB" as "no meetings".
- **D-11:** Audio-only meetings leave `video_file` null and trigger no video file operations or warnings on delete (a missing `.mov` is expected, not an error to log as a failure).

#### Docs
- **D-12:** README "Screen recording (opt-in, in progress)" section: remove the "Known gaps" bullet about deletion and the disk guard, and document the audio-only fallback when disk is low.

### Claude's Discretion
- Exact migration name and anchor column shape.
- Whether the Settings "Clean Up Orphaned Files" button also covers orphan `.mov` files, and whether "Audio storage used" is relabeled "Storage used". The total already includes `.mov` because video lives in the audio directory.
- Playability check mechanism for D-07 (AVAsset `isPlayable`/duration vs. reusing the Phase 18 `--validate-mov` logic).
- Where the D-01 tier decision lives (coordinator precondition vs. inside the video start path).

### Deferred Ideas (OUT OF SCOPE)
- RES-03: proactive disk monitoring *during* recording (stop video mid-meeting when disk runs low) → backlog / future milestone
- RES-04: move the audio drain timer off the main queue (F1 root cause) → backlog
- Automatic retention policy (e.g. expire videos older than N days) or "delete video only, keep transcript" → not in v3.0 scope; candidate for a future phase
- Storage breakdown UI (audio vs video sizes) → Phase 21 or later
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| STOR-01 | Video stored locally alongside the meeting's audio and linked to the meeting record (nullable `video_file`; never in FTS5) | §Migration (verified that `ALTER TABLE ADD COLUMN` leaves the FTS5 external-content sync intact), §Link-early/verify-on-finalize pattern, §Inspector |
| STOR-02 | Deleting a meeting deletes its video along with its audio | §deleteMedia (deletes by meetingId, not by column), §Launch orphan sweep (D-10) |
| STOR-03 | Disk guard raised when video is enabled (reinterpreted by D-01 as two tiers: block below 500 MB, record audio-only below the video threshold) | §Disk tier pure function + injectable capacity seam; threshold formula verified against the D-02 numbers |
| STOR-04 (storage leg) | Host-clock anchor persisted with the meeting so playback position maps to transcript time | §Anchor shape: `video_start_offset` seconds. Movie time 0 is the first frame (verified in the SDK header and a probe). Traceability fix in REQUIREMENTS.md |
</phase_requirements>

## Project Constraints (from CLAUDE.md)

| Directive | Source | Impact on this phase |
|-----------|--------|----------------------|
| TDD, tests first, no exceptions | global CLAUDE.md | Every task writes failing tests first. `MigrationTests.testFreshMigrationCreatesAllColumns` (asserts 13 columns) must be updated to 15 **before** the migration lands |
| Ask before committing or pushing, every time | global CLAUDE.md | Overrides `commit_docs: true` and any GSD auto-commit. The executor must ask |
| Never commit directly to main | global CLAUDE.md | Current branch is `feature/20-video-storage-retention` |
| No silent catches, no empty catch blocks, handle errors explicitly | global + project | The "missing `.mov` is expected" branch (D-11) still needs an explicit, logged (debug-level) or guarded path. No bare `try?` except the existing `Task.sleep` idiom |
| Strict typing, no `any`/`unknown` without a justifying comment | global | The inspector returns typed `Sendable` structs. No `[String: Any]` leakage |
| No dead or commented-out code; small functions; check existing helpers first | global | Extend `deleteAudio` (D-09) and reuse `hostTicksToSeconds`, `videoPath(for:)`, and the `surfaceVideoError` channel |
| README updated with user-facing changes | global + memory | D-12 is part of this phase, not a follow-up |
| No placeholder or mock implementations unless asked | global | Mocks live only in `Tests/Mocks/`. Production inspector is real AVFoundation |
| Swift 6, `SWIFT_STRICT_CONCURRENCY: complete`, deployment 14.2 | project.yml | All new code must compile cleanly. The shapes below were compile-checked at `-swift-version 6 -strict-concurrency=complete -target arm64-apple-macos14.2` |
| XcodeGen: regenerate after adding files; `make test` gates | project CLAUDE.md / Makefile | `make test` runs `xcodegen generate` first. `Caddie.xcodeproj` is gitignored |
| Naming: `*Manager`, `*Engine`, `*Tests`; `final class`; `Error & LocalizedError` enums; `// MARK: -` sections; `CaddieLogger.storage` for storage logs | project conventions | New types follow these patterns |
| GSD workflow enforcement | project CLAUDE.md | Execution through `/gsd:execute-phase` |

## Summary

The schema half is low-risk. SQLite's `ALTER TABLE ADD COLUMN` rewrites only the schema text, not table content. FTS5 external-content tables fetch only their *declared* columns by name from the content table. So adding `video_file` and `video_start_offset` leaves `meetings_fts`, its three triggers, and its rowid mapping untouched. A local sqlite3 3.51.0 run confirmed this: after `ADD COLUMN` and an `UPDATE`, a filename token is unsearchable, title and transcript search still work, and `integrity-check` with rank=1 passes. GRDB 7.10's `db.alter(table:) { t.add(column:) }` and `migrate(_:upTo:)` cover the migration and its upgrade test. Every write to `meetings` in the codebase is a targeted `UPDATE … WHERE meeting_id = ?`, so no stale full-record `update()` can clobber the new columns.

The lifecycle half has one real gap. **Today the coordinator never learns when a `.mov` is actually finalized.** `ScreenRecorder.stop()` dispatches `sink.finalize` onto the writer queue and returns before `finishWriting` completes. That holds on *every* stop path, not just the timed-out one. A stream death finalizes the file mid-meeting on its own, and an app quit may kill the process before finalize runs at all. D-05 and D-07 (link only a playable file, delete an unusable one) therefore need a finalize-completion signal from the engine. Inspecting or deleting the file before that signal races an in-place rewrite: the probe showed `finishWriting` keeps the same inode and grows the file. The root-cause fix is a small **additive** `onFinalized` callback on `ScreenRecording`/`WriterSink`, fired exactly once after the `finishWriting` completion (and on the "writer not writing" early return). It mirrors the two existing callbacks. This touches the hardware-verified Phase 18 engine file, so it needs user sign-off and a short manual gate.

Recommended lifecycle: **link early, verify on finalize, through one ordered per-meeting event funnel.** When the first frame lands, persist `video_file` and `video_start_offset` together. This is the only moment the anchor exists, and it makes quit or crash partials linked, as D-06 asks. When `onFinalized` fires, inspect the file with `AVURLAsset.load(.isPlayable, .duration)` plus `loadTracks(.video)`. An unusable file is deleted and both columns are nulled (D-07). An `AsyncStream` per meeting orders the two events by construction, so the timed-out-stop, late-finalize, stream-death, and second-meeting cases are all one code path. The disk tier belongs in `executeStartRecording` as a pure decision over a single capacity read. It needs a small injectable capacity seam, because `checkDiskSpace()` is untestable today. The launch orphan sweep lists files first, then reads meeting IDs, and skips entirely on any DB error.

**Primary recommendation:** Add migration `v2_add_video_columns` (`video_file TEXT`, `video_start_offset DOUBLE`). Add an `onFinalized` engine callback. Add a per-meeting `AsyncStream` funnel in the coordinator that links on first frame and verifies or discards on finalize through an injected `VideoFileInspecting`. Add a pure `DiskSpaceTier` decision with an injected capacity provider. Rename `deleteAudio` to `deleteMedia` (by meetingId, missing file is fine). Add a list-then-read launch orphan sweep that runs before the coordinator exists.

## Architectural Responsibility Map

(Native macOS app. The "tiers" here are its layers: Storage, Coordinator, Recording engine, App, UI.)

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| `video_file` / `video_start_offset` schema | Storage (`Migrations`, `Meeting`) | — | Schema lives only in GRDB migrations. FTS stays untouched (D-04) |
| Knowing when the `.mov` is final | Recording engine (`WriterSink` `finishWriting` completion) | Coordinator (consumes the signal) | Only the sink knows when `finishWriting` completes. Polling from outside races the in-place rewrite |
| Linking the row + persisting the anchor | Coordinator (actor) | Storage (targeted SQL UPDATE) | The coordinator owns the in-flight meeting, the anchor pair, and the DB handle |
| Playable / non-empty decision | Storage utility (`VideoFileInspector`, AVFoundation) | Coordinator (acts on the result) | Pure media inspection, reusable by Phase 21 and the DEBUG harness |
| Disk tier decision | Coordinator precondition (`executeStartRecording`) | — | One capacity snapshot for both tiers. "Inert by absence" via `screenRecorderFactory != nil` |
| Low-disk message | Coordinator → `onVideoError` → AppState `lastVideoError` → MenuBar | — | Existing non-fatal channel (D-01). Must fire after `.recording` clears the surface |
| Per-meeting file deletion | Storage (`AudioFileManager.deleteMedia`) | UI (`MeetingDetailView.deleteMeeting`) | Single deletion helper (D-09). The UI is the only call site |
| Orphan `.mov` sweep | Storage helper | App (`AppState.initialize`, after DB open, before coordinator) | Must run while no capture can be in flight |
| User docs, requirement wording | README / REQUIREMENTS / ROADMAP | — | D-12, D-01, D-08 traceability |

## Standard Stack

### Core (all already in the project. **Zero new dependencies.**)
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| GRDB.swift | 7.10.0 (resolved, `Package.resolved`) [VERIFIED: checkout tag v7.10.0] | Migration (`db.alter(table:)`, `t.add(column:_:)`), `migrate(_:upTo:)` for upgrade tests, `String.fetchSet` for the orphan sweep | Already the app's DB layer. All APIs confirmed in the local checkout source |
| SQLite (system) + FTS5 | sqlite3 3.51.0 on the dev machine [VERIFIED: `sqlite3 --version`] | `ALTER TABLE ADD COLUMN`. External-content FTS5 reads only declared columns | [CITED: sqlite.org/lang_altertable.html, sqlite.org/fts5.html §4.4.3] |
| AVFoundation | macOS SDK 26.2 (Xcode 26.2), API floor macOS 12 for `load(_:)` / `loadTracks` | `AVURLAsset.load(.isPlayable, .duration)` and `loadTracks(withMediaType: .video)` for D-07 | Same call the Phase 18 `--validate-mov` harness already uses |
| Foundation `URLResourceValues` | system | `volumeAvailableCapacityForImportantUsageKey` (already used by `checkDiskSpace`) | Existing guard semantics preserved |
| Swift Concurrency `AsyncStream.makeStream(of:)` | Swift 5.9+ stdlib, macOS 14.0+ [VERIFIED: compiled at target 14.2] | Ordered per-meeting video event funnel | Removes the first-frame vs finalize ordering race without locks |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| `ByteCountFormatter` (Foundation) | system | Human-readable "X GB free, Y GB needed" in the low-disk message | Message copy only (already used in `SettingsView.refreshStorage`) |
| XCTest | Xcode 26.2 | All new tests | Existing framework |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Additive `onFinalized` callback | Make `ScreenRecorder.stop()` await `finishWriting` | Measured cost is small (`finishWriting` took 0.026–0.045 s for 25–240 s files), but it changes a hardware-verified contract ("stop finalizes async without blocking"). It moves finalize inside the 5 s bound, and it still needs a waiter for stream-death finalizes already in flight. The callback is additive and covers every path uniformly |
| Per-meeting `AsyncStream` funnel | Keep the `Task { await self?.handler }` hops plus an actor-held "finalized" set | Works, but correctness depends on subtle guard ordering across reentrant awaits. The funnel orders events by construction |
| Link early (first frame) | Link only after finalize verification (literal D-05) | Simpler (single write), but quit or crash partials are never linked and their anchor is lost. That contradicts D-06 unless a launch reconciliation pass is added (see Open Question 1) |
| `video_start_offset` (seconds) | Raw `audio_start_ticks` + `first_frame_ticks` INTEGER columns | Raw mach ticks are boot-relative and need the recording machine's `mach_timebase_info` (Intel 1/1 vs Apple Silicon 125/3), so they are not portable. GRDB stores `UInt64` via `Int64(self)` (traps above `Int64.max`). Phase 21 only needs the offset |
| Production `VideoFileInspector` | Call `ScreenRecorderHarness.runValidateMode` | The harness is `#if DEBUG`, returns `Never`, and calls `exit()`. Not reusable. Extract the same two-property load into production code (the harness may optionally delegate to it) |

**Installation:** none. No packages are added.

## Package Legitimacy Audit

No external packages are installed or upgraded in this phase, so slopcheck was not needed.

| Package | Registry | Age | Downloads | Source Repo | slopcheck | Disposition |
|---------|----------|-----|-----------|-------------|-----------|-------------|
| (none) | — | — | — | — | — | — |

**Packages removed due to slopcheck [SLOP] verdict:** none
**Packages flagged as suspicious [SUS]:** none

## Empirical Findings (local probes, this session)

Probes were compiled with `swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete -target arm64-apple-macos14.2` against SDK 26.2 and run on macOS 26.5.1 (Apple Silicon). They used AVAssetWriter with HEVC, `.mov`, and `movieFragmentInterval` = 10 s, the same settings as `ScreenRecorder`. Source is in `scratchpad/probe/`. [VERIFIED: local probe]

| Case | Result | Planning consequence |
|------|--------|----------------------|
| A: 25 s fragmented write → `finishWriting` | took **0.045 s**. **Same inode** before and after; size grew 7.64 → 7.89 MB. Playable, 25.0 s | Finalize rewrites **in place**. Never inspect or delete before the completion signal |
| A: byte copy taken before `finishWriting` (simulated kill) | playable, **20.07 s** (lost only the open fragment) | Matches VID-07. Crash partials are worth keeping and linking (D-06) |
| H: 240 s 1080p, 120 MB → `finishWriting` | took **0.026 s**, in place, playable 240.0 s | Finalize does not scale with length at this size. 2 h behavior is extrapolated [ASSUMED] |
| B: `startWriting`, **no** `startSession`, finish (stop before first frame) | status `.failed`. **A 0-byte `.mov` is left on disk.** Inspect → `-11829 Cannot Open` | D-07's "stopped before first frame" case produces a real 0-byte file that must be deleted |
| B2: session started, zero frames | status `.completed`, **0-byte file**, `-11829` | Same as B |
| B3: exactly one frame | playable, duration 0.067 s, 1 video track | "Zero duration" check (`> 0`) keeps it. Correct per D-07's literal wording |
| C: `startWriting` then `cancelWriting` | **file deleted** (status `.cancelled`) | The engine's `startCapture` failure path already leaves no file. Matches the SDK header: "-cancelWriting will delete the file" |
| D: 4 KB garbage / E: 0-byte | `load` throws `-11829 Cannot Open` | Load error means unusable |
| F: missing file | `load` throws `-11800` | Distinguish "missing" (nothing to delete) from "unusable" |
| G: inspect while writer still open | playable, 20.07 s (only flushed fragments) | Proves inspection before finalize gives a *wrong* (short) answer |
| Session at host-time PTS 50 000 s, 3 s of frames | asset duration 3.0, track `timeRange.start` = **0** | **Movie time 0 = first frame.** Also stated in the `startSessionAtSourceTime:` header doc |
| `removeItem` on a missing file | `CocoaError` code 4, `.fileNoSuchFile` | D-11 expected-missing branch matches `CocoaError.fileNoSuchFile` |
| FTS5 after `ALTER TABLE ADD COLUMN video_file, video_start_offset` + `UPDATE` (sqlite3 3.51.0) | filename token: 0 hits; title/transcript: 1 hit; `integrity-check` rank=1 OK before and after DELETE; `PRAGMA table_info(meetings_fts)` = title, transcript, app | D-04 confirmed. Exact assertions for the "not searchable" test |
| `AVURLAsset` created and loaded inside an `actor` method, returning a `Sendable` struct | compiles clean under Swift 6 strict at target 14.2 | Inspector shape is safe |
| `AsyncStream.makeStream` funnel: `@Sendable` engine callbacks yield, actor-isolated `Task` consumes | compiles clean; events delivered in order | Funnel shape is safe |

## Architecture Patterns

### System Architecture Diagram

```
 User / calendar prompt
        │  .manualStart / .meetingDetected
        ▼
 RecordingCoordinator.handle ──► state=.recording ──► onStateChange ──► AppState clears lastVideoError
        │ side effect .startRecording
        ▼
 executeStartRecording
   ├─ read capacity ONCE (injected provider)
   ├─ DiskSpaceTier.decide(available, videoPreset: factory != nil ? preset : nil)
   │     ├─ .belowAudioFloor ───────────► .recordingFailed (blocked, as today)
   │     ├─ .belowVideoThreshold ─┐
   │     └─ .sufficient ──────────┤
   ├─ INSERT meetings row (audio_file set, video_file NULL)   ◄── row exists BEFORE any .mov (D-10 safety)
   ├─ recorder.start (audio) ── fail ──► .recordingFailed
   └─ audio OK ─┬─ tier .belowVideoThreshold ──► surfaceVideoError("low disk…") ──► menu bar orange row
                └─ tier .sufficient ──► startVideo
                                          │  makeStream(VideoEvent)
                                          │  engine.onFirstFrameHostTime → yield(.firstFrame)
                                          │  engine.onFinalized          → yield(.finalized); finish
                                          │  consumer Task (actor-isolated, per meeting)
                                          ▼
                         ┌──────── per-meeting ordered funnel ────────┐
   .firstFrame(ticks) ──►│ offset = s(first) − s(audioStart)          │──► UPDATE video_file, video_start_offset
                         │                                            │
   .finalized ──────────►│ inspector.inspect(videoPath)               │
                         │   usable   → keep link (no write if linked)│
                         │   unusable → delete file, NULL both cols   │──► UPDATE … = NULL (D-07, logged)
                         │   missing  → NULL both cols (logged)       │
                         └────────────────────────────────────────────┘
 Teardown (stopAndTranscribe / notifyError / disconnect / quit) → stopVideo → bounded engine.stop (≤5 s)
   → pipeline.enqueue is NEVER blocked by finalize/inspection (finalize arrives later via the funnel)

 Delete (MeetingDetailView) → DELETE row → AudioFileManager.deleteMedia(meetingId) → wav, m4a, mov (missing = fine)
 Launch (AppState.initialize) → open DB → list *.mov FIRST → read meeting_id set → delete row-less .mov
                                 (DB read error → skip entirely) → … → create coordinator
```

### Stop-path finalize map (answers "where does finalize complete on each path")

| Path | Coordinator entry (current lines) | What the coordinator waits for today | When `finishWriting` actually completes | `onFinalized` arrives |
|------|-----------------------------------|--------------------------------------|----------------------------------------|----------------------|
| Normal stop (`.manualStop` / `.meetingEnded`) | `executeStopAndTranscribe` L623 → `stopVideo` L548 → `stopEngineBounded` L582 | `engine.stop()` = `stopCapture` + *dispatch* of `sink.finalize` (`ScreenRecorder.swift:219`) | Shortly **after** `stop()` returns (async on writerQueue → completion) | after teardown, usually while transcribing |
| Device disconnect | reducer maps `.deviceDisconnected` → `.stopAndTranscribe` | same as normal | same | same |
| Error teardown | `executeNotifyError` L718 → `stopVideo` | same | same | same |
| Timed-out stop (SCK wedged >5 s) | `stopEngineBounded` returns `true`, stop task **not** cancelled | gives up at 5 s, surfaces "did not finish cleanly" | whenever the wedged `stopCapture` returns | late, possibly after meeting #2 started. Must be keyed by meetingId |
| Stream death mid-meeting | `handleVideoStreamStopped` L514 (context kept) | — | **mid-meeting**: `didStopWithError` → `finalizeOnQueue(.streamError)` | **before** teardown. Teardown's later `stop()` is a sink no-op (no second fire) |
| App quit | `stop()` L212 → `stopVideo` inside un-awaited `Task` from `AppState.shutdown()` | nothing (process may die) | may never complete | may never arrive. The first-frame link persists (D-06) |
| Start failed | `startVideoInner` catch L478 | — | no writer, or `cancelWriting` deleted the file | never. Coordinator must `finish()` the stream and defensively remove any file |

### Recommended file structure
```
Sources/
├── Storage/
│   ├── Migrations.swift            # + registerMigration("v2_add_video_columns")
│   ├── Meeting.swift               # + videoFile, videoStartOffset (+ CodingKeys)
│   ├── AudioFileManager.swift      # deleteAudio → deleteMedia; + orphan .mov sweep (directory-injectable)
│   └── VideoFileInspector.swift    # NEW: VideoFileInspecting protocol + AVAssetVideoInspector + VideoInspection
├── Recording/
│   ├── ScreenRecorder.swift        # + onFinalized (additive; WriterSink fires once)
│   └── ScreenRecording.swift       # + onFinalized requirement on the seam
├── Coordinator/
│   └── RecordingCoordinator.swift  # DiskSpaceTier + capacity seam; per-meeting event funnel; inspector injection
└── App/AppState.swift              # launch orphan sweep after DB open, before coordinator
Tests/
├── Mocks/MockScreenRecorder.swift  # + onFinalized firing (immediate / delayed / manual), never-finalize flag
├── Mocks/MockVideoInspector.swift  # NEW: scripted VideoInspection per call, lock-guarded call log
├── MigrationTests.swift            # extend: 15 columns, v1→v2 upgrade, not-searchable, FTS consistency
├── MeetingModelTests.swift         # extend: round-trip new fields
├── VideoFileInspectorTests.swift   # NEW: synthetic fixtures in temp dir (no TCC)
├── WriterSinkFinalizeTests.swift   # NEW: onFinalized fires exactly once (real AVAssetWriter, no SCStream)
├── MediaFileTests.swift            # NEW: deleteMedia + orphan sweep in a temp dir
├── DiskSpaceTierTests.swift        # NEW: pure threshold/decision math
└── RecordingCoordinatorVideoStorageTests.swift  # NEW: link/verify/discard/late-finalize/tier wiring
```
(All new files need `make setup` / `xcodegen generate`. `make test` does it automatically.)

### Pattern 1: Additive migration, FTS untouched
**What:** A new registered migration that only adds nullable columns. Never edit `v1_create_meetings`.
**Why it is safe:** ADD COLUMN "modif[ies] the SQL text of the schema … No changes are made to table content" [CITED: sqlite.org/lang_altertable.html]. FTS5 queries the content table with `SELECT <content_rowid>, <declared cols> FROM <content> WHERE …` [CITED: sqlite.org/fts5.html §4.4.3]. The triggers name `title, transcript, app` explicitly. Note that `meetings_au` is `AFTER UPDATE` with **no** `OF` column list, so every video-column UPDATE re-indexes the row with identical values. That is harmless, but it argues for skipping redundant writes (for example, don't re-write the link on a "usable" verdict).

### Pattern 2: Link early, verify on finalize (ordered funnel)
**What:** One `AsyncStream<VideoEvent>` per meeting, created in `startVideoInner` before `start()`. Both engine callbacks only `yield`. An actor-isolated consumer `Task` handles events sequentially.
**Why ordered:** The `.firstFrame` yield happens on writerQueue before `finalizeOnQueue` can call `finishWriting`, and the `.finalized` yield happens in its completion. That gives happens-before, and AsyncStream preserves yield order. The consumer's `await` on DB writes cannot reorder events.
**When the consumer ends:** on `.finalized` (stream finished), on start failure (coordinator calls `finish()`), or never (quit or wedge; harmless, it holds only the meeting's own context).

### Pattern 3: Disk tier as a pure function over one snapshot
**What:** `executeStartRecording` reads capacity once through an injected provider and calls a pure `DiskSpaceTier.decide(available:videoPreset:)`. It blocks only on `.belowAudioFloor`. On `.belowVideoThreshold` it starts audio normally and, **after audio succeeds**, calls `surfaceVideoError` instead of `startVideo`.
**Inert by absence (D-03):** `videoPreset` is `nil` when `screenRecorderFactory == nil`, so the decision degenerates to today's 500 MB guard.
**Single preset source:** the start call currently hard-codes `.balanced` (L473). Introduce one coordinator constant (for example `private static let videoPreset: ScreenRecorder.QualityPreset = .default`) used by both `start(...)` and the threshold, so Phase 21's preset picker changes one place.

### Pattern 4: Delete by meetingId, not by column
**What:** `deleteMedia(meetingId:)` always attempts `wav`, `m4a`, `mov` at their canonical paths, whatever `video_file` says. `CocoaError.fileNoSuchFile` is the expected branch (D-11) and is not logged as a warning.
**Why:** Phase-19-era `.mov` files exist with `video_file` NULL (3 on the dev machine, all with rows). So do unverified or in-flight files and rows whose link was nulled. Column-driven deletion would leak screen video, which is a privacy failure. The launch sweep is the safety net for any deletion failure.

### Pattern 5: Orphan sweep, list then read
**What:** (1) Enumerate `*.mov` in the directory. (2) *Then* `String.fetchSet(db, sql: "SELECT meeting_id FROM meetings")`. (3) Delete files whose stem is not in the set. Any DB error means log and skip everything (D-10).
**Why this order:** Every `.mov` present at step 1 had its row inserted before the file existed (`insert` L363 precedes `startVideo` L414). So a later ID read always contains it. The reverse order can delete a just-created video if a recording starts between the two steps. The launch call also runs before the coordinator is constructed, so no capture can be in flight.

### Anti-Patterns to Avoid
- **Inspecting or deleting the `.mov` right after `stopVideo()` returns.** Finalize is still rewriting the file in place (probe A and G).
- **Delay-based "wait 2 s then inspect".** A workaround, not a root-cause fix, and the user's rules forbid it.
- **Blocking `pipeline.enqueue` on finalize or inspection.** It undoes Phase 19's bounded-stop guarantee.
- **Deciding "no usable video" from `firstFrameTicks == nil` alone.** Use the inspector as the authority. The first-frame flag only drives the offset.
- **Surfacing the low-disk message before `handle()` transitions to `.recording`.** AppState's `.recording` handler clears `lastVideoError` and would erase it.
- **`Meeting.update(db)` (full-row write) anywhere in the recording path.** A stale struct would clobber `video_file`. Keep the targeted `UPDATE … WHERE meeting_id = ?` style.
- **Running any orphan cleanup in tests against `AudioFileManager.audioDirectory`.** With an in-memory DB it would delete the developer's real videos.
- **Reusing `findOrphanedWAVs()`-style "every file with this extension" logic for `.mov`.** That definition includes in-flight and retry-pending files.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| "Is this `.mov` playable / non-empty" | Atom parsing, size heuristics | `AVURLAsset.load(.isPlayable, .duration)` + `loadTracks(withMediaType: .video)` | Handles fragmented and defragmented movies. Errors map cleanly (`-11829`, `-11800`) |
| Knowing when a file is final | Polling size or mtime, sleeps | Engine `onFinalized` from the `finishWriting` completion handler | Only AVFoundation knows. Finalize is in place, so the file looks valid mid-rewrite |
| Event ordering between two callbacks | Locks, flags, actor-set guards | `AsyncStream.makeStream` per meeting | Ordered by construction. Already compile-verified |
| Host ticks → seconds | New conversion | `ScreenRecorder.hostTicksToSeconds(_:timebase:)` (`ScreenRecorder.swift:316`) | Already unit-tested (STOR-04 engine leg) |
| Schema change | Manual `ALTER` SQL / table rebuild | `db.alter(table:) { t.add(column:) }` | GRDB-standard. Table rebuild would require recreating FTS triggers |
| Upgrade-path test DB | Hand-built v1 SQL | `migrator.migrate(db, upTo: "v1_create_meetings")` then `migrator.migrate(db)` | [CITED: GRDB Migrations.md] |
| Free-space reading | `statfs` | `volumeAvailableCapacityForImportantUsageKey` (existing) | Includes purgeable space. Keeps current semantics |

**Key insight:** In this phase the hard part is not media or SQL. It is timing: knowing when a file is final, ordering two async callbacks, and ordering a sweep against a live recording. Each has a construction-based fix. Don't paper over any of them with sleeps or flags.

## Runtime State Inventory

(This phase includes a schema migration, so the inventory applies.)

| Category | Items Found | Action Required |
|----------|-------------|------------------|
| Stored data | Dev DB `~/Library/Application Support/Caddie/caddie.db` at migration `v1_create_meetings` only, 17 meetings [VERIFIED: read-only sqlite query]. Existing rows get NULL `video_file` / `video_start_offset` | Code edit (migration). No backfill: no released build contains video code. v1.2.2 (PR #9) predates PR #11 (Phase 18) [VERIFIED: git log] |
| Stored data (files) | 3 Phase-19-era `.mov` files in the dev audio dir. **All 3 have rows** (statuses `recording`, `done`, `done`) [VERIFIED]. They stay unlinked (NULL), and the launch sweep keeps them. Also 873 `.wav` + 424 `.m4a` across 1297 stems vs 17 rows. That is pre-existing test pollution from coordinator tests that use a real `AudioRecorder` writing to the real audio dir | None for the `.mov` files. **Don't let new tests add to the pollution or sweep the real dir** (see Pitfalls). WAV/M4A pollution is out of scope (flagged in Open Questions) |
| Live service config | None. No external services (local-only app) | None |
| OS-registered state | None. TCC Screen Recording grant for the Debug build may still be revoked from the 19-05 `tccutil reset` (19-05-SUMMARY "pending user action") | Re-grant before the manual gate |
| Secrets / env vars | None. UserDefaults key `screenRecordingEnabled` unchanged | None |
| Build artifacts | `Caddie.xcodeproj` is generated and gitignored. New source and test files require `xcodegen generate` | `make setup` / `make test` |

## Common Pitfalls

### Pitfall 1: Treating `stop()` return as "file finalized"
**What goes wrong:** Inspect says the file is short, or it's deleted, while `finishWriting` is still rewriting it in place, which corrupts or loses the video.
**Why:** `ScreenRecorder.stop()` dispatches `sink.finalize` asynchronously (L219), and `finishWriting` has its own async completion.
**How to avoid:** Act only on `onFinalized`.
**Warning signs:** a test or log shows the inspector called before the engine logged `ScreenRecorder writer finalized`.

### Pitfall 2: `onFinalized` not firing on every finalize exit
**What goes wrong:** The consumer waits forever, and a broken file stays linked.
**Why:** `finalizeOnQueue` has an early return (`writer not writing`, L576), and stream death finalizes before teardown.
**How to avoid:** Fire in the `finishWriting` completion **and** in the not-writing early return, exactly once (the existing state guard already prevents a second pass). Test both with a real `AVAssetWriter` and a directly constructed `WriterSink` (no SCStream needed).

### Pitfall 3: Low-disk warning erased by the `.recording` state handler
**What goes wrong:** The user never sees why video is missing.
**Why:** AppState sets `lastVideoError = nil` on `.recording` (AppState ~L198).
**How to avoid:** Surface from inside the `.startRecording` side effect, after audio start, at the spot where `startVideo` would run. Both hops are `Task { @MainActor … }` created in order. The analogous TCC-denied path was proven visible on hardware (19-05 check 4).

### Pitfall 4: Orphan sweep deletes live or real data
**What goes wrong:** (a) A test runs the sweep on the real directory with an in-memory DB and deletes the developer's real `.mov` files. (b) The sweep reads IDs before listing files and races a new recording. (c) A DB error is read as "no meetings".
**How to avoid:** Make the directory and the ID source injectable, and use a temp dir in tests. List first, read second. Skip on any throw. Call the sweep in `initialize()` before the coordinator is constructed and never from a background `Task`. Also note that the test host *is* the app, so `make test` launches `AppState.initialize` against the real DB and directory. Any test fixture written into the real audio dir can be swept mid-test.

### Pitfall 5: Fresh or empty DB reads as "every video is an orphan"
**What goes wrong:** If `caddie.db` is lost or recreated (user deleted it, restored a stale backup), the read *succeeds* with 0 or few rows, and the sweep deletes every `.mov`. Audio files are untouched, because D-10 sweeps only `.mov`, which makes the result inconsistent.
**How to avoid:** Recommended extra guard: skip (and log a warning) when the meeting set is empty but `.mov` files exist. This refines D-10's intent and needs user confirmation (Open Question 3).

### Pitfall 6: `MigrationTests` column-count assertion
**What goes wrong:** `testFreshMigrationCreatesAllColumns` asserts `count == 13` and fails.
**How to avoid:** Under TDD, update it to 15 and add the two names first.

### Pitfall 7: Integer truncation in the threshold
**What goes wrong:** `Int64(bitrate / 8) * 7200` is fine for these presets, but `Int64(bitrate) / 8 * 7200` or Int32 math can drift.
**How to avoid:** Use `Int64(preset.bitrate) * videoHeadroomSeconds / 8` and pin exact expected values in tests: compact **1,874,288,000**, balanced **2,774,288,000**, high **4,124,288,000** bytes (500 MiB floor = 524,288,000). These match D-02's ~1.9 / 2.75 / 4.1 GB.

### Pitfall 8: Engine single-use and callback capture
**What goes wrong:** `onFinalized` is assigned after `start()` and never fires.
**Why:** `ScreenRecorder` captures callbacks into `WriterSink` at start (L146-151). This is the same documented trap as the existing two callbacks.
**How to avoid:** Assign before `start()`, and add it to the protocol doc comment.

### Pitfall 9: Deleting a meeting that is still recording
Pre-existing and out of scope. The delete button is enabled for every status. Under the recommended design, the row is gone, so later UPDATEs affect 0 rows (safe). A usable file left behind becomes an orphan that the next launch sweeps. Don't expand scope. Just make sure nothing crashes when the row is missing.

### Pitfall 10: Path built from an untrusted `meeting_id`
`deleteMedia` builds paths from a DB value. A crafted `meeting_id` containing `/` or `..` could escape the directory. The risk is low (local, user-owned DB). A cheap guard rejects IDs with path separators. The sweep never builds paths from DB values; it only enumerates the directory.

## Code Examples

All examples follow existing project style. The migration, inspector, and funnel shapes were compile-verified in this session; the rest are recommended patterns.

### Migration (Storage/Migrations.swift)
```swift
// Source: GRDB 7.10 TableAlteration.add(column:_:) (local checkout); sqlite.org/lang_altertable.html
migrator.registerMigration("v2_add_video_columns") { db in
    // ADD COLUMN only: no table rebuild, so meetings_fts and its three triggers (which list
    // title/transcript/app explicitly) are untouched and the new columns are never indexed.
    try db.alter(table: "meetings") { t in
        t.add(column: "video_file", .text)            // "<meetingId>.mov" — filename only, like audio_file
        t.add(column: "video_start_offset", .double)  // seconds: firstFrame − audioStart; NULL iff video_file NULL
    }
}
```

### Upgrade-path + not-searchable tests (MigrationTests)
```swift
func testV1DatabaseUpgradesInPlaceAndStaysSearchable() throws {
    let queue = try DatabaseQueue()
    var migrator = DatabaseMigrator()
    Migrations.run(&migrator)
    try migrator.migrate(queue, upTo: "v1_create_meetings")
    try queue.write { try $0.execute(sql: """
        INSERT INTO meetings (meeting_id, title, date, start_time, status, transcript, created_at)
        VALUES ('old-1', 'Quarterly Review', '2026-03-22', '2026-03-22T09:00:00Z', 'done', 'budget talk', '2026-03-22T09:00:00Z')
        """) }
    try migrator.migrate(queue)
    let row = try queue.read { try Row.fetchOne($0, sql: "SELECT video_file, video_start_offset FROM meetings WHERE meeting_id = 'old-1'") }
    XCTAssertNil(row?["video_file"] as String?)
    let hits = try queue.read { try Meeting.search("budget").fetchAll($0) }
    XCTAssertEqual(hits.count, 1, "FTS must still find pre-migration rows")
}

func testVideoFileIsNeverSearchable() throws {
    try db.dbWriter.write { try $0.execute(sql: """
        INSERT INTO meetings (meeting_id, title, date, start_time, status, created_at, video_file)
        VALUES ('v-1', 'Standup', '2026-03-22', '2026-03-22T09:00:00Z', 'done', '2026-03-22T09:00:00Z', 'zqxjvideo.mov')
        """) }
    XCTAssertTrue(try db.dbWriter.read { try Meeting.search("zqxjvideo").fetchAll($0) }.isEmpty)
    XCTAssertEqual(try db.dbWriter.read { try Meeting.search("Standup").fetchAll($0) }.count, 1) // positive control
    let ftsColumns = try db.dbWriter.read { try Row.fetchAll($0, sql: "PRAGMA table_info(meetings_fts)") }.map { $0["name"] as String }
    XCTAssertEqual(ftsColumns, ["title", "transcript", "app"])
}
```
(Optional: `INSERT INTO meetings_fts(meetings_fts, rank) VALUES('integrity-check', 1)` after an UPDATE of the video columns. Verified on SQLite 3.51.0. The version that introduced the rank=1 variant is unconfirmed, so prefer the search-based assertions as the primary proof.)

### Inspector (Storage/VideoFileInspector.swift)
```swift
// Source: AVAsset.h (SDK 26.2) load(.isPlayable)/loadTracks; shape compile-verified (Swift 6, 14.2)
import AVFoundation

struct VideoInspection: Sendable, Equatable {
    let isPlayable: Bool
    let durationSeconds: Double
    let videoTrackCount: Int
    /// D-07: playable, non-zero duration, at least one video track.
    var isUsable: Bool { isPlayable && durationSeconds > 0 && videoTrackCount > 0 }
}

enum VideoInspectionResult: Sendable, Equatable {
    case missing                       // nothing on disk — nothing to delete
    case inspected(VideoInspection)
    case unreadable(String)            // AVFoundation could not open it (e.g. -11829 on a 0-byte file)
}

protocol VideoFileInspecting: Sendable {
    func inspect(_ url: URL) async -> VideoInspectionResult
}

struct AVAssetVideoInspector: VideoFileInspecting {
    func inspect(_ url: URL) async -> VideoInspectionResult {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        let asset = AVURLAsset(url: url)   // created and consumed inside this call: never crosses isolation
        do {
            let (playable, duration) = try await asset.load(.isPlayable, .duration)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            return .inspected(VideoInspection(isPlayable: playable,
                                              durationSeconds: CMTimeGetSeconds(duration),
                                              videoTrackCount: tracks.count))
        } catch {
            let ns = error as NSError
            return .unreadable("\(ns.domain) \(ns.code): \(ns.localizedDescription)")
        }
    }
}
```

### Engine: additive finalize signal (ScreenRecorder.swift / ScreenRecording.swift)
```swift
// ScreenRecording protocol: + requirement (must be assigned BEFORE start, like the other two)
var onFinalized: (@Sendable () -> Void)? { get set }

// WriterSink.finalizeOnQueue — fire exactly once on every terminal exit:
guard writer.status == .writing else {
    logger.warning("Finalize: writer not writing (status=\(self.writer.status.rawValue)); nothing to finish")
    onFinalized?()                     // NEW: nothing left to wait for
    return
}
videoInput.markAsFinished()
writer.finishWriting { [logger, writer, onFinalized] in
    if let error = writer.error { logger.error("ScreenRecorder finishWriting error: \(error.localizedDescription)") }
    else { logger.info("ScreenRecorder writer finalized (\(String(describing: reason)))") }
    onFinalized?()                     // NEW: file is now final on disk
}
```
(Threaded through `ScreenRecorder.start` into `WriterSink.init` exactly like `onStreamStopped`, at L146-151.)

### Coordinator: ordered per-meeting funnel (shape compile-verified)
```swift
enum VideoEvent: Sendable { case firstFrame(UInt64), finalized }

// inside startVideoInner, BEFORE recorder.start(...)
let (events, continuation) = AsyncStream.makeStream(of: VideoEvent.self)
recorder.onFirstFrameHostTime = { ticks in continuation.yield(.firstFrame(ticks)) }
recorder.onFinalized = { continuation.yield(.finalized); continuation.finish() }
videoRecordTasks[meetingId] = Task {   // inherits actor isolation
    await self.persistVideoLifecycle(meetingId: meetingId, url: url,
                                     audioStartTicks: audioStartTicks, events: events)
}
// ...in the start-failure catch: continuation.finish(); defensively remove `url` (missing = expected)

private func persistVideoLifecycle(meetingId: String, url: URL, audioStartTicks: UInt64,
                                   events: AsyncStream<VideoEvent>) async {
    var linked = false
    for await event in events {
        switch event {
        case .firstFrame(let ticks):
            noteFirstFrame(meetingId: meetingId, ticks: ticks)            // keeps DEBUG videoAnchorPair + log
            linked = await linkVideo(meetingId: meetingId, url: url,
                                     offset: anchorOffset(audioStartTicks, ticks))
        case .finalized:
            await verifyFinalizedVideo(meetingId: meetingId, url: url, wasLinked: linked)
        }
    }
    videoRecordTasks[meetingId] = nil
}
```

### Disk tier (pure, Coordinator)
```swift
enum DiskSpaceTier: Equatable { case belowAudioFloor, belowVideoThreshold, sufficient }

static let minimumDiskSpaceBytes: Int64 = 500 * 1024 * 1024          // unchanged audio floor
static let videoHeadroomSeconds: Int64 = 2 * 60 * 60                 // D-02: ~2 h of video

static func videoDiskThreshold(for preset: ScreenRecorder.QualityPreset) -> Int64 {
    minimumDiskSpaceBytes + Int64(preset.bitrate) * videoHeadroomSeconds / 8
}

/// `videoPreset == nil` means screen recording is off (factory absent): audio floor only (D-03).
static func diskSpaceTier(available: Int64, videoPreset: ScreenRecorder.QualityPreset?) -> DiskSpaceTier {
    guard available >= minimumDiskSpaceBytes else { return .belowAudioFloor }
    guard let videoPreset else { return .sufficient }
    return available >= videoDiskThreshold(for: videoPreset) ? .sufficient : .belowVideoThreshold
}
```
Capacity seam (minimal): add an init parameter `availableDiskSpace: @escaping @Sendable () throws -> Int64? = RecordingCoordinator.systemAvailableDiskSpace`. The default wraps today's `resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])`. A `nil` or thrown value keeps today's behavior: treat it as 0 and block.

### Deletion (Storage/AudioFileManager.swift)
```swift
/// Deletes every media file for a meeting (WAV, M4A, MOV) by id. A missing file is the
/// expected state (WAV removed after ALAC; audio-only meetings have no .mov) — D-11.
static func deleteMedia(meetingId: String, in directory: URL = audioDirectory) {
    for ext in ["wav", "m4a", "mov"] {
        let url = directory.appendingPathComponent("\(meetingId).\(ext)")
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            logger.debug("No .\(ext) for \(meetingId) — nothing to delete")
        } catch {
            logger.warning("Failed to delete .\(ext) for \(meetingId): \(error.localizedDescription)")
        }
    }
}
```

### Launch orphan sweep (list, then read; skip on DB error)
```swift
static func cleanupOrphanedVideos(in directory: URL = audioDirectory,
                                  knownMeetingIds: () throws -> Set<String>) {
    let movs: [URL]
    do {
        movs = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "mov" }
    } catch {
        logger.warning("Skipping orphan video cleanup — cannot list \(directory.lastPathComponent): \(error.localizedDescription)")
        return
    }
    guard !movs.isEmpty else { return }
    let ids: Set<String>
    do { ids = try knownMeetingIds() } catch {
        logger.error("Skipping orphan video cleanup — could not read meetings: \(error.localizedDescription)")
        return                                              // D-10: never treat "can't read" as "no meetings"
    }
    for url in movs where !ids.contains(url.deletingPathExtension().lastPathComponent) {
        do { try FileManager.default.removeItem(at: url); logger.info("Removed orphaned video \(url.lastPathComponent)") }
        catch { logger.warning("Failed to remove orphaned video \(url.lastPathComponent): \(error.localizedDescription)") }
    }
}
// AppState.initialize, right after `database = try AppDatabase()` + ensureDirectoryExists():
// AudioFileManager.cleanupOrphanedVideos { try db.dbWriter.read { try String.fetchSet($0, sql: "SELECT meeting_id FROM meetings") } }
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `AVAsset.isPlayable` / `.duration` synchronous getters | `try await asset.load(.isPlayable, .duration)` | Deprecated macOS 13 (header: "Use load(.isPlayable) instead") | Use the async load API only |
| `AVAssetWriter.finishWriting()` (blocking) | `finishWriting(completionHandler:)` with an `NS_SWIFT_SENDABLE` handler | Long-standing | The completion handler is where `onFinalized` fires |
| Swift 5 unstructured `Task { @MainActor in }` (global-executor hop, no ordering) | Swift 6 `@isolated(any)` task creation enqueues directly on the target actor | Swift 6.0 | Underpins the clear-then-set ordering of `lastVideoError` [ASSUMED from SE-0431 semantics; empirically supported by 19-05] |

**Deprecated/outdated for this phase:** 18-RESEARCH's note that the `finishWriting` "defragment pass … grows with recording length". Measured 0.026 s for a 240 s / 120 MB file, in place. It is still correct not to block quit on it, but its cost is not the reason to avoid awaiting it.

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | `finishWriting` stays sub-second for 2 h recordings (measured only up to 240 s) | Empirical, Alternatives | Low. Only matters if the planner chooses "stop awaits finalize". The callback design is timing-agnostic |
| A2 | AVURLAsset results (`-11829` for 0-byte/garbage, 1-frame playable) are the same on macOS 14.2 as on 26.5 | Inspector, D-07 | Medium. A different verdict on 14.2 could keep or delete the wrong file. Re-run `VideoFileInspectorTests` on a 14.2 machine at the milestone-close gate (already pending for kill-9) |
| A3 | Audio-half anchor imprecision is tens of ms, because `mach_absolute_time()` is sampled after `recorder.start()` returns, not at the first sample | Anchor shape | Low. Only affects Phase 21 seek accuracy. Plumbing the exact `mHostTime` is out of scope |
| A4 | MainActor FIFO ordering between the `.recording` clear and the low-disk `applyVideoError` | Pitfall 3 | Low. The analogous TCC-denied path works on hardware (19-05). Add a coordinator test asserting message delivery |
| A5 | **Link-early** (at first frame) is an acceptable reading of D-05 ("set only when a playable `.mov` exists after stop/finalize") because the end state after every completed finalize satisfies D-05, and it is the only way to satisfy D-06 for quit/crash partials without a launch reconciliation | Pattern 2 | Medium. **Needs user confirmation** (Open Question 1) |
| A6 | An AVFoundation load error on a finalized file means unusable, so it is deleted (D-07), with no transient-failure retry | Inspector | Low. A local-file open failure is deterministic. The audio is always kept |
| A7 | The empty-DB guard on the orphan sweep is a refinement, not a contradiction, of D-10 | Pitfall 5 | Low. **Needs user confirmation** (Open Question 3) |

## Open Questions

1. **When does `video_file` get written: at first frame or after finalize?**
   - What we know: D-05's wording says after stop/finalize. D-06 wants crash and quit partials linked, and D-08 wants the anchor persisted. On quit, `NSApp.terminate` does not await finalize. The anchor exists only in memory until it is persisted.
   - Recommendation: **link early, verify on finalize** (Pattern 2). After every completed finalize the D-05 invariant holds (non-null means playable). Quit and crash partials stay linked with their anchor. The cost is that a crash in the first ~10 s (before any fragment flush) leaves a linked but unplayable file. Phase 21's player must handle a linked-but-unplayable file anyway (the user can also delete files in Finder).
   - Alternative (simpler, literal D-05): a single write in the finalize handler, with the engine passing first-frame ticks. Quit and crash partials stay unlinked and lose their anchor unless a launch reconciliation pass is added. Present both at plan approval.

2. **Touching the hardware-verified engine file (`ScreenRecorder.swift`).**
   - What we know: Phase 19 kept it zero-diff to preserve 18-04 validity. D-05 and D-07 are impossible to do correctly without a finalize-completion signal, and every alternative is a sleep or poll.
   - Recommendation: the additive `onFinalized` (two call sites, plus init threading), with unit tests through a directly constructed `WriterSink` plus a real `AVAssetWriter` (no TCC). End the phase with a short manual gate:
     - A real capture's row has `video_file` and offset ≈ 0.27 s.
     - Deleting the meeting removes the `.mov`.
     - A planted row-less `.mov` is swept at relaunch, and the 3 existing linked-by-row `.mov` files survive.
     - Before the gate, re-grant TCC.

3. **Should the orphan sweep skip when the meeting set is empty but `.mov` files exist?** Recommended yes, with a warning log (Pitfall 5). Confirm with the user.

4. **Settings discretion.**
   - Relabel "Audio storage used" → "Storage used": recommended. It's a one-string accuracy fix, since the total already includes `.mov`.
   - Extending "Clean Up Orphaned Files" to `.mov`: not recommended, because the launch sweep covers it (YAGNI). If it is extended, it must reuse the list-then-read sweep, never `findOrphanedWAVs()`-style logic.
   - **Pre-existing hazard found, out of scope:** that button deletes *every* `.wav`, including the in-flight recording's WAV and WAVs kept for retry by DATA-02. Flag this to the user as a separate quick task. Don't fix it here.

5. **Phase-19-era `.mov` files (dev machine only).** There are 3, all with rows, and they stay unlinked. Recommend no backfill: no released build ever wrote video.

6. **Low-disk copy.** The menu row prefixes every message with "Screen recording stopped — audio was saved:". A pre-start skip isn't strictly "stopped". Recommend message text that reads well after the prefix, for example "not enough free disk space for video (1.4 GB free, 2.8 GB needed); this meeting is recording audio only". Leave the prefix itself to Phase 21's UI work.

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Xcode / xcodebuild | build + `make test` | ✓ | 26.2 (17C52) | — |
| Swift toolchain | Swift 6 strict concurrency | ✓ | 6.2.3 | — |
| macOS SDK | build | ✓ | 26.2 (via `xcrun --sdk macosx`) | — |
| XcodeGen | regenerate project for new files | ✓ | 2.45.3 | — |
| GRDB | migration | ✓ | 7.10.0 (resolved) | — |
| SQLite (system) | FTS5 + ALTER | ✓ | 3.51.0 (dev machine) | — |
| macOS 14.2 test machine | A2 re-verification | ✗ | dev machine is 26.5.1 | Defer to the milestone-close gate (already pending for the kill-9 re-run) |
| Screen Recording TCC for the Debug build | manual gate only | unknown (revoked in 19-05) | — | User re-grants before the manual gate. Unit tests never need it |
| Real audio hardware | existing coordinator tests (real `AudioRecorder`) | ✓ (prior runs green, 341 tests at 19-04) | — | — |

**Missing dependencies with no fallback:** none blocking.
**Missing dependencies with fallback:** a 14.2 machine (deferred re-verification) and TCC re-grant (manual gate only).

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | XCTest (Xcode 26.2), hosted in `Caddie.app` (`TEST_HOST`) |
| Config file | `project.yml`. Run `make setup` after adding files |
| Quick run command | `xcodebuild test -project Caddie.xcodeproj -scheme Caddie -configuration Debug -destination 'platform=macOS' -only-testing:CaddieTests/<ClassName>` |
| Full suite command | `make test` (require `** TEST SUCCEEDED **`; baseline 341 tests at the end of Phase 19) |
| Estimated runtime | quick ~60–90 s (build-dominated) · full ~5–10 min |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| STOR-01 | Fresh schema has `video_file` + `video_start_offset` (15 columns) | unit | `-only-testing:CaddieTests/MigrationTests` | ✅ extend (13→15) |
| STOR-01 | v1 DB upgrades in place; rows kept; new columns NULL; FTS still finds old rows | unit | `…/MigrationTests` | ✅ extend |
| STOR-01 / D-04 | `video_file` never searchable; FTS columns exactly title/transcript/app; video-column UPDATE keeps FTS consistent | unit | `…/MigrationTests` | ✅ extend |
| STOR-01 | `Meeting` round-trips `videoFile` / `videoStartOffset`; defaults nil | unit | `-only-testing:CaddieTests/MeetingModelTests` | ✅ extend |
| D-07 inspector | synthetic playable fixture → usable; 0-byte / no-session → unreadable; garbage → unreadable; missing → `.missing` | unit (AVAssetWriter fixtures in a temp dir, no TCC) | `-only-testing:CaddieTests/VideoFileInspectorTests` | ❌ Wave 0 |
| engine signal | `WriterSink.finalize` fires `onFinalized` once (`.stopped`), once (`.streamError`), never twice; fires on the writer-not-writing path | unit (real AVAssetWriter, no SCStream) | `-only-testing:CaddieTests/WriterSinkFinalizeTests` | ❌ Wave 0 |
| STOR-01 / D-08 | first frame → row has `video_file = "<id>.mov"` and `video_start_offset` non-nil | unit (mock engine + mock inspector) | `-only-testing:CaddieTests/RecordingCoordinatorVideoStorageTests` | ❌ Wave 0 |
| D-07 | finalize with an unusable verdict → both columns NULL; inspector called once with `videoPath(for:)` | unit | same | ❌ Wave 0 |
| D-05 | start throw → NULL, inspector never called | unit | same | ❌ Wave 0 |
| SC4 | no factory → NULL, no inspector calls, no video warning | unit | same | ❌ Wave 0 |
| timed-out / late finalize | `finalizeDelay` beyond reaching `.transcribing` (and across meeting #2) → row reconciled correctly per meetingId | unit | same | ❌ Wave 0 |
| D-06 | stream death + mock finalize mid-meeting → row reconciled while `.recording`; teardown adds no second inspection | unit | same | ❌ Wave 0 |
| STOR-03 / D-02 | threshold per preset = 1,874,288,000 / 2,774,288,000 / 4,124,288,000; tier boundaries (exact `>=`), nil preset → audio floor only | unit (pure) | `-only-testing:CaddieTests/DiskSpaceTierTests` | ❌ Wave 0 |
| STOR-03 / D-01 / D-03 | injected capacity: <500 MB → `.error`, no row; between → `.recording`, factory not called, warning mentions disk; ≥ threshold → video starts; feature off at 600 MB → records, no warning | unit (injected capacity provider) | `…/RecordingCoordinatorVideoStorageTests` | ❌ Wave 0 |
| STOR-02 / D-09 / D-11 | `deleteMedia` removes wav/m4a/mov in a temp dir; missing `.mov` is fine (no throw) | unit | `-only-testing:CaddieTests/MediaFileTests` | ❌ Wave 0 |
| D-10 | sweep deletes only row-less `.mov`; ignores wav/m4a; ID-source throw → nothing deleted; (if adopted) empty set → nothing deleted | unit (temp dir + closure ID source) | `…/MediaFileTests` | ❌ Wave 0 |
| hardware | real capture links row with offset ≈ 0.27 s; delete removes `.mov`; relaunch sweeps a planted orphan and keeps real ones | manual gate | — | manual |

### Sampling Rate
- **Per task commit:** the `-only-testing` quick command for the touched class
- **Per wave merge:** `make test`
- **Phase gate:** full suite green + manual gate before `/gsd:verify-work`

### Wave 0 Gaps
- [ ] `Tests/Mocks/MockScreenRecorder.swift`: add `onFinalized`. Fire it at the end of `stop()` by default, plus a `finalizeDelay` (late finalize), `neverFinalize` (wedge/quit), and `simulateFinalize()` (stream death). Keep all state lock-guarded.
- [ ] `Tests/Mocks/MockVideoInspector.swift`: scripted `VideoInspectionResult`, lock-guarded call log.
- [ ] `RecordingCoordinator` init seams: `videoInspector: VideoFileInspecting = AVAssetVideoInspector()`, `availableDiskSpace: @Sendable () throws -> Int64?` (defaults preserve production behavior).
- [ ] `AudioFileManager`: directory-injectable `deleteMedia` and sweep (defaults to `audioDirectory`).
- [ ] Synthetic `.mov` fixture helper for tests (AVAssetWriter + CVPixelBufferPool, H.264 or HEVC). Write to `FileManager.default.temporaryDirectory`, **never** `audioDirectory`.
- [ ] New test files listed above. Run `xcodegen generate`.

## Security Domain

### Applicable ASVS Categories
| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | no | — |
| V3 Session Management | no | — |
| V4 Access Control | no (single local user) | — |
| V5 Input Validation | yes (low) | Reject `meeting_id` containing `/` or `..` before building delete paths. The sweep only enumerates the directory |
| V6 Cryptography | no | — |
| V8 Data Protection | yes | Screen video is sensitive. Delete by meetingId regardless of column state, plus the launch orphan sweep. No new network paths (privacy constraint) |
| V12 Files & Resources | yes | All deletes confined to `audioDirectory`, non-recursive enumeration, `.mov` extension filter, explicit per-file error logging |
| V7 Errors & Logging | yes | Log filenames, meetingIds, and inspection codes. Never log screen content. Use `CaddieLogger.storage` / coordinator logger |

### Known Threat Patterns for this phase
| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Deleted meeting's screen video lingers on disk | Information disclosure | `deleteMedia` by id + launch sweep (D-09/D-10) |
| Sweep misreads DB state and deletes live videos | Tampering (self-inflicted data loss) | List-then-read ordering, skip on DB error, run before coordinator, optional empty-set guard |
| Disk exhaustion from video kills the audio recording | Denial of service | D-01 two-tier guard (audio floor preserved) |
| Crafted `meeting_id` path traversal in delete | Tampering | Separator check (low risk: local, user-owned DB) |
| Unusable or partial file presented as the meeting's video | Integrity | Inspector-verified link; unusable → delete + NULL (D-07) |

## Sources

### Primary (HIGH confidence)
- Caddie source read this session: `Sources/Coordinator/RecordingCoordinator.swift`, `RecordingState.swift`, `Sources/Recording/ScreenRecorder.swift`, `ScreenRecording.swift`, `ScreenRecordingSettings.swift`, `ScreenRecorderHarness.swift`, `Sources/Storage/*`, `Sources/App/AppState.swift`, `CaddieApp.swift`, `Sources/Transcription/TranscriptionPipeline.swift`, `Sources/UI/MainWindow/MeetingDetailView.swift`, `ContentView.swift`, `Sources/UI/Settings/SettingsView.swift`, `Sources/UI/MenuBar/MenuBarView.swift`, `Tests/MigrationTests.swift`, `MeetingModelTests.swift`, `RecordingCoordinator*Tests.swift`, `Mocks/MockScreenRecorder.swift`, `AppStateVideoErrorTests.swift`, `project.yml`, `Makefile`, `README.md`
- macOS SDK 26.2 headers: `AVAssetWriter.h` (`cancelWriting` deletes the file; `finishWritingWithCompletionHandler:`; `movieFragmentInterval`; `startSessionAtSourceTime:` "first session begins at movie time 0"), `AVAsset.h` (`isPlayable` deprecated for `load(.isPlayable)`)
- GRDB 7.10.0 local checkout: `TableAlteration.add(column:_:)`, `ColumnType.double`, `DatabaseMigrator.migrate(_:upTo:)`, `fetchSet`, `UInt64.databaseValue = Int64(self)`
- https://raw.githubusercontent.com/groue/GRDB.swift/master/GRDB/Documentation.docc/Migrations.md: never modify shipped migrations, `alter` example, `upTo:` testing
- https://www.sqlite.org/lang_altertable.html: ADD COLUMN modifies schema text only, restrictions, full-schema reparse
- https://www.sqlite.org/fts5.html: external-content column fetch by declared names (§4.4.3), `integrity-check` incl. rank=1 (§6.7), `rebuild`
- Local empirical probes (this session): AVAssetWriter finalize/inode/timing, edge-case inspection results, movie-time origin, `removeItem` error code, Swift 6 compile shapes, sqlite3 3.51.0 FTS5 after ADD COLUMN
- `.planning/phases/18-*/18-RESEARCH.md`, `18-CONTEXT.md`; `.planning/phases/19-*/19-CONTEXT.md`, `19-RESEARCH.md`, `19-05-SUMMARY.md`, `19-VALIDATION.md`

### Secondary (MEDIUM confidence)
- Swift 6 `@isolated(any)` task-enqueue ordering (SE-0431), supported by the 19-05 hardware result for the TCC-denied message

### Tertiary (LOW confidence)
- WebSearch on when FTS5 `integrity-check` rank=1 was introduced: unresolved (a GNOME Tracker issue points at the 3.44.x era). Tests should not depend on it on older systems. https://gitlab.gnome.org/GNOME/tracker/-/issues/418

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH. No new dependencies. Every API was confirmed in the local SDK or GRDB source.
- Schema / FTS5 safety: HIGH. Official docs agree with a local reproduction.
- Finalize gap and engine signal: HIGH. Code read plus probe (in-place finalize, 0-byte no-session files).
- Funnel and inspector shapes: HIGH for compile and ordering. MEDIUM for 14.2 runtime parity (A2).
- Disk tier: HIGH. Pure math verified against the D-02 figures.
- Pitfalls: HIGH. Most were found by reading the actual call sites and the dev machine's on-disk state.

**Research date:** 2026-11-19
**Valid until:** 2026-12-19 (stable domain; re-check only if GRDB or the deployment floor changes)

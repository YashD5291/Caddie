# Phase 20: Video Storage & Retention - Pattern Map

**Mapped:** 2026-11-19
**Files analyzed:** 22 (12 production/docs modified or created, 10 test files created or extended)
**Analogs found:** 22 / 22. Every file has an in-repo analog. Most are self-analogs (extend the existing file in its own style).

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `Sources/Storage/Migrations.swift` (mod) | migration | CRUD (schema) | same file, `v1_create_meetings` L6-23 | exact (self) |
| `Sources/Storage/Meeting.swift` (mod) | model | CRUD | same file, `audioFile` L24/L39/L53/L73 | exact (self) |
| `Sources/Storage/AudioFileManager.swift` (mod) | utility | file-I/O | same file, `deleteAudio` L250-261, `cleanupOrphanedTempFiles` L286-311 | exact (self) |
| `Sources/Storage/VideoFileInspector.swift` (NEW) | service (protocol + AVFoundation conformer) | request-response (async file inspect) | `Sources/Recording/ScreenRecorderHarness.swift` L82-101 (AVURLAsset load) + `Sources/Transcription/ASREngineProtocol.swift` (Sendable DI protocol) | role-match |
| `Sources/Recording/ScreenRecording.swift` (mod) | protocol seam | event-driven | same file, `onStreamStopped` L16-18 | exact (self) |
| `Sources/Recording/ScreenRecorder.swift` (mod, additive) | engine | event-driven | same file, `onStreamStopped` threading L35-36, L146-152, L444-466, L508-516 | exact (self) |
| `Sources/Coordinator/RecordingCoordinator.swift` (mod) | actor / controller | event-driven + CRUD | same file, `checkDiskSpace` L299-315, `startVideoInner` L444-492, targeted UPDATE L636-644 | exact (self) |
| `Sources/App/AppState.swift` (mod) | app bootstrap | batch (launch sweep) | same file, DATA-05 call L102-105 | exact (self) |
| `Sources/UI/MainWindow/MeetingDetailView.swift` (mod) | component | CRUD (delete) | same file, `deleteMeeting()` L293-303 | exact (self) |
| `Sources/UI/Settings/SettingsView.swift` (mod, discretion) | component | display | same file, storage section L193-199 | exact (self) |
| `Sources/Recording/ScreenRecorderHarness.swift` (optional mod) | DEBUG harness | request-response | same file L82-101 | exact (self) |
| `README.md`, `.planning/REQUIREMENTS.md`, `.planning/ROADMAP.md` (mod) | docs | n/a | README L59-66, REQUIREMENTS L22-25/L82-87, ROADMAP L75-86 | exact (self) |
| `Tests/MigrationTests.swift` (extend) | test | CRUD | same file L14-30, L102-127 | exact (self) |
| `Tests/MeetingModelTests.swift` (extend) | test | CRUD | same file L14-34 | exact (self) |
| `Tests/VideoFileInspectorTests.swift` (NEW) | test | file-I/O | `Tests/MonoMixdownTests.swift` (temp dir + fixture writer) + `ScreenRecorder.start` L116-141 (writer setup) | role-match |
| `Tests/WriterSinkFinalizeTests.swift` (NEW) | test | event-driven | `Tests/ScreenRecorderStateTests.swift` (engine unit tests) + `ErrorCollector` lock pattern | role-match |
| `Tests/MediaFileTests.swift` (NEW) | test | file-I/O | `Tests/MonoMixdownTests.swift` L5-18 | exact |
| `Tests/DiskSpaceTierTests.swift` (NEW) | test | transform (pure) | `Tests/ScreenRecorderConfigTests.swift` | exact |
| `Tests/RecordingCoordinatorVideoStorageTests.swift` (NEW) | test | event-driven | `Tests/RecordingCoordinatorScreenCaptureTests.swift` + `...TeardownTests.swift` | exact |
| `Tests/Mocks/MockScreenRecorder.swift` (extend) | test mock | event-driven | same file (lock-guarded knobs L23-46, factory propagation L83-121) | exact (self) |
| `Tests/Mocks/MockVideoInspector.swift` (NEW) | test mock | request-response | `Tests/Mocks/MockScreenRecorder.swift` (lock-guarded `@unchecked Sendable`) | exact |

---

## Pattern Assignments

### `Sources/Storage/Migrations.swift` (migration)

**Analog:** same file. Add a SECOND `registerMigration` inside `run(_:)`, after the v1 closure closes at L63. Never edit v1.

**Registration + column-builder style** (L4-23):
```swift
enum Migrations {
    static func run(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1_create_meetings") { db in
            // Main meetings table
            try db.create(table: "meetings") { t in
                ...
                t.column("audio_file", .text)
                ...
            }
```
**FTS triggers to leave untouched** (L41-62): `meetings_ai`, `meetings_ad`, `meetings_au` name `title, transcript, app` explicitly. `meetings_au` is `AFTER UPDATE` with no `OF` column list, so each video-column UPDATE re-indexes the row with identical values. That is harmless, but it is a reason to skip redundant writes.

**New block shape** (from RESEARCH §Migration, mirrors the closure style above):
```swift
migrator.registerMigration("v2_add_video_columns") { db in
    try db.alter(table: "meetings") { t in
        t.add(column: "video_file", .text)
        t.add(column: "video_start_offset", .double)
    }
}
```

---

### `Sources/Storage/Meeting.swift` (model)

**Analog:** same file. Thread each new field through all four places `audioFile` appears:

- Stored property (L24): `var audioFile: String?` → add `var videoFile: String?` and `var videoStartOffset: Double?` right after it.
- Init parameter (L39), defaulted to nil and kept before `status`: `audioFile: String? = nil,`
- Init assignment (L53): `self.audioFile = audioFile`
- CodingKeys (L73), snake_case mapping:
```swift
        case audioFile = "audio_file"
```
→ `case videoFile = "video_file"` and `case videoStartOffset = "video_start_offset"`.

Do NOT change `search(_:)` (L95-102). It already selects `meetings.*` filtered through `meetings_fts`, so the new columns decode but are never matched.

---

### `Sources/Storage/AudioFileManager.swift` (utility, file-I/O)

**Analog:** same file.

**Logger + enum shape** (L5-6): `enum AudioFileManager { private static let logger = CaddieLogger.storage`.

**Path helper pattern** (L28-46): every path is `audioDirectory.appendingPathComponent("\(meetingId).<ext>")`. For D-15 testability, the new `deleteMedia` and the sweep must take `in directory: URL = audioDirectory` and build paths from `directory`, not by calling `wavPath(for:)`/`videoPath(for:)`, which are hard-wired to the real directory.

**Doc comment to rewrite** (L38-43). It currently says "Phase 20 owns deletion — `deleteAudio(meetingId:)` intentionally does NOT remove this file yet". Update it once deletion lands.

**Function to rename and extend (D-09)** (L250-261):
```swift
    /// Deletes both WAV and M4A files for a given meeting ID.
    static func deleteAudio(meetingId: String) {
        let fm = FileManager.default
        let wav = wavPath(for: meetingId)
        let m4a = alacPath(for: meetingId)
        do { try fm.removeItem(at: wav) } catch {
            logger.warning("Failed to delete WAV for \(meetingId): \(error.localizedDescription)")
        }
        do { try fm.removeItem(at: m4a) } catch {
            logger.warning("Failed to delete M4A for \(meetingId): \(error.localizedDescription)")
        }
    }
```
Today every missing file logs a warning. In the normal path the WAV is always missing after ALAC conversion. The new `deleteMedia(meetingId:in:)` loops `["wav", "m4a", "mov"]` and adds a typed expected-missing branch, `catch let error as CocoaError where error.code == .fileNoSuchFile` → `logger.debug` (D-11, see RESEARCH §Deletion). Other errors keep `logger.warning`. Optional V5 guard: reject a `meetingId` that contains `/` or `..`.

**Launch-sweep pattern to mirror (D-10)** (L286-311):
```swift
    static func cleanupOrphanedTempFiles() {
        let tempDir = FileManager.default.temporaryDirectory
        let fm = FileManager.default
        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
        } catch {
            logger.warning("Failed to enumerate temp directory: \(error.localizedDescription)")
            return
        }

        let orphans = contents.filter { $0.lastPathComponent.hasPrefix("caddie_mono_") }
        for orphan in orphans {
            do {
                try fm.removeItem(at: orphan)
            } catch {
                logger.warning("Failed to remove orphaned temp file \(orphan.lastPathComponent): \(error.localizedDescription)")
            }
        }

        if !orphans.isEmpty {
            logger.info("Cleaned up \(orphans.count) orphaned temp file(s)")
        }
    }
```
New `cleanupOrphanedVideos(in:knownMeetingIds:)` keeps this structure (enumerate → filter by `pathExtension.lowercased() == "mov"` (the same filter as `findOrphanedWAVs` L247) → per-file do/catch → summary info log) and adds three steps:
- Read `knownMeetingIds()` AFTER listing files.
- On a throw, `logger.error` and return (D-10).
- On an empty set with non-empty `.mov` files, `logger.warning` and return (D-14).

Full shape: RESEARCH §Launch orphan sweep.

**Anti-pattern:** do NOT reuse `findOrphanedWAVs()` (L237-248) logic. "Every file with the extension" includes in-flight files (D-16).

---

### `Sources/Storage/VideoFileInspector.swift` (NEW, service)

**Analog A, AVFoundation load call:** `Sources/Recording/ScreenRecorderHarness.swift` L82-97:
```swift
    static func runValidateMode(path: String) -> Never {
        let url = URL(fileURLWithPath: path)

        Task {
            let asset = AVURLAsset(url: url)
            do {
                let (isPlayable, duration) = try await asset.load(.isPlayable, .duration)
                let seconds = CMTimeGetSeconds(duration)
                print("VALIDATE isPlayable=\(isPlayable) duration=\(seconds)")
```
Copy the `AVURLAsset(url:)` + `load(.isPlayable, .duration)` + `CMTimeGetSeconds` core, and add `loadTracks(withMediaType: .video)`. Do NOT call the harness itself: it is `#if DEBUG`, returns `Never`, and calls `exit()`.

**Analog B, Sendable DI protocol file:** `Sources/Transcription/ASREngineProtocol.swift`:
```swift
import Foundation

/// Contract for ASR (Automatic Speech Recognition) engines.
/// Sendable conformance required because TranscriptionPipeline is an actor.
protocol ASREngineProtocol: Sendable {
    func transcribe(audioURL: URL) async throws -> (segments: [ASRSegment], language: String, duration: Double)
}
```
Use the same shape: `protocol VideoFileInspecting: Sendable { func inspect(_ url: URL) async -> VideoInspectionResult }`, with a doc comment explaining why it is `Sendable` (the coordinator actor holds it). The production conformer `AVAssetVideoInspector` is a `struct` in the same file (one main type per file, plus small value types). The types `VideoInspection`, `VideoInspectionResult`, and `AVAssetVideoInspector` come verbatim from RESEARCH §Inspector.

**Logging:** use `CaddieLogger.storage` (Logger.swift L11) if the inspector logs at all. RESEARCH puts the logging in the coordinator, which acts on the result.

---

### `Sources/Recording/ScreenRecording.swift` (protocol seam)

**Analog:** same file L11-18. Add a third callback requirement that matches the existing doc-comment contract:
```swift
    /// Fires once with the first written frame's host time (mach ticks) — the video half
    /// of the STOR-04 anchor pair. Must be assigned BEFORE `start`; the engine captures
    /// its current value at start time, so a later assignment is a silent no-op.
    var onFirstFrameHostTime: (@Sendable (UInt64) -> Void)? { get set }

    /// Fires if the stream dies mid-meeting (window closed, SCK error -3821). The
    /// authoritative death signal — `isRecording` still reads `true` after a stream error.
    var onStreamStopped: (@Sendable (Error?) -> Void)? { get set }
```
→ `var onFinalized: (@Sendable () -> Void)? { get set }`, documented with "fires exactly once after `finishWriting` completes (or immediately if the writer was not writing); must be assigned BEFORE `start`" (Pitfall 8). Also update the type doc (L8-9), which says "The two callbacks are `@Sendable`" and becomes "three".

---

### `Sources/Recording/ScreenRecorder.swift` (engine, additive only, D-13)

**Analog:** same file. Thread `onFinalized` through the exact four places `onStreamStopped` goes. Make no other change, so the 18-04 hardware verification stays valid.

1. Public property (L35-36):
```swift
    /// Fired if the stream dies (`didStopWithError`). `@Sendable`: arrives on SCK's queue.
    var onStreamStopped: (@Sendable (Error?) -> Void)?
```
2. Captured into the sink at start (L146-152):
```swift
        let sink = WriterSink(
            writer: writer,
            videoInput: videoInput,
            queue: writerQueue,
            onFirstFrameHostTime: onFirstFrameHostTime,
            onStreamStopped: onStreamStopped
        )
```
3. Sink stored `let` + init param + assignment (L444-445, L455-466):
```swift
    private let onFirstFrameHostTime: (@Sendable (UInt64) -> Void)?
    private let onStreamStopped: (@Sendable (Error?) -> Void)?
    ...
    init(
        writer: AVAssetWriter,
        videoInput: AVAssetWriterInput,
        queue: DispatchQueue,
        onFirstFrameHostTime: (@Sendable (UInt64) -> Void)?,
        onStreamStopped: (@Sendable (Error?) -> Void)?
    ) {
```
Give the new init param a default of `nil` only if the planner wants to keep test construction short. Otherwise keep it explicit, like the other two.

4. Fire points in `finalizeOnQueue` (L575-586). These are the ONLY two terminal exits after the idempotency guard at L561-563, so "exactly once" comes from that existing guard:
```swift
        guard writer.status == .writing else {
            logger.warning("Finalize: writer not writing (status=\(self.writer.status.rawValue)); nothing to finish")
            return                                   // ← fire onFinalized?() before return
        }
        videoInput.markAsFinished()
        writer.finishWriting { [logger, writer] in   // ← add onFinalized to capture list
            if let error = writer.error {
                logger.error("ScreenRecorder finishWriting error: \(error.localizedDescription)")
            } else {
                logger.info("ScreenRecorder writer finalized (\(String(describing: reason)))")
            }
                                                     // ← fire onFinalized?() here (after log)
        }
```
`finalize(reason:)` (L552-556) is the public entry the new `WriterSinkFinalizeTests` call directly. It is already internal, so it is reachable through `@testable`.

**Pure-math helper to reuse (do not re-implement):** `hostTicksToSeconds(_:timebase:)` L316-318. **Preset source for D-02:** `QualityPreset.bitrate` L255-261 and `QualityPreset.default` L243.

---

### `Sources/Coordinator/RecordingCoordinator.swift` (actor, event-driven + CRUD)

**Analog:** same file. Six touch points.

**(a) Init seams.** Add to the dependency list L16-38 and init L120-136, following the defaulted trailing-param style:
```swift
    init(
        database: AppDatabase,
        recorder: AudioRecorder,
        pipeline: TranscriptionPipeline,
        detector: MeetingDetector,
        audioDeviceManager: AudioDeviceManager? = nil,
        liveTranscriber: LiveTranscriber? = nil,
        screenRecorderFactory: ScreenRecorderFactory? = nil
    ) {
```
Append `videoInspector: VideoFileInspecting = AVAssetVideoInspector()` and `availableDiskSpace: @escaping @Sendable () throws -> Int64? = RecordingCoordinator.systemAvailableDiskSpace`. Existing call sites (AppState L168-176, all coordinator tests) stay source-compatible.

**(b) Disk tier (D-01/D-02/D-03).** Replace `checkDiskSpace()` L299-315. Keep its constant and error type:
```swift
    private static let minimumDiskSpaceBytes: Int64 = 500 * 1024 * 1024  // 500 MB

    private func checkDiskSpace() throws {
        let resourceValues = try AudioFileManager.audioDirectory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        guard let available = resourceValues.volumeAvailableCapacityForImportantUsage,
              available >= Self.minimumDiskSpaceBytes else {
            let available = resourceValues.volumeAvailableCapacityForImportantUsage ?? 0
            throw CoordinatorError.insufficientDiskSpace(
                available: available,
                required: Self.minimumDiskSpaceBytes
            )
        }
    }
```
- The `resourceValues(...)` read becomes the body of the default `systemAvailableDiskSpace` provider.
- Add a pure `static func diskSpaceTier(available:videoPreset:)` and `videoDiskThreshold(for:)` (RESEARCH §Disk tier).
- Make both static and non-private (internal) so `DiskSpaceTierTests` can call them through `@testable`.
- Caller site (L339-345), keep the shape `do { … } catch { logger.error(...); await handle(.recordingFailed(error)); return }` for `.belowAudioFloor`.
- `videoPreset` is `nil` when `screenRecorderFactory == nil` (D-03, "inert by absence", the same gate as `startVideo` L438).
- `CoordinatorError.insufficientDiskSpace` (L756, L762-764) hard-codes "required: 500 MB" in its copy. That stays correct for the audio-floor tier.

**(c) Low-disk skip (D-01).** At the existing `startVideo` call site (L411-414), branch on the tier. Use `surfaceVideoError` (L618-621) instead of `startVideo` when the tier is `.belowVideoThreshold`:
```swift
            // Video is subordinate to audio: it starts only once audio is genuinely
            // running, and nothing in the video path can precede, gate, or fail the
            // audio start (VID-03 / VID-04).
            startVideo(meetingId: meetingId, audioStartTicks: audioStartTicks)
```
```swift
    private func surfaceVideoError(_ message: String) {
        logger.error("Video error surfaced: \(message)")
        onVideoError?(message)
    }
```
Pitfall 3: this must run after the `.recording` transition, which it does because the side effect runs after `onStateChange` at L170-176.

**(d) Single preset constant.** L473 hard-codes `.balanced`:
```swift
            try await recorder.start(target: .display(nil), preset: .balanced, outputURL: url)
```
Replace it with one `private static let videoPreset: ScreenRecorder.QualityPreset = .default`, used by both `start(...)` and the threshold.

**(e) Per-meeting event funnel (D-05/D-06/D-07/D-08).** Rewire the callback assignments in `startVideoInner` L450-458. They must still be assigned BEFORE `start()`:
```swift
        recorder.onFirstFrameHostTime = { [weak self] ticks in
            Task { await self?.recordFirstFrameAnchor(ticks) }
        }
        recorder.onStreamStopped = { [weak self] error in
            Task { await self?.handleVideoStreamStopped(error) }
        }
```
- `onFirstFrameHostTime` and the new `onFinalized` yield into `AsyncStream.makeStream(of: VideoEvent.self)`. The consumer `Task` is created in actor context, so it inherits isolation, as `videoStartTask = Task { await self.startVideoInner(...) }` does at L439-441.
- `onStreamStopped` stays as is.
- The start-failure catch (L485-491) must also `continuation.finish()` and defensively remove the file (missing is expected).
- Keep `recordFirstFrameAnchor` (L494-506) as the in-memory + log step. Its offset math is the value to persist:
```swift
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let offset = ScreenRecorder.hostTicksToSeconds(ticks, timebase: timebase)
                   - ScreenRecorder.hostTicksToSeconds(ctx.audioStartTicks, timebase: timebase)
```
- The funnel must be keyed by `meetingId` (a late finalize can land after meeting #2 starts, after `stopVideo` L552-553 has nilled `videoContext`). So the link/verify handlers must NOT read `videoContext`. Pass `meetingId`, `url`, and `audioStartTicks` in explicitly.

**(f) Targeted UPDATE style for link / unlink.** Copy L635-644 exactly. Never use `Meeting.update(db)`:
```swift
        do {
            try await database.dbWriter.write { dbConn in
                try dbConn.execute(
                    sql: "UPDATE meetings SET end_time = ? WHERE meeting_id = ?",
                    arguments: [endTime, meetingId]
                )
            }
        } catch {
            logger.error("Failed to update meeting end_time: \(error.localizedDescription)")
        }
```
→ `"UPDATE meetings SET video_file = ?, video_start_offset = ? WHERE meeting_id = ?"` (link) and `"... SET video_file = NULL, video_start_offset = NULL WHERE meeting_id = ?"` (D-07 discard). Every writer in the codebase (coordinator L638/677/702/726, pipeline L194/232/251) uses this targeted style, so the new columns cannot be clobbered. A 0-row update (meeting deleted mid-recording, Pitfall 9) is safe, as the comment at L715-717 already documents.

**Logger:** the coordinator uses its own `Logger(subsystem: "com.caddie.app", category: "RecordingCoordinator")` (L116). Log meetingId, filename, and inspection result codes.

**DEBUG accessors** (L222-247): `videoAnchorPair` / `videoOutputURL` stay. Add new test-only accessors in the same `#if DEBUG` block if needed (for example, "funnel drained for meetingId").

---

### `Sources/App/AppState.swift` (bootstrap, launch sweep)

**Analog:** same file L102-105, the DATA-05 launch cleanup call site:
```swift
            database = try AppDatabase()
            try AudioFileManager.ensureDirectoryExists()
            AudioFileManager.cleanupOrphanedTempFiles() // DATA-05
            SystemAudioCapture.cleanupStaleAggregateDevices() // REC-06
```
Insert the sweep right after `ensureDirectoryExists()`, with a requirement tag comment in the same style (`// STOR-02 / D-10`). The ID source closure reads through `database` (still optional at this point; `db` is unwrapped only at L135). Unwrap the local or capture the freshly built `AppDatabase` value. The ID query uses GRDB `String.fetchSet(dbConn, sql: "SELECT meeting_id FROM meetings")` inside `dbWriter.read`. The sweep runs before `RecordingCoordinator(...)` at L168, so no capture is in flight.

**Do not touch:** the `.recording` handler L192-199 that clears `lastVideoError`, and `applyVideoError` L286-289. The low-disk message reuses them unchanged.

---

### `Sources/UI/MainWindow/MeetingDetailView.swift` (component, delete)

**Analog:** same file L293-303, the only delete call site:
```swift
    private func deleteMeeting() {
        guard let db = appState.database else { return }
        do {
            try db.dbWriter.write { dbConn in
                _ = try Meeting.deleteOne(dbConn, id: meeting.id)
            }
            AudioFileManager.deleteAudio(meetingId: meeting.meetingId)
        } catch {
            CaddieLogger.storage.error("Failed to delete meeting: \(error.localizedDescription)")
        }
    }
```
The only change is renaming the call to `AudioFileManager.deleteMedia(meetingId: meeting.meetingId)`. Ordering (row first, then files) stays. If the file delete fails, the launch sweep later catches the leftover.

---

### `Sources/UI/Settings/SettingsView.swift` (component, discretion)

**Analog:** same file L195-199:
```swift
            HStack {
                Text("Audio storage used")
```
The recommended one-string change is "Storage used". `totalStorageUsed()` (AudioFileManager L264-284) already sums `.mov`. **Do NOT touch** the "Clean Up Orphaned Files" button L213-224 (D-16).

---

### `README.md` / `.planning/REQUIREMENTS.md` / `.planning/ROADMAP.md` (docs)

- README L59-66 "Screen recording (opt-in, in progress)": delete the **Known gaps** bullet (L65). Add a bullet in the same bold-lead style as L66 ("**Audio always wins.** …") that covers deletion removing the `.mov` and the low-disk audio-only fallback (D-12).
- REQUIREMENTS L24 (STOR-03 wording, per D-01), L25 + L82 (STOR-04 traceability: storage leg → Phase 20, per D-08).
- ROADMAP L79 (add STOR-04) and success criterion 3 at L84 (D-01 two-tier wording).

---

### `Tests/MigrationTests.swift` (extend)

**Analog:** same file.

**Fixture + setUp** (L5-10): `var db: AppDatabase!` with `db = try AppDatabase(inMemory: true)`.

**Column-count assertion to update FIRST (Pitfall 6)** (L14-30):
```swift
        let expected = [
            "id", "meeting_id", "title", "app", "date", "start_time",
            "end_time", "duration_seconds", "audio_file", "status",
            "transcript", "error", "created_at"
        ]

        XCTAssertEqual(columnNames.count, 13, "meetings table should have 13 columns")
```
→ add `"video_file", "video_start_offset"` and change the count to 15.

**Raw-SQL insert + FTS MATCH pattern** (L102-127). This is the template for the "video-column UPDATE keeps FTS consistent" test:
```swift
        try db.dbWriter.write { dbConn in
            try dbConn.execute(sql: """
                UPDATE meetings SET transcript = 'discussed architecture patterns' WHERE meeting_id = 'fts-update'
                """)
        }

        let afterResults = try db.dbWriter.read { dbConn in
            try Row.fetchAll(dbConn, sql: "SELECT * FROM meetings_fts WHERE meetings_fts MATCH 'architecture'")
        }
```
For the v1→v2 upgrade and not-searchable tests, use the RESEARCH §Upgrade-path code. It builds its own `DatabaseQueue()` and `DatabaseMigrator` with `Migrations.run(&migrator)`, which mirrors `AppDatabase.migrate` in `Database.swift` L38-42.

---

### `Tests/MeetingModelTests.swift` (extend)

**Analog:** same file L14-34, the insert-then-`fetchOne(dbConn, key:)` round trip:
```swift
        var meeting = Meeting(
            title: "Standup",
            date: "2026-03-19",
            startTime: "2026-03-19T09:00:00Z"
        )
        try db.dbWriter.write { dbConn in
            try meeting.insert(dbConn)
        }
        let fetched = try db.dbWriter.read { dbConn in
            try Meeting.fetchOne(dbConn, key: meeting.id)
        }
```
Add (1) defaults nil for `videoFile`/`videoStartOffset`, and (2) set both, insert, fetch, and assert equality (offset with `accuracy:`).

---

### `Tests/MediaFileTests.swift` (NEW) and `Tests/VideoFileInspectorTests.swift` (NEW)

**Analog:** `Tests/MonoMixdownTests.swift` L1-18, the per-test temp-dir lifecycle (D-15: never `audioDirectory`):
```swift
import XCTest
import AudioToolbox
@testable import Caddie

final class MonoMixdownTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }
```
The fixture-builder helper lives under `// MARK: - Helpers` as a private throwing func (L58-104 `createStereoWAV`). Project rules forbid force-unwrap/`try!` in production code but this test file already uses `try!` in setUp. Prefer `setUpWithError() throws` (MigrationTests L8) for new files.

**MediaFileTests specifics:**
- Create empty files `"<id>.wav/.m4a/.mov"` in `tempDir`.
- Call `deleteMedia(meetingId:in: tempDir)` and `cleanupOrphanedVideos(in: tempDir) { ids }`.
- The ID source is a closure that returns a `Set<String>` or throws, so a throw → nothing deleted and an empty set → nothing deleted (D-14).

**VideoFileInspectorTests fixture writer.** The AVAssetWriter setup to copy is `ScreenRecorder.start` L116-141:
```swift
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        } catch {
            throw ScreenRecorderError.writerCreationFailed(error)
        }
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)

        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: Self.videoSettings(for: preset, dimensions: dims)
        )
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else { ... }
        writer.add(videoInput)
        guard writer.startWriting() else { ... }
```
- `ScreenRecorder.videoSettings(for:dimensions:)` (L278-290) is internal static, so tests can reuse it for an HEVC fixture.
- Frames come from a `CVPixelBufferPool` / `AVAssetWriterInputPixelBufferAdaptor` (no analog in the repo; RESEARCH Wave 0).
- Fixtures cover a playable file (usable), a 0-byte file, no-session (startWriting then finish, so 0 bytes), 4 KB garbage, and a missing path (`.missing`).

---

### `Tests/WriterSinkFinalizeTests.swift` (NEW)

**Analogs:**
- `Tests/ScreenRecorderStateTests.swift`, an engine-level XCTest with no TCC. It imports `ScreenCaptureKit` (L2), which this test needs because `WriterSink` conforms to `SCStreamOutput`.
- The ErrorCollector lock pattern for counting callback fires from writerQueue (`RecordingCoordinatorScreenCaptureTests.swift` L277-286):
```swift
private final class ErrorCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _messages: [String] = []

    func append(_ message: String) {
        lock.withLock { _messages.append(message) }
    }

    var messages: [String] { lock.withLock { _messages } }
}
```
Construct `WriterSink(writer:videoInput:queue:onFirstFrameHostTime:onStreamStopped:onFinalized:)` directly with a real writer in a temp dir (writer setup as above), and call `sink.finalize(reason: .stopped)` twice. Wait on an `XCTestExpectation` (count 1, `assertForOverFulfill = true`). Cases:
- `.stopped` → once
- `.streamError` → once
- double finalize → still once
- writer never `startWriting()` → fires on the not-writing early return

---

### `Tests/DiskSpaceTierTests.swift` (NEW, pure)

**Analog:** `Tests/ScreenRecorderConfigTests.swift`, pure static-function tests with exact numeric assertions (L13-23):
```swift
final class ScreenRecorderConfigTests: XCTestCase {

    // MARK: - QualityPreset values (VID-06)

    func testPresetFPS() {
        XCTAssertEqual(ScreenRecorder.QualityPreset.compact.fps, 10)
        ...
    }

    func testPresetBitrate() {
        XCTAssertEqual(ScreenRecorder.QualityPreset.compact.bitrate, 1_500_000)
```
Pin these exact values (Pitfall 7):
- `videoDiskThreshold(for: .compact) == 1_874_288_000`
- `.balanced == 2_774_288_000`
- `.high == 4_124_288_000`

Tier boundaries at exactly `>=`: `minimumDiskSpaceBytes - 1` → `.belowAudioFloor`, the threshold minus 1 → `.belowVideoThreshold`, the threshold itself → `.sufficient`. A nil preset at 600 MB → `.sufficient`. No `@MainActor` is needed; the functions are pure statics.

---

### `Tests/RecordingCoordinatorVideoStorageTests.swift` (NEW)

**Analog:** `Tests/RecordingCoordinatorScreenCaptureTests.swift` (start/link half) + `Tests/RecordingCoordinatorScreenCaptureTeardownTests.swift` (late finalize / meeting #2).

**Class header + fixtures** (ScreenCaptureTests L13-27):
```swift
@MainActor
final class RecordingCoordinatorScreenCaptureTests: XCTestCase {
    var db: AppDatabase!
    var pipeline: TranscriptionPipeline!
    var factory: MockScreenRecorderFactory!

    override func setUpWithError() throws {
        db = try AppDatabase(inMemory: true)
        pipeline = TranscriptionPipeline(asr: MockASREngine(), diarization: MockDiarizationEngine())
        factory = MockScreenRecorderFactory()
    }
```
**Coordinator builder** (L31-52): extend with `videoInspector: inspector` and `availableDiskSpace: { capacity }` params. Keep a `makeCoordinatorWithoutVideo()` variant for SC4 / D-03.

**Helpers to copy:**
- `recordingMeetingId(_:)` (L59-63)
- `settle()` (L66-68): `try? await Task.sleep(for: .milliseconds(150))`. This is the existing test idiom, not production code.
- `startMeeting(_:title:)` (Teardown L57-64)

**DB assertion pattern** (L174-177):
```swift
        let meeting = try await db.dbWriter.read { dbConn in
            try Meeting.filter(Column("meeting_id") == meetingId).fetchOne(dbConn)
        }
```
→ assert `meeting?.videoFile == "\(meetingId).mov"` and that `videoStartOffset` is non-nil.

**Video-error collector** (L161-166, L179-181): `await coordinator.setOnVideoError { collector.append($0) }`, then assert count == 1 and that the message contains "disk". A private `ErrorCollector` must be redeclared per file (each existing file has its own private copy: `ErrorCollector`, `TeardownErrorCollector`). Use a distinct name such as `StorageErrorCollector`.

**Meeting #2 / late-finalize template:** Teardown L150-179 (`testSecondMeetingStartsVideoAgain`). It drives `.manualStop` → `.transcriptionComplete(meetingId:)` → a second start. **Slow-stop template:** L235-263 (`factory.stopDelay = .seconds(30)`, a `ContinuousClock` bound).

**Important (D-15):** these suites use a real `AudioRecorder` (L34) that writes WAVs to the real audio dir. That is pre-existing behavior. New tests must not add real `.mov` files there (the mock engine writes nothing, and the mock inspector reads nothing) and must never call the sweep against `audioDirectory`.

---

### `Tests/Mocks/MockScreenRecorder.swift` (extend)

**Analog:** same file.

**Lock-guarded knob pattern** (L23-46):
```swift
    private let lock = NSLock()
    ...
    private var _stopDelay: Duration?
    ...
    var stopDelay: Duration? {
        get { lock.withLock { _stopDelay } }
        set { lock.withLock { _stopDelay = newValue } }
    }
```
**Callback storage** (L50-51): add `var onFinalized: (@Sendable () -> Void)?` next to the other two.

**Fire point** (L68-73):
```swift
    func stop() async {
        if let delay = stopDelay {
            try? await Task.sleep(for: delay)
        }
        lock.withLock { _stopCallCount += 1 }
    }
```
→ by default fire `onFinalized?()` at the end of `stop()`, honoring the new `finalizeDelay` (late) and `neverFinalize` (wedge/quit) knobs. Add a `simulateFinalize()` hook beside `simulateStreamDeath` (L76-78). To mirror the engine's once-only guard, keep a lock-guarded `_didFinalize` so stop-after-simulateFinalize does not fire twice (D-06 test).

**Factory propagation** (L83-121): every new knob gets a factory-level mirror and is copied in `makeRecorder()` L114-121, exactly as `startError`/`stopDelay` are:
```swift
    private func makeRecorder() -> ScreenRecording {
        let recorder = MockScreenRecorder()
        let (error, delay): (Error?, Duration?) = lock.withLock { (_startError, _stopDelay) }
        recorder.startError = error
        recorder.stopDelay = delay
        lock.withLock { _instances.append(recorder) }
        return recorder
    }
```

---

### `Tests/Mocks/MockVideoInspector.swift` (NEW)

**Analog:** `Tests/Mocks/MockScreenRecorder.swift` L1-46. Same header (`import Foundation`, `@testable import Caddie`), the same doc-comment rationale for locking, and `final class …: VideoFileInspecting, @unchecked Sendable` with a private `NSLock`. Expose these, each lock-guarded:
- `scriptedResult: VideoInspectionResult` (default `.inspected(usable)`)
- `inspectedURLs: [URL]`
- `inspectCallCount: Int`

Do NOT copy `MockASREngine`'s unguarded `private(set) var` counters (MockASREngine.swift L12-13). The coordinator calls the inspector from its actor while the test reads from the main actor, which is the same hazard MockScreenRecorder L16-20 documents.

---

## Shared Patterns

### Non-fatal video channel (D-01 low-disk message, D-07 discard log)
**Source:** `Sources/Coordinator/RecordingCoordinator.swift` L45-52 (doc), L158-160 (setter), L618-621 (`surfaceVideoError`); AppState L222-226 + L286-289.
**Apply to:** the low-disk skip in `executeStartRecording`. Do NOT route a D-07 discard through it unless the planner decides the user should see it; the funnel logs it with context either way.
**Copy rule:** never `handle(.recordingFailed)` for any video-leg condition. Never touch `state`. The message reads well after the menu-bar prefix "Screen recording stopped — audio was saved:" (RESEARCH Open Q6).

### "Inert by absence" gate (D-03, SC4)
**Source:** `RecordingCoordinator.startVideo` L437-438 (`guard screenRecorderFactory != nil else { return }`); AppState L162-166.
**Apply to:** the disk tier (`videoPreset = screenRecorderFactory != nil ? Self.videoPreset : nil`), the funnel, and any inspector call. No factory means zero video work and no warning.

### Targeted SQL UPDATE by meeting_id
**Source:** `RecordingCoordinator.swift` L635-644 (also L675-683, L700-709, L724-733).
**Apply to:** every write of `video_file` / `video_start_offset`. Use do/catch with `logger.error` that includes context. Never full-record `update()`.

### Error handling: explicit, typed, logged
**Source:** `AudioFileManager.cleanupOrphanedTempFiles` L291-306 (enumerate-or-return, per-item do/catch), `fetchMeetingTitle` L739-749 (do/catch with logged fallback).
**Apply to:** `deleteMedia`, `cleanupOrphanedVideos`, the inspector, and funnel handlers.
- No bare `try?` outside the existing `Task.sleep` idiom (L601, L606).
- An expected-missing file uses a typed `CocoaError.fileNoSuchFile` catch → `debug`, not `warning`.

### Callback assigned BEFORE start (engine contract)
**Source:** `ScreenRecording.swift` L11-14 doc; `RecordingCoordinator.startVideoInner` L450-452 comment; `ScreenRecorder.start` L146-152 capture.
**Apply to:** `onFinalized` in the protocol doc, the engine, the coordinator wiring, and the mock.

### Logging categories
**Source:** `Sources/Utilities/Logger.swift` L7-13.
**Apply to:** `CaddieLogger.storage` for AudioFileManager and the inspector. The coordinator keeps its local `Logger(... category: "RecordingCoordinator")` (L116), and the engine keeps `category: "ScreenRecorder"` (L28, L433).

### Lock-guarded test doubles
**Source:** `Tests/Mocks/MockScreenRecorder.swift` L16-46; `ErrorCollector` (ScreenCaptureTests L277-286).
**Apply to:** MockVideoInspector, the new MockScreenRecorder knobs, and any callback counter in WriterSinkFinalizeTests.

### Temp-dir isolation (D-15)
**Source:** `Tests/MonoMixdownTests.swift` L7-18.
**Apply to:** MediaFileTests, VideoFileInspectorTests, WriterSinkFinalizeTests. Every file operation goes through an injected `directory`/URL under `FileManager.default.temporaryDirectory/<UUID>`.

## No Analog Found

| File / Element | Role | Data Flow | Reason |
|------|------|-----------|--------|
| `AsyncStream.makeStream` per-meeting funnel (inside RecordingCoordinator) | actor-internal event queue | event-driven | No AsyncStream usage exists in `Sources/`. Use the RESEARCH §Coordinator funnel code (compile-verified, Swift 6 strict, target 14.2). The nearest in-repo idiom is the actor-isolated unstructured `Task` at L439-441 |
| Synthetic `.mov` fixture frames (CVPixelBufferPool / pixel-buffer adaptor) in VideoFileInspectorTests / WriterSinkFinalizeTests | test helper | file-I/O | The repo appends only SCK-delivered `CMSampleBuffer`s. Writer setup is copyable (ScreenRecorder L116-141); frame synthesis comes from the RESEARCH Wave 0 notes |
| GRDB `db.alter(table:)` / `migrate(_:upTo:)` | migration / test | CRUD | First migration since v1, so there is no prior `alter` or upgrade test. Use the RESEARCH §Migration / §Upgrade-path snippets (verified against the GRDB 7.10 checkout) |

## Metadata

**Analog search scope:** `Sources/Storage`, `Sources/Coordinator`, `Sources/Recording`, `Sources/App`, `Sources/UI/MainWindow`, `Sources/UI/Settings`, `Sources/Utilities`, `Sources/Transcription` (protocol + pipeline write style), `Tests/`, `Tests/Mocks/`, `README.md`, `.planning/REQUIREMENTS.md`, `.planning/ROADMAP.md`
**Files scanned:** 27 read (14 source, 10 test/mock, 3 docs); grep sweeps across `Sources/` and `Tests/`
**Pattern extraction date:** 2026-11-19

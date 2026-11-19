import XCTest
import GRDB
@testable import Caddie

/// Verifies the coordinator persists each meeting's video link and timing anchor, and
/// verifies the file once the engine has finalized it (STOR-01, STOR-04 storage leg):
/// link on the first frame (D-05, D-08), keep a usable file, delete and unlink an
/// unusable one (D-07), never act before the finalize signal (D-13), and leave
/// audio-only meetings untouched (D-11).
///
/// Every recorder is a `MockScreenRecorder` and every file lives in a per-test temp
/// `videoDir` injected as the coordinator's video directory, so no test can read or
/// delete the user's real media (D-15). Audio is a real `AudioRecorder`, the same
/// pre-existing hardware dependency every other coordinator suite carries.
@MainActor
final class RecordingCoordinatorVideoStorageTests: XCTestCase {
    var db: AppDatabase!
    var pipeline: TranscriptionPipeline!
    var factory: MockScreenRecorderFactory!
    var inspector: MockVideoInspector!
    var videoDir: URL!

    override func setUpWithError() throws {
        db = try AppDatabase(inMemory: true)
        pipeline = TranscriptionPipeline(asr: MockASREngine(), diarization: MockDiarizationEngine())
        factory = MockScreenRecorderFactory()
        inspector = MockVideoInspector()
        videoDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: videoDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let videoDir, FileManager.default.fileExists(atPath: videoDir.path) {
            try FileManager.default.removeItem(at: videoDir)
        }
        db = nil; pipeline = nil; factory = nil; inspector = nil; videoDir = nil
    }

    // MARK: - Helpers

    private func makeCoordinator(withVideo: Bool = true,
                                 inspector: (any VideoFileInspecting)? = nil) -> RecordingCoordinator {
        RecordingCoordinator(
            database: db,
            recorder: AudioRecorder(),
            pipeline: pipeline,
            detector: MeetingDetector(),
            audioDeviceManager: nil,
            liveTranscriber: nil,
            screenRecorderFactory: withVideo ? factory.factory : nil,
            availableDiskSpace: { Int64.max },
            videoInspector: inspector ?? self.inspector,
            videoDirectory: videoDir
        )
    }

    /// The in-flight meeting id, or nil when the coordinator is not recording.
    private func recordingMeetingId(_ coordinator: RecordingCoordinator) async -> String? {
        let state = await coordinator.state
        guard case .recording(let meetingId) = state else { return nil }
        return meetingId
    }

    /// Lets the unstructured video-start Task (and any callback hop) land.
    private func settle(_ duration: Duration = .milliseconds(150)) async {
        try? await Task.sleep(for: duration)
    }

    /// Start a meeting and wait for its video capture to be running.
    @discardableResult
    private func startMeeting(_ coordinator: RecordingCoordinator,
                              title: String) async -> String? {
        await coordinator.handle(.manualStart(title: title))
        await settle()
        return await recordingMeetingId(coordinator)
    }

    private func fetchMeeting(_ id: String) async throws -> Meeting? {
        try await db.dbWriter.read { dbConn in
            try Meeting.filter(Column("meeting_id") == id).fetchOne(dbConn)
        }
    }

    /// Polls `condition` every 25 ms until it holds or `timeout` passes, so assertions on
    /// the asynchronous finalize path wait for the state instead of guessing a sleep.
    private func waitUntil(timeout: Duration = .seconds(3),
                           _ condition: () async throws -> Bool) async rethrows -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if try await condition() { return true }
            await settle(.milliseconds(25))
        }
        return try await condition()
    }

    private func isLinked(_ id: String) async throws -> Bool {
        try await fetchMeeting(id)?.videoFile == "\(id).mov"
    }

    private func isUnlinked(_ id: String) async throws -> Bool {
        let meeting = try await fetchMeeting(id)
        return meeting?.videoFile == nil && meeting?.videoStartOffset == nil
    }

    private func videoURL(_ id: String) -> URL {
        AudioFileManager.videoPath(for: id, in: videoDir)
    }

    private func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - D-08: offset math

    /// The anchor is the first frame minus the audio start, in seconds, on any timebase.
    func testVideoStartOffsetIsFirstFrameMinusAudioStart() {
        let unit = mach_timebase_info_data_t(numer: 1, denom: 1)
        XCTAssertEqual(
            RecordingCoordinator.videoStartOffset(audioStartTicks: 1_000_000_000,
                                                  firstFrameTicks: 1_270_000_000,
                                                  timebase: unit),
            0.27, accuracy: 1e-9)

        let appleSilicon = mach_timebase_info_data_t(numer: 125, denom: 3)
        XCTAssertEqual(
            RecordingCoordinator.videoStartOffset(audioStartTicks: 0,
                                                  firstFrameTicks: 24_000_000,
                                                  timebase: appleSilicon),
            1.0, accuracy: 1e-9)
    }

    // MARK: - D-05: link early, verify after finalize

    /// The first frame links the row with its offset while the meeting is still recording.
    func testFirstFrameLinksVideoFileAndOffset() async throws {
        let coordinator = makeCoordinator()
        guard let id = await startMeeting(coordinator, title: "Link") else {
            XCTFail("Expected the meeting to be recording")
            return
        }

        let linked = try await waitUntil { try await self.isLinked(id) }
        XCTAssertTrue(linked, "The first frame must link video_file = <id>.mov")

        let meeting = try await fetchMeeting(id)
        XCTAssertEqual(meeting?.status, .recording, "The link lands before any stop")
        let offset = try XCTUnwrap(meeting?.videoStartOffset, "The anchor offset is written with the link")
        XCTAssertGreaterThanOrEqual(offset, 0, "The first frame cannot precede the audio start")
        XCTAssertEqual(inspector.inspectCallCount, 0, "Nothing is inspected before finalize")

        await coordinator.handle(.manualStop)
    }

    /// A usable finalized video is inspected once at the injected path and stays linked.
    func testUsableFinalizedVideoStaysLinked() async throws {
        factory.createsFileOnStart = true
        let coordinator = makeCoordinator()
        guard let id = await startMeeting(coordinator, title: "Usable") else {
            XCTFail("Expected the meeting to be recording")
            return
        }
        let linked = try await waitUntil { try await self.isLinked(id) }
        XCTAssertTrue(linked)

        await coordinator.handle(.manualStop)

        let inspected = await waitUntil { self.inspector.inspectCallCount == 1 }
        XCTAssertTrue(inspected, "Finalize must trigger exactly one inspection")
        await settle(.milliseconds(300))

        XCTAssertEqual(inspector.inspectCallCount, 1)
        XCTAssertEqual(inspector.inspectedURLs, [videoURL(id)],
                       "The inspector reads the meeting's file in the injected directory")
        let meeting = try await fetchMeeting(id)
        XCTAssertEqual(meeting?.videoFile, "\(id).mov", "A usable video stays linked")
        XCTAssertNotNil(meeting?.videoStartOffset, "A usable video keeps its anchor")
        XCTAssertTrue(fileExists(videoURL(id)), "A usable video is kept on disk")
    }

    /// D-07: a zero-duration video is deleted and both columns are cleared.
    func testZeroDurationVideoIsDeletedAndUnlinked() async throws {
        factory.createsFileOnStart = true
        inspector.defaultResult = .inspected(
            VideoInspection(isPlayable: true, durationSeconds: 0, videoTrackCount: 1))
        let coordinator = makeCoordinator()
        guard let id = await startMeeting(coordinator, title: "Zero Duration") else {
            XCTFail("Expected the meeting to be recording")
            return
        }
        let linked = try await waitUntil { try await self.isLinked(id) }
        XCTAssertTrue(linked)

        await coordinator.handle(.manualStop)

        let unlinked = try await waitUntil { try await self.isUnlinked(id) }
        XCTAssertTrue(unlinked, "A zero-duration video must leave both columns NULL")
        let deleted = await waitUntil { !self.fileExists(self.videoURL(id)) }
        XCTAssertTrue(deleted, "A zero-duration video must be deleted")
    }

    /// D-07: a file AVFoundation cannot open is deleted and both columns are cleared.
    func testUnreadableVideoIsDeletedAndUnlinked() async throws {
        factory.createsFileOnStart = true
        inspector.defaultResult = .unreadable("AVFoundationErrorDomain -11829: Cannot Open")
        let coordinator = makeCoordinator()
        guard let id = await startMeeting(coordinator, title: "Unreadable") else {
            XCTFail("Expected the meeting to be recording")
            return
        }
        let linked = try await waitUntil { try await self.isLinked(id) }
        XCTAssertTrue(linked)

        await coordinator.handle(.manualStop)

        let unlinked = try await waitUntil { try await self.isUnlinked(id) }
        XCTAssertTrue(unlinked, "An unreadable video must leave both columns NULL")
        let deleted = await waitUntil { !self.fileExists(self.videoURL(id)) }
        XCTAssertTrue(deleted, "An unreadable video must be deleted")
    }

    /// End-to-end D-07 with the production inspector: the 0-byte file a stop before the
    /// first written frame leaves behind is deleted and unlinked.
    func testRealInspectorDeletesZeroByteVideo() async throws {
        factory.createsFileOnStart = true
        let coordinator = makeCoordinator(inspector: AVAssetVideoInspector())
        guard let id = await startMeeting(coordinator, title: "Real Inspector") else {
            XCTFail("Expected the meeting to be recording")
            return
        }
        let linked = try await waitUntil { try await self.isLinked(id) }
        XCTAssertTrue(linked)
        XCTAssertTrue(fileExists(videoURL(id)), "The mock leaves a 0-byte file at the injected path")

        await coordinator.handle(.manualStop)

        let unlinked = try await waitUntil(timeout: .seconds(5)) { try await self.isUnlinked(id) }
        XCTAssertTrue(unlinked, "A 0-byte video must leave both columns NULL")
        let deleted = await waitUntil { !self.fileExists(self.videoURL(id)) }
        XCTAssertTrue(deleted, "A 0-byte video must be deleted")
    }

    /// D-13: `stop()` returning is not a finalize signal. With no finalize, nothing is
    /// inspected or deleted and the link stays.
    func testNothingInspectedBeforeFinalizeSignal() async throws {
        factory.neverFinalize = true
        factory.createsFileOnStart = true
        let coordinator = makeCoordinator()
        guard let id = await startMeeting(coordinator, title: "No Finalize") else {
            XCTFail("Expected the meeting to be recording")
            return
        }
        let linked = try await waitUntil { try await self.isLinked(id) }
        XCTAssertTrue(linked)

        await coordinator.handle(.manualStop)
        await settle(.milliseconds(300))

        XCTAssertEqual(factory.latest?.stopCallCount, 1, "The engine was stopped")
        XCTAssertEqual(inspector.inspectCallCount, 0, "Nothing may inspect before the finalize signal")
        let stillLinked = try await isLinked(id)
        XCTAssertTrue(stillLinked, "Nothing may unlink before the finalize signal")
        XCTAssertTrue(fileExists(videoURL(id)), "Nothing may delete before the finalize signal")
    }

    /// D-05: a failed start (e.g. TCC denied) leaves no link, no inspection, and no file.
    func testStartFailureLeavesNoLinkAndNoFile() async throws {
        factory.startError = MockScreenRecorderError(message: "TCC denied")
        factory.createsFileOnStart = true
        let coordinator = makeCoordinator()
        guard let id = await startMeeting(coordinator, title: "Start Failure") else {
            XCTFail("A video start failure must leave the meeting in .recording")
            return
        }

        let started = await waitUntil { self.factory.latest?.startCallCount == 1 }
        XCTAssertTrue(started, "The failing start must have run (it writes its file first)")
        let removed = await waitUntil { !self.fileExists(self.videoURL(id)) }
        XCTAssertTrue(removed, "A failed start must leave no file behind")

        let unlinked = try await isUnlinked(id)
        XCTAssertTrue(unlinked, "A failed start must leave both columns NULL")
        XCTAssertEqual(inspector.inspectCallCount, 0, "A failed start is never inspected")

        await coordinator.handle(.manualStop)
        await settle(.milliseconds(300))
        let stillUnlinked = try await isUnlinked(id)
        XCTAssertTrue(stillUnlinked)
        XCTAssertEqual(inspector.inspectCallCount, 0, "Teardown after a failed start inspects nothing")
    }

    /// D-11 / SC4: with screen recording off, a meeting gets no video storage at all.
    func testAudioOnlyMeetingHasNoVideoStorage() async throws {
        let collector = StorageErrorCollector()
        let coordinator = makeCoordinator(withVideo: false)
        await coordinator.setOnVideoError { collector.append($0) }
        guard let id = await startMeeting(coordinator, title: "Audio Only") else {
            XCTFail("Expected the meeting to be recording")
            return
        }

        await coordinator.handle(.manualStop)
        await settle(.milliseconds(300))

        let unlinked = try await isUnlinked(id)
        XCTAssertTrue(unlinked, "An audio-only meeting leaves both columns NULL")
        XCTAssertEqual(factory.makeCallCount, 0, "No engine is vended with the feature off")
        XCTAssertEqual(inspector.inspectCallCount, 0, "An audio-only meeting is never inspected")
        XCTAssertTrue(collector.messages.isEmpty,
                      "An audio-only meeting surfaces no video message, got: \(collector.messages)")
        let contents = try FileManager.default.contentsOfDirectory(atPath: videoDir.path)
        XCTAssertTrue(contents.isEmpty, "An audio-only meeting performs no video file operation")
    }

    /// Finalize never gates transcription: the meeting is enqueued before its video is
    /// even final, and the inspection happens once, later.
    func testFinalizeNeverDelaysTranscription() async throws {
        factory.finalizeDelay = .seconds(2)
        let coordinator = makeCoordinator()
        guard let id = await startMeeting(coordinator, title: "Slow Finalize") else {
            XCTFail("Expected the meeting to be recording")
            return
        }
        let linked = try await waitUntil { try await self.isLinked(id) }
        XCTAssertTrue(linked)

        await coordinator.handle(.manualStop)

        let state = await coordinator.state
        guard case .transcribing = state else {
            XCTFail("The meeting must be transcribing as soon as the stop returns, got \(state)")
            return
        }
        XCTAssertEqual(inspector.inspectCallCount, 0,
                       "The meeting must be enqueued before its video finalizes")

        let inspected = await waitUntil(timeout: .seconds(5)) { self.inspector.inspectCallCount == 1 }
        XCTAssertTrue(inspected, "The late finalize must still be inspected")
        await settle(.milliseconds(300))
        XCTAssertEqual(inspector.inspectCallCount, 1, "The late finalize is inspected exactly once")
    }
}

// MARK: - Test Helpers

/// Collects messages surfaced on the coordinator's video-error channel. The callback
/// fires from the coordinator's actor while the test body reads from the main actor,
/// so the buffer is lock-guarded (same rationale as `MockStreamingEngine`).
private final class StorageErrorCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _messages: [String] = []

    func append(_ message: String) {
        lock.withLock { _messages.append(message) }
    }

    var messages: [String] { lock.withLock { _messages } }
}

import XCTest
import GRDB
@testable import Caddie

/// Verifies the two-tier disk guard is wired into `executeStartRecording` (STOR-03 as
/// reinterpreted by D-01): below the 500 MB floor the meeting is blocked exactly as
/// before, and between the floor and the preset-derived video threshold the meeting
/// records audio only, with the reason on the non-fatal video channel.
///
/// Free space comes from an injected provider, so no test depends on the developer's
/// real free space, and video files live in a per-test temp directory, so no test
/// touches the user's real media (D-15). Video is a `MockScreenRecorder` (no TCC grant,
/// no screen capture); audio is a real `AudioRecorder`, the same rig as the
/// screen-capture suites.
@MainActor
final class RecordingCoordinatorDiskGuardTests: XCTestCase {
    var db: AppDatabase!
    var pipeline: TranscriptionPipeline!
    var factory: MockScreenRecorderFactory!
    var videoDir: URL!

    nonisolated private static let fourHundredMiB: Int64 = 419_430_400
    nonisolated private static let sixHundredMiB: Int64 = 629_145_600
    nonisolated private static let oneGB: Int64 = 1_000_000_000

    override func setUpWithError() throws {
        db = try AppDatabase(inMemory: true)
        pipeline = TranscriptionPipeline(asr: MockASREngine(), diarization: MockDiarizationEngine())
        factory = MockScreenRecorderFactory()
        videoDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: videoDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let videoDir, FileManager.default.fileExists(atPath: videoDir.path) {
            try FileManager.default.removeItem(at: videoDir)
        }
        db = nil; pipeline = nil; factory = nil; videoDir = nil
    }

    // MARK: - Helpers

    private func makeCoordinator(
        capacity: @escaping RecordingCoordinator.DiskSpaceProvider,
        withVideo: Bool
    ) -> RecordingCoordinator {
        RecordingCoordinator(
            database: db,
            recorder: AudioRecorder(),
            pipeline: pipeline,
            detector: MeetingDetector(),
            audioDeviceManager: nil,
            liveTranscriber: nil,
            screenRecorderFactory: withVideo ? factory.factory : nil,
            availableDiskSpace: capacity,
            videoInspector: MockVideoInspector(),
            videoDirectory: videoDir
        )
    }

    /// Wires both callbacks into `log` so a test can read state changes, video messages,
    /// and their relative order.
    private func attach(_ log: DiskGuardEventLog, to coordinator: RecordingCoordinator) async {
        await coordinator.setOnStateChange { log.append(.state($0)) }
        await coordinator.setOnVideoError { log.append(.videoError($0)) }
    }

    /// Lets the unstructured video-start Task (and any callback hop) land.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(150))
    }

    private func recordingMeetingId(_ coordinator: RecordingCoordinator) async -> String? {
        let state = await coordinator.state
        guard case .recording(let meetingId) = state else { return nil }
        return meetingId
    }

    private func stateError(_ coordinator: RecordingCoordinator) async -> Error? {
        let state = await coordinator.state
        guard case .error(_, let error) = state else { return nil }
        return error
    }

    private func meetingRowCount() async throws -> Int {
        try await db.dbWriter.read { dbConn in
            try Meeting.fetchCount(dbConn)
        }
    }

    /// Asserts the state carries `CoordinatorError.insufficientDiskSpace` with these sizes.
    private func assertInsufficientDiskSpace(
        _ coordinator: RecordingCoordinator,
        available expectedAvailable: Int64,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        guard let error = await stateError(coordinator) else {
            let state = await coordinator.state
            XCTFail("Expected .error, got \(state)", file: file, line: line)
            return
        }
        guard case .insufficientDiskSpace(let available, let required) = error as? CoordinatorError else {
            XCTFail("Expected insufficientDiskSpace, got \(error)", file: file, line: line)
            return
        }
        XCTAssertEqual(available, expectedAvailable, file: file, line: line)
        XCTAssertEqual(required, RecordingCoordinator.minimumDiskSpaceBytes, file: file, line: line)
    }

    // MARK: - Audio floor blocks (D-01, unchanged guard)

    func testBelowAudioFloorBlocksRecordingWithVideoEnabled() async throws {
        let log = DiskGuardEventLog()
        let coordinator = makeCoordinator(capacity: { Self.fourHundredMiB }, withVideo: true)
        await attach(log, to: coordinator)

        await coordinator.handle(.manualStart(title: "Low Disk"))
        await settle()

        await assertInsufficientDiskSpace(coordinator, available: Self.fourHundredMiB)
        let rows = try await meetingRowCount()
        XCTAssertEqual(rows, 0, "A blocked start must not create a meeting row")
        XCTAssertEqual(factory.makeCallCount, 0, "No capture engine may be vended below the floor")
        XCTAssertTrue(log.videoMessages.isEmpty, "The floor block is fatal, not a video warning: \(log.videoMessages)")
    }

    func testBelowAudioFloorBlocksRecordingWithVideoDisabled() async throws {
        let coordinator = makeCoordinator(capacity: { Self.fourHundredMiB }, withVideo: false)

        await coordinator.handle(.manualStart(title: "Low Disk"))
        await settle()

        await assertInsufficientDiskSpace(coordinator, available: Self.fourHundredMiB)
        let rows = try await meetingRowCount()
        XCTAssertEqual(rows, 0, "Today's 500 MB guard must still block without screen recording")
    }

    func testCapacityReadFailureBlocksRecording() async throws {
        let coordinator = makeCoordinator(capacity: { throw DiskReadError() }, withVideo: true)

        await coordinator.handle(.manualStart(title: "Read Failure"))
        await settle()

        guard let error = await stateError(coordinator) else {
            let state = await coordinator.state
            XCTFail("A failed capacity read must block, got \(state)")
            return
        }
        XCTAssertTrue(error is DiskReadError, "The thrown read error must propagate, got \(error)")
        let rows = try await meetingRowCount()
        XCTAssertEqual(rows, 0)
        XCTAssertEqual(factory.makeCallCount, 0)
    }

    func testNilCapacityBlocksRecording() async throws {
        let coordinator = makeCoordinator(capacity: { nil }, withVideo: true)

        await coordinator.handle(.manualStart(title: "Unknown Capacity"))
        await settle()

        await assertInsufficientDiskSpace(coordinator, available: 0)
        let rows = try await meetingRowCount()
        XCTAssertEqual(rows, 0, "An unknown capacity must never read as plenty of space")
    }

    // MARK: - Video threshold (D-01, D-02)

    func testBetweenFloorAndVideoThresholdRecordsAudioOnly() async throws {
        let log = DiskGuardEventLog()
        let coordinator = makeCoordinator(capacity: { Self.oneGB }, withVideo: true)
        await attach(log, to: coordinator)

        await coordinator.handle(.manualStart(title: "Audio Only"))
        await settle()

        guard let meetingId = await recordingMeetingId(coordinator) else {
            let state = await coordinator.state
            XCTFail("Video headroom must never block audio, got \(state)")
            return
        }
        let meeting = try await db.dbWriter.read { dbConn in
            try Meeting.filter(Column("meeting_id") == meetingId).fetchOne(dbConn)
        }
        XCTAssertEqual(meeting?.status, .recording, "The audio recording must carry on")
        XCTAssertEqual(factory.makeCallCount, 0, "Video must never start below the threshold")
        let active = await coordinator.isVideoActive
        XCTAssertFalse(active)
        XCTAssertEqual(log.videoMessages.count, 1, "The skip must be surfaced exactly once: \(log.videoMessages)")
        XCTAssertTrue(log.videoMessages.first?.contains("disk space") == true,
                      "The message must name the reason, got: \(log.videoMessages)")
    }

    func testAtVideoThresholdStartsVideo() async {
        let threshold = RecordingCoordinator.videoDiskThreshold(for: .default)
        let log = DiskGuardEventLog()
        let coordinator = makeCoordinator(capacity: { threshold }, withVideo: true)
        await attach(log, to: coordinator)

        await coordinator.handle(.manualStart(title: "At Threshold"))
        await settle()

        XCTAssertEqual(factory.makeCallCount, 1, "Exactly the threshold is enough for video")
        XCTAssertTrue(log.videoMessages.isEmpty, "No warning at the threshold: \(log.videoMessages)")
    }

    func testVideoDisabledAboveFloorRecordsWithNoWarning() async {
        let log = DiskGuardEventLog()
        let coordinator = makeCoordinator(capacity: { Self.sixHundredMiB }, withVideo: false)
        await attach(log, to: coordinator)

        await coordinator.handle(.manualStart(title: "Feature Off"))
        await settle()

        let meetingId = await recordingMeetingId(coordinator)
        XCTAssertNotNil(meetingId, "Screen recording off: only the 500 MB floor applies (D-03)")
        XCTAssertTrue(log.videoMessages.isEmpty, "Audio-only users must see no video warning: \(log.videoMessages)")
    }

    // MARK: - Delivery order and single read

    /// AppState clears `lastVideoError` on `.recording`, so the disk message must arrive
    /// after that state change or the user never sees it (Pitfall 3).
    func testLowDiskMessageArrivesAfterRecordingState() async {
        let log = DiskGuardEventLog()
        let coordinator = makeCoordinator(capacity: { Self.oneGB }, withVideo: true)
        await attach(log, to: coordinator)

        await coordinator.handle(.manualStart(title: "Ordering"))
        await settle()

        let events = log.events
        let recordingIndex = events.firstIndex { event in
            if case .state(.recording) = event { return true }
            return false
        }
        let messageIndex = events.firstIndex { event in
            if case .videoError(let message) = event { return message.contains("disk space") }
            return false
        }
        guard let recordingIndex, let messageIndex else {
            XCTFail("Expected both a .recording state and a disk message, got \(events)")
            return
        }
        XCTAssertLessThan(recordingIndex, messageIndex, "The disk message must follow .recording: \(events)")
    }

    /// One snapshot decides both tiers: a blocked attempt and an audio-only attempt
    /// each read capacity exactly once.
    func testCapacityIsReadOncePerStart() async {
        let log = DiskGuardEventLog(capacities: [Self.fourHundredMiB, Self.oneGB])
        let coordinator = makeCoordinator(capacity: { try log.nextCapacity() }, withVideo: true)

        await coordinator.handle(.manualStart(title: "Blocked Attempt"))
        await settle()
        XCTAssertEqual(log.providerCalls, 1, "A blocked start must read capacity once")

        await coordinator.handle(.manualStart(title: "Audio Only Attempt"))
        await settle()
        XCTAssertEqual(log.providerCalls, 2, "An audio-only start must read capacity once")
        let meetingId = await recordingMeetingId(coordinator)
        XCTAssertNotNil(meetingId, "The second attempt must record")
    }
}

// MARK: - Test Helpers

private struct DiskReadError: Error {}

/// Records state changes and video messages in arrival order, and counts capacity reads.
/// The callbacks fire on the coordinator's actor while the test body reads on the main
/// actor, so all state is lock-guarded.
private final class DiskGuardEventLog: @unchecked Sendable {
    enum Event {
        case state(RecordingState)
        case videoError(String)
    }

    private let lock = NSLock()
    private var _events: [Event] = []
    private var _providerCalls = 0
    private var _capacities: [Int64]

    init(capacities: [Int64] = []) {
        _capacities = capacities
    }

    func append(_ event: Event) {
        lock.withLock { _events.append(event) }
    }

    var events: [Event] { lock.withLock { _events } }

    var videoMessages: [String] {
        events.compactMap { event in
            if case .videoError(let message) = event { return message }
            return nil
        }
    }

    var providerCalls: Int { lock.withLock { _providerCalls } }

    /// Returns the next scripted capacity and counts the read. Throws once the script
    /// runs out, so an unexpected extra read fails the test instead of passing silently.
    func nextCapacity() throws -> Int64? {
        try lock.withLock {
            _providerCalls += 1
            guard !_capacities.isEmpty else { throw DiskReadError() }
            return _capacities.removeFirst()
        }
    }
}

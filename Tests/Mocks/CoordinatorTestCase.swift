import XCTest
import GRDB
@testable import Caddie

/// Shared fixture for the coordinator suites that exercise screen capture: an in-memory
/// database, a mock-engine pipeline, a `MockScreenRecorderFactory`, a `MockVideoInspector`,
/// and a per-test temp `videoDir` injected as the coordinator's video directory.
///
/// Every recorder is a `MockScreenRecorder`, so no suite needs a TCC grant or captures the
/// developer's screen, and every video file lives in `videoDir`, so no suite reads or
/// deletes the user's real media (D-15). Audio is a real `AudioRecorder`, the same
/// pre-existing hardware dependency every coordinator suite carries.
@MainActor
class CoordinatorTestCase: XCTestCase {
    var db: AppDatabase!
    var pipeline: TranscriptionPipeline!
    var factory: MockScreenRecorderFactory!
    var inspector: MockVideoInspector!
    var videoDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
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
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// A coordinator wired to this fixture. `withVideo: false` leaves the factory out, which
    /// makes every video code path inert. `inspector` overrides the fixture's mock.
    func makeCoordinator(capacity: @escaping RecordingCoordinator.DiskSpaceProvider = { Int64.max },
                         withVideo: Bool = true,
                         inspector: (any VideoFileInspecting)? = nil) -> RecordingCoordinator {
        RecordingCoordinator(
            database: db,
            recorder: AudioRecorder(),
            pipeline: pipeline,
            detector: MeetingDetector(),
            audioDeviceManager: nil,
            liveTranscriber: nil,
            screenRecorderFactory: withVideo ? factory.factory : nil,
            availableDiskSpace: capacity,
            videoInspector: inspector ?? self.inspector,
            videoDirectory: videoDir
        )
    }

    /// Lets the unstructured video-start Task (and any callback hop) land.
    func settle(_ duration: Duration = .milliseconds(150)) async {
        try? await Task.sleep(for: duration)
    }

    /// The in-flight meeting id, or nil when the coordinator is not recording.
    func recordingMeetingId(_ coordinator: RecordingCoordinator) async -> String? {
        let state = await coordinator.state
        guard case .recording(let meetingId) = state else { return nil }
        return meetingId
    }

    /// Start a meeting and wait for its video capture to be running.
    @discardableResult
    func startMeeting(_ coordinator: RecordingCoordinator, title: String) async -> String? {
        await coordinator.handle(.manualStart(title: title))
        await settle()
        return await recordingMeetingId(coordinator)
    }

    func fetchMeeting(_ id: String) async throws -> Meeting? {
        try await db.dbWriter.read { dbConn in
            try Meeting.filter(Column("meeting_id") == id).fetchOne(dbConn)
        }
    }

    /// Polls `condition` every 25 ms until it holds or `timeout` passes, so assertions on
    /// asynchronous paths wait for the state instead of guessing a sleep.
    func waitUntil(timeout: Duration = .seconds(3),
                   _ condition: () async throws -> Bool) async rethrows -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if try await condition() { return true }
            await settle(.milliseconds(25))
        }
        return try await condition()
    }
}

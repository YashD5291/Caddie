import XCTest
import GRDB
@testable import Caddie

/// Verifies RecordingCoordinator wires screen capture into the recording lifecycle:
/// a fresh engine per meeting, started only AFTER audio, writing to the meeting's
/// canonical `.mov`, with the STOR-04 anchor pair held in memory (VID-03 start half).
///
/// Every recorder is a `MockScreenRecorder` vended by `MockScreenRecorderFactory`, so
/// these tests need no TCC grant and never capture the developer's screen. Audio is a
/// real `AudioRecorder` — the same pre-existing hardware dependency every other
/// coordinator test suite carries.
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

    override func tearDownWithError() throws {
        db = nil; pipeline = nil; factory = nil
    }

    // MARK: - Helpers

    private func makeCoordinator() -> RecordingCoordinator {
        RecordingCoordinator(
            database: db,
            recorder: AudioRecorder(),
            pipeline: pipeline,
            detector: MeetingDetector(),
            audioDeviceManager: nil,
            liveTranscriber: nil,
            screenRecorderFactory: factory.factory
        )
    }

    private func makeCoordinatorWithoutVideo() -> RecordingCoordinator {
        RecordingCoordinator(
            database: db,
            recorder: AudioRecorder(),
            pipeline: pipeline,
            detector: MeetingDetector(),
            audioDeviceManager: nil,
            liveTranscriber: nil
        )
    }

    private func makeMeeting() -> DetectedMeeting {
        DetectedMeeting(app: "Zoom", title: "Standup", processId: nil)
    }

    /// The in-flight meeting id, or nil when the coordinator is not recording.
    private func recordingMeetingId(_ coordinator: RecordingCoordinator) async -> String? {
        let state = await coordinator.state
        guard case .recording(let meetingId) = state else { return nil }
        return meetingId
    }

    /// Lets the unstructured video-start Task (and any callback hop) land.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(150))
    }

    // MARK: - VID-03: Start Path

    /// A manually started meeting vends exactly one recorder and starts it once.
    func testManualStartStartsVideo() async {
        let coordinator = makeCoordinator()
        await coordinator.handle(.manualStart(title: "Video Test"))
        await settle()

        XCTAssertEqual(factory.makeCallCount, 1, "Exactly one engine must be vended per meeting")
        XCTAssertEqual(factory.totalStartCount, 1, "Video must start exactly once")
    }

    /// The calendar-prompted path (.meetingDetected) converges on the same
    /// .startRecording side effect, so it must start video through the same wiring.
    func testMeetingDetectedStartsVideo() async {
        let coordinator = makeCoordinator()
        await coordinator.handle(.meetingDetected(makeMeeting()))
        await settle()

        XCTAssertEqual(factory.makeCallCount, 1, "Calendar-prompted starts must also vend an engine")
        XCTAssertEqual(factory.totalStartCount, 1, "Video must start exactly once for a detected meeting")
    }

    /// Video is written to the canonical `<meetingId>.mov` beside the audio files.
    func testVideoOutputPathIsMeetingMov() async {
        let coordinator = makeCoordinator()
        await coordinator.handle(.manualStart(title: "Path Test"))
        await settle()

        guard let meetingId = await recordingMeetingId(coordinator) else {
            XCTFail("Expected .recording state")
            return
        }
        let expected = AudioFileManager.videoPath(for: meetingId)
        XCTAssertEqual(factory.latest?.startedURLs.last, expected,
                       "Engine must be started against the meeting's canonical .mov URL")
        XCTAssertEqual(expected.pathExtension, "mov")

        let contextURL = await coordinator.videoOutputURL
        XCTAssertEqual(contextURL, expected, "The in-flight context must hold the same URL")
    }

    /// With no factory injected (feature off), recording behaves exactly as before:
    /// the coordinator reaches .recording and no video code runs.
    func testRecordingWorksWithoutScreenRecorder() async {
        let coordinator = makeCoordinatorWithoutVideo()
        await coordinator.handle(.manualStart(title: "No Video"))
        await settle()

        let state = await coordinator.state
        guard case .recording = state else {
            XCTFail("Expected .recording without a screen recorder, got \(state)")
            return
        }
        XCTAssertEqual(factory.makeCallCount, 0, "No engine may be vended when the feature is off")
        let active = await coordinator.isVideoActive
        XCTAssertFalse(active, "Video must be inactive when no factory is injected")
    }

    /// STOR-04 (in-memory leg): both halves of the anchor pair are held for the
    /// in-flight meeting — the audio-start host tick and the first-frame host tick.
    /// The first-frame half also proves the callbacks were assigned BEFORE start().
    func testAnchorPairCapturedInMemory() async {
        let coordinator = makeCoordinator()
        await coordinator.handle(.manualStart(title: "Anchor Test"))
        await settle()

        guard let pair = await coordinator.videoAnchorPair else {
            XCTFail("Expected an anchor pair for the in-flight meeting")
            return
        }
        XCTAssertGreaterThan(pair.audio, 0, "Audio-start host ticks must be recorded")
        XCTAssertNotNil(pair.firstFrame,
                        "First-frame ticks must arrive — proves onFirstFrameHostTime was set before start()")
    }

    /// While a meeting records with a healthy stream, video reports active.
    func testVideoIsActiveWhileRecording() async {
        let coordinator = makeCoordinator()
        await coordinator.handle(.manualStart(title: "Active Test"))
        await settle()

        let active = await coordinator.isVideoActive
        XCTAssertTrue(active, "Video must be active while the meeting records")
    }
}

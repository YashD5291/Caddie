import XCTest
import GRDB
@testable import Caddie

/// Verifies RecordingCoordinator finalizes screen capture on EVERY teardown path
/// (VID-03 stop half, VID-04 non-blocking guarantee): normal stop, meeting end,
/// device disconnect, error teardown, and app quit — plus the reentrancy window
/// where a stop arrives while the video start task is still in flight, and the
/// Pitfall 1 regression that meeting #2 in the same app session records again.
///
/// Every recorder is a `MockScreenRecorder` vended by `MockScreenRecorderFactory`, so
/// these tests need no TCC grant and never capture the developer's screen. Audio is a
/// real `AudioRecorder` — the same pre-existing hardware dependency every other
/// coordinator test suite carries.
@MainActor
final class RecordingCoordinatorScreenCaptureTeardownTests: XCTestCase {
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

    /// Lets the unstructured video-start Task (and any callback hop) land.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(150))
    }

    /// The in-flight meeting id, or nil when the coordinator is not recording.
    private func recordingMeetingId(_ coordinator: RecordingCoordinator) async -> String? {
        let state = await coordinator.state
        guard case .recording(let meetingId) = state else { return nil }
        return meetingId
    }

    /// Start a meeting and wait for its video capture to be running.
    @discardableResult
    private func startMeeting(_ coordinator: RecordingCoordinator,
                              title: String) async -> String? {
        await coordinator.handle(.manualStart(title: title))
        await settle()
        return await recordingMeetingId(coordinator)
    }

    // MARK: - VID-03: Every teardown path finalizes the video

    /// The normal user-driven stop finalizes the capture exactly once.
    func testManualStopStopsVideo() async {
        let coordinator = makeCoordinator()
        await startMeeting(coordinator, title: "Manual Stop")

        await coordinator.handle(.manualStop)
        await settle()

        XCTAssertEqual(factory.latest?.stopCallCount, 1,
                       "A manual stop must finalize the meeting's video exactly once")
        let active = await coordinator.isVideoActive
        XCTAssertFalse(active, "No capture may remain in flight after teardown")

        let state = await coordinator.state
        guard case .transcribing = state else {
            XCTFail("Stopping must still hand off to transcription, got \(state)")
            return
        }
    }

    /// `.meetingEnded` reduces to the same `.stopAndTranscribe` side effect, so it
    /// must finalize the video identically.
    func testMeetingEndedStopsVideo() async {
        let coordinator = makeCoordinator()
        await startMeeting(coordinator, title: "Meeting Ended")

        await coordinator.handle(.meetingEnded)
        await settle()

        XCTAssertEqual(factory.latest?.stopCallCount, 1,
                       "A meeting that ends on its own must finalize its video")
    }

    /// A disconnected input device tears the meeting down through the same effect —
    /// the video must not be left running because the audio device vanished.
    func testDeviceDisconnectStopsVideo() async {
        let coordinator = makeCoordinator()
        await startMeeting(coordinator, title: "Device Disconnect")

        await coordinator.handle(.deviceDisconnected)
        await settle()

        XCTAssertEqual(factory.latest?.stopCallCount, 1,
                       "Device disconnect must finalize the video too")
    }

    /// The error teardown path (`executeNotifyError`) also owns a running capture.
    func testErrorPathStopsVideo() async {
        let coordinator = makeCoordinator()
        await startMeeting(coordinator, title: "Error Teardown")

        await coordinator.handle(.recordingFailed(MockScreenRecorderError(message: "audio died")))
        await settle()

        XCTAssertEqual(factory.latest?.stopCallCount, 1,
                       "An error teardown must finalize the video, not leak it")
        let active = await coordinator.isVideoActive
        XCTAssertFalse(active, "No capture may survive the error teardown")
    }

    /// Quitting the app mid-recording runs the shutdown helper, which must finalize
    /// the video as well as the audio (Pitfall 6).
    func testShutdownStopFinalizesVideo() async {
        let coordinator = makeCoordinator()
        await startMeeting(coordinator, title: "App Quit")

        await coordinator.stop()
        await settle()

        XCTAssertEqual(factory.latest?.stopCallCount, 1,
                       "App quit during a recording must finalize the video")
    }

    // MARK: - Pitfall 1 regression: meeting #2 records video again

    /// The reason the coordinator takes a FACTORY rather than an instance: a single
    /// `ScreenRecorder` is single-use and its second `start()` is a SILENT no-op, so
    /// one shared engine would record nothing from meeting #2 onward with no error
    /// anywhere. Two meetings in one coordinator must yield two distinct engines,
    /// each started once and each stopped once.
    func testSecondMeetingStartsVideoAgain() async {
        let coordinator = makeCoordinator()

        guard let firstId = await startMeeting(coordinator, title: "Meeting One") else {
            XCTFail("Expected the first meeting to be recording")
            return
        }
        let first = factory.latest
        XCTAssertEqual(factory.makeCallCount, 1)

        await coordinator.handle(.manualStop)
        await settle()
        XCTAssertGreaterThanOrEqual(factory.totalStopCount, 1,
                                    "The first meeting's video must be finalized before the next starts")

        // Return to .idle deterministically (the batch pipeline's own completion is
        // not what this test is about).
        await coordinator.handle(.transcriptionComplete(meetingId: firstId))

        await startMeeting(coordinator, title: "Meeting Two")
        let second = factory.latest

        XCTAssertEqual(factory.makeCallCount, 2, "Meeting #2 must be vended its own engine")
        XCTAssertEqual(factory.totalStartCount, 2, "Meeting #2 must actually start video")
        XCTAssertFalse(first === second, "Meeting #2 must not reuse the single-use engine")

        await coordinator.handle(.manualStop)
        await settle()
        XCTAssertEqual(factory.totalStopCount, 2, "Both meetings' videos must be finalized")
    }

    // MARK: - Pitfall 3: stop racing an in-flight start

    /// `startVideo` schedules the ~215 ms ScreenCaptureKit setup in an unstructured
    /// task so it never stalls the actor — which opens a window where a stop can run
    /// while the start is still in flight. If teardown does not JOIN that task, the
    /// start lands afterwards and leaves a capture running with no owner and no stop
    /// path: a `.mov` still growing after the meeting ended.
    func testStopBeforeStartCompletesStillStopsVideo() async {
        let coordinator = makeCoordinator()

        // No settle() between start and stop: the stop deliberately races the
        // in-flight video-start task.
        await coordinator.handle(.manualStart(title: "Race"))
        await coordinator.handle(.manualStop)
        await settle()

        XCTAssertEqual(factory.makeCallCount, 1, "The racing start must still have vended its engine")
        XCTAssertEqual(factory.latest?.stopCallCount, 1,
                       "A stop racing the start must still finalize the capture exactly once")
        let active = await coordinator.isVideoActive
        XCTAssertFalse(active, "No capture may be orphaned by the start/stop race")
    }

    // MARK: - Pitfall 4: teardown after a stream death

    /// After SCK kills the stream mid-meeting the coordinator's video is inactive, but
    /// the engine still owns a partial (playable, fragmented) file. Teardown must call
    /// `stop()` anyway so that partial is finalized — the engine's own state guard is
    /// what makes the call a safe no-op, not a coordinator-side flag.
    func testStopAfterStreamDeathStillFinalizes() async {
        let coordinator = makeCoordinator()
        await startMeeting(coordinator, title: "Stream Death")

        factory.latest?.simulateStreamDeath(MockScreenRecorderError(message: "-3821"))
        await settle()

        await coordinator.handle(.manualStop)
        await settle()

        XCTAssertEqual(factory.latest?.stopCallCount, 1,
                       "A dead stream must still be stopped so its partial file is finalized")
        let state = await coordinator.state
        guard case .transcribing = state else {
            XCTFail("A meeting that lost video must still transcribe, got \(state)")
            return
        }
    }
}

// MARK: - Test Helpers

/// Collects messages surfaced on the coordinator's video-error channel. The callback
/// fires from the coordinator's actor while the test body reads from the test executor,
/// so the buffer is lock-guarded (same rationale as `MockStreamingEngine`).
private final class TeardownErrorCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _messages: [String] = []

    func append(_ message: String) {
        lock.withLock { _messages.append(message) }
    }

    var messages: [String] { lock.withLock { _messages } }
}

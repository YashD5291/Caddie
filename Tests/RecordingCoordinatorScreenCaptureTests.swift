import XCTest
import GRDB
@testable import Caddie

/// Verifies RecordingCoordinator wires screen capture into the recording lifecycle:
/// a fresh engine per meeting, started only AFTER audio, writing to the meeting's
/// canonical `.mov` (VID-03 start half).
///
/// The fixture (`CoordinatorTestCase`) vends `MockScreenRecorder`s and injects free space,
/// the video inspector, and a temp video directory, so no test needs a TCC grant, depends
/// on the host's free space, or touches the user's real media (D-15).
final class RecordingCoordinatorScreenCaptureTests: CoordinatorTestCase {

    /// The menu bar headline for a capture that failed or stopped once the meeting began.
    private static let stoppedHeadline = "Screen recording stopped \u{2014} audio was saved: "

    // MARK: - Helpers

    private func makeMeeting() -> DetectedMeeting {
        DetectedMeeting(app: "Zoom", title: "Standup", processId: nil)
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
        let expected = AudioFileManager.videoPath(for: meetingId, in: videoDir)
        XCTAssertEqual(factory.latest?.startedURLs.last, expected,
                       "Engine must be started against the meeting's canonical .mov URL")
        XCTAssertEqual(expected.pathExtension, "mov")

        let contextURL = await coordinator.videoOutputURL
        XCTAssertEqual(contextURL, expected, "The in-flight context must hold the same URL")
    }

    /// With no factory injected (feature off), recording behaves exactly as before:
    /// the coordinator reaches .recording and no video code runs.
    func testRecordingWorksWithoutScreenRecorder() async {
        let coordinator = makeCoordinator(withVideo: false)
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

    /// While a meeting records with a healthy stream, video reports active.
    func testVideoIsActiveWhileRecording() async {
        let coordinator = makeCoordinator()
        await coordinator.handle(.manualStart(title: "Active Test"))
        await settle()

        let active = await coordinator.isVideoActive
        XCTAssertTrue(active, "Video must be active while the meeting records")
    }

    // MARK: - VID-04: Failure Containment

    /// A start throw (the shape a denied TCC grant takes) degrades the meeting to
    /// audio-only: still .recording, still recording in the DB, message surfaced once.
    func testVideoStartFailureDegradesToAudioOnly() async throws {
        let collector = VideoErrorCollector()
        factory.startError = MockScreenRecorderError(message: "TCC denied")

        let coordinator = makeCoordinator()
        await coordinator.setOnVideoError { collector.append($0) }
        await coordinator.handle(.manualStart(title: "Degrade Test"))
        await settle()

        guard let meetingId = await recordingMeetingId(coordinator) else {
            XCTFail("A video start failure must leave the meeting in .recording")
            return
        }

        let meeting = try await fetchMeeting(meetingId)
        XCTAssertEqual(meeting?.status, .recording, "The audio recording must carry on untouched")

        XCTAssertEqual(collector.messages.count, 1, "The failure must be surfaced exactly once")
        XCTAssertTrue(collector.messages.first?.contains("TCC denied") == true,
                      "Surfaced copy must carry the underlying error, got: \(collector.messages)")
        XCTAssertTrue(collector.messages.first?.hasPrefix(Self.stoppedHeadline) == true,
                      "The menu bar line keeps its existing headline, got: \(collector.messages)")
        let active = await coordinator.isVideoActive
        XCTAssertFalse(active, "Video must be inactive after a start failure")
    }

    /// Audio-only completion: a meeting whose video never started still stops and
    /// hands off to transcription normally.
    func testVideoStartFailureStillCompletesMeeting() async {
        factory.startError = MockScreenRecorderError(message: "TCC denied")

        let coordinator = makeCoordinator()
        await coordinator.handle(.manualStart(title: "Complete Test"))
        await settle()

        await coordinator.handle(.manualStop)

        let state = await coordinator.state
        guard case .transcribing = state else {
            XCTFail("Expected .transcribing after stopping an audio-only meeting, got \(state)")
            return
        }
    }

    /// A mid-meeting stream death (SCK -3821 / window closed) surfaces a message and
    /// leaves the audio recording running to normal completion.
    func testStreamDeathMidMeetingSurfacesAndKeepsAudio() async {
        let collector = VideoErrorCollector()
        let coordinator = makeCoordinator()
        await coordinator.setOnVideoError { collector.append($0) }
        await coordinator.handle(.manualStart(title: "Death Test"))
        await settle()

        factory.latest?.simulateStreamDeath(MockScreenRecorderError(message: "-3821"))
        await settle()

        XCTAssertEqual(collector.messages.count, 1, "Stream death must be surfaced exactly once")
        XCTAssertTrue(collector.messages.first?.contains("-3821") == true,
                      "Surfaced copy must carry the SCK detail, got: \(collector.messages)")
        XCTAssertTrue(collector.messages.first?.hasPrefix(Self.stoppedHeadline) == true,
                      "The menu bar line keeps its existing headline, got: \(collector.messages)")

        let state = await coordinator.state
        guard case .recording = state else {
            XCTFail("Stream death must not disturb the recording state, got \(state)")
            return
        }

        await coordinator.handle(.manualStop)
        let finalState = await coordinator.state
        guard case .transcribing = finalState else {
            XCTFail("A meeting that lost video must still transcribe, got \(finalState)")
            return
        }
    }

    /// After a stream death the coordinator reports video inactive — the engine's own
    /// `isRecording` keeps returning true, so the coordinator must not trust it.
    func testStreamDeathMarksVideoInactive() async {
        let coordinator = makeCoordinator()
        await coordinator.handle(.manualStart(title: "Inactive Test"))
        await settle()

        let activeBefore = await coordinator.isVideoActive
        XCTAssertTrue(activeBefore, "Video should be active before the stream dies")

        factory.latest?.simulateStreamDeath(MockScreenRecorderError(message: "window closed"))
        await settle()

        let activeAfter = await coordinator.isVideoActive
        XCTAssertFalse(activeAfter, "Video must read inactive once the stream is dead")
    }

    /// The hard VID-04 guarantee: no video failure mode may reach the .error state.
    func testVideoFailureNeverEntersErrorState() async {
        factory.startError = MockScreenRecorderError(message: "boom")
        let coordinator = makeCoordinator()
        await coordinator.handle(.manualStart(title: "No Error Test"))
        await settle()

        factory.latest?.simulateStreamDeath(MockScreenRecorderError(message: "also boom"))
        await settle()

        let state = await coordinator.state
        if case .error = state {
            XCTFail("A video failure must never drive the coordinator into .error")
        }
        guard case .recording = state else {
            XCTFail("Expected the meeting to still be recording, got \(state)")
            return
        }
    }
}

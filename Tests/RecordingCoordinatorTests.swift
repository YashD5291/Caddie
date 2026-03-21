import XCTest
import GRDB
@testable import Caddie

@MainActor
final class RecordingCoordinatorTests: XCTestCase {
    var db: AppDatabase!
    var mockASR: MockASREngine!
    var mockDiarization: MockDiarizationEngine!
    var pipeline: TranscriptionPipeline!

    override func setUpWithError() throws {
        db = try AppDatabase(inMemory: true)
        mockASR = MockASREngine()
        mockDiarization = MockDiarizationEngine()
        pipeline = TranscriptionPipeline(asr: mockASR, diarization: mockDiarization)
    }

    override func tearDownWithError() throws {
        db = nil
        mockASR = nil
        mockDiarization = nil
        pipeline = nil
    }

    // MARK: - Helpers

    private func makeCoordinator() -> RecordingCoordinator {
        RecordingCoordinator(
            database: db,
            recorder: AudioRecorder(),
            pipeline: pipeline,
            detector: MeetingDetector()
        )
    }

    private func makeMeeting() -> DetectedMeeting {
        DetectedMeeting(app: "Zoom", title: "Standup", processId: nil)
    }

    // MARK: - State Transitions

    func testInitialStateIsIdle() async {
        let coordinator = makeCoordinator()
        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
    }

    func testMeetingDetectedTransitionsToRecording() async {
        let coordinator = makeCoordinator()
        await coordinator.handle(.meetingDetected(makeMeeting()))

        let state = await coordinator.state
        guard case .recording = state else {
            XCTFail("Expected .recording state, got \(state)")
            return
        }
    }

    func testMeetingDetectedCreatesDatabaseRecord() async throws {
        let coordinator = makeCoordinator()
        await coordinator.handle(.meetingDetected(makeMeeting()))

        let state = await coordinator.state
        guard case .recording(let meetingId) = state else {
            XCTFail("Expected .recording state")
            return
        }

        let meeting = try await db.dbWriter.read { dbConn in
            try Meeting.filter(Column("meeting_id") == meetingId).fetchOne(dbConn)
        }
        XCTAssertNotNil(meeting)
        XCTAssertEqual(meeting?.title, "Standup")
        XCTAssertEqual(meeting?.app, "Zoom")
        XCTAssertEqual(meeting?.status, .recording)
    }

    func testMeetingDetectedWhileRecordingIsIgnored() async {
        let coordinator = makeCoordinator()
        await coordinator.handle(.meetingDetected(makeMeeting()))

        let state1 = await coordinator.state
        guard case .recording(let firstMeetingId) = state1 else {
            XCTFail("Expected .recording state")
            return
        }

        // Second meeting detected while recording -- should be ignored
        await coordinator.handle(.meetingDetected(makeMeeting()))

        let state2 = await coordinator.state
        guard case .recording(let secondMeetingId) = state2 else {
            XCTFail("Expected .recording state")
            return
        }
        XCTAssertEqual(firstMeetingId, secondMeetingId, "Should not start a new recording")
    }

    func testMeetingEndedWhileIdleIsIgnored() async {
        let coordinator = makeCoordinator()
        await coordinator.handle(.meetingEnded)

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
    }

    // MARK: - State Change Callback

    func testOnStateChangeCalledOnTransition() async {
        let coordinator = makeCoordinator()
        let expectation = XCTestExpectation(description: "onStateChange called")

        let stateBox = StateBox()
        await coordinator.setOnStateChange { state in
            stateBox.state = state
            expectation.fulfill()
        }

        await coordinator.handle(.meetingDetected(makeMeeting()))
        await fulfillment(of: [expectation], timeout: 2.0)

        guard case .recording = stateBox.state else {
            XCTFail("Expected .recording state in callback, got \(String(describing: stateBox.state))")
            return
        }
    }

    // MARK: - Convenience Methods

    func testRetryTranscriptionForwardsEvent() async {
        let coordinator = makeCoordinator()

        // Get to error state: idle -> recording -> error
        await coordinator.handle(.meetingDetected(makeMeeting()))
        let state1 = await coordinator.state
        guard case .recording(let meetingId) = state1 else {
            XCTFail("Expected .recording state")
            return
        }

        await coordinator.handle(.recordingFailed(CoordinatorTestError.sample))

        let errorState = await coordinator.state
        guard case .error = errorState else {
            XCTFail("Expected .error state, got \(errorState)")
            return
        }

        // Retry should transition to transcribing
        await coordinator.retryTranscription(meetingId: meetingId)

        let state2 = await coordinator.state
        guard case .transcribing = state2 else {
            XCTFail("Expected .transcribing state, got \(state2)")
            return
        }
    }

    func testStopRecordingForwardsEvent() async throws {
        let coordinator = makeCoordinator()
        await coordinator.handle(.meetingDetected(makeMeeting()))

        let state1 = await coordinator.state
        guard case .recording = state1 else {
            XCTFail("Expected .recording state")
            return
        }

        await coordinator.stopRecording()

        let state2 = await coordinator.state
        guard case .transcribing = state2 else {
            XCTFail("Expected .transcribing state, got \(state2)")
            return
        }
    }
}

// MARK: - Test Helpers

private final class StateBox: @unchecked Sendable {
    var state: RecordingState?
}

private enum CoordinatorTestError: Error, LocalizedError {
    case sample

    var errorDescription: String? { "Test coordinator error" }
}

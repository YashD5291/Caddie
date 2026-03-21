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

    // MARK: - Pipeline Completion Callback Transitions

    func testTranscriptionCompleteTransitionsToIdle() async {
        let coordinator = makeCoordinator()

        // Drive to .transcribing: idle -> recording -> meetingEnded -> transcribing
        await coordinator.handle(.meetingDetected(makeMeeting()))
        await coordinator.handle(.meetingEnded)

        let transcribingState = await coordinator.state
        guard case .transcribing(let meetingId) = transcribingState else {
            XCTFail("Expected .transcribing state, got \(transcribingState)")
            return
        }

        // Directly send transcriptionComplete event (tests the pure state transition
        // that the onComplete callback dispatches on success)
        await coordinator.handle(.transcriptionComplete(meetingId: meetingId))

        let finalState = await coordinator.state
        XCTAssertEqual(finalState, .idle, "Coordinator should transition to .idle after transcriptionComplete")
    }

    func testTranscriptionFailedTransitionsToError() async throws {
        // Stub ASR to fail so the pipeline calls onComplete with .failure
        mockASR.stubbedError = CoordinatorTestError.sample
        let coordinator = makeCoordinator()

        await coordinator.handle(.meetingDetected(makeMeeting()))
        let recordingState = await coordinator.state
        guard case .recording(let meetingId) = recordingState else {
            XCTFail("Expected .recording state")
            return
        }

        await coordinator.handle(.meetingEnded)

        // Wait for pipeline failure callback to transition to .error
        let start = Date()
        var finalState = await coordinator.state
        while Date().timeIntervalSince(start) < 10.0 {
            finalState = await coordinator.state
            if case .error = finalState { break }
            try await Task.sleep(for: .milliseconds(100))
        }

        guard case .error(let errorMeetingId, _) = finalState else {
            XCTFail("Expected .error state after pipeline failure, got \(finalState)")
            return
        }
        XCTAssertEqual(errorMeetingId, meetingId, "Error state should reference the correct meeting")
    }

    func testRetryWithCompletionCallback() async throws {
        let coordinator = makeCoordinator()

        // Drive to .error state via recording -> recordingFailed
        await coordinator.handle(.meetingDetected(makeMeeting()))
        let recordingState = await coordinator.state
        guard case .recording(let meetingId) = recordingState else {
            XCTFail("Expected .recording state")
            return
        }

        await coordinator.handle(.recordingFailed(CoordinatorTestError.sample))
        let errorState = await coordinator.state
        guard case .error = errorState else {
            XCTFail("Expected .error state before retry, got \(errorState)")
            return
        }

        // Retry -- pipeline processes and calls back via onComplete
        await coordinator.retryTranscription(meetingId: meetingId)

        // Wait for pipeline callback to transition out of .transcribing
        let start = Date()
        var finalState = await coordinator.state
        while Date().timeIntervalSince(start) < 10.0 {
            finalState = await coordinator.state
            if case .transcribing = finalState {
                try await Task.sleep(for: .milliseconds(100))
                continue
            }
            break
        }

        // Should NOT be stuck in .transcribing -- callback should have fired
        if case .transcribing = finalState {
            XCTFail("Coordinator stuck in .transcribing -- pipeline callback did not fire")
        }
        // Accept either .idle (success) or .error (failure) -- both prove the callback works
    }

    // MARK: - Disk Space Guard

    func testInsufficientDiskSpaceBlocksRecording() async {
        let coordinator = makeCoordinator()

        // Drive to .recording state first
        await coordinator.handle(.meetingDetected(makeMeeting()))
        let recordingState = await coordinator.state
        guard case .recording(let meetingId) = recordingState else {
            XCTFail("Expected .recording state")
            return
        }

        // Simulate disk space failure by sending recordingFailed with insufficientDiskSpace
        let error = CoordinatorError.insufficientDiskSpace(
            available: 100 * 1024 * 1024,  // 100 MB
            required: 500 * 1024 * 1024     // 500 MB
        )
        await coordinator.handle(.recordingFailed(error))

        let finalState = await coordinator.state
        guard case .error(let errorMeetingId, _) = finalState else {
            XCTFail("Expected .error state after insufficient disk space, got \(finalState)")
            return
        }
        XCTAssertEqual(errorMeetingId, meetingId)
    }

    func testInsufficientDiskSpaceErrorDescription() {
        let error = CoordinatorError.insufficientDiskSpace(
            available: 100 * 1024 * 1024,
            required: 500 * 1024 * 1024
        )
        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.contains("disk space"), "Error should mention disk space, got: \(description)")
        XCTAssertTrue(description.contains("500"), "Error should mention required MB, got: \(description)")
    }

    // MARK: - Convenience Methods (Existing)

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

import XCTest
@testable import Caddie

@MainActor
final class RecordingStateTests: XCTestCase {

    // MARK: - Test Helpers

    private func makeMeeting(app: String = "Zoom", title: String = "Standup") -> DetectedMeeting {
        DetectedMeeting(app: app, title: title, processId: 1234)
    }

    // MARK: - Valid Transitions

    func testIdleToRecording() {
        let meeting = makeMeeting()
        let result = RecordingState.reduce(state: .idle, event: .meetingDetected(meeting))

        XCTAssertNotNil(result)
        let (newState, sideEffect) = result!
        guard case .recording(let meetingId) = newState else {
            XCTFail("Expected .recording state, got \(newState)")
            return
        }
        XCTAssertFalse(meetingId.isEmpty)

        guard case .startRecording(let effectId, let effectMeeting) = sideEffect else {
            XCTFail("Expected .startRecording side effect, got \(String(describing: sideEffect))")
            return
        }
        XCTAssertEqual(effectId, meetingId)
        XCTAssertEqual(effectMeeting.app, "Zoom")
    }

    func testRecordingToTranscribing() {
        let result = RecordingState.reduce(
            state: .recording(meetingId: "abc123"),
            event: .meetingEnded
        )

        XCTAssertNotNil(result)
        let (newState, sideEffect) = result!
        guard case .transcribing(let meetingId) = newState else {
            XCTFail("Expected .transcribing state, got \(newState)")
            return
        }
        XCTAssertEqual(meetingId, "abc123")

        guard case .stopAndTranscribe(let effectId) = sideEffect else {
            XCTFail("Expected .stopAndTranscribe side effect")
            return
        }
        XCTAssertEqual(effectId, "abc123")
    }

    func testRecordingToError() {
        let testError = TestError.sample
        let result = RecordingState.reduce(
            state: .recording(meetingId: "abc123"),
            event: .recordingFailed(testError)
        )

        XCTAssertNotNil(result)
        let (newState, sideEffect) = result!
        guard case .error(let meetingId, _) = newState else {
            XCTFail("Expected .error state, got \(newState)")
            return
        }
        XCTAssertEqual(meetingId, "abc123")

        guard case .notifyError(let effectId, _) = sideEffect else {
            XCTFail("Expected .notifyError side effect")
            return
        }
        XCTAssertEqual(effectId, "abc123")
    }

    func testTranscribingToIdle() {
        let result = RecordingState.reduce(
            state: .transcribing(meetingId: "abc123"),
            event: .transcriptionComplete(meetingId: "abc123")
        )

        XCTAssertNotNil(result)
        let (newState, sideEffect) = result!
        guard case .idle = newState else {
            XCTFail("Expected .idle state, got \(newState)")
            return
        }

        guard case .notifyComplete(let effectId) = sideEffect else {
            XCTFail("Expected .notifyComplete side effect")
            return
        }
        XCTAssertEqual(effectId, "abc123")
    }

    func testTranscribingToError() {
        let testError = TestError.sample
        let result = RecordingState.reduce(
            state: .transcribing(meetingId: "abc123"),
            event: .transcriptionFailed(meetingId: "abc123", testError)
        )

        XCTAssertNotNil(result)
        let (newState, sideEffect) = result!
        guard case .error(let meetingId, _) = newState else {
            XCTFail("Expected .error state, got \(newState)")
            return
        }
        XCTAssertEqual(meetingId, "abc123")

        guard case .notifyError(let effectId, _) = sideEffect else {
            XCTFail("Expected .notifyError side effect")
            return
        }
        XCTAssertEqual(effectId, "abc123")
    }

    func testErrorToTranscribing() {
        let result = RecordingState.reduce(
            state: .error(meetingId: "abc123", TestError.sample),
            event: .retryRequested(meetingId: "abc123")
        )

        XCTAssertNotNil(result)
        let (newState, sideEffect) = result!
        guard case .transcribing(let meetingId) = newState else {
            XCTFail("Expected .transcribing state, got \(newState)")
            return
        }
        XCTAssertEqual(meetingId, "abc123")

        guard case .retryTranscription(let effectId) = sideEffect else {
            XCTFail("Expected .retryTranscription side effect")
            return
        }
        XCTAssertEqual(effectId, "abc123")
    }

    func testErrorToIdle() {
        let result = RecordingState.reduce(
            state: .error(meetingId: "abc123", TestError.sample),
            event: .reset
        )

        XCTAssertNotNil(result)
        let (newState, sideEffect) = result!
        guard case .idle = newState else {
            XCTFail("Expected .idle state, got \(newState)")
            return
        }
        XCTAssertNil(sideEffect)
    }

    // MARK: - Invalid Transitions

    func testIdleMeetingEndedIsInvalid() {
        let result = RecordingState.reduce(state: .idle, event: .meetingEnded)
        XCTAssertNil(result)
    }

    func testIdleTranscriptionCompleteIsInvalid() {
        let result = RecordingState.reduce(
            state: .idle,
            event: .transcriptionComplete(meetingId: "abc123")
        )
        XCTAssertNil(result)
    }

    func testIdleRetryIsInvalid() {
        let result = RecordingState.reduce(
            state: .idle,
            event: .retryRequested(meetingId: "abc123")
        )
        XCTAssertNil(result)
    }

    func testRecordingMeetingDetectedIsInvalid() {
        let result = RecordingState.reduce(
            state: .recording(meetingId: "abc123"),
            event: .meetingDetected(makeMeeting())
        )
        XCTAssertNil(result)
    }

    func testRecordingTranscriptionCompleteIsInvalid() {
        let result = RecordingState.reduce(
            state: .recording(meetingId: "abc123"),
            event: .transcriptionComplete(meetingId: "abc123")
        )
        XCTAssertNil(result)
    }

    func testTranscribingMeetingDetectedIsInvalid() {
        let result = RecordingState.reduce(
            state: .transcribing(meetingId: "abc123"),
            event: .meetingDetected(makeMeeting())
        )
        XCTAssertNil(result)
    }

    func testTranscribingMeetingEndedIsInvalid() {
        let result = RecordingState.reduce(
            state: .transcribing(meetingId: "abc123"),
            event: .meetingEnded
        )
        XCTAssertNil(result)
    }

    // MARK: - Additional Invalid Transitions

    func testIdleRecordingFailedIsInvalid() {
        let result = RecordingState.reduce(
            state: .idle,
            event: .recordingFailed(TestError.sample)
        )
        XCTAssertNil(result)
    }

    func testIdleResetIsInvalid() {
        let result = RecordingState.reduce(state: .idle, event: .reset)
        XCTAssertNil(result)
    }

    func testErrorMeetingDetectedIsInvalid() {
        let result = RecordingState.reduce(
            state: .error(meetingId: "abc123", TestError.sample),
            event: .meetingDetected(makeMeeting())
        )
        XCTAssertNil(result)
    }

    func testErrorMeetingEndedIsInvalid() {
        let result = RecordingState.reduce(
            state: .error(meetingId: "abc123", TestError.sample),
            event: .meetingEnded
        )
        XCTAssertNil(result)
    }

    // MARK: - Device Disconnected Transitions

    func testRecordingDeviceDisconnectedTransitionsToTranscribing() {
        let result = RecordingState.reduce(
            state: .recording(meetingId: "abc123"),
            event: .deviceDisconnected
        )

        XCTAssertNotNil(result)
        let (newState, sideEffect) = result!
        guard case .transcribing(let meetingId) = newState else {
            XCTFail("Expected .transcribing state, got \(newState)")
            return
        }
        XCTAssertEqual(meetingId, "abc123")

        guard case .stopAndTranscribe(let effectId) = sideEffect else {
            XCTFail("Expected .stopAndTranscribe side effect")
            return
        }
        XCTAssertEqual(effectId, "abc123")
    }

    func testIdleDeviceDisconnectedIsInvalid() {
        let result = RecordingState.reduce(state: .idle, event: .deviceDisconnected)
        XCTAssertNil(result)
    }

    func testTranscribingDeviceDisconnectedIsInvalid() {
        let result = RecordingState.reduce(
            state: .transcribing(meetingId: "abc123"),
            event: .deviceDisconnected
        )
        XCTAssertNil(result)
    }

    func testErrorDeviceDisconnectedIsInvalid() {
        let result = RecordingState.reduce(
            state: .error(meetingId: "abc123", TestError.sample),
            event: .deviceDisconnected
        )
        XCTAssertNil(result)
    }

    // MARK: - Manual Recording Transitions

    func testManualStartFromIdleTransitionsToRecording() {
        let result = RecordingState.reduce(state: .idle, event: .manualStart(title: "Manual Recording"))

        XCTAssertNotNil(result)
        let (newState, sideEffect) = result!
        guard case .recording(let meetingId) = newState else {
            XCTFail("Expected .recording state, got \(newState)")
            return
        }
        XCTAssertFalse(meetingId.isEmpty)

        guard case .startRecording(let effectId, let effectMeeting) = sideEffect else {
            XCTFail("Expected .startRecording side effect, got \(String(describing: sideEffect))")
            return
        }
        XCTAssertEqual(effectId, meetingId)
        XCTAssertEqual(effectMeeting.app, "Manual")
        XCTAssertEqual(effectMeeting.title, "Manual Recording")
        XCTAssertNil(effectMeeting.processId)
    }

    func testManualStopFromRecordingTransitionsToTranscribing() {
        let result = RecordingState.reduce(
            state: .recording(meetingId: "abc123"),
            event: .manualStop
        )

        XCTAssertNotNil(result)
        let (newState, sideEffect) = result!
        guard case .transcribing(let meetingId) = newState else {
            XCTFail("Expected .transcribing state, got \(newState)")
            return
        }
        XCTAssertEqual(meetingId, "abc123")

        guard case .stopAndTranscribe(let effectId) = sideEffect else {
            XCTFail("Expected .stopAndTranscribe side effect")
            return
        }
        XCTAssertEqual(effectId, "abc123")
    }

    func testManualStartWhileRecordingReturnsNil() {
        let result = RecordingState.reduce(
            state: .recording(meetingId: "abc123"),
            event: .manualStart(title: "X")
        )
        XCTAssertNil(result)
    }

    func testManualStopFromIdleReturnsNil() {
        let result = RecordingState.reduce(state: .idle, event: .manualStop)
        XCTAssertNil(result)
    }

    // MARK: - Equatable

    func testIdleEquality() {
        XCTAssertEqual(RecordingState.idle, RecordingState.idle)
    }

    func testRecordingEqualitySameId() {
        XCTAssertEqual(
            RecordingState.recording(meetingId: "abc"),
            RecordingState.recording(meetingId: "abc")
        )
    }

    func testRecordingInequalityDifferentId() {
        XCTAssertNotEqual(
            RecordingState.recording(meetingId: "abc"),
            RecordingState.recording(meetingId: "xyz")
        )
    }

    // MARK: - Unique Meeting IDs

    func testUniqueMeetingIds() {
        let meeting = makeMeeting()
        let result1 = RecordingState.reduce(state: .idle, event: .meetingDetected(meeting))
        let result2 = RecordingState.reduce(state: .idle, event: .meetingDetected(meeting))

        XCTAssertNotNil(result1)
        XCTAssertNotNil(result2)

        guard case .recording(let id1) = result1!.newState,
              case .recording(let id2) = result2!.newState else {
            XCTFail("Expected .recording states")
            return
        }
        XCTAssertNotEqual(id1, id2)
    }
}

// MARK: - Test Helpers

private enum TestError: Error, LocalizedError {
    case sample

    var errorDescription: String? { "Test error" }
}

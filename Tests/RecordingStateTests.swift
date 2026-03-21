import Testing
@testable import Caddie

@Suite("RecordingState - Pure State Machine")
struct RecordingStateTests {

    // MARK: - Test Helpers

    private func makeMeeting(app: String = "Zoom", title: String = "Standup") -> DetectedMeeting {
        DetectedMeeting(app: app, title: title, processId: 1234)
    }

    // MARK: - Valid Transitions

    @Test("idle + meetingDetected -> recording with startRecording side effect")
    func idleToRecording() {
        let meeting = makeMeeting()
        let result = RecordingState.reduce(state: .idle, event: .meetingDetected(meeting))

        #expect(result != nil)
        let (newState, sideEffect) = result!
        guard case .recording(let meetingId) = newState else {
            Issue.record("Expected .recording state, got \(newState)")
            return
        }
        #expect(!meetingId.isEmpty)

        guard case .startRecording(let effectId, let effectMeeting) = sideEffect else {
            Issue.record("Expected .startRecording side effect, got \(String(describing: sideEffect))")
            return
        }
        #expect(effectId == meetingId)
        #expect(effectMeeting.app == "Zoom")
    }

    @Test("recording + meetingEnded -> transcribing with stopAndTranscribe side effect")
    func recordingToTranscribing() {
        let result = RecordingState.reduce(
            state: .recording(meetingId: "abc123"),
            event: .meetingEnded
        )

        #expect(result != nil)
        let (newState, sideEffect) = result!
        guard case .transcribing(let meetingId) = newState else {
            Issue.record("Expected .transcribing state, got \(newState)")
            return
        }
        #expect(meetingId == "abc123")

        guard case .stopAndTranscribe(let effectId) = sideEffect else {
            Issue.record("Expected .stopAndTranscribe side effect")
            return
        }
        #expect(effectId == "abc123")
    }

    @Test("recording + recordingFailed -> error with notifyError side effect")
    func recordingToError() {
        let testError = TestError.sample
        let result = RecordingState.reduce(
            state: .recording(meetingId: "abc123"),
            event: .recordingFailed(testError)
        )

        #expect(result != nil)
        let (newState, sideEffect) = result!
        guard case .error(let meetingId, _) = newState else {
            Issue.record("Expected .error state, got \(newState)")
            return
        }
        #expect(meetingId == "abc123")

        guard case .notifyError(let effectId, _) = sideEffect else {
            Issue.record("Expected .notifyError side effect")
            return
        }
        #expect(effectId == "abc123")
    }

    @Test("transcribing + transcriptionComplete -> idle with notifyComplete side effect")
    func transcribingToIdle() {
        let result = RecordingState.reduce(
            state: .transcribing(meetingId: "abc123"),
            event: .transcriptionComplete(meetingId: "abc123")
        )

        #expect(result != nil)
        let (newState, sideEffect) = result!
        guard case .idle = newState else {
            Issue.record("Expected .idle state, got \(newState)")
            return
        }

        guard case .notifyComplete(let effectId) = sideEffect else {
            Issue.record("Expected .notifyComplete side effect")
            return
        }
        #expect(effectId == "abc123")
    }

    @Test("transcribing + transcriptionFailed -> error with notifyError side effect")
    func transcribingToError() {
        let testError = TestError.sample
        let result = RecordingState.reduce(
            state: .transcribing(meetingId: "abc123"),
            event: .transcriptionFailed(meetingId: "abc123", testError)
        )

        #expect(result != nil)
        let (newState, sideEffect) = result!
        guard case .error(let meetingId, _) = newState else {
            Issue.record("Expected .error state, got \(newState)")
            return
        }
        #expect(meetingId == "abc123")

        guard case .notifyError(let effectId, _) = sideEffect else {
            Issue.record("Expected .notifyError side effect")
            return
        }
        #expect(effectId == "abc123")
    }

    @Test("error + retryRequested -> transcribing with retryTranscription side effect")
    func errorToTranscribing() {
        let result = RecordingState.reduce(
            state: .error(meetingId: "abc123", TestError.sample),
            event: .retryRequested(meetingId: "abc123")
        )

        #expect(result != nil)
        let (newState, sideEffect) = result!
        guard case .transcribing(let meetingId) = newState else {
            Issue.record("Expected .transcribing state, got \(newState)")
            return
        }
        #expect(meetingId == "abc123")

        guard case .retryTranscription(let effectId) = sideEffect else {
            Issue.record("Expected .retryTranscription side effect")
            return
        }
        #expect(effectId == "abc123")
    }

    @Test("error + reset -> idle with no side effect")
    func errorToIdle() {
        let result = RecordingState.reduce(
            state: .error(meetingId: "abc123", TestError.sample),
            event: .reset
        )

        #expect(result != nil)
        let (newState, sideEffect) = result!
        guard case .idle = newState else {
            Issue.record("Expected .idle state, got \(newState)")
            return
        }
        #expect(sideEffect == nil)
    }

    // MARK: - Invalid Transitions

    @Test("idle + meetingEnded -> nil (not recording)")
    func idleMeetingEndedIsInvalid() {
        let result = RecordingState.reduce(state: .idle, event: .meetingEnded)
        #expect(result == nil)
    }

    @Test("idle + transcriptionComplete -> nil (not transcribing)")
    func idleTranscriptionCompleteIsInvalid() {
        let result = RecordingState.reduce(
            state: .idle,
            event: .transcriptionComplete(meetingId: "abc123")
        )
        #expect(result == nil)
    }

    @Test("idle + retryRequested -> nil (no error to retry)")
    func idleRetryIsInvalid() {
        let result = RecordingState.reduce(
            state: .idle,
            event: .retryRequested(meetingId: "abc123")
        )
        #expect(result == nil)
    }

    @Test("recording + meetingDetected -> nil (already recording)")
    func recordingMeetingDetectedIsInvalid() {
        let result = RecordingState.reduce(
            state: .recording(meetingId: "abc123"),
            event: .meetingDetected(makeMeeting())
        )
        #expect(result == nil)
    }

    @Test("recording + transcriptionComplete -> nil (not transcribing yet)")
    func recordingTranscriptionCompleteIsInvalid() {
        let result = RecordingState.reduce(
            state: .recording(meetingId: "abc123"),
            event: .transcriptionComplete(meetingId: "abc123")
        )
        #expect(result == nil)
    }

    @Test("transcribing + meetingDetected -> nil (busy transcribing)")
    func transcribingMeetingDetectedIsInvalid() {
        let result = RecordingState.reduce(
            state: .transcribing(meetingId: "abc123"),
            event: .meetingDetected(makeMeeting())
        )
        #expect(result == nil)
    }

    @Test("transcribing + meetingEnded -> nil (already stopped)")
    func transcribingMeetingEndedIsInvalid() {
        let result = RecordingState.reduce(
            state: .transcribing(meetingId: "abc123"),
            event: .meetingEnded
        )
        #expect(result == nil)
    }

    // MARK: - Additional Edge Cases

    @Test("idle + recordingFailed -> nil (not recording)")
    func idleRecordingFailedIsInvalid() {
        let result = RecordingState.reduce(
            state: .idle,
            event: .recordingFailed(TestError.sample)
        )
        #expect(result == nil)
    }

    @Test("idle + reset -> nil (already idle)")
    func idleResetIsInvalid() {
        let result = RecordingState.reduce(state: .idle, event: .reset)
        #expect(result == nil)
    }

    @Test("error + meetingDetected -> nil (must reset first)")
    func errorMeetingDetectedIsInvalid() {
        let result = RecordingState.reduce(
            state: .error(meetingId: "abc123", TestError.sample),
            event: .meetingDetected(makeMeeting())
        )
        #expect(result == nil)
    }

    @Test("error + meetingEnded -> nil (not recording)")
    func errorMeetingEndedIsInvalid() {
        let result = RecordingState.reduce(
            state: .error(meetingId: "abc123", TestError.sample),
            event: .meetingEnded
        )
        #expect(result == nil)
    }

    // MARK: - State Equatable

    @Test("RecordingState idle cases are equal")
    func idleEquality() {
        #expect(RecordingState.idle == RecordingState.idle)
    }

    @Test("RecordingState recording cases with same meetingId are equal")
    func recordingEquality() {
        #expect(
            RecordingState.recording(meetingId: "abc") ==
            RecordingState.recording(meetingId: "abc")
        )
    }

    @Test("RecordingState recording cases with different meetingId are not equal")
    func recordingInequality() {
        #expect(
            RecordingState.recording(meetingId: "abc") !=
            RecordingState.recording(meetingId: "xyz")
        )
    }

    // MARK: - meetingDetected generates unique meetingId

    @Test("Two meetingDetected transitions generate different meetingIds")
    func uniqueMeetingIds() {
        let meeting = makeMeeting()
        let result1 = RecordingState.reduce(state: .idle, event: .meetingDetected(meeting))
        let result2 = RecordingState.reduce(state: .idle, event: .meetingDetected(meeting))

        #expect(result1 != nil)
        #expect(result2 != nil)

        guard case .recording(let id1) = result1!.newState,
              case .recording(let id2) = result2!.newState else {
            Issue.record("Expected .recording states")
            return
        }
        #expect(id1 != id2)
    }
}

// MARK: - Test Helpers

private enum TestError: Error, LocalizedError {
    case sample

    var errorDescription: String? { "Test error" }
}

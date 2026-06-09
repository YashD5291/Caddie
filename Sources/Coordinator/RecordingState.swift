import Foundation

// MARK: - RecordingState

enum RecordingState: Sendable, Equatable {
    case idle
    case recording(meetingId: String)
    case transcribing(meetingId: String)
    case error(meetingId: String, Error)

    static func == (lhs: RecordingState, rhs: RecordingState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle):
            return true
        case (.recording(let lId), .recording(let rId)):
            return lId == rId
        case (.transcribing(let lId), .transcribing(let rId)):
            return lId == rId
        case (.error(let lId, _), .error(let rId, _)):
            return lId == rId
        default:
            return false
        }
    }
}

// MARK: - RecordingEvent

enum RecordingEvent: Sendable {
    case meetingDetected(DetectedMeeting)
    case meetingEnded
    case recordingFailed(Error)
    case transcriptionComplete(meetingId: String)
    case transcriptionFailed(meetingId: String, Error)
    case retryRequested(meetingId: String)
    case manualStart(title: String)
    case manualStop
    case deviceDisconnected
    case reset
}

// MARK: - RecordingSideEffect

enum RecordingSideEffect: Sendable, Equatable {
    case startRecording(meetingId: String, meeting: DetectedMeeting)
    case stopAndTranscribe(meetingId: String)
    case retryTranscription(meetingId: String)
    case notifyComplete(meetingId: String)
    case notifyError(meetingId: String, Error)

    static func == (lhs: RecordingSideEffect, rhs: RecordingSideEffect) -> Bool {
        switch (lhs, rhs) {
        case (.startRecording(let lId, _), .startRecording(let rId, _)):
            return lId == rId
        case (.stopAndTranscribe(let lId), .stopAndTranscribe(let rId)):
            return lId == rId
        case (.retryTranscription(let lId), .retryTranscription(let rId)):
            return lId == rId
        case (.notifyComplete(let lId), .notifyComplete(let rId)):
            return lId == rId
        case (.notifyError(let lId, _), .notifyError(let rId, _)):
            return lId == rId
        default:
            return false
        }
    }
}

// MARK: - Reduce

extension RecordingState {

    /// Pure synchronous state transition function.
    /// Returns nil for invalid transitions, or (newState, optionalSideEffect) for valid ones.
    static func reduce(
        state: RecordingState,
        event: RecordingEvent
    ) -> (newState: RecordingState, sideEffect: RecordingSideEffect?)? {
        switch (state, event) {

        case (.idle, .meetingDetected(let meeting)):
            let meetingId = generateMeetingId()
            return (
                .recording(meetingId: meetingId),
                .startRecording(meetingId: meetingId, meeting: meeting)
            )

        case (.idle, .manualStart(let title)):
            let meetingId = generateMeetingId()
            let meeting = DetectedMeeting(app: "Manual", title: title, processId: nil)
            return (
                .recording(meetingId: meetingId),
                .startRecording(meetingId: meetingId, meeting: meeting)
            )

        // Recovery path: a previous recording or transcription failed and we're
        // sitting in `.error`. Allow the user to start a fresh recording without
        // having to relaunch the app — the failed meeting stays in DB as `.error`
        // and the new one gets its own meetingId.
        case (.error, .manualStart(let title)):
            let meetingId = generateMeetingId()
            let meeting = DetectedMeeting(app: "Manual", title: title, processId: nil)
            return (
                .recording(meetingId: meetingId),
                .startRecording(meetingId: meetingId, meeting: meeting)
            )

        case (.recording(let meetingId), .meetingEnded):
            return (
                .transcribing(meetingId: meetingId),
                .stopAndTranscribe(meetingId: meetingId)
            )

        case (.recording(let meetingId), .manualStop):
            return (
                .transcribing(meetingId: meetingId),
                .stopAndTranscribe(meetingId: meetingId)
            )

        case (.recording(let meetingId), .deviceDisconnected):
            return (
                .transcribing(meetingId: meetingId),
                .stopAndTranscribe(meetingId: meetingId)
            )

        case (.recording(let meetingId), .recordingFailed(let error)):
            return (
                .error(meetingId: meetingId, error),
                .notifyError(meetingId: meetingId, error)
            )

        case (.transcribing(let meetingId), .transcriptionComplete):
            return (
                .idle,
                .notifyComplete(meetingId: meetingId)
            )

        case (.transcribing(let meetingId), .transcriptionFailed(_, let error)):
            return (
                .error(meetingId: meetingId, error),
                .notifyError(meetingId: meetingId, error)
            )

        case (.error(let meetingId, _), .retryRequested):
            return (
                .transcribing(meetingId: meetingId),
                .retryTranscription(meetingId: meetingId)
            )

        case (.error, .reset):
            return (.idle, nil)

        // Absorb terminal-failure events that arrive while already in `.error`.
        // Callbacks (device disconnect, recording/transcription failure) can fire
        // unconditionally during teardown of an already-failed meeting. Stay in
        // `.error` with the ORIGINAL error and emit no side effect, so the first
        // failure is preserved and the coordinator stops logging "Invalid transition".
        case (.error, .deviceDisconnected),
             (.error, .transcriptionFailed),
             (.error, .recordingFailed):
            return (state, nil)

        default:
            return nil
        }
    }

    private static func generateMeetingId() -> String {
        String(UUID().uuidString.prefix(12)).lowercased()
    }
}

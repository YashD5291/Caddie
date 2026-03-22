import Foundation
import os

/// Actor-based coordinator that owns the recording lifecycle.
/// Uses RecordingState.reduce() for synchronous state transitions
/// and dispatches async side effects after each transition.
actor RecordingCoordinator {

    // MARK: - State

    private(set) var state: RecordingState = .idle

    // MARK: - Dependencies

    private let database: AppDatabase
    private let recorder: AudioRecorder
    private let pipeline: TranscriptionPipeline
    private let detector: MeetingDetector

    // MARK: - Callbacks

    private var onStateChange: (@Sendable (RecordingState) -> Void)?

    private let logger = Logger(subsystem: "com.caddie.app", category: "RecordingCoordinator")

    // MARK: - Init

    init(
        database: AppDatabase,
        recorder: AudioRecorder,
        pipeline: TranscriptionPipeline,
        detector: MeetingDetector
    ) {
        self.database = database
        self.recorder = recorder
        self.pipeline = pipeline
        self.detector = detector
    }

    // MARK: - Public API

    /// Set the state change callback. Called after every valid transition.
    func setOnStateChange(_ callback: (@Sendable (RecordingState) -> Void)?) {
        self.onStateChange = callback
    }

    /// Process a recording event through the state machine.
    /// Synchronously transitions state, then executes any resulting side effect.
    func handle(_ event: RecordingEvent) async {
        guard let result = RecordingState.reduce(state: state, event: event) else {
            logger.warning("Invalid transition: \(String(describing: self.state)) + \(String(describing: event))")
            return
        }

        state = result.newState
        logger.info("State -> \(String(describing: self.state))")
        onStateChange?(state)

        if let sideEffect = result.sideEffect {
            await execute(sideEffect)
        }
    }

    /// Wire up the meeting detector callbacks and start detection.
    /// Call this AFTER the pipeline is fully initialized.
    func start() {
        nonisolated(unsafe) let coordinator = self
        detector.onMeetingStarted = { meeting in
            Task { await coordinator.handle(.meetingDetected(meeting)) }
        }
        detector.onMeetingEnded = {
            Task { await coordinator.handle(.meetingEnded) }
        }
        detector.start()
        logger.info("RecordingCoordinator started")
    }

    /// Stop the detector and recorder.
    func stop() {
        detector.stop()
        if case .recording = state {
            recorder.stop()
        }
        logger.info("RecordingCoordinator stopped")
    }

    // MARK: - Convenience

    /// Convenience method to stop an active recording.
    func stopRecording() async {
        await handle(.meetingEnded)
    }

    /// Convenience method to retry a failed transcription.
    func retryTranscription(meetingId: String) async {
        await handle(.retryRequested(meetingId: meetingId))
    }

    // MARK: - Precondition Checks

    private static let minimumDiskSpaceBytes: Int64 = 500 * 1024 * 1024  // 500 MB

    private func checkDiskSpace() throws {
        let resourceValues = try AudioFileManager.audioDirectory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        guard let available = resourceValues.volumeAvailableCapacityForImportantUsage,
              available >= Self.minimumDiskSpaceBytes else {
            let available = resourceValues.volumeAvailableCapacityForImportantUsage ?? 0
            throw CoordinatorError.insufficientDiskSpace(
                available: available,
                required: Self.minimumDiskSpaceBytes
            )
        }
    }

    // MARK: - Side Effect Execution

    private func execute(_ effect: RecordingSideEffect) async {
        switch effect {
        case .startRecording(let meetingId, let meeting):
            await executeStartRecording(meetingId: meetingId, meeting: meeting)

        case .stopAndTranscribe(let meetingId):
            await executeStopAndTranscribe(meetingId: meetingId)

        case .retryTranscription(let meetingId):
            await executeRetryTranscription(meetingId: meetingId)

        case .notifyComplete(let meetingId):
            await executeNotifyComplete(meetingId: meetingId)

        case .notifyError(let meetingId, let error):
            await executeNotifyError(meetingId: meetingId, error: error)
        }
    }

    private func executeStartRecording(meetingId: String, meeting: DetectedMeeting) async {
        do {
            try checkDiskSpace()
        } catch {
            logger.error("Disk space check failed: \(error.localizedDescription)")
            await handle(.recordingFailed(error))
            return
        }

        let now = ISO8601DateFormatter().string(from: Date())
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let today = dateFormatter.string(from: Date())

        do {
            try await database.dbWriter.write { dbConn in
                var record = Meeting(
                    meetingId: meetingId,
                    title: meeting.title,
                    app: meeting.app,
                    date: today,
                    startTime: now,
                    status: .recording
                )
                record.audioFile = "\(meetingId).m4a"
                try record.insert(dbConn)
            }
            logger.info("Created meeting record: \(meetingId)")
        } catch {
            logger.error("Failed to insert meeting record: \(error.localizedDescription)")
            // Transition to error state since we can't proceed without a DB record
            await handle(.recordingFailed(error))
            return
        }

        let wavPath = AudioFileManager.wavPath(for: meetingId)
        do {
            try recorder.start(outputPath: wavPath, processID: meeting.processId)
            logger.info("Recording started for meeting \(meetingId)")
        } catch {
            logger.error("Failed to start recording: \(error.localizedDescription)")
            await handle(.recordingFailed(error))
        }
    }

    private func executeStopAndTranscribe(meetingId: String) async {
        recorder.stop()

        let endTime = ISO8601DateFormatter().string(from: Date())

        do {
            try await database.dbWriter.write { dbConn in
                try dbConn.execute(
                    sql: """
                        UPDATE meetings
                        SET end_time = ?, status = ?
                        WHERE meeting_id = ?
                        """,
                    arguments: [endTime, MeetingStatus.transcribing.rawValue, meetingId]
                )
            }
        } catch {
            logger.error("Failed to update meeting status to transcribing: \(error.localizedDescription)")
        }

        logger.info("Recording stopped for meeting \(meetingId), enqueuing transcription")

        let db = database
        await pipeline.enqueue(meetingId: meetingId, database: db) { [self] meetingId, result in
            Task {
                switch result {
                case .success:
                    await self.handle(.transcriptionComplete(meetingId: meetingId))
                case .failure(let error):
                    await self.handle(.transcriptionFailed(meetingId: meetingId, error))
                }
            }
        }
    }

    // DATA-06: Retry uses coordinator's non-optional database (always fresh per Phase 4).
    // No stale DB risk -- database is a required init parameter, not optional.
    private func executeRetryTranscription(meetingId: String) async {
        let wavURL = AudioFileManager.wavPath(for: meetingId)
        guard FileManager.default.fileExists(atPath: wavURL.path) else {
            logger.error("Cannot retry transcription -- WAV file not found for \(meetingId)")
            await handle(.transcriptionFailed(
                meetingId: meetingId,
                CoordinatorError.audioFileNotFound(meetingId)
            ))
            return
        }

        do {
            try await database.dbWriter.write { dbConn in
                try dbConn.execute(
                    sql: "UPDATE meetings SET status = ?, error = NULL WHERE meeting_id = ?",
                    arguments: [MeetingStatus.transcribing.rawValue, meetingId]
                )
            }
        } catch {
            logger.error("Failed to update meeting for retry: \(error.localizedDescription)")
        }

        let db = database
        await pipeline.enqueue(meetingId: meetingId, database: db) { [self] meetingId, result in
            Task {
                switch result {
                case .success:
                    await self.handle(.transcriptionComplete(meetingId: meetingId))
                case .failure(let error):
                    await self.handle(.transcriptionFailed(meetingId: meetingId, error))
                }
            }
        }
    }

    private func executeNotifyComplete(meetingId: String) async {
        do {
            try await database.dbWriter.write { dbConn in
                try dbConn.execute(
                    sql: "UPDATE meetings SET status = ? WHERE meeting_id = ?",
                    arguments: [MeetingStatus.done.rawValue, meetingId]
                )
            }
            logger.info("Meeting \(meetingId) completed successfully")
        } catch {
            logger.error("Failed to update meeting status to done: \(error.localizedDescription)")
        }
    }

    private func executeNotifyError(meetingId: String, error: Error) async {
        do {
            try await database.dbWriter.write { dbConn in
                try dbConn.execute(
                    sql: "UPDATE meetings SET status = ?, error = ? WHERE meeting_id = ?",
                    arguments: [MeetingStatus.error.rawValue, error.localizedDescription, meetingId]
                )
            }
        } catch {
            logger.error("Failed to update meeting error status: \(error.localizedDescription)")
        }
    }
}

// MARK: - Errors

enum CoordinatorError: Error, LocalizedError {
    case audioFileNotFound(String)
    case insufficientDiskSpace(available: Int64, required: Int64)

    var errorDescription: String? {
        switch self {
        case .audioFileNotFound(let meetingId):
            return "Audio file not found for meeting \(meetingId)"
        case .insufficientDiskSpace(let available, _):
            let availableMB = available / (1024 * 1024)
            return "Not enough disk space to record. Available: \(availableMB) MB, required: 500 MB. Free up space and try again."
        }
    }
}

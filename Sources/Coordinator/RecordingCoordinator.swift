import Foundation
import GRDB
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
    private let audioDeviceManager: AudioDeviceManager?

    /// Display-only live transcriber, started/stopped around the recording lifecycle.
    /// nil when ASR models are unavailable (AppState constructs it only once models
    /// are loaded). The engine owns its ASR models — the coordinator passes none.
    private let liveTranscriber: LiveTranscriber?

    // MARK: - Callbacks

    private var onStateChange: (@Sendable (RecordingState) -> Void)?
    private var onPipelineStepChange: (@Sendable (PipelineStep) -> Void)?

    private let logger = Logger(subsystem: "com.caddie.app", category: "RecordingCoordinator")

    // MARK: - Init

    init(
        database: AppDatabase,
        recorder: AudioRecorder,
        pipeline: TranscriptionPipeline,
        detector: MeetingDetector,
        audioDeviceManager: AudioDeviceManager? = nil,
        liveTranscriber: LiveTranscriber? = nil
    ) {
        self.database = database
        self.recorder = recorder
        self.pipeline = pipeline
        self.detector = detector
        self.audioDeviceManager = audioDeviceManager
        self.liveTranscriber = liveTranscriber
    }

    // MARK: - Public API

    /// Set the state change callback. Called after every valid transition.
    func setOnStateChange(_ callback: (@Sendable (RecordingState) -> Void)?) {
        self.onStateChange = callback
    }

    func setOnPipelineStepChange(_ callback: (@Sendable (PipelineStep) -> Void)?) {
        self.onPipelineStepChange = callback
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
    func start() async {
        // Forward pipeline step changes to AppState via callback
        let stepCallback = onPipelineStepChange
        await pipeline.setOnStepChange { _, step in
            stepCallback?(step)
        }

        // Auto-detection of ongoing meetings (audio process / mic / window monitors)
        // is intentionally disabled — recording is always user-initiated. The detector
        // instance remains so calendar-event signals forwarded via forwardSignal fire
        // notification prompts directly through the detector's calendar special-case
        // (it bypasses the dormant DecisionEngine, which requires >=2 active signals).
        // The audio/mic/window monitors do not run.
        logger.info("RecordingCoordinator started (auto-record disabled)")
    }

    /// Stop the recorder if a recording is in progress.
    ///
    /// Shutdown helper — by design this bypasses the normal live-transcription
    /// teardown (no liveTranscriber.stop() here). recorder.stop()'s finalize clears
    /// the onSamples tee itself before its final drain, so the display-only live
    /// transcriber is left to be torn down by the regular stop/error paths or by
    /// process exit; no tee outlives this call.
    func stop() {
        if case .recording = state {
            recorder.stop()
        }
        logger.info("RecordingCoordinator stopped")
    }

    // MARK: - Test Support

    #if DEBUG
    /// Whether the live-transcription sample tee is currently attached to the
    /// recorder. Actor-isolated so the recorder stays confined to this domain;
    /// lets tests assert tee attach/detach without sharing the recorder.
    var isLiveTeeAttached: Bool {
        recorder.onSamples != nil
    }
    #endif

    // MARK: - Convenience

    /// Convenience method to stop an active recording.
    func stopRecording() async {
        await handle(.meetingEnded)
    }

    /// Convenience method to retry a failed transcription.
    func retryTranscription(meetingId: String) async {
        await handle(.retryRequested(meetingId: meetingId))
    }

    /// Start a manual recording (bypasses MeetingDetector).
    func startManualRecording(title: String = "Manual Recording") async {
        await handle(.manualStart(title: title))
    }

    /// Stop a manual recording explicitly.
    func stopManualRecording() async {
        await handle(.manualStop)
    }

    /// Set a callback for calendar-based meeting prompts on the detector.
    func setOnMeetingPrompt(_ callback: (@Sendable (_ title: String, _ eventID: String?) -> Void)?) {
        detector.onMeetingPrompt = callback
    }

    /// Forward an external detection signal (e.g., Google Calendar) to the detector.
    func forwardSignal(_ signal: DetectionSignal) {
        detector.handleSignal(signal)
    }

    /// Switch the input device for the in-flight recording. No-op unless state is
    /// `.recording`. Bypasses the reducer because the state doesn't change — only
    /// the audio source mid-stream — and the underlying `AudioRecorder` handles
    /// its own rollback on failure.
    func switchInputDevice(deviceUID: String?) async {
        guard case .recording = state else {
            logger.warning("switchInputDevice ignored in state \(String(describing: self.state))")
            return
        }
        do {
            try recorder.switchDevice(deviceUID: deviceUID)
        } catch {
            // AudioRecorder logs the specifics; here we just surface a notification
            // and (for the catastrophic case) let the disconnect callback finalize.
            logger.error("switchInputDevice surfaced error: \(error.localizedDescription)")
        }
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
            // DATA-01: DB insert failure aborts recording.
            // Error is logged and state transitions to .error -> user sees idle status.
            // Note: Since the meeting record doesn't exist in DB, executeNotifyError's
            // UPDATE will affect 0 rows. This is safe. User notification via Phase 8 (UX-03).
            logger.error("Failed to insert meeting record: \(error.localizedDescription)")
            await handle(.recordingFailed(error))
            return
        }

        let wavPath = AudioFileManager.wavPath(for: meetingId)
        do {
            // Single source of truth: whatever input device the user selected
            // (or system default if none). Same path for manual and auto-detected
            // recordings — the meeting metadata (title, app) differs but the
            // audio source is always the user's chosen device.
            let selectedDeviceUID: String? = await MainActor.run { audioDeviceManager?.selectedDeviceUID }
            logger.info("Starting recorder for \(meetingId): device=\(selectedDeviceUID ?? "system-default") title=\"\(meeting.title)\" path=\(wavPath.lastPathComponent)")

            try recorder.start(outputPath: wavPath, deviceUID: selectedDeviceUID)
            recorder.onDeviceDisconnected = { [self] in
                Task { await self.handle(.deviceDisconnected) }
            }

            // Live transcription: display-only side effect of entering .recording.
            // The engine already owns its ASR models. Start failures are logged
            // inside LiveTranscriber and swallowed — recording proceeds with no
            // live text. onSamples fires on the main thread from the recorder's
            // periodic flush timer (DispatchSource on .main), so the assumeIsolated
            // hop is safe — LiveTranscriber.feed is @MainActor. The final drain never
            // tees: the recorder clears onSamples before its final flushRingBuffer().
            if let liveTranscriber {
                await liveTranscriber.start()
                // Strong capture of liveTranscriber is intentional: every termination
                // path (stop, error, device-disconnect, and the recorder's own
                // finalize) detaches onSamples, so the closure is short-lived and
                // never forms a retain cycle back to the coordinator.
                recorder.onSamples = { samples in
                    MainActor.assumeIsolated {
                        liveTranscriber.feed(samples: samples)
                    }
                }
            }

            NotificationManager.recordingStarted(title: meeting.title)
            logger.info("Recording started for meeting \(meetingId)")
        } catch {
            logger.error("Failed to start recording \(meetingId): \(error.localizedDescription) (\(String(describing: error)))")
            await handle(.recordingFailed(error))
        }
    }

    private func executeStopAndTranscribe(meetingId: String) async {
        recorder.onDeviceDisconnected = nil  // Clear before stop to avoid re-entrant disconnect
        recorder.onSamples = nil             // Detach live tee before stopping capture
        recorder.stop()
        await liveTranscriber?.stop()        // Cancel streaming before batch pipeline (no ANE contention)

        let endTime = ISO8601DateFormatter().string(from: Date())

        // Set end_time only. The pipeline owns the status transition to .transcribing
        // (see TranscriptionPipeline.processJob -> updateMeetingStatus). Updating status
        // here would cause pipeline.enqueue() to reject as a duplicate (.transcribing).
        do {
            try await database.dbWriter.write { dbConn in
                try dbConn.execute(
                    sql: "UPDATE meetings SET end_time = ? WHERE meeting_id = ?",
                    arguments: [endTime, meetingId]
                )
            }
        } catch {
            logger.error("Failed to update meeting end_time: \(error.localizedDescription)")
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

        let title = await fetchMeetingTitle(meetingId: meetingId)
        NotificationManager.transcriptionComplete(title: title)
    }

    // Note: If called for a meeting that was never inserted (e.g., DATA-01 DB insert
    // failure), the UPDATE will affect 0 rows. This is safe -- the error is still
    // logged and the state machine transitions correctly to .error -> .idle.
    private func executeNotifyError(meetingId: String, error: Error) async {
        recorder.onSamples = nil          // Tear down live tee on the error path too
        await liveTranscriber?.stop()
        logger.error("Meeting \(meetingId) ended in error state: \(error.localizedDescription)")
        do {
            try await database.dbWriter.write { dbConn in
                try dbConn.execute(
                    sql: "UPDATE meetings SET status = ?, error = ? WHERE meeting_id = ?",
                    arguments: [MeetingStatus.error.rawValue, error.localizedDescription, meetingId]
                )
            }
            logger.info("Updated meeting \(meetingId) status=error in DB")
        } catch {
            logger.error("Failed to update meeting \(meetingId) error status: \(error.localizedDescription)")
        }

        let title = await fetchMeetingTitle(meetingId: meetingId)
        NotificationManager.transcriptionError(title: title, error: error.localizedDescription)
    }

    private func fetchMeetingTitle(meetingId: String) async -> String {
        do {
            return try await database.dbWriter.read { dbConn in
                try Meeting.filter(Column("meeting_id") == meetingId)
                    .fetchOne(dbConn)?.title ?? "Meeting"
            }
        } catch {
            logger.warning("Failed to fetch title for notification: \(error.localizedDescription)")
            return "Meeting"
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

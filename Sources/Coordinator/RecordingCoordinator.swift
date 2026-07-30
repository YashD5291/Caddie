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

    /// Vends a fresh capture engine for each meeting. nil when screen recording is
    /// off (the default), which makes every video code path inert.
    ///
    /// A FACTORY, not an instance, because `ScreenRecorder` is single-use: `start()`
    /// guards `state == .idle` and `transition(.stopped, .started) == .stopped`, so a
    /// second `start()` on the same object logs a warning and returns WITHOUT throwing.
    /// One shared instance would therefore record nothing from meeting #2 onward, with
    /// no error anywhere — precisely the silent failure this project forbids. A fresh
    /// engine per meeting also makes the callback assignment correct by construction
    /// (each engine's callbacks are set before its own `start`), and lets the engine's
    /// defensive `deinit` finalize act as a second safety net for the file.
    private let screenRecorderFactory: ScreenRecorderFactory?

    // MARK: - Callbacks

    private var onStateChange: (@Sendable (RecordingState) -> Void)?
    private var onPipelineStepChange: (@Sendable (PipelineStep) -> Void)?

    /// Dedicated NON-FATAL channel for video failures (VID-04).
    ///
    /// Video failures must never drive the coordinator into `.error` — that would abort
    /// the meeting, exactly what VID-04 forbids. And they must not reuse
    /// AppState's fatal recording-error surface, which renders "Last recording failed"
    /// for a meeting whose audio and transcript succeeded. Hence a separate channel
    /// with honest copy.
    private var onVideoError: (@Sendable (String) -> Void)?

    // MARK: - In-flight Video State

    /// Video context for the meeting currently being recorded. nil when no video is
    /// in flight (feature off, start failed, or the meeting ended).
    private struct VideoContext {
        let meetingId: String
        let outputURL: URL
        /// The engine writing this meeting's video.
        ///
        /// nil ONLY while the start call is still in flight. The context is published
        /// before `start()` so an early first frame has somewhere to land, but the engine
        /// itself cannot be stored that early: under Swift 6 region isolation, writing the
        /// non-Sendable engine into actor state merges it into this actor's region, which
        /// makes the subsequent `await recorder.start(...)` an illegal cross-domain send.
        /// It is attached the instant start returns, and 19-03's teardown joins
        /// `videoStartTask` first — so by the time anything needs it, it is non-nil.
        var recorder: ScreenRecording?
        /// Mach host ticks sampled the instant audio capture started —
        /// the audio half of the STOR-04 anchor pair.
        let audioStartTicks: UInt64
        /// Host ticks of the first written video frame, from `onFirstFrameHostTime`.
        var firstFrameTicks: UInt64?
        /// Set when SCK reports the stream died mid-meeting. The context is deliberately
        /// KEPT so teardown still finalizes the partial (playable) file.
        var streamDied: Bool = false
    }

    private var videoContext: VideoContext?
    private var videoStartTask: Task<Void, Never>?

    private let logger = Logger(subsystem: "com.caddie.app", category: "RecordingCoordinator")

    // MARK: - Init

    init(
        database: AppDatabase,
        recorder: AudioRecorder,
        pipeline: TranscriptionPipeline,
        detector: MeetingDetector,
        audioDeviceManager: AudioDeviceManager? = nil,
        liveTranscriber: LiveTranscriber? = nil,
        screenRecorderFactory: ScreenRecorderFactory? = nil
    ) {
        self.database = database
        self.recorder = recorder
        self.pipeline = pipeline
        self.detector = detector
        self.audioDeviceManager = audioDeviceManager
        self.liveTranscriber = liveTranscriber
        self.screenRecorderFactory = screenRecorderFactory
    }

    // MARK: - Public API

    /// Set the state change callback. Called after every valid transition.
    func setOnStateChange(_ callback: (@Sendable (RecordingState) -> Void)?) {
        self.onStateChange = callback
    }

    func setOnPipelineStepChange(_ callback: (@Sendable (PipelineStep) -> Void)?) {
        self.onPipelineStepChange = callback
    }

    /// Set the non-fatal video-error callback (VID-04). Fires for every screen-capture
    /// failure — start throw, mid-meeting stream death, stop failure — while the audio
    /// recording carries on to normal completion.
    ///
    /// Deliberately separate from the recording-error path: a video failure must never
    /// drive the coordinator into `.error` (that would abort a meeting whose audio is
    /// fine), and it must never write AppState's fatal recording-error surface, which
    /// the menu bar renders as "Last recording failed" — false for a meeting that
    /// recorded and transcribed just fine.
    func setOnVideoError(_ callback: (@Sendable (String) -> Void)?) {
        self.onVideoError = callback
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

    /// Whether a healthy video capture is in flight for the current meeting.
    /// False once SCK reports a stream death, even though the engine's own
    /// `isRecording` keeps returning true after that (it lies — see 19-RESEARCH).
    var isVideoActive: Bool {
        videoContext.map { !$0.streamDied } ?? false
    }

    /// The STOR-04 anchor pair for the in-flight meeting: audio-start host ticks and
    /// (once the first frame is written) the first-frame host ticks.
    var videoAnchorPair: (audio: UInt64, firstFrame: UInt64?)? {
        videoContext.map { ($0.audioStartTicks, $0.firstFrameTicks) }
    }

    /// The `.mov` URL the in-flight capture is writing to.
    var videoOutputURL: URL? {
        videoContext?.outputURL
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
            let audioStartTicks = mach_absolute_time()  // STOR-04 anchor, audio half
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

            // Video is subordinate to audio: it starts only once audio is genuinely
            // running, and nothing in the video path can precede, gate, or fail the
            // audio start (VID-03 / VID-04).
            startVideo(meetingId: meetingId, audioStartTicks: audioStartTicks)

            NotificationManager.recordingStarted(title: meeting.title)
            logger.info("Recording started for meeting \(meetingId)")
        } catch {
            logger.error("Failed to start recording \(meetingId): \(error.localizedDescription) (\(String(describing: error)))")
            await handle(.recordingFailed(error))
        }
    }

    // MARK: - Video Capture (VID-03 start half, VID-04 containment)

    /// Kick off screen capture for this meeting. Synchronous by design: it schedules
    /// the work and returns immediately.
    ///
    /// Awaiting ScreenCaptureKit setup inline would suspend this actor for ~215 ms
    /// (measured in 18-04, dominated by `SCShareableContent` enumeration; a TCC prompt
    /// makes it far longer). During that suspension the actor is free to process a
    /// `.manualStop`, whose teardown would run while the start is still in flight —
    /// orphaning a running capture with no owner. Holding the work in an unstructured
    /// `Task` created in actor context (which inherits this actor's isolation) lets
    /// 19-03's `stopVideo()` join it before stopping, closing that window without ever
    /// stalling the audio start path.
    private func startVideo(meetingId: String, audioStartTicks: UInt64) {
        guard screenRecorderFactory != nil else { return }
        videoStartTask = Task {
            await self.startVideoInner(meetingId: meetingId, audioStartTicks: audioStartTicks)
        }
    }

    private func startVideoInner(meetingId: String, audioStartTicks: UInt64) async {
        guard let screenRecorderFactory else { return }

        let recorder = screenRecorderFactory()
        let url = AudioFileManager.videoPath(for: meetingId)

        // Both callbacks MUST be assigned BEFORE start(): the engine's WriterSink is
        // constructed with the CURRENT values of these closures, so assigning after
        // start() is a silent no-op — no anchor, and no mid-meeting death signal.
        recorder.onFirstFrameHostTime = { [weak self] ticks in
            Task { await self?.recordFirstFrameAnchor(ticks) }
        }
        recorder.onStreamStopped = { [weak self] error in
            Task { await self?.handleVideoStreamStopped(error) }
        }

        // Publish the context BEFORE starting, so a first frame delivered during the
        // start call still finds somewhere to record its anchor.
        videoContext = VideoContext(
            meetingId: meetingId,
            outputURL: url,
            recorder: nil,
            audioStartTicks: audioStartTicks
        )

        do {
            // Phase 21 owns the user-facing target/preset choice; `.display(nil)` and
            // `.balanced` are the interim defaults. Constructed at the call site, so the
            // non-Sendable CaptureTarget is a disconnected region — no isolation problem.
            try await recorder.start(target: .display(nil), preset: .balanced, outputURL: url)

            guard videoContext?.meetingId == meetingId else {
                // Teardown raced ahead of this start. 19-03 joins videoStartTask before
                // stopping, so this is belt-and-braces — but a capture with no owner
                // would keep writing forever, so stop it rather than leak it.
                logger.warning("Screen capture start landed after teardown for \(meetingId) — stopping orphan")
                await recorder.stop()
                return
            }
            videoContext?.recorder = recorder
            logger.info("Screen capture started for \(meetingId) -> \(url.lastPathComponent)")
        } catch {
            // VID-04: log, surface, and CONTINUE. This must never raise the
            // recording-failed event — that would kill audio capture that is fine.
            logger.error("Screen capture failed to start for \(meetingId): \(error.localizedDescription)")
            surfaceVideoError("Screen recording unavailable — audio is still recording: \(error.localizedDescription)")
            videoContext = nil
        }
    }

    /// Video half of the STOR-04 anchor pair. Phase 20 persists this pair to the
    /// meetings row; Phase 19 holds it in memory and logs the derived offset.
    private func recordFirstFrameAnchor(_ ticks: UInt64) {
        guard var ctx = videoContext else { return }
        ctx.firstFrameTicks = ticks
        videoContext = ctx

        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let offset = ScreenRecorder.hostTicksToSeconds(ticks, timebase: timebase)
                   - ScreenRecorder.hostTicksToSeconds(ctx.audioStartTicks, timebase: timebase)
        logger.info("Video anchor for \(ctx.meetingId): audioTicks=\(ctx.audioStartTicks) firstFrameTicks=\(ticks) offset=\(offset, format: .fixed(precision: 3))s")
    }

    /// Authoritative mid-meeting death signal (window closed, SCK error -3821). The
    /// engine's own `isRecording` still reports true after this, so never key on it.
    ///
    /// The context is deliberately KEPT: teardown must still finalize the partial file,
    /// which is playable per VID-07, and the engine's `stop()` is a safe no-op after a
    /// stream error.
    private func handleVideoStreamStopped(_ error: Error?) {
        let detail = error?.localizedDescription ?? "stream ended unexpectedly"

        guard var ctx = videoContext else {
            // No capture in flight: the start already failed (and already surfaced), or
            // the meeting ended and this is the engine's own teardown notification.
            // Logged rather than dropped so the sequence stays readable in the log.
            logger.info("Screen capture stream stopped with no in-flight capture: \(detail)")
            return
        }
        ctx.streamDied = true
        videoContext = ctx

        logger.error("Screen capture stream stopped for \(ctx.meetingId): \(detail)")
        surfaceVideoError("Screen recording stopped — audio is still recording (\(detail))")
    }

    /// The single exit for every video failure. Logs and hands the message to the
    /// dedicated non-fatal channel. Never throws, never touches `state`, never calls
    /// `handle` — a degraded recording is still a working recording.
    private func surfaceVideoError(_ message: String) {
        logger.error("Video error surfaced: \(message)")
        onVideoError?(message)
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

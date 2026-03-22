import Foundation
import GRDB
import os

// MARK: - PipelineError

enum PipelineError: Error, LocalizedError {
    case duplicateEnqueue(meetingId: String, status: MeetingStatus)
    case queueFull(depth: Int)

    var errorDescription: String? {
        switch self {
        case .duplicateEnqueue(let id, let status):
            return "Meeting \(id) already has status \(status.rawValue) -- rejecting duplicate enqueue"
        case .queueFull(let depth):
            return "Transcription queue full (\(depth) jobs) -- rejecting enqueue"
        }
    }
}

/// Queued actor that processes transcription jobs one at a time.
/// Pipeline: Mono Mixdown -> ASR -> Diarize -> Merge -> Write DB -> Compress -> Done -> Delete WAV
actor TranscriptionPipeline {

    private let logger = Logger(subsystem: "com.caddie.app", category: "TranscriptionPipeline")

    private let asrEngine: any ASREngineProtocol
    private let diarizationEngine: any DiarizationEngineProtocol

    private var queue: [(meetingId: String, database: AppDatabase?, onComplete: (@Sendable (String, Result<Void, Error>) -> Void)?)] = []
    private var isProcessing = false

    // DATA-08: Bounded queue depth
    private static let maxQueueDepth = 50

    init(asr: any ASREngineProtocol, diarization: any DiarizationEngineProtocol) {
        self.asrEngine = asr
        self.diarizationEngine = diarization
    }

    /// Enqueues a meeting for transcription processing.
    /// Rejects duplicates (.transcribing/.done) and overflows (>= 50 pending).
    /// - Parameters:
    ///   - meetingId: The meeting identifier.
    ///   - database: Optional database for status updates.
    ///   - onComplete: Optional callback fired with (meetingId, result) when pipeline finishes.
    func enqueue(
        meetingId: String,
        database: AppDatabase? = nil,
        onComplete: (@Sendable (String, Result<Void, Error>) -> Void)? = nil
    ) async {
        // DATA-08: Bounded queue
        guard queue.count < Self.maxQueueDepth else {
            logger.warning("Queue full (\(self.queue.count) jobs), rejecting \(meetingId)")
            onComplete?(meetingId, .failure(PipelineError.queueFull(depth: queue.count)))
            return
        }

        // DATA-07: Duplicate rejection -- skip if DB not provided (legacy/test compat)
        if let db = database {
            let currentStatus: MeetingStatus?
            do {
                currentStatus = try await db.dbWriter.read { dbConn in
                    try Meeting.filter(Column("meeting_id") == meetingId)
                        .fetchOne(dbConn)?.status
                }
            } catch {
                logger.warning("Failed to check duplicate status for \(meetingId): \(error.localizedDescription)")
                currentStatus = nil
            }
            if let status = currentStatus, status == .transcribing || status == .done {
                logger.warning("Meeting \(meetingId) already \(status.rawValue), rejecting duplicate")
                onComplete?(meetingId, .failure(PipelineError.duplicateEnqueue(meetingId: meetingId, status: status)))
                return
            }
        }

        queue.append((meetingId, database, onComplete))
        logger.info("Enqueued meeting \(meetingId) for transcription (queue depth: \(self.queue.count))")

        if !isProcessing {
            Task { await processNext() }
        }
    }

    // MARK: - Private

    private func processNext() async {
        guard !isProcessing, !queue.isEmpty else { return }

        isProcessing = true
        let job = queue.removeFirst()
        let meetingId = job.meetingId
        let database = job.database
        let onComplete = job.onComplete

        logger.info("Starting transcription pipeline for meeting \(meetingId)")
        let startTime = CFAbsoluteTimeGetCurrent()

        await updateMeetingStatus(meetingId: meetingId, status: .transcribing, database: database)

        do {
            let wavURL = AudioFileManager.wavPath(for: meetingId)

            // Step 1: Create mono mixdown
            logger.info("[\(meetingId)] Creating mono mixdown...")
            let monoURL = try AudioFileManager.createMonoMixdown(stereoURL: wavURL)
            logger.info("[\(meetingId)] Mono mixdown created")

            // Step 2: ASR
            logger.info("[\(meetingId)] Running ASR...")
            let (asrSegments, language, duration) = try await asrEngine.transcribe(audioURL: monoURL)
            logger.info("[\(meetingId)] ASR complete: \(asrSegments.count) segments, language=\(language)")

            // Step 3: Diarization
            logger.info("[\(meetingId)] Running diarization...")
            let speakerSegments = try await diarizationEngine.diarize(audioURL: monoURL)
            logger.info("[\(meetingId)] Diarization complete: \(speakerSegments.count) speaker segments")

            // DATA-03: Clean up mono file explicitly after BOTH ASR and diarization complete.
            // Previously used defer{} which ran even if ASR/diarization was still reading the file.
            do {
                try FileManager.default.removeItem(at: monoURL)
            } catch {
                logger.warning("Failed to remove mono temp file \(monoURL.lastPathComponent): \(error.localizedDescription)")
            }

            // Step 4: Merge
            let merged = TranscriptMerger.merge(asr: asrSegments, speakers: speakerSegments)
            let fullText = TranscriptMerger.generateFullText(segments: merged)
            let uniqueSpeakers = Set(merged.map(\.speaker)).count

            let processingTime = CFAbsoluteTimeGetCurrent() - startTime
            let transcript = Transcript(
                language: language,
                duration: duration,
                numSegments: merged.count,
                numSpeakers: uniqueSpeakers,
                processingTimeSeconds: processingTime,
                fullText: fullText,
                segments: merged
            )

            logger.info("[\(meetingId)] Transcript merged: \(transcript.numSegments) segments, \(transcript.numSpeakers) speakers")

            // Step 5: Write transcript JSON to DB -- HARD GATE (DATA-02)
            // If this fails, preserve ALL source files for retry.
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let transcriptJSON = try encoder.encode(transcript)
            let transcriptString = String(data: transcriptJSON, encoding: .utf8)

            if let db = database {
                try await db.dbWriter.write { dbConn in
                    try dbConn.execute(
                        sql: "UPDATE meetings SET transcript = ? WHERE meeting_id = ?",
                        arguments: [transcriptString, meetingId]
                    )
                }
            }

            // Step 6: Compress WAV to ALAC
            logger.info("[\(meetingId)] Compressing to ALAC...")
            let alacURL = AudioFileManager.alacPath(for: meetingId)
            try AudioFileManager.compressToALAC(wavURL: wavURL, outputURL: alacURL)
            logger.info("[\(meetingId)] ALAC compression complete")

            // Step 7: Update status to done
            await updateMeetingStatus(meetingId: meetingId, status: .done, database: database)

            // DATA-04: Delete WAV only after ALAC compression succeeded AND status is .done
            do {
                try FileManager.default.removeItem(at: wavURL)
            } catch {
                logger.warning("Failed to remove stereo WAV \(wavURL.lastPathComponent): \(error.localizedDescription)")
            }
            logger.info("[\(meetingId)] Stereo WAV deleted")

            logger.info("[\(meetingId)] Pipeline complete in \(String(format: "%.1f", processingTime))s")

            onComplete?(meetingId, .success(()))

        } catch {
            // On failure: do NOT delete mono or WAV -- they must survive for retry.
            // Mono was already cleaned up after step 3 if ASR+diarization completed.
            // WAV must ALWAYS survive on error for retry capability.
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            logger.error("[\(meetingId)] Pipeline failed after \(String(format: "%.1f", elapsed))s: \(error.localizedDescription)")

            if let db = database {
                do {
                    try await db.dbWriter.write { dbConn in
                        try dbConn.execute(
                            sql: "UPDATE meetings SET status = ?, error = ? WHERE meeting_id = ?",
                            arguments: [MeetingStatus.error.rawValue, error.localizedDescription, meetingId]
                        )
                    }
                } catch {
                    logger.error("[\(meetingId)] Failed to write error status to DB: \(error.localizedDescription)")
                }
            }

            onComplete?(meetingId, .failure(error))
        }

        isProcessing = false

        if !queue.isEmpty {
            await processNext()
        }
    }

    private func updateMeetingStatus(meetingId: String, status: MeetingStatus, database: AppDatabase?) async {
        guard let db = database else { return }
        do {
            try await db.dbWriter.write { dbConn in
                try dbConn.execute(
                    sql: "UPDATE meetings SET status = ? WHERE meeting_id = ?",
                    arguments: [status.rawValue, meetingId]
                )
            }
        } catch {
            logger.error("[\(meetingId)] Failed to update status to \(status.rawValue): \(error.localizedDescription)")
        }
    }
}

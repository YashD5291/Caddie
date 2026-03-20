import SwiftUI
import Observation
import os

enum AppStatus: String {
    case idle
    case recording
    case transcribing
}

@Observable
final class AppState {
    var status: AppStatus = .idle
    var currentMeetingTitle: String?
    var recordingStartTime: Date?
    var transcriptionProgress: Double = 0
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    var recordingDuration: TimeInterval {
        guard let start = recordingStartTime else { return 0 }
        return Date().timeIntervalSince(start)
    }

    // MARK: - Engines

    private(set) var database: AppDatabase?
    private(set) var modelManager = ModelManager()
    private let detector = MeetingDetector()
    private let recorder = AudioRecorder()
    private var pipeline: TranscriptionPipeline?
    private var currentMeetingId: String?

    private let logger = Logger(subsystem: "com.caddie.app", category: "AppState")

    var isInitialized = false
    var initError: String?

    // MARK: - Lifecycle

    func initialize() async {
        guard !isInitialized else { return }
        do {
            database = try AppDatabase()
            try AudioFileManager.ensureDirectoryExists()

            // 1. Download models (FluidAudio handles caching — instant if already downloaded)
            await modelManager.downloadModelsIfNeeded()

            if let downloadError = modelManager.downloadError {
                initError = "Model download failed: \(downloadError)"
                logger.error("Model download failed: \(downloadError)")
                return
            }

            // 2. Initialize ASR engine
            let asrEngine = ASREngine()
            if let asrModels = modelManager.asrModels {
                try await asrEngine.initialize(models: asrModels)
            }

            // 3. Initialize diarization engine
            let diarizationEngine = DiarizationEngine()
            if let diarizer = modelManager.diarizer {
                try await diarizationEngine.initialize(diarizer: diarizer)
            }

            // 4. Create pipeline with injected engines
            pipeline = TranscriptionPipeline(asr: asrEngine, diarization: diarizationEngine)

            // 5. Start detection
            detector.onMeetingStarted = { [weak self] meeting in
                self?.startRecording(meeting: meeting)
            }
            detector.onMeetingEnded = { [weak self] in
                self?.stopRecording()
            }
            detector.start()

            isInitialized = true
            logger.info("AppState initialized with ML pipeline")
        } catch {
            initError = error.localizedDescription
            logger.error("Failed to initialize: \(error.localizedDescription)")
        }
    }

    func retryTranscription(meetingId: String) {
        let wavURL = AudioFileManager.wavPath(for: meetingId)
        guard FileManager.default.fileExists(atPath: wavURL.path) else {
            if let db = database {
                do {
                    try db.dbWriter.write { dbConn in
                        try dbConn.execute(
                            sql: "UPDATE meetings SET status = ?, error = ? WHERE meeting_id = ?",
                            arguments: [MeetingStatus.error.rawValue, "Audio file not found", meetingId]
                        )
                    }
                } catch {
                    logger.error("Failed to update meeting error: \(error.localizedDescription)")
                }
            }
            return
        }
        if let db = database {
            do {
                try db.dbWriter.write { dbConn in
                    try dbConn.execute(
                        sql: "UPDATE meetings SET status = ?, error = NULL WHERE meeting_id = ?",
                        arguments: [MeetingStatus.transcribing.rawValue, meetingId]
                    )
                }
            } catch {
                logger.error("Failed to update meeting for retry: \(error.localizedDescription)")
            }
        }
        guard let pipeline = pipeline else {
            logger.error("Cannot retry transcription — pipeline not initialized")
            return
        }
        let db = database
        Task { await pipeline.enqueue(meetingId: meetingId, database: db) }
    }

    func shutdown() {
        detector.stop()
        if status == .recording {
            stopRecording()
        }
        logger.info("AppState shut down")
    }

    // MARK: - Recording Lifecycle

    private func startRecording(meeting: DetectedMeeting) {
        let meetingId = String(UUID().uuidString.prefix(12)).lowercased()
        currentMeetingId = meetingId
        currentMeetingTitle = meeting.title
        recordingStartTime = Date()
        status = .recording

        let now = ISO8601DateFormatter().string(from: Date())
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let today = dateFormatter.string(from: Date())

        var record = Meeting(
            meetingId: meetingId,
            title: meeting.title,
            app: meeting.app,
            date: today,
            startTime: now,
            status: .recording
        )
        record.audioFile = "\(meetingId).m4a"

        if let db = database {
            do {
                try db.dbWriter.write { dbConn in
                    try record.insert(dbConn)
                }
                logger.info("Created meeting record: \(meetingId)")
            } catch {
                logger.error("Failed to insert meeting record: \(error.localizedDescription)")
            }
        }

        let wavPath = AudioFileManager.wavPath(for: meetingId)
        do {
            try recorder.start(outputPath: wavPath, processID: meeting.processId)
            logger.info("Recording started for meeting \(meetingId)")
        } catch {
            logger.error("Failed to start recording: \(error.localizedDescription)")
        }
    }

    func stopRecording() {
        recorder.stop()
        guard let meetingId = currentMeetingId else { return }

        let duration = Int(Date().timeIntervalSince(recordingStartTime ?? Date()))
        let endTime = ISO8601DateFormatter().string(from: Date())

        // Update DB: set end_time, duration_seconds, status='transcribing'
        if let db = database {
            do {
                try db.dbWriter.write { dbConn in
                    try dbConn.execute(
                        sql: """
                            UPDATE meetings
                            SET end_time = ?, duration_seconds = ?, status = ?
                            WHERE meeting_id = ?
                            """,
                        arguments: [endTime, duration, MeetingStatus.transcribing.rawValue, meetingId]
                    )
                }
            } catch {
                logger.error("Failed to update meeting status to transcribing: \(error.localizedDescription)")
            }
        }

        status = .transcribing
        logger.info("Recording stopped for meeting \(meetingId), enqueuing transcription")

        guard let pipeline = pipeline else {
            logger.error("Cannot enqueue transcription — pipeline not initialized")
            return
        }
        let db = database
        Task { await pipeline.enqueue(meetingId: meetingId, database: db) }

        recordingStartTime = nil
        currentMeetingId = nil
    }
}

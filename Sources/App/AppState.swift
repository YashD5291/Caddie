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
    private let detector = MeetingDetector()
    private let recorder = AudioRecorder()
    private let pipeline = TranscriptionPipeline()
    private var currentMeetingId: String?

    private let logger = Logger(subsystem: "com.caddie.app", category: "AppState")

    // MARK: - Lifecycle

    func initialize() throws {
        database = try AppDatabase()
        try AudioFileManager.ensureDirectoryExists()

        detector.onMeetingStarted = { [weak self] meeting in
            self?.startRecording(meeting: meeting)
        }
        detector.onMeetingEnded = { [weak self] in
            self?.stopRecording()
        }
        detector.start()

        logger.info("AppState initialized")
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

        let db = database
        Task { await pipeline.enqueue(meetingId: meetingId, database: db) }

        recordingStartTime = nil
        currentMeetingId = nil
    }
}

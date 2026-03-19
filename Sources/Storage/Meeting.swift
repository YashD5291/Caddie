import Foundation
import GRDB

// MARK: - MeetingStatus

enum MeetingStatus: String, Codable, DatabaseValueConvertible {
    case recording
    case transcribing
    case done
    case error
}

// MARK: - Meeting

struct Meeting: Identifiable {
    var id: Int64?
    var meetingId: String
    var title: String
    var app: String?
    var date: String          // ISO8601 date: "2026-03-19"
    var startTime: String     // ISO8601 datetime
    var endTime: String?
    var durationSeconds: Int?
    var audioFile: String?
    var status: MeetingStatus
    var transcript: String?
    var error: String?
    var createdAt: String     // ISO8601 datetime

    init(
        id: Int64? = nil,
        meetingId: String = UUID().uuidString,
        title: String,
        app: String? = nil,
        date: String,
        startTime: String,
        endTime: String? = nil,
        durationSeconds: Int? = nil,
        audioFile: String? = nil,
        status: MeetingStatus = .recording,
        transcript: String? = nil,
        error: String? = nil,
        createdAt: String = ISO8601DateFormatter().string(from: Date())
    ) {
        self.id = id
        self.meetingId = meetingId
        self.title = title
        self.app = app
        self.date = date
        self.startTime = startTime
        self.endTime = endTime
        self.durationSeconds = durationSeconds
        self.audioFile = audioFile
        self.status = status
        self.transcript = transcript
        self.error = error
        self.createdAt = createdAt
    }
}

// MARK: - Codable

extension Meeting: Codable {
    enum CodingKeys: String, CodingKey {
        case id
        case meetingId = "meeting_id"
        case title
        case app
        case date
        case startTime = "start_time"
        case endTime = "end_time"
        case durationSeconds = "duration_seconds"
        case audioFile = "audio_file"
        case status
        case transcript
        case error
        case createdAt = "created_at"
    }
}

// MARK: - GRDB Record Conformance

extension Meeting: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "meetings"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Queries

extension Meeting {
    /// Full-text search across title, transcript, and app columns via FTS5.
    static func search(_ query: String) -> SQLRequest<Meeting> {
        let escaped = query.replacingOccurrences(of: "\"", with: "\"\"")
        let ftsQuery = "\"\(escaped)\"*"
        return SQLRequest<Meeting>(
            sql: "SELECT meetings.* FROM meetings WHERE id IN (SELECT rowid FROM meetings_fts WHERE meetings_fts MATCH ?)",
            arguments: [ftsQuery]
        )
    }

    /// All meetings ordered by date descending, then start_time descending.
    static func orderedByDate() -> QueryInterfaceRequest<Meeting> {
        Meeting.order(
            Column("date").desc,
            Column("start_time").desc
        )
    }
}

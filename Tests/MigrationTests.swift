import XCTest
import GRDB
@testable import Caddie

final class MigrationTests: XCTestCase {
    var db: AppDatabase!

    override func setUpWithError() throws {
        db = try AppDatabase(inMemory: true)
    }

    // MARK: - Schema Verification

    func testFreshMigrationCreatesAllColumns() throws {
        let columns = try db.dbWriter.read { dbConn in
            try Row.fetchAll(dbConn, sql: "PRAGMA table_info('meetings')")
        }

        let columnNames = columns.map { $0["name"] as String }
        let expected = [
            "id", "meeting_id", "title", "app", "date", "start_time",
            "end_time", "duration_seconds", "audio_file", "status",
            "transcript", "error", "created_at"
        ]

        XCTAssertEqual(columnNames.count, 13, "meetings table should have 13 columns")
        for name in expected {
            XCTAssertTrue(columnNames.contains(name), "Missing column: \(name)")
        }
    }

    // MARK: - Constraints

    func testMeetingIdHasUniqueConstraint() throws {
        try db.dbWriter.write { dbConn in
            try dbConn.execute(sql: """
                INSERT INTO meetings (meeting_id, title, date, start_time, status, created_at)
                VALUES ('dup-id', 'First', '2026-03-22', '2026-03-22T09:00:00Z', 'recording', '2026-03-22T09:00:00Z')
                """)
        }

        XCTAssertThrowsError(try db.dbWriter.write { dbConn in
            try dbConn.execute(sql: """
                INSERT INTO meetings (meeting_id, title, date, start_time, status, created_at)
                VALUES ('dup-id', 'Second', '2026-03-22', '2026-03-22T10:00:00Z', 'recording', '2026-03-22T10:00:00Z')
                """)
        }, "Duplicate meeting_id should throw a constraint error")
    }

    func testStatusDefaultsToRecording() throws {
        try db.dbWriter.write { dbConn in
            try dbConn.execute(sql: """
                INSERT INTO meetings (meeting_id, title, date, start_time, created_at)
                VALUES ('default-status', 'Test', '2026-03-22', '2026-03-22T09:00:00Z', '2026-03-22T09:00:00Z')
                """)
        }

        let status = try db.dbWriter.read { dbConn -> String in
            try String.fetchOne(dbConn, sql: "SELECT status FROM meetings WHERE meeting_id = 'default-status'")!
        }

        XCTAssertEqual(status, "recording")
    }

    // MARK: - Indexes

    func testIndexesExist() throws {
        let indexes = try db.dbWriter.read { dbConn in
            try Row.fetchAll(dbConn, sql: "PRAGMA index_list('meetings')")
        }

        let indexNames = indexes.map { $0["name"] as String }
        XCTAssertTrue(indexNames.contains("idx_meetings_date"), "idx_meetings_date index should exist")
        XCTAssertTrue(indexNames.contains("idx_meetings_status"), "idx_meetings_status index should exist")
    }

    // MARK: - FTS5

    func testFTS5VirtualTableExists() throws {
        let tables = try db.dbWriter.read { dbConn in
            try Row.fetchAll(dbConn, sql: "SELECT name FROM sqlite_master WHERE type='table' AND name='meetings_fts'")
        }

        XCTAssertEqual(tables.count, 1, "meetings_fts FTS5 virtual table should exist")
    }

    func testFTS5TriggerFiresOnInsert() throws {
        try db.dbWriter.write { dbConn in
            try dbConn.execute(sql: """
                INSERT INTO meetings (meeting_id, title, date, start_time, status, transcript, created_at)
                VALUES ('fts-insert', 'Quarterly Review', '2026-03-22', '2026-03-22T09:00:00Z', 'done', 'budget discussion notes', '2026-03-22T09:00:00Z')
                """)
        }

        let results = try db.dbWriter.read { dbConn in
            try Row.fetchAll(dbConn, sql: "SELECT * FROM meetings_fts WHERE meetings_fts MATCH 'budget'")
        }

        XCTAssertEqual(results.count, 1, "FTS5 should find the inserted meeting by transcript content")
    }

    func testFTS5TriggerFiresOnUpdate() throws {
        try db.dbWriter.write { dbConn in
            try dbConn.execute(sql: """
                INSERT INTO meetings (meeting_id, title, date, start_time, status, created_at)
                VALUES ('fts-update', 'Planning', '2026-03-22', '2026-03-22T09:00:00Z', 'recording', '2026-03-22T09:00:00Z')
                """)
        }

        // Verify not searchable by "architecture" yet
        let beforeResults = try db.dbWriter.read { dbConn in
            try Row.fetchAll(dbConn, sql: "SELECT * FROM meetings_fts WHERE meetings_fts MATCH 'architecture'")
        }
        XCTAssertEqual(beforeResults.count, 0)

        // Update transcript
        try db.dbWriter.write { dbConn in
            try dbConn.execute(sql: """
                UPDATE meetings SET transcript = 'discussed architecture patterns' WHERE meeting_id = 'fts-update'
                """)
        }

        let afterResults = try db.dbWriter.read { dbConn in
            try Row.fetchAll(dbConn, sql: "SELECT * FROM meetings_fts WHERE meetings_fts MATCH 'architecture'")
        }
        XCTAssertEqual(afterResults.count, 1, "FTS5 should find the updated transcript content")
    }

    func testFTS5TriggerFiresOnDelete() throws {
        try db.dbWriter.write { dbConn in
            try dbConn.execute(sql: """
                INSERT INTO meetings (meeting_id, title, date, start_time, status, transcript, created_at)
                VALUES ('fts-delete', 'Deletable', '2026-03-22', '2026-03-22T09:00:00Z', 'done', 'unique searchterm xyzzy', '2026-03-22T09:00:00Z')
                """)
        }

        // Verify searchable before delete
        let beforeResults = try db.dbWriter.read { dbConn in
            try Row.fetchAll(dbConn, sql: "SELECT * FROM meetings_fts WHERE meetings_fts MATCH 'xyzzy'")
        }
        XCTAssertEqual(beforeResults.count, 1)

        // Delete
        try db.dbWriter.write { dbConn in
            try dbConn.execute(sql: "DELETE FROM meetings WHERE meeting_id = 'fts-delete'")
        }

        let afterResults = try db.dbWriter.read { dbConn in
            try Row.fetchAll(dbConn, sql: "SELECT * FROM meetings_fts WHERE meetings_fts MATCH 'xyzzy'")
        }
        XCTAssertEqual(afterResults.count, 0, "FTS5 should no longer find deleted meeting")
    }

    // MARK: - Idempotency

    func testMigrationIsIdempotent() throws {
        // Running migrate again on the same DB should not throw
        XCTAssertNoThrow(try AppDatabase.migrate(db.dbWriter),
                         "Running migration a second time should not error (GRDB skips applied migrations)")
    }
}

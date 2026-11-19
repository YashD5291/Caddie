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
            "transcript", "error", "created_at", "video_file", "video_start_offset"
        ]

        XCTAssertEqual(columnNames.count, 15, "meetings table should have 15 columns")
        for name in expected {
            XCTAssertTrue(columnNames.contains(name), "Missing column: \(name)")
        }
    }

    func testVideoColumnsAreNullableWithNoDefault() throws {
        let columns = try db.dbWriter.read { dbConn in
            try Row.fetchAll(dbConn, sql: "PRAGMA table_info('meetings')")
        }
        let byName = Dictionary(uniqueKeysWithValues: columns.map { ($0["name"] as String, $0) })

        let videoFile = try XCTUnwrap(byName["video_file"], "Missing column: video_file")
        XCTAssertEqual(videoFile["type"] as String, "TEXT")
        XCTAssertEqual(videoFile["notnull"] as Int, 0, "video_file must be nullable")
        XCTAssertTrue((videoFile["dflt_value"] as DatabaseValue).isNull, "video_file must have no default")

        let offset = try XCTUnwrap(byName["video_start_offset"], "Missing column: video_start_offset")
        XCTAssertEqual(offset["type"] as String, "DOUBLE")
        XCTAssertEqual(offset["notnull"] as Int, 0, "video_start_offset must be nullable")
        XCTAssertTrue((offset["dflt_value"] as DatabaseValue).isNull, "video_start_offset must have no default")
    }

    func testMigrationsRegisteredInOrder() {
        var migrator = DatabaseMigrator()
        Migrations.run(&migrator)

        XCTAssertEqual(migrator.migrations, ["v1_create_meetings", "v2_add_video_columns"])
    }

    // MARK: - Upgrade Path (STOR-01)

    func testV1DatabaseUpgradesInPlaceAndStaysSearchable() throws {
        let queue = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        Migrations.run(&migrator)
        try migrator.migrate(queue, upTo: "v1_create_meetings")

        try queue.write { dbConn in
            try dbConn.execute(sql: """
                INSERT INTO meetings (meeting_id, title, date, start_time, status, transcript, created_at)
                VALUES ('old-1', 'Quarterly Review', '2026-03-22', '2026-03-22T09:00:00Z', 'done', 'budget talk', '2026-03-22T09:00:00Z')
                """)
        }

        try migrator.migrate(queue)

        let row = try queue.read { dbConn in
            try Row.fetchOne(dbConn, sql: "SELECT video_file, video_start_offset FROM meetings WHERE meeting_id = 'old-1'")
        }
        XCTAssertNotNil(row, "Pre-migration row must survive the upgrade")
        XCTAssertNil(row?["video_file"] as String?)
        XCTAssertNil(row?["video_start_offset"] as Double?)

        let rowCount = try queue.read { dbConn in
            try Int.fetchOne(dbConn, sql: "SELECT COUNT(*) FROM meetings")
        }
        XCTAssertEqual(rowCount, 1)

        let hits = try queue.read { dbConn in
            try Meeting.search("budget").fetchAll(dbConn)
        }
        XCTAssertEqual(hits.count, 1, "FTS must still find pre-migration rows")
    }

    // MARK: - FTS Isolation (STOR-01)

    func testVideoFileIsNeverSearchable() throws {
        try db.dbWriter.write { dbConn in
            try dbConn.execute(sql: """
                INSERT INTO meetings (meeting_id, title, date, start_time, status, created_at, video_file)
                VALUES ('v-1', 'Standup', '2026-03-22', '2026-03-22T09:00:00Z', 'done', '2026-03-22T09:00:00Z', 'zqxjvideo.mov')
                """)
        }

        let filenameHits = try db.dbWriter.read { dbConn in
            try Meeting.search("zqxjvideo").fetchAll(dbConn)
        }
        XCTAssertTrue(filenameHits.isEmpty, "video_file must never be full-text searchable")

        let titleHits = try db.dbWriter.read { dbConn in
            try Meeting.search("Standup").fetchAll(dbConn)
        }
        XCTAssertEqual(titleHits.count, 1, "Positive control: the row itself is indexed")

        let ftsColumns = try db.dbWriter.read { dbConn in
            try Row.fetchAll(dbConn, sql: "PRAGMA table_info(meetings_fts)")
        }.map { $0["name"] as String }
        XCTAssertEqual(ftsColumns, ["title", "transcript", "app"])
    }

    func testVideoColumnUpdateKeepsFTSConsistent() throws {
        try db.dbWriter.write { dbConn in
            try dbConn.execute(sql: """
                INSERT INTO meetings (meeting_id, title, date, start_time, status, transcript, created_at)
                VALUES ('fts-video', 'Design', '2026-03-22', '2026-03-22T09:00:00Z', 'done', 'architecture review', '2026-03-22T09:00:00Z')
                """)
        }

        try db.dbWriter.write { dbConn in
            try dbConn.execute(sql: """
                UPDATE meetings SET video_file = 'fts-video.mov', video_start_offset = 0.27 WHERE meeting_id = 'fts-video'
                """)
        }

        let transcriptHits = try db.dbWriter.read { dbConn in
            try Meeting.search("architecture").fetchAll(dbConn)
        }
        XCTAssertEqual(transcriptHits.count, 1, "Updating video columns must keep the row indexed")

        let filenameHits = try db.dbWriter.read { dbConn in
            try Meeting.search("fts-video.mov").fetchAll(dbConn)
        }
        XCTAssertEqual(filenameHits.count, 0, "The video filename must not become searchable")

        try db.dbWriter.write { dbConn in
            try dbConn.execute(sql: "DELETE FROM meetings WHERE meeting_id = 'fts-video'")
        }

        let afterDeleteHits = try db.dbWriter.read { dbConn in
            try Meeting.search("architecture").fetchAll(dbConn)
        }
        XCTAssertEqual(afterDeleteHits.count, 0, "Deleting the row must remove it from the FTS index")
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

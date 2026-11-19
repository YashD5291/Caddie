import Foundation
import GRDB

enum Migrations {
    static func run(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1_create_meetings") { db in
            // Main meetings table
            try db.create(table: "meetings") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("meeting_id", .text).notNull().unique()
                t.column("title", .text).notNull()
                t.column("app", .text)
                t.column("date", .text).notNull()
                t.column("start_time", .text).notNull()
                t.column("end_time", .text)
                t.column("duration_seconds", .integer)
                t.column("audio_file", .text)
                t.column("status", .text).notNull().defaults(to: "recording")
                t.column("transcript", .text)
                t.column("error", .text)
                t.column("created_at", .text).notNull()
            }

            // Indexes
            try db.create(index: "idx_meetings_date", on: "meetings", columns: ["date"])
            try db.create(index: "idx_meetings_status", on: "meetings", columns: ["status"])

            // FTS5 virtual table
            try db.execute(sql: """
                CREATE VIRTUAL TABLE meetings_fts USING fts5(
                    title,
                    transcript,
                    app,
                    content=meetings,
                    content_rowid=id,
                    tokenize='porter unicode61'
                )
                """)

            // Sync triggers to keep FTS5 in sync with meetings table
            try db.execute(sql: """
                CREATE TRIGGER meetings_ai AFTER INSERT ON meetings BEGIN
                    INSERT INTO meetings_fts(rowid, title, transcript, app)
                    VALUES (new.id, new.title, new.transcript, new.app);
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER meetings_ad AFTER DELETE ON meetings BEGIN
                    INSERT INTO meetings_fts(meetings_fts, rowid, title, transcript, app)
                    VALUES ('delete', old.id, old.title, old.transcript, old.app);
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER meetings_au AFTER UPDATE ON meetings BEGIN
                    INSERT INTO meetings_fts(meetings_fts, rowid, title, transcript, app)
                    VALUES ('delete', old.id, old.title, old.transcript, old.app);
                    INSERT INTO meetings_fts(rowid, title, transcript, app)
                    VALUES (new.id, new.title, new.transcript, new.app);
                END
                """)
        }

        // ADD COLUMN only, so no table rebuild. meetings_fts and its three triggers name
        // title, transcript, app explicitly, so the new columns are never indexed.
        // video_file holds the filename only ("<meetingId>.mov", like audio_file).
        // video_start_offset holds seconds from the audio start to the first video frame
        // (movie time 0), so video time = transcript time - offset.
        // Both are NULL whenever no usable video is linked.
        migrator.registerMigration("v2_add_video_columns") { db in
            try db.alter(table: "meetings") { t in
                t.add(column: "video_file", .text)
                t.add(column: "video_start_offset", .double)
            }
        }
    }
}

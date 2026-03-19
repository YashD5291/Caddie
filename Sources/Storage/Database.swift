import Foundation
import GRDB

struct AppDatabase {
    let dbWriter: any DatabaseWriter

    /// Creates a production database at ~/Library/Application Support/Caddie/caddie.db
    init() throws {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("Caddie", isDirectory: true)

        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)

        let dbPath = appSupport.appendingPathComponent("caddie.db").path
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }
        let pool = try DatabasePool(path: dbPath, configuration: config)
        dbWriter = pool
        try Self.migrate(dbWriter)
    }

    /// Creates an in-memory database for testing.
    init(inMemory: Bool) throws {
        precondition(inMemory, "Use init() for on-disk databases")
        let queue = try DatabaseQueue()
        dbWriter = queue
        try Self.migrate(dbWriter)
    }

    /// Runs all registered migrations.
    static func migrate(_ writer: any DatabaseWriter) throws {
        var migrator = DatabaseMigrator()
        Migrations.run(&migrator)
        try migrator.migrate(writer)
    }
}

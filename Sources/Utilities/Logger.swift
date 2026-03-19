import os
import AppKit

enum CaddieLogger {
    static let subsystem = "com.caddie.app"

    static let app = Logger(subsystem: subsystem, category: "App")
    static let detection = Logger(subsystem: subsystem, category: "Detection")
    static let recording = Logger(subsystem: subsystem, category: "Recording")
    static let transcription = Logger(subsystem: subsystem, category: "Transcription")
    static let storage = Logger(subsystem: subsystem, category: "Storage")

    /// Opens ~/Library/Logs/Caddie/ in Finder, creating it if needed.
    static func showLogs() {
        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Caddie", isDirectory: true)

        // Create the directory if it doesn't exist so Finder has something to open
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        NSWorkspace.shared.open(logsDir)
    }
}

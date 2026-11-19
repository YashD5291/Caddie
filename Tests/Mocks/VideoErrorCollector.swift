import Foundation

/// Collects messages surfaced on the coordinator's video-error channel. The callback
/// fires from the coordinator's actor while the test body reads from the main actor,
/// so the buffer is lock-guarded (same rationale as `MockStreamingEngine`).
final class VideoErrorCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _messages: [String] = []

    func append(_ message: String) {
        lock.withLock { _messages.append(message) }
    }

    var messages: [String] { lock.withLock { _messages } }
}

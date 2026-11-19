import Foundation

/// Records each `onFinalized` fire, optionally with the mock's stop count at that moment.
/// The callback arrives on AVFoundation's completion queue, the writer queue, or an
/// unstructured `Task` while the test body reads from the test executor, so the log is
/// lock-guarded.
final class FinalizeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _stopCountsAtFire: [Int] = []

    /// Records one fire. Pass `stopCount` only when the test asserts on it.
    func record(stopCount: Int = 0) {
        lock.withLock { _stopCountsAtFire.append(stopCount) }
    }

    var stopCountsAtFire: [Int] { lock.withLock { _stopCountsAtFire } }
    var count: Int { stopCountsAtFire.count }
}

import Foundation
@testable import Caddie

/// Error surfaced by forced-failure screen-capture tests, so assertions can match
/// on the message that reaches the user-facing error channel (VID-04).
struct MockScreenRecorderError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// In-memory stand-in for `ScreenRecorder`. Records lifecycle calls and lets a test
/// force every VID-04 failure mode — start throw, mid-meeting stream death, slow stop —
/// without ScreenCaptureKit, a TCC grant, or a real display. Using the real engine in
/// tests would capture the developer's screen; this mock makes that unreachable.
///
/// Thread-safety: the coordinator drives `start`/`stop` from its actor while the test
/// body reads counters from the test executor, and `onStreamStopped` is invoked from
/// whatever context calls `simulateStreamDeath`. Every piece of mutable state is
/// therefore guarded by `lock` — relying on the test executor for serialization is NOT
/// safe here (the same hazard documented in `MockStreamingEngine`).
final class MockScreenRecorder: ScreenRecording, @unchecked Sendable {

    private let lock = NSLock()

    private var _startCallCount = 0
    private var _stopCallCount = 0
    private var _startedURLs: [URL] = []
    private var _startError: Error?
    private var _stopDelay: Duration?

    var startCallCount: Int { lock.withLock { _startCallCount } }
    var stopCallCount: Int { lock.withLock { _stopCallCount } }
    var startedURLs: [URL] { lock.withLock { _startedURLs } }

    /// Forced start failure (VID-04 case 1).
    var startError: Error? {
        get { lock.withLock { _startError } }
        set { lock.withLock { _startError = newValue } }
    }

    /// Forced slow stop (VID-04 case 3): applied BEFORE the stop counter increments,
    /// so a test can observe a stop that is genuinely still in flight.
    var stopDelay: Duration? {
        get { lock.withLock { _stopDelay } }
        set { lock.withLock { _stopDelay = newValue } }
    }

    // MARK: - ScreenRecording

    var onFirstFrameHostTime: (@Sendable (UInt64) -> Void)?
    var onStreamStopped: (@Sendable (Error?) -> Void)?

    var isRecording: Bool { lock.withLock { _startCallCount > _stopCallCount } }

    func start(target: ScreenRecorder.CaptureTarget,
               preset: ScreenRecorder.QualityPreset,
               outputURL: URL) async throws {
        let error: Error? = lock.withLock {
            _startCallCount += 1
            _startedURLs.append(outputURL)
            return _startError
        }
        if let error { throw error }
        // Success path only: gives tests a deterministic STOR-04 anchor with no display.
        onFirstFrameHostTime?(mach_absolute_time())
    }

    func stop() async {
        if let delay = stopDelay {
            try? await Task.sleep(for: delay)
        }
        lock.withLock { _stopCallCount += 1 }
    }

    /// Test hook: simulate SCK error -3821 / window closed mid-meeting (VID-04 case 2).
    func simulateStreamDeath(_ error: Error) {
        onStreamStopped?(error)
    }
}

/// Vends `MockScreenRecorder` instances and remembers every one it handed out, so a
/// test can assert across meetings (e.g. meeting #2 got a fresh recorder and started).
final class MockScreenRecorderFactory: @unchecked Sendable {

    private let lock = NSLock()
    private var _instances: [MockScreenRecorder] = []
    private var _startError: Error?
    private var _stopDelay: Duration?

    /// Applied to every instance vended from now on.
    var startError: Error? {
        get { lock.withLock { _startError } }
        set { lock.withLock { _startError = newValue } }
    }

    /// Applied to every instance vended from now on.
    var stopDelay: Duration? {
        get { lock.withLock { _stopDelay } }
        set { lock.withLock { _stopDelay = newValue } }
    }

    var instances: [MockScreenRecorder] { lock.withLock { _instances } }
    var makeCallCount: Int { lock.withLock { _instances.count } }
    var latest: MockScreenRecorder? { lock.withLock { _instances.last } }
    var totalStartCount: Int { instances.reduce(0) { $0 + $1.startCallCount } }
    var totalStopCount: Int { instances.reduce(0) { $0 + $1.stopCallCount } }

    /// Capturing `self` in a `@Sendable` closure is safe: this class is
    /// `@unchecked Sendable` and every field it touches is lock-guarded.
    var factory: ScreenRecorderFactory {
        { [self] in self.makeRecorder() }
    }

    private func makeRecorder() -> ScreenRecording {
        let recorder = MockScreenRecorder()
        let (error, delay): (Error?, Duration?) = lock.withLock { (_startError, _stopDelay) }
        recorder.startError = error
        recorder.stopDelay = delay
        lock.withLock { _instances.append(recorder) }
        return recorder
    }
}

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
/// and every D-13 finalize timing — late finalize, never finalize, finalize mid-meeting —
/// without ScreenCaptureKit, a TCC grant, or a real display. Using the real engine in
/// tests would capture the developer's screen; this mock makes that unreachable.
///
/// Finalize contract (mirrors the engine): `onFinalized` fires at most once per instance,
/// only after a successful `start`, and never again once it has fired, whether that was
/// from `stop()` or from `simulateFinalize()`.
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
    private var _finalizeDelay: Duration?
    private var _neverFinalize = false
    private var _createsFileOnStart = false
    private var _didStartSuccessfully = false
    private var _didFinalize = false

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

    /// Late finalize: `stop()` returns first and `onFinalized` fires after this delay,
    /// like a `finishWriting` that completes after the coordinator stopped waiting.
    var finalizeDelay: Duration? {
        get { lock.withLock { _finalizeDelay } }
        set { lock.withLock { _finalizeDelay = newValue } }
    }

    /// Never finalize: `stop()` never fires `onFinalized`, modelling app quit or a wedged
    /// finalize. `simulateFinalize()` still fires.
    var neverFinalize: Bool {
        get { lock.withLock { _neverFinalize } }
        set { lock.withLock { _neverFinalize = newValue } }
    }

    /// Writes an empty file at `outputURL` before `startError` is checked, so a failed
    /// start can leave a file behind that the coordinator must clean up.
    var createsFileOnStart: Bool {
        get { lock.withLock { _createsFileOnStart } }
        set { lock.withLock { _createsFileOnStart = newValue } }
    }

    // MARK: - ScreenRecording

    var onFirstFrameHostTime: (@Sendable (UInt64) -> Void)?
    var onStreamStopped: (@Sendable (Error?) -> Void)?
    var onFinalized: (@Sendable () -> Void)?

    var isRecording: Bool { lock.withLock { _startCallCount > _stopCallCount } }

    func start(target: ScreenRecorder.CaptureTarget,
               preset: ScreenRecorder.QualityPreset,
               outputURL: URL) async throws {
        if createsFileOnStart {
            try Data().write(to: outputURL)
        }
        let error: Error? = lock.withLock {
            _startCallCount += 1
            _startedURLs.append(outputURL)
            _didStartSuccessfully = _startError == nil
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

        let (started, never, delay): (Bool, Bool, Duration?) = lock.withLock {
            (_didStartSuccessfully, _neverFinalize, _finalizeDelay)
        }
        // The real engine's stop() is a no-op without a running writer, so a failed or
        // missing start never finalizes.
        guard started, !never else { return }
        if let delay {
            Task {
                try? await Task.sleep(for: delay)
                self.fireFinalizedOnce()
            }
        } else {
            fireFinalizedOnce()
        }
    }

    /// Test hook: simulate SCK error -3821 / window closed mid-meeting (VID-04 case 2).
    func simulateStreamDeath(_ error: Error) {
        onStreamStopped?(error)
    }

    /// Test hook: finalize now, e.g. the mid-meeting finalize that follows a stream death.
    /// A later `stop()` does not fire again.
    func simulateFinalize() {
        fireFinalizedOnce()
    }

    /// Fires `onFinalized` only on the first call, mirroring the engine's idempotency guard.
    /// The callback runs outside the lock so it may read this mock's counters.
    private func fireFinalizedOnce() {
        let alreadyFired: Bool = lock.withLock {
            let fired = _didFinalize
            _didFinalize = true
            return fired
        }
        guard !alreadyFired else { return }
        onFinalized?()
    }
}

/// Vends `MockScreenRecorder` instances and remembers every one it handed out, so a
/// test can assert across meetings (e.g. meeting #2 got a fresh recorder and started).
final class MockScreenRecorderFactory: @unchecked Sendable {

    private let lock = NSLock()
    private var _instances: [MockScreenRecorder] = []
    private var _startError: Error?
    private var _stopDelay: Duration?
    private var _finalizeDelay: Duration?
    private var _neverFinalize = false
    private var _createsFileOnStart = false

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

    /// Applied to every instance vended from now on.
    var finalizeDelay: Duration? {
        get { lock.withLock { _finalizeDelay } }
        set { lock.withLock { _finalizeDelay = newValue } }
    }

    /// Applied to every instance vended from now on.
    var neverFinalize: Bool {
        get { lock.withLock { _neverFinalize } }
        set { lock.withLock { _neverFinalize = newValue } }
    }

    /// Applied to every instance vended from now on.
    var createsFileOnStart: Bool {
        get { lock.withLock { _createsFileOnStart } }
        set { lock.withLock { _createsFileOnStart = newValue } }
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
        let (finalizeDelay, neverFinalize, createsFile): (Duration?, Bool, Bool) = lock.withLock {
            (_finalizeDelay, _neverFinalize, _createsFileOnStart)
        }
        recorder.startError = error
        recorder.stopDelay = delay
        recorder.finalizeDelay = finalizeDelay
        recorder.neverFinalize = neverFinalize
        recorder.createsFileOnStart = createsFile
        lock.withLock { _instances.append(recorder) }
        return recorder
    }
}

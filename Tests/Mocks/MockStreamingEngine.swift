import AVFoundation
import FluidAudio
import Foundation
@testable import Caddie

/// In-memory stand-in for FluidStreamingEngine. Drives the update stream
/// manually so plumbing tests run without CoreML models.
///
/// Thread-safety: `LiveTranscriber.feed` hands buffers off on an unstructured
/// Task whose nonisolated-async `stream(_:)` witness executes on the cooperative
/// pool — concurrently with the @MainActor test body and with other feed Tasks.
/// Every piece of mutable state is therefore guarded by `lock`; relying on the
/// test executor for serialization is NOT safe here (it crashed the suite with
/// "Array replace: subrange extends past the end").
///
/// `waitForBuffers(count:)` lets a test await background hand-offs
/// deterministically instead of sleeping: the awaiting task only resumes once
/// `stream` has appended, and the lock makes the append happen-before the
/// post-await read.
final class MockStreamingEngine: StreamingTranscriptionEngine, @unchecked Sendable {

    private let lock = NSLock()

    private var _startCallCount = 0
    private var _cancelCallCount = 0
    private var _streamedBuffers: [AVAudioPCMBuffer] = []
    private var _startError: Error?
    private var continuation: AsyncStream<(text: String, isConfirmed: Bool)>.Continuation?
    private var bufferWaiters: [(target: Int, resume: () -> Void)] = []

    var startCallCount: Int { lock.withLock { _startCallCount } }
    var cancelCallCount: Int { lock.withLock { _cancelCallCount } }
    var streamedBuffers: [AVAudioPCMBuffer] { lock.withLock { _streamedBuffers } }
    var startError: Error? {
        get { lock.withLock { _startError } }
        set { lock.withLock { _startError = newValue } }
    }

    func start() async throws {
        let error: Error? = lock.withLock {
            _startCallCount += 1
            return _startError
        }
        if let error { throw error }
    }

    func stream(_ buffer: sending AVAudioPCMBuffer) async {
        // Resume waiters outside the lock so their continuations can't re-enter it.
        let ready: [() -> Void] = lock.withLock {
            _streamedBuffers.append(buffer)
            let count = _streamedBuffers.count
            let satisfied = bufferWaiters.filter { count >= $0.target }
            bufferWaiters.removeAll { count >= $0.target }
            return satisfied.map(\.resume)
        }
        ready.forEach { $0() }
    }

    func updates() -> AsyncStream<(text: String, isConfirmed: Bool)> {
        AsyncStream { continuation in
            self.lock.withLock { self.continuation = continuation }
        }
    }

    func cancel() async {
        let cont: AsyncStream<(text: String, isConfirmed: Bool)>.Continuation? = lock.withLock {
            _cancelCallCount += 1
            return continuation
        }
        cont?.finish()
    }

    /// Test hook: push a synthetic update through the stream.
    func emit(text: String, isConfirmed: Bool) {
        let cont = lock.withLock { continuation }
        cont?.yield((text: text, isConfirmed: isConfirmed))
    }

    /// Suspend until at least `count` buffers have been streamed. Deterministic
    /// replacement for polling/sleeping when asserting on background feed Tasks.
    func waitForBuffers(count: Int) async {
        await withCheckedContinuation { (cc: CheckedContinuation<Void, Never>) in
            let alreadySatisfied: Bool = lock.withLock {
                if _streamedBuffers.count >= count { return true }
                bufferWaiters.append((target: count, resume: { cc.resume() }))
                return false
            }
            if alreadySatisfied { cc.resume() }
        }
    }
}

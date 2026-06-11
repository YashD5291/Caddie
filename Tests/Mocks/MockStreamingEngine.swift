import AVFoundation
import FluidAudio
@testable import Caddie

/// In-memory stand-in for FluidStreamingEngine. Drives the update stream
/// manually so plumbing tests run without CoreML models.
// @unchecked Sendable: all mutations happen on the @MainActor test executor.
//
// LiveTranscriber.feed hands buffers off on an unstructured Task, so `stream`
// can be invoked off the main actor. `waitForBuffers(count:)` lets a test await
// those background hand-offs deterministically instead of sleeping: the awaiting
// task only resumes once `stream` has appended (and therefore the append
// happens-before the test's post-await read on the main actor).
final class MockStreamingEngine: StreamingTranscriptionEngine, @unchecked Sendable {
    private(set) var startCallCount = 0
    private(set) var cancelCallCount = 0
    private(set) var streamedBuffers: [AVAudioPCMBuffer] = []
    var startError: Error?

    private var continuation: AsyncStream<(text: String, isConfirmed: Bool)>.Continuation?
    private var bufferWaiters: [(target: Int, resume: () -> Void)] = []

    func start() async throws {
        startCallCount += 1
        if let startError { throw startError }
    }

    func stream(_ buffer: sending AVAudioPCMBuffer) async {
        streamedBuffers.append(buffer)
        let count = streamedBuffers.count
        let ready = bufferWaiters.filter { count >= $0.target }
        bufferWaiters.removeAll { count >= $0.target }
        ready.forEach { $0.resume() }
    }

    func updates() -> AsyncStream<(text: String, isConfirmed: Bool)> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    func cancel() async {
        cancelCallCount += 1
        continuation?.finish()
    }

    /// Test hook: push a synthetic update through the stream.
    func emit(text: String, isConfirmed: Bool) {
        continuation?.yield((text: text, isConfirmed: isConfirmed))
    }

    /// Suspend until at least `count` buffers have been streamed. Deterministic
    /// replacement for polling/sleeping when asserting on background feed Tasks.
    func waitForBuffers(count: Int) async {
        if streamedBuffers.count >= count { return }
        await withCheckedContinuation { continuation in
            bufferWaiters.append((target: count, resume: { continuation.resume() }))
        }
    }
}

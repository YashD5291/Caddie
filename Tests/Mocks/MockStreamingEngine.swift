import AVFoundation
import FluidAudio
@testable import Caddie

/// In-memory stand-in for FluidStreamingEngine. Drives the update stream
/// manually so plumbing tests run without CoreML models.
final class MockStreamingEngine: StreamingTranscriptionEngine, @unchecked Sendable {
    private(set) var startCallCount = 0
    private(set) var cancelCallCount = 0
    private(set) var streamedBuffers: [AVAudioPCMBuffer] = []
    var startError: Error?

    private var continuation: AsyncStream<(text: String, isConfirmed: Bool)>.Continuation?

    func start() async throws {
        startCallCount += 1
        if let startError { throw startError }
    }

    func stream(_ buffer: sending AVAudioPCMBuffer) async {
        streamedBuffers.append(buffer)
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
}

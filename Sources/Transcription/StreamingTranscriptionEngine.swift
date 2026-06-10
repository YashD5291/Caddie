import AVFoundation
import FluidAudio

/// Abstraction over FluidAudio's StreamingAsrManager so LiveTranscriber's
/// update plumbing is unit-testable without loading CoreML models.
/// All members are async because the production conformer is an actor.
protocol StreamingTranscriptionEngine: Sendable {
    /// `models` is optional so the update-plumbing tests can drive the seam with
    /// a mock engine that needs no real CoreML models. The production conformer
    /// requires non-nil models and logs+returns inert if they are absent.
    func start(models: AsrModels?) async throws
    func stream(_ buffer: sending AVAudioPCMBuffer) async
    func updates() -> AsyncStream<(text: String, isConfirmed: Bool)>
    func cancel() async
}

/// Production conformer backing onto FluidAudio's StreamingAsrManager with the
/// low-latency `.streaming` preset. Microphone source (live view never shows
/// system audio separately).
final class FluidStreamingEngine: StreamingTranscriptionEngine, @unchecked Sendable {
    private let manager = StreamingAsrManager(config: .streaming)

    func start(models: AsrModels?) async throws {
        guard let models else {
            CaddieLogger.transcription.warning("FluidStreamingEngine.start skipped: ASR models absent")
            return
        }
        try await manager.start(models: models, source: .microphone)
    }

    func stream(_ buffer: sending AVAudioPCMBuffer) async {
        await manager.streamAudio(buffer)
    }

    func updates() -> AsyncStream<(text: String, isConfirmed: Bool)> {
        AsyncStream { continuation in
            let task = Task { [manager] in
                for await update in await manager.transcriptionUpdates {
                    continuation.yield((text: update.text, isConfirmed: update.isConfirmed))
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    func cancel() async {
        await manager.cancel()
    }
}

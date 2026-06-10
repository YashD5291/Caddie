import AVFoundation
import FluidAudio

/// Abstraction over FluidAudio's StreamingAsrManager so LiveTranscriber's
/// update plumbing is unit-testable without loading CoreML models.
/// All members are async because the production conformer is an actor.
protocol StreamingTranscriptionEngine: Sendable {
    /// No `models` parameter: ASR models are bound at engine construction. AppState
    /// only constructs the engine once bundled models are loaded, so absent-models is
    /// unrepresentable at this layer — matching the spec's failure table ("ASR models
    /// absent → LiveTranscriber never constructed"). This keeps the start contract
    /// optional-free for both the production conformer and test mocks.
    func start() async throws
    func stream(_ buffer: sending AVAudioPCMBuffer) async
    func updates() -> AsyncStream<(text: String, isConfirmed: Bool)>
    func cancel() async
}

/// Production conformer backing onto FluidAudio's StreamingAsrManager with the
/// low-latency `.streaming` preset. Microphone source (live view never shows
/// system audio separately). Models are bound at init.
final class FluidStreamingEngine: StreamingTranscriptionEngine, @unchecked Sendable {
    private let manager = StreamingAsrManager(config: .streaming)
    private let models: AsrModels

    init(models: AsrModels) {
        self.models = models
    }

    func start() async throws {
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

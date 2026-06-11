import AVFoundation
import FluidAudio

/// Production conformer backing onto FluidAudio's StreamingAsrManager with the
/// low-latency `.streaming` preset. Microphone source (live view never shows
/// system audio separately). Models are bound at init.
///
/// @unchecked Sendable: FluidAudio's `StreamingAsrManager` is not declared
/// `Sendable`, so the compiler can't prove this type's safety automatically.
/// It is safe in practice because every access to `manager` goes through `await`
/// onto its own actor, and `models` is immutable after init.
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

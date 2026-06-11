import AVFoundation

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

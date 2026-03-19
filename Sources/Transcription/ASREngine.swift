import Foundation

/// Automatic Speech Recognition engine.
/// Stub implementation — will be replaced with FluidAudio Parakeet SDK.
final class ASREngine {

    enum ASRError: Error {
        case notImplemented(String)
        case modelNotLoaded
        case transcriptionFailed(String)
    }

    func transcribe(audioURL: URL) async throws -> (segments: [ASRSegment], language: String, duration: Double) {
        // TODO: Replace with actual FluidAudio Parakeet API
        throw ASRError.notImplemented("FluidAudio SDK integration pending")
    }
}

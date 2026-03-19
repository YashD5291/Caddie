import Foundation

/// Speaker diarization engine.
/// Stub implementation — will be replaced with FluidAudio pyannote SDK.
final class DiarizationEngine {

    enum DiarizationError: Error {
        case notImplemented(String)
        case modelNotLoaded
        case diarizationFailed(String)
    }

    func diarize(audioURL: URL) async throws -> [SpeakerSegment] {
        // TODO: Replace with actual FluidAudio pyannote API
        throw DiarizationError.notImplemented("FluidAudio SDK integration pending")
    }
}

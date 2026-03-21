import Foundation

/// Contract for speaker diarization engines.
/// Sendable conformance required because TranscriptionPipeline is an actor.
protocol DiarizationEngineProtocol: Sendable {
    func diarize(audioURL: URL) async throws -> [SpeakerSegment]
}

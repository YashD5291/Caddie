import Foundation

/// Contract for ASR (Automatic Speech Recognition) engines.
/// Sendable conformance required because TranscriptionPipeline is an actor.
protocol ASREngineProtocol: Sendable {
    func transcribe(audioURL: URL) async throws -> (segments: [ASRSegment], language: String, duration: Double)
}

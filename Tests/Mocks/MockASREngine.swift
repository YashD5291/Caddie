import Foundation
@testable import Caddie

final class MockASREngine: ASREngineProtocol, @unchecked Sendable {
    var stubbedResult: (segments: [ASRSegment], language: String, duration: Double) = (
        segments: [ASRSegment(start: 0.0, end: 5.0, text: "Hello world")],
        language: "en",
        duration: 5.0
    )
    var stubbedError: Error?
    private(set) var transcribeCallCount = 0
    private(set) var lastAudioURL: URL?

    func transcribe(audioURL: URL) async throws -> (segments: [ASRSegment], language: String, duration: Double) {
        transcribeCallCount += 1
        lastAudioURL = audioURL
        if let error = stubbedError { throw error }
        return stubbedResult
    }
}

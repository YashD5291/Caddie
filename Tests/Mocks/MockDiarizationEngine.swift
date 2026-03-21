import Foundation
@testable import Caddie

final class MockDiarizationEngine: DiarizationEngineProtocol, @unchecked Sendable {
    var stubbedResult: [SpeakerSegment] = [
        SpeakerSegment(start: 0.0, end: 5.0, speaker: "SPEAKER_00")
    ]
    var stubbedError: Error?
    private(set) var diarizeCallCount = 0
    private(set) var lastAudioURL: URL?

    func diarize(audioURL: URL) async throws -> [SpeakerSegment] {
        diarizeCallCount += 1
        lastAudioURL = audioURL
        if let error = stubbedError { throw error }
        return stubbedResult
    }
}

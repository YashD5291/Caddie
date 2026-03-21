import XCTest
@testable import Caddie

final class ProtocolDITests: XCTestCase {

    func testMockASREngineConformsToProtocolAndReturnsCannedSegments() async throws {
        let mock = MockASREngine()
        let result = try await mock.transcribe(audioURL: URL(fileURLWithPath: "/tmp/test.wav"))

        XCTAssertEqual(result.segments.count, 1)
        XCTAssertEqual(result.segments[0].text, "Hello world")
        XCTAssertEqual(result.language, "en")
        XCTAssertEqual(result.duration, 5.0)
        XCTAssertEqual(mock.transcribeCallCount, 1)
    }

    func testMockDiarizationEngineConformsToProtocolAndReturnsCannedSegments() async throws {
        let mock = MockDiarizationEngine()
        let result = try await mock.diarize(audioURL: URL(fileURLWithPath: "/tmp/test.wav"))

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].speaker, "SPEAKER_00")
        XCTAssertEqual(result[0].start, 0.0)
        XCTAssertEqual(result[0].end, 5.0)
        XCTAssertEqual(mock.diarizeCallCount, 1)
    }

    func testTranscriptionPipelineAcceptsProtocolTypedEngines() {
        let mockASR = MockASREngine()
        let mockDiarization = MockDiarizationEngine()

        // This line proves protocol-based init works -- would fail to compile if
        // TranscriptionPipeline still required concrete ASREngine/DiarizationEngine
        let pipeline = TranscriptionPipeline(asr: mockASR, diarization: mockDiarization)
        XCTAssertNotNil(pipeline)
    }
}

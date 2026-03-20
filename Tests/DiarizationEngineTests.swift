import XCTest
@testable import Caddie

final class DiarizationEngineTests: XCTestCase {

    func testMapSegments_normalizesLabels() {
        let input: [(speakerIndex: Int, startTime: Float, endTime: Float)] = [
            (0, 0.0, 5.0),
            (1, 5.0, 10.0),
            (0, 10.0, 15.0)
        ]

        let result = DiarizationEngine.mapToSpeakerSegments(rawSegments: input)

        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0].speaker, "SPEAKER_00")
        XCTAssertEqual(result[1].speaker, "SPEAKER_01")
        XCTAssertEqual(result[2].speaker, "SPEAKER_00")
    }

    func testMapSegments_sortedByStartTime() {
        let input: [(speakerIndex: Int, startTime: Float, endTime: Float)] = [
            (1, 5.0, 10.0),
            (0, 0.0, 5.0),
            (0, 10.0, 15.0)
        ]

        let result = DiarizationEngine.mapToSpeakerSegments(rawSegments: input)

        XCTAssertEqual(result[0].start, 0.0)
        XCTAssertEqual(result[1].start, 5.0)
        XCTAssertEqual(result[2].start, 10.0)
    }

    func testMapSegments_emptyInput() {
        let result = DiarizationEngine.mapToSpeakerSegments(rawSegments: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testMapSegments_floatToDoubleConversion() {
        let input: [(speakerIndex: Int, startTime: Float, endTime: Float)] = [
            (0, 1.5, 3.75)
        ]

        let result = DiarizationEngine.mapToSpeakerSegments(rawSegments: input)

        XCTAssertEqual(result[0].start, 1.5, accuracy: 0.001)
        XCTAssertEqual(result[0].end, 3.75, accuracy: 0.001)
    }
}

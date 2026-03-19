import XCTest
@testable import Caddie

final class TranscriptMergerTests: XCTestCase {

    // MARK: - Merge Tests

    func testSimpleMerge_noOverlap() {
        // Two ASR segments, two speaker segments, no overlap between ASR segments
        let asr = [
            ASRSegment(start: 0.0, end: 3.0, text: "Hello there"),
            ASRSegment(start: 5.0, end: 8.0, text: "How are you")
        ]
        let speakers = [
            SpeakerSegment(start: 0.0, end: 4.0, speaker: "Alice"),
            SpeakerSegment(start: 4.0, end: 9.0, speaker: "Bob")
        ]

        let result = TranscriptMerger.merge(asr: asr, speakers: speakers)

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].speaker, "Alice")
        XCTAssertEqual(result[0].text, "Hello there")
        XCTAssertEqual(result[0].start, 0.0)
        XCTAssertEqual(result[0].end, 3.0)
        XCTAssertEqual(result[1].speaker, "Bob")
        XCTAssertEqual(result[1].text, "How are you")
    }

    func testMerge_overlappingSpeakers() {
        // One ASR segment spanning two speaker segments — picks speaker with more overlap
        // ASR: 2.0 - 7.0 (5 seconds)
        // Alice: 0.0 - 4.0 → overlap with ASR = 2.0 - 4.0 = 2s
        // Bob: 4.0 - 10.0 → overlap with ASR = 4.0 - 7.0 = 3s → Bob wins
        let asr = [
            ASRSegment(start: 2.0, end: 7.0, text: "This spans two speakers")
        ]
        let speakers = [
            SpeakerSegment(start: 0.0, end: 4.0, speaker: "Alice"),
            SpeakerSegment(start: 4.0, end: 10.0, speaker: "Bob")
        ]

        let result = TranscriptMerger.merge(asr: asr, speakers: speakers)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].speaker, "Bob")
        XCTAssertEqual(result[0].text, "This spans two speakers")
    }

    func testMerge_noSpeakerSegments() {
        // ASR segments but empty speaker list → defaults to "Speaker"
        let asr = [
            ASRSegment(start: 0.0, end: 3.0, text: "Hello"),
            ASRSegment(start: 3.0, end: 6.0, text: "World")
        ]
        let speakers: [SpeakerSegment] = []

        let result = TranscriptMerger.merge(asr: asr, speakers: speakers)

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].speaker, "Speaker")
        XCTAssertEqual(result[1].speaker, "Speaker")
    }

    // MARK: - Full Text Generation

    func testFullTextGeneration() {
        // 3 segments with 2 speakers → text has speaker headers, blank lines between speaker changes
        let segments = [
            TranscriptSegment(start: 0.0, end: 3.0, text: "Hello everyone", speaker: "Alice", words: []),
            TranscriptSegment(start: 3.0, end: 6.0, text: "Hi Alice", speaker: "Bob", words: []),
            TranscriptSegment(start: 6.0, end: 9.0, text: "Let's get started", speaker: "Alice", words: [])
        ]

        let fullText = TranscriptMerger.generateFullText(segments: segments)

        let expected = """
        [Alice]
        Hello everyone

        [Bob]
        Hi Alice

        [Alice]
        Let's get started
        """

        XCTAssertEqual(fullText, expected)
    }
}

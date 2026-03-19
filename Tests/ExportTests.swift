import XCTest
@testable import Caddie

final class ExportTests: XCTestCase {

    private let segments = [
        TranscriptSegment(
            start: 0.0,
            end: 5.5,
            text: "Hello everyone, welcome to the meeting.",
            speaker: "SPEAKER_00",
            words: []
        ),
        TranscriptSegment(
            start: 5.5,
            end: 12.0,
            text: "Thanks for joining today.",
            speaker: "SPEAKER_01",
            words: []
        ),
        TranscriptSegment(
            start: 12.0,
            end: 18.3,
            text: "Let's get started with the agenda.",
            speaker: "SPEAKER_00",
            words: []
        ),
    ]

    func testExportTXT() {
        let txt = ExportFormatter.toTXT(segments: segments)
        XCTAssertTrue(txt.contains("[SPEAKER_00]"))
        XCTAssertTrue(txt.contains("[SPEAKER_01]"))
        XCTAssertTrue(txt.contains("Hello everyone, welcome to the meeting."))
        XCTAssertTrue(txt.contains("Thanks for joining today."))
    }

    func testExportSRT() {
        let srt = ExportFormatter.toSRT(segments: segments)
        XCTAssertTrue(srt.contains("1\n"))
        XCTAssertTrue(srt.contains("2\n"))
        XCTAssertTrue(srt.contains("3\n"))
        XCTAssertTrue(srt.contains("00:00:00,000 --> "))
        XCTAssertTrue(srt.contains("00:00:05,500 --> 00:00:12,000"))
        XCTAssertTrue(srt.contains("[SPEAKER_00]"))
        XCTAssertTrue(srt.contains("[SPEAKER_01]"))
    }

    func testExportSRTTimestampFormat() {
        let srt = ExportFormatter.toSRT(segments: segments)
        // Verify SRT format: number, timestamp line, text line, blank line
        let lines = srt.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "1")
        XCTAssertEqual(lines[1], "00:00:00,000 --> 00:00:05,500")
        XCTAssertEqual(lines[2], "[SPEAKER_00] Hello everyone, welcome to the meeting.")
        XCTAssertEqual(lines[3], "")
    }

    func testExportTXTEmptySegments() {
        let txt = ExportFormatter.toTXT(segments: [])
        XCTAssertEqual(txt, "")
    }

    func testExportSRTEmptySegments() {
        let srt = ExportFormatter.toSRT(segments: [])
        XCTAssertEqual(srt, "")
    }
}

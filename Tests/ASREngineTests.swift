import XCTest
@testable import Caddie

final class ASREngineTests: XCTestCase {

    func testGroupTokens_splitOnSentenceEnd() {
        let tokens: [(word: String, start: Double, end: Double)] = [
            ("Hello", 0.0, 0.3),
            (" world.", 0.3, 0.8),
            (" How", 1.0, 1.2),
            (" are", 1.2, 1.4),
            (" you?", 1.4, 1.8)
        ]

        let segments = ASREngine.groupTokensIntoSegments(tokens: tokens)

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].text, "Hello world.")
        XCTAssertEqual(segments[0].start, 0.0)
        XCTAssertEqual(segments[0].end, 0.8)
        XCTAssertEqual(segments[0].words.count, 2)
        XCTAssertEqual(segments[1].text, "How are you?")
        XCTAssertEqual(segments[1].start, 1.0)
        XCTAssertEqual(segments[1].end, 1.8)
        XCTAssertEqual(segments[1].words.count, 3)
    }

    func testGroupTokens_splitOnSilenceGap() {
        let tokens: [(word: String, start: Double, end: Double)] = [
            ("First", 0.0, 0.5),
            (" phrase", 0.5, 1.0),
            (" Second", 2.5, 3.0),
            (" phrase", 3.0, 3.5)
        ]

        let segments = ASREngine.groupTokensIntoSegments(tokens: tokens)

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].text, "First phrase")
        XCTAssertEqual(segments[1].text, "Second phrase")
    }

    func testGroupTokens_splitOnMaxDuration() {
        var tokens: [(word: String, start: Double, end: Double)] = []
        for i in 0..<40 {
            let start = Double(i) * 0.875
            let end = start + 0.5
            tokens.append(("word\(i)", start, end))
        }

        let segments = ASREngine.groupTokensIntoSegments(tokens: tokens)

        XCTAssertGreaterThan(segments.count, 1)
        for segment in segments {
            XCTAssertLessThanOrEqual(segment.end - segment.start, 31.0)
        }
    }

    func testGroupTokens_emptyInput() {
        let segments = ASREngine.groupTokensIntoSegments(tokens: [])
        XCTAssertTrue(segments.isEmpty)
    }

    func testGroupTokens_singleToken() {
        let tokens: [(word: String, start: Double, end: Double)] = [
            ("Hello", 0.0, 0.5)
        ]

        let segments = ASREngine.groupTokensIntoSegments(tokens: tokens)

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].text, "Hello")
        XCTAssertEqual(segments[0].words.count, 1)
    }

    /// Parakeet emits SentencePiece sub-word tokens. FluidAudio normalizes the ▁
    /// (U+2581) word-boundary marker to a leading space on word-start tokens; continuation
    /// tokens have no leading space. Detokenization concatenates and collapses the
    /// markers, e.g. [" play", "ing", " is", " good", "."] → "playing is good."
    func testGroupTokens_subWordTokensDetokenizeCorrectly() {
        let tokens: [(word: String, start: Double, end: Double)] = [
            (" play", 0.0, 0.2),
            ("ing", 0.2, 0.35),
            (" is", 0.35, 0.5),
            (" good", 0.5, 0.7),
            (".", 0.7, 0.75)
        ]

        let segments = ASREngine.groupTokensIntoSegments(tokens: tokens)

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].text, "playing is good.")
    }

    /// Multi-word continuation: "customers" tokenizes as four pieces in real Parakeet
    /// output (` c`, `ust`, `om`, `ers`). Without leading-space-aware joining this
    /// would render as "c ust om ers" — the bug we shipped in the first transcript.
    func testGroupTokens_continuationTokensDoNotInsertSpaces() {
        let tokens: [(word: String, start: Double, end: Double)] = [
            (" c", 0.0, 0.05),
            ("ust", 0.05, 0.15),
            ("om", 0.15, 0.25),
            ("ers", 0.25, 0.4)
        ]

        let segments = ASREngine.groupTokensIntoSegments(tokens: tokens)

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].text, "customers")
    }
}

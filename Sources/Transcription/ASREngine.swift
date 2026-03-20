import Foundation

/// Automatic Speech Recognition engine.
/// Wraps FluidAudio's Parakeet ASR with token-to-segment grouping.
final class ASREngine {

    enum ASRError: Error, LocalizedError {
        case notInitialized
        case modelNotLoaded
        case transcriptionFailed(String)

        var errorDescription: String? {
            switch self {
            case .notInitialized: return "ASR engine not initialized"
            case .modelNotLoaded: return "ASR model not loaded"
            case .transcriptionFailed(let msg): return "Transcription failed: \(msg)"
            }
        }
    }

    private var isReady = false

    /// Initialize with downloaded models. Called once at app startup.
    func initialize() async throws {
        // TODO: Task 5 — wire FluidAudio AsrManager here
        isReady = true
    }

    /// Transcribe audio at the given URL. Returns segments, language, and duration.
    func transcribe(audioURL: URL) async throws -> (segments: [ASRSegment], language: String, duration: Double) {
        guard isReady else { throw ASRError.notInitialized }
        // TODO: Task 5 — call asrManager.transcribe(audioURL) and map results
        throw ASRError.transcriptionFailed("FluidAudio integration pending — see Task 5")
    }

    // MARK: - Token Grouping (Pure Logic — Tested Independently)

    /// Groups per-token timings into sentence-level ASRSegments.
    ///
    /// Splits on:
    /// - Sentence-ending punctuation (. ? !)
    /// - Silence gap > 0.8 seconds between tokens
    /// - Segment duration exceeding 30 seconds
    static func groupTokensIntoSegments(
        tokens: [(word: String, start: Double, end: Double)]
    ) -> [ASRSegment] {
        guard !tokens.isEmpty else { return [] }

        let silenceThreshold = 0.8
        let maxSegmentDuration = 30.0

        var segments: [ASRSegment] = []
        var currentWords: [WordTimestamp] = []
        var segmentStart: Double = tokens[0].start

        for (index, token) in tokens.enumerated() {
            let trimmedWord = token.word.trimmingCharacters(in: .whitespaces)
            currentWords.append(WordTimestamp(word: trimmedWord, start: token.start, end: token.end))

            let isLastToken = index == tokens.count - 1
            let endsWithPunctuation = trimmedWord.last.map { ".?!".contains($0) } ?? false
            let segmentDuration = token.end - segmentStart

            var silenceGap = false
            if !isLastToken {
                let gap = tokens[index + 1].start - token.end
                silenceGap = gap > silenceThreshold
            }

            let shouldSplit = isLastToken
                || endsWithPunctuation
                || silenceGap
                || segmentDuration >= maxSegmentDuration

            if shouldSplit && !currentWords.isEmpty {
                let text = currentWords.map(\.word).joined(separator: " ")
                segments.append(ASRSegment(
                    start: segmentStart,
                    end: token.end,
                    text: text,
                    words: currentWords
                ))
                currentWords = []
                if !isLastToken {
                    segmentStart = tokens[index + 1].start
                }
            }
        }

        return segments
    }
}

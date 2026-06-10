import Foundation
import FluidAudio

/// Automatic Speech Recognition engine.
/// Wraps FluidAudio's Parakeet ASR with token-to-segment grouping.
final class ASREngine: ASREngineProtocol, @unchecked Sendable {

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

    private var asrManager: AsrManager?
    private var isReady = false

    /// Initialize with downloaded ASR models. Called once at app startup.
    func initialize(models: AsrModels) async throws {
        let manager = AsrManager(config: .default)
        try await manager.initialize(models: models)
        self.asrManager = manager
        isReady = true
    }

    /// Transcribe audio at the given URL. Returns segments, language, and duration.
    func transcribe(audioURL: URL) async throws -> (segments: [ASRSegment], language: String, duration: Double) {
        guard isReady, let manager = asrManager else { throw ASRError.notInitialized }

        do {
            let result = try await manager.transcribe(audioURL)

            // Map TokenTiming to our tuple format for the grouping function
            let tokens: [(word: String, start: Double, end: Double)] = (result.tokenTimings ?? []).map { timing in
                (word: timing.token, start: timing.startTime, end: timing.endTime)
            }

            let segments = Self.groupTokensIntoSegments(tokens: tokens)

            // Fallback: if no token timings, single segment from full text
            let finalSegments: [ASRSegment]
            if segments.isEmpty && !result.text.isEmpty {
                finalSegments = [ASRSegment(start: 0, end: result.duration, text: result.text)]
            } else {
                finalSegments = segments
            }

            return (segments: finalSegments, language: "en", duration: result.duration)
        } catch let error as ASRError {
            throw error
        } catch {
            throw ASRError.transcriptionFailed(error.localizedDescription)
        }
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
        // Raw tokens keep the leading-space marker that FluidAudio emits for
        // word-start tokens (the SentencePiece ▁ → " " normalization). We need
        // those markers to detokenize correctly: continuation tokens have no
        // leading space and must concatenate directly. Joining with " " (the
        // old behavior) split sub-word continuations like ["c", "ust", "om", "ers"]
        // into "c ust om ers" instead of "customers".
        var currentRawTokens: [String] = []
        var segmentStart: Double = tokens[0].start

        for (index, token) in tokens.enumerated() {
            let rawToken = token.word
            let trimmedWord = rawToken.trimmingCharacters(in: .whitespaces)
            currentWords.append(WordTimestamp(word: trimmedWord, start: token.start, end: token.end))
            currentRawTokens.append(rawToken)

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
                let text = currentRawTokens.joined()
                    .trimmingCharacters(in: .whitespaces)
                segments.append(ASRSegment(
                    start: segmentStart,
                    end: token.end,
                    text: text,
                    words: currentWords
                ))
                currentWords = []
                currentRawTokens = []
                if !isLastToken {
                    segmentStart = tokens[index + 1].start
                }
            }
        }

        return segments
    }
}

import Foundation

// MARK: - Types

struct ASRSegment {
    let start: Double
    let end: Double
    let text: String
    var words: [WordTimestamp] = []
}

struct WordTimestamp: Codable {
    let word: String
    let start: Double
    let end: Double
}

struct SpeakerSegment {
    let start: Double
    let end: Double
    let speaker: String
}

struct TranscriptSegment: Codable {
    let start: Double
    let end: Double
    let text: String
    let speaker: String
    let words: [WordTimestamp]
}

struct Transcript: Codable {
    let language: String
    let duration: Double
    let numSegments: Int
    let numSpeakers: Int
    let processingTimeSeconds: Double
    let fullText: String
    let segments: [TranscriptSegment]
}

// MARK: - TranscriptMerger

enum TranscriptMerger {

    /// For each ASR segment, find the speaker with maximum temporal overlap.
    /// If no speaker segments are provided, defaults to "Speaker".
    static func merge(asr: [ASRSegment], speakers: [SpeakerSegment]) -> [TranscriptSegment] {
        asr.map { segment in
            let speaker = bestSpeaker(for: segment, from: speakers)
            return TranscriptSegment(
                start: segment.start,
                end: segment.end,
                text: segment.text,
                speaker: speaker,
                words: segment.words
            )
        }
    }

    /// Generates readable full text with speaker labels.
    /// Inserts a speaker header when the speaker changes, with a blank line between speaker changes.
    static func generateFullText(segments: [TranscriptSegment]) -> String {
        guard !segments.isEmpty else { return "" }

        var result = ""
        var currentSpeaker: String?

        for segment in segments {
            if segment.speaker != currentSpeaker {
                if currentSpeaker != nil {
                    result += "\n\n"
                }
                result += "[\(segment.speaker)]\n"
                currentSpeaker = segment.speaker
            } else {
                result += " "
            }
            result += segment.text
        }

        return result
    }

    // MARK: - Private

    private static func bestSpeaker(for asr: ASRSegment, from speakers: [SpeakerSegment]) -> String {
        guard !speakers.isEmpty else { return "Speaker" }

        var bestSpeaker = "Speaker"
        var maxOverlap: Double = 0

        for speaker in speakers {
            let overlapStart = max(asr.start, speaker.start)
            let overlapEnd = min(asr.end, speaker.end)
            let overlap = max(0, overlapEnd - overlapStart)

            if overlap > maxOverlap {
                maxOverlap = overlap
                bestSpeaker = speaker.speaker
            }
        }

        // If no overlap found at all, default to "Speaker"
        if maxOverlap == 0 {
            return "Speaker"
        }

        return bestSpeaker
    }
}

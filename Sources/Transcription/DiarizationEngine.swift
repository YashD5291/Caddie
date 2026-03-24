import Foundation
import FluidAudio

/// Speaker diarization engine.
/// Wraps FluidAudio's SortformerDiarizer with output mapping.
final class DiarizationEngine: DiarizationEngineProtocol, @unchecked Sendable {

    enum DiarizationError: Error, LocalizedError {
        case notInitialized
        case modelNotLoaded
        case diarizationFailed(String)

        var errorDescription: String? {
            switch self {
            case .notInitialized: return "Diarization engine not initialized"
            case .modelNotLoaded: return "Diarization model not loaded"
            case .diarizationFailed(let msg): return "Diarization failed: \(msg)"
            }
        }
    }

    private var diarizer: SortformerDiarizer?
    private var isReady = false

    /// Initialize with a pre-configured SortformerDiarizer. Called once at app startup.
    func initialize(diarizer: SortformerDiarizer) async throws {
        self.diarizer = diarizer
        isReady = true
    }

    /// Run diarization on a mono audio file. Returns speaker segments sorted by start time.
    func diarize(audioURL: URL) async throws -> [SpeakerSegment] {
        guard isReady, let diarizer = diarizer else { throw DiarizationError.notInitialized }

        do {
            // Load audio samples from file URL
            let audioConverter = AudioConverter()
            let audioSamples = try audioConverter.resampleAudioFile(audioURL)

            let timeline = try diarizer.processComplete(audioSamples)

            // timeline.speakers is [Int: DiarizerSpeaker] keyed by speaker slot index
            var rawSegments: [(speakerIndex: Int, startTime: Float, endTime: Float)] = []
            for (speakerIndex, speaker) in timeline.speakers {
                for segment in speaker.finalizedSegments {
                    rawSegments.append((
                        speakerIndex: speakerIndex,
                        startTime: Float(segment.startTime),
                        endTime: Float(segment.endTime)
                    ))
                }
            }

            let result = Self.mapToSpeakerSegments(rawSegments: rawSegments)
            diarizer.reset()
            return result
        } catch let error as DiarizationError {
            throw error
        } catch {
            throw DiarizationError.diarizationFailed(error.localizedDescription)
        }
    }

    // MARK: - Output Mapping (Pure Logic — Tested Independently)

    /// Maps raw diarizer output to our SpeakerSegment type.
    /// Normalizes speaker labels: "Speaker 0" → "SPEAKER_00"
    /// Sorts by start time.
    static func mapToSpeakerSegments(
        rawSegments: [(speakerIndex: Int, startTime: Float, endTime: Float)]
    ) -> [SpeakerSegment] {
        rawSegments
            .map { seg in
                SpeakerSegment(
                    start: Double(seg.startTime),
                    end: Double(seg.endTime),
                    speaker: String(format: "SPEAKER_%02d", seg.speakerIndex)
                )
            }
            .sorted { $0.start < $1.start }
    }
}

import Foundation

/// Speaker diarization engine.
/// Wraps FluidAudio's SortformerDiarizer with output mapping.
final class DiarizationEngine {

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

    private var isReady = false

    /// Initialize with downloaded models. Called once at app startup.
    func initialize() async throws {
        // TODO: Task 5 — wire FluidAudio SortformerDiarizer here
        isReady = true
    }

    /// Run diarization on a mono audio file. Returns speaker segments sorted by start time.
    func diarize(audioURL: URL) async throws -> [SpeakerSegment] {
        guard isReady else { throw DiarizationError.notInitialized }
        // TODO: Task 5 — call diarizer.processComplete and map results
        throw DiarizationError.diarizationFailed("FluidAudio integration pending — see Task 5")
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

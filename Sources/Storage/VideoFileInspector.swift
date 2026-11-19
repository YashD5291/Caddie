import AVFoundation

/// What AVFoundation reports about a finalized `.mov`.
struct VideoInspection: Sendable, Equatable {
    let isPlayable: Bool
    let durationSeconds: Double
    let videoTrackCount: Int

    /// The D-07 rule: playable, non-zero duration, at least one video track.
    /// A one-frame file is kept, because D-07 deletes only a file with no usable video.
    var isUsable: Bool { isPlayable && durationSeconds > 0 && videoTrackCount > 0 }
}

/// Verdict on a video file path.
enum VideoInspectionResult: Sendable, Equatable {
    /// Nothing is on disk, so there is nothing to delete.
    case missing
    case inspected(VideoInspection)
    /// A file exists that AVFoundation cannot open, so the caller deletes it (D-07).
    /// The message holds the error domain, code, and description.
    case unreadable(String)
}

/// Contract for judging whether a finalized video is usable.
/// Sendable conformance required because RecordingCoordinator is an actor that holds it.
protocol VideoFileInspecting: Sendable {
    func inspect(_ url: URL) async -> VideoInspectionResult
}

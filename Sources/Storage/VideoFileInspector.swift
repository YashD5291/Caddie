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

/// Production inspector backed by AVFoundation. The `load(.isPlayable, .duration)` call
/// comes from the Phase 18 `--validate-mov` harness (`ScreenRecorderHarness`), plus a
/// video-track count. It only reads the file; it never deletes or modifies it.
struct AVAssetVideoInspector: VideoFileInspecting {

    func inspect(_ url: URL) async -> VideoInspectionResult {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        // Created and consumed inside this call, so the asset never crosses an isolation boundary.
        let asset = AVURLAsset(url: url)
        do {
            let (playable, duration) = try await asset.load(.isPlayable, .duration)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            return .inspected(VideoInspection(isPlayable: playable,
                                              durationSeconds: Self.finiteSeconds(duration),
                                              videoTrackCount: tracks.count))
        } catch {
            // Not a silent catch: the error becomes the typed verdict the caller logs and acts on.
            let ns = error as NSError
            return .unreadable("\(ns.domain) \(ns.code): \(ns.localizedDescription)")
        }
    }

    /// An indefinite time reads as NaN; report it as 0 so it can never pass the `> 0` check.
    private static func finiteSeconds(_ time: CMTime) -> Double {
        let seconds = CMTimeGetSeconds(time)
        return seconds.isFinite ? seconds : 0
    }
}

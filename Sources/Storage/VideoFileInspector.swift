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
    /// The file is empty or AVFoundation cannot parse it as a movie, a verdict about its
    /// content, so the caller deletes it (D-07). The message holds the error domain, code,
    /// and description.
    case unreadable(String)
    /// The probe failed for a reason that says nothing about the content (I/O, permissions,
    /// media services, cancellation), so the caller keeps the file and its link and logs
    /// an error. The message holds the error domain, code, and description.
    case inconclusive(String)
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
        do {
            // A writer stopped before its first frame leaves 0 bytes: no video, whatever
            // error AVFoundation would report for it.
            if try url.resourceValues(forKeys: [.fileSizeKey]).fileSize == 0 {
                return .unreadable("The file is empty (0 bytes)")
            }
            // Created and consumed inside this call, so the asset never crosses an isolation boundary.
            let asset = AVURLAsset(url: url)
            let (playable, duration) = try await asset.load(.isPlayable, .duration)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            return .inspected(VideoInspection(isPlayable: playable,
                                              durationSeconds: Self.finiteSeconds(duration),
                                              videoTrackCount: tracks.count))
        } catch {
            // Not a silent catch: the error becomes the typed verdict the caller logs and acts on.
            return Self.classify(error)
        }
    }

    /// AVFoundation codes that are a verdict about the file's content. Measured on macOS:
    /// a 0-byte file, random bytes, and a sessionless writer output all fail with
    /// -11829 (`fileFailedToParse`); a permission error fails with NSCocoaErrorDomain 257.
    private static let contentErrorCodes: Set<Int> = [
        AVError.Code.fileFormatNotRecognized.rawValue,
        AVError.Code.fileFailedToParse.rawValue
    ]

    /// Maps a failed probe to a verdict. Only a content error deletes the file (D-07);
    /// anything else (I/O, permissions, media services, cancellation) is inconclusive.
    static func classify(_ error: Error) -> VideoInspectionResult {
        let ns = error as NSError
        let detail = "\(ns.domain) \(ns.code): \(ns.localizedDescription)"
        if ns.domain == AVFoundationErrorDomain && contentErrorCodes.contains(ns.code) {
            return .unreadable(detail)
        }
        return .inconclusive(detail)
    }

    /// An indefinite time reads as NaN; report it as 0 so it can never pass the `> 0` check.
    private static func finiteSeconds(_ time: CMTime) -> Double {
        let seconds = CMTimeGetSeconds(time)
        return seconds.isFinite ? seconds : 0
    }
}

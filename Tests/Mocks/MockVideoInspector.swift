import Foundation
@testable import Caddie

/// Scripted stand-in for `AVAssetVideoInspector`. Returns `defaultResult` for any file
/// without a per-file script, so coordinator tests can force a usable, unreadable,
/// inconclusive, or missing verdict without writing a real `.mov`.
///
/// Thread-safety: the coordinator calls `inspect` from its actor while the test body
/// reads the recorded calls from the main actor. Every piece of mutable state is
/// therefore guarded by `lock` (the same hazard documented in `MockScreenRecorder`).
final class MockVideoInspector: VideoFileInspecting, @unchecked Sendable {

    static let usable = VideoInspection(isPlayable: true, durationSeconds: 30, videoTrackCount: 1)

    private let lock = NSLock()

    private var _defaultResult: VideoInspectionResult = .inspected(MockVideoInspector.usable)
    private var _resultsByFileName: [String: VideoInspectionResult] = [:]
    private var _inspectedURLs: [URL] = []

    /// Verdict for any file without a per-file script.
    var defaultResult: VideoInspectionResult {
        get { lock.withLock { _defaultResult } }
        set { lock.withLock { _defaultResult = newValue } }
    }

    var inspectedURLs: [URL] { lock.withLock { _inspectedURLs } }
    var inspectCallCount: Int { lock.withLock { _inspectedURLs.count } }

    /// Scripts the verdict for one file, keyed by `url.lastPathComponent`.
    func setResult(_ result: VideoInspectionResult, for url: URL) {
        lock.withLock { _resultsByFileName[url.lastPathComponent] = result }
    }

    // MARK: - VideoFileInspecting

    func inspect(_ url: URL) async -> VideoInspectionResult {
        lock.withLock {
            _inspectedURLs.append(url)
            return _resultsByFileName[url.lastPathComponent] ?? _defaultResult
        }
    }
}

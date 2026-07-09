import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit
import VideoToolbox
import os

/// Captures a display or window as a video-only SCStream and encodes it to a
/// crash-safe, bitrate-capped HEVC `.mov` via AVAssetWriter.
///
/// Concurrency shape (Pattern 1, proven by the Phase 18-01 spike):
/// `ScreenRecorder` is a non-`Sendable` `final class` intended to be owned by the
/// `RecordingCoordinator` actor (the same relationship `AudioRecorder` already has).
/// The SCStream/AVAssetWriter hot path is confined to one dedicated serial
/// `writerQueue`; the `WriterSink` registered as `SCStreamOutput`/`SCStreamDelegate`
/// receives callbacks on that same queue, so all writer mutation is single-threaded
/// by construction. Cross-boundary notifications hop out via `@Sendable` closures,
/// mirroring `AudioRecorder.onDeviceDisconnected`/`onSamples`.
///
/// Attribution: the first-frame / static-screen retiming recipe is adapted (not
/// vendored) from the MIT-licensed nonstrict-hq/ScreenCaptureKit-Recording-example.
///
/// NOTE (Phase 18-01): this file currently holds only the concurrency skeleton and
/// the pure config/dimension/anchor/filter/state logic. Live SCStream capture and
/// AVAssetWriter wiring land in Plan 18-02.
final class ScreenRecorder {

    private let logger = Logger(subsystem: "com.caddie.app", category: "ScreenRecorder")

    /// Fired once, with the first written frame's host time (mach ticks), so the
    /// caller can persist the anchor against the audio start host time (STOR-04).
    /// `@Sendable`: crosses the writerQueue boundary.
    var onFirstFrameHostTime: (@Sendable (UInt64) -> Void)?

    /// Fired if the stream dies (`didStopWithError`). `@Sendable`: arrives on SCK's queue.
    var onStreamStopped: (@Sendable (Error?) -> Void)?

    /// Serial queue that confines all writer + SCK-callback state. Every field on
    /// `WriterSink` is touched ONLY on this queue — the documented invariant that
    /// justifies the sink's `@unchecked Sendable` conformance.
    private let writerQueue = DispatchQueue(label: "com.caddie.screenrecorder.writer")

    private var sink: WriterSink?
    private var stream: SCStream?
}

// MARK: - QualityPreset (VID-06)

extension ScreenRecorder {

    /// Video quality presets owned by the engine. Phase 21 exposes the picker; the
    /// engine defines the values now. Each preset pairs an fps throttle with an
    /// EXPLICIT HEVC average-bitrate cap (uncapped VideoToolbox defaults are 40+ Mbps).
    enum QualityPreset: String, CaseIterable, Sendable {
        case compact
        case balanced
        case high

        /// Default preset (~1.1 GB/hr at 1080p).
        static var `default`: QualityPreset { .balanced }

        /// Frames per second throttle (the dominant file-size lever).
        var fps: Int {
            switch self {
            case .compact: return 10
            case .balanced: return 15
            case .high: return 30
            }
        }

        /// Explicit HEVC average bitrate cap (bits/sec).
        var bitrate: Int {
            switch self {
            case .compact: return 1_500_000
            case .balanced: return 2_500_000
            case .high: return 4_000_000
            }
        }

        /// SCStreamConfiguration.minimumFrameInterval derived from `fps`.
        var minimumFrameInterval: CMTime {
            CMTime(value: 1, timescale: CMTimeScale(fps))
        }
    }
}

// MARK: - Pure config / dimension / anchor math

extension ScreenRecorder {

    /// Builds the AVAssetWriterInput video settings for a preset at fixed dimensions.
    /// The bitrate key is ALWAYS present and equals the preset's cap (kills Pitfall 3,
    /// uncapped bitrate). Width/height MUST equal the SCStreamConfiguration dimensions
    /// (Pitfall 4). Pure builder — assertable without any hardware.
    static func videoSettings(for preset: QualityPreset, dimensions: (width: Int, height: Int)) -> [String: Any] {
        [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: dimensions.width,
            AVVideoHeightKey: dimensions.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: preset.bitrate,
                AVVideoExpectedSourceFrameRateKey: preset.fps,
                AVVideoMaxKeyFrameIntervalDurationKey: 2.0,
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel,
            ],
        ]
    }

    /// Computes the target capture pixel dimensions: downscale the physical-pixel
    /// source to the clamp preserving aspect ratio, rounding to even numbers (HEVC
    /// requires even dimensions). No upscaling when already under the clamp. The SAME
    /// numbers feed both the stream config and the writer input (Pitfall 4).
    static func targetDimensions(sourceWidthPx: Int, sourceHeightPx: Int, maxLongEdge: Int) -> (width: Int, height: Int) {
        let longEdge = max(sourceWidthPx, sourceHeightPx)
        guard longEdge > maxLongEdge else {
            return (roundToEven(sourceWidthPx), roundToEven(sourceHeightPx))
        }
        let scale = Double(maxLongEdge) / Double(longEdge)
        let scaledWidth = Int((Double(sourceWidthPx) * scale).rounded())
        let scaledHeight = Int((Double(sourceHeightPx) * scale).rounded())
        return (roundToEven(scaledWidth), roundToEven(scaledHeight))
    }

    /// Rounds to the nearest even integer (>= 2), as required by HEVC dimensions.
    private static func roundToEven(_ value: Int) -> Int {
        let even = (value / 2) * 2
        return max(2, even)
    }

    /// Converts mach host-clock ticks to seconds using a `mach_timebase_info`.
    /// This is the STOR-04 anchor conversion the caller uses to turn the first-frame
    /// host tick into seconds against the audio start host time.
    static func hostTicksToSeconds(_ ticks: UInt64, timebase: mach_timebase_info_data_t) -> Double {
        Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000.0
    }
}

// MARK: - State machine

extension ScreenRecorder {

    /// Internal recording lifecycle state.
    enum State: Equatable {
        case idle
        case recording
        case stopped
        case failed
    }

    /// Events that drive the state machine.
    enum StateEvent {
        case started
        case stopped
        case failed
    }

    /// Pure state transition. Makes `stop()` idempotent by construction (mirrors
    /// `AudioRecorder.stop()`'s `guard isRecording`): only `.recording` responds to
    /// `.stopped`/`.failed`; every other pairing (incl. `.stopped`+`.stopped` and
    /// `.idle`+`.stopped`) is an unchanged no-op — no illegal transition.
    static func transition(_ state: State, _ event: StateEvent) -> State {
        switch (state, event) {
        case (.idle, .started): return .recording
        case (.recording, .stopped): return .stopped
        case (.recording, .failed): return .failed
        default: return state
        }
    }
}

// MARK: - Frame-status decision

extension ScreenRecorder {

    /// Whether a delivered frame should be appended to the writer or skipped.
    enum FrameAction: Equatable {
        case append
        case skip
    }

    /// Append only `.complete` frames; skip `.idle`/`.blank`/`.suspended`/`.stopped`
    /// and any unknown status so the writer is never fed junk. (The live impl in Plan
    /// 02 also caches each appended frame for static-screen re-append — that is an impl
    /// detail; this function only decides append vs skip.)
    static func frameAction(for status: SCFrameStatus) -> FrameAction {
        switch status {
        case .complete: return .append
        default: return .skip
        }
    }
}

// MARK: - Filter-input selection (VID-05)

extension ScreenRecorder {

    /// Bundle ids to exclude from capture — Caddie's own app, so its windows never
    /// appear (VID-05). Plan 02 maps this to `SCRunningApplication`s and builds the
    /// real `SCContentFilter`. Application-level exclusion is more robust than window
    /// enumeration (covers transient panels/menus).
    static func excludedBundleIdentifiers(ownBundleID: String) -> [String] {
        [ownBundleID]
    }

    /// Selects the display to capture: the `target` if present in `available`, else
    /// the first available display, or `nil` when none exist (caller throws
    /// `.noDisplayAvailable`).
    static func selectDisplayID(available: [CGDirectDisplayID], target: CGDirectDisplayID?) -> CGDirectDisplayID? {
        if let target, available.contains(target) {
            return target
        }
        return available.first
    }
}

// MARK: - Errors

extension ScreenRecorder {

    enum ScreenRecorderError: Error, LocalizedError {
        case noDisplayAvailable
        case writerCreationFailed(Error)
        case streamStartFailed(Error)
        case notRecording

        var errorDescription: String? {
            switch self {
            case .noDisplayAvailable:
                return "No display available to capture"
            case .writerCreationFailed(let error):
                return "Failed to create video writer: \(error.localizedDescription)"
            case .streamStartFailed(let error):
                return "Failed to start screen capture stream: \(error.localizedDescription)"
            case .notRecording:
                return "Screen recorder is not recording"
            }
        }
    }
}

// MARK: - WriterSink

/// The object SCK calls back on. Confined to `writerQueue`; `@unchecked Sendable` is
/// the documented invariant boundary — all fields are touched only on `writerQueue`
/// (same spirit as `SystemAudioCapture.RenderContext` being reached via `Unmanaged`
/// from the real-time thread). AVAssetWriter + AVAssetWriterInput are not `Sendable`
/// and live here.
final class WriterSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {

    // AVAssetWriter + AVAssetWriterInput are non-`Sendable` and live here as stored
    // fields, touched ONLY on writerQueue. Wired up in Plan 18-02.
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // SCK delivers this on writerQueue (the sampleHandlerQueue). The non-Sendable
        // CMSampleBuffer will be appended SYNCHRONOUSLY here to the confined, non-Sendable
        // input — never captured across a queue hop. Live logic lands in Plan 18-02.
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // on writerQueue — finalize + surface logic lands in Plan 18-02.
    }
}

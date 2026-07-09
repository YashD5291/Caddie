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

    /// Public lifecycle state, touched only in the owner's isolation domain (the
    /// coordinator that owns this non-`Sendable` class). Distinct from `WriterSink`'s
    /// own writerQueue-confined finalize guard — both use the same pure `transition`.
    private var state: State = .idle

    /// Longest capture edge in physical pixels (~1080p class). Retina input is
    /// downscaled toward this clamp; the SAME dims feed the stream config and writer.
    static let maxLongEdge = 1920

    /// Static-screen keepalive re-append interval (18-01 decision: ~2s). Keeps
    /// `movieFragmentInterval` flushing on static content so a kill-9 loses ≤ ~10s.
    static let keepaliveInterval: TimeInterval = 2.0

    /// True while a stream is actively capturing.
    var isRecording: Bool { state == .recording }

    /// What to capture. Display mode is the default; window mode is driven by
    /// Phase 21 Settings. Caddie's own windows are excluded in display mode (VID-05).
    ///
    /// Not `Sendable`: the `.window` payload (`SCWindow`) is not `Sendable` on the SDK,
    /// and this enum never crosses an isolation boundary — `ScreenRecorder` is itself a
    /// non-`Sendable` class owned within a single isolation domain (the coordinator).
    enum CaptureTarget {
        /// A specific display, or `nil` for the main/first available display.
        case display(CGDirectDisplayID?)
        /// A specific window (non-default; Phase 21 supplies it).
        case window(SCWindow)
    }

    /// Start a video-only SCStream feeding a crash-safe fragmented HEVC `.mov`.
    /// Anchors the writer session on the first delivered frame and fires
    /// `onFirstFrameHostTime` once with that frame's host tick (STOR-04).
    /// No-op (idempotent) if already recording.
    func start(target: CaptureTarget, preset: QualityPreset, outputURL: URL) async throws {
        guard state == .idle else {
            logger.warning("ScreenRecorder.start called while state=\(String(describing: self.state)) -- ignoring")
            return
        }

        // 1. Build the content filter and derive the source pixel size from it
        //    (contentRect is in points; pointPixelScale converts to physical pixels).
        let filter = try await makeFilter(for: target)
        let scale = CGFloat(filter.pointPixelScale)
        let rect = filter.contentRect
        let sourceWidthPx = Int((rect.width * scale).rounded())
        let sourceHeightPx = Int((rect.height * scale).rounded())
        guard sourceWidthPx > 0, sourceHeightPx > 0 else {
            throw ScreenRecorderError.noDisplayAvailable
        }

        // 2. Compute dims ONCE — feed the SAME numbers to config AND writer (Pitfall 4).
        let dims = Self.targetDimensions(
            sourceWidthPx: sourceWidthPx,
            sourceHeightPx: sourceHeightPx,
            maxLongEdge: Self.maxLongEdge
        )

        // 3. SCStreamConfiguration (verbatim per RESEARCH config block).
        let config = SCStreamConfiguration()
        config.minimumFrameInterval = preset.minimumFrameInterval
        config.width = dims.width
        config.height = dims.height
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.queueDepth = 5
        config.showsCursor = true
        config.capturesAudio = false
        config.scalesToFit = true
        config.colorSpaceName = CGColorSpace.sRGB

        // 4. AVAssetWriter — .mov + movieFragmentInterval BEFORE startWriting (VID-07).
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        } catch {
            throw ScreenRecorderError.writerCreationFailed(error)
        }
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)

        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: Self.videoSettings(for: preset, dimensions: dims)
        )
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else {
            throw ScreenRecorderError.writerCreationFailed(
                NSError(domain: "ScreenRecorder", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "AVAssetWriter cannot add video input"])
            )
        }
        writer.add(videoInput)
        guard writer.startWriting() else {
            throw ScreenRecorderError.writerCreationFailed(
                writer.error ?? NSError(domain: "ScreenRecorder", code: -2,
                                        userInfo: [NSLocalizedDescriptionKey: "AVAssetWriter startWriting failed"])
            )
        }
        // startSession(atSourceTime:) is DEFERRED to the first delivered buffer (recipe B).

        // 5. WriterSink + SCStream. Output callbacks are confined to writerQueue via
        //    sampleHandlerQueue; delegate callbacks are re-dispatched onto it in the sink.
        let sink = WriterSink(
            writer: writer,
            videoInput: videoInput,
            queue: writerQueue,
            onFirstFrameHostTime: onFirstFrameHostTime,
            onStreamStopped: onStreamStopped
        )
        let stream = SCStream(filter: filter, configuration: config, delegate: sink)
        do {
            try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: writerQueue)
            try await stream.startCapture()
        } catch {
            // Never leave a half-open writer (mirror AudioRecorder rollback).
            writer.cancelWriting()
            throw ScreenRecorderError.streamStartFailed(error)
        }

        self.sink = sink
        self.stream = stream
        self.state = Self.transition(state, .started)

        let targetDesc: String
        switch target {
        case .display(let id): targetDesc = "display(\(id.map(String.init) ?? "main"))"
        case .window: targetDesc = "window"
        }
        logger.info("ScreenRecorder started: target=\(targetDesc, privacy: .public) preset=\(preset.rawValue, privacy: .public) dims=\(dims.width)x\(dims.height) -> \(outputURL.lastPathComponent, privacy: .public)")
    }

    /// Builds the `SCContentFilter` for the requested target. Display mode excludes
    /// Caddie's own application windows via `excludedBundleIdentifiers` (VID-05).
    private func makeFilter(for target: CaptureTarget) async throws -> SCContentFilter {
        switch target {
        case .display(let displayID):
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let available = content.displays.map { $0.displayID }
            guard let chosenID = Self.selectDisplayID(available: available, target: displayID),
                  let display = content.displays.first(where: { $0.displayID == chosenID }) else {
                throw ScreenRecorderError.noDisplayAvailable
            }
            let ownIDs = Self.excludedBundleIdentifiers(ownBundleID: Bundle.main.bundleIdentifier ?? "")
            let caddieApps = content.applications.filter { ownIDs.contains($0.bundleIdentifier) }
            return SCContentFilter(display: display, excludingApplications: caddieApps, exceptingWindows: [])
        case .window(let window):
            return SCContentFilter(desktopIndependentWindow: window)
        }
    }
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

    private let logger = Logger(subsystem: "com.caddie.app", category: "ScreenRecorder")

    // AVAssetWriter + AVAssetWriterInput are non-`Sendable` and live here as stored
    // fields, touched ONLY on writerQueue.
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput

    /// The confining serial queue. Output callbacks already arrive here (sampleHandlerQueue);
    /// delegate callbacks and the keepalive timer are re-dispatched onto it.
    private let queue: DispatchQueue

    private let onFirstFrameHostTime: (@Sendable (UInt64) -> Void)?
    private let onStreamStopped: (@Sendable (Error?) -> Void)?

    // writerQueue-confined operational state.
    private var state: ScreenRecorder.State = .recording
    private var hasStartedSession = false
    private var lastFrame: CMSampleBuffer?
    private var lastAppendPTS: CMTime = .invalid
    private var frameArrivedSinceKeepalive = false
    private var keepaliveTimer: DispatchSourceTimer?

    init(
        writer: AVAssetWriter,
        videoInput: AVAssetWriterInput,
        queue: DispatchQueue,
        onFirstFrameHostTime: (@Sendable (UInt64) -> Void)?,
        onStreamStopped: (@Sendable (Error?) -> Void)?
    ) {
        self.writer = writer
        self.videoInput = videoInput
        self.queue = queue
        self.onFirstFrameHostTime = onFirstFrameHostTime
        self.onStreamStopped = onStreamStopped
        super.init()
    }

    // MARK: - SCStreamOutput (on writerQueue via sampleHandlerQueue)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard state == .recording else { return }

        // Append only .complete frames (skip .idle/.blank/.suspended/.stopped junk).
        guard let status = Self.frameStatus(of: sampleBuffer),
              ScreenRecorder.frameAction(for: status) == .append else { return }
        // A complete frame must carry a pixel buffer.
        guard CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid else { return }

        // First delivered .complete frame: anchor the session at its PTS (recipe B)
        // and fire the STOR-04 host-tick anchor exactly once.
        if !hasStartedSession {
            guard writer.status == .writing else {
                logger.error("First frame arrived but writer not writing (status=\(self.writer.status.rawValue))")
                return
            }
            writer.startSession(atSourceTime: pts)
            hasStartedSession = true
            let hostTicks = CMClockConvertHostTimeToSystemUnits(pts)
            onFirstFrameHostTime?(hostTicks)
            logger.info("ScreenRecorder first frame anchored (hostTicks=\(hostTicks))")
        }

        // Cache for static-screen re-append (Plan 18-02 Task 2 keepalive + stop).
        lastFrame = sampleBuffer
        frameArrivedSinceKeepalive = true

        appendIfMonotonic(sampleBuffer, pts: pts)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Log + surface here; the finalize-a-playable-partial path lands in Task 2.
        logger.error("SCStream stopped with error: \(error.localizedDescription)")
        onStreamStopped?(error)
    }

    // MARK: - Append helpers (writerQueue)

    /// Append a buffer only when the input is ready and the PTS strictly advances the
    /// timeline — guards against out-of-order or duplicate timestamps on re-append.
    private func appendIfMonotonic(_ buffer: CMSampleBuffer, pts: CMTime) {
        guard videoInput.isReadyForMoreMediaData else {
            logger.warning("Video input not ready for more media data -- dropping frame")
            return
        }
        if lastAppendPTS.isValid && pts <= lastAppendPTS { return }
        videoInput.append(buffer)
        lastAppendPTS = pts
    }

    /// Reads the `SCStreamFrameInfo.status` attachment from a delivered buffer.
    static func frameStatus(of sampleBuffer: CMSampleBuffer) -> SCFrameStatus? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let attachment = attachments.first,
              let rawStatus = attachment[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else {
            return nil
        }
        return status
    }
}

// MARK: - WriterSink finalize reason

extension WriterSink {

    /// Why the sink is being finalized — drives the terminal state.
    enum FinalizeReason {
        case stopped
        case streamError
    }
}

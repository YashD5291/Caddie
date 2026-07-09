import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit
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

import Foundation

/// Test seam for the Phase 18 capture engine (`ScreenRecorder`), so the
/// `RecordingCoordinator` can be unit-tested without a TCC grant or a real display.
///
/// Deliberately NOT `Sendable`: like `ScreenRecorder` itself, a conformer is owned by
/// exactly one isolation domain (the `RecordingCoordinator` actor) — the same ownership
/// model `AudioRecorder` already has. The two callbacks are `@Sendable` because they are
/// invoked from the engine's writer queue and SCK's own queue, not from the owner.
protocol ScreenRecording: AnyObject {
    /// Fires once with the first written frame's host time (mach ticks) — the video half
    /// of the STOR-04 anchor pair. Must be assigned BEFORE `start`; the engine captures
    /// its current value at start time, so a later assignment is a silent no-op.
    var onFirstFrameHostTime: (@Sendable (UInt64) -> Void)? { get set }

    /// Fires if the stream dies mid-meeting (window closed, SCK error -3821). The
    /// authoritative death signal — `isRecording` still reads `true` after a stream error.
    var onStreamStopped: (@Sendable (Error?) -> Void)? { get set }

    /// True while a stream is actively capturing.
    var isRecording: Bool { get }

    func start(target: ScreenRecorder.CaptureTarget,
               preset: ScreenRecorder.QualityPreset,
               outputURL: URL) async throws

    func stop() async
}

/// Vends a fresh `ScreenRecording` per meeting.
///
/// Exists because `ScreenRecorder` is single-use by construction: `start()` guards
/// `state == .idle`, and `transition(.stopped, .started) == .stopped`, so a second
/// `start()` on the same instance logs a warning and returns WITHOUT throwing. Reusing
/// one instance would therefore record nothing from meeting #2 onward, silently — the
/// exact failure class this project forbids. A fresh instance per meeting also makes
/// callback assignment correct-by-construction and gives the engine's defensive `deinit`
/// finalize a second chance to run.
typealias ScreenRecorderFactory = @Sendable () -> ScreenRecording

extension ScreenRecorder: ScreenRecording {}

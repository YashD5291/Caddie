import XCTest
import GRDB
@testable import Caddie

/// Verifies RecordingCoordinator wires the LiveTranscriber around the recording
/// lifecycle: started + tee attached when entering .recording, and (on every
/// termination path) the tee detached and the transcriber stopped BEFORE the
/// batch pipeline is enqueued.
///
/// The transcriber's engine is bound at construction (MockStreamingEngine), so
/// `start()`/`cancel()` fire without CoreML models — letting these tests assert
/// the engine call counts directly, not just the tee state.
@MainActor
final class RecordingCoordinatorLiveTranscriptionTests: XCTestCase {
    var db: AppDatabase!
    var pipeline: TranscriptionPipeline!
    var engine: MockStreamingEngine!
    var transcriber: LiveTranscriber!

    override func setUpWithError() throws {
        db = try AppDatabase(inMemory: true)
        pipeline = TranscriptionPipeline(asr: MockASREngine(), diarization: MockDiarizationEngine())
        engine = MockStreamingEngine()
        transcriber = LiveTranscriber(engine: engine)
    }

    override func tearDownWithError() throws {
        db = nil; pipeline = nil; engine = nil; transcriber = nil
    }

    private func makeCoordinator() -> RecordingCoordinator {
        RecordingCoordinator(
            database: db,
            recorder: AudioRecorder(),
            pipeline: pipeline,
            detector: MeetingDetector(),
            audioDeviceManager: nil,
            liveTranscriber: transcriber
        )
    }

    private func makeCoordinatorWithoutLiveTranscriber() -> RecordingCoordinator {
        RecordingCoordinator(
            database: db,
            recorder: AudioRecorder(),
            pipeline: pipeline,
            detector: MeetingDetector(),
            audioDeviceManager: nil,
            liveTranscriber: nil
        )
    }

    /// On manual start, the coordinator starts the live transcriber and attaches
    /// the onSamples tee so drained capture batches flow to it.
    func testStartRecordingStartsLiveTranscriberAndAttachesTee() async {
        let coordinator = makeCoordinator()
        await coordinator.handle(.manualStart(title: "Live Test"))
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(engine.startCallCount, 1, "LiveTranscriber.start should run when entering .recording")
        XCTAssertEqual(engine.cancelCallCount, 0, "Transcriber must not be cancelled while recording")
        let attached = await coordinator.isLiveTeeAttached
        XCTAssertTrue(attached, "onSamples tee must be attached during recording")
    }

    /// On stop, the tee is detached and the transcriber cancelled before the batch
    /// pipeline runs (frees the ANE for the full-accuracy pass; no further samples
    /// flow to the now-cancelled engine).
    func testStopDetachesTeeAndCancelsLiveTranscriber() async {
        let coordinator = makeCoordinator()
        await coordinator.handle(.manualStart(title: "Live Test"))
        try? await Task.sleep(for: .milliseconds(100))

        await coordinator.handle(.manualStop)
        try? await Task.sleep(for: .milliseconds(100))

        let attached = await coordinator.isLiveTeeAttached
        XCTAssertFalse(attached, "onSamples must be detached before pipeline enqueue")
        XCTAssertEqual(engine.cancelCallCount, 1, "LiveTranscriber.stop should cancel the engine on stop")
    }

    /// Device-disconnect reduces to .stopAndTranscribe, so it must tear down the
    /// live tee identically to an explicit stop.
    func testDeviceDisconnectDetachesTeeAndCancelsLiveTranscriber() async {
        let coordinator = makeCoordinator()
        await coordinator.handle(.manualStart(title: "Live Test"))
        try? await Task.sleep(for: .milliseconds(100))

        await coordinator.handle(.deviceDisconnected)
        try? await Task.sleep(for: .milliseconds(100))

        let attached = await coordinator.isLiveTeeAttached
        XCTAssertFalse(attached, "onSamples must be detached on device disconnect")
        XCTAssertEqual(engine.cancelCallCount, 1, "LiveTranscriber.stop should cancel the engine on disconnect")
    }

    /// With no live transcriber injected, recording still works: the coordinator
    /// enters .recording and never attaches the onSamples tee. Locks in that live
    /// text is an optional display-only add-on — recording functions without it.
    func testStartRecordingWorksWithoutLiveTranscriber() async {
        let coordinator = makeCoordinatorWithoutLiveTranscriber()
        await coordinator.handle(.manualStart(title: "No Live Test"))
        try? await Task.sleep(for: .milliseconds(100))

        let state = await coordinator.state
        guard case .recording = state else {
            XCTFail("Expected .recording without a live transcriber, got \(state)")
            return
        }
        let attached = await coordinator.isLiveTeeAttached
        XCTAssertFalse(attached, "onSamples tee must not be attached when liveTranscriber is nil")
    }
}

import XCTest
@testable import Caddie

final class ProtocolDITests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: tempDir)
    }

    func testMockASREngineConformsToProtocolAndReturnsCannedSegments() async throws {
        let mock = MockASREngine()
        let result = try await mock.transcribe(audioURL: URL(fileURLWithPath: "/tmp/test.wav"))

        XCTAssertEqual(result.segments.count, 1)
        XCTAssertEqual(result.segments[0].text, "Hello world")
        XCTAssertEqual(result.language, "en")
        XCTAssertEqual(result.duration, 5.0)
        XCTAssertEqual(mock.transcribeCallCount, 1)
    }

    func testMockDiarizationEngineConformsToProtocolAndReturnsCannedSegments() async throws {
        let mock = MockDiarizationEngine()
        let result = try await mock.diarize(audioURL: URL(fileURLWithPath: "/tmp/test.wav"))

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].speaker, "SPEAKER_00")
        XCTAssertEqual(result[0].start, 0.0)
        XCTAssertEqual(result[0].end, 5.0)
        XCTAssertEqual(mock.diarizeCallCount, 1)
    }

    func testTranscriptionPipelineAcceptsProtocolTypedEngines() {
        let mockASR = MockASREngine()
        let mockDiarization = MockDiarizationEngine()

        // This line proves protocol-based init works -- would fail to compile if
        // TranscriptionPipeline still required concrete ASREngine/DiarizationEngine
        let pipeline = TranscriptionPipeline(asr: mockASR, diarization: mockDiarization)
        XCTAssertNotNil(pipeline)
    }

    // MARK: - ScreenRecording seam (Phase 19)

    func testScreenRecorderConformsToScreenRecording() {
        // The annotation is the assertion: this line fails to compile unless the
        // Phase 18 engine satisfies the seam the coordinator will depend on.
        // Constructing the engine starts no capture and needs no TCC grant.
        let recorder: ScreenRecording = ScreenRecorder()
        XCTAssertFalse(recorder.isRecording)
    }

    func testScreenRecorderFactoryVendsFreshInstances() {
        let factory: ScreenRecorderFactory = { ScreenRecorder() }
        let a = factory()
        let b = factory()

        // Per-meeting-instance contract: ScreenRecorder is single-use (a second
        // start() on a stopped instance silently no-ops), so plans 19-02/19-03
        // rely on every call vending a distinct object.
        XCTAssertFalse(a === b)
    }

    // MARK: - Finalize contract (Phase 20)

    func testOnFinalizedIsSettableThroughSeam() {
        // Compiles only if the seam requires onFinalized; the engine satisfies it.
        let recorder: ScreenRecording = ScreenRecorder()
        recorder.onFinalized = {}
        XCTAssertNotNil(recorder.onFinalized)
    }

    func testMockFinalizesOnceOnStop() async throws {
        let recorder = MockScreenRecorder()
        let log = FinalizeLog()
        recorder.onFinalized = { [weak recorder] in log.record(stopCount: recorder?.stopCallCount ?? -1) }

        try await recorder.start(target: .display(nil), preset: .compact, outputURL: movURL())
        await recorder.stop()

        XCTAssertEqual(log.stopCountsAtFire, [1], "Fires once, after the stop counter increments")
    }

    func testMockSimulatedFinalizeIsNotRepeatedByStop() async throws {
        let recorder = MockScreenRecorder()
        let log = FinalizeLog()
        recorder.onFinalized = { log.record() }

        try await recorder.start(target: .display(nil), preset: .compact, outputURL: movURL())
        // Stream death mid-meeting finalizes before teardown; the later stop() must not
        // fire a second time, mirroring the engine's idempotency guard (D-06).
        recorder.simulateStreamDeath(MockScreenRecorderError(message: "SCK -3821"))
        recorder.simulateFinalize()
        XCTAssertEqual(log.count, 1)

        await recorder.stop()

        XCTAssertEqual(recorder.stopCallCount, 1)
        XCTAssertEqual(log.count, 1)
    }

    func testMockNeverFinalizeSuppressesSignal() async throws {
        let recorder = MockScreenRecorder()
        recorder.neverFinalize = true
        let log = FinalizeLog()
        recorder.onFinalized = { log.record() }

        try await recorder.start(target: .display(nil), preset: .compact, outputURL: movURL())
        await recorder.stop()

        XCTAssertEqual(recorder.stopCallCount, 1)
        XCTAssertEqual(log.count, 0, "Models app quit or a wedged finalize")
    }

    func testMockDelayedFinalizeFiresAfterStopReturns() async throws {
        let recorder = MockScreenRecorder()
        recorder.finalizeDelay = .milliseconds(300)
        let log = FinalizeLog()
        let finalized = expectation(description: "late onFinalized")
        finalized.assertForOverFulfill = true
        recorder.onFinalized = {
            log.record()
            finalized.fulfill()
        }

        try await recorder.start(target: .display(nil), preset: .compact, outputURL: movURL())
        await recorder.stop()
        XCTAssertEqual(log.count, 0, "stop() must return before a late finalize arrives")

        await fulfillment(of: [finalized], timeout: 5)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(log.count, 1)
    }

    func testMockFailedStartNeverFinalizes() async throws {
        let recorder = MockScreenRecorder()
        recorder.startError = MockScreenRecorderError(message: "TCC denied")
        let log = FinalizeLog()
        recorder.onFinalized = { log.record() }

        do {
            try await recorder.start(target: .display(nil), preset: .compact, outputURL: movURL())
            XCTFail("start should have thrown")
        } catch let error as MockScreenRecorderError {
            XCTAssertEqual(error.message, "TCC denied")
        }
        // The real engine's stop() is a no-op after a failed start: no writer, no signal.
        await recorder.stop()

        XCTAssertEqual(log.count, 0)
    }

    func testMockCreatesFileOnStartBeforeThrowing() async throws {
        let recorder = MockScreenRecorder()
        recorder.createsFileOnStart = true
        recorder.startError = MockScreenRecorderError(message: "TCC denied")
        let url = movURL()

        do {
            try await recorder.start(target: .display(nil), preset: .compact, outputURL: url)
            XCTFail("start should have thrown")
        } catch let error as MockScreenRecorderError {
            XCTAssertEqual(error.message, "TCC denied")
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "A failed start can leave a file the coordinator must clean up")
        XCTAssertEqual(try Data(contentsOf: url).count, 0)
    }

    func testFactoryPropagatesFinalizeKnobs() throws {
        let factory = MockScreenRecorderFactory()
        factory.finalizeDelay = .milliseconds(250)
        factory.neverFinalize = true
        factory.createsFileOnStart = true

        let vended = try XCTUnwrap(factory.factory() as? MockScreenRecorder)

        XCTAssertEqual(vended.finalizeDelay, .milliseconds(250))
        XCTAssertTrue(vended.neverFinalize)
        XCTAssertTrue(vended.createsFileOnStart)
    }

    // MARK: - Helpers

    /// Never under the real audio directory (D-15).
    private func movURL() -> URL {
        tempDir.appendingPathComponent("\(UUID().uuidString).mov")
    }
}

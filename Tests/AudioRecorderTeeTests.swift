import XCTest
@testable import Caddie

final class AudioRecorderTeeTests: XCTestCase {

    /// The tee property exists, is optional, and accepts a [Int16] batch.
    func testOnSamplesPropertyIsSettableAndClearable() {
        let recorder = AudioRecorder()
        var captured: [[Int16]] = []
        recorder.onSamples = { captured.append($0) }
        XCTAssertNotNil(recorder.onSamples)
        recorder.onSamples = nil
        XCTAssertNil(recorder.onSamples)
        XCTAssertTrue(captured.isEmpty)
    }

    /// flushRingBuffer is a private main-thread drain; exercise the tee directly via
    /// the testable hook. With samples queued, the callback receives exactly the
    /// drained batch (same values written to the WAV).
    func testFlushInvokesOnSamplesWithDrainedBatch() {
        let recorder = AudioRecorder()
        var received: [Int16] = []
        recorder.onSamples = { received.append(contentsOf: $0) }

        let input: [Int16] = [10, -20, 30, -40, 32767, -32768]
        recorder.testFeedAndFlush(input)

        XCTAssertEqual(received, input)
    }

    /// nil callback = no-op: draining must not crash and must remain a pure WAV write.
    func testFlushWithNilOnSamplesIsNoOp() {
        let recorder = AudioRecorder()
        recorder.onSamples = nil
        // Should not crash when there is nothing wired.
        recorder.testFeedAndFlush([1, 2, 3])
        XCTAssertNil(recorder.onSamples)
    }
}

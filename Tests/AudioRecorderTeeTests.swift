import XCTest
@testable import Caddie

final class AudioRecorderTeeTests: XCTestCase {

    /// Real behavior: flush with callback set → samples captured; set callback to nil →
    /// second flush captures nothing more.
    func testOnSamplesPropertyIsSettableAndClearable() {
        let recorder = AudioRecorder()
        defer { recorder.stop() }

        var captured: [[Int16]] = []
        recorder.onSamples = { captured.append($0) }

        recorder.testFeedAndFlush([1, 2, 3])
        XCTAssertFalse(captured.isEmpty, "callback should fire when onSamples is set")

        recorder.onSamples = nil
        let countBefore = captured.count
        recorder.testFeedAndFlush([4, 5, 6])
        XCTAssertEqual(captured.count, countBefore, "callback must not fire after onSamples is cleared")
    }

    /// flushRingBuffer is a private main-thread drain; exercise the tee directly via
    /// the testable hook. With samples queued, the callback receives exactly the
    /// drained batch (same values written to the WAV).
    ///
    /// Implicit contract: writeToFile no-ops when audioFile is nil, so the tee can be
    /// tested without a WAV.
    func testFeedAndFlush() {
        let recorder = AudioRecorder()
        defer { recorder.stop() }

        var received: [Int16] = []
        recorder.onSamples = { received.append(contentsOf: $0) }

        let input: [Int16] = [10, -20, 30, -40, 32767, -32768]
        recorder.testFeedAndFlush(input)

        XCTAssertEqual(received, input)
    }

    /// nil callback = no-op: draining must not crash and must remain a pure WAV write.
    func testFlushWithNilOnSamplesIsNoOp() {
        let recorder = AudioRecorder()
        defer { recorder.stop() }

        recorder.onSamples = nil
        // Should not crash when there is nothing wired.
        recorder.testFeedAndFlush([1, 2, 3])
    }
}

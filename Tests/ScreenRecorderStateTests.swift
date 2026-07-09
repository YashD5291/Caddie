import XCTest
import ScreenCaptureKit
@testable import Caddie

/// State-machine + frame-status decision tests for ScreenRecorder.
/// Mirrors the RecordingState.reduce pure-transition test style.
final class ScreenRecorderStateTests: XCTestCase {

    // MARK: - State machine (idempotent stop by construction)

    func testFreshStateIsIdle() {
        XCTAssertEqual(ScreenRecorder.State.idle, .idle)
    }

    func testIdleStartedTransitionsToRecording() {
        XCTAssertEqual(ScreenRecorder.transition(.idle, .started), .recording)
    }

    func testRecordingStoppedTransitionsToStopped() {
        XCTAssertEqual(ScreenRecorder.transition(.recording, .stopped), .stopped)
    }

    func testRecordingFailedTransitionsToFailed() {
        XCTAssertEqual(ScreenRecorder.transition(.recording, .failed), .failed)
    }

    func testStoppedStoppedIsIdempotent() {
        // Idempotent stop — no crash, no illegal transition.
        XCTAssertEqual(ScreenRecorder.transition(.stopped, .stopped), .stopped)
    }

    func testIdleStoppedIsSafeNoOp() {
        // Stop before start is a safe no-op.
        XCTAssertEqual(ScreenRecorder.transition(.idle, .stopped), .idle)
    }

    // MARK: - Frame-status decision (append .complete only)

    func testFrameActionAppendsCompleteFrames() {
        XCTAssertEqual(ScreenRecorder.frameAction(for: .complete), .append)
    }

    func testFrameActionSkipsNonCompleteFrames() {
        XCTAssertEqual(ScreenRecorder.frameAction(for: .idle), .skip)
        XCTAssertEqual(ScreenRecorder.frameAction(for: .blank), .skip)
        XCTAssertEqual(ScreenRecorder.frameAction(for: .suspended), .skip)
        XCTAssertEqual(ScreenRecorder.frameAction(for: .stopped), .skip)
    }
}

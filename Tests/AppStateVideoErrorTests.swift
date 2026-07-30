import XCTest
@testable import Caddie

/// VID-04 (surfaced half): the dedicated, NON-FATAL video error channel.
///
/// Deliberately separate from `lastRecordingError` — a video failure means the
/// recording was degraded, not lost, so it must never render as "Last recording failed".
@MainActor
final class AppStateVideoErrorTests: XCTestCase {

    func testLastVideoErrorDefaultsNil() {
        let state = AppState()
        XCTAssertNil(state.lastVideoError)
    }

    func testApplyVideoErrorSetsMessage() {
        let state = AppState()
        state.applyVideoError("Screen recording stopped")
        XCTAssertEqual(state.lastVideoError, "Screen recording stopped")
    }

    func testClearVideoErrorResetsMessage() {
        let state = AppState()
        state.applyVideoError("Screen recording stopped")
        state.clearVideoError()
        XCTAssertNil(state.lastVideoError)
    }

    func testApplyVideoErrorReplacesPreviousMessage() {
        let state = AppState()
        state.applyVideoError("First failure")
        state.applyVideoError("Second failure")
        XCTAssertEqual(state.lastVideoError, "Second failure")
    }

    /// The video channel must not bleed into the fatal recording-error surface.
    func testApplyVideoErrorLeavesRecordingErrorUntouched() {
        let state = AppState()
        state.applyVideoError("Screen recording stopped")
        XCTAssertNil(state.lastRecordingError)
    }
}

import XCTest
@testable import Caddie

@MainActor
final class AppStateLiveTextTests: XCTestCase {

    func testLiveTextDefaultsEmpty() {
        let state = AppState()
        XCTAssertEqual(state.liveConfirmedText, "")
        XCTAssertEqual(state.liveVolatileText, "")
    }

    func testApplyLiveUpdateSetsBothStrings() {
        let state = AppState()
        state.applyLiveTranscript(confirmed: "hello world", volatile: "and")
        XCTAssertEqual(state.liveConfirmedText, "hello world")
        XCTAssertEqual(state.liveVolatileText, "and")
    }

    func testClearLiveTranscriptResetsBothStrings() {
        let state = AppState()
        state.applyLiveTranscript(confirmed: "hello", volatile: "world")
        state.clearLiveTranscript()
        XCTAssertEqual(state.liveConfirmedText, "")
        XCTAssertEqual(state.liveVolatileText, "")
    }
}

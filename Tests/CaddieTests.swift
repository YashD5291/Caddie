import XCTest
@testable import Caddie

final class CaddieTests: XCTestCase {
    func testAppStateInitialStatus() {
        let state = AppState()
        XCTAssertEqual(state.status, .idle)
    }
}

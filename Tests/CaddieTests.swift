import XCTest
@testable import Caddie

final class CaddieTests: XCTestCase {
    @MainActor
    func testAppStateInitialStatus() {
        let state = AppState()
        XCTAssertEqual(state.status, .idle)
    }
}

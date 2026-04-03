import XCTest
import UserNotifications
@testable import Caddie

final class NotificationManagerTests: XCTestCase {
    func testRecordPromptCategoryHasActions() {
        let category = NotificationManager.recordPromptCategory()
        XCTAssertEqual(category.identifier, "MEETING_DETECTED")
        XCTAssertEqual(category.actions.count, 2)
        XCTAssertEqual(category.actions[0].identifier, "RECORD_ACTION")
        XCTAssertEqual(category.actions[1].identifier, "DISMISS_ACTION")
    }
}

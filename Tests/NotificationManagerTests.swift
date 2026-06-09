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

    // MARK: - authState(from:)

    func testAuthState_authorizedStatusesMapToAuthorized() {
        XCTAssertEqual(NotificationManager.authState(from: .authorized), .authorized)
        XCTAssertEqual(NotificationManager.authState(from: .provisional), .authorized)
    }

    func testAuthState_notDeterminedMapsToUndetermined() {
        XCTAssertEqual(NotificationManager.authState(from: .notDetermined), .undetermined)
    }

    func testAuthState_deniedMapsToDenied() {
        XCTAssertEqual(NotificationManager.authState(from: .denied), .denied)
    }

    // MARK: - System Settings deep link

    func testNotificationSettingsURL_targetsCaddieBundle() {
        let url = NotificationManager.notificationSettingsURL
        XCTAssertEqual(url.scheme, "x-apple.systempreferences")
        XCTAssertTrue(url.absoluteString.contains("com.apple.preference.notifications"))
        XCTAssertTrue(url.absoluteString.contains("com.caddie.app"))
    }

    // MARK: - Stable meeting-prompt identifier (Finding 7)

    func testPromptIdentifierIsStableForEventID() {
        let id1 = NotificationManager.promptIdentifier(eventID: "evt-123")
        let id2 = NotificationManager.promptIdentifier(eventID: "evt-123")
        XCTAssertEqual(id1, id2, "Identifier must be deterministic so re-fired prompts replace")
        XCTAssertTrue(id1.contains("meeting-prompt-"), "Identifier should be scoped to the meeting prompt")
        XCTAssertTrue(id1.contains("evt-123"), "Identifier should embed the eventID")
    }

    func testPromptIdentifierDiffersAcrossEvents() {
        let a = NotificationManager.promptIdentifier(eventID: "evt-a")
        let b = NotificationManager.promptIdentifier(eventID: "evt-b")
        XCTAssertNotEqual(a, b)
    }
}

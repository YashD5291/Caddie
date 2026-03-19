import XCTest
@testable import Caddie

final class MeetingPatternsTests: XCTestCase {

    // MARK: - Process Detection

    func testZoomProcessDetection() {
        XCTAssertEqual(MeetingPatterns.appForProcess("zoom.us"), "Zoom")
        XCTAssertNil(MeetingPatterns.appForProcess("com.apple.finder"))
    }

    func testTeamsProcessDetection() {
        XCTAssertEqual(MeetingPatterns.appForProcess("Microsoft Teams"), "Microsoft Teams")
        XCTAssertEqual(MeetingPatterns.appForProcess("Teams"), "Microsoft Teams")
    }

    // MARK: - Window Title Matching

    func testGoogleMeetWindowTitle() {
        XCTAssertTrue(MeetingPatterns.isMeetingTitle("Meet - Budget Review", forApp: "Google Meet"))
        XCTAssertFalse(MeetingPatterns.isMeetingTitle("Gmail - Inbox", forApp: "Google Meet"))
    }

    func testZoomWindowTitle() {
        XCTAssertTrue(MeetingPatterns.isMeetingTitle("Zoom Meeting", forApp: "Zoom"))
        XCTAssertTrue(MeetingPatterns.isMeetingTitle("Zoom Meeting-ID: 123-456-789", forApp: "Zoom"))
        XCTAssertFalse(MeetingPatterns.isMeetingTitle("Zoom Workplace", forApp: "Zoom"))
    }

    // MARK: - Browser Detection

    func testBrowserIsMeetingApp() {
        XCTAssertTrue(MeetingPatterns.isBrowser("Google Chrome"))
        XCTAssertTrue(MeetingPatterns.isBrowser("Safari"))
        XCTAssertTrue(MeetingPatterns.isBrowser("Arc"))
        XCTAssertFalse(MeetingPatterns.isBrowser("Finder"))
    }

    // MARK: - Title Cleaning

    func testCleanMeetingTitle() {
        XCTAssertEqual(
            MeetingPatterns.cleanTitle("Weekly Standup - Zoom Meeting", app: "Zoom"),
            "Weekly Standup"
        )
        XCTAssertEqual(
            MeetingPatterns.cleanTitle("Sprint Planning | Microsoft Teams", app: "Microsoft Teams"),
            "Sprint Planning"
        )
        XCTAssertEqual(
            MeetingPatterns.cleanTitle("Meet - Budget Review", app: "Google Meet"),
            "Budget Review"
        )
        XCTAssertEqual(
            MeetingPatterns.cleanTitle("(3) Meeting Title", app: "Google Meet"),
            "Meeting Title"
        )
    }

    // MARK: - Known Apps Validation

    func testAllKnownAppsHaveProcessNames() {
        for app in MeetingPatterns.knownApps {
            if app.isBrowserBased {
                // Browser-based apps (Google Meet) don't need process names
                continue
            }
            XCTAssertFalse(
                app.processNames.isEmpty,
                "\(app.name) should have at least one process name"
            )
        }
    }
}

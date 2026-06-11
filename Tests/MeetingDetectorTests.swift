import XCTest
@testable import Caddie

final class MeetingDetectorTests: XCTestCase {

    private let engine = MeetingDetector.DecisionEngine()

    // MARK: - DecisionEngine Tests

    func testNoSignals_noMeeting() {
        let result = engine.evaluate(signals: [])
        XCTAssertNil(result)
    }

    func testSingleSignal_noMeeting() {
        let signals = [
            DetectionSignal(
                source: .micState,
                appName: nil,
                processId: nil,
                windowTitle: nil,
                calendarEvent: nil,
                isActive: true
            ),
        ]
        let result = engine.evaluate(signals: signals)
        XCTAssertNil(result)
    }

    func testAudioProcess_plus_mic_confirmsMeeting() {
        let signals = [
            DetectionSignal(
                source: .audioProcess,
                appName: "Zoom",
                processId: 1234,
                windowTitle: nil,
                calendarEvent: nil,
                isActive: true
            ),
            DetectionSignal(
                source: .micState,
                appName: nil,
                processId: nil,
                windowTitle: nil,
                calendarEvent: nil,
                isActive: true
            ),
        ]
        let result = engine.evaluate(signals: signals)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.app, "Zoom")
    }

    func testWindowTitle_plus_calendar_confirmsMeeting() {
        let signals = [
            DetectionSignal(
                source: .windowTitle,
                appName: "Google Meet",
                processId: nil,
                windowTitle: "Weekly Standup",
                calendarEvent: nil,
                isActive: true
            ),
            DetectionSignal(
                source: .googleCalendar,
                appName: nil,
                processId: nil,
                windowTitle: nil,
                calendarEvent: "Team Sync",
                isActive: true
            ),
        ]
        let result = engine.evaluate(signals: signals)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.title, "Team Sync")
    }

    func testTitlePriority_calendarOverWindow() {
        let signals = [
            DetectionSignal(
                source: .audioProcess,
                appName: "Zoom",
                processId: 1234,
                windowTitle: nil,
                calendarEvent: nil,
                isActive: true
            ),
            DetectionSignal(
                source: .windowTitle,
                appName: "Zoom",
                processId: nil,
                windowTitle: "Zoom Meeting Room",
                calendarEvent: nil,
                isActive: true
            ),
            DetectionSignal(
                source: .googleCalendar,
                appName: nil,
                processId: nil,
                windowTitle: nil,
                calendarEvent: "Sprint Planning",
                isActive: true
            ),
        ]
        let result = engine.evaluate(signals: signals)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.title, "Sprint Planning")
    }

    func testGoogleCalendarPlusOtherSignalProducesDetectedMeeting() {
        let signals = [
            DetectionSignal(source: .googleCalendar, appName: nil, processId: nil,
                            windowTitle: nil, calendarEvent: "Sprint Planning", isActive: true),
            DetectionSignal(source: .micState, appName: nil, processId: nil,
                            windowTitle: nil, calendarEvent: nil, isActive: true),
        ]
        let result = engine.evaluate(signals: signals)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.title, "Sprint Planning")
    }

    // MARK: - Calendar Prompt Path (CAL-02)

    @MainActor
    func testGoogleCalendarAloneFiresPrompt() {
        let detector = MeetingDetector()
        var capturedTitle: String?
        var capturedEventID: String?
        var promptCount = 0
        detector.onMeetingPrompt = { title, eventID in
            promptCount += 1
            capturedTitle = title
            capturedEventID = eventID
        }

        detector.handleSignal(
            DetectionSignal(source: .googleCalendar, appName: nil, processId: nil,
                            windowTitle: nil, calendarEvent: "Solo Event",
                            calendarEventID: "evt-1", isActive: true)
        )

        XCTAssertEqual(promptCount, 1)
        XCTAssertEqual(capturedTitle, "Solo Event")
        XCTAssertEqual(capturedEventID, "evt-1")
    }

    @MainActor
    func testSameCalendarEventDoesNotRePrompt() {
        let detector = MeetingDetector()
        var promptCount = 0
        detector.onMeetingPrompt = { _, _ in promptCount += 1 }

        let signal = DetectionSignal(
            source: .googleCalendar, appName: nil, processId: nil,
            windowTitle: nil, calendarEvent: "Solo Event",
            calendarEventID: "evt-1", isActive: true
        )
        detector.handleSignal(signal)
        detector.handleSignal(signal)

        XCTAssertEqual(promptCount, 1)
    }

    @MainActor
    func testCalendarSignalWhileMeetingCurrentDoesNotPrompt() {
        let detector = MeetingDetector()
        var promptCount = 0
        detector.onMeetingPrompt = { _, _ in promptCount += 1 }
        detector.currentMeeting = DetectedMeeting(app: "Zoom", title: "Existing", processId: nil)

        detector.handleSignal(
            DetectionSignal(source: .googleCalendar, appName: nil, processId: nil,
                            windowTitle: nil, calendarEvent: "Solo Event",
                            calendarEventID: "evt-1", isActive: true)
        )

        XCTAssertEqual(promptCount, 0)
    }

    func testTitleFallback_appNameWhenNoOtherTitle() {
        let signals = [
            DetectionSignal(
                source: .audioProcess,
                appName: "Zoom",
                processId: 5678,
                windowTitle: nil,
                calendarEvent: nil,
                isActive: true
            ),
            DetectionSignal(
                source: .micState,
                appName: nil,
                processId: nil,
                windowTitle: nil,
                calendarEvent: nil,
                isActive: true
            ),
        ]
        let result = engine.evaluate(signals: signals)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.title, "Zoom Meeting")
        XCTAssertEqual(result?.processId, 5678)
    }
}

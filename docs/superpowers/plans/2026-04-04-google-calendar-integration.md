# Google Calendar Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace EventKit calendar monitoring with Google Calendar REST API — display today's events in the sidebar and prompt users to record when meetings are detected.

**Architecture:** New `GoogleCalendarService` actor polls Google Calendar API v3 every 5 minutes, caches today's events on `AppState.todayEvents`, and emits detection signals to `MeetingDetector`. When calendar + another signal fires, a macOS notification prompts the user to start recording. `CalendarMonitor` (EventKit) is deleted.

**Tech Stack:** Swift 6, Foundation URLSession, Google Calendar API v3 REST, UNUserNotificationCenter actionable notifications, SwiftUI

---

### Task 1: GoogleCalendarEvent Model

**Files:**
- Create: `Sources/Calendar/GoogleCalendarEvent.swift`
- Create: `Tests/GoogleCalendarEventTests.swift`

- [ ] **Step 1: Write failing tests for Google Calendar event decoding**

```swift
// Tests/GoogleCalendarEventTests.swift
import XCTest
@testable import Caddie

final class GoogleCalendarEventTests: XCTestCase {

    // MARK: - JSON Decoding

    func testDecodesEventFromGoogleAPIResponse() throws {
        let json = """
        {
            "id": "abc123",
            "summary": "Sprint Planning",
            "start": { "dateTime": "2026-04-04T10:00:00-05:00" },
            "end": { "dateTime": "2026-04-04T11:00:00-05:00" },
            "attendees": [
                { "email": "alice@example.com" },
                { "email": "bob@example.com" },
                { "email": "carol@example.com" }
            ],
            "hangoutLink": "https://meet.google.com/abc-defg-hij"
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder().decode(GoogleCalendarEvent.self, from: json)
        XCTAssertEqual(event.id, "abc123")
        XCTAssertEqual(event.summary, "Sprint Planning")
        XCTAssertEqual(event.attendeeCount, 3)
        XCTAssertEqual(event.meetingLink, "https://meet.google.com/abc-defg-hij")
        XCTAssertNotNil(event.startDate)
        XCTAssertNotNil(event.endDate)
    }

    func testDecodesEventWithoutOptionalFields() throws {
        let json = """
        {
            "id": "xyz789",
            "summary": "Quick Chat",
            "start": { "dateTime": "2026-04-04T14:00:00-05:00" },
            "end": { "dateTime": "2026-04-04T14:30:00-05:00" }
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder().decode(GoogleCalendarEvent.self, from: json)
        XCTAssertEqual(event.id, "xyz789")
        XCTAssertEqual(event.attendeeCount, 0)
        XCTAssertNil(event.meetingLink)
    }

    func testDecodesEventsListResponse() throws {
        let json = """
        {
            "items": [
                {
                    "id": "e1",
                    "summary": "Standup",
                    "start": { "dateTime": "2026-04-04T09:00:00-05:00" },
                    "end": { "dateTime": "2026-04-04T09:15:00-05:00" },
                    "attendees": [
                        { "email": "a@x.com" },
                        { "email": "b@x.com" }
                    ]
                },
                {
                    "id": "e2",
                    "summary": "Lunch",
                    "start": { "date": "2026-04-04" },
                    "end": { "date": "2026-04-04" }
                }
            ]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(GoogleCalendarEventsResponse.self, from: json)
        XCTAssertEqual(response.items.count, 2)
    }

    func testSkipsAllDayEvents() throws {
        let json = """
        {
            "id": "allday1",
            "summary": "Company Holiday",
            "start": { "date": "2026-04-04" },
            "end": { "date": "2026-04-05" }
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder().decode(GoogleCalendarEvent.self, from: json)
        XCTAssertTrue(event.isAllDay)
        XCTAssertNil(event.startDate)
    }

    // MARK: - Computed Properties

    func testIsNowReturnsTrueWhenCurrentTimeInWindow() {
        let event = GoogleCalendarEvent(
            id: "test",
            summary: "Now Meeting",
            start: .init(dateTime: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-300)), date: nil),
            end: .init(dateTime: ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600)), date: nil),
            attendees: [.init(email: "a@b.com"), .init(email: "c@d.com")],
            hangoutLink: nil
        )
        XCTAssertTrue(event.isNow)
        XCTAssertFalse(event.isPast)
        XCTAssertFalse(event.isUpcoming)
    }

    func testIsPastReturnsTrueWhenEventEnded() {
        let event = GoogleCalendarEvent(
            id: "test",
            summary: "Old Meeting",
            start: .init(dateTime: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-7200)), date: nil),
            end: .init(dateTime: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600)), date: nil),
            attendees: nil,
            hangoutLink: nil
        )
        XCTAssertTrue(event.isPast)
        XCTAssertFalse(event.isNow)
    }

    func testIsUpcomingReturnsTrueWhenEventInFuture() {
        let event = GoogleCalendarEvent(
            id: "test",
            summary: "Future Meeting",
            start: .init(dateTime: ISO8601DateFormatter().string(from: Date().addingTimeInterval(7200)), date: nil),
            end: .init(dateTime: ISO8601DateFormatter().string(from: Date().addingTimeInterval(10800)), date: nil),
            attendees: nil,
            hangoutLink: nil
        )
        XCTAssertTrue(event.isUpcoming)
        XCTAssertFalse(event.isNow)
    }

    func testAttendeeCountExcludesNilAttendees() {
        let event = GoogleCalendarEvent(
            id: "test",
            summary: "Solo",
            start: .init(dateTime: nil, date: "2026-04-04"),
            end: .init(dateTime: nil, date: "2026-04-04"),
            attendees: nil,
            hangoutLink: nil
        )
        XCTAssertEqual(event.attendeeCount, 0)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project Caddie.xcodeproj -scheme Caddie -only-testing:CaddieTests/GoogleCalendarEventTests 2>&1 | tail -5`
Expected: FAIL — `GoogleCalendarEvent` not defined

- [ ] **Step 3: Implement GoogleCalendarEvent model**

```swift
// Sources/Calendar/GoogleCalendarEvent.swift
import Foundation

struct GoogleCalendarEvent: Codable, Identifiable, Sendable {
    let id: String
    let summary: String
    let start: EventDateTime
    let end: EventDateTime
    let attendees: [Attendee]?
    let hangoutLink: String?

    struct EventDateTime: Codable, Sendable {
        let dateTime: String?
        let date: String?
    }

    struct Attendee: Codable, Sendable {
        let email: String
    }

    // MARK: - Computed Properties

    var isAllDay: Bool {
        start.dateTime == nil && start.date != nil
    }

    var startDate: Date? {
        guard let dt = start.dateTime else { return nil }
        return ISO8601DateFormatter().date(from: dt)
    }

    var endDate: Date? {
        guard let dt = end.dateTime else { return nil }
        return ISO8601DateFormatter().date(from: dt)
    }

    var attendeeCount: Int {
        attendees?.count ?? 0
    }

    var meetingLink: String? {
        hangoutLink
    }

    var isNow: Bool {
        guard let s = startDate, let e = endDate else { return false }
        let now = Date()
        return now >= s && now < e
    }

    var isPast: Bool {
        guard let e = endDate else { return false }
        return Date() >= e
    }

    var isUpcoming: Bool {
        guard let s = startDate else { return false }
        return Date() < s
    }

    var timeUntilStart: TimeInterval? {
        guard let s = startDate else { return nil }
        let interval = s.timeIntervalSinceNow
        return interval > 0 ? interval : nil
    }
}

struct GoogleCalendarEventsResponse: Codable, Sendable {
    let items: [GoogleCalendarEvent]
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Caddie.xcodeproj -scheme Caddie -only-testing:CaddieTests/GoogleCalendarEventTests 2>&1 | tail -5`
Expected: All 8 tests PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/Calendar/GoogleCalendarEvent.swift Tests/GoogleCalendarEventTests.swift
git commit -m "feat: add GoogleCalendarEvent model with Codable decoding and computed state properties"
```

---

### Task 2: GoogleCalendarService Actor

**Files:**
- Create: `Sources/Calendar/GoogleCalendarService.swift`
- Create: `Tests/GoogleCalendarServiceTests.swift`

- [ ] **Step 1: Write failing tests for calendar service**

```swift
// Tests/GoogleCalendarServiceTests.swift
import XCTest
@testable import Caddie

final class GoogleCalendarServiceTests: XCTestCase {

    // MARK: - URL Construction

    func testBuildsFetchURLForToday() async {
        let url = GoogleCalendarService.buildEventsURL()
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(components.host, "www.googleapis.com")
        XCTAssertEqual(components.path, "/calendar/v3/calendars/primary/events")

        let params = Dictionary(uniqueKeysWithValues: components.queryItems!.map { ($0.name, $0.value!) })
        XCTAssertEqual(params["singleEvents"], "true")
        XCTAssertEqual(params["orderBy"], "startTime")
        XCTAssertNotNil(params["timeMin"])
        XCTAssertNotNil(params["timeMax"])
    }

    func testTimeMinIsStartOfToday() async {
        let url = GoogleCalendarService.buildEventsURL()
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let timeMin = components.queryItems!.first { $0.name == "timeMin" }!.value!

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let parsed = formatter.date(from: timeMin)!

        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        XCTAssertEqual(calendar.component(.day, from: parsed), calendar.component(.day, from: startOfToday))
    }

    // MARK: - Event Parsing

    func testParsesEventsFromAPIResponse() async throws {
        let json = """
        {
            "items": [
                {
                    "id": "e1",
                    "summary": "Standup",
                    "start": { "dateTime": "2026-04-04T09:00:00-05:00" },
                    "end": { "dateTime": "2026-04-04T09:15:00-05:00" },
                    "attendees": [{ "email": "a@x.com" }, { "email": "b@x.com" }]
                },
                {
                    "id": "e2",
                    "summary": "Lunch Break",
                    "start": { "date": "2026-04-04" },
                    "end": { "date": "2026-04-04" }
                }
            ]
        }
        """.data(using: .utf8)!

        let events = GoogleCalendarService.parseEvents(from: json)
        // All-day "Lunch Break" is excluded
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.summary, "Standup")
    }

    func testParseEventsReturnsEmptyOnInvalidJSON() {
        let events = GoogleCalendarService.parseEvents(from: Data("not json".utf8))
        XCTAssertTrue(events.isEmpty)
    }

    // MARK: - Filtering

    func testFiltersMeetingEvents() {
        let meetingEvent = GoogleCalendarEvent(
            id: "m1", summary: "Planning",
            start: .init(dateTime: "2026-04-04T10:00:00-05:00", date: nil),
            end: .init(dateTime: "2026-04-04T11:00:00-05:00", date: nil),
            attendees: [.init(email: "a@x.com"), .init(email: "b@x.com")],
            hangoutLink: nil
        )
        let soloEvent = GoogleCalendarEvent(
            id: "s1", summary: "Focus Time",
            start: .init(dateTime: "2026-04-04T14:00:00-05:00", date: nil),
            end: .init(dateTime: "2026-04-04T15:00:00-05:00", date: nil),
            attendees: [.init(email: "a@x.com")],
            hangoutLink: nil
        )
        let allDay = GoogleCalendarEvent(
            id: "a1", summary: "Holiday",
            start: .init(dateTime: nil, date: "2026-04-04"),
            end: .init(dateTime: nil, date: "2026-04-05"),
            attendees: nil,
            hangoutLink: nil
        )

        let filtered = GoogleCalendarService.filterMeetingEvents([meetingEvent, soloEvent, allDay])
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.id, "m1")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project Caddie.xcodeproj -scheme Caddie -only-testing:CaddieTests/GoogleCalendarServiceTests 2>&1 | tail -5`
Expected: FAIL — `GoogleCalendarService` not defined

- [ ] **Step 3: Implement GoogleCalendarService**

```swift
// Sources/Calendar/GoogleCalendarService.swift
import Foundation
import os

actor GoogleCalendarService {
    private let logger = Logger(subsystem: CaddieLogger.subsystem, category: "Calendar")
    private let authManager: GoogleAuthManager
    private var cachedEvents: [GoogleCalendarEvent] = []
    private var pollTimer: Timer?
    private var eventCheckTimer: Timer?
    private var dismissedEventIDs: Set<String> = []
    private var lastActiveEventID: String?

    /// Called when cached events update (for UI).
    var onEventsUpdated: (([GoogleCalendarEvent]) -> Void)?

    /// Called when a calendar-based meeting is detected (for MeetingDetector signal).
    var onSignal: ((DetectionSignal) -> Void)?

    /// Called when calendar + other signal should prompt user.
    var onMeetingPrompt: ((String) -> Void)?

    init(authManager: GoogleAuthManager) {
        self.authManager = authManager
    }

    // MARK: - Lifecycle

    func start() {
        logger.info("Starting Google Calendar service")
        Task { await fetchEvents() }
        startPollTimer()
        startEventCheckTimer()
    }

    func stop() {
        logger.info("Stopping Google Calendar service")
        pollTimer?.invalidate()
        pollTimer = nil
        eventCheckTimer?.invalidate()
        eventCheckTimer = nil
        cachedEvents = []
        lastActiveEventID = nil
    }

    func dismissEvent(_ eventID: String) {
        dismissedEventIDs.insert(eventID)
    }

    // MARK: - Fetching

    func fetchEvents() async {
        do {
            let token = try await authManager.validAccessToken()
            let url = Self.buildEventsURL()
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return }

            if http.statusCode == 401 {
                logger.warning("Google Calendar API returned 401 — token may be revoked")
                return
            }

            guard http.statusCode == 200 else {
                logger.error("Google Calendar API error: HTTP \(http.statusCode)")
                return
            }

            let events = Self.parseEvents(from: data)
            cachedEvents = events
            let allEvents = events
            onEventsUpdated?(allEvents)
            logger.info("Fetched \(events.count) calendar events for today")
        } catch {
            logger.error("Failed to fetch calendar events: \(error.localizedDescription)")
        }
    }

    // MARK: - Event Window Check

    func checkActiveEvents() {
        let meetingEvents = Self.filterMeetingEvents(cachedEvents)
        let activeEvent = meetingEvents.first(where: \.isNow)

        if let event = activeEvent {
            if event.id != lastActiveEventID {
                lastActiveEventID = event.id
                logger.info("Calendar event active: \(event.summary)")
                onSignal?(DetectionSignal(
                    source: .googleCalendar,
                    appName: nil,
                    processId: nil,
                    windowTitle: nil,
                    calendarEvent: event.summary,
                    isActive: true
                ))
            }
        } else if lastActiveEventID != nil {
            lastActiveEventID = nil
            onSignal?(DetectionSignal(
                source: .googleCalendar,
                appName: nil,
                processId: nil,
                windowTitle: nil,
                calendarEvent: nil,
                isActive: false
            ))
        }
    }

    // MARK: - Static Helpers (testable)

    static func buildEventsURL() -> URL {
        let calendar = Calendar.current
        let now = Date()
        let startOfDay = calendar.startOfDay(for: now)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!
        components.queryItems = [
            URLQueryItem(name: "timeMin", value: formatter.string(from: startOfDay)),
            URLQueryItem(name: "timeMax", value: formatter.string(from: endOfDay)),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "maxResults", value: "50"),
        ]
        return components.url!
    }

    static func parseEvents(from data: Data) -> [GoogleCalendarEvent] {
        guard let response = try? JSONDecoder().decode(GoogleCalendarEventsResponse.self, from: data) else {
            return []
        }
        return response.items.filter { !$0.isAllDay }
    }

    static func filterMeetingEvents(_ events: [GoogleCalendarEvent]) -> [GoogleCalendarEvent] {
        events.filter { !$0.isAllDay && $0.attendeeCount >= 2 }
    }

    // MARK: - Timers

    private func startPollTimer() {
        let timer = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { await self.fetchEvents() }
        }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func startEventCheckTimer() {
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { await self.checkActiveEvents() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        eventCheckTimer = timer
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Caddie.xcodeproj -scheme Caddie -only-testing:CaddieTests/GoogleCalendarServiceTests 2>&1 | tail -5`
Expected: All 5 tests PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/Calendar/GoogleCalendarService.swift Tests/GoogleCalendarServiceTests.swift
git commit -m "feat: add GoogleCalendarService actor with API polling, event parsing, and detection signals"
```

---

### Task 3: Update DetectionSignal for Google Calendar

**Files:**
- Modify: `Sources/Detection/MeetingPatterns.swift:190-195` (SignalSource enum)
- Modify: `Sources/Detection/MeetingDetector.swift:173-202` (DecisionEngine)
- Modify: `Tests/MeetingDetectorTests.swift`
- Modify: `Tests/MeetingPatternsTests.swift`

- [ ] **Step 1: Write failing test for .googleCalendar signal source**

Add to `Tests/MeetingDetectorTests.swift`:

```swift
func testGoogleCalendarPlusOtherSignalProducesDetectedMeeting() {
    let engine = DecisionEngine()
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

func testGoogleCalendarAloneDoesNotTrigger() {
    let engine = DecisionEngine()
    let signals = [
        DetectionSignal(source: .googleCalendar, appName: nil, processId: nil,
                        windowTitle: nil, calendarEvent: "Solo Event", isActive: true),
    ]
    let result = engine.evaluate(signals: signals)
    XCTAssertNil(result)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project Caddie.xcodeproj -scheme Caddie -only-testing:CaddieTests/MeetingDetectorTests 2>&1 | tail -5`
Expected: FAIL — `.googleCalendar` not a member of `SignalSource`

- [ ] **Step 3: Add .googleCalendar to SignalSource and update DecisionEngine**

In `Sources/Detection/MeetingPatterns.swift`, replace the `SignalSource` enum (lines 190-195):

```swift
    enum SignalSource: String {
        case audioProcess
        case micState
        case windowTitle
        case googleCalendar
    }
```

In `Sources/Detection/MeetingDetector.swift`, update `DecisionEngine.evaluate()` (lines 173-202). Replace the `hasCalendar` line and the `confirmed` logic:

```swift
struct DecisionEngine {
    func evaluate(signals: [DetectionSignal]) -> DetectedMeeting? {
        let active = signals.filter(\.isActive)
        guard active.count >= 2 else { return nil }

        let hasAudioProcess = active.contains { $0.source == .audioProcess }
        let hasMic = active.contains { $0.source == .micState }
        let hasWindowTitle = active.contains { $0.source == .windowTitle }
        let hasCalendar = active.contains { $0.source == .googleCalendar }

        let confirmed = (hasAudioProcess && hasMic)
                     || (hasAudioProcess && hasWindowTitle)
                     || (hasMic && hasCalendar)
                     || (hasWindowTitle && hasCalendar)
                     || (hasAudioProcess && hasCalendar)

        guard confirmed else { return nil }

        let app = active.first(where: { $0.appName != nil })?.appName ?? "Unknown"
        let title = active.first(where: { $0.calendarEvent != nil })?.calendarEvent
                 ?? active.first(where: { $0.windowTitle != nil })?.windowTitle
                 ?? "\(app) Meeting"
        let pid = active.first(where: { $0.processId != nil })?.processId

        return DetectedMeeting(app: app, title: title, processId: pid)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Caddie.xcodeproj -scheme Caddie -only-testing:CaddieTests/MeetingDetectorTests 2>&1 | tail -5`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/Detection/MeetingPatterns.swift Sources/Detection/MeetingDetector.swift Tests/MeetingDetectorTests.swift
git commit -m "feat: add .googleCalendar signal source to DetectionSignal and DecisionEngine"
```

---

### Task 4: Update MeetingDetector to Use GoogleCalendarService

**Files:**
- Modify: `Sources/Detection/MeetingDetector.swift:33-36` (remove calendarMonitor)
- Modify: `Sources/Detection/MeetingDetector.swift:43-79` (start method)
- Modify: `Sources/Detection/MeetingDetector.swift:81-91` (stop method)

- [ ] **Step 1: Remove CalendarMonitor from MeetingDetector**

In `Sources/Detection/MeetingDetector.swift`, remove the `calendarMonitor` property (line 36):

```swift
// Before:
private var audioMonitor: any DetectionMonitor = AudioProcessMonitor()
private var micMonitor: any DetectionMonitor = MicStateMonitor()
private var windowMonitor: any DetectionMonitor = WindowTitleMonitor()
private var calendarMonitor: any DetectionMonitor = CalendarMonitor()
```

```swift
// After:
private var audioMonitor: any DetectionMonitor = AudioProcessMonitor()
private var micMonitor: any DetectionMonitor = MicStateMonitor()
private var windowMonitor: any DetectionMonitor = WindowTitleMonitor()
```

Add a new callback for prompting the user (after `onMeetingEnded` around line 24):

```swift
var onMeetingPrompt: ((String) -> Void)?
```

- [ ] **Step 2: Update start() to remove calendarMonitor setup**

In the `start()` method, remove the calendar monitor callback setup and `calendarMonitor.start()` call. The GoogleCalendarService will call `handleSignal()` directly via its `onSignal` callback wired in AppState.

Remove these lines from `start()`:
```swift
calendarMonitor.onSignal = { [weak self] signal in
    self?.handleSignal(signal)
}
calendarMonitor.start()
```

- [ ] **Step 3: Update stop() to remove calendarMonitor.stop()**

Remove `calendarMonitor.stop()` from the `stop()` method.

- [ ] **Step 4: Add prompt logic to handleSignal**

In `handleSignal()`, after the DecisionEngine evaluation finds a confirmed meeting, check if the trigger involved `.googleCalendar`. If so, prompt instead of auto-starting:

Replace the meeting detection block (around lines 109-128) with:

```swift
if let detected = engine.evaluate(signals: activeSignals) {
    let hasCalendarSignal = activeSignals.contains { $0.source == .googleCalendar && $0.isActive }

    if hasCalendarSignal && currentMeeting == nil {
        // Calendar-based detection: prompt user instead of auto-starting
        cancelGrace()
        onMeetingPrompt?(detected.title)
    } else if currentMeeting == nil {
        // Non-calendar detection: auto-start as before
        cancelGrace()
        currentMeeting = detected
        isDetectingMeeting = true
        onMeetingStarted?(detected)
        logger.info("Meeting started: \(detected.title) via \(detected.app)")
    } else if currentMeeting != nil {
        cancelGrace()
        currentMeeting = detected
    }
} else if currentMeeting != nil {
    startGrace()
}
```

- [ ] **Step 5: Run all detection tests**

Run: `xcodebuild test -project Caddie.xcodeproj -scheme Caddie -only-testing:CaddieTests/MeetingDetectorTests 2>&1 | tail -10`
Expected: All tests PASS

- [ ] **Step 6: Commit**

```bash
git add Sources/Detection/MeetingDetector.swift
git commit -m "refactor: remove CalendarMonitor from MeetingDetector, add prompt-based calendar detection"
```

---

### Task 5: Actionable Notification for Recording Prompt

**Files:**
- Modify: `Sources/Utilities/NotificationManager.swift`
- Create: `Tests/NotificationManagerTests.swift`

- [ ] **Step 1: Write failing test for record prompt notification**

```swift
// Tests/NotificationManagerTests.swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Caddie.xcodeproj -scheme Caddie -only-testing:CaddieTests/NotificationManagerTests 2>&1 | tail -5`
Expected: FAIL — `recordPromptCategory` not defined

- [ ] **Step 3: Implement record prompt notification**

Add to `Sources/Utilities/NotificationManager.swift`:

```swift
    // MARK: - Meeting Detection Prompt

    static let meetingDetectedCategory = "MEETING_DETECTED"
    static let recordAction = "RECORD_ACTION"
    static let dismissAction = "DISMISS_ACTION"

    static func recordPromptCategory() -> UNNotificationCategory {
        let record = UNNotificationAction(
            identifier: recordAction,
            title: "Record",
            options: [.foreground]
        )
        let dismiss = UNNotificationAction(
            identifier: dismissAction,
            title: "Dismiss",
            options: [.destructive]
        )
        return UNNotificationCategory(
            identifier: meetingDetectedCategory,
            actions: [record, dismiss],
            intentIdentifiers: [],
            options: []
        )
    }

    static func promptToRecord(eventTitle: String) {
        let content = UNMutableNotificationContent()
        content.title = "Meeting Detected: \(eventTitle)"
        content.body = "Your calendar event is in progress. Start recording?"
        content.sound = .default
        content.categoryIdentifier = meetingDetectedCategory

        send(content: content, id: "meeting-prompt")
    }

    static func registerCategories() {
        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories([recordPromptCategory()])
    }
```

Update `requestAuthorization()` to also register categories — add `registerCategories()` call at the end of the method.

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Caddie.xcodeproj -scheme Caddie -only-testing:CaddieTests/NotificationManagerTests 2>&1 | tail -5`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/Utilities/NotificationManager.swift Tests/NotificationManagerTests.swift
git commit -m "feat: add actionable meeting detection notification with Record/Dismiss actions"
```

---

### Task 6: Wire GoogleCalendarService into AppState

**Files:**
- Modify: `Sources/App/AppState.swift`
- Modify: `Sources/App/CaddieApp.swift` (notification delegate)

- [ ] **Step 1: Add todayEvents and calendarService to AppState**

In `Sources/App/AppState.swift`, add after `googleAuthState` (line 46):

```swift
var todayEvents: [GoogleCalendarEvent] = []
private(set) var calendarService: GoogleCalendarService?
```

- [ ] **Step 2: Initialize GoogleCalendarService in initialize()**

In the `initialize()` method, after the auth restore block (after line 76 `googleAuthState = await authManager.state`), add:

```swift
// Start Google Calendar service if signed in
if case .signedIn = googleAuthState {
    let service = GoogleCalendarService(authManager: authManager)
    await service.set(onEventsUpdated: { [weak self] events in
        Task { @MainActor in
            self?.todayEvents = events
        }
    })
    await service.start()
    calendarService = service
}
```

- [ ] **Step 3: Wire calendar signal to MeetingDetector**

After `newCoordinator.start()` (line 169), wire the calendar service signal:

```swift
// Wire Google Calendar detection signals to MeetingDetector
if let service = calendarService {
    await service.set(onSignal: { [weak newCoordinator] signal in
        Task { @MainActor in
            guard let coordinator = newCoordinator else { return }
            await coordinator.detector.handleSignal(signal)
        }
    })
}
```

Note: This requires `handleSignal` to be accessible. If `MeetingDetector.handleSignal` is private, it needs to be made `internal`.

- [ ] **Step 4: Wire meeting prompt to notification**

In the MeetingDetector setup, wire `onMeetingPrompt`:

```swift
newCoordinator.detector.onMeetingPrompt = { title in
    NotificationManager.promptToRecord(eventTitle: title)
}
```

- [ ] **Step 5: Handle notification response in AppDelegate**

In `Sources/App/CaddieApp.swift`, make `AppDelegate` conform to `UNUserNotificationCenterDelegate`:

```swift
func applicationDidFinishLaunching(_ notification: Notification) {
    CaddieLogger.app.info("Caddie launched")
    NotificationManager.requestAuthorization()
    UNUserNotificationCenter.current().delegate = self
    // ... existing observers
}

// MARK: - Notification Response

func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse
) async {
    switch response.actionIdentifier {
    case NotificationManager.recordAction:
        let title = response.notification.request.content.title
            .replacingOccurrences(of: "Meeting Detected: ", with: "")
        appState?.currentMeetingTitle = title
        appState?.startManualRecording()
    case NotificationManager.dismissAction:
        // Dismissed — no action needed, notification clears
        break
    default:
        break
    }
}

// Show notifications even when app is in foreground
func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification
) async -> UNNotificationPresentationOptions {
    [.banner, .sound]
}
```

Add `UNUserNotificationCenterDelegate` to the class declaration.

- [ ] **Step 6: Start/stop calendar service on sign-in/sign-out**

Update `signInToGoogle()` in AppState:

```swift
func signInToGoogle() {
    googleAuthState = .signingIn
    Task {
        do {
            try await authManager.signIn()
            googleAuthState = await authManager.state

            // Start calendar service after successful sign-in
            if case .signedIn = googleAuthState, calendarService == nil {
                let service = GoogleCalendarService(authManager: authManager)
                await service.set(onEventsUpdated: { [weak self] events in
                    Task { @MainActor in self?.todayEvents = events }
                })
                await service.start()
                calendarService = service
            }
        } catch {
            CaddieLogger.auth.error("Google sign-in failed: \(error.localizedDescription)")
            googleAuthState = await authManager.state
        }
    }
}
```

Update `signOutFromGoogle()`:

```swift
func signOutFromGoogle() {
    Task {
        await calendarService?.stop()
        calendarService = nil
        todayEvents = []
        await authManager.signOut()
        googleAuthState = await authManager.state
    }
}
```

- [ ] **Step 7: Build to verify compilation**

Run: `xcodebuild build -project Caddie.xcodeproj -scheme Caddie -configuration Debug -destination 'platform=macOS' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 8: Commit**

```bash
git add Sources/App/AppState.swift Sources/App/CaddieApp.swift
git commit -m "feat: wire GoogleCalendarService into AppState with notification-based recording prompts"
```

---

### Task 7: Today's Schedule Sidebar UI

**Files:**
- Create: `Sources/UI/MainWindow/TodayScheduleView.swift`
- Modify: `Sources/UI/MainWindow/MeetingListView.swift`

- [ ] **Step 1: Create TodayScheduleView**

```swift
// Sources/UI/MainWindow/TodayScheduleView.swift
import SwiftUI

struct TodayScheduleView: View {
    let events: [GoogleCalendarEvent]

    var body: some View {
        if events.isEmpty {
            emptyState
        } else {
            ForEach(events) { event in
                CalendarEventRow(event: event)
            }
        }
    }

    private var emptyState: some View {
        Text("No events today")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
    }
}

struct CalendarEventRow: View {
    let event: GoogleCalendarEvent

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(accentColor)
                .frame(width: 3, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.summary)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(timeRangeText)
                    if event.attendeeCount > 0 {
                        Text("·")
                        Text("\(event.attendeeCount) attendees")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            Spacer()

            Text(statusText)
                .font(.system(size: 10))
                .foregroundStyle(statusColor)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .opacity(event.isPast ? 0.5 : 1.0)
        .background(event.isNow ? Color.green.opacity(0.08) : Color.clear)
        .cornerRadius(6)
    }

    private var accentColor: Color {
        if event.isPast { return Color.gray }
        if event.isNow { return Color.green }
        return Color.blue
    }

    private var statusText: String {
        if event.isPast { return "Done" }
        if event.isNow { return "Now" }
        if let interval = event.timeUntilStart {
            if interval < 3600 {
                return "in \(Int(interval / 60))m"
            }
            return "in \(Int(interval / 3600))h"
        }
        return ""
    }

    private var statusColor: Color {
        if event.isNow { return .green }
        return .secondary
    }

    private var timeRangeText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        guard let start = event.startDate, let end = event.endDate else { return "" }
        return "\(formatter.string(from: start)) – \(formatter.string(from: end))"
    }
}
```

- [ ] **Step 2: Add Today's Schedule section to MeetingListView**

In `Sources/UI/MainWindow/MeetingListView.swift`, add an `Environment` property for `appState` and the schedule section.

Add at the top of the struct:

```swift
@Environment(AppState.self) private var appState
```

In the `body`, insert the schedule section above the existing meetings list. Replace the body:

```swift
var body: some View {
    List(selection: $selectedMeetingId) {
        if case .signedIn = appState.googleAuthState {
            Section {
                TodayScheduleView(events: appState.todayEvents)
            } header: {
                HStack {
                    Text("Today's Schedule")
                    Spacer()
                    if !appState.todayEvents.isEmpty {
                        Text("\(appState.todayEvents.count) events")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }

        if meetings.isEmpty && appState.todayEvents.isEmpty {
            emptyState
        } else {
            Section("Recordings") {
                ForEach(groupedMeetings, id: \.date) { group in
                    Section(Formatters.sectionDate(group.date)) {
                        ForEach(group.meetings) { meeting in
                            MeetingRow(meeting: meeting)
                                .tag(meeting.id)
                        }
                    }
                }
            }
        }
    }
    .listStyle(.sidebar)
    .searchable(text: $searchText, prompt: "Search meetings")
    .navigationTitle("Caddie")
}
```

- [ ] **Step 3: Build to verify UI compiles**

Run: `xcodebuild build -project Caddie.xcodeproj -scheme Caddie -configuration Debug -destination 'platform=macOS' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add Sources/UI/MainWindow/TodayScheduleView.swift Sources/UI/MainWindow/MeetingListView.swift
git commit -m "feat: add Today's Schedule section to sidebar showing Google Calendar events"
```

---

### Task 8: Remove CalendarMonitor and Calendar Entitlement

**Files:**
- Delete: `Sources/Detection/CalendarMonitor.swift`
- Modify: `Resources/Caddie.entitlements`

- [ ] **Step 1: Delete CalendarMonitor.swift**

```bash
git rm Sources/Detection/CalendarMonitor.swift
```

- [ ] **Step 2: Remove calendar entitlement**

Edit `Resources/Caddie.entitlements` — remove the calendar key:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key>
    <true/>
</dict>
</plist>
```

- [ ] **Step 3: Verify no remaining references to CalendarMonitor**

```bash
grep -r "CalendarMonitor" Sources/ Tests/
```

Expected: No matches. If any remain, update those files to remove the references.

- [ ] **Step 4: Build to verify nothing breaks**

Run: `xcodebuild build -project Caddie.xcodeproj -scheme Caddie -configuration Debug -destination 'platform=macOS' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Run full test suite**

Run: `xcodebuild test -project Caddie.xcodeproj -scheme Caddie -configuration Debug -destination 'platform=macOS' 2>&1 | tail -10`
Expected: All tests PASS

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "refactor: remove CalendarMonitor (EventKit) and calendar entitlement, replaced by GoogleCalendarService"
```

---

### Task 9: Update README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update README with Google Calendar feature**

Add to the features section:

- Google Calendar integration — displays today's schedule in the sidebar, prompts to record when meetings are detected
- No Apple Calendar dependency — events fetched directly from Google Calendar API

Update the permissions section to remove Calendar and note that Google sign-in is used instead.

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: update README with Google Calendar integration feature"
```

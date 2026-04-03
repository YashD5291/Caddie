import XCTest
@testable import Caddie

final class GoogleCalendarServiceTests: XCTestCase {

    // MARK: - buildEventsURL

    func testBuildsFetchURLForToday() {
        let url = GoogleCalendarService.buildEventsURL()
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!

        XCTAssertEqual(components.host, "www.googleapis.com")
        XCTAssertEqual(components.path, "/calendar/v3/calendars/primary/events")

        let items = components.queryItems ?? []
        let names = items.map(\.name)
        XCTAssertTrue(names.contains("singleEvents"), "Missing singleEvents param")
        XCTAssertTrue(names.contains("orderBy"), "Missing orderBy param")
        XCTAssertTrue(names.contains("timeMin"), "Missing timeMin param")
        XCTAssertTrue(names.contains("timeMax"), "Missing timeMax param")

        XCTAssertEqual(items.first(where: { $0.name == "singleEvents" })?.value, "true")
        XCTAssertEqual(items.first(where: { $0.name == "orderBy" })?.value, "startTime")
    }

    // MARK: - timeMin is start of today

    func testTimeMinIsStartOfToday() {
        let url = GoogleCalendarService.buildEventsURL()
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let items = components.queryItems ?? []

        guard let timeMinValue = items.first(where: { $0.name == "timeMin" })?.value else {
            XCTFail("timeMin param missing")
            return
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let timeMin = formatter.date(from: timeMinValue) else {
            XCTFail("timeMin is not a valid ISO8601 date: \(timeMinValue)")
            return
        }

        let calendar = Calendar.current
        let expectedStartOfDay = calendar.startOfDay(for: Date())
        XCTAssertEqual(timeMin, expectedStartOfDay,
                       "timeMin should be the start of today")
    }

    // MARK: - parseEvents

    func testParsesEventsFromAPIResponse() {
        let json = """
        {
            "items": [
                {
                    "id": "timed1",
                    "summary": "Team Sync",
                    "start": { "dateTime": "2026-04-03T10:00:00Z" },
                    "end":   { "dateTime": "2026-04-03T10:30:00Z" },
                    "attendees": [
                        { "email": "alice@example.com" },
                        { "email": "bob@example.com" }
                    ]
                },
                {
                    "id": "allday1",
                    "summary": "Company Holiday",
                    "start": { "date": "2026-04-03" },
                    "end":   { "date": "2026-04-04" }
                }
            ]
        }
        """.data(using: .utf8)!

        let events = GoogleCalendarService.parseEvents(from: json)

        XCTAssertEqual(events.count, 1, "All-day event should be excluded")
        XCTAssertEqual(events[0].id, "timed1")
        XCTAssertEqual(events[0].summary, "Team Sync")
    }

    func testParseEventsReturnsEmptyOnInvalidJSON() {
        let garbage = Data("not valid json at all }{".utf8)
        let events = GoogleCalendarService.parseEvents(from: garbage)
        XCTAssertTrue(events.isEmpty)
    }

    func testParseEventsReturnsEmptyOnEmptyData() {
        let events = GoogleCalendarService.parseEvents(from: Data())
        XCTAssertTrue(events.isEmpty)
    }

    // MARK: - filterMeetingEvents

    func testFiltersMeetingEvents() {
        let now = Date()
        let twoAttendee = makeTimedEvent(
            id: "meeting1",
            summary: "Team Sync",
            start: now.addingTimeInterval(-300),
            end: now.addingTimeInterval(300),
            attendees: ["alice@example.com", "bob@example.com"]
        )
        let soloEvent = makeTimedEvent(
            id: "solo1",
            summary: "Focus Block",
            start: now.addingTimeInterval(-300),
            end: now.addingTimeInterval(300),
            attendees: ["alice@example.com"]
        )
        let allDayEvent = makeAllDayEvent(id: "allday1", summary: "Holiday")

        let result = GoogleCalendarService.filterMeetingEvents([twoAttendee, soloEvent, allDayEvent])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].id, "meeting1")
    }

    func testFiltersMeetingEventsExcludesNoAttendees() {
        let now = Date()
        let noAttendees = makeTimedEvent(
            id: "no-attendees",
            summary: "Blocked",
            start: now.addingTimeInterval(-300),
            end: now.addingTimeInterval(300),
            attendees: []
        )

        let result = GoogleCalendarService.filterMeetingEvents([noAttendees])
        XCTAssertTrue(result.isEmpty)
    }

    func testFiltersMeetingEventsAllowsTwoOrMore() {
        let now = Date()
        let threeAttendees = makeTimedEvent(
            id: "big-meeting",
            summary: "All Hands",
            start: now.addingTimeInterval(-300),
            end: now.addingTimeInterval(300),
            attendees: ["a@x.com", "b@x.com", "c@x.com"]
        )

        let result = GoogleCalendarService.filterMeetingEvents([threeAttendees])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].id, "big-meeting")
    }

    // MARK: - Helpers

    private let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private func makeTimedEvent(
        id: String,
        summary: String,
        start: Date,
        end: Date,
        attendees: [String]
    ) -> GoogleCalendarEvent {
        let attendeesJSON = attendees
            .map { "{ \"email\": \"\($0)\" }" }
            .joined(separator: ", ")
        let json = """
        {
            "id": "\(id)",
            "summary": "\(summary)",
            "start": { "dateTime": "\(iso8601.string(from: start))" },
            "end":   { "dateTime": "\(iso8601.string(from: end))" },
            "attendees": [\(attendeesJSON)]
        }
        """.data(using: .utf8)!
        return try! JSONDecoder().decode(GoogleCalendarEvent.self, from: json)
    }

    private func makeAllDayEvent(id: String, summary: String) -> GoogleCalendarEvent {
        let json = """
        {
            "id": "\(id)",
            "summary": "\(summary)",
            "start": { "date": "2026-04-03" },
            "end":   { "date": "2026-04-04" }
        }
        """.data(using: .utf8)!
        return try! JSONDecoder().decode(GoogleCalendarEvent.self, from: json)
    }
}

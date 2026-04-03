import XCTest
@testable import Caddie

final class GoogleCalendarEventTests: XCTestCase {

    // MARK: - Full event decoding

    func testDecodesFullEvent() throws {
        let json = """
        {
            "id": "abc123",
            "summary": "Team Standup",
            "start": { "dateTime": "2026-04-03T10:00:00Z" },
            "end":   { "dateTime": "2026-04-03T10:30:00Z" },
            "attendees": [
                { "email": "alice@example.com" },
                { "email": "bob@example.com" }
            ],
            "hangoutLink": "https://meet.google.com/abc-defg-hij"
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder().decode(GoogleCalendarEvent.self, from: json)

        XCTAssertEqual(event.id, "abc123")
        XCTAssertEqual(event.summary, "Team Standup")
        XCTAssertEqual(event.start.dateTime, "2026-04-03T10:00:00Z")
        XCTAssertEqual(event.end.dateTime, "2026-04-03T10:30:00Z")
        XCTAssertEqual(event.attendees?.count, 2)
        XCTAssertEqual(event.attendees?[0].email, "alice@example.com")
        XCTAssertEqual(event.hangoutLink, "https://meet.google.com/abc-defg-hij")
    }

    // MARK: - Optional fields absent

    func testDecodesEventWithoutOptionalFields() throws {
        let json = """
        {
            "id": "xyz789",
            "summary": "Solo Focus Block",
            "start": { "dateTime": "2026-04-03T14:00:00Z" },
            "end":   { "dateTime": "2026-04-03T15:00:00Z" }
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder().decode(GoogleCalendarEvent.self, from: json)

        XCTAssertEqual(event.id, "xyz789")
        XCTAssertNil(event.attendees)
        XCTAssertNil(event.hangoutLink)
    }

    // MARK: - Events list response

    func testDecodesEventsListResponse() throws {
        let json = """
        {
            "items": [
                {
                    "id": "e1",
                    "summary": "Event One",
                    "start": { "dateTime": "2026-04-03T09:00:00Z" },
                    "end":   { "dateTime": "2026-04-03T09:30:00Z" }
                },
                {
                    "id": "e2",
                    "summary": "Event Two",
                    "start": { "dateTime": "2026-04-03T11:00:00Z" },
                    "end":   { "dateTime": "2026-04-03T12:00:00Z" }
                }
            ]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(GoogleCalendarEventsResponse.self, from: json)

        XCTAssertEqual(response.items.count, 2)
        XCTAssertEqual(response.items[0].id, "e1")
        XCTAssertEqual(response.items[1].id, "e2")
    }

    // MARK: - All-day events

    func testAllDayEventHasDateNotDateTime() throws {
        let json = """
        {
            "id": "allday1",
            "summary": "Company Holiday",
            "start": { "date": "2026-04-03" },
            "end":   { "date": "2026-04-04" }
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder().decode(GoogleCalendarEvent.self, from: json)

        XCTAssertTrue(event.isAllDay)
        XCTAssertNil(event.startDate)
    }

    func testTimedEventIsNotAllDay() throws {
        let json = """
        {
            "id": "timed1",
            "summary": "Meeting",
            "start": { "dateTime": "2026-04-03T10:00:00Z" },
            "end":   { "dateTime": "2026-04-03T11:00:00Z" }
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder().decode(GoogleCalendarEvent.self, from: json)

        XCTAssertFalse(event.isAllDay)
        XCTAssertNotNil(event.startDate)
    }

    // MARK: - isNow computed property

    func testIsNowWhenCurrentTimeIsBetweenStartAndEnd() throws {
        let now = Date()
        let start = now.addingTimeInterval(-600)  // 10 min ago
        let end   = now.addingTimeInterval(600)   // 10 min from now

        let event = makeEvent(start: start, end: end)

        XCTAssertTrue(event.isNow)
    }

    func testIsNowFalseWhenEventHasEnded() throws {
        let now = Date()
        let start = now.addingTimeInterval(-3600)
        let end   = now.addingTimeInterval(-1800)

        let event = makeEvent(start: start, end: end)

        XCTAssertFalse(event.isNow)
    }

    func testIsNowFalseWhenEventHasNotStarted() throws {
        let now = Date()
        let start = now.addingTimeInterval(1800)
        let end   = now.addingTimeInterval(3600)

        let event = makeEvent(start: start, end: end)

        XCTAssertFalse(event.isNow)
    }

    // MARK: - isPast computed property

    func testIsPastWhenEndIsInPast() throws {
        let now = Date()
        let event = makeEvent(
            start: now.addingTimeInterval(-3600),
            end:   now.addingTimeInterval(-1)
        )
        XCTAssertTrue(event.isPast)
    }

    func testIsPastFalseWhenEndIsInFuture() throws {
        let now = Date()
        let event = makeEvent(
            start: now.addingTimeInterval(-600),
            end:   now.addingTimeInterval(600)
        )
        XCTAssertFalse(event.isPast)
    }

    // MARK: - isUpcoming computed property

    func testIsUpcomingWhenStartIsInFuture() throws {
        let now = Date()
        let event = makeEvent(
            start: now.addingTimeInterval(1800),
            end:   now.addingTimeInterval(3600)
        )
        XCTAssertTrue(event.isUpcoming)
    }

    func testIsUpcomingFalseWhenStartIsInPast() throws {
        let now = Date()
        let event = makeEvent(
            start: now.addingTimeInterval(-600),
            end:   now.addingTimeInterval(600)
        )
        XCTAssertFalse(event.isUpcoming)
    }

    // MARK: - attendeeCount

    func testAttendeeCountIsZeroWhenNil() throws {
        let json = """
        {
            "id": "no-attendees",
            "summary": "Solo",
            "start": { "dateTime": "2026-04-03T10:00:00Z" },
            "end":   { "dateTime": "2026-04-03T10:30:00Z" }
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder().decode(GoogleCalendarEvent.self, from: json)
        XCTAssertEqual(event.attendeeCount, 0)
    }

    func testAttendeeCountReflectsArrayLength() throws {
        let json = """
        {
            "id": "with-attendees",
            "summary": "Call",
            "start": { "dateTime": "2026-04-03T10:00:00Z" },
            "end":   { "dateTime": "2026-04-03T10:30:00Z" },
            "attendees": [
                { "email": "a@x.com" },
                { "email": "b@x.com" },
                { "email": "c@x.com" }
            ]
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder().decode(GoogleCalendarEvent.self, from: json)
        XCTAssertEqual(event.attendeeCount, 3)
    }

    // MARK: - Helpers

    private let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private func makeEvent(start: Date, end: Date) -> GoogleCalendarEvent {
        let startStr = iso8601.string(from: start)
        let endStr   = iso8601.string(from: end)
        let json = """
        {
            "id": "test-id",
            "summary": "Test Event",
            "start": { "dateTime": "\(startStr)" },
            "end":   { "dateTime": "\(endStr)" }
        }
        """.data(using: .utf8)!
        return try! JSONDecoder().decode(GoogleCalendarEvent.self, from: json)
    }
}

import Foundation

struct GoogleCalendarEvent: Codable, Identifiable, Sendable {
    let id: String
    let summary: String?
    let status: String?
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
        let responseStatus: String?
    }

    var displayName: String { summary ?? "Untitled Event" }

    var isCancelled: Bool { status == "cancelled" }

    var isAllDay: Bool { start.dateTime == nil && start.date != nil }

    var startDate: Date? {
        guard let dt = start.dateTime else { return nil }
        return Formatters.parseISO8601(dt)
    }

    var endDate: Date? {
        guard let dt = end.dateTime else { return nil }
        return Formatters.parseISO8601(dt)
    }

    var attendeeCount: Int { attendees?.count ?? 0 }
    var meetingLink: String? { hangoutLink }

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

    // MARK: - Lead-time prompt helpers (now-injectable for deterministic testing)

    /// True once the event's end time has passed relative to `now`.
    func hasEnded(now: Date) -> Bool {
        guard let e = endDate else { return false }
        return now >= e
    }

    /// True when the event starts within `lead` seconds of `now`. The interval may
    /// be negative for already-started events, which are still considered "within".
    func startsWithin(_ lead: TimeInterval, now: Date) -> Bool {
        guard let s = startDate else { return false }
        return s.timeIntervalSince(now) <= lead
    }

    /// True when the event should trigger the "record this meeting?" prompt:
    /// it is within the lead-time window and has not yet ended.
    func shouldPrompt(leadTime: TimeInterval, now: Date) -> Bool {
        !hasEnded(now: now) && startsWithin(leadTime, now: now)
    }
}

struct GoogleCalendarEventsResponse: Codable, Sendable {
    let items: [GoogleCalendarEvent]
}

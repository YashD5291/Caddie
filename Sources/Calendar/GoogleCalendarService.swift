import Foundation
import os

actor GoogleCalendarService {
    private let logger = Logger(subsystem: "com.caddie.app", category: "Calendar")
    private let authManager: GoogleAuthManager
    private var cachedEvents: [GoogleCalendarEvent] = []
    private var pollTimer: Timer?
    private var eventCheckTimer: Timer?
    private var dismissedEventIDs: Set<String> = []
    private var lastActiveEventID: String?

    var onEventsUpdated: (([GoogleCalendarEvent]) -> Void)?
    var onSignal: ((DetectionSignal) -> Void)?

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
                logger.warning("Google Calendar API 401 — token may be revoked")
                return
            }
            guard http.statusCode == 200 else {
                logger.error("Google Calendar API error: HTTP \(http.statusCode)")
                return
            }
            let events = Self.parseEvents(from: data)
            cachedEvents = events
            onEventsUpdated?(events)
            logger.info("Fetched \(events.count) calendar events")
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
                onSignal?(DetectionSignal(
                    source: .googleCalendar,
                    appName: nil, processId: nil, windowTitle: nil,
                    calendarEvent: event.summary, isActive: true
                ))
            }
        } else if lastActiveEventID != nil {
            lastActiveEventID = nil
            onSignal?(DetectionSignal(
                source: .googleCalendar,
                appName: nil, processId: nil, windowTitle: nil,
                calendarEvent: nil, isActive: false
            ))
        }
    }

    // MARK: - Static Helpers (testable)

    static func buildEventsURL() -> URL {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
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

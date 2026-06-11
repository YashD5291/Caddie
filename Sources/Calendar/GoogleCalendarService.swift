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

    var onEventsUpdated: (@Sendable ([GoogleCalendarEvent]) -> Void)?
    var onSignal: (@Sendable (DetectionSignal) -> Void)?

    init(authManager: GoogleAuthManager) {
        self.authManager = authManager
    }

    // MARK: - Configuration

    func setCallbacks(
        onEventsUpdated: (@Sendable ([GoogleCalendarEvent]) -> Void)?,
        onSignal: (@Sendable (DetectionSignal) -> Void)?
    ) {
        self.onEventsUpdated = onEventsUpdated
        self.onSignal = onSignal
    }

    func setOnSignal(_ callback: (@Sendable (DetectionSignal) -> Void)?) {
        self.onSignal = callback
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
        // If an event was active, emit a deactivating signal so the detector drops the
        // lingering calendar signal and clears its prompted-event state on sign-out.
        if lastActiveEventID != nil {
            onSignal?(DetectionSignal(
                source: .googleCalendar,
                appName: nil, processId: nil, windowTitle: nil,
                calendarEvent: nil, calendarEventID: nil, isActive: false
            ))
        }
        cachedEvents = []
        lastActiveEventID = nil
    }

    func dismissEvent(_ eventID: String) {
        dismissedEventIDs.insert(eventID)
    }

    #if DEBUG
    /// Test seam: inspect whether an event ID has been dismissed. Only the
    /// internal `dismissedEventIDs` set is consulted at runtime.
    func isDismissed(_ eventID: String) -> Bool {
        dismissedEventIDs.contains(eventID)
    }
    #endif

    // MARK: - Fetching

    func fetchEvents() async {
        do {
            let token = try await authManager.validAccessToken()
            let calendarIDs = try await fetchCalendarIDs(token: token)
            let (timeMin, timeMax) = Self.todayTimeWindow()
            var allEvents: [GoogleCalendarEvent] = []

            await withTaskGroup(of: [GoogleCalendarEvent].self) { group in
                for calendarID in calendarIDs {
                    group.addTask { [self] in
                        await self.fetchEventsFromCalendar(calendarID: calendarID, token: token, timeMin: timeMin, timeMax: timeMax)
                    }
                }
                for await events in group {
                    allEvents.append(contentsOf: events)
                }
            }

            let unique = Self.deduplicateAndSort(allEvents)
            cachedEvents = unique
            onEventsUpdated?(unique)
            logger.info("Fetched \(unique.count) events from \(calendarIDs.count) calendars")
        } catch {
            logger.error("Failed to fetch calendar events: \(error.localizedDescription)")
        }
    }

    // MARK: - Calendar List

    private func fetchCalendarIDs(token: String) async throws -> [String] {
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            logger.warning("calendarList fetch failed: HTTP \(status), falling back to primary")
            return ["primary"]
        }

        struct CalendarListResponse: Decodable {
            let items: [CalendarEntry]
        }
        struct CalendarEntry: Decodable {
            let id: String
            let accessRole: String?
            let selected: Bool?
        }

        let list = try JSONDecoder().decode(CalendarListResponse.self, from: data)
        // Only include calendars the user has selected (visible in their UI)
        let selectedIDs = list.items
            .filter { $0.selected ?? false }
            .map(\.id)
        return selectedIDs.isEmpty ? ["primary"] : selectedIDs
    }

    // MARK: - Per-Calendar Fetch

    private func fetchEventsFromCalendar(calendarID: String, token: String, timeMin: String, timeMax: String) async -> [GoogleCalendarEvent] {
        let url = Self.buildEventsURL(calendarID: calendarID, timeMin: timeMin, timeMax: timeMax)
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                logger.warning("Events fetch failed for \(calendarID): HTTP \(status)")
                return []
            }
            return Self.parseEvents(from: data)
        } catch {
            logger.error("Events fetch error for \(calendarID): \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Event Window Check

    func checkActiveEvents() {
        let meetingEvents = Self.filterMeetingEvents(cachedEvents)
        // Skip dismissed events: treat them as if no event is active so they never re-prompt.
        let activeEvent = meetingEvents.first { $0.isNow && !dismissedEventIDs.contains($0.id) }
        if let event = activeEvent {
            // Finding 1: only consume the event (record lastActiveEventID) when we can
            // actually deliver the signal. If onSignal is nil (e.g. during the model-load
            // startup window), leave lastActiveEventID unchanged so the event re-fires
            // exactly once after setOnSignal wires the callback.
            guard let onSignal else { return }
            if event.id != lastActiveEventID {
                lastActiveEventID = event.id
                onSignal(DetectionSignal(
                    source: .googleCalendar,
                    appName: nil, processId: nil, windowTitle: nil,
                    calendarEvent: event.displayName, calendarEventID: event.id, isActive: true
                ))
            }
        } else if lastActiveEventID != nil {
            lastActiveEventID = nil
            onSignal?(DetectionSignal(
                source: .googleCalendar,
                appName: nil, processId: nil, windowTitle: nil,
                calendarEvent: nil, calendarEventID: nil, isActive: false
            ))
        }
    }

    // MARK: - Test Support

    #if DEBUG
    /// Seed the in-memory event cache directly (used by unit tests that exercise
    /// `checkActiveEvents` without a live network fetch).
    func injectCachedEvents(_ events: [GoogleCalendarEvent]) {
        cachedEvents = events
    }
    #endif

    // MARK: - Static Helpers (testable)

    static func todayTimeWindow() -> (timeMin: String, timeMax: String) {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return (formatter.string(from: startOfDay), formatter.string(from: endOfDay))
    }

    static func buildEventsURL(calendarID: String = "primary", timeMin: String, timeMax: String) -> URL {
        let encodedID = calendarID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? calendarID
        var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/\(encodedID)/events")!
        components.queryItems = [
            URLQueryItem(name: "timeMin", value: timeMin),
            URLQueryItem(name: "timeMax", value: timeMax),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "maxResults", value: "50"),
        ]
        return components.url!
    }

    /// Legacy overload for existing tests
    static func buildEventsURL() -> URL {
        let (timeMin, timeMax) = todayTimeWindow()
        return buildEventsURL(calendarID: "primary", timeMin: timeMin, timeMax: timeMax)
    }

    static func parseEvents(from data: Data) -> [GoogleCalendarEvent] {
        do {
            let response = try JSONDecoder().decode(GoogleCalendarEventsResponse.self, from: data)
            return response.items.filter { !$0.isAllDay && !$0.isCancelled }
        } catch {
            let logger = Logger(subsystem: "com.caddie.app", category: "Calendar")
            logger.error("Failed to decode calendar events: \(error)")
            if let preview = String(data: data.prefix(500), encoding: .utf8) {
                logger.debug("Response preview: \(preview)")
            }
            return []
        }
    }

    static func filterMeetingEvents(_ events: [GoogleCalendarEvent]) -> [GoogleCalendarEvent] {
        events.filter { !$0.isAllDay && !$0.isCancelled && $0.attendeeCount >= 2 }
    }

    static func deduplicateAndSort(_ events: [GoogleCalendarEvent]) -> [GoogleCalendarEvent] {
        var seen = Set<String>()
        let unique = events.filter { seen.insert($0.id).inserted }
        return unique.sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
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

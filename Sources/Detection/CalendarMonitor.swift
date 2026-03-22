import EventKit
import Foundation
import os

final class CalendarMonitor: DetectionMonitor, @unchecked Sendable {

    var onSignal: ((DetectionSignal) -> Void)?

    private let logger = Logger(subsystem: "com.caddie.app", category: "CalendarMonitor")
    private let eventStore = EKEventStore()
    private var timer: Timer?
    private var lastEventTitle: String?
    private var hasAccess = false

    func start() {
        logger.info("Starting calendar monitor")
        requestAccess()
    }

    func stop() {
        logger.info("Stopping calendar monitor")
        timer?.invalidate()
        timer = nil
        lastEventTitle = nil
    }

    // MARK: - Private

    private func requestAccess() {
        if #available(macOS 14.0, *) {
            eventStore.requestFullAccessToEvents { [weak self] granted, error in
                guard let self else {
                    CaddieLogger.detection.warning("CalendarMonitor deallocated -- access callback dropped")
                    return
                }
                self.handleAccessResult(granted: granted, error: error)
            }
        } else {
            eventStore.requestAccess(to: .event) { [weak self] granted, error in
                guard let self else {
                    CaddieLogger.detection.warning("CalendarMonitor deallocated -- access callback dropped")
                    return
                }
                self.handleAccessResult(granted: granted, error: error)
            }
        }
    }

    private func handleAccessResult(granted: Bool, error: Error?) {
        if let error = error {
            logger.error("Calendar access error: \(error.localizedDescription)")
        }

        hasAccess = granted
        guard granted else {
            logger.warning("Calendar access denied")
            return
        }

        logger.info("Calendar access granted")
        Task { @MainActor [weak self] in
            guard let self else {
                CaddieLogger.detection.warning("CalendarMonitor deallocated -- post-access setup dropped")
                return
            }
            self.poll()
            self.startTimer()
        }
    }

    private func startTimer() {
        let t = Timer(timeInterval: 30.0, repeats: true) { [weak self] _ in
            guard let self else {
                CaddieLogger.detection.warning("CalendarMonitor deallocated -- poll timer orphaned")
                return
            }
            self.poll()
        }
        t.tolerance = 5.0
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func poll() {
        guard hasAccess else { return }

        let now = Date()
        let start = now.addingTimeInterval(-60)
        let end = now.addingTimeInterval(60)
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = eventStore.events(matching: predicate)

        // Filter: no all-day events, must have 2+ attendees
        let meetingEvents = events.filter { event in
            !event.isAllDay && (event.attendees?.count ?? 0) >= 2
        }

        if let event = meetingEvents.first {
            let title = event.title ?? "Untitled Meeting"
            if title != lastEventTitle {
                logger.info("Calendar event detected: \(title)")
                lastEventTitle = title
                onSignal?(DetectionSignal(
                    source: .calendar,
                    appName: nil,
                    processId: nil,
                    windowTitle: nil,
                    calendarEvent: title,
                    isActive: true
                ))
            }
        } else if lastEventTitle != nil {
            logger.info("No active calendar event")
            lastEventTitle = nil
            onSignal?(DetectionSignal(
                source: .calendar,
                appName: nil,
                processId: nil,
                windowTitle: nil,
                calendarEvent: nil,
                isActive: false
            ))
        }
    }
}

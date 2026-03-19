import Foundation
import os

// MARK: - DetectedMeeting

struct DetectedMeeting {
    let app: String
    let title: String
    let processId: pid_t?
}

// MARK: - MeetingDetector

@Observable
final class MeetingDetector {

    // MARK: - Public State

    var activeSignals: [DetectionSignal] = []
    var isDetectingMeeting = false
    var currentMeeting: DetectedMeeting?

    var onMeetingStarted: ((DetectedMeeting) -> Void)?
    var onMeetingEnded: (() -> Void)?

    var graceSeconds: TimeInterval = 15.0

    // MARK: - Private

    private let logger = Logger(subsystem: "com.caddie.app", category: "MeetingDetector")
    private let engine = DecisionEngine()

    private var audioMonitor: any DetectionMonitor = AudioProcessMonitor()
    private var micMonitor: any DetectionMonitor = MicStateMonitor()
    private var windowMonitor: any DetectionMonitor = WindowTitleMonitor()
    private var calendarMonitor: any DetectionMonitor = CalendarMonitor()

    private var graceTimer: Timer?
    private var graceElapsed: TimeInterval = 0

    // MARK: - Lifecycle

    func start() {
        logger.info("Starting meeting detector")

        audioMonitor.onSignal = { [weak self] signal in self?.handleSignal(signal) }
        micMonitor.onSignal = { [weak self] signal in self?.handleSignal(signal) }
        windowMonitor.onSignal = { [weak self] signal in self?.handleSignal(signal) }
        calendarMonitor.onSignal = { [weak self] signal in self?.handleSignal(signal) }

        audioMonitor.start()
        micMonitor.start()
        windowMonitor.start()
        calendarMonitor.start()
    }

    func stop() {
        logger.info("Stopping meeting detector")
        audioMonitor.stop()
        micMonitor.stop()
        windowMonitor.stop()
        calendarMonitor.stop()
        cancelGrace()
        activeSignals = []
        isDetectingMeeting = false
        currentMeeting = nil
    }

    // MARK: - Signal Handling

    func handleSignal(_ signal: DetectionSignal) {
        // Remove existing signal with same source + appName
        activeSignals.removeAll { existing in
            existing.source == signal.source && existing.appName == signal.appName
        }

        // Add new signal if active
        if signal.isActive {
            activeSignals.append(signal)
        }

        // Evaluate
        let result = engine.evaluate(signals: activeSignals)

        if let meeting = result {
            if !isDetectingMeeting {
                // New meeting detected
                logger.info("Meeting started: \(meeting.app) — \(meeting.title)")
                isDetectingMeeting = true
                currentMeeting = meeting
                cancelGrace()
                onMeetingStarted?(meeting)
            } else {
                // Already detecting — update title if better, reset grace
                if let current = currentMeeting, meeting.title != current.title {
                    logger.info("Meeting title updated: \(meeting.title)")
                    currentMeeting = meeting
                }
                cancelGrace()
            }
        } else if isDetectingMeeting {
            // No meeting detected but was detecting — start grace period
            startGrace()
        }
    }

    // MARK: - Grace Period

    private func startGrace() {
        guard graceTimer == nil else { return }
        logger.info("Starting grace period (\(self.graceSeconds)s)")
        graceElapsed = 0
        let t = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.graceTick()
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        graceTimer = t
    }

    private func graceTick() {
        graceElapsed += 3.0
        if graceElapsed >= graceSeconds {
            logger.info("Grace period expired — meeting ended")
            cancelGrace()
            let wasDetecting = isDetectingMeeting
            isDetectingMeeting = false
            currentMeeting = nil
            activeSignals = []
            if wasDetecting {
                onMeetingEnded?()
            }
        }
    }

    private func cancelGrace() {
        graceTimer?.invalidate()
        graceTimer = nil
        graceElapsed = 0
    }
}

// MARK: - DecisionEngine

extension MeetingDetector {

    struct DecisionEngine {

        func evaluate(signals: [DetectionSignal]) -> DetectedMeeting? {
            let active = signals.filter(\.isActive)
            guard active.count >= 2 else { return nil }

            let hasAudioProcess = active.contains { $0.source == .audioProcess }
            let hasMic = active.contains { $0.source == .micState }
            let hasWindowTitle = active.contains { $0.source == .windowTitle }
            let hasCalendar = active.contains { $0.source == .calendar }

            let confirmed = (hasAudioProcess && hasMic)
                         || (hasAudioProcess && hasWindowTitle)
                         || (hasMic && hasCalendar)
                         || (hasWindowTitle && hasCalendar)

            guard confirmed else { return nil }

            let appName = active.compactMap(\.appName).first ?? "Unknown"
            let calendarTitle = active.compactMap(\.calendarEvent).first
            let windowTitle = active.compactMap(\.windowTitle).first
            let title = calendarTitle ?? windowTitle ?? "\(appName) Meeting"
            let pid = active.compactMap(\.processId).first

            return DetectedMeeting(app: appName, title: title, processId: pid)
        }
    }
}

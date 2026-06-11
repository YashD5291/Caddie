import Foundation
import os

// MARK: - DetectedMeeting

struct DetectedMeeting: Sendable {
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

    var onMeetingPrompt: ((_ title: String, _ eventID: String?) -> Void)?

    var graceSeconds: TimeInterval = 15.0

    // MARK: - Private

    private let logger = Logger(subsystem: "com.caddie.app", category: "MeetingDetector")
    private let engine = DecisionEngine()

    private var audioMonitor: any DetectionMonitor = AudioProcessMonitor()
    private var micMonitor: any DetectionMonitor = MicStateMonitor()
    private var windowMonitor: any DetectionMonitor = WindowTitleMonitor()

    private var graceTimer: Timer?
    private var graceElapsed: TimeInterval = 0

    /// Calendar event IDs already prompted this session. Prevents re-prompting for the
    /// same in-progress event when the calendar service re-fires its active signal.
    /// Cleared when the event deactivates (so a re-occurrence can prompt again) and on stop().
    private var promptedEventIDs: Set<String> = []

    // MARK: - Lifecycle

    func start() {
        logger.info("Starting meeting detector")

        audioMonitor.onSignal = { [weak self] signal in
            guard let self else {
                CaddieLogger.detection.warning("MeetingDetector deallocated -- audio signal dropped")
                return
            }
            self.handleSignal(signal)
        }
        micMonitor.onSignal = { [weak self] signal in
            guard let self else {
                CaddieLogger.detection.warning("MeetingDetector deallocated -- mic signal dropped")
                return
            }
            self.handleSignal(signal)
        }
        windowMonitor.onSignal = { [weak self] signal in
            guard let self else {
                CaddieLogger.detection.warning("MeetingDetector deallocated -- window signal dropped")
                return
            }
            self.handleSignal(signal)
        }
        audioMonitor.start()
        micMonitor.start()
        windowMonitor.start()
    }

    func stop() {
        logger.info("Stopping meeting detector")
        audioMonitor.stop()
        micMonitor.stop()
        windowMonitor.stop()
        cancelGrace()
        activeSignals = []
        isDetectingMeeting = false
        currentMeeting = nil
        promptedEventIDs = []
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

        // Calendar special-case: a lone active .googleCalendar signal fires the
        // notification prompt directly. The DecisionEngine requires >=2 active signals,
        // but the other monitors (audio/mic/window) don't run in production, so a single
        // calendar signal must bypass the engine to reach the user. The user decides
        // whether to record via the notification — we do NOT set currentMeeting here.
        if signal.source == .googleCalendar {
            if signal.isActive {
                if currentMeeting == nil {
                    let eventID = signal.calendarEventID
                    let alreadyPrompted = eventID.map { promptedEventIDs.contains($0) } ?? false
                    if !alreadyPrompted {
                        cancelGrace()
                        onMeetingPrompt?(signal.calendarEvent ?? "Meeting", eventID)
                        if let eventID { promptedEventIDs.insert(eventID) }
                    }
                }
            } else {
                // Event ended: drop its prompted state so a future re-occurrence can prompt.
                // A deactivating signal with no eventID (e.g. sign-out teardown from
                // GoogleCalendarService.stop()) clears all prompted state.
                if let eventID = signal.calendarEventID {
                    promptedEventIDs.remove(eventID)
                } else {
                    promptedEventIDs.removeAll()
                }
            }
            // Calendar signals never drive DecisionEngine-based currentMeeting tracking,
            // but a deactivating signal must still let grace/teardown run if a meeting
            // was being tracked via the dormant multi-signal path.
            if signal.isActive {
                return
            }
        }

        // Evaluate
        if let detected = engine.evaluate(signals: activeSignals) {
            let hasCalendarSignal = activeSignals.contains { $0.source == .googleCalendar && $0.isActive }

            if hasCalendarSignal && currentMeeting == nil {
                // Calendar-based detection: prompt user instead of auto-starting
                cancelGrace()
                let eventID = activeSignals.first { $0.source == .googleCalendar && $0.calendarEventID != nil }?.calendarEventID
                onMeetingPrompt?(detected.title, eventID)
            } else if currentMeeting == nil {
                // Non-calendar detection: track the active meeting so grace-period
                // teardown can run. Auto-start was removed (recording is user-initiated);
                // this branch only maintains detector state.
                cancelGrace()
                currentMeeting = detected
                isDetectingMeeting = true
                logger.info("Meeting detected: \(detected.title) via \(detected.app)")
            } else if currentMeeting != nil {
                cancelGrace()
                currentMeeting = detected
            }
        } else if currentMeeting != nil {
            startGrace()
        }
    }

    // MARK: - Grace Period

    private func startGrace() {
        guard graceTimer == nil else { return }
        logger.info("Starting grace period (\(self.graceSeconds)s)")
        graceElapsed = 0
        let t = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self else {
                CaddieLogger.detection.warning("MeetingDetector deallocated -- grace timer orphaned")
                return
            }
            self.graceTick()
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
            isDetectingMeeting = false
            currentMeeting = nil
            activeSignals = []
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
}

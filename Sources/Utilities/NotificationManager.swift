import UserNotifications
import os

enum NotificationManager {

    private static let logger = Logger(subsystem: CaddieLogger.subsystem, category: "Notifications")

    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                logger.error("Notification auth failed: \(error.localizedDescription)")
            } else {
                logger.info("Notification auth granted: \(granted)")
            }
        }
        registerCategories()
    }

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
        send(id: "meeting-prompt", content: content)
    }

    static func registerCategories() {
        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories([recordPromptCategory()])
    }

    static func recordingStarted(title: String, mode: RecordingMode) {
        let content = UNMutableNotificationContent()
        content.title = "Recording Started"
        let modeText = mode == .systemAndMic ? "system audio + microphone" : "microphone only"
        content.body = "\(title) -- recording \(modeText)"
        content.sound = nil  // Silent -- don't interrupt meeting
        send(id: "recording-started", content: content)
    }

    static func transcriptionComplete(title: String) {
        let content = UNMutableNotificationContent()
        content.title = "Transcription Complete"
        content.body = "\(title) is ready to review"
        content.sound = .default
        send(id: "transcription-complete", content: content)
    }

    static func transcriptionError(title: String, error: String) {
        let content = UNMutableNotificationContent()
        content.title = "Transcription Failed"
        content.body = "\(title) -- \(error)"
        content.sound = .default
        send(id: "transcription-error", content: content)
    }

    static func systemAudioFallback() {
        let content = UNMutableNotificationContent()
        content.title = "System Audio Unavailable"
        content.body = "Recording with microphone only. System audio capture failed -- check Screen Recording permission."
        content.sound = nil
        send(id: "system-audio-fallback", content: content)
    }

    private static func send(id: String, content: UNNotificationContent) {
        let request = UNNotificationRequest(
            identifier: "com.caddie.\(id)-\(UUID().uuidString.prefix(8))",
            content: content,
            trigger: nil  // Deliver immediately
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                logger.error("Failed to send notification '\(id)': \(error.localizedDescription)")
            }
        }
    }
}

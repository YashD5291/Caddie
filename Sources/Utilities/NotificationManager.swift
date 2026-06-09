import UserNotifications
import os

enum NotificationManager {

    private static let logger = Logger(subsystem: CaddieLogger.subsystem, category: "Notifications")

    enum AuthState: Equatable {
        case authorized
        case undetermined
        case denied
    }

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

    /// Pure mapping from system status to app-level state. Provisional allows delivery,
    /// so it collapses into `.authorized` for UI purposes.
    static func authState(from status: UNAuthorizationStatus) -> AuthState {
        switch status {
        case .authorized, .provisional:
            return .authorized
        case .notDetermined:
            return .undetermined
        case .denied:
            return .denied
        @unknown default:
            return .denied
        }
    }

    static func currentAuthState() async -> AuthState {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return authState(from: settings.authorizationStatus)
    }

    /// Deep link to System Settings → Notifications, scoped to Caddie. macOS may ignore the
    /// `id` query and just open the Notifications pane on older versions — that's acceptable.
    static var notificationSettingsURL: URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.notifications?id=com.caddie.app")!
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

    /// Stable, deterministic identifier for a meeting-prompt notification. Re-firing a prompt
    /// for the same event reuses this identifier so the system replaces (not stacks) the banner.
    static func promptIdentifier(eventID: String) -> String {
        "com.caddie.meeting-prompt-\(eventID)"
    }

    static func promptToRecord(eventTitle: String, eventID: String) {
        let content = UNMutableNotificationContent()
        content.title = "Meeting Detected: \(eventTitle)"
        content.body = "Your calendar event is in progress. Start recording?"
        content.sound = .default
        content.categoryIdentifier = meetingDetectedCategory
        content.userInfo = ["eventID": eventID]
        send(identifier: promptIdentifier(eventID: eventID), content: content)
    }

    static func registerCategories() {
        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories([recordPromptCategory()])
    }

    static func recordingStarted(title: String) {
        let content = UNMutableNotificationContent()
        content.title = "Recording Started"
        content.body = title
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

    private static func send(id: String, content: UNNotificationContent) {
        send(identifier: "com.caddie.\(id)-\(UUID().uuidString.prefix(8))", content: content)
    }

    /// Send with an explicit, caller-controlled identifier. Used for the meeting prompt so a
    /// re-fired prompt for the same event replaces the existing banner instead of stacking.
    private static func send(identifier: String, content: UNNotificationContent) {
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil  // Deliver immediately
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                logger.error("Failed to send notification '\(identifier)': \(error.localizedDescription)")
            }
        }
    }
}

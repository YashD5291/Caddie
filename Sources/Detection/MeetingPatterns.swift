import Foundation
import os

// MARK: - MeetingApp

struct MeetingApp {
    let name: String
    let processNames: [String]
    let bundleIds: [String]
    let titlePatterns: [NSRegularExpression]
    let isBrowserBased: Bool

    init(
        name: String,
        processNames: [String] = [],
        bundleIds: [String] = [],
        titlePatterns: [String] = [],
        isBrowserBased: Bool = false
    ) {
        self.name = name
        self.processNames = processNames
        self.bundleIds = bundleIds
        self.titlePatterns = titlePatterns.compactMap { pattern in
            do {
                return try NSRegularExpression(pattern: pattern, options: [])
            } catch {
                let logger = Logger(subsystem: "com.caddie.app", category: "MeetingPatterns")
                logger.error("Invalid regex pattern '\(pattern)' for app \(name): \(error.localizedDescription)")
                return nil
            }
        }
        self.isBrowserBased = isBrowserBased
    }
}

// MARK: - MeetingPatterns

enum MeetingPatterns {

    static let knownApps: [MeetingApp] = [
        MeetingApp(
            name: "Zoom",
            processNames: ["zoom.us", "zoom"],
            bundleIds: ["us.zoom.xos"],
            titlePatterns: ["^Zoom Meeting", "^Zoom Webinar"]
        ),
        MeetingApp(
            name: "Microsoft Teams",
            processNames: ["Microsoft Teams", "Teams"],
            bundleIds: ["com.microsoft.teams", "com.microsoft.teams2"],
            titlePatterns: []
        ),
        MeetingApp(
            name: "Google Meet",
            processNames: [],
            bundleIds: [],
            titlePatterns: ["^Meet\\s*[-\u{2013}\u{2014}]\\s*"],
            isBrowserBased: true
        ),
        MeetingApp(
            name: "Slack",
            processNames: ["Slack"],
            bundleIds: ["com.tinyspeck.slackmacgap"],
            titlePatterns: []
        ),
        MeetingApp(
            name: "Discord",
            processNames: ["Discord"],
            bundleIds: ["com.hnc.Discord"],
            titlePatterns: []
        ),
        MeetingApp(
            name: "Webex",
            processNames: ["Cisco Webex Meetings", "Webex"],
            bundleIds: ["com.webex.meetingmanager"],
            titlePatterns: []
        ),
        MeetingApp(
            name: "FaceTime",
            processNames: ["FaceTime"],
            bundleIds: ["com.apple.FaceTime"],
            titlePatterns: []
        ),
        MeetingApp(
            name: "Skype",
            processNames: ["Skype"],
            bundleIds: ["com.skype.skype"],
            titlePatterns: []
        ),
    ]

    static let browsers: [String] = [
        "Google Chrome",
        "Safari",
        "Arc",
        "Firefox",
        "Brave Browser",
        "Microsoft Edge",
    ]

    // MARK: - Lookup

    static func appForProcess(_ processName: String) -> String? {
        for app in knownApps {
            if app.processNames.contains(processName) {
                return app.name
            }
        }
        return nil
    }

    static func isBrowser(_ processName: String) -> Bool {
        browsers.contains(processName)
    }

    static func isMeetingTitle(_ title: String, forApp appName: String) -> Bool {
        guard let app = knownApps.first(where: { $0.name == appName }) else {
            return false
        }
        if app.titlePatterns.isEmpty {
            return true
        }
        let range = NSRange(title.startIndex..., in: title)
        return app.titlePatterns.contains { pattern in
            pattern.firstMatch(in: title, options: [], range: range) != nil
        }
    }

    // MARK: - Title Cleaning

    static func cleanTitle(_ rawTitle: String, app: String) -> String {
        var title = rawTitle

        // Strip browser notification counts like "(3) "
        if let range = title.range(of: #"^\(\d+\)\s*"#, options: .regularExpression) {
            title.removeSubrange(range)
        }

        switch app {
        case "Zoom":
            // Remove "- Zoom Meeting" suffix
            if let range = title.range(of: #"\s*-\s*Zoom Meeting$"#, options: .regularExpression) {
                title.removeSubrange(range)
            }
            // Remove "Zoom Meeting -" prefix
            if let range = title.range(of: #"^Zoom Meeting\s*-\s*"#, options: .regularExpression) {
                title.removeSubrange(range)
            }

        case "Microsoft Teams":
            // Remove "| Microsoft Teams" suffix
            if let range = title.range(of: #"\s*\|\s*Microsoft Teams$"#, options: .regularExpression) {
                title.removeSubrange(range)
            }

        case "Google Meet":
            // Remove "Meet - " prefix
            if let range = title.range(of: #"^Meet\s*[-\u{2013}\u{2014}]\s*"#, options: .regularExpression) {
                title.removeSubrange(range)
            }
            // Remove "- Google Meet" suffix
            if let range = title.range(of: #"\s*-\s*Google Meet$"#, options: .regularExpression) {
                title.removeSubrange(range)
            }

        case "Slack":
            // Remove "- Slack" suffix
            if let range = title.range(of: #"\s*-\s*Slack$"#, options: .regularExpression) {
                title.removeSubrange(range)
            }

        default:
            break
        }

        return title.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - DetectionSignal

struct DetectionSignal {
    let source: SignalSource
    let appName: String?
    let processId: pid_t?
    let windowTitle: String?
    let calendarEvent: String?
    let calendarEventID: String?
    let isActive: Bool

    init(
        source: SignalSource,
        appName: String?,
        processId: pid_t?,
        windowTitle: String?,
        calendarEvent: String?,
        calendarEventID: String? = nil,
        isActive: Bool
    ) {
        self.source = source
        self.appName = appName
        self.processId = processId
        self.windowTitle = windowTitle
        self.calendarEvent = calendarEvent
        self.calendarEventID = calendarEventID
        self.isActive = isActive
    }

    enum SignalSource: String {
        case audioProcess
        case micState
        case windowTitle
        case googleCalendar
    }
}

// MARK: - DetectionMonitor

protocol DetectionMonitor {
    var onSignal: ((DetectionSignal) -> Void)? { get set }
    func start()
    func stop()
}

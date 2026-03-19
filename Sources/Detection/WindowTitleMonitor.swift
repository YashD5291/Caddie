import CoreGraphics
import Foundation
import os

final class WindowTitleMonitor: DetectionMonitor {

    var onSignal: ((DetectionSignal) -> Void)?

    private let logger = Logger(subsystem: "com.caddie.app", category: "WindowTitleMonitor")
    private var timer: Timer?
    private var lastMatchedTitles: [String: String] = [:]  // appName -> title

    func start() {
        logger.info("Starting window title monitor")
        poll()
        let t = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
        t.tolerance = 1.0
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        logger.info("Stopping window title monitor")
        timer?.invalidate()
        timer = nil
        lastMatchedTitles = [:]
    }

    // MARK: - Private

    private func poll() {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return }

        var currentMatches: [String: String] = [:]

        for window in windowList {
            guard let ownerName = window[kCGWindowOwnerName as String] as? String else { continue }
            let windowName = window[kCGWindowName as String] as? String ?? ""

            // Check native meeting apps
            if let appName = MeetingPatterns.appForProcess(ownerName) {
                if !windowName.isEmpty, MeetingPatterns.isMeetingTitle(windowName, forApp: appName) {
                    let cleaned = MeetingPatterns.cleanTitle(windowName, app: appName)
                    if !cleaned.isEmpty {
                        currentMatches[appName] = cleaned
                    }
                }
                continue
            }

            // Check browser-based apps
            if MeetingPatterns.isBrowser(ownerName), !windowName.isEmpty {
                for app in MeetingPatterns.knownApps where app.isBrowserBased {
                    if MeetingPatterns.isMeetingTitle(windowName, forApp: app.name) {
                        let cleaned = MeetingPatterns.cleanTitle(windowName, app: app.name)
                        if !cleaned.isEmpty {
                            currentMatches[app.name] = cleaned
                        }
                    }
                }
            }
        }

        // Emit signals for new or changed matches
        for (appName, title) in currentMatches {
            if lastMatchedTitles[appName] != title {
                logger.info("Window title match: \(appName) — \(title)")
                onSignal?(DetectionSignal(
                    source: .windowTitle,
                    appName: appName,
                    processId: nil,
                    windowTitle: title,
                    calendarEvent: nil,
                    isActive: true
                ))
            }
        }

        // Emit signals for lost matches
        for appName in lastMatchedTitles.keys where currentMatches[appName] == nil {
            logger.info("Window title lost: \(appName)")
            onSignal?(DetectionSignal(
                source: .windowTitle,
                appName: appName,
                processId: nil,
                windowTitle: nil,
                calendarEvent: nil,
                isActive: false
            ))
        }

        lastMatchedTitles = currentMatches
    }
}

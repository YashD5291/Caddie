import SwiftUI
import UserNotifications

@main
struct CaddieApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState()
    @Environment(\.openWindow) private var openWindow

    init() {
        appDelegate.appState = appState
        // openWindow must be captured from a View context — reading @Environment
        // here in init() returns the default no-op and logs a SwiftUI warning.
        // The capture happens in MenuBarView's .onAppear below.
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(appState)
                .onAppear {
                    // MenuBarExtra is created at launch — use this to open the main window.
                    // SwiftUI Window scenes are lazy and won't auto-show alongside MenuBarExtra.
                    appDelegate.openWindowAction = openWindow
                    if !appState.hasOpenedMainWindow {
                        appState.hasOpenedMainWindow = true
                        openWindow(id: "main")
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
        } label: {
            switch appState.status {
            case .idle:
                Image(systemName: "mic.badge.plus")
                    .symbolRenderingMode(.monochrome)
            case .recording:
                Image(systemName: "record.circle.fill")
                    .symbolRenderingMode(.monochrome)
            case .transcribing:
                Image(systemName: "waveform")
                    .symbolRenderingMode(.monochrome)
            }
        }
        .menuBarExtraStyle(.menu)

        Window("Caddie", id: "main") {
            ContentView()
                .environment(appState)
        }
        .defaultSize(width: 800, height: 600)

        Settings {
            SettingsView()
                .environment(appState)
        }
    }
}

// MARK: - AppDelegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var appState: AppState?
    var openWindowAction: OpenWindowAction?

    func applicationDidFinishLaunching(_ notification: Notification) {
        CaddieLogger.app.info("Caddie launched")
        UNUserNotificationCenter.current().delegate = self
        NotificationManager.requestAuthorization()

        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification, object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        CaddieLogger.app.info("Caddie terminating")
    }

    // MARK: - Reopen on Dock Click

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            NSApp.setActivationPolicy(.regular)
            // Try existing window first, fall back to SwiftUI openWindow
            if let window = Self.findMainWindow() {
                window.makeKeyAndOrderFront(nil)
            } else {
                openWindowAction?(id: "main")
            }
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }

    // MARK: - OAuth URL Scheme Handler

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first,
              url.scheme == GoogleOAuthConfig.callbackScheme else { return }
        guard let appState else { return }
        Task {
            await appState.authManager.handleRedirectURL(url)
            let newState = await appState.authManager.state
            appState.googleAuthState = newState
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Window Lifecycle

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              Self.isMainAppWindow(window) else { return }
        NSApp.setActivationPolicy(.regular)
    }

    @objc private func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            let hasVisibleMainWindow = NSApp.windows.contains {
                $0.isVisible && Self.isMainAppWindow($0)
            }
            if !hasVisibleMainWindow {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    // MARK: - Notification Handling

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        switch response.actionIdentifier {
        case NotificationManager.recordAction:
            let title = response.notification.request.content.title
                .replacingOccurrences(of: "Meeting Detected: ", with: "")
            await MainActor.run {
                // startManualRecording(title:) sets currentMeetingTitle itself.
                appState?.startManualRecording(title: title)
            }
        case NotificationManager.dismissAction:
            // Suppress re-prompting for this event for the rest of the session.
            if let eventID = response.notification.request.content.userInfo["eventID"] as? String {
                await appState?.calendarService?.dismissEvent(eventID)
            }
        default:
            break
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    // MARK: - Window Identification

    private static func isMainAppWindow(_ window: NSWindow) -> Bool {
        if let identifier = window.identifier?.rawValue, identifier.contains("main") {
            return true
        }
        return window.styleMask.contains(.titled)
            && !window.className.contains("Settings")
            && !window.className.contains("MenuBar")
            && window.title.contains("Caddie")
    }

    static func findMainWindow() -> NSWindow? {
        NSApp.windows.first(where: { isMainAppWindow($0) })
    }
}

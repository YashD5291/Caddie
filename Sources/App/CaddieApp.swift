import SwiftUI
import UserNotifications
import Sparkle

// MARK: - Sparkle Updater Environment

/// Carries the single app-scoped Sparkle updater controller into SwiftUI views
/// (menu bar + settings) the same way `appState` is injected. There is exactly
/// one controller for the app lifetime; views read it from here.
private struct SparkleUpdaterControllerKey: EnvironmentKey {
    static let defaultValue: SPUStandardUpdaterController? = nil
}

extension EnvironmentValues {
    var sparkleUpdaterController: SPUStandardUpdaterController? {
        get { self[SparkleUpdaterControllerKey.self] }
        set { self[SparkleUpdaterControllerKey.self] = newValue }
    }
}

@main
struct CaddieApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState()
    @Environment(\.openWindow) private var openWindow

    init() {
        appDelegate.appState = appState
        // openWindow must be captured from a View context — reading @Environment
        // here in init() returns the default no-op and logs a SwiftUI warning.
        // The capture happens in the MenuBarExtra LABEL's .onAppear below (see note
        // there for why the label — not the content view — is the correct seam).
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(appState)
                .environment(\.sparkleUpdaterController, appDelegate.updaterController)
        } label: {
            // Under `.menuBarExtraStyle(.menu)` the MenuBarExtra CONTENT view
            // (MenuBarView above) is instantiated LAZILY — only when the user
            // first clicks the menu bar icon. Its `.onAppear` therefore does NOT
            // fire at launch. The LABEL below, however, renders immediately at
            // launch (the mic icon is visible in the menu bar right away), so it
            // is the only view guaranteed to run at startup. Capture the
            // openWindow action and perform the one-time launch auto-open here.
            Group {
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
            .onAppear {
                // Idempotent: the label may re-appear on redraws; re-assigning the
                // same action is harmless, and the `hasOpenedMainWindow` guard makes
                // the auto-open strictly one-time.
                appDelegate.openWindowAction = openWindow
                if !appState.hasOpenedMainWindow {
                    appState.hasOpenedMainWindow = true
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
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
                .environment(\.sparkleUpdaterController, appDelegate.updaterController)
        }
    }
}

// MARK: - AppDelegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var appState: AppState?
    var openWindowAction: OpenWindowAction?

    /// The single, app-scoped Sparkle updater. `startingUpdater: true` begins
    /// automatic-check scheduling at launch. Initialized on MainActor (AppDelegate
    /// is @MainActor), satisfying Swift 6 isolation.
    let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

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
        // Decide from our OWN window inventory, not the `flag` argument. For a
        // MenuBarExtra + single-`Window` app, `hasVisibleWindows` is unreliable
        // (status/menu-bar windows can make it true even when the main window is
        // closed), which historically caused the reopen to be skipped.
        let hasVisibleMainWindow = NSApp.windows.contains {
            $0.isVisible && Self.isMainAppWindow($0)
        }
        if Self.shouldReopenMainWindow(hasVisibleMainWindow: hasVisibleMainWindow) {
            // Converge on the proven menu-bar "Open Caddie" path: always drive the
            // SwiftUI openWindow action. A closed single-`Window` scene retains its
            // NSWindow, but SwiftUI has torn down its content — makeKeyAndOrderFront
            // on that stale window does not restore it; only openWindow(id:) does.
            guard let openWindowAction else {
                // No silent failure (project rule). openWindowAction is captured in
                // the MenuBarExtra label's .onAppear, which fires at launch — so nil
                // here means the label has not rendered yet (should not happen in
                // practice). Log so the regression is visible rather than a dead click.
                CaddieLogger.app.warning(
                    "Dock reopen requested but openWindowAction is nil — cannot open main window (label .onAppear has not run)"
                )
                return true
            }
            NSApp.setActivationPolicy(.regular)
            openWindowAction(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }

    /// Pure decision seam for Dock reopen: reopen the main window only when there
    /// is no visible main window. Extracted so the reopen rule is unit-testable
    /// without AppKit windows and guarded against regression.
    static func shouldReopenMainWindow(hasVisibleMainWindow: Bool) -> Bool {
        !hasVisibleMainWindow
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
            // Prefer the title carried in userInfo; fall back to stripping the banner prefix.
            let content = response.notification.request.content
            let title = (content.userInfo["title"] as? String)
                ?? content.title.replacingOccurrences(of: "Meeting Detected: ", with: "")
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
}

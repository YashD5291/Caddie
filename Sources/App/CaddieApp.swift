import SwiftUI

@main
struct CaddieApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState()

    init() {
        appDelegate.appState = appState
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(appState)
        } label: {
            switch appState.status {
            case .idle:
                Image(systemName: "mic.badge.plus")
                    .symbolRenderingMode(.monochrome)
            case .recording:
                if appState.recordingMode == .micOnly {
                    Image(systemName: "mic.fill")
                        .symbolRenderingMode(.monochrome)
                } else {
                    Image(systemName: "record.circle.fill")
                        .symbolRenderingMode(.monochrome)
                }
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
final class AppDelegate: NSObject, NSApplicationDelegate {
    var appState: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        CaddieLogger.app.info("Caddie launched")
        NotificationManager.requestAuthorization()

        // LSUIElement=false means the app launches as a regular app with
        // window, dock icon, and menu bar. We observe window lifecycle to
        // switch to accessory mode when all windows close.
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
            Self.findMainWindow()?.makeKeyAndOrderFront(nil)
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

    // MARK: - Window Identification

    private static func isMainAppWindow(_ window: NSWindow) -> Bool {
        // Match by SwiftUI Window identifier when available, fall back to title
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

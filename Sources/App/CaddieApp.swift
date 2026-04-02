import SwiftUI

@main
struct CaddieApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState()
    @Environment(\.openWindow) private var openWindow

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
                .onAppear {
                    // Switch to regular app mode when main window appears
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .defaultSize(width: 800, height: 600)

        Settings {
            SettingsView()
                .environment(appState)
        }
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    var appState: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        CaddieLogger.app.info("Caddie launched")
        NotificationManager.requestAuthorization()

        // Open main window on launch so the app behaves like a standard macOS app
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.regular)
            if let window = NSApp.windows.first(where: { $0.title.contains("Caddie") && $0.styleMask.contains(.titled) }) {
                window.makeKeyAndOrderFront(nil)
            }
            NSApp.activate(ignoringOtherApps: true)
        }

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
            // User clicked dock icon with no visible windows — reopen main window
            NSApp.setActivationPolicy(.regular)
            if let window = NSApp.windows.first(where: { $0.title.contains("Caddie") && $0.styleMask.contains(.titled) }) {
                window.makeKeyAndOrderFront(nil)
            }
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
            await MainActor.run {
                appState.googleAuthState = newState
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Window Lifecycle

    @objc private func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            let hasVisibleMainWindow = NSApp.windows.contains {
                $0.isVisible && $0.styleMask.contains(.titled)
                    && !$0.className.contains("Settings")
                    && $0.title.contains("Caddie")
            }
            if !hasVisibleMainWindow {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}

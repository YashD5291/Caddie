import SwiftUI

@main
struct CaddieApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState()

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

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        CaddieLogger.app.info("Caddie launched")

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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Dynamic Activation Policy

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              isMainAppWindow(window) else { return }
        NSApp.setActivationPolicy(.regular)
    }

    @objc private func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async {
            let hasVisibleMainWindow = NSApp.windows.contains {
                $0.isVisible && self.isMainAppWindow($0)
            }
            if !hasVisibleMainWindow {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    private func isMainAppWindow(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.titled)
            && !window.className.contains("Settings")
            && !window.className.contains("MenuBar")
            && window.title.contains("Caddie")
    }
}

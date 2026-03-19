import SwiftUI

@main
struct CaddieApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(appState)
        } label: {
            menuBarLabel
        }

        WindowGroup {
            ContentView()
                .environment(appState)
                .task {
                    do {
                        try appState.initialize()
                    } catch {
                        CaddieLogger.app.error("Failed to initialize AppState: \(error.localizedDescription)")
                    }
                }
        }

        Settings {
            SettingsView()
        }
    }

    @ViewBuilder
    private var menuBarLabel: some View {
        switch appState.status {
        case .idle:
            Image(systemName: "mic.badge.plus")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.primary)
        case .recording:
            Image(systemName: "record.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.red)
        case .transcribing:
            Image(systemName: "waveform")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.orange)
        }
    }
}

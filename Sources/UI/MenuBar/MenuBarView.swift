import SwiftUI
import GRDB

private let menuBarLogger = CaddieLogger.app

struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        statusSection
        Divider()
        recentMeetingsSection
        Divider()
        actionsSection
        Divider()
        Button {
            NSApp.terminate(nil)
        } label: {
            Label("Quit Caddie", systemImage: "power")
        }
    }

    // MARK: - Status

    @ViewBuilder
    private var statusSection: some View {
        switch appState.status {
        case .idle:
            Text("No Active Meeting")

        case .recording:
            Text("\u{1F534} \(appState.currentMeetingTitle ?? "Recording...")")
            Text("Recording \u{00B7} \(Formatters.duration(seconds: Int(appState.recordingDuration)))")
            Button {
                confirmStopRecording()
            } label: {
                Label("Stop Recording", systemImage: "stop.circle.fill")
            }

        case .transcribing:
            Text("Transcribing...")
        }
    }

    // MARK: - Recent Meetings

    @ViewBuilder
    private var recentMeetingsSection: some View {
        let meetings = fetchRecentMeetings()
        if !meetings.isEmpty {
            Section("Recent") {
                ForEach(meetings) { meeting in
                    Button {
                        openWindow(id: "main")
                        NSApp.activate(ignoringOtherApps: true)
                    } label: {
                        Text(menuLabel(for: meeting))
                    }
                }
            }
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private var actionsSection: some View {
        Button {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        } label: {
            Label("Open Caddie", systemImage: "macwindow")
        }

        SettingsLink {
            Label("Settings...", systemImage: "gear")
        }
    }

    // MARK: - Helpers

    private func confirmStopRecording() {
        let title = appState.currentMeetingTitle ?? "this meeting"
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Stop Recording?"
            alert.informativeText = "This will stop recording '\(title)'."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Stop")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                appState.stopRecording()
            }
        }
    }

    private func fetchRecentMeetings() -> [Meeting] {
        guard let db = appState.database else { return [] }
        do {
            return try db.dbWriter.read { dbConn in
                try Meeting
                    .order(Column("created_at").desc)
                    .limit(3)
                    .fetchAll(dbConn)
            }
        } catch {
            menuBarLogger.warning("Failed to fetch recent meetings: \(error.localizedDescription)")
            return []
        }
    }

    private func menuLabel(for meeting: Meeting) -> String {
        if let duration = meeting.durationSeconds {
            return "\(meeting.title)  \(Formatters.duration(seconds: duration))"
        } else {
            return "\(meeting.title)  \(meeting.status.rawValue.capitalized)"
        }
    }
}

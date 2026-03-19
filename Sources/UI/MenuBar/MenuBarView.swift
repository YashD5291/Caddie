import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusSection
            Divider()
            actionsSection
        }
        .frame(width: 240)
    }

    // MARK: - Status Section

    @ViewBuilder
    private var statusSection: some View {
        switch appState.status {
        case .idle:
            Label("No active meeting", systemImage: "mic.slash")
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

        case .recording:
            HStack(spacing: 8) {
                RecordingIndicator()
                VStack(alignment: .leading, spacing: 2) {
                    Text(appState.currentMeetingTitle ?? "Recording...")
                        .font(.caption.bold())
                        .lineLimit(1)
                    Text(Formatters.duration(seconds: Int(appState.recordingDuration)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Button(role: .destructive) {
                // Stop action wired in Task 11
            } label: {
                Label("Stop Recording", systemImage: "stop.circle.fill")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 4)

        case .transcribing:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Transcribing...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Actions Section

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Open Caddie", systemImage: "macwindow")
            }

            Divider()

            Button {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } label: {
                Label("Preferences...", systemImage: "gear")
            }

            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit Caddie", systemImage: "power")
            }
        }
    }
}

#Preview {
    MenuBarView()
        .environment(AppState())
}

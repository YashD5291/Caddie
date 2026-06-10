import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        statusSection
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
            if let recordingError = appState.lastRecordingError {
                Text("\u{26A0}\u{FE0F} Last recording failed: \(recordingError)")
                    .foregroundStyle(.red)
                Button("Dismiss Error") {
                    appState.lastRecordingError = nil
                }
            }
            if appState.coordinator == nil {
                Text("Loading models...")
                    .foregroundStyle(.secondary)
            } else {
                Text("No Active Meeting")
            }
            Button {
                appState.startManualRecording()
            } label: {
                Label("Start Recording", systemImage: "record.circle")
            }
            .disabled(appState.coordinator == nil)

        case .recording:
            Text("\u{1F534} \(appState.currentMeetingTitle ?? "Recording...")")
            Text("Recording \u{00B7} \(Formatters.duration(seconds: Int(appState.recordingDuration)))")
            Button {
                confirmStopRecording()
            } label: {
                Label("Stop Recording", systemImage: "stop.circle.fill")
            }

        case .transcribing:
            Text("Processing...")
            Text(pipelineStepLabel(appState.pipelineStep))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private var actionsSection: some View {
        Button {
            NSApp.setActivationPolicy(.regular)
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

    private func pipelineStepLabel(_ step: PipelineStep) -> String {
        switch step {
        case .idle: return "Queued"
        case .mixdown: return "Mixing down audio..."
        case .transcribing: return "Transcribing speech..."
        case .diarizing: return "Identifying speakers..."
        case .compressing: return "Compressing audio..."
        }
    }
}

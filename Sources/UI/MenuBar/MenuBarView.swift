import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.sparkleUpdaterController) private var updaterController

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
            videoErrorRow
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
            videoErrorRow
            Text("\u{1F534} \(appState.currentMeetingTitle ?? "Recording...")")
            Text("Recording \u{00B7} \(Formatters.duration(seconds: Int(appState.recordingDuration)))")
            // Deliberately no confirmation dialog: a modal here blocks the main thread,
            // starving the main-queue audio drain timer so ring-buffer samples are silently
            // dropped (Finding F1, 19-VALIDATION.md). Stopping is non-destructive — the
            // meeting is saved and transcribed — so the guard is not worth the data loss.
            Button {
                appState.stopRecording()
            } label: {
                Label("Stop Recording", systemImage: "stop.circle.fill")
            }

        case .transcribing:
            Text("Processing...")
            Text(pipelineStepLabel(appState.pipelineStep))
                .foregroundStyle(.secondary)
        }
    }

    /// The non-fatal video surface (VID-04). Rendered in BOTH the idle and recording
    /// branches: a degraded capture matters most while the meeting is still running,
    /// which is exactly when the idle-only error row is invisible. Orange, not red, and
    /// explicit that the audio survived — this is a degradation, not a failed recording.
    @ViewBuilder
    private var videoErrorRow: some View {
        if let videoError = appState.lastVideoError {
            Text("\u{26A0}\u{FE0F} Screen recording stopped \u{2014} audio was saved: \(videoError)")
                .foregroundStyle(.orange)
            Button("Dismiss Video Warning") {
                appState.clearVideoError()
            }
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

        if let updaterController {
            Button {
                updaterController.checkForUpdates(nil)
            } label: {
                Label("Check for Updates...", systemImage: "arrow.down.circle")
            }
        }
    }

    // MARK: - Helpers

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

import SwiftUI

struct OnboardingView: View {
    @Binding var isComplete: Bool
    @Environment(AppState.self) private var appState
    @State private var micStatus: PermissionStatus = Permissions.microphone
    @State private var screenStatus: PermissionStatus = Permissions.screenRecording
    @State private var accessibilityStatus: PermissionStatus = Permissions.accessibility
    @State private var isRequesting = false
    @State private var showModelDownload = false

    private var permissionsGranted: Bool {
        micStatus == .granted && accessibilityStatus == .granted
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: "mic.badge.plus")
                .font(.system(size: 56, weight: .thin))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.orange)
                .padding(.bottom, 20)

            Text("Welcome to Caddie")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .padding(.bottom, 8)

            Text("Everything stays on your Mac.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 32)

            if showModelDownload {
                modelDownloadSection
            } else {
                permissionsSection
            }

            Spacer()
        }
        .padding(40)
        .frame(minWidth: 520, minHeight: 520)
        .onAppear { refreshStatuses() }
    }

    // MARK: - Permissions Section

    private var permissionsSection: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                permissionRow(title: "Microphone", description: "Record meeting audio", icon: "mic.fill", status: micStatus)
                Divider().padding(.leading, 44)
                permissionRow(title: "Accessibility", description: "Detect active meeting windows", icon: "hand.raised.fill", status: accessibilityStatus)
                Divider().padding(.leading, 44)
                permissionRow(title: "Screen Recording", description: "Capture system audio from meeting apps", icon: "rectangle.inset.filled.and.person.filled", status: screenStatus, isOptional: true)
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
            .frame(maxWidth: 400)
            .padding(.bottom, 24)

            if screenStatus != .granted {
                Text("Screen Recording is needed for system audio capture.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.bottom, 8)

                Button("Open System Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
                .font(.caption)
                .padding(.bottom, 16)
            }

            Button {
                if permissionsGranted {
                    showModelDownload = true
                    Task { await appState.modelManager.loadModelsFromBundle() }
                } else {
                    requestPermissions()
                }
            } label: {
                if isRequesting {
                    ProgressView().controlSize(.small)
                } else {
                    Text(permissionsGranted ? "Continue" : "Grant Permissions")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .controlSize(.large)
            .disabled(isRequesting)

            Button("Refresh") { refreshStatuses() }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
        }
    }

    // MARK: - Model Download Section

    @ViewBuilder
    private var modelDownloadSection: some View {
        VStack(spacing: 16) {
            if let error = appState.modelManager.loadError {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 32))
                    .foregroundStyle(.red)

                Text("Model Loading Failed")
                    .font(.headline)

                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 350)

                Button("Retry Loading") {
                    Task { await appState.modelManager.loadModelsFromBundle() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.large)
            } else if appState.modelManager.modelsReady {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.green)

                Text("Models Ready")
                    .font(.headline)

                Button("Get Started") {
                    isComplete = true
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.large)
            } else {
                Text("Loading AI Models")
                    .font(.headline)

                Text("Preparing speech recognition...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                ProgressView(value: appState.modelManager.loadProgress)
                    .frame(maxWidth: 300)
                    .padding(.vertical, 8)

                Text("\(Int(appState.modelManager.loadProgress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: 400)
    }

    // MARK: - Helpers

    private func permissionRow(title: String, description: String, icon: String, status: PermissionStatus, isOptional: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(title).font(.body.bold())
                    if isOptional {
                        Text("(recommended)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
            statusLabel(for: status)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func statusLabel(for status: PermissionStatus) -> some View {
        switch status {
        case .granted:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .denied:
            HStack(spacing: 4) {
                Image(systemName: "xmark.circle.fill")
                Text("Denied")
            }
            .font(.caption)
            .foregroundStyle(.red)
        case .undetermined:
            Text("Not set")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func requestPermissions() {
        isRequesting = true
        Permissions.requestAccessibility()
        Task {
            _ = await Permissions.requestMicrophone()
            refreshStatuses()
            isRequesting = false
        }
    }

    private func refreshStatuses() {
        micStatus = Permissions.microphone
        screenStatus = Permissions.screenRecording
        accessibilityStatus = Permissions.accessibility
    }
}

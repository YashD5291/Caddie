import SwiftUI

struct OnboardingView: View {
    @Binding var isComplete: Bool
    @State private var micStatus: PermissionStatus = Permissions.microphone
    @State private var screenStatus: PermissionStatus = Permissions.screenRecording
    @State private var accessibilityStatus: PermissionStatus = Permissions.accessibility

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "mic.badge.plus")
                .font(.system(size: 64))
                .foregroundStyle(.tint)

            Text("Welcome to Caddie")
                .font(.largeTitle.bold())

            Text("Caddie automatically detects your meetings, records audio, and generates speaker-labeled transcripts — all on-device.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 400)

            VStack(alignment: .leading, spacing: 12) {
                permissionRow(
                    title: "Microphone",
                    description: "Record meeting audio",
                    icon: "mic.fill",
                    status: micStatus
                )
                permissionRow(
                    title: "Screen Recording",
                    description: "Detect meeting windows",
                    icon: "rectangle.inset.filled.and.person.filled",
                    status: screenStatus
                )
                permissionRow(
                    title: "Accessibility",
                    description: "Read window titles",
                    icon: "hand.raised.fill",
                    status: accessibilityStatus
                )
            }
            .padding()
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))

            Button("Get Started") {
                Task {
                    Permissions.requestAccessibility()
                    _ = await Permissions.requestMicrophone()
                    refreshStatuses()
                    isComplete = true
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Spacer()
        }
        .padding(40)
        .frame(minWidth: 500, minHeight: 500)
        .onAppear { refreshStatuses() }
    }

    private func permissionRow(title: String, description: String, icon: String, status: PermissionStatus) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.bold())
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            statusIcon(for: status)
        }
    }

    @ViewBuilder
    private func statusIcon(for status: PermissionStatus) -> some View {
        switch status {
        case .granted:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .denied:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        case .undetermined:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
        }
    }

    private func refreshStatuses() {
        micStatus = Permissions.microphone
        screenStatus = Permissions.screenRecording
        accessibilityStatus = Permissions.accessibility
    }
}

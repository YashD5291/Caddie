import SwiftUI
import ServiceManagement

private let settingsLogger = CaddieLogger.app

struct SettingsView: View {
    @State private var launchAtLogin = false
    @State private var gracePeriod: Double = 10
    @State private var micStatus: PermissionStatus = .undetermined
    @State private var screenStatus: PermissionStatus = .undetermined
    @State private var accessibilityStatus: PermissionStatus = .undetermined
    @State private var storageUsed: String = "Calculating..."

    var body: some View {
        Form {
            generalSection
            permissionsSection
            storageSection
            aboutSection
        }
        .formStyle(.grouped)
        .frame(width: 450)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            refreshPermissions()
            refreshStorage()
        }
    }

    // MARK: - General

    private var generalSection: some View {
        Section("General") {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, newValue in
                    do {
                        if newValue { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                    } catch {
                        CaddieLogger.app.error("Failed to update launch at login: \(error.localizedDescription)")
                        launchAtLogin = !newValue
                    }
                }

            VStack(alignment: .leading) {
                HStack {
                    Text("Grace period")
                    Spacer()
                    Text("\(Int(gracePeriod))s")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $gracePeriod, in: 5...30, step: 5)
                Text("Seconds to wait after meeting signals stop before ending recording.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        Section("Permissions") {
            permissionRow("Microphone", status: micStatus)
            permissionRow("Screen Recording", status: screenStatus)
            permissionRow("Accessibility", status: accessibilityStatus)

            Button("Open System Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!)
            }
        }
    }

    private func permissionRow(_ name: String, status: PermissionStatus) -> some View {
        HStack {
            Text(name)
            Spacer()
            switch status {
            case .granted:
                Text("Granted").foregroundStyle(.green).font(.caption)
            case .denied:
                Text("Denied").foregroundStyle(.red).font(.caption)
            case .undetermined:
                Text("Not Set").foregroundStyle(.secondary).font(.caption)
            }
        }
    }

    // MARK: - Storage

    private var storageSection: some View {
        Section("Storage") {
            HStack {
                Text("Audio storage used")
                Spacer()
                Text(storageUsed).foregroundStyle(.secondary)
            }

            Button("Show in Finder") {
                guard let appSupport = FileManager.default.urls(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask
                ).first else {
                    settingsLogger.error("Application Support directory not found")
                    return
                }
                let caddieDir = appSupport.appendingPathComponent("Caddie", isDirectory: true)
                NSWorkspace.shared.open(caddieDir)
            }

            Button("Clean Up Orphaned Files") {
                let orphans = AudioFileManager.findOrphanedWAVs()
                for url in orphans {
                    do {
                        try FileManager.default.removeItem(at: url)
                    } catch {
                        settingsLogger.warning("Failed to remove orphaned file \(url.lastPathComponent): \(error.localizedDescription)")
                    }
                }
                refreshStorage()
            }
            .disabled(AudioFileManager.findOrphanedWAVs().isEmpty)
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section("About") {
            HStack {
                Text("Version")
                Spacer()
                let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
                let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
                Text("\(version) (\(build))")
                    .foregroundStyle(.secondary)
            }

            Button("View Logs") {
                CaddieLogger.showLogs()
            }
        }
    }

    // MARK: - Helpers

    private func refreshPermissions() {
        micStatus = Permissions.microphone
        screenStatus = Permissions.screenRecording
        accessibilityStatus = Permissions.accessibility
    }

    private func refreshStorage() {
        let bytes = AudioFileManager.totalStorageUsed()
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        storageUsed = formatter.string(fromByteCount: Int64(bytes))
    }
}

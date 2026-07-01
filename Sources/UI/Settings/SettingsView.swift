import SwiftUI
import ServiceManagement

private let settingsLogger = CaddieLogger.app

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.sparkleUpdaterController) private var updaterController
    @State private var launchAtLogin = false
    @State private var gracePeriod: Double = 10
    @State private var promptLeadTime: Double = 120
    @State private var micStatus: PermissionStatus = .undetermined
    @State private var screenStatus: PermissionStatus = .undetermined
    @State private var accessibilityStatus: PermissionStatus = .undetermined
    @State private var notificationAuth: NotificationManager.AuthState = .undetermined
    @State private var storageUsed: String = "Calculating..."

    var body: some View {
        Form {
            generalSection
            audioInputSection
            GoogleAccountSection()
            updatesSection
            permissionsSection
            storageSection
            aboutSection
        }
        .formStyle(.grouped)
        .frame(width: 450)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            promptLeadTime = UserDefaults.standard.object(forKey: "meetingPromptLeadTimeSeconds") as? Double ?? 120
            refreshPermissions()
            refreshStorage()
        }
        .onChange(of: promptLeadTime) { _, newValue in
            UserDefaults.standard.set(newValue, forKey: "meetingPromptLeadTimeSeconds")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
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

            VStack(alignment: .leading) {
                Picker("Prompt lead time", selection: $promptLeadTime) {
                    Text("1 minute").tag(60.0)
                    Text("2 minutes").tag(120.0)
                    Text("5 minutes").tag(300.0)
                }
                Text("How early before a meeting starts Caddie asks if you want to record.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Audio Input

    private var audioInputSection: some View {
        @Bindable var audioDeviceManager = appState.audioDeviceManager
        return Section("Audio Input") {
            Picker("Input Device", selection: $audioDeviceManager.selectedDeviceUID) {
                Text("System Default").tag(String?.none)
                ForEach(audioDeviceManager.availableInputDevices) { device in
                    HStack {
                        Text(device.name)
                        if !device.manufacturer.isEmpty && device.manufacturer != "Unknown" {
                            Text("(\(device.manufacturer))")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(Optional(device.id))
                }
            }

            if audioDeviceManager.isUsingFallback {
                Label("Previously selected device not found. Using system default.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Text("Choose which microphone Caddie records from.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Updates

    @ViewBuilder
    private var updatesSection: some View {
        if let updaterController {
            Section("Updates") {
                Toggle("Automatically check for updates", isOn: Binding(
                    get: { updaterController.updater.automaticallyChecksForUpdates },
                    set: { updaterController.updater.automaticallyChecksForUpdates = $0 }
                ))

                Button("Check Now") {
                    updaterController.checkForUpdates(nil)
                }

                Text("Updates are delivered securely from GitHub Releases.")
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
            notificationRow

            Button("Open Privacy Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!)
            }

            if notificationAuth != .authorized {
                Button("Open Notification Settings") {
                    NSWorkspace.shared.open(NotificationManager.notificationSettingsURL)
                }
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

    private var notificationRow: some View {
        HStack {
            Text("Notifications")
            Spacer()
            switch notificationAuth {
            case .authorized:
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
        Task { @MainActor in
            notificationAuth = await NotificationManager.currentAuthState()
        }
    }

    private func refreshStorage() {
        let bytes = AudioFileManager.totalStorageUsed()
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        storageUsed = formatter.string(fromByteCount: Int64(bytes))
    }
}

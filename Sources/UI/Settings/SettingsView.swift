import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @State private var launchAtLogin = false
    @State private var gracePeriod: Double = 10

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            CaddieLogger.app.error("Failed to update launch at login: \(error.localizedDescription)")
                            launchAtLogin = !newValue
                        }
                    }

                VStack(alignment: .leading) {
                    Text("Grace period: \(Int(gracePeriod)) seconds")
                    Slider(value: $gracePeriod, in: 5...30, step: 5)
                }
            }

            Section("Storage") {
                HStack {
                    Text("Audio storage used")
                    Spacer()
                    Text(formattedStorageUsed)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private var formattedStorageUsed: String {
        let bytes = AudioFileManager.totalStorageUsed()
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

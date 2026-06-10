import SwiftUI
import GRDB

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedMeetingId: Int64?
    @State private var searchText = ""
    @State private var meetings: [Meeting] = []
    @State private var observationCancellable: AnyDatabaseCancellable?

    var body: some View {
        Group {
            if !appState.hasCompletedOnboarding {
                OnboardingView(isComplete: Binding(
                    get: { appState.hasCompletedOnboarding },
                    set: { appState.hasCompletedOnboarding = $0 }
                ))
            } else if let error = appState.initError {
                initErrorView(error)
            } else if !isSignedInToGoogle {
                googleSignInGate
            } else {
                mainContent
            }
        }
        .task {
            await appState.ensureInitialized()
        }
    }

    private var isSignedInToGoogle: Bool {
        if case .signedIn = appState.googleAuthState { return true }
        return false
    }

    // MARK: - Google Sign-In Gate

    @ViewBuilder
    private var googleSignInGate: some View {
        VStack(spacing: 20) {
            Image(systemName: "calendar.badge.plus")
                .font(.system(size: 56, weight: .thin))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.orange)

            Text("Connect Google Calendar")
                .font(.system(size: 24, weight: .bold, design: .rounded))

            Text("Caddie uses Google Calendar to detect meetings and show your schedule. Sign in to continue.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            switch appState.googleAuthState {
            case .signingIn:
                ProgressView()
                    .controlSize(.regular)
                Text("Complete sign-in in your browser.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Cancel") {
                    appState.cancelGoogleSignIn()
                }
                .font(.caption)
                .foregroundStyle(.secondary)

            case .error(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)

                Button("Try Again") {
                    appState.signInToGoogle()
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.large)

            default:
                Button("Sign in with Google") {
                    appState.signInToGoogle()
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.large)
                .padding(.top, 12)
            }
        }
        .padding(40)
        .frame(minWidth: 520, minHeight: 520)
    }

    // MARK: - Error State

    private func initErrorView(_ error: String) -> some View {
        ContentUnavailableView {
            Label("Failed to Start", systemImage: "exclamationmark.triangle")
        } description: {
            Text(error)
        } actions: {
            Button("Retry") {
                appState.initError = nil
                appState.retryInitialization()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(minWidth: 700, minHeight: 500)
    }

    // MARK: - Main Content

    /// True while the RecordingCoordinator is still being constructed (ML models
    /// loading) and no init error has surfaced — drives the loading overlay.
    private var isLoadingPipeline: Bool {
        appState.coordinator == nil && appState.initError == nil
    }

    @ViewBuilder
    private var mainContent: some View {
        NavigationSplitView {
            MeetingListView(
                meetings: meetings,
                selectedMeetingId: $selectedMeetingId,
                searchText: $searchText
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 350)
        } detail: {
            if let id = selectedMeetingId,
               let meeting = meetings.first(where: { $0.id == id }) {
                MeetingDetailView(meeting: meeting)
            } else {
                ContentUnavailableView(
                    "No Meeting Selected",
                    systemImage: "waveform",
                    description: Text("Select a meeting from the sidebar to view its transcript.")
                )
            }
        }
        .frame(minWidth: 700, minHeight: 500)
        .overlay {
            // Shown until the RecordingCoordinator is constructed. ML model loading
            // can take 30+ seconds on first launch (Parakeet encoder + Sortformer),
            // and we don't want the user staring at a faded New Recording button
            // wondering whether the app is broken.
            if isLoadingPipeline {
                LoadingOverlay()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: isLoadingPipeline)
        .onAppear { startObserving() }
        .onDisappear { observationCancellable?.cancel() }
        .task(id: searchText) {
            // Debounce keystrokes so we don't tear down and rebuild the GRDB
            // ValueObservation on every character. The initial observation is set up
            // by onAppear / the isInitialized handler; this only handles edits.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            startObserving()
        }
        .onChange(of: appState.isInitialized) { _, ready in
            // Database becomes available only after initialize() completes.
            // First onAppear may fire while database is still nil — retry once ready.
            if ready { startObserving() }
        }
        .toolbar { inputDeviceToolbarItem }
    }

    // MARK: - Input Device Toolbar

    @ToolbarContentBuilder
    private var inputDeviceToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            @Bindable var deviceManager = appState.audioDeviceManager
            Menu {
                Picker("Input Device", selection: $deviceManager.selectedDeviceUID) {
                    Text("System Default").tag(String?.none)
                    Divider()
                    ForEach(deviceManager.availableInputDevices) { device in
                        Text(device.name).tag(Optional(device.id))
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label(currentDeviceLabel, systemImage: appState.status == .recording ? "mic.fill" : "mic")
                    .labelStyle(.titleAndIcon)
            }
            .help(devicePickerHelp)
            // Disabled only during transcribing (when changing source would do
            // nothing useful). Idle = choose source for next recording.
            // Recording = hot-swap the live source.
            .disabled(appState.status == .transcribing)
            .onChange(of: deviceManager.selectedDeviceUID) { _, newValue in
                appState.switchInputDevice(deviceUID: newValue)
            }
        }
    }

    private var devicePickerHelp: String {
        switch appState.status {
        case .idle: return "Select the microphone Caddie will record from"
        case .recording: return "Switch the live recording to a different input device"
        case .transcribing: return "Processing — device cannot be changed"
        }
    }

    private var currentDeviceLabel: String {
        let manager = appState.audioDeviceManager
        if let uid = manager.selectedDeviceUID,
           let device = manager.availableInputDevices.first(where: { $0.id == uid }) {
            return device.name
        }
        // No explicit selection — recording goes to the macOS system default.
        // Resolve it so the toolbar shows what's actually being captured rather
        // than a generic "Default Mic".
        if let resolved = manager.systemDefaultInputName {
            return "Default · \(resolved)"
        }
        return "Default Mic"
    }

    // MARK: - Database Observation

    private func startObserving() {
        guard let dbWriter = appState.database?.dbWriter else { return }
        observationCancellable?.cancel()

        let currentSearch = searchText
        let observation = ValueObservation.tracking { db -> [Meeting] in
            if currentSearch.isEmpty {
                return try Meeting
                    .order(Column("created_at").desc)
                    .fetchAll(db)
            } else {
                let escaped = currentSearch.replacingOccurrences(of: "\"", with: "\"\"")
                let ftsQuery = "\"\(escaped)\"*"
                return try Meeting
                    .filter(
                        sql: "id IN (SELECT rowid FROM meetings_fts WHERE meetings_fts MATCH ?)",
                        arguments: [ftsQuery]
                    )
                    .order(Column("created_at").desc)
                    .fetchAll(db)
            }
        }

        observationCancellable = observation.start(
            in: dbWriter,
            onError: { error in
                CaddieLogger.app.error("Database observation error: \(error.localizedDescription)")
            },
            onChange: { newMeetings in
                meetings = newMeetings
            }
        )
    }
}

import SwiftUI
import AppKit
import Observation
import os

enum AppStatus: String {
    case idle
    case recording
    case transcribing
}

enum PipelineStep: String, Sendable {
    case idle
    case mixdown
    case transcribing
    case diarizing
    case compressing
}

@MainActor
@Observable
final class AppState {
    var status: AppStatus = .idle
    var pipelineStep: PipelineStep = .idle
    var currentMeetingTitle: String?
    var recordingStartTime: Date?
    var transcriptionProgress: Double = 0
    var hasOpenedMainWindow = false
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    var recordingDuration: TimeInterval {
        guard let start = recordingStartTime else { return 0 }
        return Date().timeIntervalSince(start)
    }

    // MARK: - Dependencies

    private(set) var database: AppDatabase?
    private(set) var modelManager = ModelManager()
    private(set) var audioDeviceManager = AudioDeviceManager()
    private(set) var authManager = GoogleAuthManager()
    private(set) var coordinator: RecordingCoordinator?
    var googleAuthState: GoogleAuthManager.AuthState = .signedOut
    var todayEvents: [GoogleCalendarEvent] = []
    private(set) var calendarService: GoogleCalendarService?

    private let logger = Logger(subsystem: "com.caddie.app", category: "AppState")

    var isInitialized = false
    var initError: String?

    /// Internal task that survives view lifecycle cancellation.
    private var initTask: Task<Void, Never>?

    // MARK: - Lifecycle

    /// Called from ContentView.task — delegates to a long-lived Task
    /// so initialization can't be cancelled by SwiftUI view lifecycle.
    func ensureInitialized() async {
        if initTask == nil {
            initTask = Task { await initialize() }
        }
        await initTask?.value
    }

    func retryInitialization() {
        initTask = Task { await initialize() }
    }

    private func initialize() async {
        guard !isInitialized else { return }
        do {
            // Restore Google auth session from Keychain (AUTH-01)
            await authManager.restoreSession()
            googleAuthState = await authManager.state

            // Start calendar service if signed in
            if case .signedIn = googleAuthState {
                let service = GoogleCalendarService(authManager: authManager)
                await service.setCallbacks(
                    onEventsUpdated: { [weak self] events in
                        Task { @MainActor in self?.todayEvents = events }
                    },
                    onSignal: nil // Wired after coordinator is created
                )
                await service.start()
                calendarService = service
            }

            database = try AppDatabase()
            try AudioFileManager.ensureDirectoryExists()
            AudioFileManager.cleanupOrphanedTempFiles() // DATA-05
            SystemAudioCapture.cleanupStaleAggregateDevices() // REC-06
            audioDeviceManager.initialize() // AUD-01/AUD-02: enumerate devices and load persisted selection

            // 1. Load models from app bundle (D-04: bundle-based, no network)
            await modelManager.loadModelsFromBundle()

            if let loadError = modelManager.loadError {
                initError = "Model loading failed: \(loadError)"
                logger.error("Model loading failed: \(loadError)")
                return
            }

            // 2. Initialize ASR engine
            let asrEngine = ASREngine()
            if let asrModels = modelManager.asrModels {
                try await asrEngine.initialize(models: asrModels)
            }

            // 3. Initialize diarization engine
            let diarizationEngine = DiarizationEngine()
            if let diarizer = modelManager.diarizer {
                nonisolated(unsafe) let d = diarizer
                try await diarizationEngine.initialize(diarizer: d)
            }

            // 4. Create pipeline with injected engines
            let pipeline = TranscriptionPipeline(asr: asrEngine, diarization: diarizationEngine)

            // 5. Create coordinator with all dependencies -- eliminates init race (REC-04)
            // All deps are non-optional: coordinator cannot exist without a working pipeline
            guard let db = database else {
                initError = "Database failed to initialize"
                return
            }
            let deviceManager = audioDeviceManager
            let newCoordinator = RecordingCoordinator(
                database: db,
                recorder: AudioRecorder(),
                pipeline: pipeline,
                detector: MeetingDetector(),
                audioDeviceManager: deviceManager
            )

            // 6. Wire coordinator state changes to observable properties
            await newCoordinator.setOnStateChange { [weak self] newState in
                Task { @MainActor in
                    guard let self else {
                        CaddieLogger.app.warning("AppState deallocated -- state change to \(String(describing: newState)) dropped")
                        return
                    }
                    switch newState {
                    case .idle:
                        self.status = .idle
                        self.currentMeetingTitle = nil
                        self.recordingStartTime = nil
                        self.pipelineStep = .idle
                    case .recording:
                        self.status = .recording
                        self.recordingStartTime = Date()
                    case .transcribing:
                        self.status = .transcribing
                    case .error:
                        self.status = .idle
                    }
                }
            }

            // Wire pipeline step changes to observable property
            await newCoordinator.setOnPipelineStepChange { [weak self] step in
                Task { @MainActor in
                    guard let self else { return }
                    self.pipelineStep = step
                }
            }

            // 7. Wire calendar-based meeting prompt to notification
            await newCoordinator.setOnMeetingPrompt { title, eventID in
                // eventID is always present for calendar-sourced prompts; fall back to the
                // title only if a future non-calendar source ever drives this path.
                NotificationManager.promptToRecord(eventTitle: title, eventID: eventID ?? title)
            }

            // 8. Start detection AFTER pipeline exists -- fixes init race (REC-04)
            await newCoordinator.start()
            coordinator = newCoordinator

            // 9. Wire calendar service signal to detector via coordinator
            if let service = calendarService {
                let coord = newCoordinator
                await service.setOnSignal { signal in
                    Task { await coord.forwardSignal(signal) }
                }
            }

            isInitialized = true
            logger.info("AppState initialized with RecordingCoordinator")
        } catch {
            initError = error.localizedDescription
            logger.error("Failed to initialize: \(error.localizedDescription)")
        }
    }

    // MARK: - UI Actions (delegate to coordinator)

    func startManualRecording(title: String = "Manual Recording") {
        let selectedDevice = audioDeviceManager.selectedDeviceUID ?? "system default"
        CaddieLogger.app.info("User requested manual recording: title='\(title)' device=\(selectedDevice)")

        // Block if initialization isn't complete yet (models still loading)
        guard coordinator != nil else {
            CaddieLogger.app.warning("Manual recording blocked: coordinator nil (models still loading)")
            showPermissionAlert(
                title: "Caddie is still loading",
                message: "AI models are still being prepared. This can take a few minutes on first launch. Please try again shortly."
            )
            return
        }

        // Check microphone permission before attempting to record
        switch Permissions.microphone {
        case .granted:
            CaddieLogger.app.info("Mic permission granted; dispatching to coordinator")
            currentMeetingTitle = title
            Task { await coordinator?.startManualRecording(title: title) }
        case .undetermined:
            CaddieLogger.app.info("Mic permission undetermined; requesting from OS")
            Task {
                let granted = await Permissions.requestMicrophone()
                CaddieLogger.app.info("Mic permission OS response: granted=\(granted)")
                await MainActor.run {
                    if granted {
                        self.currentMeetingTitle = title
                        Task { await self.coordinator?.startManualRecording(title: title) }
                    } else {
                        self.showPermissionAlert(
                            title: "Microphone Access Required",
                            message: "Caddie needs microphone access to record meetings. Enable it in System Settings."
                        )
                    }
                }
            }
        case .denied:
            CaddieLogger.app.warning("Manual recording blocked: mic permission denied")
            showPermissionAlert(
                title: "Microphone Access Required",
                message: "Caddie needs microphone access to record meetings. Enable it in System Settings → Privacy & Security → Microphone."
            )
        }
    }

    private func showPermissionAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        }
    }

    func stopManualRecording() {
        Task { await coordinator?.stopManualRecording() }
    }

    func stopRecording() {
        Task { await coordinator?.stopRecording() }
    }

    func retryTranscription(meetingId: String) {
        Task { await coordinator?.retryTranscription(meetingId: meetingId) }
    }

    /// User changed the input device picker. If a recording is active, switch
    /// the live capture source; otherwise the change just persists for the
    /// next recording (handled by AudioDeviceManager.selectedDeviceUID).
    func switchInputDevice(deviceUID: String?) {
        CaddieLogger.app.info("User changed input device to \(deviceUID ?? "system-default") (status=\(String(describing: self.status)))")
        guard status == .recording else { return }
        Task { await coordinator?.switchInputDevice(deviceUID: deviceUID) }
    }

    func signInToGoogle() {
        googleAuthState = .signingIn
        Task {
            do {
                try await authManager.signIn()
                googleAuthState = await authManager.state
                if case .signedIn = googleAuthState, calendarService == nil {
                    let service = GoogleCalendarService(authManager: authManager)
                    await service.setCallbacks(
                        onEventsUpdated: { [weak self] events in
                            Task { @MainActor in self?.todayEvents = events }
                        },
                        onSignal: nil
                    )
                    await service.start()
                    calendarService = service

                    // Wire calendar signal to detector if coordinator exists
                    if let coord = coordinator {
                        await service.setOnSignal { signal in
                            Task { await coord.forwardSignal(signal) }
                        }
                    }
                }
            } catch {
                CaddieLogger.auth.error("Google sign-in failed: \(error.localizedDescription)")
                googleAuthState = await authManager.state
            }
        }
    }

    func cancelGoogleSignIn() {
        Task {
            await authManager.cancelSignIn()
            googleAuthState = await authManager.state
        }
    }

    func signOutFromGoogle() {
        Task {
            await calendarService?.stop()
            calendarService = nil
            todayEvents = []
            await authManager.signOut()
            googleAuthState = await authManager.state
        }
    }

    func shutdown() {
        Task { await coordinator?.stop() }
        logger.info("AppState shut down")
    }
}

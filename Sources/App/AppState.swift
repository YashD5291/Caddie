import SwiftUI
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
    var recordingMode: RecordingMode = .systemAndMic
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
            // nonisolated(unsafe) suppresses Swift 6 sending checks for FluidAudio
            // types that aren't Sendable but are moved (not shared) to the engines.
            let asrEngine = ASREngine()
            if let asrModels = modelManager.asrModels {
                nonisolated(unsafe) let models = asrModels
                try await asrEngine.initialize(models: models)
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
                        self.recordingMode = .systemAndMic
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

            // Wire recording mode changes to observable property
            await newCoordinator.setOnRecordingModeChange { [weak self] mode in
                Task { @MainActor in
                    guard let self else { return }
                    self.recordingMode = mode
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
            await newCoordinator.setOnMeetingPrompt { title in
                NotificationManager.promptToRecord(eventTitle: title)
            }

            // 8. Start detection AFTER pipeline exists -- fixes init race (REC-04)
            await newCoordinator.start()
            coordinator = newCoordinator

            // 9. Wire calendar service signal to detector via coordinator
            if let service = calendarService {
                nonisolated(unsafe) let coord = newCoordinator
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

    func startManualRecording() {
        currentMeetingTitle = "Manual Recording"
        Task { await coordinator?.startManualRecording() }
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
                        nonisolated(unsafe) let c = coord
                        await service.setOnSignal { signal in
                            Task { await c.forwardSignal(signal) }
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

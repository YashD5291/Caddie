# Codebase Structure

**Analysis Date:** 2026-03-22

## Directory Layout

```
/Users/yashdesai/Codebase/Fun/Caddie/
├── Sources/                     # All application source code
│   ├── App/                     # Application lifecycle and state
│   ├── Detection/               # Meeting detection monitors
│   ├── Models/                  # ML model management
│   ├── Recording/               # Audio capture orchestration
│   ├── Storage/                 # Database and file management
│   ├── Transcription/           # ML pipeline (ASR, diarization)
│   ├── UI/                      # SwiftUI views organized by feature
│   │   ├── MainWindow/          # Primary app window views
│   │   ├── MenuBar/             # Menu bar extra controls
│   │   ├── Onboarding/          # First-run setup
│   │   ├── Settings/            # User preferences
│   │   └── Shared/              # Reusable UI components
│   └── Utilities/               # Cross-cutting concerns
├── Tests/                       # Unit and integration tests
├── Resources/                   # Assets and configuration
│   ├── Assets.xcassets/         # App icons and images
│   ├── Info.plist               # App metadata
│   └── Caddie.entitlements      # System permissions
├── Caddie.xcodeproj/            # Xcode project configuration
├── project.yml                  # XcodeGen project spec
├── README.md                    # Project overview
└── docs/                        # Additional documentation
```

## Directory Purposes

**Sources/App:**
- Purpose: Application entry point, state management, and lifecycle orchestration
- Contains: CaddieApp (SwiftUI @main), AppState (@Observable), AppDelegate (NSApplicationDelegate)
- Key files: `CaddieApp.swift`, `AppState.swift`
- Manages: Global AppState, MenuBarExtra + Window + Settings scenes, app delegate events

**Sources/Detection:**
- Purpose: Monitor system for meeting indicators using multiple independent signals
- Contains: MeetingDetector, 4 protocol-implementing monitors, DecisionEngine, MeetingPatterns
- Key files: `MeetingDetector.swift`, `AudioProcessMonitor.swift`, `MicStateMonitor.swift`, `WindowTitleMonitor.swift`, `CalendarMonitor.swift`, `MeetingPatterns.swift`
- Monitors: Audio process list (3s poll), microphone state (AVAudioEngine), accessibility window titles (AXSwift), calendar events (EventKit)

**Sources/Models:**
- Purpose: Download and cache ML models required for transcription pipeline
- Contains: ModelManager (ObservableObject) that delegates to FluidAudio SDK
- Key files: `ModelManager.swift`
- Manages: ASR model download, diarization model initialization, progress tracking

**Sources/Recording:**
- Purpose: Capture system audio and microphone into stereo WAV files with buffering
- Contains: AudioRecorder, SystemAudioCapture, MicrophoneCapture
- Key files: `AudioRecorder.swift`, `SystemAudioCapture.swift`, `MicrophoneCapture.swift`
- Format: Stereo WAV, 16kHz, 16-bit PCM (left=system audio, right=microphone)

**Sources/Storage:**
- Purpose: Persist meetings to SQLite database and manage audio file lifecycle
- Contains: AppDatabase (GRDB DatabasePool), Meeting model, AudioFileManager utility, Migrations
- Key files: `Database.swift`, `Meeting.swift`, `AudioFileManager.swift`, `Migrations.swift`
- Database: `/Users/[user]/Library/Application Support/Caddie/caddie.db` (WAL mode)
- Audio storage: `/Users/[user]/Library/Application Support/Caddie/audio/` (WAV during transcription, ALAC after)

**Sources/Transcription:**
- Purpose: Execute multi-stage ML pipeline: mono mixdown → ASR → diarization → merge → DB write → compress
- Contains: TranscriptionPipeline (actor), ASREngine, DiarizationEngine, TranscriptMerger, type definitions
- Key files: `TranscriptionPipeline.swift`, `ASREngine.swift`, `DiarizationEngine.swift`, `TranscriptMerger.swift`
- Stages: Mono mixdown (channel averaging) → ASR (FluidAudio Parakeet) → Diarization (Sortformer) → JSON serialization → ALAC compression

**Sources/UI:**
- Purpose: SwiftUI views organized by user-facing feature
- Contains: 5 feature-specific subdirectories + Shared reusable components
- Key files:
  - MainWindow: `ContentView.swift`, `MeetingListView.swift`, `MeetingDetailView.swift`, `TranscriptView.swift`, `AudioPlayerView.swift`, `ExportSheet.swift`
  - MenuBar: `MenuBarView.swift`, `RecordingIndicator.swift`
  - Onboarding: `OnboardingView.swift`
  - Settings: `SettingsView.swift`
  - Shared: `SpeakerBadge.swift`, `StatusDot.swift`

**Sources/Utilities:**
- Purpose: Cross-cutting utilities (logging, system permissions, formatting)
- Contains: Logger enum with subsystem categories, Permissions wrapper, Formatters
- Key files: `Logger.swift`, `Permissions.swift`, `Formatters.swift`

**Tests:**
- Purpose: Unit and integration test suites
- Target: CaddieTests bundle (linked against main Caddie target)
- Contains: Test files (naming convention likely `*.swift` in Tests directory)

**Resources:**
- Purpose: Non-code assets and app configuration
- Key files:
  - `Assets.xcassets`: App icons (AppIcon set)
  - `Info.plist`: App metadata, permissions descriptions, version info
  - `Caddie.entitlements`: Sandbox and capability declarations (Screen Recording, Microphone, Calendar, Accessibility)

## Key File Locations

**Entry Points:**
- `Sources/App/CaddieApp.swift`: @main entry point, creates AppState, renders scenes
- `Sources/App/AppState.swift`: async initialize() method triggered on app launch
- `Sources/UI/MainWindow/ContentView.swift`: Main window content with meeting list + detail split view

**Configuration:**
- `project.yml`: XcodeGen project specification (defines targets, packages, dependencies)
- `Resources/Info.plist`: App metadata (bundle ID, version, permissions descriptions)
- `Resources/Caddie.entitlements`: Entitlements for system audio capture, microphone, calendar, accessibility

**Core Logic:**
- `Sources/App/AppState.swift`: Orchestrates detection, recording, transcription lifecycle
- `Sources/Detection/MeetingDetector.swift`: Multi-signal meeting detection with grace period
- `Sources/Recording/AudioRecorder.swift`: Stereo WAV orchestration with ring buffers
- `Sources/Transcription/TranscriptionPipeline.swift`: Sequential job queue for transcription
- `Sources/Storage/Database.swift`: GRDB setup with WAL mode and migrations
- `Sources/Storage/Meeting.swift`: Database model with GRDB + Codable conformance

**Testing:**
- `Tests/`: Directory containing unit/integration test files

## Naming Conventions

**Files:**
- Swift source files: PascalCase, one class/major type per file (e.g., `AudioRecorder.swift`)
- Grouping: Logical features grouped in directories (e.g., all detection monitors in `Sources/Detection/`)
- Database models: PascalCase struct name matching entity type (e.g., `Meeting.swift`)

**Directories:**
- Feature/layer-based: `Detection/`, `Recording/`, `Transcription/`, etc.
- UI views organized by window/feature: `UI/MainWindow/`, `UI/MenuBar/`, `UI/Onboarding/`
- Test pattern: Collocated in `Tests/` directory

**Code Entities:**
- Classes/Structs: PascalCase (e.g., `MeetingDetector`, `AudioRecorder`)
- Functions: camelCase (e.g., `startRecording()`, `handleSignal()`)
- Properties: camelCase (e.g., `isRecording`, `currentMeetingTitle`)
- Enums: PascalCase (e.g., `AppStatus`, `MeetingStatus`)
- Constants: PascalCase (e.g., `flushThreshold`)

## Where to Add New Code

**New Meeting Detection Signal Source:**
- Implementation: `Sources/Detection/[NewMonitor]Monitor.swift` (conform to DetectionMonitor protocol)
- Integration: Add to MeetingDetector.start() to initialize monitor and set onSignal callback
- Decision logic: Update DecisionEngine.evaluate() if new signal type affects confirmation rules
- Patterns: `AudioProcessMonitor.swift` uses polling timer; `MicStateMonitor.swift` uses AVAudioEngine callbacks; follow matching pattern

**New Transcription Stage:**
- Pipeline step: Add method to TranscriptionPipeline.processNext()
- New file if substantial: `Sources/Transcription/[StageProcessor].swift`
- Database persistence: Update meetings table schema in Migrations if storing new data
- Error handling: Create stage-specific error enum, wrap in try-catch with DB status update

**New UI View:**
- Feature window/screen: Add to appropriate `Sources/UI/[Feature]/` directory
- Naming: `[Feature]View.swift` for main views, `[Feature]Sheet.swift` for modal sheets
- Environment: Accept AppState via `@Environment(AppState.self)`
- Database access: Query via `appState.database?.dbWriter` using GRDB ValueObservation for reactivity

**New Utility Function:**
- Formatting: Add to `Sources/Utilities/Formatters.swift` (e.g., duration string formatting)
- Permission checking: Add to `Sources/Utilities/Permissions.swift` (e.g., new system permission check)
- Logging: Use CaddieLogger with appropriate subsystem (defined in `Sources/Utilities/Logger.swift`)

**New Database Schema/Model:**
- Entity struct: `Sources/Storage/[Entity].swift` with GRDB conformance (FetchableRecord, MutablePersistableRecord)
- Migration: Add to `Sources/Storage/Migrations.swift` as new migrator version
- Query helpers: Add static methods to model (e.g., `.search()`, `.orderedByDate()`)
- Full-text search: Register table in migration if search needed (FTS5 trigger)

**New External Integration:**
- SDK import: Add to `project.yml` packages section with git URL and version constraint
- Wrapper: Create dedicated file in appropriate layer (e.g., `Sources/Models/` for new ML service)
- Error types: Define integration-specific error enums for proper error handling
- Initialization: Add to AppState.initialize() or lazy-initialize on first use

## Special Directories

**Sources/UI/Shared:**
- Purpose: Reusable UI components used across multiple features
- Generated: No, manually created components
- Committed: Yes, persistent code

**Resources/Assets.xcassets:**
- Purpose: Asset catalog for app icons and images
- Generated: Managed by Xcode
- Committed: Yes (including icon sets)

**Caddie.xcodeproj:**
- Purpose: Xcode project workspace configuration
- Generated: Partially (references project.yml via XcodeGen)
- Committed: Yes, but primary source is project.yml

**/Users/[user]/Library/Application Support/Caddie/**
- Purpose: Runtime data directory (created by app, not in repo)
- Generated: Yes, at first app launch
- Committed: No, excluded from git

---

*Structure analysis: 2026-03-22*

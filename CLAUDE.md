<!-- GSD:project-start source:PROJECT.md -->
## Project

**Caddie**

A native macOS menu bar app that automatically detects meetings, records system audio and microphone, transcribes with on-device ML (speaker diarization included), and stores everything locally in a searchable database. Zero cloud dependency — nothing leaves the device.

**Core Value:** Every meeting must be reliably captured, transcribed, and retrievable — no silent failures, no lost recordings, no data corruption.

### Constraints

- **Platform**: macOS 14.2+ (Sonoma), Apple Silicon recommended — CoreML/ANE acceleration
- **Privacy**: All processing on-device, no network calls except model download and Sparkle updates
- **Dependencies**: FluidAudio is the ML backbone — its C dependency (yyjson) causes the test linker issue
- **Permissions**: Requires Microphone, Screen Recording, Accessibility, Calendar — all via system prompts
- **Build system**: XcodeGen → Xcode project, SPM for dependencies
<!-- GSD:project-end -->

<!-- GSD:stack-start source:codebase/STACK.md -->
## Technology Stack

## Languages
- Swift - macOS application development (entire codebase in `Sources/`)
- SwiftUI - User interface framework
## Runtime
- macOS (10.13+ based on AudioToolbox and CoreAudio availability, SwiftUI features suggest 12.0+ minimum)
- Native application compiled via Xcode
- Swift Package Manager (SPM) - Integrated with Xcode
- Lockfile: `.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` (present)
## Frameworks
- SwiftUI - UI framework for app interface (CaddieApp.swift, ContentView.swift, MenuBarView.swift)
- AppKit - macOS window management, system integrations (`NSApplication`, `NSWindow`, `NSWorkspace`)
- Observation - State management with `@Observable` macro (AppState.swift)
- ServiceManagement - Launch at login functionality (SettingsView.swift)
- AudioToolbox - Low-level audio file operations (WAV creation, compression to ALAC)
- CoreAudio - Raw audio buffer handling and system audio capture
- AVFoundation - Microphone access and audio session management
- EventKit - Calendar event monitoring (CalendarMonitor.swift)
- AppKit - Window title monitoring (AXSwift wrapper for accessibility)
- CoreGraphics - Screen event handling
- FluidAudio v0.12.4 - ASR (Automatic Speech Recognition) and diarization models
- GRDB v7.10.0 - SQLite ORM and query builder
- SimplyCoreAudio v4.1.1 - Simplified CoreAudio wrapper for microphone capture
- AXSwift v0.3.2 - Accessibility API wrapper for window title monitoring
- Sparkle v2.9.0 - Automatic app updates (menu bar app updating)
- swift-nio v2.96.0 - Async networking (used by FluidAudio for model downloads)
- swift-huggingface v0.9.0 - HuggingFace API client for model downloads
- swift-transformers v1.2.0 - ML transformer models (FluidAudio dependency)
- EventSource v1.4.1 - Server-sent events handling
- yyjson v0.12.0 - Fast JSON parsing
- swift-crypto v4.3.0 - Cryptographic operations
- swift-collections v1.4.1 - Advanced collection types
- swift-atomics v1.3.0 - Thread-safe operations
- swift-system v1.6.4 - System APIs
- swift-asn1 v1.6.0 - ASN.1 encoding/decoding (certificate handling)
- swift-jinja v2.3.2 - Template rendering
## Configuration
- UserDefaults - App preferences (onboarding flag in AppState.swift)
- Application Support Directory (`~/Library/Application Support/Caddie/`) - Database and audio files
- Xcode project: `Caddie.xcodeproj`
- Target: macOS app with MenuBar (statusbar) and main window
- Architectures: arm64 and x86_64 (universal binary typical for macOS)
## Platform Requirements
- macOS 12.0 or later (for SwiftUI features and @Observable)
- Xcode 15+ (with Swift 5.9+ for @Observable macro)
- Microphone and/or system audio capture capability
- Permissions: Microphone, Screen Recording (for system audio), Accessibility (window title monitoring), Calendar
- macOS 12.0 or later
- Microphone access required for core functionality
- System audio capture requires Screen Recording permission
- Calendar and accessibility integrations optional but enabled by default
- Sparkle auto-update infrastructure active
- App Store (.pkg installer) or direct DMG distribution
- Code signing with Apple developer certificate
- Notarization required for Sparkle distribution
- MenuBar app with optional main window
<!-- GSD:stack-end -->

<!-- GSD:conventions-start source:CONVENTIONS.md -->
## Conventions

## Naming Patterns
- **View files:** `*View.swift` (e.g., `ContentView.swift`, `MeetingDetailView.swift`)
- **Engine classes:** `*Engine.swift` (e.g., `ASREngine.swift`, `DiarizationEngine.swift`)
- **Manager classes:** `*Manager.swift` (e.g., `ModelManager.swift`)
- **Monitor classes:** `*Monitor.swift` (e.g., `AudioProcessMonitor.swift`, `MicStateMonitor.swift`)
- **Utility enums:** Descriptive name ending with noun (e.g., `Formatters.swift`, `Permissions.swift`, `AudioFileManager.swift`)
- **Tests:** `*Tests.swift` (e.g., `FormattersTests.swift`, `MeetingModelTests.swift`)
- **Private helper functions:** Prefixed with underscore is NOT used; instead use `private` keyword with descriptive names
- **Static utility methods:** Grouped in enums or as static functions on types (e.g., `Formatters.duration()`, `AudioFileManager.wavPath()`)
- **Initialization methods:** `initialize()` for setting up complex state
- **Async methods:** Use `async throws` pattern explicitly (e.g., `func transcribe(audioURL:) async throws`)
- **Event handlers:** Prefixed with verb (e.g., `startRecording()`, `stopRecording()`)
- **Callback properties:** Named with `on` prefix (e.g., `onMeetingStarted`, `onSignal`)
- **Instance properties:** camelCase (e.g., `isRecording`, `currentMeetingId`, `recordingDuration`)
- **Private properties:** `private(set)` for read-only public access with internal write (e.g., `private(set) var database: AppDatabase?`)
- **Static constants:** camelCase starting with `Self.` prefix in private context (e.g., `Self.flushThreshold`, `Self.sampleRate`)
- **Enum cases:** lowercase (e.g., `case idle`, `case recording`, `case done`)
- **Enum cases:** Snake_case or UPPERCASE for constants (e.g., `case .recording`, `"SPEAKER_00"` format)
- **Error enums:** Always conform to `Error & LocalizedError` (e.g., `ASRError`, `DiarizationError`)
- **Observable types:** Use `@Observable` macro from Observation framework (e.g., `@Observable final class AppState`)
- **Final classes:** Always mark classes as `final` unless inheritance is required (e.g., `final class AppState`, `final class AudioRecorder`)
- **Struct vs class:** Use structs for immutable data models (e.g., `Meeting`, `ASRSegment`), classes for mutable state managers
## Code Style
- **Indentation:** 4 spaces (Swift standard)
- **Line length:** Pragmatic; lines extend beyond 80 chars for readability when necessary
- **Braces:** Opening brace on same line (Java/Kotlin style)
- **Blank lines:** Single blank line between methods and logical sections
- No SwiftLint or formatting tool enforced; style is enforced through code review
- Standard Swift conventions are followed (Apple Swift Style Guide)
## Import Organization
- No path aliases used; all relative imports use direct module references
## Error Handling
- **Error types:** Custom error enums inheriting from `Error & LocalizedError` with `errorDescription` property
- **Error propagation:** Use `throws` and `async throws` for propagating errors up the call stack
- **Error catching:** Specific error type matching in `catch` blocks (not generic catch-all)
- **Graceful degradation:** When partial failure is acceptable, log and continue (e.g., `AudioRecorder` logs system audio capture failure but continues with microphone-only recording)
- **Database errors:** Wrapped and logged; database connection errors are fatal to operation
## Logging
- `logger.info()` for significant state changes (e.g., "Recording started for meeting \(meetingId)")
- `logger.error()` for recoverable errors with context
- `logger.warning()` for unexpected but non-fatal conditions
- Log messages include context variables (meeting IDs, counts, durations)
- Async operations log completion and timing (e.g., "Pipeline complete in 45.3s")
## Comments
- Complex algorithms with non-obvious logic (e.g., token grouping in `ASREngine`)
- Workarounds and platform-specific behavior (e.g., screen recording permission detection in `Permissions`)
- Section headers using `// MARK: - SectionName` convention
- Public API documentation (doc comments on public functions)
- Not used; Swift relies on inline code clarity and function signatures
- Function documentation is sparse; code is self-documenting
## Function Design
- Short to medium functions (15-40 lines typical)
- Longer functions only when they represent a single logical step with complex state management
- Complex flows broken into named private helper methods
- Explicit parameter names always used (no positional arguments without labels)
- Optional parameters placed at end
- Related parameters grouped together (e.g., `outputPath`, `processID` together)
- Async functions return via tuple when multiple values needed (e.g., `(segments: [ASRSegment], language: String, duration: Double)`)
- Void returns when side effects are the goal (state updates, file writes)
- Optional returns only when absence of value is meaningful, not for error cases (errors thrown instead)
## Module Design
- Public APIs are explicit; only what's needed for external use is public
- Internal integration types marked `@testable` for testing access
- Actors used for concurrency boundaries (e.g., `actor TranscriptionPipeline`)
- Not used; each file exports a single main type
- Flat file organization within module directories
- Used to organize code within files: `// MARK: - Lifecycle`, `// MARK: - Private`, `// MARK: - Errors`
- Standard pattern for readability
<!-- GSD:conventions-end -->

<!-- GSD:architecture-start source:ARCHITECTURE.md -->
## Architecture

## Pattern Overview
- Multi-stage pipeline: Detection → Recording → Transcription → Storage
- Protocol-driven extensibility for detection monitors
- Actor-based TranscriptionPipeline for safe concurrent processing
- Observable state management via SwiftUI's @Observable macro
- Dependency injection through constructor parameters
- Ring buffers with thread-safe locking for audio samples
- Database-first design using GRDB with FTS5 full-text search
## Layers
- Purpose: Monitor system state for meeting indicators (audio processes, microphone, window titles, calendar events)
- Location: `Sources/Detection/`
- Contains: MeetingDetector, AudioProcessMonitor, MicStateMonitor, WindowTitleMonitor, CalendarMonitor, MeetingPatterns
- Depends on: AppKit, CoreAudio, EventKit, AXSwift
- Used by: AppState for initiating recording/transcription lifecycle
- Purpose: Capture system audio + microphone into stereo WAV files with thread-safe buffer management
- Location: `Sources/Recording/`
- Contains: AudioRecorder, SystemAudioCapture, MicrophoneCapture
- Depends on: AudioToolbox, AVFoundation, AppKit
- Used by: AppState to persist raw audio
- Purpose: Manage database persistence, audio file lifecycle, and file format conversion
- Location: `Sources/Storage/`
- Contains: AppDatabase, Meeting, AudioFileManager, Migrations
- Depends on: GRDB, Foundation, AudioToolbox
- Used by: AppState (database), TranscriptionPipeline (transcripts), UI components (queries)
- Purpose: Process audio through ML pipeline: mono mixdown → ASR → diarization → merge → write to DB
- Location: `Sources/Transcription/`
- Contains: TranscriptionPipeline (actor), ASREngine, DiarizationEngine, TranscriptMerger
- Depends on: FluidAudio (ASR + diarization models), AudioFileManager, AppDatabase
- Used by: AppState to enqueue transcription jobs
- Purpose: Download and cache ML models (ASR, diarization) via FluidAudio
- Location: `Sources/Models/`
- Contains: ModelManager
- Depends on: FluidAudio
- Used by: AppState initialization
- Purpose: SwiftUI views organized by feature (MainWindow, MenuBar, Onboarding, Settings)
- Location: `Sources/UI/`
- Contains: ContentView, MeetingListView, MeetingDetailView, MenuBarView, OnboardingView, SettingsView, AudioPlayerView, ExportSheet
- Depends on: SwiftUI, AppState, AppDatabase
- Used by: CaddieApp entry point
- Purpose: Cross-cutting concerns (logging, permissions, formatting)
- Location: `Sources/Utilities/`
- Contains: Logger, Permissions, Formatters
- Depends on: Foundation, AppKit, os
- Used by: All layers
- Purpose: Initialize application state and manage lifecycle
- Location: `Sources/App/`
- Contains: CaddieApp, AppState, AppDelegate
- Depends on: All other layers
- Used by: @main entry point
## Data Flow
- AppState holds all lifecycle state: status, currentMeetingTitle, recordingStartTime, transcriptionProgress
- AppState is @Observable, passed via .environment() to all UI views
- Database is lazy-loaded during AppState.initialize()
- Models downloaded asynchronously during onboarding or app launch
## Key Abstractions
- Purpose: Abstract interface for monitoring different meeting indicators
- Examples: `Sources/Detection/AudioProcessMonitor.swift`, `Sources/Detection/MicStateMonitor.swift`
- Pattern: Polling timer with callback-based signal emission. Each monitor runs independently, no blocking.
- Purpose: Stateless logic to evaluate multiple signals and determine if meeting is occurring
- Examples: Requires audio process + microphone, OR window title + calendar event
- Pattern: Pure function (no state mutations) for testability
- Purpose: Serial queue for transcription jobs with built-in concurrency safety
- Pattern: Swift actor with async/await. Single `isProcessing` flag. Processes queue[0], then recursively calls processNext()
- Guarantees: No race conditions on job queue, no concurrent transcription of same file
- Purpose: Encapsulate FluidAudio SDK integration and error handling
- Pattern: Initialize once with models, then call transcribe/diarize multiple times
- Injected into TranscriptionPipeline as constructor parameters
- Purpose: Orchestrate system + microphone capture into single stereo WAV
- Pattern: Composes SystemAudioCapture + MicrophoneCapture. Buffers samples separately. Flushes on threshold. Thread-safe via NSLock.
- Purpose: Database entity with Codable + FetchableRecord + MutablePersistableRecord
- Pattern: Single struct with GRDB conformance, CodingKeys for snake_case mapping, static query helpers
## Entry Points
- Location: `Sources/App/CaddieApp.swift`
- Triggers: @main entry point
- Responsibilities: Create AppState, render MenuBarExtra + Window + Settings, establish AppDelegate for window lifecycle management
- Location: `Sources/App/AppState.swift`
- Triggers: ContentView.task on appearance
- Responsibilities: Create AppDatabase, download models, initialize ASR/diarization engines, create TranscriptionPipeline, start MeetingDetector
- Location: `Sources/Detection/MeetingDetector.swift`
- Triggers: AppState.initialize() after pipeline setup
- Responsibilities: Start all 4 monitors, set up signal callbacks, enable meeting detection loop
- Location: `Sources/Transcription/TranscriptionPipeline.swift`
- Triggers: AppState.stopRecording() with meetingId
- Responsibilities: Add job to queue, process next if not already processing
## Error Handling
- Recording failures: Log and continue (microphone-only fallback if system audio fails)
- Transcription failures: Write error message to meetings.error column, set status=error
- Model download failures: Write to AppState.initError, display in UI with Retry button
- Audio file operation failures: Custom OSStatus-based error types (AudioError, RecorderError)
- Database failures: Log, attempt to update status, bail gracefully
## Cross-Cutting Concerns
- CaddieLogger.app (AppState, CaddieApp)
- CaddieLogger.detection (MeetingDetector, monitors)
- CaddieLogger.recording (AudioRecorder, captures)
- CaddieLogger.transcription (TranscriptionPipeline, engines)
- CaddieLogger.storage (Database, AudioFileManager)
- Meeting title extraction from detected app: MeetingPatterns.isMeetingTitle() with regex matching
- Window title parsing via AXSwift accessibility API
- Audio file format checks: Expect stereo 16kHz Int16 PCM for recording, mono for transcription
- System audio capture: Requires Screen Recording + Microphone permissions via PrivacyScreen
- Calendar monitoring: Requires Calendar access via EventKit
- Window title access: Requires Accessibility permissions via AXSwift
<!-- GSD:architecture-end -->

<!-- GSD:workflow-start source:GSD defaults -->
## GSD Workflow Enforcement

Before using Edit, Write, or other file-changing tools, start work through a GSD command so planning artifacts and execution context stay in sync.

Use these entry points:
- `/gsd:quick` for small fixes, doc updates, and ad-hoc tasks
- `/gsd:debug` for investigation and bug fixing
- `/gsd:execute-phase` for planned phase work

Do not make direct repo edits outside a GSD workflow unless the user explicitly asks to bypass it.
<!-- GSD:workflow-end -->



<!-- GSD:profile-start -->
## Developer Profile

> Profile not yet configured. Run `/gsd:profile-user` to generate your developer profile.
> This section is managed by `generate-claude-profile` -- do not edit manually.
<!-- GSD:profile-end -->

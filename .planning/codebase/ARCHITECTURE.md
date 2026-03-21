# Architecture

**Analysis Date:** 2026-03-22

## Pattern Overview

**Overall:** Layered architecture with clear separation of concerns using protocol-based abstraction and actor-based concurrency.

**Key Characteristics:**
- Multi-stage pipeline: Detection → Recording → Transcription → Storage
- Protocol-driven extensibility for detection monitors
- Actor-based TranscriptionPipeline for safe concurrent processing
- Observable state management via SwiftUI's @Observable macro
- Dependency injection through constructor parameters
- Ring buffers with thread-safe locking for audio samples
- Database-first design using GRDB with FTS5 full-text search

## Layers

**Detection Layer:**
- Purpose: Monitor system state for meeting indicators (audio processes, microphone, window titles, calendar events)
- Location: `Sources/Detection/`
- Contains: MeetingDetector, AudioProcessMonitor, MicStateMonitor, WindowTitleMonitor, CalendarMonitor, MeetingPatterns
- Depends on: AppKit, CoreAudio, EventKit, AXSwift
- Used by: AppState for initiating recording/transcription lifecycle

**Recording Layer:**
- Purpose: Capture system audio + microphone into stereo WAV files with thread-safe buffer management
- Location: `Sources/Recording/`
- Contains: AudioRecorder, SystemAudioCapture, MicrophoneCapture
- Depends on: AudioToolbox, AVFoundation, AppKit
- Used by: AppState to persist raw audio

**Storage Layer:**
- Purpose: Manage database persistence, audio file lifecycle, and file format conversion
- Location: `Sources/Storage/`
- Contains: AppDatabase, Meeting, AudioFileManager, Migrations
- Depends on: GRDB, Foundation, AudioToolbox
- Used by: AppState (database), TranscriptionPipeline (transcripts), UI components (queries)

**Transcription Layer:**
- Purpose: Process audio through ML pipeline: mono mixdown → ASR → diarization → merge → write to DB
- Location: `Sources/Transcription/`
- Contains: TranscriptionPipeline (actor), ASREngine, DiarizationEngine, TranscriptMerger
- Depends on: FluidAudio (ASR + diarization models), AudioFileManager, AppDatabase
- Used by: AppState to enqueue transcription jobs

**Models Layer:**
- Purpose: Download and cache ML models (ASR, diarization) via FluidAudio
- Location: `Sources/Models/`
- Contains: ModelManager
- Depends on: FluidAudio
- Used by: AppState initialization

**UI Layer:**
- Purpose: SwiftUI views organized by feature (MainWindow, MenuBar, Onboarding, Settings)
- Location: `Sources/UI/`
- Contains: ContentView, MeetingListView, MeetingDetailView, MenuBarView, OnboardingView, SettingsView, AudioPlayerView, ExportSheet
- Depends on: SwiftUI, AppState, AppDatabase
- Used by: CaddieApp entry point

**Utilities Layer:**
- Purpose: Cross-cutting concerns (logging, permissions, formatting)
- Location: `Sources/Utilities/`
- Contains: Logger, Permissions, Formatters
- Depends on: Foundation, AppKit, os
- Used by: All layers

**App Layer:**
- Purpose: Initialize application state and manage lifecycle
- Location: `Sources/App/`
- Contains: CaddieApp, AppState, AppDelegate
- Depends on: All other layers
- Used by: @main entry point

## Data Flow

**Meeting Recording Lifecycle:**

1. **Detection Phase (Continuous)**
   - MeetingDetector polls 4 detection monitors every 3 seconds
   - Monitors emit DetectionSignal when state changes
   - DecisionEngine evaluates signals: requires 2+ active signals confirming meeting
   - Valid meeting triggers `onMeetingStarted` callback

2. **Recording Phase**
   - AppState.startRecording() creates Meeting record in DB with status=recording
   - AudioRecorder orchestrates SystemAudioCapture + MicrophoneCapture
   - Audio samples (16kHz PCM Int16) buffered separately per source
   - Buffers flushed when both reach 1600 samples (~100ms at 16kHz)
   - Interleaved stereo samples written to WAV file
   - Recording continues until `onMeetingEnded` fires (after 15s grace period)

3. **Transcription Enqueue**
   - AppState.stopRecording() updates DB: status=transcribing
   - Enqueues meeting to TranscriptionPipeline (actor)
   - TranscriptionPipeline processes one job at a time (FIFO queue)

4. **Transcription Processing (Sequential)**
   - **Mono Mixdown**: Stereo WAV → mono WAV (channel average)
   - **ASR**: Mono → ASR segments with word-level timings
   - **Diarization**: Mono → speaker segments (speaker slots 0-N)
   - **Merge**: Overlap ASR + speakers → TranscriptSegments with speaker attribution
   - **Write DB**: Transcript JSON serialized to meetings.transcript
   - **Compress**: Stereo WAV → ALAC (.m4a) for storage
   - **Update Status**: DB status=done
   - **Cleanup**: Delete stereo WAV (already have ALAC)

5. **UI Observation**
   - ContentView observes meetings table via GRDB ValueObservation
   - Auto-updates when new meetings created or transcripts written
   - Search uses FTS5 index on meetings_fts table

**State Management:**
- AppState holds all lifecycle state: status, currentMeetingTitle, recordingStartTime, transcriptionProgress
- AppState is @Observable, passed via .environment() to all UI views
- Database is lazy-loaded during AppState.initialize()
- Models downloaded asynchronously during onboarding or app launch

## Key Abstractions

**DetectionMonitor (Protocol):**
- Purpose: Abstract interface for monitoring different meeting indicators
- Examples: `Sources/Detection/AudioProcessMonitor.swift`, `Sources/Detection/MicStateMonitor.swift`
- Pattern: Polling timer with callback-based signal emission. Each monitor runs independently, no blocking.

**DecisionEngine (Nested Extension):**
- Purpose: Stateless logic to evaluate multiple signals and determine if meeting is occurring
- Examples: Requires audio process + microphone, OR window title + calendar event
- Pattern: Pure function (no state mutations) for testability

**TranscriptionPipeline (Actor):**
- Purpose: Serial queue for transcription jobs with built-in concurrency safety
- Pattern: Swift actor with async/await. Single `isProcessing` flag. Processes queue[0], then recursively calls processNext()
- Guarantees: No race conditions on job queue, no concurrent transcription of same file

**ASREngine, DiarizationEngine (Wrappers):**
- Purpose: Encapsulate FluidAudio SDK integration and error handling
- Pattern: Initialize once with models, then call transcribe/diarize multiple times
- Injected into TranscriptionPipeline as constructor parameters

**AudioRecorder (Composition):**
- Purpose: Orchestrate system + microphone capture into single stereo WAV
- Pattern: Composes SystemAudioCapture + MicrophoneCapture. Buffers samples separately. Flushes on threshold. Thread-safe via NSLock.

**Meeting (GRDB Model):**
- Purpose: Database entity with Codable + FetchableRecord + MutablePersistableRecord
- Pattern: Single struct with GRDB conformance, CodingKeys for snake_case mapping, static query helpers

## Entry Points

**CaddieApp:**
- Location: `Sources/App/CaddieApp.swift`
- Triggers: @main entry point
- Responsibilities: Create AppState, render MenuBarExtra + Window + Settings, establish AppDelegate for window lifecycle management

**AppState.initialize():**
- Location: `Sources/App/AppState.swift`
- Triggers: ContentView.task on appearance
- Responsibilities: Create AppDatabase, download models, initialize ASR/diarization engines, create TranscriptionPipeline, start MeetingDetector

**MeetingDetector.start():**
- Location: `Sources/Detection/MeetingDetector.swift`
- Triggers: AppState.initialize() after pipeline setup
- Responsibilities: Start all 4 monitors, set up signal callbacks, enable meeting detection loop

**TranscriptionPipeline.enqueue():**
- Location: `Sources/Transcription/TranscriptionPipeline.swift`
- Triggers: AppState.stopRecording() with meetingId
- Responsibilities: Add job to queue, process next if not already processing

## Error Handling

**Strategy:** Errors cascade to database for persistence, logged via os.Logger subsystem categories.

**Patterns:**
- Recording failures: Log and continue (microphone-only fallback if system audio fails)
- Transcription failures: Write error message to meetings.error column, set status=error
- Model download failures: Write to AppState.initError, display in UI with Retry button
- Audio file operation failures: Custom OSStatus-based error types (AudioError, RecorderError)
- Database failures: Log, attempt to update status, bail gracefully

## Cross-Cutting Concerns

**Logging:** Uses os.Logger with subsystem "com.caddie.app" and per-module categories:
- CaddieLogger.app (AppState, CaddieApp)
- CaddieLogger.detection (MeetingDetector, monitors)
- CaddieLogger.recording (AudioRecorder, captures)
- CaddieLogger.transcription (TranscriptionPipeline, engines)
- CaddieLogger.storage (Database, AudioFileManager)

**Validation:**
- Meeting title extraction from detected app: MeetingPatterns.isMeetingTitle() with regex matching
- Window title parsing via AXSwift accessibility API
- Audio file format checks: Expect stereo 16kHz Int16 PCM for recording, mono for transcription

**Authentication:**
- System audio capture: Requires Screen Recording + Microphone permissions via PrivacyScreen
- Calendar monitoring: Requires Calendar access via EventKit
- Window title access: Requires Accessibility permissions via AXSwift

---

*Architecture analysis: 2026-03-22*

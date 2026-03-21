# Architecture Research

**Domain:** macOS on-device audio recording + ML transcription pipeline hardening
**Researched:** 2026-03-22
**Confidence:** HIGH (patterns well-documented in Swift ecosystem; verified against current codebase)

## Standard Architecture

### System Overview

```
┌───────────────────────────────────────────────────────────────────────┐
│                         UI Layer (SwiftUI)                            │
│  ┌────────────┐ ┌────────────┐ ┌────────────┐ ┌───────────────┐      │
│  │ MenuBar    │ │ MeetingList│ │ Detail/    │ │ Onboarding/  │      │
│  │ View       │ │ View       │ │ Transcript │ │ Settings     │      │
│  └─────┬──────┘ └─────┬──────┘ └─────┬──────┘ └──────┬───────┘      │
│        │              │              │               │              │
│        └──────────────┴──────┬───────┴───────────────┘              │
│                              │ @Observable                          │
├──────────────────────────────┴──────────────────────────────────────┤
│                      Coordinator Layer                              │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │               RecordingCoordinator (Actor)                   │   │
│  │  State Machine: idle → recording → transcribing → done/err  │   │
│  │  Owns: lifecycle transitions, error policy, retry logic      │   │
│  └──────────┬─────────────────┬─────────────────┬──────────────┘   │
│             │                 │                 │                   │
├─────────────┴─────────────────┴─────────────────┴──────────────────┤
│                       Service Layer                                 │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────────┐     │
│  │ Detection   │  │ Recording   │  │ Transcription           │     │
│  │ Service     │  │ Service     │  │ Pipeline (Actor)        │     │
│  │             │  │             │  │ mono→ASR→diarize→merge  │     │
│  └──────┬──────┘  └──────┬──────┘  └──────────┬──────────────┘     │
│         │                │                    │                     │
├─────────┴────────────────┴────────────────────┴────────────────────┤
│                      Infrastructure Layer                           │
│  ┌──────────┐  ┌───────────────┐  ┌──────────┐  ┌──────────────┐   │
│  │ CoreAudio│  │ GRDB/SQLite   │  │ FluidAudio│ │ FileManager │   │
│  │ HAL+Taps │  │ DatabasePool  │  │ ASR+Diar │  │ Temp/ALAC   │   │
│  └──────────┘  └───────────────┘  └──────────┘  └──────────────┘   │
└───────────────────────────────────────────────────────────────────────┘
```

### Component Responsibilities

| Component | Responsibility | Boundary |
|-----------|----------------|----------|
| **RecordingCoordinator** | Owns the recording lifecycle state machine. Validates transitions, gates operations on preconditions (disk space, DB writability, pipeline readiness). Single source of truth for "what state is this meeting in?" | Receives events from Detection; dispatches to Recording/Transcription services; publishes state to UI via @Observable |
| **DetectionService** | Monitors system for meeting indicators (audio processes, mic, window titles, calendar). Emits meeting-started/ended events. | Talks only to Coordinator via callback/AsyncStream. No direct access to Recording or DB. |
| **RecordingService** | Manages CoreAudio tap lifecycle, buffer management, WAV file writing. | Receives start/stop commands from Coordinator. Emits errors back. No DB access. |
| **TranscriptionPipeline** | Processes audio through mono mixdown, ASR, diarization, merge. Writes transcript to DB. Manages temp file lifecycle. | Receives jobs from Coordinator. Owns its own queue. Reports completion/failure back. |
| **AppDatabase** | Thread-safe SQLite access via GRDB DatabasePool. WAL mode. Migrations. | Injected once at init, never replaced. Shared by Coordinator and Pipeline. |
| **AudioFileManager** | File path conventions, mono mixdown, ALAC compression, temp file cleanup. | Pure utility, no state. Called by Pipeline and Coordinator. |

## Recommended Project Structure

The current folder layout is already well-organized. The key structural change is introducing a coordinator to decouple AppState from business logic.

```
Sources/
├── App/                    # Entry point, app lifecycle
│   ├── CaddieApp.swift     # @main, window/menu setup
│   ├── AppState.swift      # @Observable UI state container (thin)
│   └── AppDelegate.swift   # Window lifecycle
├── Coordinator/            # NEW: Recording lifecycle orchestration
│   ├── RecordingCoordinator.swift  # Actor-based state machine
│   └── RecordingState.swift        # State enum + transition validation
├── Detection/              # Meeting detection (unchanged)
│   ├── MeetingDetector.swift
│   ├── AudioProcessMonitor.swift
│   ├── MicStateMonitor.swift
│   ├── WindowTitleMonitor.swift
│   ├── CalendarMonitor.swift
│   └── MeetingPatterns.swift
├── Recording/              # Audio capture (unchanged)
│   ├── AudioRecorder.swift
│   ├── SystemAudioCapture.swift
│   └── MicrophoneCapture.swift
├── Transcription/          # ML pipeline (unchanged)
│   ├── TranscriptionPipeline.swift
│   ├── ASREngine.swift
│   ├── DiarizationEngine.swift
│   └── TranscriptMerger.swift
├── Storage/                # Database + file management
│   ├── Database.swift
│   ├── Meeting.swift
│   ├── Migrations.swift
│   └── AudioFileManager.swift
├── Models/                 # ML model management
│   └── ModelManager.swift
├── UI/                     # SwiftUI views (unchanged structure)
│   ├── MenuBar/
│   ├── MainWindow/
│   ├── Onboarding/
│   ├── Settings/
│   └── Shared/
└── Utilities/              # Cross-cutting
    ├── Logger.swift
    ├── Permissions.swift
    └── Formatters.swift
```

### Structure Rationale

- **Coordinator/**: Extracted from the current AppState which is doing too much (UI state + business logic + lifecycle management). The coordinator owns the state machine; AppState becomes a thin @Observable wrapper that the coordinator publishes to.
- **Everything else stays**: The existing layer separation (Detection, Recording, Transcription, Storage) is sound. The problem is not structure but rather the lack of a proper state machine and error handling discipline between them.

## Architectural Patterns

### Pattern 1: Actor-Based State Machine with Synchronous Transitions

**What:** The recording lifecycle (idle -> recording -> transcribing -> done/error) is modeled as a Swift actor with an enum state. All state transitions happen in synchronous (non-async) methods to prevent actor reentrancy bugs. Async work (recording, transcription) is dispatched after the transition completes.

**When to use:** Any multi-step lifecycle where invalid transitions cause data loss or crashes. This is the critical missing piece in the current codebase.

**Trade-offs:** Requires discipline to keep transition logic synchronous. Adds an indirection layer between AppState and services. Worth it because the current approach (mutating state across multiple methods in a non-actor class with `[weak self]` callbacks) is the root cause of most concerns in CONCERNS.md.

**Example:**

```swift
actor RecordingCoordinator {
    enum State: Sendable {
        case idle
        case recording(meetingId: String, startTime: Date)
        case transcribing(meetingId: String)
        case error(meetingId: String, Error)
    }

    enum Event: Sendable {
        case meetingDetected(DetectedMeeting)
        case meetingEnded
        case transcriptionComplete(meetingId: String)
        case transcriptionFailed(meetingId: String, Error)
        case retryRequested(meetingId: String)
    }

    private(set) var state: State = .idle

    // SYNCHRONOUS - no await, no reentrancy risk
    // Returns side effects to execute, does NOT execute them
    private func reduce(event: Event) -> SideEffect? {
        switch (state, event) {
        case (.idle, .meetingDetected(let meeting)):
            let meetingId = generateMeetingId()
            state = .recording(meetingId: meetingId, startTime: Date())
            return .startRecording(meetingId: meetingId, meeting: meeting)

        case (.recording(let meetingId, _), .meetingEnded):
            state = .transcribing(meetingId: meetingId)
            return .stopAndTranscribe(meetingId: meetingId)

        case (.transcribing(let meetingId), .transcriptionComplete):
            state = .idle
            return .notifyComplete(meetingId: meetingId)

        case (.transcribing(let meetingId), .transcriptionFailed(_, let error)):
            state = .error(meetingId: meetingId, error)
            return .notifyError(meetingId: meetingId, error: error)

        default:
            // Invalid transition - log but don't crash
            logger.warning("Invalid transition: \(state) + \(event)")
            return nil
        }
    }

    // PUBLIC async method - dispatches event, then executes side effect
    func handle(_ event: Event) async {
        let effect = reduce(event: event)  // synchronous!
        if let effect {
            await execute(effect)  // async work happens AFTER state update
        }
    }
}
```

**Why this pattern matters for Caddie:** The current AppState has multiple race conditions documented in CONCERNS.md (pipeline nil during init, weak self in callbacks, state mutations spread across startRecording/stopRecording). The reduce pattern centralizes all transitions in one switch statement, making invalid states impossible and all transitions auditable.

**Source:** LINE Engineering Tech Blog - [Implementing a robust state machine with Swift Concurrency](https://techblog.lycorp.co.jp/en/20250117a); Apple WWDC21 - [Protect mutable state with Swift actors](https://developer.apple.com/videos/play/wwdc2021/10133/)

### Pattern 2: Critical Write Protection via Unstructured Tasks

**What:** GRDB 7's async write methods respect Swift Task cancellation -- if a task is cancelled, the write throws CancellationError and the transaction is rolled back. For writes that must never be lost (transcript persistence, status updates), wrap them in an unstructured `Task {}` that ignores the parent task's cancellation.

**When to use:** Any database write where data loss is unacceptable. In Caddie, this means: transcript writes, meeting status transitions, and meeting record creation.

**Trade-offs:** Unstructured Tasks bypass structured concurrency's automatic cleanup. Use sparingly and only for writes that are truly critical. The alternative -- losing a completed transcript because the parent task was cancelled -- is worse.

**Example:**

```swift
// BAD: Parent task cancellation rolls back the transcript write
func processTranscription(meetingId: String) async throws {
    let transcript = try await runASR(meetingId)
    try await db.dbWriter.write { db in  // <-- CancellationError if task cancelled!
        try db.execute(sql: "UPDATE meetings SET transcript = ?", arguments: [transcript])
    }
}

// GOOD: Critical write completes regardless of parent task cancellation
func processTranscription(meetingId: String) async throws {
    let transcript = try await runASR(meetingId)
    // Unstructured Task ignores parent cancellation
    await Task {
        try await db.dbWriter.write { db in
            try db.execute(sql: "UPDATE meetings SET transcript = ?", arguments: [transcript])
        }
    }.value
}
```

**Source:** [GRDB.swift releases](https://github.com/groue/GRDB.swift/releases) - documented behavior in GRDB 7.x where async writes respect Task cancellation; [GRDB concurrency docs](https://swiftpackageindex.com/groue/GRDB.swift/master/documentation/grdb/swiftconcurrency)

### Pattern 3: Precondition Gating Before Expensive Operations

**What:** Before starting any expensive operation (recording, transcription), validate all preconditions synchronously. If any fail, refuse to proceed and report the failure immediately rather than discovering it mid-operation.

**When to use:** Before recording (check disk space, DB writability, pipeline readiness). Before transcription (check WAV file exists, DB record exists). This directly addresses 5+ concerns in CONCERNS.md.

**Trade-offs:** Adds a small latency to operation start (checking disk space, validating DB). Negligible compared to the cost of a failed recording or lost transcript.

**Example:**

```swift
enum PreconditionError: Error {
    case insufficientDiskSpace(available: UInt64, required: UInt64)
    case databaseUnavailable
    case pipelineNotReady
    case audioFileNotFound(String)
    case meetingRecordMissing(String)
}

// In RecordingCoordinator
private func validateRecordingPreconditions() throws {
    guard database != nil else {
        throw PreconditionError.databaseUnavailable
    }
    let available = try FileManager.default.availableDiskSpace()
    let required: UInt64 = 500 * 1024 * 1024 // 500MB
    guard available >= required else {
        throw PreconditionError.insufficientDiskSpace(available: available, required: required)
    }
}

private func validateTranscriptionPreconditions(meetingId: String) throws {
    guard pipeline != nil else {
        throw PreconditionError.pipelineNotReady
    }
    let wavURL = AudioFileManager.wavPath(for: meetingId)
    guard FileManager.default.fileExists(atPath: wavURL.path) else {
        throw PreconditionError.audioFileNotFound(meetingId)
    }
}
```

### Pattern 4: Explicit Temp File Lifecycle Management

**What:** Instead of using `defer` for temp file cleanup (which runs even on cancellation/crash, potentially deleting files still in use), track temp files explicitly and clean them up only after all consumers are done.

**When to use:** Any pipeline with shared intermediate files. In Caddie, the mono mixdown file is consumed by both ASR and diarization engines.

**Trade-offs:** More verbose than `defer`. Requires tracking which files exist. But `defer` in the current pipeline deletes the mono file while diarization might still be reading it -- this pattern prevents that.

**Example:**

```swift
actor TranscriptionPipeline {
    // Track temp files per job for explicit lifecycle management
    private var activeTempFiles: [String: Set<URL>] = [:]

    private func process(meetingId: String) async throws {
        let monoURL = try AudioFileManager.createMonoMixdown(
            stereoURL: AudioFileManager.wavPath(for: meetingId)
        )
        activeTempFiles[meetingId, default: []].insert(monoURL)

        // Both ASR and diarization read from monoURL
        let asrResult = try await asrEngine.transcribe(audioURL: monoURL)
        let speakerResult = try await diarizationEngine.diarize(audioURL: monoURL)

        // ONLY clean up after BOTH consumers are done
        cleanupTempFiles(for: meetingId)

        // ... merge and persist
    }

    private func cleanupTempFiles(for meetingId: String) {
        guard let files = activeTempFiles.removeValue(forKey: meetingId) else { return }
        for file in files {
            do {
                try FileManager.default.removeItem(at: file)
            } catch {
                logger.warning("Failed to cleanup temp file \(file.lastPathComponent): \(error)")
            }
        }
    }
}
```

### Pattern 5: CoreAudio Error Recovery with Property Listeners

**What:** Register `AudioObjectPropertyListenerProc` callbacks on the aggregate device and tap to detect device disconnection, configuration changes, or process termination mid-recording. On detection, attempt graceful recovery (stop + restart with new device) or fail explicitly.

**When to use:** Any CoreAudio integration where the audio source can disappear (process exits, bluetooth disconnects, user changes audio output).

**Trade-offs:** CoreAudio's C API is verbose and error-prone in Swift. The listener callback is a C function pointer, requiring careful memory management. But without it, device disconnection causes silent recording failure.

**Example:**

```swift
final class SystemAudioCapture {
    private var deviceListenerInstalled = false

    func installDeviceListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectAddPropertyListenerBlock(
            aggregateDeviceID,
            &address,
            DispatchQueue.main
        ) { [weak self] _, _ in
            self?.handleDeviceChange()
        }
        if status == noErr {
            deviceListenerInstalled = true
        }
    }

    private func handleDeviceChange() {
        // Check if device is still alive
        var isAlive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(aggregateDeviceID, &address, 0, nil, &size, &isAlive)

        if isAlive == 0 {
            logger.error("Audio device disconnected during recording")
            // Notify coordinator to handle graceful degradation
            onDeviceDisconnected?()
        }
    }
}
```

**Source:** [Core Audio Tap API example](https://gist.github.com/sudara/34f00efad69a7e8ceafa078ea0f76f6f); Apple [Core Audio documentation](https://developer.apple.com/documentation/coreaudio)

## Data Flow

### Recording Lifecycle (Hardened)

```
Detection Service                  Coordinator                     Services
     │                                │                               │
     │  meetingDetected(meeting)       │                               │
     ├───────────────────────────────►│                               │
     │                                │ validate preconditions        │
     │                                │──┐                            │
     │                                │  │ disk space? DB writable?   │
     │                                │◄─┘                            │
     │                                │                               │
     │                                │ reduce: idle → recording      │
     │                                │──┐ (synchronous!)             │
     │                                │◄─┘                            │
     │                                │                               │
     │                                │ DB: INSERT meeting record     │
     │                                ├──────────────────────────────►│ Database
     │                                │ (critical write - must succeed│
     │                                │  or abort recording)          │
     │                                │◄──────────────────────────────┤
     │                                │                               │
     │                                │ start recording               │
     │                                ├──────────────────────────────►│ AudioRecorder
     │                                │                               │
     │  meetingEnded                   │                               │
     ├───────────────────────────────►│                               │
     │                                │ reduce: recording → transcribing
     │                                │──┐ (synchronous!)             │
     │                                │◄─┘                            │
     │                                │                               │
     │                                │ stop recording                │
     │                                ├──────────────────────────────►│ AudioRecorder
     │                                │                               │
     │                                │ DB: UPDATE status=transcribing│
     │                                ├──────────────────────────────►│ Database
     │                                │                               │
     │                                │ enqueue transcription         │
     │                                ├──────────────────────────────►│ Pipeline
     │                                │                               │
     │                                │         transcriptionComplete │
     │                                │◄──────────────────────────────┤ Pipeline
     │                                │                               │
     │                                │ reduce: transcribing → idle   │
     │                                │──┐ (synchronous!)             │
     │                                │◄─┘                            │
```

### Critical Data Flow Rules

1. **DB record MUST exist before recording starts.** If the INSERT fails, abort. The current codebase logs the error and records anyway, resulting in orphaned audio files with no DB entry.

2. **Transcript write MUST succeed before status=done.** If the DB write fails, keep status=transcribing and preserve WAV file for retry. The current codebase can set status=done with no transcript.

3. **WAV file deletion MUST happen after ALAC compression succeeds AND status=done is committed.** The current ordering is correct in intent but not enforced -- a failure between steps 6 and 7 in the pipeline can leave an inconsistent state.

4. **Temp file cleanup MUST happen after all consumers finish.** The current `defer` pattern is unsafe because it runs even if diarization is still reading the mono file.

### State Management

```
RecordingCoordinator (Actor)          AppState (@Observable, @MainActor)
        │                                    │
        │  state changes                     │
        ├──────────────────────────────────►│ status, meetingTitle,
        │  (via MainActor.run or             │ progress, etc.
        │   @MainActor-isolated publish)     │
        │                                    │
        │                                    │  UI binds via @Observable
        │                                    ├──────────────────────► SwiftUI Views
        │                                    │
        │  user actions (retry, stop)        │
        │◄────────────────────────────────────┤
```

**Current problem:** AppState is both the state machine AND the UI state container. It directly calls `recorder.start()`, `pipeline.enqueue()`, and mutates `status` -- all in a non-actor class with `[weak self]` callbacks. This creates every race condition documented in CONCERNS.md.

**Fix:** Split into Coordinator (actor, owns transitions) and AppState (thin @Observable, publishes to UI). The coordinator is the only thing that can change recording state.

### Key Data Flows

1. **Meeting detection -> recording start:** Detection emits event -> Coordinator validates preconditions -> Coordinator transitions state synchronously -> Coordinator creates DB record (critical write) -> Coordinator starts recorder
2. **Recording stop -> transcription:** Coordinator transitions state -> stops recorder -> updates DB status -> enqueues transcription job
3. **Transcription completion -> done:** Pipeline writes transcript to DB (critical, cancellation-protected write) -> compresses to ALAC -> Pipeline reports success -> Coordinator transitions to idle -> deletes WAV

## Scaling Considerations

This is a single-user desktop app, so traditional web-scale concerns don't apply. The relevant scaling dimensions are:

| Dimension | Current | Stress Point | Mitigation |
|-----------|---------|--------------|------------|
| Meeting frequency | 3-5/day | 15+/day (heavy meeting schedule) | Transcription queue already serial; bound queue depth to 50 |
| Recording duration | 30-60 min | 4+ hours (all-day workshop) | WAV at 16kHz stereo ~230MB/hr; check disk space before start; periodic disk checks during recording |
| Transcript size | ~50KB JSON | ~500KB for 4-hour meeting | SQLite handles this fine; FTS5 index grows but remains fast |
| Concurrent meetings | 1 at a time | Back-to-back with overlap | State machine prevents: recording state must transition through transcribing before next recording. Queue the new meeting or warn user. |
| Database size | 10s of meetings | 1000s over months | GRDB DatabasePool with WAL handles reads/writes concurrently; periodic VACUUM in maintenance window |

### Scaling Priorities

1. **First bottleneck: Disk space.** Each meeting produces a WAV file (230MB/hr) that lives until ALAC compression completes. With back-to-back meetings, temp files accumulate. Fix: pre-recording disk check + periodic check during recording + startup orphan cleanup.
2. **Second bottleneck: Transcription queue depth.** If many meetings end while transcription is running, the queue grows. Fix: Bound to 50, surface queue depth in UI, let user prioritize.

## Anti-Patterns

### Anti-Pattern 1: God Object AppState

**What people do:** Put business logic, state management, service coordination, and UI state all in one `@Observable` class.
**Why it's wrong:** Creates untestable monolith. Race conditions because `@Observable` is not actor-isolated. Impossible to reason about valid state transitions when mutations are scattered across 6+ methods.
**Do this instead:** Thin AppState for UI binding only. Actor-based Coordinator owns all business logic and state transitions. AppState subscribes to Coordinator state changes.

### Anti-Pattern 2: `defer` for Shared Resource Cleanup

**What people do:** Use `defer { try? FileManager.removeItem(at: tempFile) }` to clean up temp files in a multi-step pipeline.
**Why it's wrong:** `defer` runs when the scope exits, including on error/cancellation. If a later step is still reading the file, it gets deleted from under it. Also, `try?` silences the cleanup failure.
**Do this instead:** Explicit cleanup after all consumers complete. Track active temp files per job. Log cleanup failures.

### Anti-Pattern 3: Passing Database Per-Call

**What people do:** Pass `database: AppDatabase?` as a parameter to each pipeline call, storing it in queue tuples.
**Why it's wrong:** The database reference can become stale if AppState replaces it. Optional chaining means all DB operations silently no-op if nil. Creates a "maybe we have a database, maybe we don't" ambiguity.
**Do this instead:** Inject database once at Pipeline initialization. Make it non-optional. If the database doesn't exist, the pipeline can't be created -- fail fast.

### Anti-Pattern 4: Silent Fallback Without Notification

**What people do:** If system audio capture fails, silently fall back to mic-only recording. Log a warning but don't tell the user.
**Why it's wrong:** User thinks they have full stereo recording. Discovers hours later that system audio is missing. Violates the core value of "reliable capture."
**Do this instead:** Track capture mode (stereo vs mic-only) in the Meeting record. Surface it in UI. Let user decide whether mic-only recording is acceptable.

### Anti-Pattern 5: `try?` as Error Handling Strategy

**What people do:** Use `try?` throughout the codebase (14 instances) to suppress errors without logging.
**Why it's wrong:** Makes failures invisible. Disk fills up with orphaned temp files. Regex patterns silently fail to compile. Transcript JSON fails to decode with no diagnostic info.
**Do this instead:** `do { try ... } catch { logger.warning("Context: \(error)") }` for every single instance. If the error is truly ignorable, document why in a comment.

## Integration Points

### Internal Boundaries

| Boundary | Communication | Notes |
|----------|---------------|-------|
| Detection -> Coordinator | AsyncStream or callback | Detection runs on RunLoop timers (3s polling). Coordinator is an actor. Bridge via `Task { await coordinator.handle(.meetingDetected(meeting)) }` |
| Coordinator -> Recording | Direct method calls | AudioRecorder is synchronous (start/stop). Called from within coordinator's side effect execution. |
| Coordinator -> Pipeline | Actor-to-actor async call | `await pipeline.enqueue(meetingId:)`. Pipeline reports back via completion callback or the coordinator polls the DB. |
| Pipeline -> Database | GRDB async write | Critical writes wrapped in unstructured Task to survive cancellation. Use `db.dbWriter.write {}` for transaction safety. |
| Coordinator -> AppState | @MainActor publish | Coordinator publishes state changes to AppState on MainActor for UI binding. Use `await MainActor.run { appState.status = .recording }` |
| UI -> Coordinator | Method calls via AppState | User actions (retry, stop) go through AppState which forwards to Coordinator. |

### External Dependencies

| Dependency | Integration Pattern | Hardening Notes |
|------------|---------------------|-----------------|
| CoreAudio (Tap API) | C function calls via AudioToolbox | Install property listeners for device disconnection. Validate OSStatus on every call. Clean up aggregate device + tap on stop. Handle process exit between detection and recording start. |
| GRDB 7.10 | DatabasePool with WAL mode | Use `write {}` for transactional updates. Wrap critical writes in unstructured Task. Never pass database as optional parameter to pipeline. |
| FluidAudio 0.12.4 | ASREngine + DiarizationEngine wrappers | Initialize once, reuse. Handle model loading failures at startup (already done). Catch inference errors per-meeting, don't crash the pipeline. |
| FileManager | Standard Foundation file I/O | Check disk space before recording. Create directories with `withIntermediateDirectories: true`. Clean orphaned temp files on startup. Log all cleanup failures. |

## Build Order (Dependency Implications for Roadmap)

The architectural changes have a natural dependency order:

1. **Fix test infrastructure first.** Everything else needs tests to verify correctness. Can't validate state machine transitions or error handling without running tests.

2. **Extract RecordingCoordinator with state machine.** This is the foundation -- every other fix (precondition checks, error handling, retry logic) needs a place to live. The coordinator centralizes all lifecycle logic that's currently scattered across AppState.

3. **Harden database writes.** Make database non-optional in Pipeline. Protect critical writes from cancellation. Make meeting record creation a gate for recording start. This must come before pipeline cleanup because the pipeline depends on reliable DB state.

4. **Fix temp file lifecycle.** Replace `defer` cleanup with explicit lifecycle tracking. Add orphaned file cleanup on startup. This depends on the coordinator existing (to coordinate when cleanup is safe).

5. **Add CoreAudio error recovery.** Install property listeners. Handle device disconnection. Surface mic-only fallback to user. This is independent of other fixes but benefits from the coordinator pattern (device errors become events the coordinator handles).

6. **Replace all `try?` with proper error handling.** Mechanical but important. Can be done incrementally alongside other work. Each replacement is a small PR.

7. **Add precondition checks.** Disk space, pipeline readiness, DB writability. These plug into the coordinator's transition validation. Depends on coordinator existing.

## Sources

- [Swift actor isolation and reentrancy](https://www.donnywals.com/actor-reentrancy-in-swift-explained/) - Donny Wals (HIGH confidence)
- [WWDC21: Protect mutable state with Swift actors](https://developer.apple.com/videos/play/wwdc2021/10133/) - Apple (HIGH confidence)
- [WWDC23: Beyond the basics of structured concurrency](https://developer.apple.com/videos/play/wwdc2023/10170/) - Apple (HIGH confidence)
- [Swift 6.2 concurrency changes](https://www.swift.org/blog/swift-6.2-released/) - Swift.org (HIGH confidence)
- [GRDB.swift repository](https://github.com/groue/GRDB.swift) - Task cancellation behavior in GRDB 7 (HIGH confidence)
- [GRDB concurrency documentation](https://swiftpackageindex.com/groue/GRDB.swift/master/documentation/grdb/swiftconcurrency) (HIGH confidence)
- [Core Audio Tap API example (macOS 14.2)](https://gist.github.com/sudara/34f00efad69a7e8ceafa078ea0f76f6f) (MEDIUM confidence - community example)
- [LINE Engineering: Robust state machine with Swift Concurrency](https://techblog.lycorp.co.jp/en/20250117a) (MEDIUM confidence - production usage at scale)
- [Task cancellation and lifetimes](https://tanaschita.com/swift-async-tasks-cancellation/) (MEDIUM confidence)
- [Swift state machines with enums](https://www.splinter.com.au/2019/04/10/swift-state-machines-with-enums/) (MEDIUM confidence)

---
*Architecture research for: macOS on-device audio recording + ML transcription pipeline hardening*
*Researched: 2026-03-22*

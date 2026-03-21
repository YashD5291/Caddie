# Coding Conventions

**Analysis Date:** 2026-03-22

## Naming Patterns

**Files:**
- **View files:** `*View.swift` (e.g., `ContentView.swift`, `MeetingDetailView.swift`)
- **Engine classes:** `*Engine.swift` (e.g., `ASREngine.swift`, `DiarizationEngine.swift`)
- **Manager classes:** `*Manager.swift` (e.g., `ModelManager.swift`)
- **Monitor classes:** `*Monitor.swift` (e.g., `AudioProcessMonitor.swift`, `MicStateMonitor.swift`)
- **Utility enums:** Descriptive name ending with noun (e.g., `Formatters.swift`, `Permissions.swift`, `AudioFileManager.swift`)
- **Tests:** `*Tests.swift` (e.g., `FormattersTests.swift`, `MeetingModelTests.swift`)

**Functions:**
- **Private helper functions:** Prefixed with underscore is NOT used; instead use `private` keyword with descriptive names
- **Static utility methods:** Grouped in enums or as static functions on types (e.g., `Formatters.duration()`, `AudioFileManager.wavPath()`)
- **Initialization methods:** `initialize()` for setting up complex state
- **Async methods:** Use `async throws` pattern explicitly (e.g., `func transcribe(audioURL:) async throws`)
- **Event handlers:** Prefixed with verb (e.g., `startRecording()`, `stopRecording()`)
- **Callback properties:** Named with `on` prefix (e.g., `onMeetingStarted`, `onSignal`)

**Variables:**
- **Instance properties:** camelCase (e.g., `isRecording`, `currentMeetingId`, `recordingDuration`)
- **Private properties:** `private(set)` for read-only public access with internal write (e.g., `private(set) var database: AppDatabase?`)
- **Static constants:** camelCase starting with `Self.` prefix in private context (e.g., `Self.flushThreshold`, `Self.sampleRate`)
- **Enum cases:** lowercase (e.g., `case idle`, `case recording`, `case done`)

**Types:**
- **Enum cases:** Snake_case or UPPERCASE for constants (e.g., `case .recording`, `"SPEAKER_00"` format)
- **Error enums:** Always conform to `Error & LocalizedError` (e.g., `ASRError`, `DiarizationError`)
- **Observable types:** Use `@Observable` macro from Observation framework (e.g., `@Observable final class AppState`)
- **Final classes:** Always mark classes as `final` unless inheritance is required (e.g., `final class AppState`, `final class AudioRecorder`)
- **Struct vs class:** Use structs for immutable data models (e.g., `Meeting`, `ASRSegment`), classes for mutable state managers

## Code Style

**Formatting:**
- **Indentation:** 4 spaces (Swift standard)
- **Line length:** Pragmatic; lines extend beyond 80 chars for readability when necessary
- **Braces:** Opening brace on same line (Java/Kotlin style)
- **Blank lines:** Single blank line between methods and logical sections

**Linting:**
- No SwiftLint or formatting tool enforced; style is enforced through code review
- Standard Swift conventions are followed (Apple Swift Style Guide)

## Import Organization

**Order:**
1. Framework imports (SwiftUI, Foundation, AppKit, etc.)
2. Third-party package imports (GRDB, SimplyCoreAudio, AXSwift, Sparkle, FluidAudio)
3. Module-internal types are never explicitly imported

**Path Aliases:**
- No path aliases used; all relative imports use direct module references

**Example from `AudioRecorder.swift`:**
```swift
import AudioToolbox
import Foundation
import os
```

**Example from `AppState.swift`:**
```swift
import SwiftUI
import Observation
import os
```

## Error Handling

**Patterns:**
- **Error types:** Custom error enums inheriting from `Error & LocalizedError` with `errorDescription` property
- **Error propagation:** Use `throws` and `async throws` for propagating errors up the call stack
- **Error catching:** Specific error type matching in `catch` blocks (not generic catch-all)
- **Graceful degradation:** When partial failure is acceptable, log and continue (e.g., `AudioRecorder` logs system audio capture failure but continues with microphone-only recording)
- **Database errors:** Wrapped and logged; database connection errors are fatal to operation

**Example from `ASREngine.swift`:**
```swift
enum ASRError: Error, LocalizedError {
    case notInitialized
    case modelNotLoaded
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInitialized: return "ASR engine not initialized"
        case .modelNotLoaded: return "ASR model not loaded"
        case .transcriptionFailed(let msg): return "Transcription failed: \(msg)"
        }
    }
}
```

**Example error handling in `AppState.swift`:**
```swift
do {
    database = try AppDatabase()
    try AudioFileManager.ensureDirectoryExists()
    // ...
} catch {
    initError = error.localizedDescription
    logger.error("Failed to initialize: \(error.localizedDescription)")
}
```

## Logging

**Framework:** OS Log (`import os`)

**Logger pattern:** Each module/class creates a local logger instance with subsystem and category
```swift
private let logger = Logger(subsystem: "com.caddie.app", category: "AudioRecorder")
```

**Centralized logger access:** `CaddieLogger` enum provides pre-configured loggers by domain
```swift
enum CaddieLogger {
    static let app = Logger(subsystem: subsystem, category: "App")
    static let recording = Logger(subsystem: subsystem, category: "Recording")
    static let transcription = Logger(subsystem: subsystem, category: "Transcription")
}
```

**Patterns:**
- `logger.info()` for significant state changes (e.g., "Recording started for meeting \(meetingId)")
- `logger.error()` for recoverable errors with context
- `logger.warning()` for unexpected but non-fatal conditions
- Log messages include context variables (meeting IDs, counts, durations)
- Async operations log completion and timing (e.g., "Pipeline complete in 45.3s")

## Comments

**When to Comment:**
- Complex algorithms with non-obvious logic (e.g., token grouping in `ASREngine`)
- Workarounds and platform-specific behavior (e.g., screen recording permission detection in `Permissions`)
- Section headers using `// MARK: - SectionName` convention
- Public API documentation (doc comments on public functions)

**JSDoc/TSDoc:**
- Not used; Swift relies on inline code clarity and function signatures
- Function documentation is sparse; code is self-documenting

**Example from `AudioRecorder.swift`:**
```swift
/// Start recording system audio and microphone to a stereo WAV file.
/// - Parameters:
///   - outputPath: URL for the output WAV file.
///   - processID: If provided, capture system audio from this process only.
func start(outputPath: URL, processID: pid_t?) throws {
```

## Function Design

**Size:**
- Short to medium functions (15-40 lines typical)
- Longer functions only when they represent a single logical step with complex state management
- Complex flows broken into named private helper methods

**Parameters:**
- Explicit parameter names always used (no positional arguments without labels)
- Optional parameters placed at end
- Related parameters grouped together (e.g., `outputPath`, `processID` together)

**Return Values:**
- Async functions return via tuple when multiple values needed (e.g., `(segments: [ASRSegment], language: String, duration: Double)`)
- Void returns when side effects are the goal (state updates, file writes)
- Optional returns only when absence of value is meaningful, not for error cases (errors thrown instead)

**Example from `AudioFileManager.swift`:**
```swift
@discardableResult
static func compressToALAC(wavURL: URL, outputURL: URL) throws -> URL {
    // ...
}
```

## Module Design

**Exports:**
- Public APIs are explicit; only what's needed for external use is public
- Internal integration types marked `@testable` for testing access
- Actors used for concurrency boundaries (e.g., `actor TranscriptionPipeline`)

**Barrel Files:**
- Not used; each file exports a single main type
- Flat file organization within module directories

**MARK sections:**
- Used to organize code within files: `// MARK: - Lifecycle`, `// MARK: - Private`, `// MARK: - Errors`
- Standard pattern for readability

---

*Convention analysis: 2026-03-22*

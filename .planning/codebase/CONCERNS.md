# Codebase Concerns

**Analysis Date:** 2026-03-22

## Force Unwraps — Directory Access

**URLs for Application Support Directory:**
- Issue: Four locations use `.first!` to access the application support directory without null checking. If the filesystem returns no application support URLs (extremely rare but possible), the app will crash immediately.
- Files:
  - `Sources/Storage/Database.swift:12`
  - `Sources/Storage/AudioFileManager.swift:10`
  - `Sources/UI/Settings/SettingsView.swift:102`
- Impact: Crash during initialization or when user attempts to delete data in Settings
- Fix approach: Replace `.first!` with `.first ?? fallback` or throw a descriptive error. Example:
  ```swift
  guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
      throw InitializationError.appSupportDirectoryUnavailable
  }
  ```

**Array Index Force Unwrap:**
- Issue: `Sources/UI/MainWindow/MeetingListView.swift:64` uses `grouped[date]!` after filtering, but if the dictionary key doesn't exist, it crashes.
- Files: `Sources/UI/MainWindow/MeetingListView.swift:64`
- Impact: Potential crash when viewing meeting list if grouping logic has a bug
- Fix approach: Use optional chaining or provide a default value: `grouped[date] ?? []`

## Silent Error Suppression with `try?`

**Undiagnosed Cleanup Failures:**
- Issue: 14 instances of `try?` silently suppress errors without logging, making it impossible to diagnose failures:
  - File cleanup: `Sources/Transcription/TranscriptionPipeline.swift:56`, line 112
  - Directory enumeration: `Sources/Storage/AudioFileManager.swift:224`, 245
  - File deletion: `Sources/Storage/AudioFileManager.swift:238-239`
  - Settings cleanup: `Sources/UI/Settings/SettingsView.swift:109`
  - JSON decoding: `Sources/UI/MainWindow/MeetingDetailView.swift:197`, `ExportSheet.swift:73`
  - Regex compilation: `Sources/Detection/MeetingPatterns.swift:23`
  - Logger directory creation: `Sources/Utilities/Logger.swift:19`
- Impact: When temp files fail to delete or regex patterns fail to compile, there's no diagnostic information. This can lead to disk space accumulation (monoURL and wavURL files in temp) and silent meeting app pattern matching failures.
- Fix approach: Replace `try?` with `do-catch` blocks that log warnings/errors:
  ```swift
  do {
      try FileManager.default.removeItem(at: monoURL)
  } catch {
      logger.warning("Failed to cleanup mono file: \(error.localizedDescription)")
  }
  ```

## Temporary File Cleanup Timing Risk

**Mono Mixdown File Deletion:**
- Issue: In `Sources/Transcription/TranscriptionPipeline.swift:56`, the mono file is deleted in a `defer` block, but if the pipeline is cancelled or crashes during ASR/diarization, the file might be deleted while still in use.
- Files: `Sources/Transcription/TranscriptionPipeline.swift:54-57`
- Impact: If a transcription pipeline is cancelled between diarization start and file cleanup, the `defer` block will delete the monoURL while the diarization engine might still be processing it. This can cause hard-to-debug crashes in the audio processing code.
- Fix approach: Use explicit cleanup after both ASR and diarization complete, not in defer. Track whether the file is still in use before deletion:
  ```swift
  // After both ASR and diarization complete successfully
  try? FileManager.default.removeItem(at: monoURL)
  ```

**Stereo WAV File Deletion After Status Update:**
- Issue: Line 112 in `Sources/Transcription/TranscriptionPipeline.swift` deletes the stereo WAV file after writing the compressed ALAC and updating status. The comment says "AFTER status is .done so retry is still possible on failure" but `defer` cleanup of monoURL already deleted it at line 56 if status is error.
- Files: `Sources/Transcription/TranscriptionPipeline.swift:111-113`
- Impact: If compression fails, the status is set to `.error` but the stereo WAV has already been processed. On retry, the WAV file might be partially compressed or cleaned up prematurely.
- Fix approach: Only delete WAV file after ALAC compression succeeds, and ensure it's not deleted if status is being set to error.

## Initialization Race Condition

**AppState Async Initialization with UI Dependencies:**
- Issue: `Sources/App/AppState.swift:43-88` initializes ML engines asynchronously without blocking. The pipeline is created at line 71 but can be `nil` when `stopRecording()` is called from a meeting detection signal if initialization hasn't completed.
- Files: `Sources/App/AppState.swift:43-88`, lines 207-212 in `stopRecording()`
- Impact: If a meeting ends before AppState finishes initializing (during onboarding or slow model downloads), the check `guard let pipeline = pipeline else` will log an error and the transcription job will be silently dropped.
- Fix approach: Use `MainActor` to ensure UI updates don't race with initialization, or wait for pipeline to be ready before processing meetings. Consider:
  ```swift
  @MainActor
  private var pipelineReady: Bool { pipeline != nil }
  ```

## Missing Database Persistence for Initial Records

**Meeting Record Creation Failure Silently Continues:**
- Issue: `Sources/App/AppState.swift:159-168` creates a meeting record in the database when recording starts. If this insert fails (disk full, permission issue), the error is logged but recording continues with no database entry.
- Files: `Sources/App/AppState.swift:159-168`
- Impact: Recording proceeds but the meeting won't appear in the database. On transcription completion, `updateMeetingStatus` will fail silently because the meeting ID doesn't exist in the database, and the transcript will be written to a non-existent record.
- Fix approach: Make database write failures critical. Stop recording and notify the user if the meeting record can't be created.

## Weak Self Capture in Closure Callbacks

**Potential Nil Access in Signal Handlers:**
- Issue: Many closures use `[weak self]` but then access `self` without checking nil. Examples:
  - `Sources/Detection/MeetingDetector.swift:46-49` — signal handlers
  - `Sources/Detection/CalendarMonitor.swift:31-36`, `53-55` — calendar permission callbacks
  - `Sources/Detection/AudioProcessMonitor.swift:17` — timer callback
  - `Sources/App/AppState.swift:74-79` — meeting lifecycle callbacks
- Files: Multiple locations as listed above
- Impact: If the object is deallocated while a callback is in flight, the optional `self` becomes nil and the callback silently does nothing. This can cause meetings to be detected but recording not to start, or meetings to end but transcription not to enqueue.
- Fix approach: Use explicit nil-coalescing where appropriate, or wrap in `guard let self = self else { return }`:
  ```swift
  detector.onMeetingStarted = { [weak self] meeting in
      guard let self = self else { return }
      self.startRecording(meeting: meeting)
  }
  ```

## Calendar Access Blocking on Main Thread

**EventKit Request Callbacks:**
- Issue: `Sources/Detection/CalendarMonitor.swift:29-39` calls `eventStore.requestFullAccessToEvents` with a completion handler. The callback calls `DispatchQueue.main.async` (line 53) which is correct, but the initial permission dialog blocks user interaction.
- Files: `Sources/Detection/CalendarMonitor.swift:29-39`, 53
- Impact: If calendar access is denied or the user takes time to respond, the main thread might appear unresponsive while waiting for the system dialog. This is acceptable UX but should be documented.
- Fix approach: Already handled correctly with `DispatchQueue.main.async`. Consider adding a timeout or user-facing indicator.

## Unvalidated Process ID Translation

**CoreAudio PID Translation Without Timeout:**
- Issue: `Sources/Recording/SystemAudioCapture.swift:114-139` translates a process ID to an AudioObjectID. If the process has exited or the ID is invalid, the translation fails and throws an error, but there's no retry mechanism or timeout.
- Files: `Sources/Recording/SystemAudioCapture.swift:87`, `114-139`
- Impact: If a meeting app process ID becomes invalid between detection and recording start, system audio capture will fail with a generic OSStatus error. The user will only have microphone audio.
- Fix approach: Add validation before translation, or implement graceful fallback to all-system-audio mode if process-specific capture fails (already attempted in AudioRecorder at line 62-64).

## No Validation of Meeting Detection Signals

**Missing Overlap/Conflict Detection:**
- Issue: `Sources/Detection/MeetingDetector.swift:71-100` processes signals but doesn't validate that the detected app/title combination makes sense. If two incompatible meeting signals fire simultaneously (e.g., calendar event for "Team Sync" but Zoom shows "Demo"), the detector picks one and ignores the other.
- Files: `Sources/Detection/MeetingDetector.swift:71-100`
- Impact: If multiple monitoring sources detect different meetings, the recording will capture the wrong meeting or miss a meeting transition.
- Fix approach: Add a conflict resolution strategy — log ambiguous detections and let the user see what was detected.

## Regex Compilation Failures Silent

**Meeting Pattern Initialization:**
- Issue: `Sources/Detection/MeetingPatterns.swift:22-24` compiles regex patterns with `try?`, silently dropping invalid patterns. If a pattern is malformed, the meeting app won't be detected.
- Files: `Sources/Detection/MeetingPatterns.swift:22-24`
- Impact: If a titlePattern contains an invalid regex, that meeting app's title pattern matching will be skipped without warning. This particularly affects "Google Meet" which has a complex pattern.
- Fix approach: Validate all patterns at app startup:
  ```swift
  for pattern in titlePatterns {
      if try? NSRegularExpression(pattern: pattern, options: []) == nil {
          logger.error("Invalid regex pattern: \(pattern)")
      }
  }
  ```

## Transcription Pipeline Queue Unbounded

**No Queue Depth Limit:**
- Issue: `Sources/Transcription/TranscriptionPipeline.swift:13` uses an unbounded array `queue: [(meetingId: String, database: AppDatabase?)] = []`. If many meetings end in rapid succession during batch imports, the queue grows without limit.
- Files: `Sources/Transcription/TranscriptionPipeline.swift:13`, 22-28`
- Impact: If a user has a high meeting load, the queue could grow very large, consuming memory. There's no maximum queue depth or priority system.
- Fix approach: Add a queue depth limit or implement priority-based processing:
  ```swift
  private static let maxQueueDepth = 100
  guard queue.count < maxQueueDepth else {
      logger.warning("Transcription queue full, dropping meeting \(meetingId)")
      return
  }
  ```

## Audio Recorder Fallback Doesn't Validate Success

**System Audio Capture Optional Failure:**
- Issue: `Sources/Recording/AudioRecorder.swift:57-65` starts system audio capture in a try-catch, logs a warning if it fails, and continues with microphone-only recording. There's no state tracking of whether system audio actually started.
- Files: `Sources/Recording/AudioRecorder.swift:57-65`
- Impact: Users won't know that system audio capture failed. They'll think they have stereo audio (system + mic) but only have microphone audio. The quality will be degraded compared to expected.
- Fix approach: Track whether system audio is active and expose this in UI:
  ```swift
  private var systemAudioActive = false
  // In start():
  systemAudioActive = false
  do {
      try systemCapture.start(...)
      systemAudioActive = true
  } catch {
      // log and continue
  }
  ```

## Database Write Failures in Pipeline Don't Block Processing

**Transcript Not Persisted But Status Updated:**
- Issue: `Sources/Transcription/TranscriptionPipeline.swift:87-100` writes the transcript JSON to the database. If this write fails (e.g., database is locked or corrupted), the error is caught but processing continues to compression and cleanup. The transcript is lost even though the status is set to `.done`.
- Files: `Sources/Transcription/TranscriptionPipeline.swift:87-100`, 109
- Impact: A transcription completes successfully but isn't saved to the database due to a transient database error. The meeting status is marked as `.done` with no transcript, and the original WAV/mono files are deleted. There's no way to retry.
- Fix approach: Make transcript persistence a critical step. Treat database write failures the same as transcription failures:
  ```swift
  do {
      try db.dbWriter.write { ... }
  } catch {
      throw PipelineError.failedToPersistTranscript(error)
  }
  ```

## No Concurrent Access Control for Pipeline

**Pipeline Actor But Database Shared Reference:**
- Issue: `Sources/Transcription/TranscriptionPipeline.swift` is an actor, but the `database` parameter is passed to `enqueue()` and stored in the queue. If AppState mutates or replaces the database while a job is in flight, concurrent access could cause issues.
- Files: `Sources/Transcription/TranscriptionPipeline.swift:13`, `22-23`, `94`
- Impact: Low probability but high consequence — if the database connection is replaced mid-transcription, the write to update status could use a deallocated or incompatible connection.
- Fix approach: Pass the database connection once at pipeline initialization, not per-job. Or ensure the database is immutable after initialization.

## Temporary Files in System Temp Directory

**No Cleanup of Crashed Mono Files:**
- Issue: `Sources/Storage/AudioFileManager.swift:151-152` creates temp mono mixdown files in `FileManager.default.temporaryDirectory`. If the app crashes between file creation and deletion, these files accumulate indefinitely.
- Files: `Sources/Storage/AudioFileManager.swift:151-152`, `Sources/Transcription/TranscriptionPipeline.swift:56`
- Impact: Over time, `~/.tmp/caddie_mono_*.wav` files will accumulate, consuming disk space. Users won't know where they came from.
- Fix approach: Add an app startup routine to clean orphaned temp files:
  ```swift
  static func cleanupOrphanedTempFiles() {
      let fm = FileManager.default
      let tempDir = fm.temporaryDirectory
      if let files = try? fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil) {
          for file in files where file.lastPathComponent.hasPrefix("caddie_mono_") {
              try? fm.removeItem(at: file)
          }
      }
  }
  ```

## Test Coverage Gaps

**No Tests for Audio Unit Setup/Teardown:**
- Issue: The most complex CoreAudio integration code has no tests. `Sources/Recording/SystemAudioCapture.swift` (431 lines) and `AudioFileManager.swift` (267 lines) have no corresponding test files for the audio codec and device setup logic.
- Files: `Sources/Recording/SystemAudioCapture.swift`, `Sources/Storage/AudioFileManager.swift`
- Impact: Audio capture bugs are only caught at runtime. Edge cases like missing permissions, invalid device IDs, or malformed audio formats cause crashes in production.
- Fix approach: Add unit tests for:
  - Audio format configuration
  - Aggregate device creation/destruction
  - Process ID translation
  - Mono mixdown averaging
  - ALAC compression

**No Tests for Database Migrations:**
- Issue: The database schema is migrated at app startup, but there are no tests verifying that migrations run correctly or that the schema is valid.
- Files: `Sources/Storage/Database.swift`, database migration code
- Impact: If a future migration is added incorrectly, existing user databases could become corrupted or unreadable.
- Fix approach: Add migration tests that verify the schema before and after each migration.

**Partial Test Coverage for Transcription Pipeline:**
- Issue: `Tests/` contains test files but `TranscriptionPipeline` is an actor with complex async sequencing. Only basic enqueue logic is tested; error handling paths are not exercised.
- Files: `Sources/Transcription/TranscriptionPipeline.swift`
- Impact: Bugs in error recovery (e.g., failed compression doesn't prevent WAV deletion) are untested.
- Fix approach: Add tests for:
  - Pipeline failure recovery
  - Queued job ordering
  - Status update failures
  - Concurrent job enqueueing

## No Disk Space Checks Before Recording

**Recording Can Start with Full Disk:**
- Issue: `Sources/App/AppState.swift:137-177` and `Sources/Recording/AudioRecorder.swift:39-73` start recording without checking available disk space.
- Files: `Sources/App/AppState.swift:137-177`, `Sources/Recording/AudioRecorder.swift:39-73`
- Impact: Recording can start and fail mid-way through if disk fills up. Users won't be warned upfront.
- Fix approach: Check available disk space before starting recording and warn if below a threshold (e.g., 500MB):
  ```swift
  let availableSpace = FileManager.default.availableStorageSpace()
  guard availableSpace > 500 * 1024 * 1024 else {
      throw RecordingError.insufficientDiskSpace(availableSpace)
  }
  ```

## No Timeout for Model Download

**Long-Running Initialization:**
- Issue: `Sources/App/AppState.swift:50` calls `await modelManager.downloadModelsIfNeeded()` with no timeout. If the download stalls, the app appears frozen during onboarding.
- Files: `Sources/App/AppState.swift:50`
- Impact: Users see a frozen onboarding screen if their internet is slow or the download server is unresponsive. No visual indication of progress is provided.
- Fix approach: Add a timeout and periodic progress updates to the UI:
  ```swift
  try await withTimeoutSeconds(300) {
      await modelManager.downloadModelsIfNeeded()
  }
  ```

## TranscriptionPipeline Database Parameter None in UI Retry

**Retry Transcription May Lose Database Connection:**
- Issue: `Sources/App/AppState.swift:90-124` calls `pipeline.enqueue(meetingId:, database: db)` but in `retryTranscription`, the database is passed at line 123 after the function checks for WAV existence. If the database connection was closed between the original transcription error and the retry attempt, the retry will have a stale reference.
- Files: `Sources/App/AppState.swift:90-124`, specifically line 123
- Impact: Retry transcription may fail silently if the database connection is no longer valid.
- Fix approach: Always refresh the database reference at retry time:
  ```swift
  guard let db = database ?? AppDatabase() else {
      logger.error("Cannot retry — database unavailable")
      return
  }
  ```

---

*Concerns audit: 2026-03-22*

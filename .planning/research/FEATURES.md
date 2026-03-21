# Feature Landscape

**Domain:** macOS meeting recorder reliability and error handling hardening
**Researched:** 2026-03-22

## Table Stakes

Features users expect. Missing = product feels incomplete or users lose data.

These are non-negotiable for a meeting recorder whose core value is "every meeting must be reliably captured." Any failure here means a user trusts Caddie, goes into a meeting, and comes out with nothing.

### Data Integrity

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| Critical DB write gating | DB insert failure during `startRecording` must abort recording, not continue silently. A recording with no DB record produces an orphaned audio file and a transcript write to a nonexistent row. | Low | Currently recording proceeds even when DB insert fails (CONCERNS.md). Make DB record creation a precondition. |
| Transcript persistence as blocking step | If the DB write after transcription fails, the transcript is lost forever because source WAV/mono files get deleted downstream. Pipeline must treat DB write failure as a pipeline failure and preserve source files. | Medium | TranscriptionPipeline.swift lines 87-100 write transcript, but lines 104-112 delete source files regardless of write success. Restructure to: write DB -> only then compress -> only then delete WAV. |
| Safe temp file lifecycle | `defer` block deletes mono file while diarization may still be reading it. Crash between creation and cleanup leaves orphaned files. | Medium | Two fixes: (1) explicit cleanup after both ASR and diarization complete (not `defer`), (2) startup sweep of `caddie_mono_*` files in temp directory. |
| Orphaned temp file cleanup on startup | Crashed sessions leave `caddie_mono_*.wav` files in system temp forever. Over time this silently consumes disk. | Low | Add `AudioFileManager.cleanupOrphanedTempFiles()` call in AppState init. Pattern: delete files matching `caddie_mono_` prefix older than 1 hour. |
| Crash-safe recording format | WAV files are not crash-safe -- if the app crashes mid-recording, the WAV header may be invalid and the entire recording is lost. WAV requires a valid header with final file size written at close. | Medium | OBS uses MKV (container that does not need finalization) and auto-remuxes after. For audio-only, consider periodic header updates or writing to a crash-tolerant container format. Alternatively, write raw PCM and finalize WAV on `stop()` -- if crash occurs, raw PCM can be recovered. |

### Error Recovery

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| Retry transcription with valid state | Retry button exists in UI but `retryTranscription` may use a stale database reference. Retry must refresh DB connection and verify WAV file exists before re-enqueuing. | Low | AppState.swift line 123 passes potentially stale DB ref. |
| Bounded transcription queue | Unbounded queue can grow without limit if many meetings end during batch scenarios. | Low | Add `maxQueueDepth` constant (e.g., 50). Log warning and reject when full. |
| Idempotent pipeline processing | If a meeting is retried or double-enqueued, the pipeline must not corrupt state. Check if meeting is already `.transcribing` or `.done` before starting. | Low | Guard at pipeline entry: skip if status is already `.transcribing` or `.done`. |
| Eliminate force unwraps on directory access | Four `.first!` calls on `applicationSupportDirectory` will crash the app if the filesystem returns empty (rare, but fatal). | Low | Replace with `guard let ... else { throw }` pattern. Already specified in CONCERNS.md. |
| Replace silent `try?` with logged `do-catch` | 14 instances of `try?` suppress errors without logging. Makes diagnosing production failures impossible. | Low | Systematic replacement. Each `try?` becomes `do { try ... } catch { logger.warning/error(...) }`. |
| Fix weak self nil access in signal handlers | Meeting detection callbacks silently do nothing if `self` is deallocated. This means a meeting starts but recording does not, or a meeting ends but transcription is never enqueued. | Low | Add `guard let self = self else { return }` to all closure callbacks in MeetingDetector, CalendarMonitor, AudioProcessMonitor, AppState. |

### User Feedback

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| Disk space check before recording | Recording on a full disk fails mid-way with no warning. Loom blocks recording below 2GB free and warns below 16GB (with SCK). For audio-only recording, a 500MB minimum is reasonable. | Low | Check `FileManager.default.attributesOfFileSystem` for free space. Block recording and show alert if below threshold. |
| System audio capture status indicator | System audio capture silently falls back to mic-only. User thinks they have stereo but only has mic audio. This is the #1 complaint pattern in macOS recorder apps. | Medium | Track `systemAudioActive` boolean in AudioRecorder. Surface in menu bar: "Recording (mic only)" vs "Recording (system + mic)". Show a one-time notification when fallback occurs. |
| Transcription progress in UI | Menu bar shows "Transcribing..." with no progress or ETA. For a 1-hour meeting, transcription can take 5-15 minutes. Users wonder if it is frozen. | Medium | Expose pipeline step as observable state: "Creating mixdown...", "Transcribing audio...", "Identifying speakers...", "Compressing...". Show in menu bar and MeetingDetailView. |
| Recording duration in menu bar | Already partially implemented -- MenuBarView shows duration. Verify it updates live with a timer. | Low | Currently uses `appState.recordingDuration`. Ensure this is a published property updated by a Timer. |

### Testing Infrastructure

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| Fix test target linker error | Tests cannot execute at all due to yyjson (C dep of FluidAudio) failing to link with code coverage. Zero test coverage is unacceptable for a reliability milestone. | High | Root cause: yyjson is a C library that does not link properly when code coverage instrumentation is enabled. Options: (1) disable coverage for the FluidAudio module, (2) create a separate test target that excludes FluidAudio, (3) use protocol-based DI to mock ML engines so tests never import FluidAudio directly. Option 3 is best -- it also enables testing the pipeline without real ML models. |
| Protocol-based dependency injection for ML engines | ASREngine and DiarizationEngine are concrete types. Tests cannot substitute mock implementations. | Medium | Define `ASREngineProtocol` and `DiarizationEngineProtocol`. TranscriptionPipeline takes protocols. Test target provides mock implementations that return canned results. This also breaks the FluidAudio linker dependency in tests. |
| Database migration tests | No tests verify schema migrations. A bad migration corrupts every user's database on update. | Medium | Create test that applies migrations sequentially on an in-memory GRDB database. Verify schema after each migration. GRDB's `DatabaseQueue(configuration:)` supports in-memory databases. |
| Pipeline error path tests | Only basic enqueue logic is tested. Error recovery, failed compression, concurrent enqueue, status update failures are all untested. | Medium | Use mock ASR/diarization engines that throw specific errors. Verify pipeline sets correct status, preserves source files on failure, processes queue correctly after errors. |

## Differentiators

Features that set the product apart. Not expected by default, but significantly improve trust and reliability perception.

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| Recording health dashboard in settings | Show recording history with success/failure stats, disk usage trend, orphaned file count. Builds trust that the app is working correctly. Most recorders only show individual meeting status -- a health overview is rare. | Medium | Query DB for meeting count by status. Calculate audio storage size. Show in SettingsView. |
| Proactive disk space monitoring during recording | Check disk space periodically (every 60s) while recording. If space drops below threshold, show notification and stop recording gracefully (finalize WAV) rather than crashing. Loom does this; most local-first recorders do not. | Medium | Timer during recording that checks available space. On low space: (1) finalize current WAV, (2) show UNUserNotification, (3) set meeting to error state with descriptive message. |
| Recording session state persistence | If Caddie crashes or macOS kills it during recording, on next launch detect the incomplete session and offer to recover the audio. QuickTime stores autosave data in `~/Library/Containers/.../Autosave Information/`. | High | Write recording state (meetingId, wav path, start time) to a plist/UserDefaults. On launch, check for incomplete sessions. If WAV exists and has data, offer recovery. If WAV is corrupt, clean up and notify user. |
| Structured error logging to file | Current logging uses `os.Logger` which is great for Console.app but hard for users to share when reporting bugs. Write errors to a structured log file that can be attached to bug reports. | Medium | Already have `CaddieLogger.showLogs()` pointing to `~/Library/Logs/Caddie/`. Add a file handler that writes errors and warnings there. Include session ID, timestamps, pipeline step. |
| Automatic retry with exponential backoff | When transcription fails due to transient errors (temporary memory pressure, disk I/O timeout), auto-retry with 30s, 60s, 120s backoff up to 3 attempts before marking as permanent failure. | Medium | Track retry count in meeting record (add `retryCount` column). Pipeline checks retry count before processing. Exponential delay between retries. After max retries, set status to `.error` with "Failed after 3 attempts" message. |
| Meeting detection conflict resolution | When multiple monitors fire conflicting signals (calendar says "Team Sync" but Zoom shows "Demo"), show user what was detected and let them pick. Most recorders just pick one and ignore conflicts. | High | Requires refactoring MeetingDetector to expose multiple candidate signals. UI to show "Multiple meetings detected" with picker. Defer to later milestone if scope is too large. |
| Notification on recording start/stop | Send macOS notification when recording auto-starts ("Recording: Team Standup on Zoom") and when transcription completes ("Transcript ready: Team Standup"). User knows the app is working without checking menu bar. | Low | Use `UNUserNotificationCenter`. Request notification permission during onboarding. Send local notifications at recording start, recording stop, transcription complete, and transcription error. |

## Anti-Features

Features to explicitly NOT build during this hardening milestone.

| Anti-Feature | Why Avoid | What to Do Instead |
|--------------|-----------|-------------------|
| AI summaries / action items | Hardening first, features later. Adding ML-powered summarization while the base pipeline has data loss bugs creates compound failure modes. The core value is reliable capture, not smart analysis. | Fix every data integrity issue first. Summaries are a future milestone. |
| Cloud sync or backup | Core value is local-only, privacy-first. Adding sync introduces network failure modes, auth complexity, and privacy concerns that contradict the product identity. | Ensure local data integrity is bulletproof. Users can manually export. |
| Real-time transcription | Streaming ASR during recording is architecturally different from post-recording batch transcription. It requires a completely different pipeline, different memory management, and introduces latency/accuracy tradeoffs. | Keep batch pipeline. Improve progress feedback so users know transcription is happening post-meeting. |
| Custom recording format (MKV/fragmented MP4) | While crash-safe containers are ideal, changing the recording format is a large architectural change that touches every part of the pipeline (recording, mixdown, compression, playback). Risk of introducing new bugs exceeds benefit at this stage. | Instead: write recording state to disk for crash recovery, and add periodic WAV header updates as a smaller safety measure. |
| Multi-language transcription UI | The ASR engine already detects language. Building language selection UI, per-language model management, and translation features is feature scope, not hardening. | Keep auto-detection. Log detected language. Surface language in transcript metadata (already done). |
| Fancy retry UI with progress bars per attempt | Over-engineering the retry UX. A simple "Retry" button with a toast notification on success/failure is sufficient. | Keep the existing retry button in MeetingDetailView. Add a toast/notification on retry outcome. |
| Accessibility audit / VoiceOver support | Important but orthogonal to reliability hardening. Mixing accessibility work with error handling work creates unfocused milestones. | Defer to a dedicated accessibility milestone. |

## Feature Dependencies

```
Fix test target linker error
  |
  v
Protocol-based DI for ML engines
  |
  +---> Pipeline error path tests
  |
  +---> Database migration tests
  |
  v
(All error handling features can now be TDD'd)
  |
  +---> Replace silent try? with do-catch
  |
  +---> Eliminate force unwraps
  |
  +---> Fix weak self captures
  |
  +---> Critical DB write gating
  |       |
  |       v
  |     Transcript persistence as blocking step
  |       |
  |       v
  |     Safe temp file lifecycle
  |       |
  |       v
  |     Orphaned temp file cleanup
  |
  +---> Disk space check before recording
  |       |
  |       v
  |     Proactive disk monitoring during recording (differentiator)
  |
  +---> System audio capture status indicator
  |
  +---> Transcription progress in UI
  |
  +---> Bounded transcription queue
  |       |
  |       v
  |     Idempotent pipeline processing
  |       |
  |       v
  |     Automatic retry with backoff (differentiator)
  |
  +---> Recording session state persistence (differentiator)
  |
  +---> Notification on recording start/stop (differentiator)
```

Key dependency insight: **Everything gates on fixing the test target.** The test linker error is the single biggest blocker. Protocol-based DI for ML engines solves both the linker issue and enables proper testing of the entire pipeline.

## MVP Recommendation

Prioritize (in order):

1. **Fix test target** -- nothing else can be verified without this. Protocol-based DI for ML engines is the right approach because it also enables pipeline testing.
2. **Critical DB write gating + transcript persistence** -- these prevent data loss, which is the highest-severity class of bug.
3. **Replace silent `try?` + force unwraps + weak self** -- these are systematic, low-complexity fixes that eliminate entire categories of crashes and silent failures.
4. **Safe temp file lifecycle + orphaned cleanup** -- prevents disk space leaks and crash-during-transcription data loss.
5. **System audio capture status indicator + disk space check** -- highest-value user feedback features. Users must know when they only have mic audio.
6. **Transcription progress in UI** -- reduces "is it frozen?" support burden.

Defer:
- **Recording session state persistence**: High complexity, and most users will not experience crashes. Do after the pipeline itself is hardened.
- **Meeting detection conflict resolution**: High complexity, edge case. Defer to a future milestone.
- **Automatic retry with backoff**: Medium complexity but depends on pipeline being reliable first. After pipeline hardening, most failures will be non-transient anyway.
- **Recording health dashboard**: Nice-to-have, low urgency. Build after reliability metrics exist.

## Sources

- [Loom: Low Disk Space Error Handling](https://support.atlassian.com/loom/kb/seeing-a-low-on-disk-space-or-cannot-start-recording-error) -- disk space thresholds: 16GB warning (SCK), 2GB hard block (SCK), 1GB hard block (no SCK)
- [Loom: Performance and Reliability](https://www.loom.com/blog/performance-and-reliability-2023) -- 99%+ recording success rate, 80%+ auto-recovery of failed processing
- [Otter.ai: Troubleshooting Notetaker](https://help.otter.ai/hc/en-us/articles/14149727495831-Troubleshooting-Notetaker) -- 5-minute timeout, 4 retry attempts, 12-minute silence detection
- [Fireflies.ai: Troubleshooting](https://guide.fireflies.ai/articles/5736968288-troubleshooting-transcription-issues) -- processing delays for long meetings, network checks
- [OBS: Auto-Remux Feature](https://github.com/obsproject/obs-studio/issues/6903) -- MKV recording + auto-remux pattern for crash safety
- [SQLite: How to Corrupt a Database](https://sqlite.org/howtocorrupt.html) -- WAL file management, corruption prevention
- [GRDB: Write Failures in Sandboxed Apps](https://github.com/groue/GRDB.swift/issues/450) -- journal file creation failures in macOS sandboxed apps
- [AssemblyAI: Retry Best Practices](https://www.assemblyai.com/blog/customer-issues-retrying-requests) -- exponential backoff for transcription APIs
- [Screencastify: Low Disk Space](https://learn.screencastify.com/hc/en-us/articles/360049990913-I-received-a-Low-Disk-Space-notification) -- auto-pause recording on low disk
- [Apple: UNUserNotificationCenter](https://developer.apple.com/documentation/usernotifications/unusernotificationcenter) -- macOS notification API (replaces deprecated NSUserNotification)

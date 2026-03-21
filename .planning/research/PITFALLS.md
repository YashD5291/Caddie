# Pitfalls Research

**Domain:** macOS native audio recording/ML transcription app hardening
**Researched:** 2026-03-22
**Confidence:** HIGH (verified against codebase + official Apple docs + community reports)

## Critical Pitfalls

### Pitfall 1: NSLock on the Real-Time Audio Thread Causes Priority Inversion

**What goes wrong:**
`AudioRecorder.swift` uses `NSLock` to protect `systemBuffer` and `micBuffer`. The render callback in `SystemAudioCapture` runs on CoreAudio's real-time audio thread. When the render callback delivers samples to `handleSystemAudioBuffer`/`handleMicBuffer`, these methods acquire the same `NSLock`. If the main thread holds the lock (during `stop()` -> `flushBuffers(final: true)`), the real-time audio thread blocks waiting for it. CoreAudio's real-time thread has strict deadline guarantees -- blocking it causes audio glitches, buffer underruns, and in pathological cases the audio subsystem kills the tap.

**Why it happens:**
NSLock seems correct for protecting shared buffers. The subtlety is that CoreAudio render callbacks run on a real-time priority thread where blocking is forbidden. Apple's documentation states render callbacks "should return immediately without blocking on anything." NSLock does not implement priority inheritance (unlike `pthread_mutex` with `PTHREAD_PRIO_INHERIT`), so a lower-priority thread holding the lock starves the real-time thread.

**How to avoid:**
Replace `NSLock` + shared arrays with a lock-free ring buffer (single-producer, single-consumer). The render callback writes into the ring buffer without locks, and a separate drain timer on the main thread reads and flushes to disk. Apple's `TPCircularBuffer` is the canonical pattern. Alternatively, use `os_unfair_lock` which supports priority donation on Apple platforms, but even that is discouraged on real-time threads -- lock-free is the correct solution.

**Warning signs:**
- Audio glitches or dropouts during recording, especially when the UI is busy
- Thread Sanitizer warnings about lock contention between audio and main threads
- Xcode's Thread Performance Checker flagging priority inversion on the audio thread
- Occasional silence gaps in recorded audio

**Phase to address:**
Phase 1 (Test Infrastructure) or Phase 2 (Error Hardening). This is a correctness bug in the recording core. Must be fixed before any other recording work.

---

### Pitfall 2: `Unmanaged.passUnretained(self)` in Render Callback Crashes After Deallocation

**What goes wrong:**
`SystemAudioCapture.swift:287` passes `self` to the render callback as `Unmanaged.passUnretained(self).toOpaque()`. The callback at line 396 does `Unmanaged<SystemAudioCapture>.fromOpaque(inRefCon).takeUnretainedValue()`. If `SystemAudioCapture` is deallocated while the audio unit is still running (race between `deinit` calling `stop()` and a pending render callback), the callback accesses freed memory. This is a use-after-free crash, not a Swift-level optional -- it happens below ARC's visibility.

**Why it happens:**
`passUnretained` is the common pattern for C callbacks because `passRetained` would leak. The assumption is that `stop()` in `deinit` stops the AudioUnit before `self` is deallocated. But CoreAudio's `AudioOutputUnitStop` does not guarantee that all in-flight render callbacks have completed by the time it returns -- there can be one final callback executing concurrently.

**How to avoid:**
Use `Unmanaged.passRetained(self)` in `start()` and `Unmanaged.fromOpaque(refCon).release()` in `stop()` (after `AudioOutputUnitStop`). This ensures `self` stays alive until explicitly released. Alternatively, use a separate context object that outlives the callback lifecycle:
```swift
private class RenderContext {
    var onBuffer: BufferCallback?
    var audioUnit: AudioComponentInstance?
}
```
Pass the context (retained) and nil out its fields in `stop()`.

**Warning signs:**
- EXC_BAD_ACCESS crashes with stack traces in `systemAudioRenderCallback`
- Crashes when rapidly starting/stopping recordings
- Crashes during app shutdown if a recording is active

**Phase to address:**
Phase 2 (Error Hardening). This is a memory safety bug that can crash the app. Must be fixed alongside the NSLock issue since both are in the recording core.

---

### Pitfall 3: Process Tap Invalidation When Meeting App Exits or is Force-Quit

**What goes wrong:**
`SystemAudioCapture` creates a process tap targeting a specific `pid_t`. If the meeting app (Zoom, Teams, etc.) exits, crashes, or is force-quit during recording, the process tap becomes invalid. The aggregate device built on top of it starts delivering silence or errors. CoreAudio does not automatically notify that the tap source has disappeared -- the render callback keeps running but produces zero samples. The recording completes with partial silence, and the user has no indication their audio was lost.

**Why it happens:**
CoreAudio process taps are tied to a running process. When that process terminates, the tap's audio source disappears. There is no built-in notification mechanism for tap invalidation in the `CATapDescription` API. The aggregate device remains valid (it is a device-level construct), but its sub-device (the tap) is gone.

**How to avoid:**
1. Monitor the target process with `NSWorkspace.shared.runningApplications` or `DispatchSource.makeProcessSource` to detect when it exits
2. When the process exits, switch to either all-system-audio capture or mic-only mode
3. Log a warning and surface the fallback state to the UI
4. Register for `kAudioObjectPropertyOwnedObjects` changes on the tap to detect when it becomes invalid

**Warning signs:**
- Recordings that have long stretches of silence on the system audio channel
- Users reporting "it recorded but there's no audio from the other participants"
- The meeting app's process ID changing mid-meeting (some apps restart helper processes)

**Phase to address:**
Phase 2 (Error Hardening) -- recording resilience. This is a significant edge case that directly violates the core value of "reliable capture."

---

### Pitfall 4: Transcript Data Loss from Non-Critical DB Write + Premature File Deletion

**What goes wrong:**
In `TranscriptionPipeline.swift`, the pipeline writes the transcript to the database (step 5, line 93-100), then compresses the WAV to ALAC (step 6), then marks status as `.done` (step 7), then deletes the WAV (step 8). If the database write at step 5 fails (db locked, disk full, schema mismatch), the error is caught in the outer `catch` block, but by that point the `defer` block has already deleted the mono file. The pipeline sets status to `.error`, but the transcript computation is permanently lost -- the original audio is still there, but the expensive ML computation (potentially minutes of processing) must be redone.

Worse: if steps 5-7 succeed but the WAV deletion at step 8 is what fails (impossible since it uses `try?`), that is harmless. But if the DB write at step 5 succeeds partially (write succeeds but the connection drops before commit in WAL mode), the transcript may be silently incomplete.

**Why it happens:**
The pipeline treats database writes as non-blocking operations. The `defer` block at line 54-57 for mono file cleanup runs regardless of which step fails. The sequencing assumes every step either fully succeeds or the outer `catch` handles it cleanly, but file cleanup via `defer` does not respect this.

**How to avoid:**
1. Make the database write a hard gate: if it fails, do NOT proceed to compression or file deletion. Keep all source files for retry.
2. Remove the `defer` block for mono file cleanup. Instead, clean up mono files explicitly only after both the DB write and status update succeed.
3. Verify the written transcript by reading it back before proceeding.
4. Keep the WAV file until the transcript is verified in the database. Only delete it after confirming `.done` status AND transcript presence.

**Warning signs:**
- Meetings with status `.done` but null/empty transcript fields in the database
- Meetings with status `.error` where retry fails because mono file is gone
- Log entries showing "Failed to write transcript" followed by "ALAC compression complete"

**Phase to address:**
Phase 2 (Error Hardening) -- pipeline resilience. This is the most common path to permanent data loss.

---

### Pitfall 5: Actor Reentrancy in TranscriptionPipeline Corrupts Queue State

**What goes wrong:**
`TranscriptionPipeline` is a Swift actor. The `processNext()` method contains multiple `await` points (ASR, diarization, DB writes). At each `await`, the actor can be reentered -- meaning `enqueue()` can run between awaits. The `isProcessing` flag is set to `true` at the start and `false` at the end, but if `enqueue()` is called while `processNext()` is suspended at an `await`, the new job is appended to `queue` correctly (actors serialize access), but the `if !isProcessing` check in `enqueue()` sees `true` and does NOT spawn a new `processNext()` Task. This is actually correct for this specific pattern.

However, the real reentrancy bug is subtle: at line 135, `isProcessing = false` runs, then line 137-139 checks `!queue.isEmpty` and recursively calls `await processNext()`. If between `isProcessing = false` and the `queue.isEmpty` check, another call to `enqueue()` sees `isProcessing == false` and spawns its OWN `processNext()` Task, you get two concurrent pipeline executions -- violating the serial processing guarantee.

**Why it happens:**
Actor reentrancy is a design choice in Swift concurrency to prevent deadlocks. The tradeoff is that state can change across any `await` boundary. The recursive `await processNext()` pattern at line 137-139 creates a window where both the recursive call and a new Task from `enqueue()` can enter `processNext()`.

**How to avoid:**
Use a proper serial queue pattern inside the actor:
```swift
private func processNext() async {
    while !queue.isEmpty {
        isProcessing = true
        let job = queue.removeFirst()
        // ... process job ...
    }
    isProcessing = false
}
```
The `while` loop eliminates the recursive `await processNext()` call, removing the reentrancy window. The actor's serialization guarantees that `enqueue()` and the loop body cannot execute simultaneously.

**Warning signs:**
- Two transcription jobs running concurrently (visible in logs as interleaved pipeline step messages for different meeting IDs)
- Database write conflicts or "database is locked" errors during transcription
- Higher-than-expected memory usage (two ML models active simultaneously)

**Phase to address:**
Phase 2 (Error Hardening). Fix alongside the pipeline data-loss pitfall since both are in `TranscriptionPipeline`.

---

### Pitfall 6: Test Target Linker Failure Blocks All Quality Verification

**What goes wrong:**
The test target fails to link because yyjson (a C dependency of FluidAudio) produces undefined symbols when Xcode's code coverage instrumentation is enabled. The `__llvm_profile_runtime` symbol is missing because the C target is not compiled with `-fprofile-instr-generate` when coverage is on. This blocks all 10 test files from executing, meaning no hardening work can be verified through automated tests.

**Why it happens:**
When Xcode enables code coverage (`-fprofile-instr-generate -fcoverage-mapping`), it expects all linked objects to include profiling symbols. C targets compiled through SPM may not receive these flags, causing the linker to fail with undefined symbol errors. This is a known issue with mixed Swift/C SPM packages under Xcode's coverage instrumentation.

**How to avoid:**
Three options (in order of preference):
1. **Disable code coverage for the test scheme** in Xcode (Edit Scheme > Test > Options > Code Coverage OFF). You can re-enable it later for specific targets.
2. **Add linker flags** in the XcodeGen project spec to link the profiling runtime: `OTHER_LDFLAGS: ["-lclang_rt.profile_osx"]`
3. **Isolate the C dependency**: create a wrapper target that re-exports FluidAudio without exposing yyjson to the test target, or use `@testable import` only on the Swift layer.

**Warning signs:**
- `Undefined symbols for architecture arm64: "___llvm_profile_runtime"` in build logs
- Test navigator shows 0 tests found
- CI/CD pipeline skipping test phase entirely

**Phase to address:**
Phase 1 (Test Infrastructure). This MUST be the very first thing fixed. Nothing else can be verified without working tests.

---

### Pitfall 7: FTS5 Content-Sync Triggers Desync During Concurrent Reads/Writes

**What goes wrong:**
`Migrations.swift` creates FTS5 with `content=meetings` and three sync triggers (INSERT, DELETE, UPDATE). If the app crashes between a meetings table write and the trigger-fired FTS5 update (possible in WAL mode where the write to the meetings table and the trigger's write to FTS5 are part of the same transaction but the crash happens during WAL checkpoint), the FTS5 index becomes inconsistent with the content table. Search results will miss recent meetings or return stale data. The FTS5 `rebuild` command is the only recovery, but nothing in the app detects or triggers this.

**Why it happens:**
FTS5 content-sync tables place the burden of synchronization on the programmer (per SQLite documentation). While triggers handle the common case, crash recovery is not guaranteed -- if the WAL file is corrupted during a checkpoint, the trigger-based sync can lose updates. Additionally, manually executing raw SQL that bypasses triggers (e.g., direct `UPDATE meetings SET transcript = ?` as done in the pipeline) fires the UPDATE trigger correctly, but if the `old.transcript` value is very large (full meeting transcripts can be megabytes), the DELETE+INSERT into FTS5 on every status update is expensive and can cause WAL growth.

**How to avoid:**
1. Add an FTS5 integrity check on app startup: `INSERT INTO meetings_fts(meetings_fts) VALUES('integrity-check')`. If it fails, run `INSERT INTO meetings_fts(meetings_fts) VALUES('rebuild')`.
2. Consider using GRDB's built-in FTS5 support (`db.makeFTS5Pattern`) instead of raw SQL triggers for better integration.
3. Be aware that every `UPDATE meetings` triggers a full FTS5 delete+insert cycle. Minimize updates to rows with large transcript fields, or restructure so the transcript column is not in the FTS5 index (index only title and a summary field).

**Warning signs:**
- Search returns no results for meetings that clearly exist
- Database file growing unexpectedly (WAL file bloat from large FTS5 trigger operations)
- Slow database writes during transcript updates (the FTS5 trigger processes the full transcript text)
- `SQLITE_CORRUPT` errors on FTS5 queries after a crash

**Phase to address:**
Phase 3 (Database Hardening / Data Integrity). Add integrity checks and consider restructuring the FTS5 index to exclude full transcript text.

---

### Pitfall 8: Disk Full Mid-Recording Produces Corrupted WAV with No User Warning

**What goes wrong:**
`AudioRecorder.writeToFile()` calls `ExtAudioFileWrite` and logs an error if it fails, but does not stop recording or notify the user. Recording continues, accumulating samples in memory buffers that can never be flushed to disk. When the recording eventually stops, `ExtAudioFileDispose` is called on a partially-written file. The resulting WAV file has a valid header but truncated data -- it may play partially or be rejected by the transcription pipeline. The user sees the meeting marked as "recorded" with no indication of the problem.

**Why it happens:**
`ExtAudioFileWrite` returns an `OSStatus` error code for disk-full conditions, but the error handling at line 201-203 only logs it. There is no mechanism to propagate the error back to the recording lifecycle (the write happens inside a lock-protected callback chain). The recording continues operating on the assumption that writes succeed.

**How to avoid:**
1. Check available disk space before starting recording (minimum 500MB for a 1-hour meeting at 16kHz stereo 16-bit = ~220MB WAV)
2. Monitor `ExtAudioFileWrite` return values and set an error flag that the main-thread flush loop checks
3. When disk is critically low, stop recording gracefully, save what has been written, and notify the user
4. On app startup, check for WAV files with no corresponding `.done` status and offer recovery

**Warning signs:**
- WAV files that are significantly smaller than expected for the meeting duration
- `ExtAudioFileWrite` errors in logs (OSStatus -34 = `eofErr`, -39 = `dskFulErr`)
- Transcription failures on meetings that "recorded successfully"

**Phase to address:**
Phase 2 (Error Hardening). Add pre-recording disk check and mid-recording monitoring.

---

### Pitfall 9: Weak Self in Meeting Lifecycle Callbacks Silently Drops Events

**What goes wrong:**
`AppState.swift:74-79` sets up meeting lifecycle callbacks with `[weak self]`:
```swift
detector.onMeetingStarted = { [weak self] meeting in
    self?.startRecording(meeting: meeting)
}
```
If `AppState` is deallocated (or temporarily nil due to SwiftUI view lifecycle), the callback fires but `self?` is nil. The meeting detection succeeds, but recording never starts. No error is logged, no UI indication -- the meeting is simply missed. Similarly for `onMeetingEnded`: if `self` is nil, recording continues indefinitely.

**Why it happens:**
`[weak self]` is the standard pattern to avoid retain cycles. But in this architecture, `AppState` is the central coordinator -- if it goes away, the entire app is non-functional. The callbacks silently no-op via optional chaining, which is the opposite of what the core value ("every meeting must be reliably captured") requires.

**How to avoid:**
For lifecycle-critical callbacks, use `[weak self]` with a guard and explicit error logging:
```swift
detector.onMeetingStarted = { [weak self] meeting in
    guard let self else {
        Logger.error("AppState deallocated during meeting detection -- meeting missed")
        return
    }
    self.startRecording(meeting: meeting)
}
```
Better yet: ensure `AppState` outlives the detector. If `AppState` owns `detector`, and `detector` holds a callback referencing `AppState`, use `[unowned self]` (since `AppState` is guaranteed to outlive `detector`). Or restructure to use delegation or `@Observable` pattern instead of closures.

**Warning signs:**
- Meetings detected in logs but no corresponding recording started
- Grace period expiring with no `stopRecording` call
- Orphaned `MeetingDetector` instances in memory profiler

**Phase to address:**
Phase 2 (Error Hardening). Fix weak-self patterns alongside other reliability work.

---

### Pitfall 10: AppState Initialization Race -- Pipeline Nil When Meeting Ends During Init

**What goes wrong:**
`AppState.initialize()` is async and contains multiple `await` points (model download, ASR init, diarization init). The detector is started at line 80, AFTER pipeline creation at line 71. But if `initialize()` is called and a meeting is already in progress (user joins a Zoom call, then opens Caddie), the detector fires immediately. The `startRecording()` call succeeds (it does not require the pipeline), but when the meeting ends, `stopRecording()` at line 207 checks `guard let pipeline = pipeline` and finds it nil because initialization has not completed. The meeting's audio is recorded but never transcribed, and the meeting stays in "transcribing" status forever.

**Why it happens:**
The initialization sequence starts detection before the pipeline is ready. There is no readiness gate between "detection active" and "pipeline available." The model download alone can take minutes on first launch.

**How to avoid:**
1. Do not start the detector until the pipeline is fully initialized
2. Or: queue meetings that end before the pipeline is ready, and process them once initialization completes
3. Add a `pipelineReady` state that `stopRecording` checks, and if not ready, stores the meeting ID for deferred transcription

**Warning signs:**
- Meetings stuck in "transcribing" status indefinitely
- Log entry: "Cannot enqueue transcription -- pipeline not initialized"
- First-launch users who join a meeting before onboarding completes lose their first transcript

**Phase to address:**
Phase 2 (Error Hardening). This is the initialization ordering bug.

---

## Technical Debt Patterns

| Shortcut | Immediate Benefit | Long-term Cost | When Acceptable |
|----------|-------------------|----------------|-----------------|
| `try?` without logging | Avoids writing error handling boilerplate | Impossible to diagnose failures in production; silent data loss | Never in recording/transcription/DB paths. Acceptable only for truly best-effort operations like deleting a temp file that may not exist |
| `defer` for file cleanup | Guarantees cleanup runs | Cleanup runs even when the file is still in use by an async operation. Creates race conditions with concurrent consumers | Never when the file is shared across async boundaries. Use explicit cleanup after all consumers complete |
| Optional database parameter per-job (`database: AppDatabase?`) | Allows pipeline to work without DB in tests | Database reference can become stale between enqueue and processing. Every pipeline step must nil-check. Missing DB means transcripts are computed but never saved | Never in production. Inject database at pipeline init time, not per-job |
| `NSLock` for audio buffer synchronization | Simple API, familiar pattern | Priority inversion on real-time audio thread, potential deadlocks | Never for audio thread synchronization. Use lock-free ring buffers |
| Raw SQL strings in pipeline | Quick to write, no ORM overhead | SQL injection risk (low since values are parameterized), no compile-time validation, migration breakage not caught at compile time | Acceptable for simple queries, but wrap in tested helper methods |

## Integration Gotchas

| Integration | Common Mistake | Correct Approach |
|-------------|----------------|------------------|
| CoreAudio Process Taps (macOS 14.2+) | Assuming the process tap API is stable across macOS versions. macOS 26 changed USB audio device IO Registry entries, breaking device-to-LocationID mapping for some apps | Pin minimum macOS version in `project.yml`. Test on each new macOS release. Do not rely on undocumented HAL properties |
| FluidAudio / yyjson | Treating it as a pure Swift package. yyjson is a C dependency that requires special linker handling for code coverage, and its memory model does not integrate with Swift ARC | Isolate FluidAudio behind a protocol. Mock in tests. Disable coverage for the C target specifically |
| GRDB DatabasePool | Using `dbWriter.write` from the main thread for quick operations. GRDB's `DatabasePool` in WAL mode can block the writer queue if a long-running read snapshot holds a WAL checkpoint | Use `dbWriter.asyncWrite` for all writes from the main thread. Or use `writeWithoutTransaction` for simple single-statement updates |
| macOS Screen & System Audio Permission | Assuming permission is granted once forever. macOS Sequoia added monthly re-prompts for screen recording. Permission can be revoked in System Settings while the app is running | Check permission status before each recording start. Register for permission change notifications. Handle mid-recording permission revocation gracefully |
| EventKit (Calendar Access) | Calling `requestFullAccessToEvents` on the main thread and expecting a synchronous response. The system dialog blocks UI | Always call from a background context. Handle the "undetermined" state explicitly in the UI |

## Performance Traps

| Trap | Symptoms | Prevention | When It Breaks |
|------|----------|------------|----------------|
| FTS5 full-transcript indexing | Slow UPDATE triggers (FTS5 delete+insert on every status change), WAL file bloat | Index only title, app, and a summary field. Keep full transcript in a non-indexed column | Meetings longer than 30 minutes produce transcripts >100KB, making every status update expensive |
| Unbounded transcription queue | Memory pressure from storing many pending jobs, potential OOM if ML models are loaded per-job | Cap queue at 10-20 items. Drop or defer excess jobs with user notification | Back-to-back meetings with no processing gaps (3+ meetings queuing up) |
| Array `removeFirst` in ring-buffer pattern | O(n) array copy on every flush cycle (1600 samples at 16kHz = every 100ms) | Use a circular buffer with head/tail indices, or `Data` with `replaceSubrange` | Long recordings (>1 hour) where cumulative allocation pressure causes GC pauses |
| Full table scan on meetings list | UI lag when loading meeting list as database grows | Add proper indexes (already have date/status). Paginate queries. Use GRDB's `ValueObservation` for incremental updates | After 500+ meetings in the database |
| Mono mixdown creating full copy of audio | Doubles disk usage temporarily (stereo WAV + mono WAV in temp) | Check available space before mixdown. Clean up immediately after both ASR and diarization complete | Recordings >1GB (meetings >2 hours) on machines with limited free space |

## Security Mistakes

| Mistake | Risk | Prevention |
|---------|------|------------|
| Storing audio files with predictable names in Application Support | Any app with file system access can enumerate and read meeting recordings | Use randomized subdirectories or encrypt audio at rest. File-level encryption with a keychain-stored key |
| No validation of meeting titles from window scraping | Meeting titles from Accessibility API could contain malicious content if rendered as HTML/markdown in export | Sanitize all externally-sourced strings before display or export. Use `String` not `AttributedString` for raw titles |
| Database file unencrypted | SQLite database with full meeting transcripts is readable by any process with file access | Consider SQLCipher or GRDB's encryption extension for the database file. At minimum, ensure the app's container is properly sandboxed |
| Model download over HTTP without certificate pinning | MITM attack could replace ML models with adversarial versions | Verify model checksums after download. Use HTTPS with certificate pinning for model server |

## UX Pitfalls

| Pitfall | User Impact | Better Approach |
|---------|-------------|-----------------|
| Silent mic-only fallback when system audio fails | User thinks they have full stereo recording but only has their own voice. Remote participants are inaudible | Show a persistent warning badge in the menu bar: "System audio unavailable -- recording microphone only" |
| No indication of transcription progress | User sees "transcribing" status with no progress bar. For a 1-hour meeting, transcription can take 5-15 minutes. User thinks app is frozen | Show estimated time remaining based on audio duration. Update progress as ASR/diarization complete |
| Permission request at first launch with no explanation | macOS permission dialogs are cryptic. User denies Screen Recording because they do not understand why a "meeting recorder" needs it | Show a pre-permission screen explaining what each permission does and why it is needed. Request permissions one at a time |
| Meetings stuck in "transcribing" or "error" with no recovery path | User has no way to fix a broken meeting except deleting it | Add "Retry Transcription" button (exists but only works if WAV file is preserved). Add "Mark as Failed" to clear stuck states |

## "Looks Done But Isn't" Checklist

- [ ] **Audio Recording:** Verify system audio channel actually contains audio (not silence). A successful recording with silent system channel means the tap failed silently.
- [ ] **Transcription Pipeline:** Verify transcript is in the database AND the meeting status is `.done`. Status can be `.done` with null transcript if the DB write failed but status update succeeded.
- [ ] **ALAC Compression:** Verify the `.m4a` file plays correctly after compression. A zero-byte or truncated ALAC means compression failed but deletion proceeded.
- [ ] **FTS5 Search:** Verify search returns the meeting you just transcribed. FTS5 can be out of sync with the content table after crashes.
- [ ] **Test Infrastructure:** After fixing the linker issue, verify tests actually RUN (not just compile). A green build with 0 tests executed gives false confidence.
- [ ] **Meeting Detection:** Verify detection works for ALL supported apps (Zoom, Teams, Meet, Slack, Discord, Webex, FaceTime). Pattern changes in app updates break detection silently.
- [ ] **Temp File Cleanup:** After a recording+transcription cycle, verify no `caddie_mono_*` files remain in the system temp directory.
- [ ] **Database Migration:** After adding a new migration, test it against a database created by the PREVIOUS version. Fresh installs always work; upgrades are where migrations break.

## Recovery Strategies

| Pitfall | Recovery Cost | Recovery Steps |
|---------|---------------|----------------|
| NSLock priority inversion causing audio glitches | MEDIUM | Replace NSLock with lock-free ring buffer. Requires rewriting buffer management in AudioRecorder but the interface stays the same |
| Unmanaged.passUnretained crash | LOW | Switch to passRetained + explicit release in stop(). Two-line change + verification |
| Process tap invalidation | MEDIUM | Add process monitoring + fallback to all-system-audio. Requires new DispatchSource and UI state |
| Transcript data loss from premature file deletion | MEDIUM | Restructure pipeline step ordering: remove defer, add explicit cleanup gates. Requires careful sequencing |
| Actor reentrancy in pipeline | LOW | Replace recursive `await processNext()` with `while` loop. Small change, big impact |
| Test target linker failure | LOW | Disable code coverage or add linker flag. One-line fix in project config |
| FTS5 desync after crash | LOW | Add integrity check + rebuild on app startup. Self-healing |
| Disk full mid-recording | MEDIUM | Add pre-recording check + mid-recording monitoring. Requires error propagation from write callback |
| Weak self dropping meeting events | LOW | Add guard-let + logging to all lifecycle callbacks. Mechanical fix |
| Initialization race condition | MEDIUM | Reorder init to start detection last, or add deferred queue for pre-pipeline meetings |

## Pitfall-to-Phase Mapping

| Pitfall | Prevention Phase | Verification |
|---------|------------------|--------------|
| Test linker failure (yyjson) | Phase 1: Test Infrastructure | `xcodebuild test` succeeds with >0 tests executed |
| NSLock priority inversion | Phase 2: Recording Hardening | No Thread Performance Checker warnings during recording. Audio playback has no glitches |
| Unmanaged crash on dealloc | Phase 2: Recording Hardening | Stress test: start/stop recording 100 times rapidly with no crashes |
| Process tap invalidation | Phase 2: Recording Hardening | Kill the meeting app mid-recording; verify fallback to system audio and user notification |
| Transcript data loss | Phase 2: Pipeline Hardening | Simulate DB write failure (e.g., read-only DB); verify transcript is preserved for retry |
| Actor reentrancy | Phase 2: Pipeline Hardening | Enqueue 5 jobs rapidly; verify serial processing (no interleaved log entries) |
| Weak self callbacks | Phase 2: Error Hardening | All lifecycle callbacks log when self is nil. Integration test verifies end-to-end flow |
| Init race condition | Phase 2: Error Hardening | Start app with meeting already in progress; verify deferred transcription completes |
| Disk full mid-recording | Phase 2: Error Hardening | Fill disk to <100MB, start recording; verify graceful error and user notification |
| FTS5 desync | Phase 3: Data Integrity | Force-kill app during transcription write; restart; verify search finds the meeting |
| Silent `try?` suppression | Phase 2: Error Hardening (spread across all files) | `grep -r "try?" Sources/` returns 0 results in recording/pipeline/DB code paths |
| FTS5 performance with large transcripts | Phase 3: Data Integrity | Benchmark UPDATE trigger time with 1MB transcript. Must be <100ms |

## Sources

- [Apple: Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps) -- official process tap documentation
- [Why CoreAudio is Hard (Mike Ash)](https://www.mikeash.com/pyblog/why-coreaudio-is-hard.html) -- render callback constraints, real-time thread rules
- [Hacking with Swift: Actor Reentrancy](https://www.hackingwithswift.com/quick-start/concurrency/what-is-actor-reentrancy-and-how-can-it-cause-problems) -- reentrancy semantics and pitfalls
- [Swift Senpai: Actor Reentrancy Problem](https://swiftsenpai.com/swift/actor-reentrancy-problem/) -- detailed reentrancy examples
- [SQLite FTS5 documentation](https://www.sqlite.org/fts5.html) -- content-sync table rules, rebuild command
- [SQLite Forum: FTS5 corruption from triggers](https://sqlite.org/forum/info/da59bf102d7a7951740bd01c4942b1119512a86bfa1b11d4f762056c8eb7fc4e) -- trigger ordering matters
- [GRDB.swift GitHub](https://github.com/groue/GRDB.swift) -- WAL mode, DatabasePool concurrent access patterns
- [Stripe: SPM build fails with undefined __llvm_profile_runtime](https://github.com/stripe/stripe-ios/issues/1651) -- code coverage + C target linker issue
- [Real-time audio programming 101 (Ross Bencina)](http://www.rossbencina.com/code/real-time-audio-programming-101-time-waits-for-nothing) -- lock-free patterns for audio
- [TPCircularBuffer (A Tasty Pixel)](https://atastypixel.com/a-simple-fast-circular-buffer-implementation-for-audio-processing/) -- canonical lock-free ring buffer for CoreAudio
- [Apple Forums: CoreAudio crashes on macOS Sonoma](https://discussions.apple.com/thread/255788454) -- aggregate device issues
- [Apple Support: Screen & System Audio Recording permission](https://support.apple.com/guide/mac-help/control-access-screen-system-audio-recording-mchld6aa7d23/mac) -- permission model for taps
- [Creating files safely in Mac apps (Wade Tregaskis)](https://wadetregaskis.com/creating-temporary-files-safely-in-mac-apps/) -- temp file handling patterns
- [Swift Forums: Realtime threads with Swift](https://forums.swift.org/t/realtime-threads-with-swift/40562) -- Swift memory model incompatibility with real-time audio

---
*Pitfalls research for: macOS native audio/ML app hardening*
*Researched: 2026-03-22*

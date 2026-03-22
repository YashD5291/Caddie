---
phase: 05-pipeline-data-integrity
verified: 2026-03-22T00:00:00Z
status: gaps_found
score: 4/5 truths verified
re_verification: false
gaps:
  - truth: "Pipeline rejects enqueue for meetings already in .transcribing status in DB"
    status: failed
    reason: "DB status check in enqueue() only gates on .done. A meeting actively processing (dequeued from queue array but mid-pipeline) would have status .transcribing in DB but would not be in the queue array, allowing a duplicate enqueue to slip through."
    artifacts:
      - path: "Sources/Transcription/TranscriptionPipeline.swift"
        issue: "Line 85: DB check is `status == .done` only. Missing `|| status == .transcribing` clause per DATA-07 requirement."
    missing:
      - "Add `status == .transcribing` to the DB status check on line 85 in enqueue()"
      - "Add test testRejectsDuplicateEnqueueForTranscribingMeeting (required by plan 05-02, currently absent from TranscriptionPipelineTests.swift)"
human_verification:
  - test: "DB insert failure aborts recording and returns app to usable idle state"
    expected: "When the SQLite DB is full or locked at meeting start, the coordinator logs the error, transitions to .error then .idle, and the menu bar becomes interactive again -- no recording is started"
    why_human: "DATA-01 abort path is wired via state machine but the 'user notification' component is deferred to Phase 8 (UX-03). Programmatic verification only confirms the state machine path; whether the user actually sees a meaningful signal requires UI inspection."
---

# Phase 5: Pipeline Data Integrity Verification Report

**Phase Goal:** No transcript is ever lost due to premature file deletion, failed DB writes, or concurrent processing bugs
**Verified:** 2026-03-22
**Status:** gaps_found
**Re-verification:** No -- initial verification

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | Mono temp file survives until both ASR and diarization finish | VERIFIED | `removeItem(at: monoURL)` at line 145 is explicit, after both `asrEngine.transcribe()` (step 2) and `diarizationEngine.diarize()` (step 3). No `defer` block present. Test `testMonoFileDeletedAfterASRAndDiarization` exists. |
| 2 | If transcript DB write fails, WAV and mono files are preserved | VERIFIED | DB write at step 5 (line 176) is a hard gate inside the `do` block. Catch block (line 205) does not delete any files. Test `testMonoAndWAVPreservedOnDBWriteFailure` exists and drops the `meetings` table to trigger the failure. |
| 3 | WAV is deleted only after ALAC compression succeeds AND transcript is persisted AND status is .done | VERIFIED | `removeItem(at: wavURL)` at line 195 occurs after: DB write (step 5), `compressToALAC` (step 6), `updateMeetingStatus(.done)` (step 7). Test `testWAVDeletedOnlyAfterFullSuccess` and `testWAVPreservedOnALACCompressionFailure` exist. |
| 4 | Orphaned caddie_mono_* temp files are cleaned up on app startup | VERIFIED | `AudioFileManager.cleanupOrphanedTempFiles()` exists at line 278 of AudioFileManager.swift. `AppState.initialize()` calls it at line 46 with `// DATA-05` comment. Tests `testCleanupOrphanedTempFilesRemovesCaddieMonoFiles`, `testCleanupOrphanedTempFilesPreservesNonCaddieFiles`, and `testCleanupOrphanedTempFilesHandlesEmptyTempDir` all exist. |
| 5 | Pipeline rejects enqueue for meetings already in .transcribing or .done status | PARTIAL | `.done` rejection via DB check is implemented and tested. Queue-membership check catches duplicates in the pending queue (covers in-queue `.transcribing`). But a meeting actively being processed (removed from queue, status=.transcribing in DB) is not caught by the DB check (`status == .done` only, line 85). Test for this case (`testRejectsDuplicateEnqueueForTranscribingMeeting`) is absent. |

**Score:** 4/5 truths verified

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `Sources/Transcription/TranscriptionPipeline.swift` | Restructured processNext with safe file lifecycle, PipelineError enum, maxQueueDepth, async enqueue | VERIFIED | All present. `defer` removed. File deletions are gated on success. `PipelineError` with `duplicateEnqueue` and `queueFull`. `maxQueueDepth = 50`. `enqueue()` is async. |
| `Sources/Storage/AudioFileManager.swift` | `cleanupOrphanedTempFiles()` method | VERIFIED | Exists at line 278. Filters by `caddie_mono_` prefix. Logs count. Handles errors per case. |
| `Sources/App/AppState.swift` | Startup cleanup call | VERIFIED | `AudioFileManager.cleanupOrphanedTempFiles()` called in `initialize()` at line 46. |
| `Sources/Coordinator/RecordingCoordinator.swift` | DB insert failure abort path, DATA-06 retry safety | VERIFIED | `executeStartRecording` catch block calls `handle(.recordingFailed(error))` at line 172. DATA-01 comment present. `executeRetryTranscription` uses non-optional `self.database` with WAV existence check. DATA-06 comment present. |
| `Tests/TranscriptionPipelineTests.swift` | Data integrity tests and entry guard tests | PARTIAL | All DATA-02/03/04 tests present. DATA-05 cleanup tests present. DATA-08 queue-full test present. DATA-07 done-rejection test present. Missing: `testRejectsDuplicateEnqueueForTranscribingMeeting`. |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `TranscriptionPipeline.processNext()` | `FileManager.removeItem(at: monoURL)` | Explicit call after ASR+diarization | WIRED | Line 145, inside success path after both steps 2 and 3. No defer. |
| `TranscriptionPipeline.processNext()` | `FileManager.removeItem(at: wavURL)` | Only after status is .done | WIRED | Line 195, after step 7 (`updateMeetingStatus(.done)`). |
| `TranscriptionPipeline.enqueue()` | `AppDatabase.dbWriter.read` | Status check before accepting job | PARTIAL | Checks `.done` only (line 85). Missing `.transcribing` check per DATA-07. |
| `TranscriptionPipeline.enqueue()` | `queue.count` | Bounded check | WIRED | Line 59, `queue.count < Self.maxQueueDepth`. |
| `AppState.initialize()` | `AudioFileManager.cleanupOrphanedTempFiles()` | Direct call during startup | WIRED | Line 46 of AppState.swift. |
| `RecordingCoordinator.executeStartRecording()` | `handle(.recordingFailed(error))` | Catch block on DB insert | WIRED | Line 172. Transitions state machine to .error on insert failure. |

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|-------------|-------------|--------|----------|
| DATA-01 | 05-03 | Recording aborts with user notification if initial DB insert fails | PARTIAL | Abort path is wired (coordinator catch -> recordingFailed -> .error state). "User notification" deferred to Phase 8 (UX-03), documented with comment in RecordingCoordinator.swift line 167-170. Programmatic abort: satisfied. Observable notification: not yet. |
| DATA-02 | 05-01 | Transcript DB write failure preserves source WAV and mono | SATISFIED | Hard gate at step 5. Catch block preserves files. Test `testMonoAndWAVPreservedOnDBWriteFailure` verified. |
| DATA-03 | 05-01 | Mono file deleted only after both ASR and diarization complete | SATISFIED | Explicit `removeItem(at: monoURL)` after step 3. No defer. Test `testMonoFileDeletedAfterASRAndDiarization` verified. |
| DATA-04 | 05-01 | WAV deleted only after ALAC compression succeeds and transcript persisted | SATISFIED | `removeItem(at: wavURL)` after step 7 (.done). Tests verified. |
| DATA-05 | 05-03 | Orphaned caddie_mono_* cleaned on startup | SATISFIED | `cleanupOrphanedTempFiles()` in `AudioFileManager`, called from `AppState.initialize()`. Three tests cover this. |
| DATA-06 | 05-02 | Retry verifies WAV exists and uses fresh DB | SATISFIED | `executeRetryTranscription` checks `fileExists` before enqueue, uses non-optional `self.database`. DATA-06 comment documents the guarantee. |
| DATA-07 | 05-02 | Pipeline rejects duplicate enqueue for .transcribing or .done meetings | BLOCKED | Only `.done` is checked in DB. `.transcribing` via DB is missed (queue-membership check only covers pending jobs, not active jobs). `testRejectsDuplicateEnqueueForTranscribingMeeting` missing. |
| DATA-08 | 05-02 | Transcription queue bounded (max 50 jobs) | SATISFIED | `maxQueueDepth = 50`, check on line 59, warning logged. Test `testRejectsEnqueueWhenQueueFull` present. |

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| `Sources/Transcription/TranscriptionPipeline.swift` | 85 | `status == .done` only -- missing `.transcribing` in DB check | Warning | DATA-07 partially unimplemented: active-processing duplicate not caught |
| `Sources/App/AppState.swift` | 79 | `database!` force-unwrap | Info | Safe in context (database was just assigned on line 44 in same do-block, force-unwrap is immediately after guard-equivalent assignment). Not a data integrity risk. |

No `defer`-based file deletion found. No `try?` on file deletion paths that would silently lose data. No empty catch blocks. File preservation on failure is correctly structured.

### Human Verification Required

#### 1. DATA-01 User Notification Path

**Test:** Start Caddie, then in a separate terminal use `lsof` to find the SQLite DB file and lock it (`flock`), then trigger a meeting detection event.
**Expected:** App logs the DB insert error, returns to idle state, and the menu bar becomes interactive (not stuck in recording state). In Phase 8, a macOS notification should fire.
**Why human:** The programmatic abort is verified; the "user notification" component is explicitly deferred to Phase 8 (UX-03). Whether the state machine properly resets the menu bar UI requires visual inspection of the running app.

### Gaps Summary

One gap blocks full goal achievement:

**DATA-07 is partially implemented.** The requirement states "Pipeline rejects duplicate enqueue for meetings already in .transcribing or .done state." The implementation correctly:
- Rejects a meeting already in the pending queue (catches in-queue transcribing)
- Rejects a meeting with `.done` status in DB

The gap: a meeting that is actively being processed (already dequeued from the queue array but mid-pipeline execution) will have `.transcribing` status in DB. If `enqueue()` is called for that same meeting ID during processing, the queue-membership check passes (it's not in the array) and the DB check passes (it checks `== .done` only, line 85). The meeting would be double-queued.

Fix required: Change line 85 from `status == .done` to `status == .done || status == .transcribing`. Also add the missing test `testRejectsDuplicateEnqueueForTranscribingMeeting`.

DATA-01's user notification component is explicitly deferred to Phase 8 and documented in the code -- this is by design, not a gap in Phase 5's scope.

---

_Verified: 2026-03-22_
_Verifier: Claude (gsd-verifier)_

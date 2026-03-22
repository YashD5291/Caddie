---
phase: 06-error-discipline
plan: 02
subsystem: concurrency-safety
tags: [weak-self, reentrancy, actor-safety, logging]
dependency_graph:
  requires: []
  provides: [guard-let-self-logging, reentrancy-safe-pipeline]
  affects: [Detection, Recording, TranscriptionPipeline, AppState]
tech_stack:
  added: []
  patterns: [task-chaining-for-serial-execution, guard-let-self-with-logging]
key_files:
  created: []
  modified:
    - Sources/Detection/MeetingDetector.swift
    - Sources/Detection/CalendarMonitor.swift
    - Sources/Detection/AudioProcessMonitor.swift
    - Sources/Detection/MicStateMonitor.swift
    - Sources/Detection/WindowTitleMonitor.swift
    - Sources/Recording/AudioRecorder.swift
    - Sources/Transcription/TranscriptionPipeline.swift
    - Sources/App/AppState.swift
    - Tests/TranscriptionPipelineTests.swift
decisions:
  - "Real-time audio callbacks guard without logging (priority inversion risk)"
  - "Task-chaining via processingTask replaces isProcessing flag entirely"
  - "drainQueue() + processJob() replaces recursive processNext()"
  - "CompletionOrderBox with NSLock for thread-safe test verification"
metrics:
  duration: 10min
  completed: "2026-03-22T00:12:00Z"
---

# Phase 06 Plan 02: Weak Self and Reentrancy Fixes Summary

All weak self closures use guard-let-self with logging. TranscriptionPipeline cannot execute two jobs concurrently.

## What Changed

### Task 1: Guard-let-self with logging (ERR-03)
- **MeetingDetector:** 5 guard-let-self (4 signal handler closures + grace timer)
- **CalendarMonitor:** 4 guard-let-self (2 access callbacks + Task + poll timer)
- **AudioProcessMonitor:** 1 guard-let-self (poll timer)
- **MicStateMonitor:** 1 guard-let-self (notification handler)
- **WindowTitleMonitor:** 1 guard-let-self (poll timer)
- **AudioRecorder:** 3 guard-let-self (flush timer with logging, 2 audio capture callbacks without logging)
- **AppState:** Added warning log to existing guard-let-self in onStateChange callback
- Real-time audio callbacks guard without logging to avoid priority inversion

### Task 2: Eliminate actor reentrancy (ERR-04) -- TDD
- **RED:** Added `testConcurrentEnqueueProcessesSequentially` with `CompletionOrderBox` for FIFO order verification
- **GREEN:** Replaced `isProcessing` flag + recursive `processNext()` with `processingTask` Task-chaining
- Each `enqueue()` chains a new Task that awaits the previous before calling `drainQueue()`
- `drainQueue()` processes all queued jobs in a while loop
- `processJob()` handles a single job (no recursion)
- No concurrent execution possible even under actor reentrancy

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed try? in DATA-07 duplicate rejection**
- **Found during:** Task 2 pipeline refactor
- **Issue:** DATA-07 duplicate rejection used `try?` for DB read
- **Fix:** Replaced with do-catch + logging
- **Files modified:** Sources/Transcription/TranscriptionPipeline.swift
- **Commit:** 164a84d

**2. [Rule 3 - Blocking] Reconciled parallel phase changes**
- **Found during:** Full test run
- **Issue:** A parallel phase modified duplicate rejection and coordinator test expectations
- **Fix:** Accepted refined duplicate rejection (queue-based + only reject .done from DB)
- **Files modified:** Sources/Transcription/TranscriptionPipeline.swift, Tests/TranscriptionPipelineTests.swift
- **Commit:** 477b0b2

## Commits

| Task | Commit | Description |
|------|--------|-------------|
| 1 | 8e57bc2 | Add guard-let-self with logging to all weak self closures |
| 2 (RED) | 164a84d | Add failing reentrancy test |
| 2 (GREEN) | e968ac0 | Implement Task-chaining for reentrancy safety |
| 2 (reconcile) | 477b0b2 | Reconcile parallel phase changes |

## Verification Results

- All weak self closures use guard-let-self (no `self?.` without guard)
- `isProcessing` removed from pipeline code (only in doc comments)
- `processingTask` present with 3 references
- `drainQueue` + `processJob` present
- 128/128 tests passing
- Build: SUCCEEDED

## Known Stubs

None.

# Roadmap: Caddie Production Hardening

## Overview

This milestone takes a working-on-the-happy-path macOS meeting recorder and makes it production-solid. The journey starts by unblocking tests (zero execute today), then fixes memory safety bugs on the audio thread, extracts a proper state machine from the god-object AppState, hardens the transcription pipeline against data loss, systematically eliminates every silent error suppression, adds precondition checks, surfaces recording status and progress to the user, and finishes with device resilience. Every phase delivers a verifiable capability that builds toward the core value: every meeting reliably captured, transcribed, and retrievable.

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [x] **Phase 1: Test Target Revival** - Fix linker error and Swift version so tests execute
- [x] **Phase 2: Test Infrastructure** - Protocol-based DI and test coverage for critical paths
- [ ] **Phase 3: Audio Thread Safety** - Lock-free ring buffer and use-after-free fix on real-time thread
- [ ] **Phase 4: Recording Coordinator** - Actor-based state machine replacing god-object AppState
- [ ] **Phase 5: Pipeline Data Integrity** - Eliminate transcript data loss from premature file deletion and failed DB writes
- [ ] **Phase 6: Error Discipline** - Replace all silent error suppression with logged handling
- [ ] **Phase 7: Precondition Guards** - Disk space checks and model download timeout
- [ ] **Phase 8: User Feedback** - Recording status, transcription progress, and notifications in UI
- [ ] **Phase 9: Recording Resilience** - Device disconnection handling and stale resource cleanup

## Phase Details

### Phase 1: Test Target Revival
**Goal**: Tests compile, link, and execute -- the test target is no longer broken
**Depends on**: Nothing (first phase)
**Requirements**: BUILD-01, BUILD-02
**Success Criteria** (what must be TRUE):
  1. `xcodebuild test` completes without linker errors against the Caddie test target
  2. All existing test files (10) compile and their tests execute (pass or fail -- execution is the bar, not green)
  3. Swift version is 6.0+ and strict concurrency checking is enabled
**Plans**: 1 plan

Plans:
- [x] 01-01-PLAN.md -- Update project.yml (Swift 6.0, coverageTargets, strict concurrency) and verify tests execute

### Phase 2: Test Infrastructure
**Goal**: ML engines and database are testable in isolation without hardware or model dependencies
**Depends on**: Phase 1
**Requirements**: BUILD-03, BUILD-04, BUILD-05
**Success Criteria** (what must be TRUE):
  1. Tests run without downloading ML models or requiring FluidAudio at link time
  2. Database migration tests verify schema integrity for both fresh install and upgrade paths
  3. Pipeline error path tests cover at least: enqueue failure, transcription failure, concurrent enqueue rejection, and state transition validation
**Plans**: 3 plans

Plans:
- [x] 02-01-PLAN.md -- Extract ASREngineProtocol/DiarizationEngineProtocol, refactor pipeline to protocols, create mocks, remove FluidAudio from test target
- [x] 02-02-PLAN.md -- Database migration tests (schema, constraints, indexes, FTS5 triggers, idempotency)
- [x] 02-03-PLAN.md -- Pipeline error path tests (ASR/diarization failure, concurrent enqueue, status transitions)

### Phase 3: Audio Thread Safety
**Goal**: The real-time audio render callback cannot crash the app or cause priority inversion
**Depends on**: Phase 1
**Requirements**: REC-01, REC-02
**Success Criteria** (what must be TRUE):
  1. Audio render callback uses a lock-free ring buffer -- no locks of any kind on the real-time thread
  2. SystemAudioCapture render callback does not use Unmanaged.passUnretained of self (no use-after-free risk)
  3. Recording a 30+ minute meeting produces correct audio without glitches caused by priority inversion
**Plans**: 2 plans

Plans:
- [x] 03-01-PLAN.md -- Lock-free SPSC ring buffer + Unmanaged use-after-free fix in SystemAudioCapture
- [x] 03-02-PLAN.md -- Replace NSLock in AudioRecorder with SPSCRingBuffer + flush timer

### Phase 4: Recording Coordinator
**Goal**: Recording lifecycle is managed by a single actor with explicit state machine -- not scattered across AppState
**Depends on**: Phase 2, Phase 3
**Requirements**: REC-03, REC-04
**Success Criteria** (what must be TRUE):
  1. RecordingCoordinator actor owns all state transitions (idle -> recording -> transcribing -> done/error) with no valid transition path that skips a state
  2. Starting a recording while the pipeline is still initializing does not crash or lose the recording (init race eliminated)
  3. AppState is a thin observable wrapper -- it does not contain recording lifecycle logic
  4. State transitions are tested with unit tests covering every valid and invalid transition
**Plans**: 3 plans

Plans:
- [x] 04-01-PLAN.md -- RecordingState enum with pure state machine (TDD: state/event/sideEffect types + exhaustive transition tests)
- [x] 04-02-PLAN.md -- RecordingCoordinator actor + AppState refactor to thin observable wrapper
- [x] 04-03-PLAN.md -- Gap closure: wire pipeline completion callback to coordinator state machine

### Phase 5: Pipeline Data Integrity
**Goal**: No transcript is ever lost due to premature file deletion, failed DB writes, or concurrent processing bugs
**Depends on**: Phase 4
**Requirements**: DATA-01, DATA-02, DATA-03, DATA-04, DATA-05, DATA-06, DATA-07, DATA-08
**Success Criteria** (what must be TRUE):
  1. If the initial DB meeting record insert fails, recording aborts and the user sees a notification (not a silent failure)
  2. If transcript DB write fails, source WAV and mono files are preserved on disk for retry -- never deleted
  3. Mono temp file is deleted only after both ASR and diarization consumers finish (not via defer)
  4. WAV file is deleted only after ALAC compression succeeds AND transcript is persisted to DB
  5. On app startup, orphaned caddie_mono_* temp files from previous sessions are cleaned up
**Plans**: 3 plans

Plans:
- [ ] 05-01-PLAN.md -- Restructure processNext() file lifecycle: remove defer, gate deletion on success (DATA-02, DATA-03, DATA-04)
- [ ] 05-02-PLAN.md -- Pipeline entry guards: duplicate rejection, bounded queue, retry safety (DATA-06, DATA-07, DATA-08)
- [ ] 05-03-PLAN.md -- Orphaned temp file cleanup on startup + DB insert failure verification (DATA-01, DATA-05)

### Phase 6: Error Discipline
**Goal**: Every error in the codebase is explicitly handled and logged -- no silent swallowing
**Depends on**: Phase 4
**Requirements**: ERR-01, ERR-02, ERR-03, ERR-04
**Success Criteria** (what must be TRUE):
  1. Zero `try?` expressions remain in the codebase -- every error is caught and logged via os.Logger
  2. Zero force unwraps on file system directory access -- all replaced with guard-let-else-throw
  3. Every weak self closure in signal handlers logs when self is nil instead of silently returning
  4. TranscriptionPipeline cannot execute two jobs concurrently (actor reentrancy eliminated)
**Plans**: TBD

Plans:
- [ ] 06-01: TBD
- [ ] 06-02: TBD

### Phase 7: Precondition Guards
**Goal**: Recording and onboarding fail fast with clear user feedback instead of failing mid-operation
**Depends on**: Phase 4
**Requirements**: ERR-05, ERR-06
**Success Criteria** (what must be TRUE):
  1. Recording refuses to start and shows an alert if available disk space is below 500MB
  2. Model download during onboarding times out after 5 minutes with a clear error message and retry option
  3. Both precondition failures are recoverable -- user can free space or retry download and proceed
**Plans**: TBD

Plans:
- [ ] 07-01: TBD

### Phase 8: User Feedback
**Goal**: Users always know what Caddie is doing -- recording status, transcription progress, and completion are visible
**Depends on**: Phase 5, Phase 6
**Requirements**: UX-01, UX-02, UX-03, UX-04
**Success Criteria** (what must be TRUE):
  1. Menu bar icon or label distinguishes between "recording system+mic" and "recording mic-only" states
  2. Menu bar shows which transcription step is active (mixdown, transcribing, diarizing, compressing)
  3. macOS notification fires on recording auto-start, transcription complete, and transcription error
  4. When system audio capture fails and falls back to mic-only, user sees a notification explaining the degraded state
**Plans**: TBD

Plans:
- [ ] 08-01: TBD
- [ ] 08-02: TBD

### Phase 9: Recording Resilience
**Goal**: Caddie handles device changes and stale resources gracefully instead of crashing or corrupting
**Depends on**: Phase 4
**Requirements**: REC-05, REC-06
**Success Criteria** (what must be TRUE):
  1. Disconnecting an audio device mid-recording stops the recording gracefully and notifies the user (no crash, no corrupted file)
  2. Stale aggregate device UIDs from previous sessions are cleaned up on app launch
  3. Reconnecting a device after disconnection allows the next meeting to record normally
**Plans**: TBD

Plans:
- [ ] 09-01: TBD
- [ ] 09-02: TBD

## Progress

**Execution Order:**
Phases execute in numeric order. Phases 3, 5, 6, 7, 9 can parallelize where dependencies allow (see dependency graph).

**Dependency Graph:**
```
Phase 1 ──> Phase 2 ──> Phase 4 ──> Phase 5 ──> Phase 8
Phase 1 ──> Phase 3 ──> Phase 4 ──> Phase 6 ──> Phase 8
                         Phase 4 ──> Phase 7
                         Phase 4 ──> Phase 9
```

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Test Target Revival | 1/1 | Complete | 2026-03-22 |
| 2. Test Infrastructure | 3/3 | Complete | 2026-03-22 |
| 3. Audio Thread Safety | 2/2 | Complete | 2026-03-22 |
| 4. Recording Coordinator | 3/3 | Complete | 2026-03-22 |
| 5. Pipeline Data Integrity | 0/3 | Not started | - |
| 6. Error Discipline | 0/TBD | Not started | - |
| 7. Precondition Guards | 0/TBD | Not started | - |
| 8. User Feedback | 0/TBD | Not started | - |
| 9. Recording Resilience | 0/TBD | Not started | - |

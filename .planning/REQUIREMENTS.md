# Requirements: Caddie Production Hardening

**Defined:** 2026-03-22
**Core Value:** Every meeting must be reliably captured, transcribed, and retrievable — no silent failures, no lost recordings, no data corruption.

## v1 Requirements

Requirements for production-solid release. Each maps to roadmap phases.

### Build & Test Infrastructure

- [x] **BUILD-01**: Swift version updated from 5.9 to 6.0+ so GRDB 7.10 and strict concurrency checking are available
- [x] **BUILD-02**: Test target links and all existing tests execute (yyjson/coverage linker error resolved)
- [x] **BUILD-03**: ML engines abstracted behind protocols so tests run without FluidAudio dependency
- [x] **BUILD-04**: Database migration tests verify schema integrity on fresh and upgraded databases
- [x] **BUILD-05**: Pipeline error path tests cover failure recovery, concurrent enqueue, and status transitions

### Recording Core Safety

- [x] **REC-01**: Audio render callback uses lock-free ring buffer instead of NSLock (no priority inversion on real-time thread)
- [x] **REC-02**: SystemAudioCapture render callback safe from use-after-free (no Unmanaged.passUnretained of self)
- [ ] **REC-03**: Recording lifecycle managed by a RecordingCoordinator actor with explicit state machine (idle → recording → transcribing → done/error)
- [ ] **REC-04**: AppState initialization race condition eliminated (pipeline guaranteed ready before meeting lifecycle events fire)
- [ ] **REC-05**: CoreAudio device disconnection detected mid-recording with graceful stop and user notification
- [ ] **REC-06**: Stale aggregate device UIDs cleaned up on app launch

### Data Integrity

- [ ] **DATA-01**: Recording aborts with user notification if initial DB meeting record insert fails
- [ ] **DATA-02**: Transcript DB write failure treated as pipeline failure — source WAV and mono files preserved for retry
- [ ] **DATA-03**: Mono file deleted only after both ASR and diarization complete (no defer-based cleanup)
- [ ] **DATA-04**: WAV file deleted only after ALAC compression succeeds and transcript is persisted
- [ ] **DATA-05**: Orphaned temp files (caddie_mono_*) cleaned up on app startup
- [ ] **DATA-06**: Transcription retry refreshes DB connection and verifies WAV exists before re-enqueuing
- [ ] **DATA-07**: Pipeline rejects duplicate enqueue for meetings already in .transcribing or .done state
- [ ] **DATA-08**: Transcription queue bounded (max 50 jobs) with logged rejection

### Error Handling

- [ ] **ERR-01**: All 14 `try?` instances replaced with `do-catch` blocks that log the error
- [ ] **ERR-02**: All 4 force unwraps on directory access replaced with guard-let-else-throw
- [ ] **ERR-03**: All weak self closures in signal handlers use `guard let self else { return }` with logged fallthrough
- [ ] **ERR-04**: Actor reentrancy in TranscriptionPipeline eliminated (no concurrent job execution)
- [ ] **ERR-05**: Disk space checked before recording starts — recording blocked with alert if below 500MB
- [ ] **ERR-06**: Model download has a timeout (5 min) with progress feedback during onboarding

### User Feedback

- [ ] **UX-01**: Menu bar shows system audio capture status (recording system+mic vs mic-only)
- [ ] **UX-02**: Menu bar shows transcription progress steps (mixdown → transcribing → diarizing → compressing)
- [ ] **UX-03**: macOS notification sent on recording auto-start, transcription complete, and transcription error
- [ ] **UX-04**: User notified when system audio capture fails and falls back to mic-only

## v2 Requirements

Deferred to future release. Tracked but not in current roadmap.

### Resilience

- **RES-01**: Recording session state persisted to disk for crash recovery on next launch
- **RES-02**: Automatic transcription retry with exponential backoff (30s, 60s, 120s, max 3 attempts)
- **RES-03**: Proactive disk space monitoring during recording (periodic checks, graceful stop on low space)
- **RES-04**: Structured error logging to file for user bug reports

### UX Polish

- **UXP-01**: Recording health dashboard in Settings (success/failure stats, disk usage trend)
- **UXP-02**: Meeting detection conflict resolution UI when multiple monitors disagree

## Out of Scope

Explicitly excluded. Documented to prevent scope creep.

| Feature | Reason |
|---------|--------|
| AI summaries / action items | Hardening first — fix data integrity before adding ML features on top |
| Cloud sync or backup | Core value is local-only, privacy-first |
| Real-time transcription | Architecturally different pipeline; out of scope for hardening |
| Custom recording format (MKV) | Large architectural change with regression risk; periodic WAV header updates instead |
| Multi-language transcription UI | Feature scope, not hardening scope |
| Accessibility audit / VoiceOver | Important but orthogonal; defer to dedicated milestone |
| Fancy retry UI with progress bars | Simple retry button + notification is sufficient |

## Traceability

Which phases cover which requirements. Updated during roadmap creation.

| Requirement | Phase | Status |
|-------------|-------|--------|
| BUILD-01 | Phase 1: Test Target Revival | Complete |
| BUILD-02 | Phase 1: Test Target Revival | Complete |
| BUILD-03 | Phase 2: Test Infrastructure | Pending |
| BUILD-04 | Phase 2: Test Infrastructure | Pending |
| BUILD-05 | Phase 2: Test Infrastructure | Pending |
| REC-01 | Phase 3: Audio Thread Safety | Complete |
| REC-02 | Phase 3: Audio Thread Safety | Complete |
| REC-03 | Phase 4: Recording Coordinator | Pending |
| REC-04 | Phase 4: Recording Coordinator | Pending |
| REC-05 | Phase 9: Recording Resilience | Pending |
| REC-06 | Phase 9: Recording Resilience | Pending |
| DATA-01 | Phase 5: Pipeline Data Integrity | Pending |
| DATA-02 | Phase 5: Pipeline Data Integrity | Pending |
| DATA-03 | Phase 5: Pipeline Data Integrity | Pending |
| DATA-04 | Phase 5: Pipeline Data Integrity | Pending |
| DATA-05 | Phase 5: Pipeline Data Integrity | Pending |
| DATA-06 | Phase 5: Pipeline Data Integrity | Pending |
| DATA-07 | Phase 5: Pipeline Data Integrity | Pending |
| DATA-08 | Phase 5: Pipeline Data Integrity | Pending |
| ERR-01 | Phase 6: Error Discipline | Pending |
| ERR-02 | Phase 6: Error Discipline | Pending |
| ERR-03 | Phase 6: Error Discipline | Pending |
| ERR-04 | Phase 6: Error Discipline | Pending |
| ERR-05 | Phase 7: Precondition Guards | Pending |
| ERR-06 | Phase 7: Precondition Guards | Pending |
| UX-01 | Phase 8: User Feedback | Pending |
| UX-02 | Phase 8: User Feedback | Pending |
| UX-03 | Phase 8: User Feedback | Pending |
| UX-04 | Phase 8: User Feedback | Pending |

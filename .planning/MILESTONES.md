# Milestones

## v2.0 Google Calendar + Remote Meeting Recording (Shipped: 2026-07-01)

**Released as:** v1.1.0 → v1.2.1 (notarized DMGs on public GitHub Releases; ML models bundled, zero runtime downloads)

**Tracking note:** Phases 11–13 ran through the GSD phase flow (7 plans). Phases 14–17 (Google auth, calendar sync, calendar-triggered recording, calendar UI) were implemented outside the phase flow on feature branches and merged via PRs #2–#8; their work is captured below and in the milestone audit rather than as phase SUMMARY files.

**Key accomplishments:**

*Audio device pipeline (Phases 11–13):*
- AudioDeviceManager with SimplyCoreAudio enumeration, UserDefaults persistence, fallback validation, and a SwiftUI Settings picker
- HAL AudioUnit device-specific capture (TN2091 order, RenderContext memory safety); device UID routed through AudioRecorder → RecordingCoordinator; mid-recording device hot-swap with rollback
- Manual start/stop recording from the menu bar via new RecordingState events

*Google Calendar + auth (Phases 14–17, shipped v1.1.0):*
- Replaced EventKit with GoogleCalendarService: OAuth (PKCE S256, Keychain-stored tokens, actor-serialized refresh), 5-min event polling, Today's Schedule sidebar
- Calendar-triggered recording via actionable notification (Record/Dismiss) — the prompt fires a configurable lead time before start (CAL-03), one per event, no auto-start
- Single-source mono capture (selected input device or system default)

*Reliability + features (v1.1.x–v1.2.x):*
- Fixed SentencePiece detokenization that fragmented exported transcripts
- Live transcription during recording (streaming ASR, display-only; final diarized transcript unchanged)
- 7 code-review fixes (calendar signal loss, WAV finalization on device-switch failure, RT-thread allocations, error-state surfacing, dead-code removal)

*Release engineering:*
- OAuth secret externalized to a gitignored file; sortformer runtime-download guard (fully self-contained app)
- Sparkle auto-updates: updater controller + Settings/menu-bar controls + EdDSA-signed appcast generated and uploaded per release (live from v1.2.1)

**Requirements:** 13/13 addressed (11 satisfied, 2 satisfied-with-deviation). Audit gaps CAL-02 (PR #3) and CAL-03 (PR #8) both resolved post-audit. See `milestones/v2.0-MILESTONE-AUDIT.md`.

---

## v1.0 Production Hardening (Shipped: 2026-03-24)

**Phases completed:** 10 phases, 22 plans, 35 tasks

**Key accomplishments:**

- Fixed yyjson linker error via selective code coverage, upgraded to Swift 6.0 with complete strict concurrency, and resolved 7 concurrency errors across the codebase -- 49 tests now execute with 0 failures
- Engine protocols with existential types enabling mock injection into TranscriptionPipeline without FluidAudio in tests
- 9 migration integrity tests covering schema columns, UNIQUE constraints, default values, indexes, FTS5 triggers, and idempotency
- 6 TranscriptionPipeline tests covering ASR/diarization failure, missing file, success path with DB writes, sequential processing, and status transitions
- Lock-free SPSC ring buffer with OSMemoryBarrier and retained RenderContext eliminating use-after-free in SystemAudioCapture
- Replaced NSLock + Array buffers with lock-free SPSCRingBuffer and DispatchSourceTimer eliminating priority inversion on real-time audio thread
- Pure synchronous state machine with RecordingState/Event/SideEffect enums and exhaustive reduce function covering 7 valid and 11+ invalid transitions
- Actor-based RecordingCoordinator owning full recording lifecycle with synchronous reduce and async side effects, AppState reduced to thin observable wrapper
- TranscriptionPipeline.enqueue() onComplete callback wired to RecordingCoordinator state machine, closing the transcribing-to-done/error lifecycle gap
- 1. [Rule 1 - Bug] Fixed DATA-03/DATA-04 reintroduced try? in TranscriptionPipeline
- 1. [Rule 1 - Bug] Fixed try? in DATA-07 duplicate rejection
- Disk space guard (500MB) blocks recording pre-start; model download times out at 5min with retry via task group race
- RecordingMode and PipelineStep enums threaded from AudioRecorder/TranscriptionPipeline through RecordingCoordinator to AppState as observable properties
- NotificationManager with 4 notification types, MenuBarView showing recording mode and pipeline step, menu bar icon differentiation for capture modes
- CoreAudio device alive listener detects mid-recording disconnect, propagates through AudioRecorder to RecordingCoordinator for graceful stop and transcription
- Idempotent HuggingFace download script with size validation for all FluidAudio ML models (~711MB), integrated as XcodeGen preBuildScript
- Bundle-based ModelManager using AsrModels.load(from:) with modelsExist() pre-check guard, all download terminology replaced across ModelManager/AppState/OnboardingView
- GitHub Actions cache for ~711MB ML models with stable version-keyed caching and increased timeouts for both release and CI workflows

---

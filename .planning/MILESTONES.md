# Milestones

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

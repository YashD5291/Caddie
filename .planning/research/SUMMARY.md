# Project Research Summary

**Project:** Caddie Production Hardening
**Domain:** macOS native app reliability hardening (CoreAudio recording + on-device ML transcription)
**Researched:** 2026-03-22
**Confidence:** HIGH

## Executive Summary

Caddie is a macOS meeting recorder that auto-detects meetings, captures system + mic audio via CoreAudio process taps, and transcribes with on-device ML (FluidAudio's Parakeet ASR + Sortformer diarization). The core recording and ML pipeline shipped in Phase 1, but the codebase has systemic reliability gaps: 14 silent `try?` error suppressions, a use-after-free risk in the audio render callback, an NSLock on the real-time audio thread causing priority inversion, and a pipeline ordering bug that can permanently delete transcripts before verifying they were saved. The test target is completely broken (zero tests execute) due to a C linker issue with yyjson under code coverage. This is not a feature milestone -- it is a hardening milestone where the goal is making every existing feature reliable.

The recommended approach is to fix the test infrastructure first (unblocking all verification), then extract an actor-based RecordingCoordinator to replace the current god-object AppState, and systematically harden the recording core and transcription pipeline in parallel workstreams. The architecture research strongly recommends a state-machine pattern with synchronous transitions to eliminate the race conditions that pervade the current callback-driven design. The existing project structure (Detection, Recording, Transcription, Storage layers) is sound -- the problem is the lack of a proper coordinator and error handling discipline between layers.

The three highest-risk pitfalls are: (1) transcript data loss from premature file deletion when DB writes fail, (2) the NSLock priority inversion on CoreAudio's real-time thread causing audio glitches, and (3) the Unmanaged.passUnretained use-after-free crash in the render callback. All three are fixable with well-documented patterns (explicit cleanup ordering, lock-free ring buffers, retained context objects). The Swift version must be bumped from 5.9 to 6.0+ because GRDB 7.10.0 requires Swift 6.1, and strict concurrency checking is a core goal.

## Key Findings

### Recommended Stack

The existing stack (Swift/SwiftUI/GRDB/FluidAudio/CoreAudio/SimplyCoreAudio) is correct and stays. No new libraries are needed. The changes are configuration and tooling.

**Core changes:**
- **Swift 6.0+ with strict concurrency (`complete` mode):** Compile-time data race detection. GRDB 7.10.0 requires Swift 6.1+, and the project is stuck on 5.9. This is a blocking upgrade.
- **Swift Testing framework:** Replaces XCTest for new tests. Parallel by default, native async/await, parameterized tests via `@Test` macro.
- **XcodeGen `coverageTargets` fix:** Solves the yyjson linker crash by limiting code coverage instrumentation to the Caddie target only, excluding FluidAudio's C dependencies.
- **`withTaskCancellationHandler` / `withThrowingTaskGroup` timeout:** Pipeline cancellation support and model download timeouts, replacing unbounded awaits.
- **`os.Logger` (keep, fix usage):** Already in use. The problem is 14 `try?` call sites that suppress errors without logging. No new logging library needed.

### Expected Features

**Must have (table stakes):**
- Critical DB write gating -- abort recording if DB insert fails
- Transcript persistence as blocking step -- never delete source files before verifying DB write
- Safe temp file lifecycle -- replace `defer` with explicit post-consumer cleanup
- Orphaned temp file cleanup on startup
- Fix test target linker error (zero tests run today)
- Protocol-based DI for ML engines (breaks FluidAudio test dependency)
- Replace all 14 silent `try?` with logged `do-catch`
- Eliminate 4 force unwraps on directory access
- Fix weak self nil access in lifecycle callbacks
- Disk space check before recording (500MB minimum)
- System audio capture status indicator (mic-only fallback must be visible)
- Transcription progress in UI (step-level feedback)

**Should have (differentiators):**
- Proactive disk space monitoring during recording (periodic checks)
- Recording session state persistence for crash recovery
- Notification on recording start/stop (UNUserNotificationCenter)
- Automatic retry with exponential backoff (3 attempts)
- Structured error logging to file for bug reports

**Defer (v2+):**
- AI summaries / action items
- Cloud sync
- Real-time streaming transcription
- Custom recording format (MKV/fragmented MP4)
- Multi-language transcription UI
- Meeting detection conflict resolution
- Recording health dashboard
- Accessibility audit

### Architecture Approach

The central architectural change is extracting a `RecordingCoordinator` actor from the current god-object `AppState`. The coordinator owns a state machine (idle -> recording -> transcribing -> done/error) with synchronous transitions to prevent actor reentrancy bugs. AppState becomes a thin `@Observable` wrapper that the coordinator publishes to. All precondition checks (disk space, DB writability, pipeline readiness) live in the coordinator's transition validation.

**Major components:**
1. **RecordingCoordinator (Actor)** -- State machine, lifecycle transitions, error policy, precondition gating. Single source of truth for recording state.
2. **TranscriptionPipeline (Actor, refactored)** -- Explicit temp file lifecycle, cancellation-protected DB writes, `while` loop instead of recursive `await processNext()`, non-optional database injection.
3. **RecordingService (refactored AudioRecorder)** -- Lock-free ring buffer replacing NSLock, retained render context replacing Unmanaged.passUnretained, process tap monitoring.
4. **DetectionService (existing)** -- Unchanged structure, but callbacks refactored to go through Coordinator.
5. **AppDatabase (existing)** -- Unchanged, but injected at init (non-optional), with FTS5 integrity checks on startup.

### Critical Pitfalls

1. **NSLock on real-time audio thread** -- Replace with lock-free ring buffer (TPCircularBuffer pattern). NSLock causes priority inversion; CoreAudio can kill the tap. Must fix before any other recording work.
2. **Unmanaged.passUnretained use-after-free** -- Switch to passRetained + explicit release in stop(), or use a separate retained RenderContext object. Two-line fix with high crash-prevention impact.
3. **Transcript data loss from premature file deletion** -- Remove `defer` cleanup. Make DB write a hard gate: if write fails, preserve all source files. Only delete WAV after ALAC succeeds AND status=done is committed.
4. **Actor reentrancy in pipeline queue** -- Replace recursive `await processNext()` with `while !queue.isEmpty` loop. Eliminates the window where two pipeline executions run concurrently.
5. **Test target linker failure (yyjson)** -- Set `coverageTargets: [Caddie]` in XcodeGen to exclude C deps from coverage instrumentation. Protocol-based DI eliminates the test-time FluidAudio import entirely.

## Implications for Roadmap

### Phase 1: Test Infrastructure and Build Fixes
**Rationale:** Everything gates on this. Zero tests execute today. No hardening work can be verified without a functioning test target. The Swift version bump to 6.0+ is also a prerequisite for strict concurrency and GRDB 7.10 compatibility.
**Delivers:** Working test target, Swift Testing framework, protocol-based DI for ML engines, in-memory GRDB test database, initial test suite for pipeline error paths and migrations.
**Addresses:** Fix test target linker error, protocol-based DI, database migration tests, pipeline error path tests.
**Avoids:** Pitfall 6 (test linker failure blocking all verification).
**Stack changes:** Swift version bump to 6.0+, XcodeGen `coverageTargets` config, Swift Testing import.

### Phase 2: Recording Core Hardening
**Rationale:** The recording path has memory safety bugs (use-after-free, priority inversion) that can crash the app or corrupt audio. These must be fixed before adding any error handling logic on top, because the foundation is unsafe.
**Delivers:** Lock-free audio buffer, safe render callback lifecycle, process tap monitoring, device disconnection handling, disk space pre-check.
**Addresses:** NSLock replacement, Unmanaged.passUnretained fix, process tap invalidation handling, disk space check before recording, system audio capture status indicator.
**Avoids:** Pitfalls 1 (priority inversion), 2 (use-after-free), 3 (process tap invalidation), 8 (disk full mid-recording).
**Implements:** RecordingService refactoring from ARCHITECTURE.md.

### Phase 3: Pipeline and State Machine Hardening
**Rationale:** With recording safe and tests working, harden the transcription pipeline and extract the RecordingCoordinator. The pipeline has the transcript data loss bug and the reentrancy issue. The coordinator centralizes all the scattered lifecycle logic from AppState.
**Delivers:** RecordingCoordinator actor with state machine, pipeline with explicit temp file lifecycle, cancellation-protected DB writes, proper queue processing, init race fix, `try?`/force unwrap/weak self cleanup.
**Addresses:** Critical DB write gating, transcript persistence as blocking step, safe temp file lifecycle, orphaned temp file cleanup, actor reentrancy fix, bounded transcription queue, idempotent processing, init race condition, all `try?` replacements, force unwrap elimination, weak self fixes.
**Avoids:** Pitfalls 4 (transcript data loss), 5 (actor reentrancy), 9 (weak self dropping events), 10 (init race condition).
**Implements:** RecordingCoordinator pattern, explicit temp file lifecycle pattern, precondition gating pattern from ARCHITECTURE.md.

### Phase 4: Data Integrity and User Feedback
**Rationale:** With the core pipeline and recording reliable, add the data integrity safeguards (FTS5 health, crash recovery) and user-facing feedback (progress, notifications, proactive disk monitoring).
**Delivers:** FTS5 integrity check on startup, transcription progress in UI, disk space monitoring during recording, notifications on recording start/stop, structured error logging to file.
**Addresses:** FTS5 desync prevention, transcription progress, proactive disk monitoring, notifications, structured logging.
**Avoids:** Pitfall 7 (FTS5 desync after crash).
**Implements:** Differentiator features from FEATURES.md that build on the hardened foundation.

### Phase 5: Resilience and Polish
**Rationale:** Final hardening layer. Recording session persistence for crash recovery, automatic retry with backoff, strict concurrency audit. These depend on everything else being solid.
**Delivers:** Crash recovery for incomplete sessions, automatic retry with exponential backoff, strict concurrency `complete` audit passing clean, macOS permission change handling.
**Addresses:** Recording session state persistence, automatic retry, strict concurrency verification, permission revocation handling.
**Avoids:** Remaining edge cases from PITFALLS.md integration gotchas.

### Phase Ordering Rationale

- **Phase 1 before everything:** Cannot verify any fix without tests. The feature dependency graph in FEATURES.md shows this explicitly -- every other feature gates on test infrastructure.
- **Phase 2 before Phase 3:** Recording core has memory safety bugs (C-level, below ARC). These must be fixed before adding Swift-level error handling on top. Fixing the coordinator while the audio thread can crash is building on sand.
- **Phase 3 is the largest phase:** It bundles the coordinator extraction with pipeline hardening and systematic error handling cleanup. These are tightly coupled -- the coordinator is where precondition checks and error policies live, and the pipeline is where data loss bugs live. Both need to be addressed together for coherent error handling.
- **Phase 4 after Phase 3:** User feedback features (progress, notifications) require the coordinator and pipeline to have stable state and reliable transitions. Showing progress from a pipeline that can lose data is misleading.
- **Phase 5 last:** Crash recovery and retry logic are defense-in-depth. They assume the happy path is already reliable. Building retry before fixing the root causes of failure is backwards.

### Research Flags

Phases likely needing deeper research during planning:
- **Phase 2 (Recording Core):** Lock-free ring buffer implementation is well-documented but requires careful tuning for buffer sizes and drain timing. TPCircularBuffer is canonical but it is a C library -- need to decide between wrapping it or writing a Swift version. CoreAudio property listener registration has subtle lifecycle requirements.
- **Phase 3 (State Machine):** Actor-based state machine is well-documented conceptually, but the specific integration with SwiftUI's `@Observable` and MainActor publishing needs careful design. The LINE Engineering blog post provides a production reference but the Caddie-specific state transitions need mapping.

Phases with standard patterns (skip phase-level research):
- **Phase 1 (Test Infrastructure):** XcodeGen config changes, Swift Testing adoption, and protocol-based DI are all well-documented with established patterns.
- **Phase 4 (User Feedback):** UNUserNotificationCenter, progress state publishing, and disk space APIs are standard Foundation/AppKit patterns with extensive documentation.
- **Phase 5 (Resilience):** Retry with backoff and state persistence are standard patterns. Strict concurrency audit is mechanical.

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | MEDIUM-HIGH | No new libraries needed. Swift version bump is well-understood. The yyjson linker fix has two verified solutions (coverageTargets or linker flags). GRDB 7.10 Swift 6.1 requirement is documented in release notes. |
| Features | HIGH | Feature list derived from direct codebase analysis (CONCERNS.md) + competitive analysis (Loom, Otter.ai, OBS patterns). Table stakes are clearly data integrity and error recovery -- not new features. |
| Architecture | HIGH | Patterns verified against Apple WWDC sessions, GRDB docs, and production usage (LINE Engineering). Actor-based state machine is the canonical Swift solution for this problem. Current codebase anti-patterns (god object, defer cleanup, optional DB) are well-documented. |
| Pitfalls | HIGH | All 10 pitfalls verified against the actual codebase with specific line numbers. Sources include Apple docs, CoreAudio community experts (sudara, Mike Ash), SQLite official docs, and Swift forums. |

**Overall confidence:** HIGH

### Gaps to Address

- **Lock-free ring buffer implementation choice:** TPCircularBuffer (C) vs pure Swift implementation. Need to evaluate whether Swift's memory model (ARC, no guaranteed atomics before Swift 6) is suitable for a real-time audio ring buffer. The Swift Forums thread on realtime threads suggests pure Swift is risky for the render callback itself.
- **Swift 6.0 vs 6.1 target:** GRDB 7.10 requires Swift 6.1 (Xcode 16.3+). Need to verify the team's Xcode version. If stuck on Xcode 16.0-16.2, must pin GRDB to 7.8.0 or upgrade Xcode.
- **FTS5 index restructuring:** Research suggests excluding full transcript text from the FTS5 index (index only title + summary). This requires a migration and changes to the search query. Impact on search quality needs evaluation.
- **macOS permission re-prompt behavior:** macOS Sequoia added monthly re-prompts for screen recording. Need to verify exact behavior and whether the app can detect permission revocation mid-session.

## Sources

### Primary (HIGH confidence)
- [Apple: Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)
- [Apple WWDC21: Protect mutable state with Swift actors](https://developer.apple.com/videos/play/wwdc2021/10133/)
- [Apple WWDC23: Beyond the basics of structured concurrency](https://developer.apple.com/videos/play/wwdc2023/10170/)
- [GRDB.swift GitHub](https://github.com/groue/GRDB.swift) -- v7.10.0 release, migration testing, Swift 6.1 requirement
- [GRDB concurrency documentation](https://swiftpackageindex.com/groue/GRDB.swift/master/documentation/grdb/swiftconcurrency)
- [SQLite FTS5 documentation](https://www.sqlite.org/fts5.html)
- [SQLite: How to Corrupt a Database](https://sqlite.org/howtocorrupt.html)
- [Apple: volumeAvailableCapacityForImportantUsage](https://developer.apple.com/documentation/foundation/urlresourcevalues/volumeavailablecapacityforimportantusage)

### Secondary (MEDIUM confidence)
- [Core Audio Tap reference implementation (sudara)](https://gist.github.com/sudara/34f00efad69a7e8ceafa078ea0f76f6f)
- [LINE Engineering: State machine with Swift Concurrency](https://techblog.lycorp.co.jp/en/20250117a)
- [Why CoreAudio is Hard (Mike Ash)](https://www.mikeash.com/pyblog/why-coreaudio-is-hard.html)
- [TPCircularBuffer (A Tasty Pixel)](https://atastypixel.com/a-simple-fast-circular-buffer-implementation-for-audio-processing/)
- [Real-time audio programming 101 (Ross Bencina)](http://www.rossbencina.com/code/real-time-audio-programming-101-time-waits-for-nothing)
- [Loom: Performance and Reliability](https://www.loom.com/blog/performance-and-reliability-2023)
- [OBS: Auto-Remux Feature](https://github.com/obsproject/obs-studio/issues/6903)
- [Swift 6.2 concurrency changes](https://www.donnywals.com/exploring-concurrency-changes-in-swift-6-2/)
- [Stripe: SPM build fails with undefined __llvm_profile_runtime](https://github.com/stripe/stripe-ios/issues/1651)

### Tertiary (LOWER confidence)
- [Swift Forums: Realtime threads with Swift](https://forums.swift.org/t/realtime-threads-with-swift/40562) -- suggests pure Swift may not be safe for real-time audio callbacks
- [Apple Forums: CoreAudio crashes on macOS Sonoma](https://discussions.apple.com/thread/255788454) -- aggregate device stability across macOS versions

---
*Research completed: 2026-03-22*
*Ready for roadmap: yes*

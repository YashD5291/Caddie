---
phase: 18-screen-capture-engine
plan: 01
subsystem: recording
tags: [screencapturekit, avassetwriter, hevc, swift6-concurrency, tdd, macos]

# Dependency graph
requires:
  - phase: (milestone research v3.0)
    provides: stack + ten pitfalls + Pattern 1 concurrency recommendation
provides:
  - "ScreenRecorder.swift engine surface: QualityPreset enum, ScreenRecorderError enum, State machine + pure transition, pure config/dimension/anchor/frame-status/filter static functions"
  - "Proven Pattern 1 concurrency shape (queue-confined final class + @unchecked Sendable WriterSink) compiling clean under SWIFT_STRICT_CONCURRENCY=complete"
  - "Recorded first-frame recipe (B) + keepalive interval (~2s) for Plan 18-02 to consume"
affects: [18-02-live-capture, 18-03, 18-04, 20-storage, 21-settings-playback]

# Tech tracking
tech-stack:
  added: []  # zero new SPM dependencies — Apple system frameworks only
  patterns:
    - "Queue-confined non-Sendable final class + @unchecked Sendable delegate sink (Pattern 1)"
    - "Pure static functions as the unit-test seam (mirrors SystemAudioCapture.outputCapacity)"
    - "Pure state transition function makes stop() idempotent by construction"

key-files:
  created:
    - Sources/Recording/ScreenRecorder.swift
    - Tests/ScreenRecorderConfigTests.swift
    - Tests/ScreenRecorderStateTests.swift
    - Tests/ScreenRecorderFilterTests.swift
  modified: []

key-decisions:
  - "First-frame recipe B (startSession at first PTS + append raw PTS) — anchor is a single stored scalar, least retiming code"
  - "Static-screen keepalive re-append interval starting value: ~2s (tune against kill-9 static-screen gate in Plan 02)"
  - "WriterSink @unchecked Sendable with writer/input as confined fields; no @preconcurrency/nonisolated seasoning needed"
  - "CMSampleBuffer appended synchronously inside the SCK delegate callback (delivered on writerQueue via sampleHandlerQueue), never captured across a queue hop"

patterns-established:
  - "Pattern 1 concurrency topology: writerQueue-confined final class + @unchecked Sendable sink"
  - "Engine-owned QualityPreset enum with explicit HEVC bitrate caps (no uncapped default)"

requirements-completed: [VID-05, VID-06, STOR-04]

# Metrics
duration: 11min
completed: 2026-07-09
---

# Phase 18 Plan 01: Screen Capture Engine Surface Summary

**Queue-confined `ScreenRecorder` engine surface — QualityPreset (HEVC + explicit bitrate caps), pure config/dimension/anchor/frame-status/filter functions, and a state machine — with Pattern 1 concurrency proven green under complete strict concurrency; no live SCStream capture yet.**

## Performance

- **Duration:** 11 min
- **Started:** 2026-07-09T12:11:38Z
- **Completed:** 2026-07-09T12:22:45Z
- **Tasks:** 3
- **Files modified:** 4 (all created)

## Accomplishments

- **Concurrency spike proven green:** Pattern 1 (queue-confined `final class ScreenRecorder` + `@unchecked Sendable WriterSink` conforming to `SCStreamOutput`/`SCStreamDelegate`, confined to `com.caddie.screenrecorder.writer`) compiles with **zero** concurrency diagnostics under `SWIFT_STRICT_CONCURRENCY=complete` on the local Swift 6.2.3 toolchain — no `@preconcurrency`/`nonisolated` seasoning required. The public engine API was committed only after the spike was green.
- **VID-06 preset math:** `QualityPreset` (compact 10fps/1.5Mbps, balanced 15fps/2.5Mbps default, high 30fps/4Mbps) + `videoSettings` builder emitting `AVVideoCodecType.hevc` with an explicit `AVVideoAverageBitRateKey` equal to the preset cap (kills Pitfall 3), and `targetDimensions` that downscales Retina input to the clamp, preserves aspect, and returns even numbers (kills Pitfall 4).
- **STOR-04 anchor math:** `hostTicksToSeconds` mach-tick → seconds conversion via `mach_timebase_info`, unit-tested against identity and Apple-Silicon (125/3) timebases.
- **State machine + VID-05 filter selection:** pure `transition` (idempotent stop by construction), `frameAction` (append `.complete` only), `excludedBundleIdentifiers`/`selectDisplayID`, and the `ScreenRecorderError` contract for Plan 02.
- **Full suite green:** 304 tests pass (278 baseline + 26 new), `** TEST SUCCEEDED **`.

## Baseline

`make test` was confirmed green **before** any changes: `** TEST SUCCEEDED **`, 278 tests, 0 failures. The CLAUDE.md-flagged FluidAudio/yyjson linker issue did not block the suite (resolved via selective coverage per PROJECT.md). No pre-existing blocker.

## Decisions for Plan 18-02 (recorded per plan output requirement)

- **First-frame recipe: B** — on the first delivered buffer, `startSession(atSourceTime: firstPTS)` and append raw PTS. Movie timeline is host time; the anchor is the session start, stored as a single scalar. Chosen over recipe A because it needs no per-buffer `CMSampleBuffer(copying:withNewTiming:)` retiming — least code, single stored anchor (RESEARCH.md Open Question 2). Either recipe satisfies STOR-04; B is simpler to reason about for the anchor.
- **Static-screen keepalive interval: ~2s** starting value — a low-frequency timer re-appends the cached last complete frame every ~2s so `movieFragmentInterval` keeps flushing on static content. Tune against the kill-9 static-screen gate in Plan 02 so a kill-9 loses ≤ ~10s (RESEARCH.md Open Question 3).
- **Concurrency seasoning needed: none beyond `@unchecked Sendable`.** The `SCStreamOutput`/`SCStreamDelegate` conformance on an `@unchecked Sendable NSObject` compiled clean with no `@preconcurrency` or `nonisolated`. The one real finding: the non-`Sendable` `CMSampleBuffer` must be appended **synchronously inside the delegate callback** (SCK delivers it on `writerQueue` via the `sampleHandlerQueue`) and never captured across a `writerQueue.async {}` hop — capturing it into a `@Sendable` closure warns. Writer/input state lives as confined fields on the sink, not as closure-captured parameters.

## Task Commits

Each task committed atomically:

1. **Task 1: Concurrency spike** — `c9cf007` (feat)
2. **Task 2 (TDD): preset/config/dimension/anchor** — `e25b3d6` (test RED) → `eb61348` (feat GREEN)
3. **Task 3 (TDD): state machine/frame-status/filter selection** — `8d21c26` (test RED) → `de8b881` (feat GREEN)

_No refactor commits needed — implementations were minimal and clean on first GREEN._

## Files Created/Modified

- `Sources/Recording/ScreenRecorder.swift` - Engine surface: `QualityPreset`, `ScreenRecorderError`, `State`/`StateEvent`/`transition`, `FrameAction`/`frameAction`, `videoSettings`, `targetDimensions`, `hostTicksToSeconds`, `excludedBundleIdentifiers`, `selectDisplayID`, plus the queue-confined skeleton (`writerQueue`, `WriterSink @unchecked Sendable`, `@Sendable` callbacks).
- `Tests/ScreenRecorderConfigTests.swift` - 13 tests: preset values, `videoSettings` (HEVC + bitrate cap + dims), `targetDimensions`, `hostTicksToSeconds`.
- `Tests/ScreenRecorderStateTests.swift` - 8 tests: state transitions incl. idempotent stop + frame-status decision.
- `Tests/ScreenRecorderFilterTests.swift` - 5 tests: Caddie exclusion + display selection (VID-05).

## Decisions Made

See "Decisions for Plan 18-02" above (first-frame recipe B, ~2s keepalive, concurrency findings). All preset/bitrate numbers copied verbatim from RESEARCH.md.

## Deviations from Plan

None - plan executed exactly as written. The spike's append-proof was iterated to surface the correct confinement (synchronous append inside the delegate callback rather than a captured async hop), which is the intended purpose of the spike — the finding is recorded above, not a scope change.

## Issues Encountered

- The initial throwaway append-proof captured the non-`Sendable` `AVAssetWriterInput`/`CMSampleBuffer` into a `@Sendable writerQueue.async {}` closure, producing concurrency warnings. Resolved by mirroring the real design: writer/input confined as fields on the `@unchecked Sendable` sink, and the sample buffer appended synchronously inside the SCK delegate callback. This is exactly the invariant the spike existed to prove.

## Known Stubs

The `WriterSink` delegate methods (`didOutputSampleBuffer`, `didStopWithError`) and its `writer`/`videoInput` fields are intentionally empty placeholders — live SCStream capture and AVAssetWriter wiring are explicitly Plan 18-02's scope (this plan proves the concurrency shape and lands pure logic only). Not UI-facing; no data stub reaches any view.

## User Setup Required

None - no external service configuration required. (Screen Recording TCC grant is only needed for live capture / integration, which lands in Plan 18-02.)

## Next Phase Readiness

- Plan 18-02 (live capture) can proceed: the concurrency topology is proven, the engine type surface (presets, error contract, state machine, pure config/anchor/filter functions) is committed, and the first-frame recipe (B) + keepalive interval (~2s) decisions are recorded.
- **Gap to close on the actual floor:** the kill-9 fragment-recovery gate (VID-07) and real-capture integration harness run on the local macOS 26 toolchain as a proxy; they must be re-run on a macOS 14.2 machine before the milestone ships (per RESEARCH.md Environment Availability).

---
*Phase: 18-screen-capture-engine*
*Completed: 2026-07-09*

## Self-Check: PASSED

All 4 created files verified on disk; all 5 task commits verified in git history.

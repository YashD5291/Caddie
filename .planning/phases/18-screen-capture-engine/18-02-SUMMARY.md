---
phase: 18-screen-capture-engine
plan: 02
subsystem: recording
tags: [screencapturekit, avassetwriter, hevc, movie-fragments, swift6-concurrency, macos]

# Dependency graph
requires:
  - phase: 18-01
    provides: "ScreenRecorder engine surface — QualityPreset, ScreenRecorderError, State machine + transition, pure config/dimension/anchor/frame-status/filter functions, Pattern 1 concurrency skeleton"
provides:
  - "Live ScreenRecorder.start(target:preset:outputURL:) / stop() — video-only SCStream -> AVAssetWriter capture on a confined writer queue producing a crash-safe fragmented HEVC .mov"
  - "CaptureTarget (display OR window) capture-target API for Phase 21 Settings"
  - "First-frame host-tick anchor via onFirstFrameHostTime (STOR-04)"
  - "Static-screen keepalive + non-blocking async finalize + didStopWithError playable-partial finalize"
affects: [18-03, 18-04, 19-coordinator, 20-storage, 21-settings-playback]

# Tech tracking
tech-stack:
  added: []  # zero new SPM dependencies — Apple system frameworks only
  patterns:
    - "Filter-derived dimensions: SCContentFilter.contentRect * pointPixelScale -> source pixels, fed once to both stream config and writer (Pitfall 4)"
    - "Recipe B first-frame anchoring: startSession(atSourceTime: firstPTS) + raw-PTS append; anchor = CMClockConvertHostTimeToSystemUnits(firstPTS)"
    - "Static-screen keepalive: DispatchSourceTimer on writerQueue re-appending the cached frame via CMSampleBuffer(copying:withNewTiming:)"
    - "Non-blocking finalize: async finishWriting(completionHandler:) never blocks app quit"

key-files:
  created: []
  modified:
    - Sources/Recording/ScreenRecorder.swift

key-decisions:
  - "CaptureTarget is NOT Sendable — its .window payload (SCWindow) is non-Sendable on the SDK and the enum never crosses an isolation boundary (ScreenRecorder is a non-Sendable class owned within one isolation domain)"
  - "Dimensions derived from SCContentFilter.contentRect * pointPixelScale rather than SCDisplay.width/height — one code path works for both display and window modes and gives true physical pixels"
  - "First frame anchored with recipe B (startSession at first PTS) per 18-01 decision; host-tick anchor is a single scalar from CMClockConvertHostTimeToSystemUnits"
  - "WriterSink keeps its own writerQueue-confined finalize-guard state distinct from ScreenRecorder's owner-domain start guard; both use the pure transition so stop-after-error and double-stop are safe no-ops"
  - "didStopWithError re-dispatches finalize onto writerQueue (SCStreamDelegate callbacks are not guaranteed on the sampleHandlerQueue) to preserve the @unchecked Sendable confinement invariant"

patterns-established:
  - "Filter-first dimension derivation (contentRect * pointPixelScale)"
  - "Dual-state guard (owner-domain start guard + queue-confined finalize guard) for idempotent stop across caller-driven and stream-error paths"

requirements-completed: [VID-05, VID-06, VID-07, STOR-04]

# Metrics
duration: 7min
completed: 2026-07-09
---

# Phase 18 Plan 02: Live Screen Capture Summary

**Live `ScreenRecorder` capture path — a video-only `SCStream` feeding a crash-safe fragmented HEVC `.mov` `AVAssetWriter` on a confined writer queue, with first-frame host-clock anchoring (STOR-04), a ~2s static-screen keepalive, a non-blocking async finalize, and a `didStopWithError` playable-partial finalize; 304 tests green.**

## Performance

- **Duration:** 7 min
- **Started:** 2026-07-09T12:29:52Z
- **Completed:** 2026-07-09T12:37:05Z
- **Tasks:** 2
- **Files modified:** 1 (`Sources/Recording/ScreenRecorder.swift`)

## Accomplishments

- **Live capture wired (Task 1):** `start(target:preset:outputURL:)` resolves an `SCContentFilter` (display mode excludes Caddie's own app via `excludedBundleIdentifiers` → VID-05; window mode via `desktopIndependentWindow`), derives physical-pixel dimensions once from `filter.contentRect * pointPixelScale`, and feeds the SAME `dims` to both the `SCStreamConfiguration` and the writer's `videoSettings` (kills Pitfall 4). The `.mov` writer sets `movieFragmentInterval` BEFORE `startWriting` (VID-07), and the stream registers the `WriterSink` as `SCStreamOutput`/`SCStreamDelegate` with `sampleHandlerQueue: writerQueue`.
- **First-frame anchor (STOR-04):** on the first `.complete` frame the sink calls `startSession(atSourceTime: firstPTS)` (recipe B), captures the host tick via `CMClockConvertHostTimeToSystemUnits(firstPTS)`, and fires `onFirstFrameHostTime` exactly once. Frames are appended only when `.complete`, carry a pixel buffer, and strictly advance the timeline.
- **Static-screen keepalive (Task 2, Pitfall 2):** a ~2s `DispatchSourceTimer` on `writerQueue` re-appends the cached last frame (retimed via `CMSampleBuffer(copying:withNewTiming:)`) whenever no live frame arrived that interval, so `movieFragmentInterval` keeps flushing on static content and a kill-9 loses ≤ ~10s.
- **Non-blocking stop (Pitfall 7):** `stop()` stops the stream, re-appends the cached frame at stop-time PTS (duration ≈ wall clock), `markAsFinished()`, and calls `finishWriting` ASYNC — the defragment pass never blocks app quit.
- **Stream-death finalize (Pitfall 6):** `didStopWithError` logs, fires `onStreamStopped(error)`, and re-dispatches a finalize onto `writerQueue` so the fragmented partial stays playable — no silent failure.
- **Idempotency:** a `WriterSink`-internal finalize guard (distinct from the owner-domain start guard) means stop-after-error and double-stop are safe no-ops via the pure `transition`. A defensive `deinit` finalizes the writer.
- **Full suite green:** 304 tests, `** TEST SUCCEEDED **`; build clean under `SWIFT_STRICT_CONCURRENCY=complete`.

## Baseline

Wave 1 (18-01) left the suite at 304 tests green. This plan modified only `ScreenRecorder.swift` (no new test files — the live SCStream path is not unit-testable per RESEARCH; the pure logic it wires was already covered by 18-01's 26 tests). Suite remained 304 green after both tasks.

## Decisions Made

- **`CaptureTarget` is not `Sendable`** — the plan sketch marked it `Sendable`, but `SCWindow` is non-`Sendable` on the local SDK (Xcode 26.2) and the enum never crosses an isolation boundary (`ScreenRecorder` is a non-`Sendable` class owned within one isolation domain, per Pattern 1). Dropped the conformance with a documented comment rather than an `@unchecked` lie.
- **Filter-derived dimensions** — computed from `SCContentFilter.contentRect * pointPixelScale` (both macOS 14.0+) instead of `SCDisplay.width/height`, giving true physical pixels through one code path for both display and window modes.
- **Dual-state guard** — `WriterSink` owns a `writerQueue`-confined finalize-guard `State` separate from `ScreenRecorder`'s owner-domain start guard; both use the pure `transition`, so the caller-driven `stop()` and the stream-error `didStopWithError` funnel through the same idempotent finalize without a data race.

## Public API (for Plan 18-03's harness)

```swift
enum CaptureTarget { case display(CGDirectDisplayID?); case window(SCWindow) }
func start(target: CaptureTarget, preset: QualityPreset, outputURL: URL) async throws
func stop() async
var isRecording: Bool { get }
var onFirstFrameHostTime: (@Sendable (UInt64) -> Void)?   // fires once with first-frame mach ticks (STOR-04)
var onStreamStopped: (@Sendable (Error?) -> Void)?         // fires on didStopWithError
static let keepaliveInterval: TimeInterval = 2.0           // static-screen re-append interval
static let maxLongEdge = 1920                              // downscale clamp (physical px)
```

- **Anchor return:** `onFirstFrameHostTime(hostTicks)` delivers the first written frame's host time in mach ticks; the caller converts to seconds via the existing pure `ScreenRecorder.hostTicksToSeconds(_:timebase:)` and persists it against the audio start host time (Phase 20).
- **Keepalive interval used:** 2.0 s (18-01 starting value; to be tuned against the kill-9 static-screen gate in Plan 03/04).

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] `CaptureTarget: Sendable` does not compile**
- **Found during:** Task 1 (build verification)
- **Issue:** The plan's sketch marked `enum CaptureTarget: Sendable` with a `case window(SCWindow)` payload; `SCWindow` is not `Sendable` on the SDK, so the build failed with "associated value 'window' … has non-Sendable type 'SCWindow'".
- **Fix:** Dropped the `Sendable` conformance (the enum never crosses an isolation boundary — `ScreenRecorder` is a non-`Sendable` class owned within one isolation domain) and documented why in a comment.
- **Files modified:** `Sources/Recording/ScreenRecorder.swift`
- **Commit:** `6d63d6d`

## Issues Encountered

None beyond the `Sendable` deviation above. The `finishWriting(completionHandler:)` completion capturing the non-`Sendable` `AVAssetWriter` compiled clean under complete checking (the handler is a plain, non-`@Sendable` escaping closure).

## Known Stubs

None — the `WriterSink` delegate bodies and writer/input fields that Plan 18-01 left as intentional stubs are now fully implemented. No data stub reaches any view (engine is not UI-facing until Phase 21).

## Verification Gaps (deferred to Plan 03/04, per RESEARCH)

Live `SCStream` capture requires the Screen Recording TCC grant + hardware and cannot run in `make test`. The following are validated by Plan 03/04's integration harness + scripted kill-9 gate, and must be re-run on a macOS 14.2 machine before the milestone ships (local toolchain is macOS 26):

- Real capture duration ≈ wall clock (first-frame + static-screen).
- First-frame anchor accuracy (~100 ms).
- kill-9 fragment recovery (≤ ~10s loss) on `.mov` + `movieFragmentInterval`.
- `didStopWithError` fault injection → playable partial + `onStreamStopped` fired.
- Caddie windows never appear (visual QA).

## Next Phase Readiness

- Plan 18-03 (integration harness / kill-9 gate) can proceed — the live capture API (`start`/`stop`/`CaptureTarget`) and the anchor callback are complete and build-green.
- Phase 19 (`RecordingCoordinator` wiring) can inject `ScreenRecorder` like `AudioRecorder`; video failure surfaces via `onStreamStopped` for the degrade-to-audio-only path (Phase 19 owns that).

---
*Phase: 18-screen-capture-engine*
*Completed: 2026-07-09*

## Self-Check: PASSED

`Sources/Recording/ScreenRecorder.swift` and `18-02-SUMMARY.md` verified on disk; both task commits (`6d63d6d`, `6f6269a`) verified in git history; all acceptance greps present (`func start(target:`, `fileType: .mov` + `movieFragmentInterval`, `capturesAudio = false`, `excludedBundleIdentifiers` + `SCContentFilter`, `onFirstFrameHostTime?(`, `sampleHandlerQueue`, `markAsFinished` + `finishWriting {`, `didStopWithError` + `onStreamStopped`, `CMSampleBuffer(copying:` + `DispatchSource`, `deinit`).

# Phase 18: Screen Capture Engine - Research

**Researched:** 2026-07-09
**Domain:** macOS ScreenCaptureKit → AVAssetWriter video capture in a Swift 6 strict-concurrency codebase (Caddie v3.0)
**Confidence:** HIGH (stack/pitfalls inherited from milestone research at HIGH; concurrency topology MEDIUM pending the mandated spike; preset numbers HIGH against stable Apple APIs)

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **Capture stack:** Native ScreenCaptureKit `SCStream` → `AVAssetWriter`. **Zero new SPM dependencies.** No viable OSS library exists; wulkano/Aperture and nonstrict-hq/ScreenCaptureKit-Recording-example are MIT pattern references only (safe to study/adapt with attribution, not to vendor).
- **`SCRecordingOutput` is macOS 15+ — NOT usable.** Deployment floor is 14.2. Do NOT add an availability-gated 15+ branch this milestone.
- **Video-only stream:** `capturesAudio = false`. System audio stays on CoreAudio process taps (`SystemAudioCapture`) — do NOT consolidate audio onto the SCStream.
- **Encoding:** HEVC hardware encode (VideoToolbox Media Engine) with EXPLICIT bitrate caps. Uncapped defaults produce 40+ Mbps files.
- **Quality presets owned by the engine as an enum:** compact ~10 fps, balanced ~15 fps (default), high ~30 fps, each with an explicit average-bitrate cap (~2–3 Mbps class for balanced ≈ 0.5–1.3 GB/hr). Phase 21 exposes the picker; the engine defines the values now.
- **Downscale Retina capture toward point / ~1080p–1440p class; writer dimensions MUST exactly match stream configuration dimensions.**
- **Crash safety:** `.mov` container with `movieFragmentInterval` ≈ 10 s. A `kill -9` mid-recording must leave a playable file missing at most the last fragment.
- **Timing anchor:** Record the first video frame's host-clock (mach) timestamp; expose it so callers can persist it against the audio start host time (STOR-04 storage lands in Phase 20; the engine produces the value now).
- **Capture target:** Engine accepts display OR window as a capture target (user-facing choice ships in Phase 21; engine API supports both now). Caddie's own windows excluded via `SCContentFilter` in both modes (VID-05).
- **Conventions:** TDD — tests first, no exceptions. `final class ScreenRecorder` (or actor if the spike says so) in `Sources/Recording/`, custom `enum ScreenRecorderError: Error, LocalizedError`, no silent failures, Swift 6 strict concurrency.

### Claude's Discretion
- Exact public API shape (start/stop signatures, how the anchor is returned).
- Queue/actor topology for SCK delegate + writer (decide via the concurrency spike).
- Exact preset bitrate numbers within the researched ranges; exact fragment interval near 10 s.
- Test seam design (SCStream is not mockable in unit tests — decide what is unit-tested vs covered by an integration/manual gate; kill -9 fragment recovery likely needs a script or manual gate documented in the plan).

### Deferred Ideas (OUT OF SCOPE)
- Coordinator wiring, graceful-degradation behavior → Phase 19.
- `video_file` column, deletion, disk guard → Phase 20.
- Settings toggle/target/preset UI, AVKit playback, transcript-seek, export → Phase 21.
- `SCRecordingOutput` simplification → future milestone when the floor moves to macOS 15+.
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| **VID-05** | Caddie's own windows excluded from capture (SCContentFilter exclusion) | Filter-construction section: `SCContentFilter(display:excludingApplications:exceptingWindows:)` for display mode; own-window enumeration via `SCShareableContent` filtered on `Bundle.main.bundleIdentifier`. Pure filter-input logic is unit-testable. |
| **VID-06** | User can choose a video quality preset (compact ~10 / balanced ~15 / high ~30 fps; HEVC + explicit bitrate caps) | `QualityPreset` enum section with concrete `SCStreamConfiguration` + `AVAssetWriter` numbers per preset. Preset→config math is a pure, unit-testable static function. |
| **VID-07** | Crash/power loss loses at most the last ~10 s; partial file stays playable (fragmented .mov) | Crash-safety section: `AVFileType.mov` + `movieFragmentInterval = CMTime(seconds: 10, ...)` set before `startWriting`; async `finishWriting`. Verified by a scripted kill-9 gate (Validation Architecture). |
| **STOR-04** | Video/audio timeline alignment metadata (host-clock anchor) produced by the engine | Timing-anchor section: capture first-written-frame host time + expose it; conversion via `mach_timebase_info`. Anchor computation is a pure, unit-testable function. Storage lands Phase 20 — engine returns the value now. |
</phase_requirements>

## Summary

This phase builds a standalone `ScreenRecorder` (final class, `Sources/Recording/`) that drives a video-only `SCStream` into an `AVAssetWriter`, producing a crash-safe, bitrate-capped HEVC `.mov` with a host-clock timing anchor. The milestone research (`.planning/research/*`) already established the stack (native SCK + AVAssetWriter, zero dependencies), the ten sharp edges, and the integration architecture at HIGH confidence — this document does not repeat that groundwork. It answers the six phase-specific planning unknowns: (1) the Swift 6 strict-concurrency topology, (2) exact preset/writer numbers, (3) which behavior is unit-testable vs harness/manual, (4) how to script the kill-9 gate, (5) window/display filter specifics, and (6) first-frame/static-screen handling.

The dominant risk is the Swift 6 concurrency shape. SCK delivers `SCStreamOutput`/`SCStreamDelegate` callbacks on a caller-supplied `DispatchQueue`, and `AVAssetWriter`/`AVAssetWriterInput` are not `Sendable`. The recommended shape — consistent with the existing codebase — is **a non-`Sendable` `final class ScreenRecorder` owned by the RecordingCoordinator actor, with a separate `@unchecked Sendable` writer-sink object that the SCK delegate confines to one dedicated serial queue** (mirroring how `AudioRecorder` is a non-actor class confined to the coordinator, and how `SystemAudioCapture` uses a retained `RenderContext` for its C callback). This keeps the writer hot path off the actor executor and off the audio ring buffer entirely. The spike's job is to confirm this compiles clean under `SWIFT_STRICT_CONCURRENCY=complete` on the local toolchain (Swift 6.2.3 / Xcode 26.2) before the API is committed.

**Primary recommendation:** Build the engine as a queue-confined `final class` with the writer isolated behind a dedicated serial `DispatchQueue`, extract all preset/dimension/anchor math into pure static functions (unit-tested, exactly like `SystemAudioCapture.outputCapacity`/`makeDownsamplingConverter`), and gate the two hardware behaviors (kill-9 recovery, real capture playability) behind a scripted integration test that spawns a short recording, `kill -9`s it, and validates the `.mov` with `AVAsset`.

## Project Constraints (from CLAUDE.md)

- **TDD is mandatory** — tests first, no exceptions (global + project CLAUDE.md). Every pure function gets a failing test before implementation.
- **Swift 6 strict concurrency** — `SWIFT_VERSION 6.0`, `SWIFT_STRICT_CONCURRENCY: complete` (project.yml). No `@preconcurrency` escape hatches without a documented reason.
- **No silent failures** — every error path logs with context and surfaces (core value). SCK `didStopWithError` must never leave an unfinalized writer or a silently-stopped stream.
- **Error enums** conform to `Error & LocalizedError` with `errorDescription` (e.g., `ScreenRecorderError`), matching `RecorderError`/`CaptureError`.
- **`final class`** unless inheritance is required; `private(set)` for read-only public state; camelCase; `// MARK: -` section headers.
- **Logging** via `CaddieLogger.recording` (`Logger(subsystem: "com.caddie.app", category: "ScreenRecorder")`), context variables in messages.
- **No new SPM dependencies** (locked decision + reinforces CLAUDE.md "check if something already exists").
- **Deployment floor macOS 14.2** — no API newer than 14.2 without an availability guard, and the locked decision forbids a 15+ branch this milestone.
- **README update** when shipping user-facing behavior (global CLAUDE.md). Phase 18 is engine-only/no UI, so README lands with Phase 21 — note in the plan that Phase 18 does not touch README.

## Standard Stack

**Zero new dependencies.** Everything below is an Apple system framework already available at the 14.2 floor. (Full availability matrix and license landscape: `.planning/research/STACK.md` — not repeated here.)

### Core (all present at macOS 14.2)
| Framework / API | Purpose | Notes |
|-----------------|---------|-------|
| `ScreenCaptureKit` (`SCStream`, `SCContentFilter`, `SCStreamConfiguration`, `SCShareableContent`, `SCStreamOutput`, `SCStreamDelegate`) | Capture a display or window as `CMSampleBuffer`s | Delegate/output callbacks arrive on a **caller-supplied `DispatchQueue`** (`addStreamOutput(_:type:sampleHandlerQueue:)`) — this is the concurrency crux |
| `AVFoundation` (`AVAssetWriter`, `AVAssetWriterInput`, `AVAssetWriterInputPixelBufferAdaptor` optional) | In-flight HEVC encode to `.mov` | `movieFragmentInterval` (QuickTime-only) gives crash safety; not `Sendable` |
| `VideoToolbox` (implicit via AVAssetWriter compression settings) | Hardware HEVC on the Media Engine | Selected through `AVVideoCodecType.hevc` + `AVVideoCompressionPropertiesKey`; near-zero CPU |
| `CoreMedia` (`CMSampleBuffer`, `CMTime`, `CMClockGetHostTimeClock`, `CMSampleBuffer(copying:withNewTiming:)`) | Retiming + host-clock anchor | Shares the mach host clock with CoreAudio's `AudioTimeStamp.mHostTime` |
| `mach_timebase_info` (Darwin) | Convert mach ticks → seconds for the anchor | Same conversion the audio side uses for host time |

### Installation
None. Add `import ScreenCaptureKit` / `import AVFoundation` / `import CoreMedia` to the new file. No `project.yml` package additions.

### Toolchain (verified locally 2026-07-09)
- **Local:** `swift --version` → Apple Swift 6.2.3; `xcodebuild -version` → Xcode 26.2 (17C52).
- **Project pins (project.yml):** `SWIFT_VERSION: "6.0"`, `SWIFT_STRICT_CONCURRENCY: complete`, `MACOSX_DEPLOYMENT_TARGET: "14.2"`, `xcodeVersion: "15.0"` (project minimum, not the local toolchain).
- **Consequence:** the concurrency spike must compile under language-mode 6 + complete checking on the *local* 6.2.3 toolchain; that is the real gate.

## Architecture Patterns

### Recommended engine placement
```
Sources/Recording/
├── AudioRecorder.swift          # existing — mirror its lifecycle shape
├── SystemAudioCapture.swift     # existing — mirror its retained-callback + error-enum pattern
└── ScreenRecorder.swift         # NEW — SCStream → AVAssetWriter engine (this phase)
```
The engine is a **sibling** of the audio capture classes and follows their conventions exactly. It has zero dependencies on Storage/UI/Coordinator (validated in isolation, per the phase boundary).

### Pattern 1 (RECOMMENDED): Queue-confined non-Sendable `final class` + isolated writer sink

**What:** `ScreenRecorder` is a `final class` (not an actor) intended to be owned by the `RecordingCoordinator` actor in Phase 19 — the same relationship `AudioRecorder` already has. The SCStream/AVAssetWriter hot path lives on **one dedicated serial `DispatchQueue`** (e.g. `com.caddie.screenrecorder.writer`). The object registered as `SCStreamOutput`/`SCStreamDelegate` receives callbacks on that same queue (pass it as the `sampleHandlerQueue`), so all writer mutation is single-threaded by construction. Cross-boundary notifications (stream died, first-frame captured) hop out via `@Sendable` closures, exactly like `AudioRecorder.onDeviceDisconnected` / `onSamples`.

**Why this one:**
- It is the pattern already in the codebase: `AudioRecorder` is a confined non-actor class; `SystemAudioCapture` hands a retained context to a C callback and marshals results out via a `@Sendable`-style callback. `RecordingCoordinator` (actor) already owns a non-`Sendable` `AudioRecorder`. The planner should not invent a new topology.
- `AVAssetWriter` handles its own backpressure via `AVAssetWriterInput.isReadyForMoreMediaData` — no locks needed if all appends happen on the one queue.
- The audio ring buffer and the SCK path never touch: zero shared state, zero contention with the real-time audio thread.

**Compile shape (the spike proves this):**
```swift
// Source pattern: mirror of SystemAudioCapture.RenderContext confinement + AudioRecorder callback style.
// Verify under SWIFT_STRICT_CONCURRENCY=complete before committing the public API.

final class ScreenRecorder {
    // Public, main/actor-facing surface (called from the coordinator's isolation domain).
    private(set) var isRecording = false

    // Fired once, with the first written frame's host time, so the caller can persist
    // the anchor against the audio start host time. @Sendable: crosses the queue boundary.
    var onFirstFrameHostTime: (@Sendable (UInt64) -> Void)?
    // Fired if the stream dies (didStopWithError). @Sendable: arrives on SCK's queue.
    var onStreamStopped: (@Sendable (Error?) -> Void)?

    private let writerQueue = DispatchQueue(label: "com.caddie.screenrecorder.writer")
    private var sink: WriterSink?      // confined to writerQueue after start()
    private var stream: SCStream?
    ...
}

// The object SCK calls back on. Confined to writerQueue; @unchecked Sendable is the
// documented invariant boundary (all access is on writerQueue). Same spirit as
// SystemAudioCapture.RenderContext being reached via Unmanaged from the RT thread.
final class WriterSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    // AVAssetWriter + AVAssetWriterInput live here; touched only on writerQueue.
    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer,
                of type: SCStreamOutputType) { /* on writerQueue */ }
    func stream(_ s: SCStream, didStopWithError error: Error) { /* on writerQueue */ }
}
```

**Trade-off:** the `@unchecked Sendable` boundary needs a written invariant comment ("all fields touched only on `writerQueue`"), exactly like `SystemAudioCapture`'s retained-context justification comment. That is the accepted cost.

### Pattern 2 (REJECT): `ScreenRecorder` as an `actor`
SCK's delegate protocols are not async and callbacks arrive on a framework queue; forcing them through an actor means `nonisolated` delegate methods that immediately `Task { await ... }`-hop, adding latency and reordering risk on a real-time frame stream, and fighting `AVAssetWriter`'s non-`Sendable` inputs. ARCHITECTURE.md Anti-Pattern and the milestone research both flag this. Do not.

### Pattern 3: Crash-safe in-flight encoding (contrast with audio's compress-after)
`AVAssetWriter` encodes HEVC straight to the final `.mov`; no WAV→ALAC-style post-pass. `finishWriting` runs an async defragment pass that grows with recording length — **never block app quit on it** (Pitfall 7). Unlike audio, the file must survive independent of transcription status.

### Pattern 4: Host-clock anchoring for transcript alignment
`CMSampleBuffer` PTS is on `CMClockGetHostTimeClock()` (mach host time) — the same clock CoreAudio reports as `AudioTimeStamp.mHostTime`. Capture the host time of the **first frame actually written** and expose it; Phase 20 persists it against the first WAV sample's host time as `videoStartOffsetSeconds`. These anchors cannot be reconstructed after the fact — capturing them is a Phase 18 requirement (STOR-04) even though seek UI ships in Phase 21.

### Anti-Patterns to avoid (phase-specific)
- **Making the engine an actor** (Pattern 2 above).
- **Sharing any queue/lock with the audio ring buffer** — the two paths must have zero contact.
- **`queueDepth` set large "to be safe"** — keep 3–6 and return buffers promptly, or memory pressure builds.
- **Starting the writer session "at now"** — silently drops the first frame (Pitfall 1).
- **`.mp4` container** — `movieFragmentInterval` is a no-op; a crash loses everything (Pitfall 7).

## Preset & Writer Configuration (VID-06 — concrete numbers to copy)

Define the presets as an engine-owned enum. These are copy-into-task-actions starting values; the exact bitrate within each researched band is Claude's discretion (STACK.md band: HEVC, 10–15 fps, explicit 2–3 Mbps → ~0.5–1.3 GB/hr; uncapped defaults are 40+ Mbps).

| Preset | fps | `minimumFrameInterval` | Suggested `AVVideoAverageBitRateKey` | ~GB/hr | Notes |
|--------|-----|------------------------|--------------------------------------|--------|-------|
| `.compact` | 10 | `CMTime(value: 1, timescale: 10)` | 1_500_000 (1.5 Mbps) | ~0.6 | Apple's WWDC22 low-motion text guidance is ~10 fps |
| `.balanced` (default) | 15 | `CMTime(value: 1, timescale: 15)` | 2_500_000 (2.5 Mbps) | ~1.1 | Matches ScreenSage production (~BPP 0.05) |
| `.high` | 30 | `CMTime(value: 1, timescale: 30)` | 4_000_000 (4.0 Mbps) | ~1.8 | Full-motion; still an order below QuickTime defaults |

### `SCStreamConfiguration` (per start)
```swift
let config = SCStreamConfiguration()
config.minimumFrameInterval = preset.minimumFrameInterval        // fps throttle (dominant size lever)
config.width  = targetPixelWidth                                 // see dimension math below
config.height = targetPixelHeight                                // MUST equal writer AVVideoWidth/HeightKey
config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange  // '420v' — HEVC-friendly, hardware path
config.queueDepth = 5                                            // 3–6; return buffers promptly
config.showsCursor = true                                        // product choice; cheap
config.capturesAudio = false                                    // LOCKED — video-only stream
config.scalesToFit = true                                        // let SCK downscale to the configured size
config.colorSpaceName = CGColorSpace.sRGB                        // deterministic color; avoids writer surprises
```

### Dimension math (Pitfall 4 — writer MUST match stream; unit-testable)
`SCStreamConfiguration.width/height` are **physical pixels**. Retina displays have a scale factor between the `SCDisplay`/`SCWindow` point frame and delivered buffers. Compute the target pixel size once, clamp to the ~1080p–1440p class, and feed the **same** numbers to both the stream config and the writer input. Extract as a pure static function (test it):
```swift
// ScreenRecorder.targetDimensions(sourceWidthPx:sourceHeightPx:maxLongEdge:) -> (w: Int, h: Int)
// - source is display.frame * scaleFactor (or window.frame * scale)
// - downscale preserving aspect so max(w,h) <= maxLongEdge (e.g. 1920 or 2560)
// - round to even numbers (HEVC requires even dimensions)
// - if H.264 is ever offered, additionally clamp to <= 4096 x 2304 (Pitfall 9)
```

### `AVAssetWriter` / `AVAssetWriterInput` (per start)
```swift
let writer = try AVAssetWriter(outputURL: movURL, fileType: .mov)     // .mov is REQUIRED for fragments
writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)  // set BEFORE startWriting

let videoSettings: [String: Any] = [
    AVVideoCodecKey: AVVideoCodecType.hevc,
    AVVideoWidthKey: targetPixelWidth,           // == config.width
    AVVideoHeightKey: targetPixelHeight,         // == config.height
    AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: preset.bitrate,            // EXPLICIT cap — non-negotiable (Pitfall 3)
        AVVideoExpectedSourceFrameRateKey: preset.fps,
        AVVideoMaxKeyFrameIntervalDurationKey: 2.0,          // keyframe every ~2s (seek + fragment friendliness)
        AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel,
    ],
]
let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
input.expectsMediaDataInRealTime = true          // real-time capture source
writer.add(input)
writer.startWriting()
// startSession(atSourceTime:) deferred to the FIRST buffer — see first-frame handling.
```
The writer-settings dictionary is buildable and assertable **without any hardware** — a pure builder function (`ScreenRecorder.videoSettings(for:preset:dimensions:)`) is the primary unit-test seam (Pitfall 3 becomes a compile-time-verified assertion: "bitrate key present and == preset value").

## First-Frame, Static-Screen & Stop Handling (the risk-bearing detail)

### First-frame drop (Pitfall 1) → success criterion 5, STOR-04
Do **not** `startSession(atSourceTime: CMClockGetTime(...))` at "now". Two proven recipes; pick one in the spike:
- **(A) Nonstrict recipe:** `startSession(atSourceTime: .zero)`, then retime every buffer relative to the first frame's PTS via `CMSampleBuffer(copying:withNewTiming:)`. Movie timeline starts at 0; the persisted anchor is the first frame's host time.
- **(B) Session-at-first-PTS:** on the first delivered buffer, `startSession(atSourceTime: firstPTS)` and append raw PTS. Movie timeline is host time; anchor is the session start.
Either way, the **first written frame's host time is the anchor** (STOR-04). Extract the anchor conversion (`mach ticks → seconds` via `mach_timebase_info`) as a pure static function and unit-test it against known inputs.

### Static-screen duration bug (Pitfall 2) → success criterion 5
SCK stops emitting frames when the screen is static (most of a meeting). Cache the last complete frame; at `stop()`, re-append it retimed to the stop-time PTS so file duration matches wall clock. For fragment advancement during long static stretches, a low-frequency timer re-appends the cached frame every few seconds so `movieFragmentInterval` keeps flushing (otherwise a kill-9 on static content loses far more than one fragment). The "compute the stop PTS / re-append timing" logic is pure and unit-testable; the actual frame delivery is not.

### Frame status filtering
Read `SCStreamFrameInfo.status` from the sample buffer attachment (`SCStreamFrameInfoStatus`); append only `.complete` frames. Skipping `.idle`/`.blank`/`.suspended`/`.stopped` frames avoids feeding the writer junk. The classification (given a status enum → append/skip/cache) is a pure, testable decision function.

### Stream death (`didStopWithError`, error -3821) (Pitfall 6) → no silent failures
Implement `stream(_:didStopWithError:)`: finalize the current file cleanly (fragments make it playable), log with context, fire `onStreamStopped`. In Phase 18 the engine's job ends at "finalize + surface"; the coordinator's degrade-to-audio-only wiring is Phase 19. Never leave an unfinalized writer on the error path.

### Stop path
`stop()` must be driven by the caller, never by frame arrival (Pitfall 10) — re-append the cached last frame, mark input finished, call `writer.finishWriting` **async** (do not block quit; Pitfall 7). Mirror `AudioRecorder.stop()`'s `guard isRecording` idempotency.

## Capture-Target Filter Construction (VID-05)

### Display mode (default), excluding Caddie's own windows
```swift
let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
guard let display = content.displays.first(where: { $0.displayID == targetDisplayID }) else { throw ... }
// Exclude Caddie's own app so its windows never appear (VID-05):
let caddieApp = content.applications.first { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
let filter = SCContentFilter(display: display,
                             excludingApplications: caddieApp.map { [$0] } ?? [],
                             exceptingWindows: [])
```
`SCContentFilter(display:excludingApplications:exceptingWindows:)` is available at 14.2. Excluding by application (Caddie's bundle id) is more robust than enumerating individual windows because it also covers transient panels/menus. The **filter-input selection** (which display, which apps to exclude) is pure logic → unit-test the selector given a mock `SCShareableContent`-shaped input; the actual `SCContentFilter` construction needs the framework.

### Window mode (user-selectable, Phase 21)
```swift
let filter = SCContentFilter(desktopIndependentWindow: targetWindow)   // SCWindow
```
Known limitation (Pitfall 5): mid-recording **resize** changes delivered content scale, but writer dimensions are fixed per session. Rely on `config.scalesToFit = true` so SCK scales into the fixed size (accepting aspect changes); do **not** attempt mid-recording writer reconfiguration. If the window **closes**, SCK fires `didStopWithError` → the Pitfall 6 finalize path. Document window mode as the non-default; display capture is the default per the scoping decision. Phase 18 must handle window-close gracefully (finalize a playable file); resize-distortion is an accepted, documented behavior.

### Own-window enumeration (reliable method)
Match on `Bundle.main.bundleIdentifier` against `SCRunningApplication.bundleIdentifier` (application-level exclusion) rather than `CGWindowListCopyWindowInfo` scraping. This is deterministic and survives window creation/destruction during the recording.

## Runtime State Inventory

Not applicable — Phase 18 is greenfield (a new engine class, no rename/refactor/migration). Verified: no existing `ScreenRecorder`, no SCStream/AVAssetWriter references anywhere in `Sources/` (milestone codebase read + grep confirm). Section omitted intentionally.

## Don't Hand-Roll

| Problem | Don't build | Use instead | Why |
|---------|-------------|-------------|-----|
| Crash-safe partial video | Custom chunked writer / periodic file copies | `AVAssetWriter.movieFragmentInterval` on `.mov` | One property; QuickTime fragmenting is the documented, tested mechanism (Pitfall 7) |
| HEVC encoding | Any ffmpeg / VideoToolbox-by-hand pipeline | `AVAssetWriter` HEVC settings | Hardware Media Engine path, near-zero CPU; ffmpeg adds licensing/notarization liability (STACK.md "What NOT to Use") |
| Capture-target selection | `CGWindowList` scraping, legacy `AVCaptureScreenInput` | `SCShareableContent` + `SCContentFilter` | Legacy APIs are deprecated (`CGDisplayStream` 14.0) and trigger extra Sonoma consent alerts; can't exclude own windows |
| Retiming / frame copy | Manual pixel-buffer timestamp surgery | `CMSampleBuffer(copying:withNewTiming:)` | The Nonstrict-proven recipe for first-frame + static-screen fixes |
| Host-clock conversion | Reinventing tick math | `mach_timebase_info` (same as audio side) | Both clocks are already mach host time; the audio path already does this conversion |

**Key insight:** the entire value of building this natively (vs the dormant Aperture wrapper) is owning the per-frame timestamp for transcript alignment and the exact fragment/bitrate config — everything *else* is a thin call into Apple frameworks. Do not add abstraction beyond the preset enum + pure config functions.

## Common Pitfalls

The ten sharp edges are catalogued in full in `.planning/research/PITFALLS.md` with sources — not repeated. Phase-18-relevant ones and how the plan verifies them:

| Pitfall | Prevention | Verification in this phase |
|---------|-----------|----------------------------|
| 1. First-frame drop | Session anchored to first buffer PTS (recipe A or B) | Duration test on integration harness; anchor within ~100 ms |
| 2. Static-screen duration | Cache + re-append last frame at stop; low-freq keepalive | Static-screen integration test: file duration ≈ wall clock |
| 3. Uncapped bitrate | Explicit `AVVideoAverageBitRateKey` per preset | **Unit test** on the settings-builder (bitrate key present == preset value); 10-min file ≤ ~250 MB integration check |
| 4. Dimension mismatch | Compute once, feed stream + writer identically; even dims | **Unit test** on `targetDimensions(...)` (Retina + downscale + odd-number cases) |
| 5. Window resize/close | `scalesToFit`; finalize on close; document display-default | Manual resize QA (Phase 21 copy); window-close → playable file (integration) |
| 6. Stream death -3821 | `didStopWithError` finalize + surface | Fault-injection: stop stream externally → playable partial + `onStreamStopped` fired |
| 7. `.mov` + async finalize | `.mov` fileType; `movieFragmentInterval` pre-`startWriting`; async `finishWriting` | **kill-9 scripted gate** (below); quit-after-long-record no-hang manual check |
| 9. H.264 4096×2304 cap | Default HEVC; clamp if H.264 ever offered | **Unit test** on the clamp branch |
| 10. Display sleep/Space/unplug | Surfaces as Pitfall 6 or frame starvation → Pitfall 2 patch; stop never waits on a frame | Manual edge-case QA |

## Code Examples

The concrete, copy-ready config blocks are in **Preset & Writer Configuration** above (SCStreamConfiguration + AVAssetWriter settings) and the **Pattern 1** compile shape. Those are the load-bearing snippets for the planner. First-frame/static-screen recipes are described in their section rather than as full code because the exact recipe (A vs B) is chosen during the spike.

## State of the Art

| Old approach | Current approach | When changed | Impact for this phase |
|--------------|------------------|--------------|-----------------------|
| `AVCaptureScreenInput` / `CGDisplayStream` | `SCStream` + `AVAssetWriter` | `CGDisplayStream` deprecated macOS 14.0 | Use SCK exclusively |
| Manual AVAssetWriter (12–14) | `SCRecordingOutput` records to file itself | macOS 15.0 | **Not usable at 14.2** — AVAssetWriter path mandatory (locked) |
| Uncapped VideoToolbox defaults | Explicit BPP-derived bitrate cap | ShipsToday best practice | 40+ Mbps → 2.5 Mbps |

**Deprecated / do not use:** `CGDisplayStream` (14.0), `AVCaptureScreenInput`+`AVCaptureMovieFileOutput` (legacy, extra consent alerts), `AVOutputSettingsAssistant` presets (camera-tuned, 40+ Mbps), `SCRecordingOutput` (15+ only).

## Open Questions

1. **Concurrency shape compiles clean under complete checking?**
   - Known: Pattern 1 (queue-confined class + `@unchecked Sendable` sink) matches the existing `AudioRecorder`/`SystemAudioCapture` precedent and should compile.
   - Unclear: whether SCK's `SCStreamOutput`/`SCStreamDelegate` conformance on an `@unchecked Sendable NSObject` needs any `nonisolated`/`@preconcurrency` seasoning on the local 6.2.3 toolchain.
   - Recommendation: **budget the spike as the first task** — a ~50-line throwaway that registers a stream output, appends to a writer on the dedicated queue, and builds under `SWIFT_STRICT_CONCURRENCY=complete`. Commit the API only after it's green. This is the phase's stated research flag.

2. **First-frame recipe A vs B.**
   - Known: both are proven (Nonstrict). B keeps the movie timeline in host time, which can simplify the anchor.
   - Recommendation: decide in the spike; either satisfies STOR-04. Prefer the one that makes the anchor a single stored scalar with the least retiming code.

3. **Static-screen keepalive frequency.**
   - Known: needed so fragments keep advancing on static content.
   - Unclear: exact interval (a few seconds) — tune so kill-9 on a static screen still loses ≤ ~10 s.
   - Recommendation: start at ~2 s keepalive re-append; validate against the kill-9 static-screen case.

4. **Kill-9 recovery on the 14.2 floor specifically.**
   - Known: `movieFragmentInterval` behavior is documented.
   - Unclear: empirical fragment-recovery amount on 14.2 hardware.
   - Recommendation: the scripted kill-9 gate (below) is the answer — run it as a phase gate. Local toolchain is macOS 26; if no 14.2 machine is available, document the gate as "must run on 14.2 before release" and validate the fragmenting behavior on the available OS as a proxy.

## Environment Availability

| Dependency | Required by | Available | Version | Fallback |
|------------|-------------|-----------|---------|----------|
| Swift toolchain | Build | ✓ | 6.2.3 | — |
| Xcode | Build/test | ✓ | 26.2 (17C52) | — |
| ScreenCaptureKit / AVFoundation / CoreMedia | Engine | ✓ | macOS 14.2+ system frameworks | — |
| Screen Recording TCC grant | Real capture (integration only) | ✓ (existing grant; Caddie already requests it) | — | Unit tests need no grant |
| macOS 14.2 test machine | kill-9 recovery gate on the floor | ✗ (local is macOS 26 / Darwin 25.5) | — | Run gate on available OS as proxy; document "must re-run on 14.2 before release" |

**Missing with fallback:** the 14.2-floor machine — the kill-9 gate can validate fragmenting behavior on the local OS and be flagged for a 14.2 re-run before the milestone ships (SUMMARY.md already lists this as a gap to close on the actual floor).
**Missing, blocking:** none — everything needed to build and unit-test the engine is present.

## Validation Architecture

Nyquist validation is **enabled** (`config.json → workflow.nyquist_validation: true`). SCStream cannot run in unit tests (permission + hardware), so validation splits into unit-testable pure logic vs an integration harness / scripted gate — the same split the codebase already uses for `SystemAudioCapture` (pure `outputCapacity`/`makeDownsamplingConverter` are unit-tested; the capture path is only "does not crash").

### Test Framework
| Property | Value |
|----------|-------|
| Framework | XCTest (project standard; ~34 test files under `Tests/`) |
| Config file | none — XcodeGen-generated scheme; test target defined in `project.yml` |
| Quick run command | `xcodebuild test -project Caddie.xcodeproj -scheme Caddie -only-testing:CaddieTests/ScreenRecorderTests` |
| Full suite command | `make test` (→ `xcodebuild test -project Caddie.xcodeproj -scheme Caddie`) |

**Note on the known linker issue:** CLAUDE.md flags that FluidAudio's C dependency (yyjson) causes a test linker issue. Confirm `make test` currently runs green before adding tests; if the linker issue blocks the whole suite, the plan must account for it (it is pre-existing, not introduced by this phase).

### Testability seams — what is unit-testable vs harness/manual
| Layer | Testable in a unit test? | How |
|-------|--------------------------|-----|
| `QualityPreset` → fps/bitrate/frameInterval | ✅ Yes | Assert enum values + derived `CMTime` |
| `videoSettings(for:preset:dimensions:)` builder | ✅ Yes | Assert dict has HEVC codec + `AVVideoAverageBitRateKey` == preset (kills Pitfall 3) |
| `targetDimensions(...)` downscale/clamp/even-round | ✅ Yes | Retina, 5K downscale, odd-number, H.264 clamp cases (Pitfall 4/9) |
| Anchor conversion (`mach ticks → seconds`) | ✅ Yes | Known-input arithmetic (STOR-04) |
| Frame-status → append/skip/cache decision | ✅ Yes | Table of `SCFrameStatus` → action |
| Filter-input selection (which display, which apps to exclude) | ✅ Yes (logic) | Given a shareable-content-shaped struct, assert the chosen display + Caddie exclusion (VID-05 logic) |
| State machine (`idle`→`recording`→`stopped`/`failed`, idempotent stop) | ✅ Yes | Drive transitions without hardware |
| Actual `SCStream` capture / real `.mov` playability | ❌ No | Integration harness (permission + hardware) |
| kill-9 fragment recovery | ❌ No | Scripted gate (below) |

### Phase Requirements → Test Map
| Req | Behavior | Test type | Command / gate |
|-----|----------|-----------|----------------|
| VID-06 | Preset defines HEVC + explicit bitrate cap; settings builder emits them | unit | `xcodebuild test ... -only-testing:CaddieTests/ScreenRecorderConfigTests` — ❌ Wave 0 |
| VID-06 | Dimensions clamp/downscale, writer == stream | unit | same target, `testTargetDimensions_*` — ❌ Wave 0 |
| VID-05 | Filter-input selection excludes Caddie's app; own-window enumeration by bundle id | unit (logic) + integration (real filter) | unit ❌ Wave 0; integration harness |
| STOR-04 | First-frame host time captured + exposed; tick→seconds conversion correct | unit (conversion) + integration (real anchor) | unit ❌ Wave 0; integration asserts anchor within ~100 ms |
| VID-07 | `.mov` + `movieFragmentInterval` produces recoverable partial on kill-9 | scripted gate | `Scripts/kill9-recovery-gate.sh` (below) — ❌ Wave 0 |
| SC5 | First-frame + static-screen produce correct-duration output | integration harness | record display + record static screen; assert duration ≈ wall clock |
| SC2 | Caddie windows never appear | manual/visual | record a display with a Caddie window open; inspect output |
| SC6 (Pitfall 6) | `didStopWithError` finalizes a playable partial | integration (fault injection) | stop stream externally; assert playable + `onStreamStopped` fired |

### kill-9 recovery gate (VID-07) — how to script it
A **shell-driven gate**, not an XCTest (XCTest cannot cleanly `kill -9` itself and still assert). Recommended shape (document in the plan as `Scripts/kill9-recovery-gate.sh` + a tiny CLI recording target, or a `#if DEBUG` `swift run`-able entry):
1. A minimal harness (a small executable or a debug entry point) starts `ScreenRecorder` recording a display to a temp `.mov` at the `.balanced` preset.
2. The script `sleep`s ~30 s (≥ 3 fragment intervals), then `kill -9 <pid>`.
3. The script validates the file with `AVAsset`: load `isPlayable` and `duration`; assert `duration >= (elapsed - 10s)` and `isPlayable == true`. A tiny validator (`avassetinfo`-style Swift snippet, or `ffprobe` if available) reads duration.
4. Pass criteria: file opens, plays, and is missing at most the last fragment (~≤10 s). Static-screen variant: run the same with a paused screen to exercise the keepalive.

This gate is feasible on the local OS to prove the fragmenting mechanism; flag it to re-run on a 14.2 machine before the milestone ships (Environment Availability).

### Sampling Rate
- **Per task commit:** the quick unit-test target (`ScreenRecorderConfigTests` / `ScreenRecorderStateTests`) — sub-30 s.
- **Per wave merge:** `make test` (full suite green).
- **Phase gate:** full suite green **plus** the kill-9 recovery gate and the static-screen/first-frame integration harness pass before `/gsd:verify-work`.

### Wave 0 Gaps
- [ ] `Tests/ScreenRecorderConfigTests.swift` — preset values, settings-builder (VID-06, Pitfall 3), dimension math (VID-04/09), anchor conversion (STOR-04).
- [ ] `Tests/ScreenRecorderStateTests.swift` — state machine + idempotent stop + frame-status decision.
- [ ] `Tests/ScreenRecorderFilterTests.swift` — filter-input selection / Caddie-exclusion logic (VID-05).
- [ ] `Scripts/kill9-recovery-gate.sh` (+ minimal recording harness/CLI entry) — VID-07 gate.
- [ ] Integration harness (manual/gated, not in `make test` CI path) — real capture duration + anchor + didStopWithError finalize.
- [ ] Confirm `make test` runs green today (FluidAudio/yyjson linker issue per CLAUDE.md) before adding tests.

## Sources

### Primary (HIGH confidence)
- Milestone research (codebase-verified 2026-07-09): `.planning/research/SUMMARY.md`, `STACK.md`, `ARCHITECTURE.md`, `PITFALLS.md` — stack, ten pitfalls, integration points (file:symbol), Swift 6 patterns.
- Caddie source read 2026-07-09: `Sources/Recording/AudioRecorder.swift` (confined non-actor lifecycle, `@Sendable` callbacks, idempotent stop), `Sources/Recording/SystemAudioCapture.swift` (retained-context C-callback pattern, error-enum style, pure static seams), `Sources/Coordinator/RecordingCoordinator.swift` (actor owning non-Sendable recorder, optional-dependency injection), `Tests/SystemAudioCaptureTests.swift` + `Tests/AudioRecorderBufferTests.swift` + `Tests/ProtocolDITests.swift` (pure-function + protocol-seam testing precedent), `Sources/Storage/Migrations.swift` (migration/FTS5 pattern for Phase 20 handoff), `project.yml` (SWIFT_VERSION 6.0, strict-concurrency complete, deployment 14.2), `Makefile` (`make test`).
- Toolchain probed locally 2026-07-09: Swift 6.2.3, Xcode 26.2.
- Apple frameworks (stable at 14.2): ScreenCaptureKit (`SCStream`/`SCContentFilter`/`SCStreamConfiguration`/`SCStreamOutput`/`SCStreamDelegate`), AVFoundation (`AVAssetWriter.movieFragmentInterval`, `AVAssetWriterInput`, HEVC compression keys), CoreMedia (`CMClockGetHostTimeClock`, `CMSampleBuffer(copying:withNewTiming:)`).

### Secondary (MEDIUM confidence)
- nonstrict.eu SCK-to-file blog + MIT example repo (first-frame + static-screen recipes) — via milestone research.
- fatbobman.com ScreenSage post-mortem (bitrate cap, error -3821, 10 s fragment interval) — via milestone research.

## Metadata

**Confidence breakdown:**
- Standard stack / API surface: HIGH — inherited from milestone research + stable Apple APIs at 14.2.
- Preset/writer numbers: HIGH — concrete values in researched bands; exact bitrate is discretion.
- Concurrency topology: MEDIUM — Pattern 1 matches codebase precedent but must be spike-verified under complete checking on 6.2.3 (the phase's stated research flag).
- Testability/validation split: HIGH — mirrors the existing `SystemAudioCapture` unit-test pattern exactly.
- kill-9 gate feasibility: MEDIUM — mechanism is sound; empirical 14.2-floor behavior must be confirmed on the floor before release.

**Research date:** 2026-07-09
**Valid until:** ~2026-08-09 (30 days; SCK/AVAssetWriter are stable — the volatile item is the local toolchain's strict-concurrency behavior, resolved by the spike).

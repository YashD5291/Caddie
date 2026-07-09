# Phase 18: Screen Capture Engine - Context

**Gathered:** 2026-07-09
**Status:** Ready for planning
**Source:** Session decisions (milestone scoping via AskUserQuestion + 22-agent research workflow, 2026-07-09)

<domain>
## Phase Boundary

A standalone `ScreenRecorder` in `Sources/Recording/` that records a display or window to a crash-safe, bitrate-capped HEVC `.mov` with host-clock timing anchors — validated in isolation. NO coordinator wiring (Phase 19), NO database schema (Phase 20), NO Settings/playback UI (Phase 21). The engine exposes the APIs those phases will consume (capture-target parameter, quality-preset enum, anchor value returned from recording).

</domain>

<decisions>
## Implementation Decisions

### Capture stack (locked by research verdict)
- Native ScreenCaptureKit `SCStream` → `AVAssetWriter`. Zero new SPM dependencies — no viable OSS library exists (wulkano/Aperture and nonstrict-hq/ScreenCaptureKit-Recording-example are MIT pattern references only, safe to study/adapt with attribution).
- `SCRecordingOutput` is macOS 15+ — NOT usable; the deployment floor is 14.2. Do not add an availability-gated 15+ branch this milestone.
- Video-only stream: `capturesAudio = false`. System audio stays on CoreAudio process taps (`SystemAudioCapture`) — do NOT consolidate audio onto the SCStream.

### Encoding (locked)
- HEVC hardware encode (VideoToolbox Media Engine) with EXPLICIT bitrate caps — uncapped defaults produce 40+ Mbps files.
- Quality presets owned by the engine as an enum: compact ~10 fps, balanced ~15 fps (default), high ~30 fps, each with an explicit average-bitrate cap in the ~2–3 Mbps class for balanced (~0.5–1.3 GB/hr). Phase 21 exposes the picker; engine defines the values.
- Downscale Retina capture toward point resolution / ~1080p–1440p class; writer dimensions MUST exactly match stream configuration dimensions.

### Crash safety (locked — core value)
- Fragmented QuickTime: `.mov` container with `movieFragmentInterval` ≈ 10 s. A `kill -9` mid-recording must leave a playable file missing at most the last fragment.

### Timing anchor (locked)
- Record the first video frame's host-clock (mach) timestamp; expose it so callers can persist it against the audio start host time (STOR-04 storage lands in Phase 20; engine produces the value now).

### Capture target (locked by scoping)
- Engine accepts display OR window as capture target (user-facing choice ships in Phase 21 Settings; engine API supports both now).
- Caddie's own windows are excluded via `SCContentFilter` in both modes (VID-05).

### Known sharp edges the engine MUST handle (from research)
- First-frame drop: start the writer session on the first buffer's PTS (or retime to .zero) or the first frame is silently dropped.
- Static-screen duration bug: SCK stops emitting frames when the screen is static — cache the last buffer and re-append retimed at stop, or a 30-min static meeting yields a seconds-long file.
- `SCStreamDelegate.didStopWithError` (window closed, error -3821): finalize the writer cleanly so the partial file is playable.
- `finishWriting` defragment pass on long recordings must not block app quit.

### Conventions (project)
- TDD — tests first, no exceptions. `final class ScreenRecorder` (or actor if the spike says so) in `Sources/Recording/`, custom `enum ScreenRecorderError: Error, LocalizedError`, no silent failures, Swift 6 strict concurrency (SCStream delegate callbacks arrive on background queues — Sendable/isolation design needs a short spike before committing).

### Claude's Discretion
- Exact public API shape (start/stop signatures, how the anchor is returned).
- Queue/actor topology for SCK delegate + writer (decide via the concurrency spike).
- Exact preset bitrate numbers within the researched ranges; exact fragment interval near 10 s.
- Test seam design (SCStream is not mockable in unit tests — decide what is unit-tested vs covered by an integration/manual gate; kill -9 fragment recovery likely needs a script or manual gate documented in the plan).

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Research (this milestone)
- `.planning/research/SUMMARY.md` — synthesis, phase-shape rationale, confidence
- `.planning/research/STACK.md` — API availability at the 14.2 floor, license landscape
- `.planning/research/ARCHITECTURE.md` — integration points (file:symbol), Swift 6 patterns, anti-patterns
- `.planning/research/PITFALLS.md` — the ten sharp edges with prevention strategies

### Existing code to mirror
- `Sources/Recording/AudioRecorder.swift` — sibling class conventions, lifecycle shape
- `Sources/Recording/SystemAudioCapture.swift` — capture-class error handling, retained-context patterns
- `Sources/Coordinator/RecordingCoordinator.swift` — how the engine will be consumed in Phase 19 (isolation expectations)

</canonical_refs>

<specifics>
## Specific Ideas

- MIT reference implementations to study: `github.com/nonstrict-hq/ScreenCaptureKit-Recording-example` (canonical SCStream→AVAssetWriter blueprint), `github.com/wulkano/Aperture` (single-file Swift package, same pattern), `github.com/jasonzh0/CineScreen` (active, macOS 14 floor).
- Success gate from roadmap: kill -9 mid-recording → playable file missing ≤ ~10 s, verified empirically on the 14.2 floor.

</specifics>

<deferred>
## Deferred Ideas

- Coordinator wiring, graceful degradation behavior → Phase 19
- `video_file` column, deletion, disk guard → Phase 20
- Settings toggle/target/preset UI, AVKit playback, transcript-seek, export → Phase 21
- `SCRecordingOutput` simplification → future milestone when the deployment floor moves to macOS 15+

</deferred>

---

*Phase: 18-screen-capture-engine*
*Context gathered: 2026-07-09 from session scoping decisions + v3.0 research*

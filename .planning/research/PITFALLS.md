# Pitfalls Research

**Domain:** ScreenCaptureKit → AVAssetWriter screen recording on macOS 14.2+
**Researched:** 2026-07-09 (22-agent workflow sweep; sharp edges cross-verified against Nonstrict blog/example, ScreenSage production post-mortem, Azayaka source, Apple forums)
**Confidence:** HIGH — every pitfall below has been hit by a shipping app or is documented Apple behavior

## Critical Pitfalls

### Pitfall 1: First-frame drop (session started at "now")

**What goes wrong:** Starting the writer session with `startSession(atSourceTime: CMClockGetTime(...))` at "now" silently drops the first frame — its PTS predates the session start — and the video begins with a gap or wrong duration.

**Why it happens:** SCStream buffers carry host-clock PTS; the first buffer arrives *after* you start the session, so any "start at now" timestamp is ahead of it.

**How to avoid:** Nonstrict's proven recipe: `startSession(atSourceTime: .zero)` and re-time every sample buffer relative to the first frame's PTS via `CMSampleBuffer(copying:withNewTiming:)`. Alternative: start the session at the *first buffer's* PTS and append raw PTS (then the movie timeline is host time and the anchor is the session start). Either way, the session must be anchored to the first actual buffer, and that first-frame host time is exactly the alignment anchor to persist (ARCHITECTURE.md Pattern 4).

**Warning signs:** Recorded duration ≈ wall time minus a fraction of a second; A/V alignment off by a constant.

**Phase to address:** Phase 1 (capture engine).

---

### Pitfall 2: Static-screen duration bug (SCK stops emitting frames)

**What goes wrong:** When screen content is static (a paused slide — i.e., *most of a meeting*), SCK stops delivering frames as a power optimization. An AVAssetWriter fed no buffers records a file whose duration is wrong (ends at the last change, not at stop time), and fragments stop advancing.

**Why it happens:** SCK only emits on content change; AVAssetWriter duration is defined by appended sample timing.

**How to avoid:** Cache the last complete frame; at stop, re-append it with the stop-time PTS so the file's duration matches reality. For fragment advancement during long static stretches, a low-frequency repeating-frame timer (re-append last frame every few seconds) keeps `movieFragmentInterval` meaningful. Both Nonstrict and ScreenSage shipped this fix.

**Warning signs:** File duration shorter than recording duration; crash-recovery tests lose far more than one fragment interval on static content.

**Phase to address:** Phase 1.

---

### Pitfall 3: Uncapped bitrate (VideoToolbox defaults)

**What goes wrong:** Omitting `AVVideoAverageBitRateKey` (or using `AVOutputSettingsAssistant` presets) produces 40+ Mbps files on Retina screen content — 18+ GB/hr, a disk-eating disaster for meeting-length recordings.

**Why it happens:** Hardware-encoder defaults are tuned for camera video, not screen content (screen BPP is ~0.03–0.1). ScreenSage measured 40+ Mbps default vs ~17 Mbps at its own BPP=0.05 cap.

**How to avoid:** Always set explicit compression properties: HEVC, `AVVideoAverageBitRateKey` ≈ 2–3 Mbps at 10–15 fps / ~1080p class → ~0.5–1.3 GB/hr. Treat a missing bitrate key as a review-blocking defect.

**Warning signs:** A 10-minute test recording over ~300 MB.

**Phase to address:** Phase 1 (encoder config); Phase 2 asserts the guard math against the configured bitrate.

---

### Pitfall 4: Writer dimensions must match stream output dimensions

**What goes wrong:** AVAssetWriterInput configured with logical (point) dimensions while SCStream delivers physical pixels (or vice versa) → encoder errors, scaling artifacts, or appends that silently fail.

**Why it happens:** `SCStreamConfiguration.width/height` are in physical pixels; Retina displays have a 2× (or fractional) `displayScaleFactor` between the SCDisplay/SCWindow frame and the buffers delivered.

**How to avoid:** Compute stream width/height from the target's frame × scale factor and configure the writer input with the *same* values. When downscaling to ~1080p, set the downscaled size in `SCStreamConfiguration` (let SCK scale) so stream and writer always agree.

**Warning signs:** `AVAssetWriter.status == .failed` immediately after first append; blurry or letterboxed output.

**Phase to address:** Phase 1.

---

### Pitfall 5: Window-capture resize mid-recording

**What goes wrong:** In single-window capture, the user resizes the meeting window; SCK starts delivering differently-scaled content, but AVAssetWriter dimensions are fixed at start → distorted/cropped video or writer failure.

**Why it happens:** Writer dimensions are immutable per session; window geometry is not.

**How to avoid:** Make **display capture the default** (per the Settings scoping decision, window capture is user-selectable — document the limitation). For window mode: keep writer dimensions fixed and rely on SCK scaling into the configured size (accepting aspect changes), and handle the update path (`updateContentFilter`/configuration) deliberately. Do not attempt mid-recording writer reconfiguration.

**Warning signs:** QA resize test shows squashed content or a dead stream after resize.

**Phase to address:** Phase 1 (engine behavior) + Phase 3 (Settings copy setting expectations).

---

### Pitfall 6: SCK error -3821 / `didStopWithError` mid-recording

**What goes wrong:** Under sustained multi-hour load SCStream can disconnect with error -3821 (also seen on display sleep, Space changes, display unplug). If `SCStreamDelegate.stream(_:didStopWithError:)` is unhandled, video silently stops while the app believes it is recording — a silent failure, Caddie's cardinal sin.

**Why it happens:** SCK's capture service can drop the stream; documented in ScreenSage's production post-mortem and OBS's SCK plugin handles the same family of errors.

**How to avoid:** Implement `didStopWithError`: finalize the current file cleanly (fragments make it playable), log with context, surface via `lastRecordingError`, and degrade to audio-only (v3.0 baseline). Auto-restart into a continuation file is a v3.x enhancement. Never let the error path leave an unfinalized writer.

**Warning signs:** Long-recording soak test (2+ hr) ends with video shorter than audio and no logged error.

**Phase to address:** Phase 1 (handler + finalize); Phase 2 (error surfacing through coordinator).

---

### Pitfall 7: Crash safety requires `.mov`, not `.mp4` — and finishWriting must not block quit

**What goes wrong:** Two related traps. (a) `movieFragmentInterval` only works with the QuickTime container — set it on an `.mp4` writer and you silently get a non-fragmented file where a crash loses *everything* (plain MP4 writes the moov atom only at `finishWriting`). (b) On successful stop, `finishWriting` runs a defragment/consolidation pass that grows with file length — blocking app termination on it for a multi-hour recording looks like a hang.

**Why it happens:** Fragmenting is a QuickTime-format feature; the defragment-on-finish behavior is documented in Apple forums (threads 74600, 663675).

**How to avoid:** `AVFileType.mov` + `movieFragmentInterval = CMTime(seconds: 10, ...)` set *before* `startWriting`. Run `finishWriting` async; if the user quits mid-finalize, the fragmented file is still playable up to the last fragment — prefer fast quit over blocking. Verify crash-recovery behavior with a kill-9 test: file must open in AVFoundation/QuickTime.

**Warning signs:** Kill-9 during recording leaves an unplayable file; quitting after a long recording beachballs.

**Phase to address:** Phase 1; kill-9 recovery test is a phase gate.

---

### Pitfall 8: macOS 15 monthly re-approval nag

**What goes wrong:** On Sequoia, apps holding Screen Recording permission trigger a monthly system prompt ("Caddie can access this computer's screen"). Users read it as suspicious behavior; support burden follows.

**Why it happens:** OS policy (mjtsai.com 2024-08-08 coverage). The `com.apple.developer.persistent-content-capture` entitlement suppresses it but is granted mainly to remote-desktop apps via an Apple request form — **effectively unobtainable** for Caddie.

**How to avoid:** Accept and message it: onboarding/Settings copy explaining the periodic macOS prompt when screen recording is enabled. Do not architect around it (e.g., SCContentSharingPicker-only flows) — that trades a monthly nag for per-recording friction.

**Warning signs:** n/a — policy, not a bug. Watch for user reports post-release.

**Phase to address:** Phase 3 (UX copy).

---

### Pitfall 9: H.264's 4096×2304 encoder cap on 5K/6K displays

**What goes wrong:** If an H.264 compatibility option is ever exposed, full-res capture of a 5K/6K display exceeds the encoder's 4096×2304 limit → writer failure at start.

**How to avoid:** Default HEVC (no such cap at these sizes) and always downscale to the ~1080p–1440p class anyway (file-size lever). If H.264 is offered, clamp dimensions ≤ 4096×2304.

**Phase to address:** Phase 1 (dimension clamp in config code).

---

### Pitfall 10: Display sleep / Space changes / display unplug

**What goes wrong:** Stream stops or delivers nothing when the captured display sleeps, the user switches Spaces (window capture), or the display is unplugged; naive code hangs waiting for frames or records dead air with wrong duration.

**How to avoid:** These surface as either `didStopWithError` (→ Pitfall 6 path) or frame starvation (→ Pitfall 2 last-frame patching keeps duration honest). Ensure stop/finalize never *waits* on a next frame — stop must be driven by the coordinator, not frame arrival. Mirror the audio path's device-disconnect discipline (`.deviceDisconnected` teardown already exists in the reducer).

**Phase to address:** Phase 1–2.

## Integration Gotchas

| Integration | Common Mistake | Correct Approach |
|-------------|----------------|------------------|
| Swift 6 strict concurrency | Making ScreenRecorder an actor and fighting SCK's delegate queues | Non-Sendable final class confined to the coordinator (AudioRecorder pattern); writer appends on a dedicated serial queue; `@Sendable` cross-actor callbacks (ARCHITECTURE.md Pattern 2) |
| Permissions | Assuming a request API exists | `Permissions.screenRecording` only *checks*; add `CGRequestScreenCaptureAccess()`. Existing TCC grant covers video — no new prompt for onboarded users |
| GRDB migration | Touching FTS5 triggers when adding `video_file` | Plain nullable TEXT column; FTS5 shadow table/triggers (title, transcript, app) untouched |
| Coordinator | Stopping video only in `executeStopAndTranscribe` | Also stop in `executeNotifyError` — the error path already tears down the live-transcription tee there |
| SCStream config | `queueDepth` large "to be safe" | Keep 3–5 and return buffers promptly, or memory pressure builds |
| Audio path | Sharing queues/locks with the audio ring buffer | Zero contact: SCK delivers on its own queues; AVAssetWriter has its own backpressure |

## Performance Traps

| Trap | Symptoms | Prevention | When It Breaks |
|------|----------|------------|----------------|
| Believing video encode will hurt ASR/CPU | (None — trap is over-engineering around a non-problem) | HEVC encode runs on the Media Engine, not CPU/GPU; SCK capture at 60 fps costs ~1.9% of one core, less at 10–15 fps | Never at Caddie's settings; post-meeting FluidAudio ASR dwarfs it |
| Disk exhaustion mid-meeting | Recording fails partway; SCK flaky | Raised start guard (bitrate-derived: 2.5 Mbps ≈ 1.1 GB/hr) + `volumeAvailableCapacityForImportantUsage`; note SCK misbehaves under ~12 GB free (ScreenSage); degrade to audio-only, never the reverse | Multi-hour meetings on nearly-full disks |
| `finishWriting` latency growth | Slow finalize after long recordings | Async finalize, never block quit (Pitfall 7) | Multi-hour recordings |

## "Looks Done But Isn't" Checklist

- [ ] **Kill -9 during recording:** resulting `.mov` opens and plays up to the last fragment
- [ ] **Static-screen recording (5 min of unchanged slide):** file duration matches wall clock
- [ ] **10-minute recording ≤ ~250 MB** at default settings (bitrate cap actually applied)
- [ ] **Video start failure (revoke TCC, then record):** audio recording completes normally; error logged + surfaced, meeting row has no video_file
- [ ] **`didStopWithError` mid-recording:** partial video finalized + playable; audio unaffected; error surfaced
- [ ] **First/last frame timing:** video duration and transcript-seek offsets line up within ~100 ms (anchor persisted)
- [ ] **Deletion:** deleting a meeting removes the `.mov`; storage total includes video
- [ ] **App quit right after stop of a 1-hour recording:** no hang (async finalize)
- [ ] **5K/6K display:** recording starts (dimensions clamped/downscaled)
- [ ] **Window-capture resize:** documented behavior, no writer death

## Pitfall-to-Phase Mapping

| Pitfall | Prevention Phase | Verification |
|---------|------------------|--------------|
| First-frame drop (1) | Phase 1 | Duration test; alignment within tolerance |
| Static-screen duration (2) | Phase 1 | Static-content duration test |
| Uncapped bitrate (3) | Phase 1 | File-size assertion on test recording |
| Dimension mismatch (4) | Phase 1 | Retina + downscale start-up test |
| Window resize (5) | Phase 1/3 | Manual resize QA + Settings copy |
| Error -3821 / didStopWithError (6) | Phase 1–2 | Fault-injection: stop stream externally |
| .mov fragmenting + finalize (7) | Phase 1 | Kill-9 test; quit-latency check |
| Sequoia monthly nag (8) | Phase 3 | Copy review on macOS 15 |
| H.264 resolution cap (9) | Phase 1 | Config clamp unit test |
| Display sleep/Space/unplug (10) | Phase 1–2 | Manual edge-case QA |

## Sources

- nonstrict.eu/blog/2023 "Recording to a file using ScreenCaptureKit" + MIT example repo — first-frame drop, static-screen duration, retiming recipe
- fatbobman.com ScreenSage post-mortem — BPP bitrate capping (0.05 → ~17 Mbps vs 40+ default), error -3821 under multi-hour load, movieFragmentInterval=10 s, static-frame patching, ~12 GB free-disk flakiness
- Apple Developer Forums threads 74600 & 663675 — fragment defragment-on-finish behavior; Apple docs movieFragmentInterval (QuickTime-only)
- mjtsai.com/blog/2024/08/08 — Sequoia monthly prompts + persistent-content-capture entitlement scarcity
- Apple WWDC22 10155/10156 (SCK perf: ~1.9% one core at 60 fps), WWDC20 10011 (fMP4); OBS hybrid-MP4 blog (why fragmented recording survives power loss)
- Azayaka ClassicProcessing.swift (read-only) — dual-path writer structure, HEVC/H.264 bitrate heuristics

---
*Pitfalls research for: Caddie v3.0 Screen Recording*
*Researched: 2026-07-09 via 22-agent workflow sweep + repo verification*

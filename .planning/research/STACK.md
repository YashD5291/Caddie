# Stack Research

**Domain:** macOS screen recording (Caddie v3.0 milestone — video capture additions to an existing Swift 6 audio pipeline)
**Researched:** 2026-07-09 (22-agent workflow sweep + repo verification against live GitHub state)
**Confidence:** HIGH

## Recommended Stack

**Headline: zero new SPM dependencies.** The entire v3.0 stack is Apple system frameworks already linked or trivially linkable. The sweep evaluated 31 candidates (native APIs, SPM libraries, reference apps, commercial SDKs) and verified 16 against live repos — no viable OSS library exists for this feature (see "Why Zero Dependencies" below).

### Core Technologies

| Technology | Availability | Purpose | Why Recommended |
|------------|--------------|---------|-----------------|
| ScreenCaptureKit `SCStream` | macOS 12.3+ | Delivers CMSampleBuffers of a display or window | Apple's canonical capture path; fully available at Caddie's 14.2 floor with no availability guards |
| `SCContentFilter` / `SCShareableContent` | macOS 12.3+ | Programmatic capture-target selection (display, single window, exclude Caddie's own windows) | Supports the Settings-driven display-vs-window choice without any picker UI; `SCContentFilter.includeMenuBar` is exactly 14.2+ |
| `SCStreamConfiguration` | macOS 12.3+ | Resolution, `minimumFrameInterval` (frame-rate throttle), `queueDepth`, cursor, pixel format | 10–15 fps throttling and ~1080p downscale are the levers that make meeting-length files small; `captureResolution` control is 14.0+ |
| AVFoundation `AVAssetWriter` + `AVAssetWriterInput` | all supported | Encodes SCStream buffers to HEVC/H.264 on disk | The mandatory write path at 14.2 (see SCRecordingOutput note); `AVVideoCodecType.hevc` routes to the Apple Silicon Media Engine via VideoToolbox — near-zero CPU |
| `movieFragmentInterval` (QuickTime `.mov`) | all supported | Crash-safe fragmented writing | One property delivers "a crash loses at most the last fragment"; requires the QuickTime container, not `.mp4` |
| AVKit (`VideoPlayer` / `AVPlayerView`) | all supported | In-app playback in MeetingDetailView | Native SwiftUI playback next to the existing audio player; no player dependency needed |
| `SCContentSharingPicker` | macOS 14.0+ | Optional system picker for capture target | Available at 14.2 but **not recommended as the default** — interactive picker clashes with recording start flow; programmatic `SCShareableContent` selection fits better since Caddie already holds the TCC grant |

### Recommended Encoding Configuration

| Setting | Value | Rationale |
|---------|-------|-----------|
| Codec | HEVC (`AVVideoCodecType.hevc`) | 40–60% smaller than H.264 at equal quality; hardware-encoded on every Apple Silicon Mac (14.2+ floor means no software-fallback risk) |
| Frame rate | 10–15 fps (`minimumFrameInterval = CMTime(value: 1, timescale: 10...15)`) | Apple's own WWDC22 guidance for low-motion text/meeting content (~10 fps); fps is the dominant storage lever |
| Bitrate | **Explicit** `AVVideoAverageBitRateKey` ≈ 2–3 Mbps | VideoToolbox/`AVOutputSettingsAssistant` defaults are camera-tuned and produce 40+ Mbps (18+ GB/hr) on screen content — must be capped explicitly |
| Resolution | Display point resolution or ~1080p–1440p downscale | H.264 hard-caps at 4096×2304 (5K/6K displays must downscale); HEVC avoids the cap but downscaling still controls size |
| Container | `.mov` with `movieFragmentInterval` ≈ 10 s | Fragmenting requires QuickTime file type; happy-path finish defragments to a normal moov |
| Result | ~0.5–1.3 GB per meeting-hour | vs QuickTime screen-recording defaults at 6–12 GB/hr (15–25 Mbps H.264) |

## SCRecordingOutput: Not Usable at the 14.2 Floor

macOS 15 Sequoia added `SCRecordingOutput` — attach it to an SCStream and ScreenCaptureKit writes the HEVC `.mov` itself (no AVAssetWriter, no retiming, no static-screen patching). **It is macOS 15+ only.** At Caddie's 14.2 deployment floor the SCStream → AVAssetWriter path is mandatory. An `#available(macOS 15, *)` branch to SCRecordingOutput would add a second code path and testing surface for no user-visible gain; treat it as a *future simplification* (delete the AVAssetWriter code when the minimum eventually moves to 15+), not something to build now. Note also its crash-recovery semantics are undocumented, whereas `movieFragmentInterval` behavior is well understood.

## Why Zero Dependencies

The sweep found **no viable OSS library**: the space is dominated by full apps and license-trapped code. wulkano/Aperture is the only real MIT SPM library — a small (3-file, not 1-file as sometimes claimed: `Aperture.swift` ~27KB, `Devices.swift`, `Utilities.swift`) SCStream → AVAssetWriter wrapper — but it is **dormant since Nov 2024** (v3.0.0 rewrite, zero commits since, ~20 months), swift-tools 5.7 with no Sendable/Swift-6 strict-concurrency audit (would need `@preconcurrency import`), no tests (issue #83), exposes no per-frame timestamp API for transcript alignment, and its wrapper is roughly the same size as writing the code directly. Everything else is an app to study or legally untouchable. Writing ~300–500 lines of owned, Swift-6-native, testable code beats depending on any of it.

## License Landscape (verified against live repos, 2026-07-09)

| Project | License | Stars | Status | Usable As |
|---------|---------|-------|--------|-----------|
| wulkano/Aperture v3 | MIT | 1,303 | Dormant since Nov 2024 (pre-Swift-6) | Reference implementation; vendorable in principle but no advantage over owning the code |
| nonstrict-hq/ScreenCaptureKit-Recording-example | MIT | 63 | Frozen teaching artifact (Sept 2023) | **Primary blueprint** for the SCStream → AVAssetWriter pattern (companion to the Nonstrict blog series documenting first-frame drop + static-screen bugs) |
| jasonzh0/CineScreen | MIT | 27 | Very active (v2.7.0 Jul 2026), macOS 14+ | Pattern reference at exactly Caddie's OS floor; note its "no dropped frames" claim applies to offline export, not live capture — study `Capture/` and `Export/` separately |
| JerryZLiu/Dayflow | MIT | 6,630 | Very active; Swift/SwiftUI/**GRDB**/SCK | Identical stack to Caddie; pattern for low-FPS context capture + timestamps-in-SQLite (now uses `SCScreenshotManager` at ~0.1 fps, not continuous video) |
| jsattler/BetterCapture | MIT | ~1,500 | Very active | Pattern-only — **requires macOS 15.2+**, so its SCRecordingOutput-era paths don't port to 14.2 |
| lihaoyun6/QuickRecorder | **AGPL-3.0** | 8,480 | Slowing (last release Jun 2025) | Do not copy anything — AGPL contamination risk for a public MIT-badged repo |
| Mnpn/Azayaka | **NO LICENSE FILE** (all rights reserved; verified via GitHub API) | 745 | Active-ish | Read-only architectural study; its `ClassicProcessing.swift` is the most compact real-app dual-path (AVAssetWriter 13/14 vs SCRecordingOutput 15+) demo — reimplement ideas, never copy |
| screenpipe/screenpipe | **Proprietary** "Screenpipe Commercial License" (formerly MIT) | 19,700 | Very active (YC S26) | Schema pattern only (video_chunks + frames tables keyed by timestamp) |
| CapSoftware/Cap | **AGPLv3** app / MIT only for `scap-*`/`camera-*` Rust crates | 20,000 | Very active | Rust/Tauri — no SPM path; API-checklist value only |
| lzhgus/Capso | **BUSL-1.1** (→ Apache-2.0 Apr 2029) | ~1,000 | Active, macOS 15+ Swift 6 | Monorepo-internal SPM packages with local-path deps — not remotely consumable regardless of license |
| nonstrict-hq/RecordKit | **Commercial closed-source** binary XCFramework | 4 | Professionally maintained | Disqualified: unauditable blob contradicts Caddie's verify-everything privacy posture |
| wulkano/Kap | MIT | 19,300 | **Dead** (Electron 13, last release Oct 2022) | Nothing — historical validation of old Aperture only |
| jasonjmcghee/rem | MIT | 2,500 | Dormant (May 2024) | Secondary Swift periodic-frame reference; bundles ffmpeg (avoid that pattern) |
| OBS Studio | GPL-2.0 | 73,700 | Very active | Edge-case reference only (`plugins/mac-capture`); GPL, C/C++, ffmpeg pipeline — nothing transfers |

## What NOT to Use

| Avoid | Why | Use Instead |
|-------|-----|-------------|
| `AVCaptureScreenInput` + `AVCaptureMovieFileOutput` | Legacy pre-SCK path; display-only (can't exclude Caddie's windows), and Sonoma shows extra consent alerts for legacy capture APIs | SCStream + AVAssetWriter |
| `CGDisplayStream` | Deprecated in macOS 14.0; triggers extra Sonoma consent alerts | ScreenCaptureKit |
| `SCRecordingOutput` as the only path | macOS 15+ only; Caddie floor is 14.2 | AVAssetWriter path; revisit when floor rises |
| `AVOutputSettingsAssistant` presets / default bitrate | Camera-oriented, 40+ Mbps on screen content | Explicit `AVVideoAverageBitRateKey` 2–3 Mbps |
| ffmpeg sidecar (rem/screenpipe pattern) | Licensing + notarization liability; unnecessary with VideoToolbox | AVAssetWriter hardware encode |
| Muxing audio into the video container | Couples video-writer failure to the audio (violates the "no lost recordings" core value); double-stores audio; WAV is the ASR source of truth | Separate video-only file + stored host-clock offset; optional `AVMutableComposition` mux at export time (no re-encode) |
| Consolidating system audio into the video SCStream | System audio uses CoreAudio process taps (`SystemAudioCapture.swift`), not SCK — rewriting working code for no gain | Independent video-only SCStream with `capturesAudio = false` |

## Version Compatibility (macOS 14.2 floor)

| API | Min macOS | Available at 14.2? |
|-----|-----------|--------------------|
| SCStream / SCContentFilter / SCStreamConfiguration | 12.3 | Yes |
| SCScreenshotManager, SCContentSharingPicker, `captureResolution` | 14.0 | Yes |
| `SCContentFilter.includeMenuBar` | 14.2 | Yes (exactly) |
| `SCRecordingOutput`, `SCStreamConfiguration.captureMicrophone`, presets | 15.0 | **No** |
| `AVAssetWriter.movieFragmentInterval` | long-standing | Yes |
| fMP4 segment delegate (`.mpeg4AppleHLS` + `preferredOutputSegmentInterval`) | 11.0 | Yes (alternative crash-safety pattern; more code, only needed if scrub-while-recording becomes a feature) |

## Permissions

Video capture reuses the **existing Screen Recording TCC grant** — same TCC service Caddie already surfaces in Settings/Onboarding; users who passed onboarding can start video capture with no new prompt. Gap: `Permissions.screenRecording` (Sources/Utilities/Permissions.swift) only *checks* (CGWindowListCopyWindowInfo inference), it never *requests* — add `CGRequestScreenCaptureAccess()`. Caveat: on macOS 15 Sequoia, apps holding Screen Recording get a **monthly re-approval nag**; the `com.apple.developer.persistent-content-capture` entitlement suppresses it but Apple grants it mainly to remote-desktop apps via a request form — plan UX messaging instead.

## Sources

- developer.apple.com/documentation/screencapturekit (SCStream, SCContentFilter, SCRecordingOutput availability)
- Apple WWDC22 10155/10156 (SCK performance, fps guidance for text content); WWDC24 10088 (SCRecordingOutput); WWDC20 10011 (fragmented MP4 authoring)
- nonstrict.eu blog series "Recording to a file using ScreenCaptureKit" + MIT example repo — first-frame drop, static-screen duration
- fatbobman.com ScreenSage post-mortem — BPP bitrate capping, SCK error -3821, `movieFragmentInterval` = 10 s in production
- GitHub API license/activity verification of all 16 repos above (2026-07-09)

---
*Stack research for: Caddie v3.0 Screen Recording*
*Researched: 2026-07-09 via 22-agent workflow sweep + repo verification*

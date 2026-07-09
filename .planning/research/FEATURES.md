# Feature Research

**Domain:** Screen recording in on-device meeting recorders / privacy-first capture apps (Caddie v3.0)
**Researched:** 2026-07-09 (22-agent workflow sweep + repo verification)
**Confidence:** HIGH

## Category Finding: Video Is a Differentiator, Not a Catch-Up

**No open-source meeting recorder in Caddie's category records screen video.** Verified via GitHub code search: Anarlog/Hyprnote (fastrepl, 8.8k stars, MIT) has zero ScreenCaptureKit references — audio only (Core Audio process taps, same 14.2+ API family as Caddie). Meetily (21.9k stars, MIT) is audio-only with auto meeting detection still an open feature request (issue #387 — Caddie already ships it). Video in the on-device/privacy space comes from two *adjacent* lineages, neither of which is a meeting recorder:

1. **Rewind-style lifeloggers** — screenpipe (0.5–1 fps adaptive, MP4 chunks + SQLite frame index), Dayflow (screenshots every ~10 s via SCScreenshotManager, timelapse on demand), rem (0.5 fps screenshots + OCR)
2. **Generic SCK recorders** — QuickRecorder, Azayaka, BetterCapture: full-motion HEVC/H.264 recording of a user-picked display/window/area

By adding transcript-aligned meeting video, Caddie is differentiating, not copying.

## The Product-Pattern Spectrum

| Pattern | Examples | FPS | Storage | Fit for Caddie |
|---------|----------|-----|---------|----------------|
| Full-motion continuous | QuickRecorder, Azayaka, BetterCapture, QuickTime | 30–60 | 1.8–12 GB/hr | Overkill — meeting content is static slides + webcam grid |
| **Low-FPS full video (chosen)** | Apple WWDC22 guidance for text content | 10–15 | ~0.5–1.3 GB/hr (HEVC, 2–3 Mbps cap) | **Sweet spot: scrubable real video, legible text, meeting-sized files** |
| Context frames / timelapse | Dayflow (~0.1 fps), screenpipe (0.5–1 fps), rem, Rewind (sub-1 fps, GBs/year) | ≤1 | 50–150 MB/hr or less | Fallback "minimal storage" mode later — same pipeline, different `minimumFrameInterval`; not real video, users expecting playback would be disappointed |

Encoding anchors: QuickTime default screen recording = 15–25 Mbps H.264 → **6–12 GB/hr (the anti-pattern)**. Uncapped VideoToolbox defaults → 40+ Mbps (18+ GB/hr on Retina). Zoom local recording ≈ 0.5–2.4 GB/hr for 1080p group calls. Caddie target: HEVC 10–15 fps, explicit 2–3 Mbps cap → **~0.5–1.3 GB per meeting-hour**.

## Feature Landscape

### Table Stakes (Users Expect These)

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| Record-screen on/off toggle | Video must be opt-in for a privacy-first app; every recorder has it | LOW | Settings toggle via the `MeetingPromptSettings` shared-enum UserDefaults pattern (see ARCHITECTURE.md) |
| Capture-target selection (display vs window) | Every SCK recorder (QuickRecorder/Azayaka/BetterCapture) offers it; users don't want their whole desktop captured by default | MEDIUM | Scoped decision: user-selectable in Settings. Display capture is the *safer default* — window capture has a mid-recording resize problem (PITFALLS.md) |
| In-app playback | A video file you can't watch in-app feels broken; audio player already exists in MeetingDetailView | MEDIUM | AVKit `VideoPlayer`/`AVPlayerView` alongside the existing AudioPlayerView |
| File management + deletion | Existing deleteAudio flow must also remove video; storage totals must include video | LOW | Extend `AudioFileManager.deleteAudio(meetingId:)`; `totalStorageUsed()` already sums the directory |
| Disk-space guard | Video is ~GB/hr; recording to a full disk corrupts the core promise | LOW | Raise the coordinator's 500 MB `minimumDiskSpaceBytes` when video enabled; bytes/hr is predictable from the bitrate cap (2.5 Mbps ≈ 1.1 GB/hr). Note SCK itself gets flaky under ~12 GB free (ScreenSage) |
| Graceful degradation to audio-only | Core value: video failure must never lose the meeting audio | LOW | Established LiveTranscriber pattern in `executeStartRecording` — log + continue |

### Differentiators (Competitive Advantage)

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| **Screen video at all** | No OSS meeting recorder has it — unique in category | HIGH | The milestone itself |
| Transcript-time-aligned video | "What was on screen when X was said" — jump from a transcript segment to the video moment | MEDIUM | SCK sample buffers and CoreAudio callbacks share the mach host clock; store first-video-frame vs audio-start host-time delta in the meetings row; alignment is pure arithmetic (drift is ppm-level over an hour). No library exposes this — native-API advantage |
| Crash-safe recording | A crash loses at most the last ~10 s fragment, never the file | LOW–MEDIUM | `movieFragmentInterval` on a `.mov` container; crashed files still play in AVFoundation/QuickTime up to the last fragment |
| Meeting-sized files by default | 5–10× smaller than QuickTime defaults without user tuning | LOW | HEVC + fps throttle + explicit bitrate cap (config, not code) |
| Zero new permission prompt | Existing Screen Recording TCC grant covers SCK video | LOW | Same TCC service already used for the system-audio story; onboarding users are pre-cleared |

### Anti-Features (Commonly Requested, Often Problematic)

| Feature | Why Requested | Why Problematic | Alternative |
|---------|---------------|-----------------|-------------|
| Uncapped/default bitrate ("best quality") | "Just record at full quality" | VideoToolbox defaults are camera-tuned: 40+ Mbps → 18+ GB/hr; QuickTime's 6–12 GB/hr is the category anti-pattern | Explicit 2–3 Mbps HEVC cap; quality is fine for slides + webcam grid |
| Always-on / auto-start capture | Lifelogger envy (Rewind, screenpipe) | Contradicts v2.0's deliberate product shift to user-initiated recording; privacy expectations for screen ≫ audio; macOS 15 monthly re-approval nag punishes always-on capture apps | Video piggybacks the existing manual/notification-driven recording lifecycle only |
| Cloud upload / sharing links (Loom-style, à la Cap) | Category-adjacent products do it | Violates the core "nothing leaves the device" value | Local file; optional export/mux at share time |
| Muxed audio+video single file | "One file is tidier" | Couples video-writer failure to audio (violates no-lost-recordings); double-stores audio; WAV is the ASR source of truth | Separate video-only file + stored clock offset; `AVMutableComposition` mux at export (no re-encode) if ever needed |
| Interactive system picker (SCContentSharingPicker) at record start | Apple-blessed consent UX | Friction at every recording start; Caddie already holds the TCC grant; picker state is global with per-stream quirks | Settings-level target choice + programmatic `SCShareableContent` selection |
| 30–60 fps "smooth" recording | Smoother motion | 2–3× the file size for content that is mostly static; Apple's own guidance for text content is ~10 fps (prioritize resolution over fps for legibility) | 10–15 fps default |

## Feature Dependencies

```
Settings toggle + target choice
    └──gates──> ScreenRecorder capture engine (SCStream → AVAssetWriter)
                    └──requires──> crash-safe writer (.mov + movieFragmentInterval)
                    └──requires──> disk guard raise (coordinator)
                    └──produces──> video file + host-clock anchor
                                       └──requires──> video_file column + timestamp migration
                                                          └──enables──> in-app AVKit playback
                                                          └──enables──> transcript-time alignment (seek video from segment)
File deletion extension ──requires──> videoPath(for:) in AudioFileManager
Graceful degradation ──conflicts──> muxed audio+video container (must stay separate files)
```

### Dependency Notes

- **Playback requires storage schema:** MeetingDetailView can only show a player if `Meeting.videoFile` is queryable; migration precedes UI.
- **Alignment requires anchors captured at record time:** the host-clock delta cannot be reconstructed after the fact — it must be persisted in phase 1/2, even if the seek UI ships later.
- **Degradation conflicts with muxing:** keeping video strictly additive (separate file, optional dependency) is what makes "video failure never aborts audio" cheap to guarantee.

## MVP Definition

### Launch With (v3.0)

- [ ] Settings toggle ("Record screen") + display-vs-window target choice — gates everything, privacy-first opt-in
- [ ] ScreenRecorder: SCStream → AVAssetWriter, HEVC 10–15 fps, explicit 2–3 Mbps cap — the capture engine
- [ ] Crash-safe fragmented `.mov` — core value ("no lost recordings") applies to video from day one
- [ ] Graceful degradation to audio-only on any video failure — core value
- [ ] `video_file` + host-clock anchor columns; deletion + storage accounting extended — no orphaned files
- [ ] In-app AVKit playback in MeetingDetailView — video you can't watch is not a feature
- [ ] Raised disk guard when video enabled

### Add After Validation (v3.x)

- [ ] Transcript-segment → video seek (tap a segment, video jumps there) — anchors are already persisted; pure UI arithmetic
- [ ] Export/share flow for video (optional mux with audio via AVMutableComposition)
- [ ] Mid-recording disk-space polling with automatic video stop (degrade to audio, never the reverse)

### Future Consideration (v4+)

- [ ] "Minimal storage" context-frames mode (1–2 s `minimumFrameInterval`, tens of MB/hr) — Dayflow/screenpipe pattern, same pipeline
- [ ] SCRecordingOutput simplification when the OS floor moves to macOS 15+
- [ ] Stream auto-restart into a new fragment on SCK error -3821 for multi-hour robustness (basic didStopWithError handling ships in v3.0; seamless segment stitching can come later)

## Feature Prioritization Matrix

| Feature | User Value | Implementation Cost | Priority |
|---------|------------|---------------------|----------|
| Capture engine + crash-safe writer | HIGH | HIGH | P1 |
| Settings toggle + target choice | HIGH | LOW | P1 |
| Graceful degradation | HIGH (invisible until it saves a meeting) | LOW | P1 |
| Storage schema + file lifecycle | HIGH | LOW | P1 |
| AVKit playback | HIGH | MEDIUM | P1 |
| Disk guard raise | MEDIUM | LOW | P1 |
| Transcript-time seek | HIGH (the differentiator payoff) | MEDIUM | P2 |
| Export/mux | MEDIUM | MEDIUM | P2 |
| Context-frames mode | LOW–MEDIUM | LOW (config) | P3 |

## Competitor Feature Analysis

| Feature | Anarlog/Meetily (meeting recorders) | QuickRecorder/BetterCapture (SCK recorders) | screenpipe/Dayflow (lifeloggers) | Caddie v3.0 |
|---------|-------------------------------------|---------------------------------------------|----------------------------------|-------------|
| Screen video | None | Full-motion, user-triggered | Continuous low-FPS frames | Optional per-meeting, 10–15 fps HEVC |
| Transcript alignment | n/a (no video) | n/a (no transcript) | Timestamp tables in SQLite | Host-clock delta in meetings row → segment-accurate seek |
| Crash safety | n/a | Mostly none (plain finishWriting) | Per-chunk files | Fragmented `.mov` |
| Privacy | Local-first | Local | screenpipe: proprietary/cloud-optional | Fully local, opt-in toggle |

## Sources

- GitHub code search + repo verification (2026-07-09): fastrepl/anarlog (zero SCK refs), Zackriya-Solutions/meetily (issue #387), screenpipe schema (`video_chunks`/`frames`), Dayflow `ScreenRecorder.swift` rewrite comment
- kevinchen.co Rewind.ai teardown (fps as dominant storage lever); Zoom recording-size support docs; Apple WWDC22 fps guidance
- Encoding math: bitrate ≈ pixels × fps × BPP (screen content BPP ~0.03–0.1 H.264, HEVC ~40% lower); ScreenSage production BPP=0.05 cap

---
*Feature research for: Caddie v3.0 Screen Recording*
*Researched: 2026-07-09 via 22-agent workflow sweep + repo verification*

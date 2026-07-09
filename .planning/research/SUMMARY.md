# Project Research Summary

**Project:** Caddie — v3.0 Screen Recording milestone
**Domain:** macOS screen recording (ScreenCaptureKit) integrated into an existing Swift 6 on-device meeting recorder
**Researched:** 2026-07-09
**Confidence:** HIGH (22-agent workflow sweep; 16 candidates verified against live GitHub repos; integration points verified by full codebase read)

## Executive Summary

Caddie should build screen recording **natively with zero new dependencies**: a video-only `SCStream` feeding an `AVAssetWriter` (hardware HEVC via the Media Engine), written as a new `ScreenRecorder` final class in Sources/Recording/ and injected into the `RecordingCoordinator` actor as an optional dependency — the exact shape `LiveTranscriber` already uses. The sweep evaluated 31 candidates and verified 16 against real repos; there is no viable OSS library. The only MIT SPM package (wulkano/Aperture v3) is dormant since Nov 2024 and pre-Swift-6; everything else is a full app or license-trapped (QuickRecorder AGPL, Azayaka unlicensed, screenpipe proprietary, Cap AGPL-mixed, Capso BUSL, RecordKit commercial). MIT references (Aperture, nonstrict-hq/ScreenCaptureKit-Recording-example, CineScreen) serve as blueprints only. `SCRecordingOutput` — Apple's easy record-to-file path — is macOS 15+ and unusable at the 14.2 floor, which makes the SCStream → AVAssetWriter path mandatory and the ~300–500 lines of owned writer code the central engineering work.

The product finding is that **no open-source meeting recorder records video** — Anarlog and Meetily are audio-only (verified via code search) — so this milestone is a category differentiator, and the transcript-time-aligned playback is its payoff: SCK sample buffers and CoreAudio callbacks share the mach host clock, so persisting a first-frame vs audio-start delta in the meetings row gives segment-accurate video seek with pure arithmetic. Recommended defaults (HEVC, 10–15 fps, explicit 2–3 Mbps cap, ~1080p class) yield ~0.5–1.3 GB per meeting-hour versus QuickTime's 6–12 GB/hr, at near-zero CPU.

The main risks are well-documented AVAssetWriter/SCK sharp edges — first-frame drop, static-screen duration bug, uncapped VideoToolbox bitrate defaults, `.mov`-only fragmenting, stream death (error -3821) — every one of which has a known prevention from shipping apps (Nonstrict, ScreenSage, Azayaka). The architecture risk is Swift 6 strict concurrency around SCK's background-queue delegates; the mitigation is the established AudioRecorder confinement pattern plus a dedicated writer queue, with a spike budgeted early. Video must be strictly additive: start after audio succeeds, degrade gracefully, never abort the meeting.

## Key Findings

### Recommended Stack

Zero new SPM dependencies; all Apple frameworks available at the 14.2 floor (see STACK.md).

**Core technologies:**
- ScreenCaptureKit (`SCStream`/`SCContentFilter`/`SCStreamConfiguration`/`SCShareableContent`, 12.3+; `SCContentSharingPicker` 14.0+ but not the default UX): capture + programmatic display-vs-window targeting
- AVFoundation `AVAssetWriter` + `movieFragmentInterval` on `.mov`: in-flight hardware HEVC encode, crash-safe fragments — mandatory path since `SCRecordingOutput` is macOS 15+
- AVKit (`VideoPlayer`): in-app playback in MeetingDetailView, no player dependency

### Expected Features

**Must have (table stakes):** opt-in Record-screen toggle + capture-target choice (display default), in-app playback, deletion/storage accounting for video, raised disk guard, graceful degradation to audio-only.

**Should have (differentiators):** transcript-time-aligned video seek (host-clock anchors — persist them from day one even if the seek UI ships later), crash-safe fragments, meeting-sized files by default. No competitor in category has any of this.

**Defer (v3.x+):** segment-tap-to-video-seek polish, export/mux (AVMutableComposition, no re-encode), mid-recording disk polling, low-FPS "context frames" mode, SCRecordingOutput swap when the floor reaches macOS 15.

**Anti-features:** uncapped bitrate, always-on capture, cloud upload, muxed A/V container, per-recording picker friction.

### Architecture Approach

Independent video-only SCStream (system audio stays on CoreAudio process taps — do not consolidate), owned by a non-Sendable `ScreenRecorder` final class confined to the RecordingCoordinator actor, delegate callbacks on SCK's background queues appending to the writer on a dedicated serial queue. No new reducer states — video piggybacks `.startRecording`/`.stopAndTranscribe` side effects and stops in both `executeStopAndTranscribe` and `executeNotifyError` (see ARCHITECTURE.md for the twelve file:symbol integration points, all verified against source).

**Major components:**
1. `Sources/Recording/ScreenRecorder` (new) — SCStream → AVAssetWriter engine, fragments, anchors, error handling
2. `RecordingCoordinator` (modified) — optional injection, start-after-audio, stop/error wiring, raised disk guard
3. Storage (modified) — `v2_add_video_file` migration (nullable TEXT + host-clock anchor, **not** in FTS5), `Meeting.videoFile`, `AudioFileManager.videoPath(for:)` + deletion
4. UI (modified) — Settings toggle/target (MeetingPromptSettings pattern), AVKit player in MeetingDetailView; `Permissions` gains `CGRequestScreenCaptureAccess()`

### Critical Pitfalls

1. **First-frame drop** — start writer session at `.zero` and retime buffers against the first frame's PTS (never "start at now")
2. **Static-screen duration bug** — SCK stops emitting on static content; cache and re-append the last frame at stop (and periodically, to keep fragments advancing)
3. **Uncapped bitrate** — VideoToolbox defaults are 40+ Mbps on screen content; explicit `AVVideoAverageBitRateKey` 2–3 Mbps is non-negotiable
4. **Crash safety needs `.mov`** — `movieFragmentInterval` is QuickTime-only; async `finishWriting` (defragment pass grows with duration — never block quit)
5. **Stream death (error -3821 / didStopWithError)** — finalize + surface + degrade to audio-only; silent video loss is the failure mode Caddie exists to prevent
6. **macOS 15 monthly re-approval nag** — unavoidable (persistent-content-capture entitlement effectively unobtainable); handle with UX copy, not architecture

## Implications for Roadmap

Suggested phase structure:

### Phase 1: ScreenRecorder capture engine + crash-safe writer
**Rationale:** All the sharp edges live here and it has zero schema/UI dependencies — de-risk first. Includes the Swift 6 delegate-isolation spike.
**Delivers:** `ScreenRecorder` recording a display/window to fragmented `.mov` (HEVC, fps/bitrate-capped), first-frame + audio host-clock anchor capture, `didStopWithError` finalize, dimension clamping.
**Addresses:** capture engine, crash-safe fragments, meeting-sized files.
**Avoids:** Pitfalls 1–7, 9 (first-frame, static-screen, bitrate, dimensions, resize behavior, stream death, fragmenting/finalize, H.264 cap). Gate on the kill-9 and static-screen tests.

### Phase 2: Coordinator, storage, and permissions integration
**Rationale:** Wiring into the hardened lifecycle; storage before UI because playback queries the schema.
**Delivers:** Optional injection into RecordingCoordinator (start-after-audio-success, graceful degradation, stop in both stop and error paths), `v2_add_video_file` migration + `Meeting.videoFile` + anchor column, `videoPath(for:)` + deletion/storage accounting, raised disk guard, `CGRequestScreenCaptureAccess()`.
**Uses:** LiveTranscriber injection pattern, MeetingPromptSettings persistence pattern, GRDB append-only migrations (FTS5 untouched).
**Avoids:** silent-failure violations; orphaned video files; disk exhaustion.

### Phase 3: Settings + playback UI + alignment
**Rationale:** User-facing surface last, on top of a proven engine and schema.
**Delivers:** Record-screen toggle + display-vs-window choice in SettingsView, AppState gating, AVKit player in MeetingDetailView beside the audio player, transcript-segment → video seek using the stored anchor, macOS 15 nag messaging, README update.
**Addresses:** table-stakes UX + the alignment differentiator.
**Avoids:** Pitfall 8 (copy), Pitfall 5 (window-capture expectations).

### Phase Ordering Rationale

- Engine → storage → UI follows the dependency chain (playback needs schema; schema needs files worth pointing at).
- Alignment anchors are *captured* in Phase 1 but *consumed* in Phase 3 — they cannot be reconstructed retroactively, so they are a Phase 1 requirement despite being a Phase 3 feature.
- Graceful degradation lands with the coordinator wiring (Phase 2) so no user-visible toggle exists before the safety net does (Phase 3 exposes the toggle).

### Research Flags

- **Phase 1:** Swift 6 strict-concurrency shape for SCK delegates + writer queue deserves a short spike before committing the design; also verify fragment behavior empirically with kill-9 on 14.x and 15.x.
- **Phase 3:** Transcript-seek UX has no in-category precedent to copy — small design exploration warranted.
- **Phases with standard patterns (skip research-phase):** Phase 2 — every integration point is documented file:symbol against current source in ARCHITECTURE.md; migration/injection/persistence patterns all have in-repo precedents.

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | License/activity of all 16 repos verified via GitHub API on 2026-07-09; API availability from Apple docs |
| Features | HIGH | Category claims verified by code search (zero SCK refs in Anarlog); encoding numbers cross-checked against shipping-app data and Apple guidance |
| Architecture | HIGH | All integration points read from current Caddie source, cited file:symbol |
| Pitfalls | HIGH | Every pitfall traced to a shipping app post-mortem, Apple docs, or forum-documented behavior |

**Overall confidence:** HIGH

### Gaps to Address

- **Swift 6 concurrency shape for SCK delegates:** researched at pattern level, not compiled — Phase 1 spike.
- **Fragmented `.mov` recovery semantics on 14.2 specifically:** documented behavior, but the kill-9 recovery test should run on the actual floor OS as a phase gate.
- **Window-capture resize behavior:** known problem, chosen mitigation (display default + documented limitation) is a product judgment to confirm during Phase 3 UX.
- **Repo LICENSE file:** the codebase read noted Caddie's repo declares MIT in README but has no LICENSE file — worth fixing this milestone since license hygiene drove several reference-code decisions.

## Sources

### Primary (HIGH confidence)
- Apple: developer.apple.com/documentation/screencapturekit; WWDC22 10155/10156, WWDC24 10088, WWDC20 10011; AVAssetWriter/movieFragmentInterval docs
- Caddie codebase read 2026-07-09 (Coordinator, Recording, Storage, Utilities, UI, project.yml)
- GitHub API verification of 16 repos (licenses, activity, source spot-checks) — 2026-07-09

### Secondary (MEDIUM-HIGH confidence)
- nonstrict.eu SCK recording blog series + MIT example repo (first-frame, static-screen recipes)
- fatbobman.com ScreenSage production post-mortem (bitrate capping, error -3821, fragment interval, disk flakiness)
- mjtsai.com 2024-08-08 (Sequoia monthly prompts); Apple forums 74600/663675 (defragment-on-finish)

### Tertiary (LOW confidence — directional only)
- kevinchen.co Rewind teardown; Zoom recording-size support docs; OBS hybrid-MP4 blog

---
*Research completed: 2026-07-09 via 22-agent workflow sweep + repo verification*
*Ready for roadmap: yes*

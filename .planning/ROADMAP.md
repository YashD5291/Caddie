# Roadmap: Caddie

## Milestones

- ✅ **v1.0 Production Hardening** — Phases 1–10 (shipped 2026-03-24) — [archive](milestones/v1.0-ROADMAP.md)
- ✅ **v2.0 Google Calendar + Remote Meeting Recording** — Phases 11–17 (shipped 2026-07-01, released v1.1.0→v1.2.1) — [archive](milestones/v2.0-ROADMAP.md)
- 🚧 **v3.0 Screen Recording** — Phases 18–21 (in progress, started 2026-07-09)

## Notes

- v2.0 delivered Google Calendar integration (OAuth, polling, Today's Schedule), calendar-triggered recording via a configurable pre-meeting notification prompt, user-selectable audio devices with mid-recording hot-swap, live transcription, and Sparkle auto-updates. Requirements 13/13 addressed (2 satisfied-with-deviation); see `milestones/v2.0-MILESTONE-AUDIT.md`.
- Phases 11–13 ran through the GSD phase flow; phases 14–17 shipped on feature branches (PRs #2–#8) and are recorded in MILESTONES.md and the v2.0 audit rather than as phase directories.
- v3.0 adds optional screen video capture during meeting recordings — native ScreenCaptureKit (SCStream → AVAssetWriter), zero new dependencies, crash-safe fragmented `.mov`, transcript-time-aligned playback. Video is strictly additive: it starts only after audio succeeds and degrades to audio-only on any failure.

## v3.0 Screen Recording (Phases 18–21)

**Milestone Goal:** Optionally capture screen video alongside audio during meeting recordings — native ScreenCaptureKit, on-device, crash-safe, time-aligned with the transcript. Video never compromises the audio path.

**Phase Numbering:**

- Integer phases (18, 19, 20, 21): Planned milestone work
- Decimal phases (e.g., 18.1): Urgent insertions (marked with INSERTED)

### Phases

- [x] **Phase 18: Screen Capture Engine** - Standalone `ScreenRecorder` writes a crash-safe, bitrate-capped HEVC `.mov` with timing anchors (completed 2026-07-09)
- [ ] **Phase 19: Recording Lifecycle Integration** - Video starts/stops with the meeting and can never take down the audio recording
- [ ] **Phase 20: Video Storage & Retention** - Video files linked to meetings, deleted with them, and guarded against disk exhaustion
- [ ] **Phase 21: Settings, Playback & Alignment** - User controls, in-app AVKit playback, transcript-seek, and export

## Phase Details

### Phase 18: Screen Capture Engine

**Goal**: A standalone `ScreenRecorder` records a display or window to a crash-safe, bitrate-capped HEVC `.mov` with correct timing anchors — the risk-bearing core, validated in isolation before any wiring.
**Depends on**: Phase 17 (existing recording infrastructure)
**Requirements**: VID-05, VID-06, VID-07, STOR-04
**Success Criteria** (what must be TRUE):

  1. `ScreenRecorder` records a display to a playable HEVC `.mov` at a chosen preset (compact ~10 fps / balanced ~15 fps / high ~30 fps) with bitrate held to the preset's explicit cap
  2. Caddie's own windows never appear in the recorded video (SCContentFilter exclusion)
  3. Force-killing the process mid-recording (kill -9) leaves a playable file missing at most the last ~10 seconds (fragmented `.mov`)
  4. Each recording persists a host-clock anchor tying the first video frame to the audio start time
  5. First-frame and static-screen edge cases produce correct-duration output (no dropped first frame, no truncated tail)

**Plans**: 4 plans

- [x] 18-01-PLAN.md — Concurrency spike + engine types & all pure config/dimension/anchor/filter logic (TDD)
- [x] 18-02-PLAN.md — Live SCStream -> AVAssetWriter engine (first-frame, static-screen keepalive, stop, didStopWithError)
- [x] 18-03-PLAN.md — kill-9 recovery gate + DEBUG record/validate harness (VID-07)
- [x] 18-04-PLAN.md — Manual verification checkpoint (real capture, VID-05 exclusion, static duration, anchor)

**Research flag**: Swift 6 strict-concurrency shape for SCK background-queue delegates + dedicated writer queue warrants a short spike before committing the design; verify fragment recovery empirically with a kill-9 gate on the 14.2 floor.

### Phase 19: Recording Lifecycle Integration

**Goal**: Screen capture is injected into `RecordingCoordinator` so it starts and stops with every meeting recording (manual and calendar-prompted alike) and can never take down the audio recording.
**Depends on**: Phase 18
**Requirements**: VID-03, VID-04
**Success Criteria** (what must be TRUE):

  1. When a meeting recording starts (manual or calendar-prompted), video capture begins after audio starts successfully and stops when the meeting stops
  2. Both stop paths (normal stop and error) finalize the video file cleanly
  3. A forced video-capture failure is logged and surfaced, and the audio recording still completes normally (degrades to audio-only)
  4. No video file is left open or corrupted when a meeting ends

**Plans**: TBD

### Phase 20: Video Storage & Retention

**Goal**: Video files are linked to their meeting, cleaned up on deletion, and guarded against disk exhaustion — no orphans, no FTS5 contamination.
**Depends on**: Phase 19
**Requirements**: STOR-01, STOR-02, STOR-03
**Success Criteria** (what must be TRUE):

  1. A recorded meeting's row references its video via a nullable `video_file` column that is absent from the FTS5 index
  2. Deleting a meeting removes both its audio and video files from disk
  3. Starting a recording is blocked pre-start when free disk space is below the raised video threshold (above the current 500 MB)
  4. Meetings recorded audio-only leave `video_file` null with no storage side effects

**Plans**: TBD

### Phase 21: Settings, Playback & Alignment

**Goal**: Users control screen recording, watch it in-app aligned to the transcript, and export it — the complete user-facing surface on top of a proven engine and schema.
**Depends on**: Phase 20
**Requirements**: VID-01, VID-02, PLAY-01, PLAY-02, PLAY-03, EXP-01
**Success Criteria** (what must be TRUE):

  1. Settings has a "Record screen" toggle (off by default) and a capture-target choice (full display vs meeting window), and the Screen Recording permission is requested when first enabled
  2. A meeting with video shows an in-app AVKit player in the detail view beside the existing audio player
  3. Clicking a transcript segment seeks the video to that moment using the stored host-clock anchor
  4. Meetings without video keep the existing audio-only detail view unchanged
  5. The video file can be exported via the existing export sheet

**Plans**: TBD
**UI hint**: yes
**Research flag**: Transcript-segment → video-seek UX has no in-category precedent to copy — a small design exploration is warranted.

## Progress

**Execution Order:**
Phases execute in numeric order: 18 → 19 → 20 → 21

| Phase | Milestone | Plans Complete | Status | Completed |
|-------|-----------|----------------|--------|-----------|
| 1–10. Production Hardening | v1.0 | — | ✅ Complete | 2026-03-24 |
| 11–17. Calendar + Remote Recording | v2.0 | — | ✅ Complete | 2026-07-01 |
| 18. Screen Capture Engine | v3.0 | 4/4 | Complete    | 2026-07-09 |
| 19. Recording Lifecycle Integration | v3.0 | 0/TBD | Not started | - |
| 20. Video Storage & Retention | v3.0 | 0/TBD | Not started | - |
| 21. Settings, Playback & Alignment | v3.0 | 0/TBD | Not started | - |

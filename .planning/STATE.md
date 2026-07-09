---
gsd_state_version: 1.0
milestone: v3.0
milestone_name: Screen Recording
status: roadmap created
stopped_at: Roadmap created — Phases 18–21 defined, awaiting phase planning
last_updated: "2026-07-09"
last_activity: 2026-07-09
progress:
  total_phases: 4
  completed_phases: 0
  total_plans: 0
  completed_plans: 0
---

# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-07-09)

**Core value:** Every meeting must be reliably captured, transcribed, and retrievable -- no silent failures, no lost recordings, no data corruption.
**Current focus:** Milestone v3.0 Screen Recording — roadmap created (Phases 18–21)

## Current Position

Phase: 18 — Screen Capture Engine (not started)
Plan: —
Status: Roadmap created — awaiting phase planning (`/gsd:plan-phase 18`)
Last activity: 2026-07-09 — ROADMAP.md written, 15/15 requirements mapped across 4 phases

## Performance Metrics

**Velocity (v1.0):**

- Total plans completed: 19
- Average duration: ~9 min
- Total execution time: ~2.8 hours

**Recent Trend (v2.0 phases):**

| Phase 11 P01 | 29min | 2 tasks | 5 files |
| Phase 12 P01 | 23min | 1 tasks | 3 files |
| Phase 12 P02 | 35min | 2 tasks | 7 files |
| Phase 13 P01 | 26min | 2 tasks | 6 files |

## Accumulated Context

### Decisions

Decisions are logged in PROJECT.md Key Decisions table.
Recent decisions affecting current work:

- [v3.0 Roadmap 2026-07-09]: 4 phases (18–21) — capture engine first (risk-bearing core, validated standalone), then coordinator lifecycle, then storage/retention, then user-facing Settings/playback/alignment
- [v3.0 Research 2026-07-09]: Zero new SPM dependencies for screen recording — native SCStream + AVAssetWriter (no viable OSS library exists; Aperture/nonstrict example are MIT pattern references only)
- [v3.0 Research]: SCRecordingOutput is macOS 15+ — AVAssetWriter path mandatory at the 14.2 deployment floor
- [v3.0 Research]: Video is an independent video-only SCStream; system audio stays on CoreAudio process taps (do NOT consolidate)
- [v3.0 Research]: HEVC hardware encode, 10–15 fps, explicit 2–3 Mbps bitrate cap (~0.5–1.3 GB/hr); uncapped VideoToolbox defaults produce 40+ Mbps files
- [v3.0 Research]: Crash safety via .mov + movieFragmentInterval (~10 s) — satisfies no-lost-recordings core value
- [v3.0 Research]: Time alignment via shared mach host clock — persist first-frame host timestamp next to audio start time
- [v3.0 Scoping]: Capture target (full display vs meeting window) is user-selectable in Settings
- [v3.0 Scoping]: In-app video playback in MeetingDetailView (AVKit)
- [v2.0]: Recording is user-initiated (manual / calendar prompt); auto-detection removed as trigger

### Pending Todos

- User-side manual checks from v2.0 still open: Sparkle update offer (1.2.1 → 1.2.2) and live-transcription mic test

### Blockers/Concerns

- Phase 18 research flag: Swift 6 strict-concurrency shape for SCK background-queue delegates + writer queue needs a spike before committing the design; kill-9 fragment-recovery gate must run on the 14.2 floor
- Phase 21 research flag: transcript-segment → video-seek UX has no in-category precedent to copy — small design exploration warranted
- SCStream sharp edges to handle: first-frame drop (retime session to zero), static-screen duration bug (re-append last frame at stop), window-capture resize behavior, SCK error -3821 stream restarts
- macOS 15+ monthly screen-recording re-approval nag — needs UX messaging
- Disk guard (500 MB) must be raised when video is enabled

### Quick Tasks Completed

| # | Description | Date | Commit | Directory |
|---|-------------|------|--------|-----------|
| 260610-1ur | Fix 7 code-review findings: calendar signal loss, switchDevice WAV finalization, notification title, error-state handling, LoadingOverlay task leak, RT-thread allocations, dead dismiss code | 2026-06-09 | cfc4cad | [260610-1ur-fix-7-confirmed-code-review-findings-cal](./quick/260610-1ur-fix-7-confirmed-code-review-findings-cal/) |
| 260610-nnu | Release prep v1.1.0: externalize Google OAuth secret to gitignored file, guard against runtime sortformer download, bump version, commit branch work in 8 atomic chunks (secret-free, tests green) | 2026-06-10 | b2cebbb | [260610-nnu-release-prep-v1-1-0-externalize-oauth-se](./quick/260610-nnu-release-prep-v1-1-0-externalize-oauth-se/) |
| 260612-15a | Wire Sparkle auto-updates: updater controller + UI, SUFeedURL/SUPublicEDKey, appcast generation/signing/upload in release.sh | 2026-06-12 | f12b109 | [260612-15a-wire-sparkle-auto-updates-updater-contro](./quick/260612-15a-wire-sparkle-auto-updates-updater-contro/) |
| 260701-xbi | CAL-03: fire the calendar record prompt a configurable lead time before start (default 2 min), now-injectable model helpers + lead-time service selection + 1/2/5-min Settings picker persisted in UserDefaults, README updated | 2026-07-01 | 84b1b3a | [260701-xbi-cal-03-fire-meeting-record-prompt-config](./quick/260701-xbi-cal-03-fire-meeting-record-prompt-config/) |

## Session Continuity

Last session: 2026-07-09
Last activity: 2026-07-09
Stopped at: Roadmap created — Phases 18–21 defined, 15/15 requirements mapped
Resume file: None
Next: `/gsd:plan-phase 18`

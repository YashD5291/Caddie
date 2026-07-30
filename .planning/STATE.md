---
gsd_state_version: 1.0
milestone: v3.0
milestone_name: Screen Recording
status: executing
stopped_at: Completed 19-04-PLAN.md
last_updated: "2026-07-30T20:28:58.295Z"
last_activity: 2026-07-30
progress:
  total_phases: 4
  completed_phases: 1
  total_plans: 9
  completed_plans: 8
  percent: 25
---

# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-07-09)

**Core value:** Every meeting must be reliably captured, transcribed, and retrievable -- no silent failures, no lost recordings, no data corruption.
**Current focus:** Phase 19 — recording-lifecycle-integration

## Current Position

Phase: 19 (recording-lifecycle-integration) — EXECUTING
Plan: 5 of 5
Status: Ready to execute
Last activity: 2026-07-30

## Performance Metrics

**Velocity (v1.0):**

- Total plans completed: 23
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
- [Phase 18]: 18-01: Pattern 1 concurrency (queue-confined final class + @unchecked Sendable WriterSink) proven green under strict concurrency; no @preconcurrency/nonisolated needed
- [Phase 18]: 18-01: First-frame recipe B (startSession at first PTS) + ~2s static-screen keepalive chosen for Plan 18-02
- [Phase 18]: 18-02: Live SCStream->AVAssetWriter capture landed; recipe-B first-frame anchor + ~2s static-screen keepalive + async non-blocking finalize; CaptureTarget kept non-Sendable (SCWindow), dims derived from filter.contentRect*pointPixelScale
- [Phase 18]: 18-03: VID-07 crash-safety gated via a DEBUG launch-arg harness (--screen-record-harness / --validate-mov) reusing the app binary as a kill-able separate process + scripts/kill9-recovery-gate.sh (record→kill -9→assert playable, <=10s loss); live capture leg + 14.2-floor re-run deferred to 18-04 human checkpoint (headless env has no Screen Recording TCC)
- [Phase 19 Planning 2026-07-10]: Two locked-context reinterpretations, forced by research findings and surfaced to user: (1) per-meeting FACTORY injection (`ScreenRecorderFactory`) instead of a literal single optional instance — research proved the engine is single-use (second start() silently no-ops; meeting #2 would lose video); (2) dedicated `lastVideoError` channel instead of reusing `lastRecordingError` — reuse would render "Last recording failed" for meetings whose audio succeeded. Also: stop-timeout (5s bounded race) shipped per planner judgment; reentrancy task-join guard.
- [Phase 19]: 19-01: ScreenRecording seam added by retroactive conformance in a NEW file — the hardware-verified Phase 18 engine file keeps a zero diff; feature gate reads object(forKey:) so absent-key can never read as enabled (VID-01 opt-in) — Keeps 18-04's hardware verification valid without a re-run, and makes the opt-in semantic provable by test
- [Phase 19]: 19-02: VideoContext.recorder is attached after start() returns — Swift 6 region isolation rejects storing the non-Sendable engine into actor state before the await start(...) call
- [Phase 19]: 19-02: video start runs in an unstructured videoStartTask instead of inline await, so SCK's ~215ms setup never stalls the coordinator actor; 19-03 joins the task before stopping
- [Phase 19]: 19-02: video failures use a dedicated setOnVideoError channel — never .error, never the fatal recording-error surface
- [Phase 19]: 19-03: The capture engine is stored in a Sendable single-owner box (CaptureEngineBox) so the coordinator actor can call its nonisolated stop() — a bare stored engine is 'self'-isolated and region isolation rejects the send
- [Phase 19]: 19-03: The compile-verified withTaskGroup stop-timeout race does not bound anything (a group awaits ALL children; Task<Void,Never>.value ignores cancellation) — the waiting child polls a lock-guarded latch instead
- [Phase 19]: 19-03: A timed-out video stop never cancels the stop task — the coordinator stops waiting, the engine's finalize still completes in the background
- [Phase 19]: 19-04: Screen recording is inert by ABSENCE, not by flag — the ScreenRecorderFactory is constructed only inside the ScreenRecordingSettings.isEnabled branch, so no downstream path re-checks the gate
- [Phase 19]: 19-04: Permissions.screenRecording is logged for diagnostics but never gates construction — it is a window-name inference, so a false negative would silently disable video; a denied TCC grant is handled as a real start() throw on the non-fatal channel
- [Phase 19]: 19-04: The video warning renders in the .recording menu-bar branch too (not just .idle) — a capture that dies mid-meeting would otherwise be invisible for the rest of the meeting

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
| Phase 18 P01 | 11 | 3 tasks | 4 files |
| Phase 18 P02 | 7 | 2 tasks | 1 files |
| Phase 18 P03 | 18 | 2 tasks | 3 files |
| Phase 19 P01 | 17 min | 3 tasks | 6 files |
| Phase 19 P02 | 13 min | 2 tasks | 2 files |
| Phase 19 P03 | 16 min | 2 tasks | 2 files |
| Phase 19 P04 | 12 min | 2 tasks | 4 files |

## Session Continuity

Last session: 2026-07-30T20:28:58.286Z
Last activity: 2026-07-09
Stopped at: Completed 19-04-PLAN.md
Resume file: None
Next: `/gsd:plan-phase 18`

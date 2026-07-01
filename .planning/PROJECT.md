# Caddie

## What This Is

A native macOS menu bar app that automatically detects meetings, records system audio and microphone, transcribes with on-device ML (speaker diarization included), and stores everything locally in a searchable database. Zero cloud dependency — nothing leaves the device. ML models ship bundled in the app.

## Core Value

Every meeting must be reliably captured, transcribed, and retrievable — no silent failures, no lost recordings, no data corruption.

## Requirements

### Validated

- ✓ Auto-detect meetings across Zoom, Teams, Meet, Slack, Discord, Webex, FaceTime — existing
- ✓ Stereo recording of system audio + microphone — existing
- ✓ On-device ASR via FluidAudio/Parakeet — existing
- ✓ Speaker diarization via Sortformer — existing
- ✓ Transcript merging (ASR + diarization) — existing
- ✓ Local SQLite storage with GRDB and FTS5 full-text search — existing
- ✓ ALAC audio compression — existing
- ✓ SwiftUI menu bar app with meeting list, detail, audio player, export — existing
- ✓ Settings view with launch-at-login and data management — existing
- ✓ Test infrastructure with 49+ tests executing — v1.0 Phase 1-2
- ✓ Lock-free audio thread safety (SPSC ring buffer) — v1.0 Phase 3
- ✓ RecordingCoordinator actor state machine — v1.0 Phase 4
- ✓ Pipeline data integrity (file lifecycle, orphan cleanup, queue bounds) — v1.0 Phase 5
- ✓ Full error discipline (zero try?, zero force unwraps, weak self guarded) — v1.0 Phase 6
- ✓ Precondition guards (disk space, model timeout) — v1.0 Phase 7
- ✓ User feedback (menu bar status, transcription progress, notifications) — v1.0 Phase 8
- ✓ Recording resilience (device disconnect, stale cleanup) — v1.0 Phase 9
- ✓ ML models bundled in app (no runtime download) — v1.0 Phase 10
- ✓ Onboarding flow with bundle-based model loading — v1.0 Phase 10
- ✓ Audio input device picker with persistence + mid-recording hot-swap — v2.0 (Phases 11–13)
- ✓ Manual start/stop recording from menu bar — v2.0 (Phase 13)
- ✓ Google Calendar integration (OAuth PKCE, Keychain, polling, Today's Schedule) — v2.0 (v1.1.0)
- ✓ Calendar-triggered recording via actionable notification prompt — v2.0 (PR #3)
- ✓ Pre-meeting notification at configurable lead time before start — v2.0 (PR #8)
- ✓ Calendar event title carried into meeting records — v2.0
- ✓ Live transcription during recording (streaming ASR, display-only) — v2.0 (v1.2.0)
- ✓ Sparkle auto-updates (signed appcast in release pipeline) — v2.0 (v1.2.1)

### Active

(None — v2.0 shipped. Next milestone not yet defined; run `/gsd:new-milestone`.)

### Future

- AI summaries / action items
- Recording session crash recovery
- Automatic transcription retry with backoff
- Proactive disk space monitoring during recording
- Structured error logging to file for bug reports
- Recording health dashboard in Settings

### Out of Scope

- Cloud sync — core value is local-only, privacy-first
- Multi-platform — macOS only
- Multi-language transcription UI — feature scope
- Browser extension for calendar — native OAuth preferred

**Note:** "Real-time transcription" was previously out of scope but shipped in v2.0 as *display-only live transcription* during recording — the persisted transcript still comes from the post-recording diarized pipeline, so the architectural boundary held.

## Current State

**Shipped:** v2.0 (Google Calendar + Remote Meeting Recording), released as v1.1.0 → **v1.2.1** (current). Notarized DMGs on a public GitHub repo; Sparkle auto-updates live from v1.2.1.

**Product shift this milestone:** local app-based auto-detection (Zoom/Teams/Meet window + audio-process signals) was **removed** as the recording trigger. Recording is now user-initiated — manual (menu bar / New Recording), a calendar event's Record button, or the actionable pre-meeting notification. Google Calendar replaced EventKit. The auto-start-on-meeting-start idea was deliberately dropped in favor of the notification prompt (no recording of pre-meeting silence, user stays in control).

**User context:** User joins meetings on a remote PC via Jump Desktop, with a Loopback virtual device routing that audio to the Mac; Caddie runs on the local Mac and captures from the selected input device.

**Next milestone:** not yet defined. Candidate directions in Future below; run `/gsd:new-milestone` to scope.

## Context

- v2.0 shipped across v1.1.0–v1.2.1; 267 tests passing, Swift 6 strict concurrency
- Stack: Swift 6, SwiftUI, macOS 14.2+, GRDB 7.10, FluidAudio 0.12.4 (Parakeet ASR + Sortformer diarization + streaming ASR), Sparkle 2.9, XcodeGen
- Self-contained app bundle (~690MB ML models bundled; zero runtime downloads)
- Google OAuth secret externalized to a gitignored file; EdDSA update key in login Keychain
- Release pipeline: scripts/build-dmg.sh → scripts/release.sh (notarize/staple/sign appcast); notary profile "Caddie"
- Known tech debt (from v2.0 audit): attendee names decoded but not rendered/persisted; onboarding copy doesn't enumerate exact calendar data accessed; GitHub Actions release workflow disabled (local script is source of truth)
- Open manual check: live-transcription end-to-end with a real microphone was never run

## Constraints

- **Platform**: macOS 14.2+ (Sonoma), Apple Silicon recommended — CoreML/ANE acceleration
- **Privacy**: All processing on-device, network only for Google Calendar API, Sparkle updates
- **Dependencies**: FluidAudio is the ML backbone — yyjson linker issue resolved via selective coverage
- **Permissions**: Requires Microphone, Screen Recording, Accessibility, Calendar — all via system prompts
- **Build system**: XcodeGen → Xcode project, SPM for dependencies, preBuildScript for model download

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Fix tests before anything else | Can't verify fixes without a working test target | ✓ Good — 49+ tests now gate every change |
| Treat all error suppression as bugs | Silent failures violate core value of reliable capture | ✓ Good — zero try? remaining |
| No new features until hardened | Existing features must be trustworthy before adding more | ✓ Good — v1.0 complete, ready for features |
| Swift 6.0 with strict concurrency | Full data race checking from day one | ✓ Good — caught 7 concurrency bugs |
| Lock-free SPSC ring buffer | Eliminate priority inversion on real-time audio thread | ✓ Good — no locks on render callback |
| RecordingCoordinator actor | Single owner of recording lifecycle, eliminates scattered state | ✓ Good — clean state machine with tests |
| Bundle ML models in app | Zero network dependency after install | ✓ Good — instant onboarding, offline-first |

## Evolution

This document evolves at phase transitions and milestone boundaries.

**After each phase transition:**
1. Requirements invalidated? → Move to Out of Scope with reason
2. Requirements validated? → Move to Validated with phase reference
3. New requirements emerged? → Add to Active
4. Decisions to log? → Add to Key Decisions
5. "What This Is" still accurate? → Update if drifted

**After each milestone:**
1. Full review of all sections
2. Core Value check — still the right priority?
3. Audit Out of Scope — reasons still valid?
4. Update Context with current state

---
*Last updated: 2026-07-02 after v2.0 milestone completion*

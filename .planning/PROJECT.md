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

### Active

- [ ] Google Calendar integration (OAuth2, read meetings, auto-trigger recording)
- [ ] Audio device picker (select Loopback/Jump Desktop device as capture source)
- [ ] Calendar-based meeting detection (replaces local app detection as primary)
- [ ] Pre-meeting notification before recording starts
- [ ] Manual start/stop recording from menu bar
- [ ] Calendar event metadata in meeting list (title, attendees)

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
- Real-time transcription — architecturally different pipeline
- Multi-language transcription UI — feature scope
- Browser extension for calendar — native OAuth preferred

## Current Milestone: v2.0 Google Calendar + Remote Meeting Recording

**Goal:** Caddie detects meetings from Google Calendar and records from a user-selected audio device (Loopback virtual device for Jump Desktop) — fully automatic.

**Target features:**
- Google OAuth2 sign-in for calendar access
- Read upcoming meetings from Google Calendar
- Auto-start recording when a calendar meeting begins
- Audio device picker in settings (select Loopback device for Jump Desktop audio)
- Pre-meeting notification ("Recording starts in 2 min")
- Manual start/stop recording from menu bar
- Meeting list shows calendar event metadata (title, attendees)

**User context:** User joins meetings on remote PC via Jump Desktop, with Loopback virtual device routing Jump Desktop audio to Mac. Caddie runs on the local Mac.

## Context

- v1.0 shipped: 10 phases, 22 plans, 8,292 LOC Swift across Sources + Tests
- 49+ tests passing (unit + integration), Swift 6.0 strict concurrency
- Stack: Swift 6.0, SwiftUI, macOS 14.2+, GRDB 7.10, FluidAudio 0.12.4, XcodeGen
- App bundle includes ~711MB of ML models (ASR + Sortformer)
- CI/CD: GitHub Actions with model caching, Sparkle for updates

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
*Last updated: 2026-03-24 after v2.0 milestone start*

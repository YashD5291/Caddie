# Caddie

## What This Is

A native macOS menu bar app that automatically detects meetings, records system audio and microphone, transcribes with on-device ML (speaker diarization included), and stores everything locally in a searchable database. Zero cloud dependency — nothing leaves the device.

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
- ✓ Onboarding flow with ML model loading — Validated in Phase 10: bundle-ml-models
- ✓ ML models bundled in app (no runtime download) — Validated in Phase 10: bundle-ml-models
- ✓ Settings view with launch-at-login and data management — existing

### Active

- [ ] Fix broken test infrastructure (yyjson linker error blocks all tests)
- [ ] Eliminate crash risks (force unwraps on directory access, array indexing)
- [ ] Replace silent error suppression (14 `try?` instances with no logging)
- [ ] Fix initialization race condition (pipeline nil when meeting ends during init)
- [ ] Make transcript persistence critical (DB write failure currently loses transcript)
- [ ] Fix temp file cleanup timing (defer deletes mono file while diarization may be in-flight)
- [ ] Add disk space checks before recording
- ✓ Model download timeout removed — models bundled in app (Phase 10)
- [ ] Bound transcription queue depth
- [ ] Clean orphaned temp files on app startup
- [ ] Surface system audio capture failures to user (currently silent mic-only fallback)
- [ ] Add meeting detection conflict resolution
- [ ] Fix weak self captures in signal handlers
- [ ] Add test coverage for CoreAudio setup/teardown, database migrations, pipeline error paths
- [ ] Make database write failures in pipeline block processing (not silently continue)

### Out of Scope

- Cloud sync — core value is local-only, privacy-first
- AI summaries / action items — hardening first, features later
- Calendar notification prompts — future milestone
- Multi-platform — macOS only

## Context

- Brownfield project: core features shipped across ~17 commits, ML pipeline (Phase 1) most recent
- App compiles and builds successfully
- Test target is broken — yyjson (C dep of FluidAudio) fails to link with code coverage enabled
- 10 test files exist but none can execute
- Codebase concern audit identified 15+ issues ranging from crash risks to silent data loss
- The app works on the happy path but has no resilience to edge cases or failures
- Stack: Swift 5.9, SwiftUI, macOS 14.2+, GRDB 7.10, FluidAudio 0.12.4, XcodeGen

## Constraints

- **Platform**: macOS 14.2+ (Sonoma), Apple Silicon recommended — CoreML/ANE acceleration
- **Privacy**: All processing on-device, no network calls except Sparkle updates (models bundled since Phase 10)
- **Dependencies**: FluidAudio is the ML backbone — its C dependency (yyjson) causes the test linker issue
- **Permissions**: Requires Microphone, Screen Recording, Accessibility, Calendar — all via system prompts
- **Build system**: XcodeGen → Xcode project, SPM for dependencies

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Fix tests before anything else | Can't verify fixes without a working test target | — Pending |
| Treat all error suppression as bugs | Silent failures violate core value of reliable capture | — Pending |
| No new features until hardened | Existing features must be trustworthy before adding more | — Pending |

## Evolution

This document evolves at phase transitions and milestone boundaries.

**After each phase transition** (via `/gsd:transition`):
1. Requirements invalidated? → Move to Out of Scope with reason
2. Requirements validated? → Move to Validated with phase reference
3. New requirements emerged? → Add to Active
4. Decisions to log? → Add to Key Decisions
5. "What This Is" still accurate? → Update if drifted

**After each milestone** (via `/gsd:complete-milestone`):
1. Full review of all sections
2. Core Value check — still the right priority?
3. Audit Out of Scope — reasons still valid?
4. Update Context with current state

---
*Last updated: 2026-03-23 after Phase 10 completion — ML models bundled in app, all 10 phases complete*

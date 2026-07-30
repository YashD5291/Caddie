# Research Summary: Caddie v2.0 Google Calendar + Audio Device Selection

**Domain:** macOS meeting recorder -- calendar-driven recording with configurable audio devices
**Researched:** 2026-03-24
**Overall confidence:** HIGH

## Executive Summary

Caddie v2.0 adds two major capabilities to the existing meeting recorder: Google Calendar integration for automatic meeting detection and audio device selection for capturing from virtual devices (specifically Loopback routing Jump Desktop audio). These features address the user's core workflow: joining meetings on a remote PC via Jump Desktop, where existing v1.0 detection (audio process monitoring, microphone state, window titles) produces no signals because the meeting runs on the remote machine.

The Google Calendar integration requires OAuth2 authentication, periodic API polling for events, and a scheduling system that triggers recording at meeting start time. The recommended approach uses zero new SPM dependencies -- ASWebAuthenticationSession (system framework) for OAuth, URLSession + Codable for the Calendar REST API, and Security framework for Keychain token storage. Google's Calendar API supports incremental sync via syncTokens, which minimizes polling overhead. Push notifications were evaluated and rejected because they require a webhook server, violating Caddie's zero-server architecture.

Audio device selection leverages SimplyCoreAudio (already a dependency) for device enumeration and extends SystemAudioCapture with an alternative code path that opens a specific device directly instead of creating a process tap. MicrophoneCapture needs rework from AVAudioEngine (which cannot select non-default devices) to a HAL AudioUnit pattern (same as SystemAudioCapture). This is the highest-risk engineering change because it introduces a second capture code path in SystemAudioCapture and requires rewriting MicrophoneCapture's architecture.

The two feature tracks (calendar + audio devices) are architecturally independent and can be built in parallel. They converge in the RecordingCoordinator when calendar events trigger recording on user-selected devices. The existing detection/recording/transcription pipeline stays intact -- new components inject into the existing signal flow through `DetectionSignal.SignalSource.googleCalendar` and new `AudioRecorder.start()` parameters.

## Key Findings

**Stack:** Zero new SPM dependencies. All new functionality uses ASWebAuthenticationSession, URLSession, Security framework, and the existing SimplyCoreAudio dependency.

**Architecture:** 6 new files (GoogleAuthManager, GoogleCalendarService, CalendarScheduler, GoogleCalendarModels, AudioDeviceManager, KeychainHelper), 11 modified files. New components inject into existing flows via DetectionSignal extension and AudioRecorder parameter additions.

**Critical pitfall:** Token refresh race condition -- concurrent calendar API calls discovering expired tokens can race to refresh, causing `invalid_grant` and silent calendar failure. Must serialize all refresh attempts through the GoogleAuthManager actor from day one.

## Implications for Roadmap

Based on research, suggested phase structure:

1. **Foundation** - Standalone utilities and schema changes
   - Addresses: KeychainHelper, GoogleCalendarModels, DB migration v2, AudioDeviceManager
   - Avoids: Cross-component dependencies that slow parallel work
   - Rationale: All items are independently testable with no dependencies on each other

2. **Audio Device Path** - CoreAudio device selection for recording
   - Addresses: SystemAudioCapture device-based capture, MicrophoneCapture rewrite, AudioRecorder device params, manual start/stop
   - Avoids: AVAudioEngine device selection limitation (documented in PITFALLS.md)
   - Rationale: Most mechanically complex change. User can immediately benefit by selecting Loopback device with manual recording, even before calendar integration.

3. **OAuth + Calendar API** - Google authentication and event fetching (parallelizable with Phase 2)
   - Addresses: GoogleAuthManager (ASWebAuthenticationSession + PKCE + Keychain), GoogleCalendarService (REST + incremental sync)
   - Avoids: Token refresh race condition, sync token invalidation (410 Gone)
   - Rationale: External dependency (Google Cloud Console setup, privacy policy) may take calendar time. Independent of audio device work.

4. **Orchestration** - Wire calendar events into detection and recording flow
   - Addresses: CalendarScheduler, DecisionEngine calendar-only rule, RecordingCoordinator integration, AppState wiring
   - Avoids: EventKit/Google Calendar duplicate detection
   - Rationale: Requires both audio device and calendar components to be working

5. **UI + Polish** - Settings sections, menu bar updates, notifications
   - Addresses: Google account settings, audio device picker, upcoming meeting display, pre-meeting notifications, manual recording controls
   - Avoids: Building UI before backend is stable
   - Rationale: UI is the last mile -- depends on all backend components being wired up

**Phase ordering rationale:**
- Phases 2 and 3 are **independent tracks** that can run in parallel, converging in Phase 4
- Audio device path (Phase 2) first because it's the highest engineering risk and provides immediate value with manual recording
- OAuth/Calendar (Phase 3) requires external setup (Google Cloud Console, privacy policy) which can happen while audio device code is being written
- Orchestration (Phase 4) is the integration phase where both tracks merge into the existing RecordingCoordinator
- UI (Phase 5) last because it should reflect stable backend behavior

**Research flags for phases:**
- Phase 2: Needs testing with actual Loopback virtual device. MicrophoneCapture HAL AudioUnit rewrite is highest risk. Sample rate mismatch with virtual devices needs verification.
- Phase 3: Google Cloud Console setup and OAuth consent screen configuration should happen early. Privacy policy URL needed before OAuth can be tested with external users. Token refresh serialization must be built correctly from day one.
- Phase 4: EventKit + Google Calendar deduplication logic needs design. Grace period extension based on calendar event end time needs testing.

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | Zero new dependencies. All system frameworks verified against macOS 14.2+ |
| Features | HIGH | Feature list derived from explicit user workflow (Jump Desktop + Loopback + Google Calendar) |
| Architecture | HIGH | All integration points mapped to specific code locations. Build order based on actual dependency graph. |
| Pitfalls | HIGH | 15 pitfalls documented with prevention strategies. Critical ones (token refresh race, device disappearance, AVAudioEngine limitation) have verified solutions. |

## Gaps to Address

- **Loopback virtual device testing:** The device-based capture path in SystemAudioCapture needs testing with an actual Loopback configuration at specific sample rates (44.1kHz, 48kHz). Verified via documentation that CoreAudio handles sample rate conversion, but virtual device quirks are real.
- **MicrophoneCapture HAL AudioUnit rewrite scope:** The recommended approach (rewrite to HAL AudioUnit when device is selected) is more work than the AVAudioEngine hack but is architecturally cleaner. Need to assess if the hack (`kAudioOutputUnitProperty_CurrentDevice` on inputNode's audioUnit) is reliable enough as a temporary solution.
- **Google OAuth consent screen verification timeline:** Sensitive scope verification can take days to weeks. For personal use (<100 users), testing mode is sufficient. For broader distribution, submit verification early.
- **ASWebAuthenticationSession + Google custom URI scheme compatibility:** STACK.md recommends this approach. Need to verify that Google's Desktop Application client type in Cloud Console supports custom URI scheme redirects (reversed client ID format). The Loopback Migration Guide confirms loopback IP is NOT deprecated for desktop, so that remains a fallback.
- **EventKit + Google Calendar overlap handling:** When both are active for the same Google account, the same events appear in both. Deduplication strategy (by title + time window, or by disabling EventKit for Google calendars) needs design during Phase 4.

## Sources

- [Google OAuth2 for Desktop Apps](https://developers.google.com/identity/protocols/oauth2/native-app)
- [Google Loopback Migration Guide](https://developers.google.com/identity/protocols/oauth2/resources/loopback-migration)
- [Google Calendar API Sync Guide](https://developers.google.com/workspace/calendar/api/guides/sync)
- [Google Calendar API Scopes](https://developers.google.com/workspace/calendar/api/auth)
- [ASWebAuthenticationSession](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession)
- [SimplyCoreAudio](https://github.com/rnine/SimplyCoreAudio)
- [AudioKit #2130: AVAudioEngine device selection limitations](https://github.com/AudioKit/AudioKit/issues/2130)
- [Apple Developer Forums: AVAudioEngine Device Selection](https://developer.apple.com/forums/thread/71008)

# Requirements: Caddie v2.0 — Google Calendar + Remote Meeting Recording

**Defined:** 2026-03-24
**Core Value:** Every meeting must be reliably captured, transcribed, and retrievable — no silent failures, no lost recordings, no data corruption.

## v2 Requirements

Requirements for Google Calendar integration and remote meeting recording support. Each maps to roadmap phases.

### Audio Device Selection

- [ ] **AUD-01**: User can select which audio input device to capture from in Settings (Loopback, built-in mic, etc.)
- [ ] **AUD-02**: Selected audio device persists across app restarts (stored in UserDefaults)
- [ ] **AUD-03**: MicrophoneCapture supports non-default input devices via HAL AudioUnit (replaces AVAudioEngine path when custom device selected)

### Manual Recording

- [ ] **REC-01**: User can manually start recording from the menu bar with one click
- [ ] **REC-02**: User can manually stop recording from the menu bar
- [ ] **REC-03**: Manual recordings go through the same transcription pipeline as auto-detected ones

### Google Authentication

- [ ] **AUTH-01**: User can sign into Google via ASWebAuthenticationSession + PKCE during onboarding
- [ ] **AUTH-02**: OAuth tokens stored securely in macOS Keychain
- [ ] **AUTH-03**: Token refresh is serialized through a single actor (no race conditions)
- [ ] **AUTH-04**: User can sign out and re-authenticate from Settings

### Google Calendar Integration

- [ ] **CAL-01**: Caddie polls Google Calendar API for upcoming events using incremental sync tokens
- [ ] **CAL-02**: Caddie auto-starts recording when a calendar meeting's start time arrives
- [ ] **CAL-03**: Pre-meeting notification fires 2 minutes before a calendar event
- [ ] **CAL-04**: Meeting list shows calendar event title and attendees from Google Calendar
- [ ] **CAL-05**: 410 Gone sync token expiry handled gracefully (full resync, no crash)

### Onboarding

- [ ] **ONB-01**: Onboarding flow includes Google sign-in as a required step
- [ ] **ONB-02**: Clear explanation of what calendar data is accessed and that it stays on-device

## Future Requirements

Deferred to later milestones. Tracked but not in current roadmap.

### Resilience
- **RES-01**: Recording session crash recovery
- **RES-02**: Automatic transcription retry with exponential backoff
- **RES-03**: Proactive disk space monitoring during recording

### Intelligence
- **INT-01**: AI summaries / action items from transcripts
- **INT-02**: Multi-language transcription support

### Polish
- **POL-01**: Structured error logging to file for bug reports
- **POL-02**: Recording health dashboard in Settings

## Out of Scope

Explicitly excluded. Documented to prevent scope creep.

| Feature | Reason |
|---------|--------|
| Browser extension for calendar | Native OAuth preferred — simpler, no extension maintenance |
| Real-time transcription | Architecturally different pipeline |
| Cloud sync or backup | Core value is local-only, privacy-first (Google Calendar read-only is the exception) |
| Multiple Google accounts | Single account sufficient for personal use |
| Webhook-based calendar sync | Requires a server — contradicts local-first architecture |
| Device hot-plug handling | Deferred — existing v1.0 device disconnect handling covers basics |

## Traceability

Which phases cover which requirements. Updated during roadmap creation.

| Requirement | Phase | Status |
|-------------|-------|--------|
| AUD-01 | Phase 11: Audio Device Selection | Pending |
| AUD-02 | Phase 11: Audio Device Selection | Pending |
| AUD-03 | Phase 12: Audio Capture Engine | Pending |
| REC-01 | Phase 13: Manual Recording | Pending |
| REC-02 | Phase 13: Manual Recording | Pending |
| REC-03 | Phase 13: Manual Recording | Pending |
| AUTH-01 | Phase 14: Google Authentication | Pending |
| AUTH-02 | Phase 14: Google Authentication | Pending |
| AUTH-03 | Phase 14: Google Authentication | Pending |
| AUTH-04 | Phase 14: Google Authentication | Pending |
| CAL-01 | Phase 15: Google Calendar Sync | Pending |
| CAL-05 | Phase 15: Google Calendar Sync | Pending |
| CAL-02 | Phase 16: Calendar-Triggered Recording | Pending |
| CAL-03 | Phase 16: Calendar-Triggered Recording | Pending |
| CAL-04 | Phase 17: Calendar UI + Onboarding | Pending |
| ONB-01 | Phase 17: Calendar UI + Onboarding | Pending |
| ONB-02 | Phase 17: Calendar UI + Onboarding | Pending |

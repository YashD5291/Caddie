# Roadmap: Caddie

## Milestones

- ✅ **v1.0 Production Hardening** -- Phases 1-10 (shipped 2026-03-24) -- [archive](milestones/v1.0-ROADMAP.md)
- 🚧 **v2.0 Google Calendar + Remote Meeting Recording** -- Phases 11-17 (in progress)

## Phases

<details>
<summary>✅ v1.0 Production Hardening (Phases 1-10) -- SHIPPED 2026-03-24</summary>

- [x] Phase 1: Test Target Revival (1/1 plans) -- completed 2026-03-22
- [x] Phase 2: Test Infrastructure (3/3 plans) -- completed 2026-03-22
- [x] Phase 3: Audio Thread Safety (2/2 plans) -- completed 2026-03-22
- [x] Phase 4: Recording Coordinator (3/3 plans) -- completed 2026-03-22
- [x] Phase 5: Pipeline Data Integrity (verified via code audit + quick fix)
- [x] Phase 6: Error Discipline (2/2 plans) -- completed 2026-03-22
- [x] Phase 7: Precondition Guards (1/1 plans) -- completed 2026-03-22
- [x] Phase 8: User Feedback (2/2 plans) -- completed 2026-03-22
- [x] Phase 9: Recording Resilience (2/2 plans) -- completed 2026-03-22
- [x] Phase 10: Bundle ML Models (3/3 plans) -- completed 2026-03-23

</details>

### 🚧 v2.0 Google Calendar + Remote Meeting Recording

- [x] **Phase 11: Audio Device Selection** - User can see, select, and persist audio input devices in Settings (completed 2026-03-24)
- [x] **Phase 12: Audio Capture Engine** - Recording engine captures from user-selected devices via HAL AudioUnit (completed 2026-03-24)
- [x] **Phase 13: Manual Recording** - User can start/stop recording from menu bar on demand (completed 2026-03-24)
- [ ] **Phase 14: Google Authentication** - User can sign into Google with OAuth2 and manage auth state
- [ ] **Phase 15: Google Calendar Sync** - Caddie fetches and caches upcoming meetings from Google Calendar
- [ ] **Phase 16: Calendar-Triggered Recording** - Caddie auto-starts recording when calendar meetings begin
- [ ] **Phase 17: Calendar UI + Onboarding** - Meeting list shows calendar metadata and onboarding includes Google sign-in

## Phase Details

### Phase 11: Audio Device Selection
**Goal**: Users can browse available audio input devices and choose which one Caddie uses, with their choice surviving app restarts
**Depends on**: Nothing (first v2 phase)
**Requirements**: AUD-01, AUD-02
**Success Criteria** (what must be TRUE):
  1. User opens Settings and sees a list of all available audio input devices (built-in mic, Loopback virtual device, USB mics, etc.)
  2. User selects a device from the picker and it becomes the active selection
  3. User quits and relaunches the app, and their previously selected device is still selected
  4. If a previously selected device is no longer connected, user sees a fallback to the default device
**Plans**: 1 plan
Plans:
- [ ] 11-01-PLAN.md -- AudioDeviceManager + SettingsView picker + AppState wiring
**UI hint**: yes

### Phase 12: Audio Capture Engine
**Goal**: The recording engine actually captures audio from the user-selected device instead of only the system default
**Depends on**: Phase 11
**Requirements**: AUD-03
**Success Criteria** (what must be TRUE):
  1. When a specific device is selected, SystemAudioCapture opens that device directly via HAL AudioUnit (no process tap)
  2. When a specific microphone device is selected, MicrophoneCapture uses HAL AudioUnit instead of AVAudioEngine
  3. When no custom device is selected, existing v1.0 capture behavior (process tap + default mic) is unchanged
  4. Recording produces valid stereo WAV files regardless of which capture path is used
**Plans**: 2 plans
Plans:
- [x] 12-01-PLAN.md -- MicrophoneCapture HAL AudioUnit path (TDD)
- [ ] 12-02-PLAN.md -- SystemAudioCapture device path + AudioRecorder routing + RecordingCoordinator wiring

### Phase 13: Manual Recording
**Goal**: Users can record any meeting on demand without waiting for auto-detection
**Depends on**: Phase 12
**Requirements**: REC-01, REC-02, REC-03
**Success Criteria** (what must be TRUE):
  1. User clicks "Start Recording" in the menu bar and recording begins immediately on the selected audio device
  2. User clicks "Stop Recording" in the menu bar and recording stops
  3. Manual recordings appear in the meeting list and go through the full transcription pipeline (ASR + diarization + DB storage)
  4. Menu bar clearly shows recording state with source label ("Manual Recording")
**Plans**: 1 plan
Plans:
- [ ] 13-01-PLAN.md -- Manual recording state machine + menu bar Start/Stop UI
**UI hint**: yes

### Phase 14: Google Authentication
**Goal**: Users can securely sign into their Google account for calendar access
**Depends on**: Nothing (independent track, parallelizable with Phases 11-13)
**Requirements**: AUTH-01, AUTH-02, AUTH-03, AUTH-04
**Success Criteria** (what must be TRUE):
  1. User can sign into Google via a browser-based OAuth flow (ASWebAuthenticationSession + PKCE) and see "Connected as user@gmail.com" in Settings
  2. OAuth tokens are stored in macOS Keychain (not UserDefaults or plaintext)
  3. Multiple simultaneous API calls that discover an expired token result in exactly one refresh request (no race conditions, no invalid_grant errors)
  4. User can sign out from Settings, which clears Keychain tokens and revokes the Google token
  5. User can re-authenticate after signing out
**Plans**: TBD
**UI hint**: yes

### Phase 15: Google Calendar Sync
**Goal**: Caddie knows about the user's upcoming meetings from Google Calendar
**Depends on**: Phase 14
**Requirements**: CAL-01, CAL-05
**Success Criteria** (what must be TRUE):
  1. After signing in, Caddie polls Google Calendar API and retrieves upcoming events using incremental sync tokens
  2. Subsequent polls only fetch changed events (not full re-fetches), reducing API traffic
  3. When Google returns 410 Gone (expired sync token), Caddie performs a full resync without crashing or losing data
  4. Calendar events are cached in memory and available to other components (scheduler, UI)
**Plans**: TBD

### Phase 16: Calendar-Triggered Recording
**Goal**: Caddie automatically records meetings based on the user's Google Calendar schedule
**Depends on**: Phase 12, Phase 15
**Requirements**: CAL-02, CAL-03
**Success Criteria** (what must be TRUE):
  1. When a calendar meeting's start time arrives, Caddie automatically starts recording on the selected audio device
  2. A notification fires 2 minutes before a calendar meeting starts ("Recording starts in 2 min")
  3. Calendar-triggered recordings flow through the full transcription pipeline identically to manual and auto-detected recordings
  4. Google Calendar alone is sufficient to trigger recording (no local audio/mic/window signals required -- the remote meeting use case)
**Plans**: TBD

### Phase 17: Calendar UI + Onboarding
**Goal**: Calendar metadata is visible in the app and new users are guided through Google sign-in
**Depends on**: Phase 14, Phase 15
**Requirements**: CAL-04, ONB-01, ONB-02
**Success Criteria** (what must be TRUE):
  1. Meeting list shows calendar event title and attendees for calendar-triggered recordings
  2. Onboarding flow includes a Google sign-in step as a required part of setup
  3. Onboarding clearly explains what calendar data is accessed and that it stays on-device
  4. Menu bar shows the next upcoming meeting when signed in ("Next: Standup in 12 min")
**Plans**: TBD
**UI hint**: yes

## Progress

**Execution Order:**
Phases 11-13 (audio device track) and Phase 14 (auth) can run in parallel. Phase 15 depends on 14. Phase 16 is the convergence point (depends on 12 + 15). Phase 17 depends on 14 + 15.

| Phase | Milestone | Plans Complete | Status | Completed |
|-------|-----------|----------------|--------|-----------|
| 1. Test Target Revival | v1.0 | 1/1 | Complete | 2026-03-22 |
| 2. Test Infrastructure | v1.0 | 3/3 | Complete | 2026-03-22 |
| 3. Audio Thread Safety | v1.0 | 2/2 | Complete | 2026-03-22 |
| 4. Recording Coordinator | v1.0 | 3/3 | Complete | 2026-03-22 |
| 5. Pipeline Data Integrity | v1.0 | verified | Complete | 2026-03-22 |
| 6. Error Discipline | v1.0 | 2/2 | Complete | 2026-03-22 |
| 7. Precondition Guards | v1.0 | 1/1 | Complete | 2026-03-22 |
| 8. User Feedback | v1.0 | 2/2 | Complete | 2026-03-22 |
| 9. Recording Resilience | v1.0 | 2/2 | Complete | 2026-03-22 |
| 10. Bundle ML Models | v1.0 | 3/3 | Complete | 2026-03-23 |
| 11. Audio Device Selection | v2.0 | 0/1 | Complete    | 2026-03-24 |
| 12. Audio Capture Engine | v2.0 | 1/2 | Complete    | 2026-03-24 |
| 13. Manual Recording | v2.0 | 0/1 | Complete    | 2026-03-24 |
| 14. Google Authentication | v2.0 | 0/TBD | Not started | - |
| 15. Google Calendar Sync | v2.0 | 0/TBD | Not started | - |
| 16. Calendar-Triggered Recording | v2.0 | 0/TBD | Not started | - |
| 17. Calendar UI + Onboarding | v2.0 | 0/TBD | Not started | - |

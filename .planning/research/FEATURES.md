# Feature Landscape: v2.0 Google Calendar + Audio Device Selection

**Domain:** macOS meeting recorder -- calendar-driven recording with configurable audio devices
**Researched:** 2026-03-24
**Confidence:** HIGH (existing codebase deeply understood, Google APIs well-documented, audio APIs already in use)

## User Context

The user joins meetings on a remote PC via Jump Desktop. Audio from the remote PC is routed through Rogue Amoeba Loopback, which creates a virtual audio device on the local Mac. Caddie runs on the local Mac and must capture audio from that Loopback virtual device. Meetings appear on Google Calendar, not the local macOS calendar.

**Current limitation:** Caddie detects meetings by monitoring local audio processes (Zoom, Teams, etc.) + microphone state + window titles + local EventKit calendar. None of these fire when the meeting runs on a remote machine. The user needs calendar-driven detection + explicit audio device selection.

## Table Stakes

Features users expect for a calendar-integrated meeting recorder. Missing = product feels broken for the stated use case.

| Feature | Why Expected | Complexity | Dependencies | Notes |
|---------|--------------|------------|--------------|-------|
| Google OAuth2 sign-in | Users must authenticate to access their calendar. Every calendar-integrated app does this. | Medium | New: OAuth2 module (loopback IP + PKCE) | Desktop apps use loopback redirect (`http://127.0.0.1:port`) with PKCE. Google deprecated custom URI schemes. Must open system browser, not embedded WebView. Token + refresh token stored in Keychain. |
| Calendar event list (upcoming meetings) | Users need to see what meetings Caddie knows about. Without visibility, they can't trust auto-recording. | Low | Google OAuth2 token, Google Calendar API `events.list` | Use `calendar.events.readonly` scope (most restrictive). Initial full sync, then incremental via `syncToken`. Poll every 5 minutes (Google recommends minimizing polling). |
| Calendar-triggered auto-start recording | The core value: meeting starts, recording starts -- no manual intervention. This is the entire point of the milestone. | High | Calendar event list, audio device selection, RecordingCoordinator | Schedule recording start at event `startTime`. Use `UNUserNotificationCenter` to schedule time-based local notification. Must handle: early joins, late starts, event time changes, cancelled events. |
| Audio device picker (system audio source) | User must select the Loopback virtual device as the capture source instead of the default process tap. Without this, Caddie captures nothing from Jump Desktop. | Medium | SimplyCoreAudio (already a dependency), SystemAudioCapture refactor | Enumerate input devices via SimplyCoreAudio. Present SwiftUI Picker in Settings. Store selected device UID in UserDefaults. Pass to SystemAudioCapture as device-based capture instead of process-based tap. |
| Audio device picker (microphone source) | When using a virtual audio setup, the user may also need a non-default microphone. Loopback can route mic audio too. | Low | SimplyCoreAudio, MicrophoneCapture refactor | AVAudioEngine uses system default input. Must set specific device via `kAudioOutputUnitProperty_CurrentDevice` on the underlying AudioUnit. |
| Pre-meeting notification | Users need a heads-up that recording is about to start. Recording without warning feels invasive, even to the user themselves. MacWhisper, Granola, and Krisp all do this. | Low | Calendar event list, UNUserNotificationCenter | Schedule notification 2 minutes before meeting start. Actionable: "Recording starts in 2 min" with option to skip. Use `UNNotificationAction` for "Skip" button. |
| Manual start/stop recording | Fallback for ad-hoc meetings not on calendar, or when auto-detection misses. Every competitor has this. MacWhisper requires it; Granola offers it as override. | Low | RecordingCoordinator (add `manualStart` event) | Add "Start Recording" / "Stop Recording" to MenuBarView. Trigger `RecordingEvent.manualStart` in coordinator. Title defaults to "Manual Recording" or user-entered title. |
| Calendar event metadata in meeting list | Meeting list must show calendar title + attendees, not just "Unknown Meeting". Gives context when reviewing recordings. | Low | Meeting model migration, Calendar event data | Add `attendees: String?` and `calendarEventId: String?` columns to `meetings` table. Store JSON-encoded attendee list. Display in MeetingDetailView. |

## Differentiators

Features that set Caddie apart from competitors. Not expected by users, but valued when present.

| Feature | Value Proposition | Complexity | Dependencies | Notes |
|---------|-------------------|------------|--------------|-------|
| Automatic calendar sync with incremental updates | Most competitors require manual refresh or only check on app launch. Caddie can poll every 5 min with `syncToken` to catch event edits, cancellations, and new meetings in near-real-time. | Medium | Google Calendar API sync flow | Use incremental sync: initial full sync stores `syncToken`, subsequent requests send it back. Handle `410 GONE` by clearing local cache and re-syncing. Far more efficient than re-fetching all events. |
| Smart grace period extension for calendar events | Current grace period (15s default) may end recording too early if meeting audio drops briefly. When a calendar event is still active (endTime not passed), extend grace period automatically. | Low | Calendar event data + existing grace period logic | Check `event.endTime > now` in `MeetingDetector.graceTick()`. If true, extend grace. Simple but prevents premature recording stops during long meetings. |
| Device validation on recording start | Verify the selected Loopback device is available before starting recording. If device disappeared (Loopback not running), fall back gracefully or notify user. | Low | Audio device picker, SystemAudioCapture | Check device exists via SimplyCoreAudio before recording. If missing, show notification: "Selected audio device unavailable. Check Loopback is running." |
| Calendar-aware meeting titles | Use calendar event title as the meeting title instead of inferring from window titles. Much more accurate. | Low | Calendar event list | Already partially supported: `DecisionEngine` prefers `calendarEvent` over `windowTitle`. Extend to use full Google Calendar event title. |
| Multiple Google account support | Power users have work + personal calendars on different Google accounts. Supporting multiple accounts avoids "which account has that meeting?" confusion. | Medium | OAuth2 module refactor for multi-account | Store multiple refresh tokens in Keychain, keyed by email. Aggregate events from all accounts. UI: account list in Settings with add/remove. Defer to later if scope pressure exists. |
| Audio device hot-swap detection | If Loopback device disconnects mid-recording (Loopback crashes, USB audio device unplugged), detect and notify immediately. Already have `onDeviceDisconnected` callback on SystemAudioCapture. | Low | Existing `onDeviceDisconnected` + device alive listener | Already implemented for aggregate devices. Extend to cover user-selected device. SimplyCoreAudio fires `deviceListChanged` notification. |

## Anti-Features

Features to explicitly NOT build for v2.0.

| Anti-Feature | Why Avoid | What to Do Instead |
|--------------|-----------|-------------------|
| Google Calendar push notifications (webhooks) | Requires an HTTPS server endpoint to receive webhook callbacks. Caddie is a desktop app with no server. Push notifications are designed for web services, not local apps. | Poll with `syncToken` every 5 minutes. For a single user's calendar, this is well within rate limits and adds zero infrastructure. |
| Full calendar CRUD (create/edit/delete events) | Scope creep. Caddie reads meetings, it doesn't manage them. Requesting `calendar.events` (read-write) scope triggers a more invasive Google OAuth consent screen. | Use `calendar.events.readonly` scope. Read-only access is all that's needed and earns more user trust. |
| Embedded web view for OAuth | Google explicitly disallows embedded WebViews for OAuth. Using one will fail with `disallowed_useragent` error. Also a security anti-pattern (app can intercept credentials). | Use system browser via `ASWebAuthenticationSession` or spawn `NSWorkspace.shared.open(url)` to default browser. Listen on loopback for redirect. |
| Real-time calendar event streaming | Building a persistent connection to Google Calendar for instant updates. Over-engineered for a single-user desktop app. | 5-minute polling interval with incremental sync. Meetings don't appear/change that frequently. |
| Audio device auto-detection for Loopback | Trying to automatically detect "which device is the Loopback device" by name or manufacturer. Fragile -- users can name Loopback devices anything. | Let the user explicitly pick their device in Settings. Show all input devices, user picks the right one. Simple, reliable, no magic. |
| Screen Recording permission bypass for device-based capture | Attempting to capture audio from a specific device without Screen Recording permission. Some CoreAudio device capture paths need it, some don't. | Always require Screen Recording permission (already granted for v1.0 process tap). The user already has this. |
| Multi-calendar picker UI (select which calendars to monitor) | Over-engineering for v2.0. Users typically want all calendars monitored. Adding a picker adds UI complexity for minimal value. | Monitor all calendars from the authenticated account. If users complain about noise, add calendar filtering in v3.0. |
| Speaker identification from calendar attendees | Mapping diarized speakers to calendar attendee names. Requires voice fingerprinting or manual assignment. Far too complex for v2.0. | Show attendee names as metadata. Speaker labels remain "Speaker 1", "Speaker 2" etc. |

## Feature Dependencies

```
Google OAuth2 Sign-in
  |
  v
Calendar Event List (events.list + syncToken)
  |
  +---> Calendar-triggered Auto-start Recording
  |       |
  |       +---> Pre-meeting Notification
  |       |
  |       +---> Calendar Event Metadata in Meeting List
  |       |
  |       +---> Smart Grace Period Extension
  |
  +---> Calendar-aware Meeting Titles

Audio Device Picker (Settings)
  |
  +---> SystemAudioCapture refactor (device-based capture)
  |       |
  |       +---> Device Validation on Recording Start
  |
  +---> MicrophoneCapture refactor (specific input device)

Manual Start/Stop Recording (independent, no dependencies)
```

Key observation: OAuth2 and Audio Device Picker are independent tracks that can be built in parallel. They converge at the RecordingCoordinator when calendar events trigger recording on a specific device.

## Integration Points with Existing Code

### Detection Layer (`Sources/Detection/`)
- **CalendarMonitor.swift**: Currently uses EventKit (local macOS calendar). Needs a new `GoogleCalendarMonitor` that polls the Google Calendar API instead. Should conform to the same `DetectionMonitor` protocol but emit richer signals (event title, attendees, start/end times).
- **MeetingDetector.swift**: `DecisionEngine.evaluate()` needs a new rule: a Google Calendar event whose time range includes "now" should be sufficient to trigger recording on its own (no need for audio process + mic signals, since the meeting is on a remote machine). Currently requires 2+ active signals with specific combinations. Calendar-only should be valid.
- **DetectionSignal**: May need extension to carry event start/end times for grace period logic.

### Recording Layer (`Sources/Recording/`)
- **SystemAudioCapture.swift**: Currently creates a process tap (`CATapDescription(monoMixdownOfProcesses:)`) or global tap, then builds an aggregate device. For device-based capture, the approach is different: set the selected `AudioDeviceID` directly as the HAL Output AudioUnit's input device, bypassing the tap/aggregate device entirely. This is actually simpler -- no tap creation, no aggregate device. Just configure the AudioUnit to pull from the user's chosen device.
- **MicrophoneCapture.swift**: Currently uses `AVAudioEngine().inputNode` which defaults to system default input. Must set specific device UID before calling `engine.start()`. Use `AudioUnitSetProperty(kAudioOutputUnitProperty_CurrentDevice)` on the underlying audio unit retrieved via `engine.inputNode.auAudioUnit.audioUnit`.
- **AudioRecorder.swift**: `start(outputPath:processID:)` signature needs to accept device UIDs. When `systemDeviceUID` is provided, use device-based capture instead of process tap. When not provided, keep existing behavior for backward compatibility.

### Coordinator (`Sources/Coordinator/`)
- **RecordingCoordinator.swift**: Add `RecordingEvent.manualStart(title: String)` and extend `meetingDetected` to carry calendar event metadata. The coordinator already handles the full lifecycle; new events just create `DetectedMeeting` with different source data.
- **RecordingState.swift**: No changes needed -- states are already generic (idle/recording/transcribing/error).

### Storage (`Sources/Storage/`)
- **Meeting model**: Add `attendees: String?`, `calendarEventId: String?` columns via GRDB migration.
- **Auth storage**: Refresh token and account email in Keychain. SyncToken in UserDefaults (not sensitive data). No new database table needed.

### UI (`Sources/UI/`)
- **SettingsView.swift**: Add "Google Calendar" section (sign in/out, connected account email) and "Audio Devices" section (system audio device picker, microphone picker, test button).
- **MenuBarView.swift**: Add "Start Recording" button when idle. Show next upcoming meeting from calendar with countdown.
- **MeetingListView/MeetingDetailView**: Show attendees and calendar event source.

## MVP Recommendation

**Phase 1 -- Audio Device Selection (build first):**
1. Audio device picker in Settings (system audio + microphone)
2. SystemAudioCapture device-based capture mode
3. MicrophoneCapture specific device support
4. Device validation + disconnect handling

**Rationale:** This is the most mechanically complex change (CoreAudio refactoring) and is independently testable. The user can immediately benefit by selecting their Loopback device, even with manual recording.

**Phase 2 -- Manual Recording:**
1. Manual start/stop in menu bar
2. New RecordingEvent types in coordinator

**Rationale:** Quick win that makes audio device selection immediately useful. User can manually record Jump Desktop meetings while calendar integration is built.

**Phase 3 -- Google Calendar Integration:**
1. Google OAuth2 sign-in (loopback + PKCE)
2. Calendar event fetching with incremental sync
3. Calendar-triggered auto-start recording
4. Pre-meeting notifications
5. Calendar event metadata in meeting list

**Rationale:** Biggest feature, most external dependencies (Google API Console setup, OAuth consent screen configuration). Benefits from audio device selection already working.

**Defer:**
- Multiple Google account support: add after single-account is proven
- Smart grace period extension: small enhancement, add after core calendar flow works
- Calendar filtering: only if users report noise from all-calendar monitoring

## Complexity Budget

| Feature | Estimated Effort | Risk Level |
|---------|-----------------|------------|
| Audio device picker (UI) | 1-2 days | Low -- SimplyCoreAudio already in project |
| SystemAudioCapture device mode | 2-3 days | Medium -- new CoreAudio capture path, needs careful testing |
| MicrophoneCapture device mode | 1 day | Low -- well-documented AudioUnit property |
| Manual start/stop recording | 1 day | Low -- coordinator already supports the pattern |
| Google OAuth2 | 2-3 days | Medium -- loopback HTTP server, PKCE, Keychain storage |
| Calendar sync + event list | 2 days | Low -- REST API, well-documented |
| Calendar-triggered recording | 2-3 days | Medium -- timer scheduling, cancellation edge cases |
| Pre-meeting notifications | 1 day | Low -- UNUserNotificationCenter already in use |
| Meeting metadata migration | 0.5 days | Low -- simple GRDB migration |

**Total: ~13-17 days of focused development**

## Sources

- [Google OAuth2 for Desktop Apps](https://developers.google.com/identity/protocols/oauth2/native-app) -- loopback redirect, PKCE flow, token exchange
- [Google Calendar API Scopes](https://developers.google.com/workspace/calendar/api/auth) -- `calendar.events.readonly` recommended
- [Google Calendar API Sync](https://developers.google.com/workspace/calendar/api/guides/sync) -- incremental sync with `syncToken`, 410 GONE handling
- [Google Calendar API Quotas](https://developers.google.com/workspace/calendar/api/guides/quota) -- per-minute rate limits, exponential backoff
- [Google Loopback IP Migration](https://developers.google.com/identity/protocols/oauth2/resources/loopback-migration) -- custom URI deprecated, loopback IP required
- [SimplyCoreAudio](https://github.com/rnine/SimplyCoreAudio) -- device enumeration, change notifications (already a dependency)
- [Apple: Scheduling Local Notifications](https://developer.apple.com/documentation/usernotifications/scheduling-a-notification-locally-from-your-app) -- `UNUserNotificationCenter` for pre-meeting alerts
- [Rogue Amoeba Loopback](https://rogueamoeba.com/loopback/) -- virtual device behavior, CoreAudio integration
- [MacWhisper Meeting Recording](https://macwhisper.helpscoutdocs.com/article/30-record-meetings) -- competitor UX: notification-based, manual confirm
- [Krisp Meeting Recorder](https://krisp.ai/meeting-recording/) -- competitor UX: calendar-integrated, auto-record toggle

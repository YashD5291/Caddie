# Google Calendar Integration Design

**Date:** 2026-04-04
**Status:** Approved
**Scope:** Fetch and display today's Google Calendar events, use them as meeting detection signals with user-prompted recording.

## Summary

Replace the EventKit-based CalendarMonitor with a Google Calendar REST API client. Show today's events in the sidebar above the recordings list. When an event is in progress and a second detection signal fires, prompt the user via macOS notification to start recording.

## Architecture

### New Components

**`GoogleCalendarService` (actor)** — `Sources/Calendar/GoogleCalendarService.swift`
- Polls `GET /calendar/v3/calendars/primary/events` every 5 minutes
- Query: `timeMin=start of today`, `timeMax=end of today`, `singleEvents=true`, `orderBy=startTime`
- Filters: excludes all-day events, requires 2+ attendees for detection signals
- Caches events in memory as `[GoogleCalendarEvent]`
- Checks cached events against current time every 30 seconds for active event window
- Emits `DetectionSignal(source: .googleCalendar)` when an event window starts
- Uses `GoogleAuthManager.validAccessToken()` for auth (auto-refresh handled)
- No-ops gracefully when user is not signed into Google

**`GoogleCalendarEvent` model** — `Sources/Calendar/GoogleCalendarEvent.swift`
- Lightweight Codable struct matching Google Calendar API v3 response
- Fields: `id`, `summary` (title), `start` (DateTime), `end` (DateTime), `attendees` (count), `hangoutLink` or `conferenceData` (meeting URL)
- Not persisted to database — fetched fresh each poll cycle
- Computed properties: `isNow`, `isPast`, `isUpcoming`, `timeUntilStart`

### Modified Components

**`AppState`** — `Sources/App/AppState.swift`
- New observable property: `todayEvents: [GoogleCalendarEvent] = []`
- New dependency: `calendarService: GoogleCalendarService?` (nil when not signed in)
- Initialize `GoogleCalendarService` after auth restore if signed in
- Wire service callback to update `todayEvents` on each poll
- Wire service detection callback to `MeetingDetector`

**`MeetingDetector`** — `Sources/Detection/MeetingDetector.swift`
- Replace `CalendarMonitor` with signal input from `GoogleCalendarService`
- Accept `.googleCalendar` as signal source (replaces `.calendar`)
- Detection rule change: when googleCalendar + one other signal → prompt user (not auto-record)

**`DetectionSignal`** — `Sources/Detection/MeetingPatterns.swift`
- Add `.googleCalendar` case to `SignalSource` enum
- Remove `.calendar` case (EventKit path removed)

**`NotificationManager`** — `Sources/Utilities/NotificationManager.swift`
- New method: `promptToRecord(eventTitle:)` — sends actionable notification
- Actions: "Record" (starts manual recording with event title), "Dismiss" (silences for this event)
- Notification category registered on app launch

**`RecordingCoordinator`** — Wire notification response to `startManualRecording()` with event title

### Removed Components

**`CalendarMonitor.swift`** — Deleted. No more EventKit dependency.
- The `com.apple.security.personal-information.calendars` entitlement can be removed from `Caddie.entitlements`

## UI Design

### Sidebar: Today's Schedule

Collapsible section at the top of the sidebar (above "Recordings" list in `MeetingListView`).

**Event row:** Left color bar + title + time range + attendee count + status label
- **Past events:** Grey bar, dimmed (0.5 opacity), "Done" label
- **In-progress events:** Green bar (#34C759), subtle green background tint, "Now" label
- **Upcoming events:** Blue bar (#0A84FF), relative countdown ("in 3h", "in 20m")

**Empty states:**
- Signed in, no events: "No events today"
- Not signed in: "Sign in to Google in Settings to sync your calendar"

**Section header:** "TODAY'S SCHEDULE" with event count badge

### No Database Changes

Google Calendar events are transient — fetched fresh every 5 minutes, held in memory only. No migration needed. The existing `Meeting` model (recordings) is unchanged.

## Detection & Notification Flow

1. `GoogleCalendarService` polls every 5 min, updates `todayEvents` on AppState
2. Every 30 seconds, service checks if any cached event is currently in its time window
3. If an event with 2+ attendees is active → emits `DetectionSignal(source: .googleCalendar, calendarEvent: title, isActive: true)`
4. `MeetingDetector` receives signal, adds to `activeSignals`
5. When `DecisionEngine.evaluate()` sees googleCalendar + one other signal (mic, audioProcess, windowTitle):
   - Instead of `onMeetingStarted` → calls `onMeetingPrompt` callback
   - `NotificationManager.promptToRecord(eventTitle:)` fires macOS notification
6. User clicks "Record" → `AppState.startManualRecording()` with calendar event title
7. User clicks "Dismiss" → event ID added to `dismissedEvents` set, won't re-prompt
8. If user is already recording → no prompt sent

## Error Handling

- **Not signed in:** GoogleCalendarService is nil. No calendar signals. Other detection works normally.
- **Token expired:** `validAccessToken()` auto-refreshes. Transparent to service.
- **API error (network, quota):** Log warning, keep serving cached events, retry on next poll cycle.
- **Google returns 401:** Token refresh failed. Set auth state to `.signedOut`, clear calendar events from UI.
- **Empty response:** Show "No events today" in sidebar. No detection signals emitted.

## Testing Strategy

- `GoogleCalendarServiceTests`: Mock URLSession responses, verify event parsing, filtering, poll timing
- `GoogleCalendarEventTests`: Codable decoding from sample Google API JSON, computed properties (isNow, isPast, etc.)
- `DetectionSignalTests`: Verify `.googleCalendar` source works with DecisionEngine rules
- `NotificationManagerTests`: Verify prompt notification is created with correct content and actions

## Files Changed

| Action | File | Purpose |
|--------|------|---------|
| **New** | `Sources/Calendar/GoogleCalendarService.swift` | API client actor |
| **New** | `Sources/Calendar/GoogleCalendarEvent.swift` | Event model |
| **Modify** | `Sources/App/AppState.swift` | Add todayEvents, wire service |
| **Modify** | `Sources/Detection/MeetingDetector.swift` | Remove CalendarMonitor, accept service signals |
| **Modify** | `Sources/Detection/MeetingPatterns.swift` | .googleCalendar signal source |
| **Modify** | `Sources/UI/MainWindow/MeetingListView.swift` | Today's Schedule section |
| **Modify** | `Sources/Utilities/NotificationManager.swift` | Actionable record prompt |
| **Delete** | `Sources/Detection/CalendarMonitor.swift` | Replaced by GoogleCalendarService |
| **Modify** | `Resources/Caddie.entitlements` | Remove calendar entitlement |
| **Modify** | `Tests/` | New test files for service, model, detection |

## Dependencies

No new SPM packages. Uses Foundation `URLSession` for API calls. Google Calendar API v3 is a simple REST API — no SDK needed.

## Out of Scope

- Google Calendar write access (creating/modifying events)
- Multi-calendar support (only primary calendar)
- Incremental sync with syncToken (full fetch each poll is fine for today-only scope)
- Offline calendar caching beyond the in-memory poll cache
- Menu bar event display (sidebar only for now)

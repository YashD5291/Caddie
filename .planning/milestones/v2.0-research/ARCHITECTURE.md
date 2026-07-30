# Architecture Patterns

**Domain:** Google Calendar integration + audio device selection for existing macOS meeting recorder
**Researched:** 2026-03-24

## Recommended Architecture

### High-Level Integration Map

```
Existing (untouched)              New Components                  Modified Components
--------------------              --------------                  -------------------
TranscriptionPipeline             GoogleAuthManager                MeetingDetector (extend DecisionEngine)
ASREngine / DiarizationEngine     GoogleCalendarService            RecordingCoordinator (new events)
AudioFileManager                  AudioDeviceManager               AudioRecorder (device injection)
AppDatabase (schema extends)      CalendarScheduler                SystemAudioCapture (device param)
MeetingListView                   KeychainHelper                   MicrophoneCapture (device param)
MeetingDetailView                 GoogleCalendarModels             AppState (new properties)
CalendarMonitor (EventKit)                                         SettingsView (new sections)
                                                                   MenuBarView (manual controls)
                                                                   Meeting model (new columns)
                                                                   Migrations (v2 migration)
                                                                   NotificationManager (pre-meeting)
                                                                   MeetingPatterns (new SignalSource)
                                                                   Info.plist (URL scheme)
```

### Data Flow: Calendar-Triggered Recording

```
Google Calendar API
        |
        v
GoogleCalendarService (polls events via syncToken, caches in memory)
        |
        v
CalendarScheduler (computes upcoming meetings, fires pre-meeting notifications)
        |
        v
MeetingDetector.handleSignal() (emits DetectionSignal with .googleCalendar source)
        |
        v
MeetingDetector.DecisionEngine (calendar-only trigger -- no other signals needed)
        |
        v
RecordingCoordinator.handle(.meetingDetected) -- existing state machine flow
        |
        v
AudioRecorder.start(outputPath:, processID: nil, systemDeviceUID: selected, micDeviceUID: selected)
        |
        v
SystemAudioCapture (device-based) / MicrophoneCapture (device-based)
```

### Data Flow: OAuth2 Authentication

```
User clicks "Sign in with Google" in Settings
        |
        v
GoogleAuthManager.signIn()
  1. Generate PKCE code_verifier + code_challenge
  2. Open ASWebAuthenticationSession with Google's auth URL
  3. User authenticates in system browser
  4. ASWebAuthenticationSession captures redirect via custom URI scheme
  5. Exchange auth code + code_verifier for access_token + refresh_token
  6. Store refresh_token + access_token in macOS Keychain
        |
        v
GoogleCalendarService.startPolling() -- authorized
```

**OAuth redirect mechanism:** ASWebAuthenticationSession with custom URI scheme (reversed Google client ID, e.g., `com.googleusercontent.apps.CLIENT_ID:/oauth2redirect/google`). This is simpler than spinning up a loopback HTTP server -- ASWebAuthenticationSession handles browser lifecycle, session isolation, and redirect capture natively on macOS 14.2+.

## Component Boundaries

### NEW: GoogleAuthManager (`Sources/Calendar/GoogleAuthManager.swift`)

| Aspect | Detail |
|--------|--------|
| **Responsibility** | OAuth2 Authorization Code + PKCE flow, token storage/refresh |
| **Communicates With** | Keychain (storage), ASWebAuthenticationSession (auth), Google token endpoint (exchange/refresh) |
| **Pattern** | Actor -- owns mutable token state, **serializes refresh requests** |
| **State** | `.signedOut`, `.signingIn`, `.signedIn`, `.error(String)` |

Key design decisions:
- **Use ASWebAuthenticationSession + PKCE, not GoogleSignIn SDK.** ASWebAuthenticationSession is Apple's first-party API for browser-based OAuth. It handles the browser popup, session isolation, and redirect capture. No third-party dependency needed. GoogleSignIn SDK adds 3+ transitive deps for something that's ~150 lines of code.
- **Store tokens in macOS Keychain** via Security framework directly. We need 3 items: access_token, refresh_token, and expiry timestamp. A thin KeychainHelper enum suffices.
- **Serialize token refresh** through the actor. When multiple callers discover an expired token simultaneously, only one refresh request fires. Others await the result. This prevents the `invalid_grant` race condition documented in PITFALLS.md.
- **Proactive refresh** 5 minutes before expiry rather than waiting for 401 responses.

```swift
actor GoogleAuthManager {
    enum AuthState: Sendable {
        case signedOut
        case signingIn
        case signedIn
        case error(String)
    }

    private(set) var state: AuthState = .signedOut

    /// Opens ASWebAuthenticationSession, captures redirect, exchanges code for tokens.
    func signIn(presenting window: NSWindow) async throws
    /// Clears Keychain tokens and revokes Google token via revocation endpoint.
    func signOut() async
    /// Returns cached access token or transparently refreshes if expired/near-expiry.
    /// Serializes concurrent refresh attempts through a single in-flight request.
    func validAccessToken() async throws -> String
}
```

### NEW: GoogleCalendarService (`Sources/Calendar/GoogleCalendarService.swift`)

| Aspect | Detail |
|--------|--------|
| **Responsibility** | Fetch events from Google Calendar API, cache locally, provide upcoming meetings |
| **Communicates With** | GoogleAuthManager (tokens), Google Calendar REST API (events.list) |
| **Pattern** | Actor -- serializes API calls, owns event cache |

Key design decisions:
- **Direct URLSession + Codable.** One REST endpoint: `GET /calendar/v3/calendars/primary/events`. No GoogleAPIClientForREST needed.
- **Incremental sync with syncToken.** Initial full sync stores `nextSyncToken`. Subsequent polls send it back, receiving only changes. Handle 410 Gone by clearing cache and re-syncing.
- **Adaptive polling:** Every 60 seconds when meetings are within 15 min. Every 5 minutes otherwise. Every 15 minutes when nothing is upcoming in 2 hours.
- **In-memory cache** (`[CalendarEvent]`). Calendar events are ephemeral scheduling data -- no SQLite table needed.
- **Scope:** `calendar.events.readonly` (minimum required, sensitive but not restricted).

```swift
actor GoogleCalendarService {
    func startPolling()
    func stopPolling()
    func upcomingEvents(within minutes: Int) -> [CalendarEvent]
    func forceSync() async throws  // Manual refresh from UI
}
```

### NEW: CalendarScheduler (`Sources/Calendar/CalendarScheduler.swift`)

| Aspect | Detail |
|--------|--------|
| **Responsibility** | Schedule pre-meeting notifications and auto-start triggers based on cached events |
| **Communicates With** | GoogleCalendarService (event data), NotificationManager (pre-meeting alerts), MeetingDetector (trigger signals) |
| **Pattern** | `@Observable` class on MainActor -- drives UI for upcoming meetings |

Key design decisions:
- **Maintains sorted list of upcoming meetings** from GoogleCalendarService.
- **Fires pre-meeting notification** 2 minutes before meeting start (configurable).
- **At meeting start time**, calls `MeetingDetector.handleSignal()` with a `.googleCalendar` DetectionSignal.
- **Timer-based scheduling** (consistent with existing monitor patterns).
- **Filters:** Exclude all-day events, exclude declined events, require 2+ attendees (same logic as existing CalendarMonitor for EventKit).

```swift
@MainActor
@Observable
final class CalendarScheduler {
    var upcomingMeetings: [ScheduledMeeting] = []
    var nextMeeting: ScheduledMeeting?

    func update(events: [CalendarEvent])
    func startScheduling()
    func stopScheduling()
}
```

### NEW: AudioDeviceManager (`Sources/Recording/AudioDeviceManager.swift`)

| Aspect | Detail |
|--------|--------|
| **Responsibility** | Enumerate audio input devices, persist user selection, provide selected device UID |
| **Communicates With** | CoreAudio (device enumeration), UserDefaults (persistence), SimplyCoreAudio (already a dependency) |
| **Pattern** | `@Observable` class on MainActor -- drives Settings UI picker |

Key design decisions:
- **SimplyCoreAudio for enumeration** -- already a dependency (MicStateMonitor). Provides `.allInputDevices` with name, UID, channel info.
- **Store device UID in UserDefaults** (not AudioDeviceID -- UIDs are persistent, IDs are transient).
- **Validate on startup** -- if stored UID no longer exists, fall back to default and notify user.
- **Listen for device changes** via `.deviceListDidChange` notification for dynamic UI updates.

```swift
@MainActor
@Observable
final class AudioDeviceManager {
    struct AudioDevice: Identifiable, Sendable {
        let id: String  // UID
        let name: String
        let isInput: Bool
        let manufacturer: String?
    }

    var availableInputDevices: [AudioDevice] = []
    var selectedSystemDeviceUID: String?   // nil = use process tap (v1.0 default behavior)
    var selectedMicDeviceUID: String?       // nil = system default mic

    func refresh()
    func selectSystemDevice(_ uid: String?)
    func selectMicDevice(_ uid: String?)
    func resolveDeviceID(uid: String) -> AudioDeviceID?  // UID -> transient ID at runtime
}
```

### NEW: KeychainHelper (`Sources/Utilities/KeychainHelper.swift`)

| Aspect | Detail |
|--------|--------|
| **Responsibility** | Thin wrapper over Security framework for OAuth token CRUD |
| **Communicates With** | macOS Keychain via Security framework |
| **Pattern** | Enum with static methods (like existing `Formatters`, `Permissions`) |

```swift
enum KeychainHelper {
    static func save(key: String, data: Data) throws
    static func load(key: String) throws -> Data?
    static func update(key: String, data: Data) throws
    static func delete(key: String) throws
}
```

Handles `errSecItemNotFound` (-25300) and `errSecDuplicateItem` (-25299) gracefully.

## Modified Components

### MeetingPatterns / DetectionSignal -- New Signal Source

**Change:** Add `case googleCalendar` to `DetectionSignal.SignalSource`. Add optional `attendees` and `meetingLink` fields to `DetectionSignal`.

```swift
enum SignalSource: String {
    case audioProcess
    case micState
    case windowTitle
    case calendar         // Existing: EventKit
    case googleCalendar   // New: Google Calendar API
}

struct DetectionSignal {
    let source: SignalSource
    let appName: String?
    let processId: pid_t?
    let windowTitle: String?
    let calendarEvent: String?
    let isActive: Bool
    // New fields
    let attendees: [String]?    // Email addresses from Google Calendar
    let meetingLink: String?    // Conference URL (meet.google.com/...)
    let eventStartTime: Date?   // For grace period extension
    let eventEndTime: Date?     // For grace period extension
}
```

**CalendarMonitor (EventKit) stays unchanged.** The new Google Calendar signals are injected by CalendarScheduler directly into MeetingDetector, bypassing CalendarMonitor. This preserves separation of concerns.

### MeetingDetector.DecisionEngine -- Calendar-Only Trigger

**Current rules** (all require 2+ signals):
```
audioProcess + mic
audioProcess + windowTitle
mic + calendar
windowTitle + calendar
```

**New rule (additive):**
```swift
// Google Calendar alone triggers recording (configurable)
let hasGoogleCalendar = active.contains { $0.source == .googleCalendar }
if hasGoogleCalendar {
    let event = active.first { $0.source == .googleCalendar }!
    let title = event.calendarEvent ?? "Calendar Meeting"
    return DetectedMeeting(app: "Google Calendar", title: title, processId: nil)
}
```

**Why calendar-only is valid:** The user joins meetings on a remote PC via Jump Desktop. There are NO local audio process, mic state, or window title signals when the meeting is on a remote machine. Google Calendar is the only signal source for these meetings.

### RecordingCoordinator -- New Events

**New `RecordingEvent` cases:**
```swift
case manualStart(title: String)       // Menu bar "Start Recording" button
case manualStop                       // Menu bar "Stop Recording" (distinct from meetingEnded)
```

**New `RecordingState.reduce()` transitions:**
```swift
case (.idle, .manualStart(let title)):
    let meetingId = generateMeetingId()
    let meeting = DetectedMeeting(app: "Manual", title: title, processId: nil)
    return (.recording(meetingId: meetingId), .startRecording(meetingId: meetingId, meeting: meeting))

case (.recording(let meetingId), .manualStop):
    return (.transcribing(meetingId: meetingId), .stopAndTranscribe(meetingId: meetingId))
```

**Device injection:** RecordingCoordinator passes selected device UIDs from AudioDeviceManager to AudioRecorder.

### AudioRecorder -- Accept Device UIDs

**Current:** `func start(outputPath: URL, processID: pid_t?) throws`
**New:** `func start(outputPath: URL, processID: pid_t?, systemDeviceUID: String?, micDeviceUID: String?) throws`

Behavior:
- `processID != nil && systemDeviceUID == nil` -- existing process tap path (v1.0 default)
- `processID == nil && systemDeviceUID != nil` -- new device-based capture (Loopback use case)
- `processID == nil && systemDeviceUID == nil` -- global tap (all system audio)
- `processID != nil && systemDeviceUID != nil` -- invalid, reject with error

### SystemAudioCapture -- Alternative Input Path

**New overload:** `func start(deviceUID: String, onBuffer: @escaping BufferCallback) throws`

When given a device UID:
1. Resolve UID to AudioDeviceID via `kAudioHardwarePropertyTranslateUIDToDevice`
2. Skip CATapDescription and aggregate device creation entirely
3. Create HAL Output AudioUnit directly with the resolved device as input
4. Same render callback, same 16kHz mono Int16 output format
5. Register `kAudioDevicePropertyDeviceIsAlive` listener on the device (same pattern as aggregate device)

This is actually **simpler** than the process tap path -- no tap, no aggregate device.

### MicrophoneCapture -- Accept Device UID

**Current:** `AVAudioEngine().inputNode` always uses system default.
**Recommended change:** Rewrite to use HAL AudioUnit (same pattern as SystemAudioCapture) when a specific device is selected.

AVAudioEngine's `inputNode` cannot target a specific device via public API. The workaround of reaching into the underlying AudioUnit with `kAudioOutputUnitProperty_CurrentDevice` is fragile and undocumented. A clean HAL AudioUnit implementation (same as SystemAudioCapture's render callback pattern) provides reliable device selection.

When `micDeviceUID` is nil, keep existing AVAudioEngine behavior for backward compatibility.

### Meeting Model + Migrations

**New columns (v2 migration):**
```sql
ALTER TABLE meetings ADD COLUMN google_event_id TEXT;
ALTER TABLE meetings ADD COLUMN attendees TEXT;       -- JSON array of names/emails
ALTER TABLE meetings ADD COLUMN meeting_link TEXT;     -- Conference URL
ALTER TABLE meetings ADD COLUMN source TEXT DEFAULT 'detection';  -- 'detection', 'calendar', 'manual'
```

**FTS5 update:** Add `attendees` to the FTS5 index so users can search by attendee name.

### AppState -- New Observable Properties

```swift
// Calendar state
var isGoogleSignedIn: Bool = false
var nextScheduledMeeting: ScheduledMeeting?
var googleAuthError: String?

// Device state
private(set) var audioDeviceManager = AudioDeviceManager()

// Calendar services (initialized only after OAuth sign-in)
private(set) var authManager: GoogleAuthManager?
private(set) var calendarService: GoogleCalendarService?
private(set) var scheduler: CalendarScheduler?
```

**OAuth initialization is separate from ML pipeline initialization.** The ML pipeline (models, ASR, diarization) initializes on app launch. Calendar services initialize only after the user signs in with Google. This keeps the existing init flow untouched.

### SettingsView -- New Sections

```
[Google Calendar]
  - Sign in / Sign out button
  - Status: "Connected as user@gmail.com" or "Not connected"
  - Auto-record calendar meetings: Toggle
  - Pre-meeting notification: Toggle + minutes picker (2, 5, 10 min)

[Audio Devices]
  - System audio source: Picker ["Default (process tap)", "Loopback Virtual", ...]
  - Microphone: Picker ["Default", "Built-in Microphone", "External USB Mic", ...]
  - Info text explaining device selection
```

### MenuBarView -- New Controls

```
[idle status section]
  - "Next: Standup in 12 min" (from CalendarScheduler, if signed in)
  - "Start Recording" button (manual trigger)

[recording status section -- existing, with enhancements]
  - Source label: "Calendar: Standup" or "Manual Recording" or "Detected: Zoom"
```

## Patterns to Follow

### Pattern 1: Actor for Network/Token Services
**What:** GoogleAuthManager and GoogleCalendarService as Swift actors
**When:** Any component managing mutable state across async boundaries
**Why:** Consistent with RecordingCoordinator actor. Serializes token refresh, prevents race conditions.

### Pattern 2: DetectionSignal Extension (Not New Protocol)
**What:** Extend `DetectionSignal.SignalSource` enum with `.googleCalendar`, add optional fields
**When:** Adding new meeting detection sources
**Why:** DecisionEngine already evaluates `[DetectionSignal]`. Additive change, zero impact on existing rules.

### Pattern 3: Two Capture Paths in SystemAudioCapture
**What:** Process tap path (existing) + device-based path (new), selected at `start()` time
**When:** Different audio source types require fundamentally different CoreAudio setup
**Why:** A process tap captures app output. A device captures device input. These are different CoreAudio operations. Don't force one to behave like the other.

### Pattern 4: CalendarScheduler Injects Signals Into MeetingDetector
**What:** CalendarScheduler calls `MeetingDetector.handleSignal()` directly, not through a DetectionMonitor
**When:** Signal source is timer-driven (scheduled events) rather than polling-driven
**Why:** CalendarScheduler knows exactly when to fire signals (event start time). It doesn't need to poll -- it schedules timers. Making it conform to `DetectionMonitor` would add unnecessary polling overhead.

### Pattern 5: Optional Integration (Calendar Works Independently of Device Selection)
**What:** Google Calendar and audio device selection are independently useful
**When:** User may want one feature without the other
**Why:** User can select a Loopback device for manual recording without Google Calendar. User can use Google Calendar with default devices. Features should not gate each other.

## Anti-Patterns to Avoid

### Anti-Pattern 1: GoogleSignIn SDK or AppAuth-iOS for macOS
**Why bad:** Heavy transitive deps (GTMSessionFetcher, GTMAppAuth) for a flow that's ~150 lines with ASWebAuthenticationSession.
**Instead:** ASWebAuthenticationSession + URLSession + Security framework.

### Anti-Pattern 2: GoogleAPIClientForREST for Calendar
**Why bad:** 50K+ line Obj-C library for one endpoint.
**Instead:** URLSession + Codable.

### Anti-Pattern 3: Storing Tokens in UserDefaults
**Why bad:** Plaintext on disk. Any process can read it.
**Instead:** macOS Keychain via Security framework.

### Anti-Pattern 4: SQLite Table for Calendar Events
**Why bad:** Creates sync state to maintain. Events change frequently on Google's side.
**Instead:** In-memory cache, refreshed via incremental sync.

### Anti-Pattern 5: Forcing Process Tap for Loopback Devices
**Why bad:** CATapDescription taps process audio output. Loopback presents audio as a standard input device.
**Instead:** Direct HAL device capture when a device UID is provided.

### Anti-Pattern 6: Changing System Default Input Programmatically
**Why bad:** `AudioObjectSetPropertyData` on `kAudioHardwarePropertyDefaultInputDevice` changes the global system setting. Affects all apps.
**Instead:** Set device on the specific AudioUnit instance only.

## File Organization

```
Sources/
  Calendar/                          <-- NEW directory
    GoogleAuthManager.swift          <-- OAuth2 + PKCE + ASWebAuthenticationSession
    GoogleCalendarService.swift      <-- REST API client + incremental sync
    CalendarScheduler.swift          <-- Timer-based scheduling + notifications
    GoogleCalendarModels.swift       <-- Codable structs for API responses
  Detection/
    CalendarMonitor.swift            <-- UNCHANGED (EventKit, remains active)
    MeetingDetector.swift            <-- MODIFIED (new DecisionEngine rule)
    MeetingPatterns.swift            <-- MODIFIED (new SignalSource case, new fields)
    AudioProcessMonitor.swift        <-- UNCHANGED
    MicStateMonitor.swift            <-- UNCHANGED
    WindowTitleMonitor.swift         <-- UNCHANGED
  Recording/
    AudioDeviceManager.swift         <-- NEW
    AudioRecorder.swift              <-- MODIFIED (device UID params)
    SystemAudioCapture.swift         <-- MODIFIED (alternative device-based path)
    MicrophoneCapture.swift          <-- MODIFIED (HAL AudioUnit for device selection)
    SPSCRingBuffer.swift             <-- UNCHANGED
  Storage/
    Meeting.swift                    <-- MODIFIED (new columns)
    Migrations.swift                 <-- MODIFIED (v2 migration)
    Database.swift                   <-- UNCHANGED
    AudioFileManager.swift           <-- UNCHANGED
  Utilities/
    KeychainHelper.swift             <-- NEW
    Logger.swift                     <-- UNCHANGED
    Permissions.swift                <-- UNCHANGED
    Formatters.swift                 <-- UNCHANGED
    NotificationManager.swift        <-- MODIFIED (pre-meeting notification)
  UI/
    Settings/
      SettingsView.swift             <-- MODIFIED (new sections)
      GoogleAccountSection.swift     <-- NEW
      AudioDeviceSection.swift       <-- NEW
    MenuBar/
      MenuBarView.swift              <-- MODIFIED (upcoming meeting, manual start)
    MainWindow/                      <-- MINOR CHANGES (show attendees, source)
    Onboarding/                      <-- UNCHANGED
  App/
    AppState.swift                   <-- MODIFIED (calendar + device state)
    CaddieApp.swift                  <-- UNCHANGED
  Coordinator/
    RecordingCoordinator.swift       <-- MODIFIED (device injection, manual start)
    RecordingState.swift             <-- MODIFIED (new event cases)
  Transcription/                     <-- UNCHANGED (entire directory)
  Models/                            <-- UNCHANGED (entire directory)
```

## Build Order (Dependency Graph)

```
Phase 1: Foundation (standalone, no cross-dependencies)
  1. KeychainHelper                -- standalone utility, testable immediately
  2. GoogleCalendarModels          -- standalone Codable structs, testable immediately
  3. DB Migration v2               -- standalone schema change, testable with in-memory DB
  4. AudioDeviceManager            -- standalone, uses SimplyCoreAudio (existing dep)

Phase 2: Audio Device Path (depend on Phase 1 items 3-4)
  5. SystemAudioCapture device path -- new start(deviceUID:) overload
  6. MicrophoneCapture device path  -- HAL AudioUnit for specific device
  7. AudioRecorder device params    -- passes UIDs to capture components
  8. RecordingState + Coordinator   -- manualStart/manualStop events

Phase 3: OAuth + Calendar API (depend on Phase 1 items 1-2)
  9.  GoogleAuthManager             -- ASWebAuthenticationSession + PKCE + Keychain
  10. GoogleCalendarService          -- REST API + incremental sync + adaptive polling
  11. DetectionSignal extension      -- .googleCalendar source + new fields

Phase 4: Orchestration (depends on Phases 2 + 3)
  12. CalendarScheduler              -- timer scheduling + pre-meeting notifications
  13. DecisionEngine update          -- calendar-only trigger rule
  14. RecordingCoordinator wiring    -- calendar + device injection into existing flow
  15. AppState integration           -- calendar state + device state + init flow

Phase 5: UI (depends on Phase 4)
  16. SettingsView new sections      -- Google account + audio device picker
  17. MenuBarView updates            -- upcoming meeting display + manual start
  18. MeetingDetailView updates      -- attendees + source display
  19. NotificationManager            -- pre-meeting notification scheduling
```

**Key insight:** Phases 2 (audio device) and 3 (OAuth + calendar) are **independent tracks** that can be built in parallel. They converge in Phase 4 when CalendarScheduler triggers recording on user-selected devices.

## Integration Risk Assessment

| Integration Point | Risk | Reason |
|-------------------|------|--------|
| ASWebAuthenticationSession OAuth2 | LOW | Apple first-party API, well-documented for macOS |
| Google Calendar REST API | LOW | Single endpoint, standard Codable, incremental sync documented |
| Keychain token storage | LOW | Standard macOS pattern, small API surface |
| Audio device enumeration | LOW | SimplyCoreAudio already in use for this |
| SystemAudioCapture device path | MEDIUM | New CoreAudio code path, needs testing with Loopback specifically |
| MicrophoneCapture device override | MEDIUM | Rewriting to HAL AudioUnit is more work but cleaner than hacking AVAudioEngine |
| DecisionEngine calendar-only rule | LOW | Additive change, existing rules untouched, all existing tests pass |
| RecordingCoordinator new events | LOW | State machine is well-tested, adding transition cases is mechanical |
| EventKit + Google Calendar dedup | MEDIUM | Both sources fire for the same Google Calendar. Need dedup by event title + time |
| Token refresh serialization | MEDIUM | Must be correct from day one. Race condition causes silent calendar failures |

## Sources

- [Google OAuth2 for Desktop/Native Apps](https://developers.google.com/identity/protocols/oauth2/native-app) -- HIGH confidence
- [Google Loopback Migration Guide](https://developers.google.com/identity/protocols/oauth2/resources/loopback-migration) -- HIGH confidence (desktop NOT deprecated)
- [ASWebAuthenticationSession](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession) -- HIGH confidence
- [Google Calendar API Events.list](https://developers.google.com/workspace/calendar/api/v3/reference/events/list) -- HIGH confidence
- [Google Calendar API Sync Guide](https://developers.google.com/workspace/calendar/api/guides/sync) -- HIGH confidence (syncToken, 410 handling)
- [Google Calendar Push Notifications](https://developers.google.com/workspace/calendar/api/guides/push) -- HIGH confidence (requires webhook, not suitable)
- [SimplyCoreAudio](https://github.com/rnine/SimplyCoreAudio) -- HIGH confidence (already in project)
- [Apple Developer Forums: AVAudioEngine Device Selection](https://developer.apple.com/forums/thread/71008) -- MEDIUM confidence
- [AudioKit #2130: AVAudioEngine device selection limitations](https://github.com/AudioKit/AudioKit/issues/2130) -- MEDIUM confidence
- [CoreAudio Device Enumeration Gist](https://gist.github.com/SteveTrewick/c0668ee438eb784cbc5fb4674f0c2cd1) -- MEDIUM confidence
- [Keychain Secure Storage in Swift](https://oneuptime.com/blog/post/2026-02-02-swift-keychain-secure-storage/view) -- MEDIUM confidence

# Technology Stack

**Project:** Caddie v2.0 -- Google Calendar + Audio Device Selection
**Researched:** 2026-03-24
**Scope:** NEW dependencies only. Existing stack (Swift 6.0, SwiftUI, GRDB, FluidAudio, SimplyCoreAudio, etc.) is validated and unchanged.

## Recommended Stack Additions

### Google OAuth2

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| ASWebAuthenticationSession (AuthenticationServices) | System framework | OAuth2 login flow | Apple's first-party, secure browser-based auth. Already ships with macOS 14.2+. No third-party dependency needed. Handles the browser popup, redirect capture, and session cleanup. |
| URLSession (Foundation) | System framework | Google Calendar REST API calls + token exchange | The Calendar API is a simple REST API with JSON responses. 3 endpoints needed (events.list, token exchange, token refresh). A dedicated Google API client library is massive overkill for read-only calendar access. |
| Security (Keychain) | System framework | Store OAuth2 refresh token | SecItemAdd/SecItemCopyMatching for persisting the refresh token. Native macOS Keychain is the correct place for credentials. No wrapper library needed -- the API surface is small (add, query, update, delete). |

### Google Calendar API

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| Google Calendar API v3 (REST) | v3 | Read upcoming meetings | Direct HTTP calls via URLSession. Endpoint: `GET /calendar/v3/calendars/primary/events`. Only read-only access needed. Scope: `calendar.events.readonly`. |

### Audio Device Selection

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| SimplyCoreAudio | 4.x (existing) | Enumerate audio input devices | Already a dependency. Provides `allInputDevices`, device name, UID, manufacturer. Also provides `.deviceListDidChange` notification for hot-plug detection. Even though archived (Mar 2024), it works on macOS 14.2+ and the underlying CoreAudio APIs it wraps are stable. |
| CoreAudio | System framework | Set capture device on AudioUnit | Already used by SystemAudioCapture. Device selection means passing a different `AudioDeviceID` to `kAudioOutputUnitProperty_CurrentDevice` instead of the aggregate device. |

### Pre-Meeting Notifications

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| UserNotifications (UNUserNotificationCenter) | System framework | Schedule "Recording starts in 2 min" alerts | Apple's standard local notification API. Works on macOS 14.2+. Supports time-interval triggers, actionable notifications, and respects Do Not Disturb. No library needed. |

## What NOT to Add

| Library | Why Not |
|---------|---------|
| **AppAuth-iOS** (openid/AppAuth-iOS v2.0.0) | Adds OAuth2 framework + OIDC discovery + session management for a flow that is ~150 lines of code with ASWebAuthenticationSession. Google's OAuth2 for desktop apps is well-documented with exact endpoints. AppAuth brings Objective-C bridging headers and complexity we don't need. |
| **google-api-swift-client** (googleapis) | Archived Jan 2026. Was experimental, never reached 1.0. Dead project. |
| **GoogleAPIClientForREST** (Obj-C) | Massive Objective-C library that generates typed clients for ALL Google APIs. We need exactly one endpoint (`events.list`). The JSON response is simple enough to decode with `Codable`. This library would be the single largest dependency in the app. |
| **GTMAppAuth** (google/GTMAppAuth) | Companion to GoogleAPIClientForREST. Same problem -- heavy Objective-C dependency for a simple OAuth flow. |
| **OAuthSwift** | Third-party OAuth library. ASWebAuthenticationSession is Apple's blessed solution and already handles the hard parts (secure browser, session isolation). Adding OAuthSwift just to avoid writing ~100 lines of token exchange code is not worth the dependency. |
| **p2/OAuth2** | Another OAuth framework. Same reasoning as OAuthSwift -- we don't need a framework for a single-provider, single-scope OAuth flow. |
| **KeychainAccess / SwiftKeychainWrapper** | Keychain wrapper libraries. The raw Security framework API for storing one refresh token is ~30 lines. A wrapper library for that is unnecessary. |
| **Any new CoreAudio wrapper** | SimplyCoreAudio is archived but stable. The CoreAudio APIs it wraps haven't changed. Switching to a different wrapper introduces risk for no benefit. If SimplyCoreAudio breaks in a future macOS, we can fork or drop to raw CoreAudio (which SystemAudioCapture already uses directly). |

## Alternatives Considered

| Category | Recommended | Alternative | Why Not |
|----------|-------------|-------------|---------|
| OAuth2 flow | ASWebAuthenticationSession + URLSession | AppAuth-iOS v2.0.0 | AppAuth adds Obj-C bridging, OIDC discovery we don't need, and complexity for a single-provider flow. ASWebAuthenticationSession + manual token exchange is simpler, testable, and dependency-free. |
| Calendar API client | Direct URLSession + Codable | GoogleAPIClientForREST | One endpoint needed. Obj-C library is 10x heavier than needed. Direct REST is more maintainable and lets us control retry/error handling. |
| Token storage | Security framework (Keychain) | UserDefaults | Never store OAuth tokens in UserDefaults. Keychain provides encryption at rest and proper access control. |
| Device enumeration | SimplyCoreAudio (existing) | Raw CoreAudio APIs | Already a dependency, already used by MicStateMonitor. Provides clean Swift API for device listing and change notifications. |
| Notifications | UNUserNotificationCenter | NSUserNotification (deprecated) | UNUserNotificationCenter is the modern API. NSUserNotification was deprecated in macOS 11. |

## OAuth2 Flow Design

**Client type:** Desktop application (Google Cloud Console)
**Redirect method:** Custom URI scheme (`com.caddie.app:/oauth2redirect`) via ASWebAuthenticationSession
**Why custom scheme over loopback:** ASWebAuthenticationSession natively supports custom URI schemes. No need to spin up a local HTTP server. Simpler, fewer moving parts. Google supports custom URI schemes for desktop apps. For Google specifically, the custom scheme is the reversed client ID (e.g., `com.googleusercontent.apps.CLIENT_ID:/oauth2redirect/google`).

**Flow:**
1. Generate PKCE code_verifier (43-128 char random string) + code_challenge (Base64URL-encoded SHA256)
2. Open ASWebAuthenticationSession with Google's auth URL + PKCE params + scope
3. User authenticates in system browser
4. Redirect captured by ASWebAuthenticationSession with auth code
5. Exchange auth code + code_verifier for access_token + refresh_token via URLSession POST
6. Store refresh_token in Keychain (SecItemAdd with kSecClassGenericPassword)
7. Use access_token for API calls; refresh when expired (HTTP 401 or proactive expiry check)

**Endpoints:**
- Authorization: `https://accounts.google.com/o/oauth2/v2/auth`
- Token exchange: `https://oauth2.googleapis.com/token`
- Token refresh: `https://oauth2.googleapis.com/token` (with `grant_type=refresh_token`)
- Events list: `GET https://www.googleapis.com/calendar/v3/calendars/primary/events`

**Scope:** `https://www.googleapis.com/auth/calendar.events.readonly` (minimum required for listing events with attendees)

**Token lifecycle:**
- Access tokens expire after ~1 hour
- Refresh tokens are long-lived (persist across app restarts via Keychain)
- On HTTP 401: use refresh token to get new access token, retry request
- On refresh failure (revoked access): clear Keychain, prompt re-auth

## Google Calendar API Usage

**Polling strategy:** Poll every 60 seconds for events in a window of [now - 5min, now + 30min]. This catches:
- Meetings starting soon (pre-meeting notification at T-2min)
- Meetings currently happening (auto-start recording)
- Recently ended meetings (grace period before stopping)

**Key parameters:**
```
timeMin: ISO 8601 (now - 5 min)
timeMax: ISO 8601 (now + 30 min)
singleEvents: true (expand recurring events)
orderBy: startTime
maxResults: 10
```

**Response decoding:** Standard `Codable` structs for the Calendar Event JSON. Key fields: `summary`, `start.dateTime`, `end.dateTime`, `attendees[].email`, `status`, `conferenceData`.

## Audio Device Selection Design

**Current state:** SystemAudioCapture creates a process tap + aggregate device. MicrophoneCapture uses `AVAudioEngine.inputNode` which always uses the system default input device.

**What changes for device selection:**
1. New `AudioDeviceManager` class wrapping SimplyCoreAudio for device enumeration
2. `MicrophoneCapture` needs a method to target a specific input device (not just default)
3. `AudioRecorder.start()` gets an optional `inputDeviceID: AudioDeviceID?` parameter
4. Settings UI gets a device picker dropdown
5. Selected device UID stored in UserDefaults (survives app restart, UID is stable across reboots)

**Device enumeration API (SimplyCoreAudio, already available):**
```swift
let sca = SimplyCoreAudio()
let inputDevices = sca.allInputDevices  // includes virtual devices like Loopback
// Each device has: .name, .uid, .manufacturer, .id (AudioDeviceID)
```

**Hot-plug detection (SimplyCoreAudio, already available):**
```swift
NotificationCenter.default.addObserver(forName: .deviceListDidChange, ...)
```

**Setting a specific input device on AVAudioEngine:**
```swift
// Get the AudioDeviceID for the selected device
let deviceID: AudioDeviceID = selectedDevice.id
var id = deviceID
// Set on the AVAudioEngine's inputNode
AudioUnitSetProperty(
    engine.inputNode.audioUnit!,
    kAudioOutputUnitProperty_CurrentDevice,
    kAudioUnitScope_Global, 0,
    &id, UInt32(MemoryLayout<AudioDeviceID>.size)
)
```

## Entitlements Changes

**Current entitlements:**
- `com.apple.security.device.audio-input` (microphone)
- `com.apple.security.personal-information.calendars` (EventKit)

**New entitlements needed:** None. The app is not sandboxed (no `com.apple.security.app-sandbox`), so outgoing network connections for Google Calendar API work without additional entitlements.

**Info.plist additions:**
- `CFBundleURLTypes` with URL scheme for OAuth redirect (reversed client ID from Google Cloud Console)

## Installation

**No new SPM packages needed.** All new capabilities use system frameworks:

```
AuthenticationServices  -- ASWebAuthenticationSession (OAuth2 login)
Security               -- Keychain (token storage)
UserNotifications      -- UNUserNotificationCenter (pre-meeting alerts)
Foundation/URLSession  -- Google Calendar REST API calls
```

Existing dependency SimplyCoreAudio already provides device enumeration.

**project.yml changes:** None for dependencies. Only Info.plist and potentially entitlements need updating.

## Confidence Assessment

| Area | Confidence | Reason |
|------|------------|--------|
| OAuth2 flow (ASWebAuthenticationSession + PKCE) | HIGH | Apple first-party API, Google officially documents this flow for desktop apps, multiple verified examples |
| Google Calendar REST API | HIGH | Official Google docs, well-documented REST endpoints, standard Codable decoding |
| Keychain token storage | HIGH | Standard macOS pattern, Security framework is stable |
| Audio device enumeration (SimplyCoreAudio) | HIGH | Already in use in MicStateMonitor, device listing API is straightforward |
| Setting specific input device on AVAudioEngine | MEDIUM | CoreAudio API is documented but setting input device on AVAudioEngine.inputNode requires AudioUnit-level property manipulation. Needs testing with Loopback virtual device specifically. |
| UNUserNotificationCenter for pre-meeting | HIGH | Standard macOS notification API, well-documented |
| Zero new dependencies needed | MEDIUM | Validated that direct URLSession works for Calendar API. Token refresh edge cases (revocation, network errors) may surface complexity but not library-level complexity. |

## Sources

- [Google OAuth2 for Desktop Apps](https://developers.google.com/identity/protocols/oauth2/native-app) -- Official flow documentation, endpoints, PKCE parameters
- [Google Calendar Events.list](https://developers.google.com/workspace/calendar/api/v3/reference/events/list) -- REST endpoint, parameters, response format
- [Google Calendar API Scopes](https://developers.google.com/workspace/calendar/api/auth) -- `calendar.events.readonly` is minimum scope
- [Loopback Migration Guide](https://developers.google.com/identity/protocols/oauth2/resources/loopback-migration) -- Confirms loopback NOT deprecated for desktop apps
- [ASWebAuthenticationSession](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession) -- Apple docs
- [AppAuth-iOS v2.0.0](https://github.com/openid/AppAuth-iOS/releases) -- Evaluated and rejected (too heavy for single-provider flow)
- [google-api-swift-client](https://github.com/googleapis/google-api-swift-client) -- Archived Jan 2026, experimental, do not use
- [GoogleAPIClientForREST](https://swiftpackageindex.com/google/google-api-objectivec-client-for-rest) -- Evaluated and rejected (massive Obj-C library for one endpoint)
- [SimplyCoreAudio](https://github.com/rnine/SimplyCoreAudio) -- Archived Mar 2024, v4.1.1, but stable and already in use
- [UNUserNotificationCenter](https://developer.apple.com/documentation/usernotifications/unusernotificationcenter) -- Apple docs for local notifications
- [CoreAudio Device Enumeration Gist](https://gist.github.com/SteveTrewick/c0668ee438eb784cbc5fb4674f0c2cd1) -- Swift device listing patterns

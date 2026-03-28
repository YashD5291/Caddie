# Domain Pitfalls

**Domain:** Google Calendar OAuth2 integration + audio device selection for macOS meeting recorder
**Researched:** 2026-03-24
**Confidence:** HIGH (verified against Google official docs, Apple docs, codebase analysis, community reports)

---

## Critical Pitfalls

Mistakes that cause rewrites, data loss, or broken user experience.

---

### Pitfall 1: OAuth2 Token Refresh Race Condition Causes Silent Calendar Failures

**What goes wrong:**
Google OAuth2 access tokens expire after 1 hour. When two concurrent calendar API requests discover the token is expired simultaneously, both attempt to refresh using the same refresh token. Google's token endpoint issues a new access token on the first refresh but may invalidate the refresh token (rotation). The second refresh request fails with `invalid_grant`. The app now has no valid tokens and cannot access the calendar until the user re-authenticates -- but nothing in the app detects this state. Calendar sync silently stops working. Meetings are missed because Caddie thinks it has calendar access but every API call fails.

**Why it happens:**
Caddie will poll the Calendar API periodically AND the user might trigger a manual sync from the UI. If both fire near the token expiry boundary, two refresh attempts race. This is especially common when the app wakes from sleep (laptop lid open) -- the token expired hours ago, and multiple subsystems all discover this at once.

**Consequences:**
- Calendar sync silently stops. No meetings detected from Google Calendar.
- User has no idea their OAuth session is broken until they miss a meeting.
- Violates core value: "every meeting must be reliably captured."

**Prevention:**
1. **Serialize all token refresh attempts** through a single async gate (e.g., an actor property `isRefreshing: Bool` with a continuation queue). When refresh is in progress, other callers suspend and receive the new token when it arrives.
2. **Proactively refresh tokens 5 minutes before expiry** rather than waiting for a 401 response. Store `expiresAt` alongside the access token.
3. **On `invalid_grant`**: immediately set a `calendarAuthBroken` state in AppState, show a persistent UI warning ("Calendar disconnected -- sign in again"), and stop all Calendar API polling.
4. **Retry once** on 401, then escalate to re-auth.

**Detection:**
- Calendar API calls returning 401 repeatedly after a refresh attempt
- `invalid_grant` error from token endpoint
- Log messages showing two concurrent refresh attempts
- User reports that Caddie stopped detecting calendar meetings

**Phase to address:** OAuth2 implementation phase. Build the token refresh serialization from day one -- retrofitting it is painful.

**Confidence:** HIGH -- race condition documented in multiple OAuth2 libraries and Google's own issue tracker.

---

### Pitfall 2: Loopback Virtual Device Disappears During Recording When User Quits Loopback App

**What goes wrong:**
Caddie's v2.0 use case has the user selecting a Loopback virtual audio device as the capture source (routing Jump Desktop audio through Loopback). If the user quits Loopback (or Loopback's ACE audio component crashes), the virtual device disappears from CoreAudio's device list. The existing `SystemAudioCapture` uses a process tap on a specific process, but with a user-selected device, the capture path is different -- it targets a specific `AudioDeviceID`. When that device vanishes:

- The aggregate device built on top of it may crash or return `kAudioObjectUnknown`
- The render callback gets `AudioUnitRender` errors (OSStatus -10863 `kAudioUnitErr_CannotDoInCurrentContext`)
- Caddie currently has `onDeviceDisconnected` but it only fires for the aggregate device's alive listener -- a Loopback virtual device disappearing may not trigger `kAudioDevicePropertyDeviceIsAlive` because the device was never "alive" in the hardware sense

**Why it happens:**
Loopback virtual devices are software-created AudioObjects. They exist only while the Loopback kernel extension / user-space daemon is running. Unlike hardware devices that have USB disconnect events, virtual device removal is handled differently by CoreAudio. On macOS 14.5+, Loopback uses a new capture mechanism that does not require a system extension, making it even more transient.

**Consequences:**
- Recording produces silence from the moment the device disappears
- No error notification to the user
- Meeting audio is partially or fully lost
- Existing `onDeviceDisconnected` handler may not fire for virtual devices

**Prevention:**
1. **Register for `kAudioHardwarePropertyDevices` changes** on the system AudioObject to detect when devices are added/removed, not just device-alive on a specific device
2. **Periodically validate the selected device still exists** during recording (every 5-10 seconds, check device ID is in the system device list)
3. **When the selected device disappears mid-recording**: fall back to the default system audio tap (existing behavior), log a warning, and show a persistent menu bar notification
4. **On recording start**: verify the selected device exists before creating the capture. If it is gone, show an error and refuse to start with a clear message: "Selected audio device not found. Open Loopback first."

**Detection:**
- `AudioUnitRender` returning non-zero OSStatus during recording
- `kAudioHardwarePropertyDevices` change notification with the selected device ID no longer in the list
- Silence on the system audio channel despite active meeting

**Phase to address:** Audio device selection phase. The device picker and device monitoring must be built together.

**Confidence:** HIGH -- confirmed by Loopback documentation and CoreAudio behavior with virtual devices.

---

### Pitfall 3: Google Calendar Sync Token Becomes Invalid (410 Gone) With No Recovery Path

**What goes wrong:**
Google Calendar's incremental sync uses sync tokens. After the initial full sync, Caddie stores a `nextSyncToken` and uses it for subsequent requests to get only changed events. The server can invalidate this token at any time (token expiration, ACL changes, Google-side infrastructure changes), returning HTTP 410 Gone. If Caddie does not handle 410 correctly, it:
- Keeps retrying with the stale sync token, getting 410 every time
- Or crashes/throws an unhandled error
- Calendar data becomes stale. New meetings are never discovered. Existing meetings are not updated.

Per Google's documentation: "The server will respond to an incremental request with a response code 410. This should trigger a full wipe of the client's store and a new full sync."

**Why it happens:**
Developers often handle 200 (success) and 401 (auth), but 410 is uncommon and easy to miss. The requirement to "full wipe the client's store" is counterintuitive -- most developers retry the same request rather than resetting state.

**Consequences:**
- Calendar data goes stale silently
- Meetings added/changed after the token invalidation are never seen
- If recovery involves a full resync, all local event IDs change, potentially breaking references from existing meeting recordings

**Prevention:**
1. **Explicitly handle HTTP 410 in every Calendar API call path.** On 410:
   - Delete the stored sync token
   - Delete all cached calendar events from the local database
   - Perform a fresh full sync
   - Re-link any existing meeting recordings to the new event data by matching on event title + time window
2. **Log the 410 event** prominently (not as a warning -- as an info-level recovery event)
3. **Test this path explicitly** -- it will happen in production, probably within the first month

**Detection:**
- HTTP 410 response from Calendar API
- Calendar events list in Caddie does not match user's actual Google Calendar
- Log entries showing repeated 410 errors with no recovery

**Phase to address:** Calendar sync implementation phase. Handle 410 from the start.

**Confidence:** HIGH -- documented requirement in Google Calendar API sync guide.

---

### Pitfall 4: Privacy Contradiction -- "Zero Cloud" App Now Sends Meeting Data to Google

**What goes wrong:**
Caddie's core identity is "zero cloud dependency -- nothing leaves the device." Adding Google Calendar OAuth2 means:
- Meeting titles, attendees, and times are fetched FROM Google (acceptable -- they originated there)
- But the OAuth2 flow sends the user's Google identity to Google's auth servers (obviously necessary)
- The app's Google Cloud Console project is tied to a developer account, meaning Google knows which users authorized Caddie
- Google's Calendar API TOS requires a privacy policy explaining data access
- If the app ever requests `calendar.events` (read/write) instead of `calendar.readonly`, Google requires a more invasive verification process including a security audit

The real pitfall is not technical but perceptual: users chose Caddie because it is private. Seeing "This app wants to access your Google Calendar" in an OAuth dialog may cause immediate trust erosion. If the privacy policy is vague or the consent screen lists unnecessary scopes, users will bail.

**Why it happens:**
Google Calendar integration is inherently a cloud dependency. There is no local-only way to read Google Calendar events.

**Consequences:**
- User trust erosion if the integration feels invasive
- Google OAuth verification process blocks distribution if scopes are sensitive
- Privacy policy must be written and hosted
- If not handled carefully, breaks the brand promise

**Prevention:**
1. **Request only `calendar.readonly` scope** -- never `calendar.events`. This is a "sensitive" scope but not "restricted," so verification is lighter.
2. **Make Google Calendar integration optional** with clear UI separation. The app must work fully without it (local EventKit calendar detection remains).
3. **Pre-sign-in explanation screen** before the OAuth dialog: explain exactly what data Caddie accesses and that meeting titles/times are stored only locally.
4. **Write the privacy policy now**, before building the OAuth flow. It must be hosted publicly (Google requires it during consent screen configuration).
5. **Use the "testing" mode** during development (limited to 100 users) to avoid verification delays.
6. **Never store Google Calendar event data in a way that could be synced or exported** without the user's explicit action.

**Detection:**
- Users abandoning the OAuth flow without completing it (if you track this)
- App Store reviews mentioning privacy concerns
- Google rejecting the OAuth consent screen verification

**Phase to address:** First phase -- decide the integration boundary before writing any code. The privacy policy and consent screen must be configured before the OAuth flow can be tested.

**Confidence:** HIGH -- Google's verification requirements are well-documented.

---

### Pitfall 5: AVAudioEngine Cannot Select a Specific Input Device -- Architecture Mismatch

**What goes wrong:**
Caddie's `MicrophoneCapture` uses `AVAudioEngine` for microphone capture. AVAudioEngine's `inputNode` is hardwired to the system default input device. There is no AVFoundation API to select a specific input device. If the user selects a Loopback virtual device as their audio input in Caddie's device picker, `MicrophoneCapture` cannot route to that device -- it always captures from the system default.

The existing `SystemAudioCapture` uses low-level CoreAudio (HAL AudioUnit + aggregate devices) which CAN target specific devices. But `MicrophoneCapture` is built on a fundamentally different API that does not support device selection.

**Why it happens:**
AVAudioEngine was designed for simplicity, trading away device selection flexibility. Apple's documentation states the input node "communicates with the system's default input." This was fine for v1.0 where Caddie always captured from the default mic, but v2.0 requires targeting specific devices.

**Consequences:**
- Audio device picker appears to work but microphone capture ignores the selection
- User selects "Loopback Virtual Device" but microphone still captures from MacBook built-in mic
- The two channels (system + mic) come from different devices, causing confusion

**Prevention:**
1. **Do NOT try to change the system default input programmatically** (via `AudioObjectSetPropertyData` on `kAudioHardwarePropertyDefaultInputDevice`). This changes the global system setting and affects all apps.
2. **Two approaches for device selection:**
   - **Approach A (recommended):** Rewrite `MicrophoneCapture` to use the same HAL AudioUnit pattern as `SystemAudioCapture`. Use `kAudioOutputUnitProperty_CurrentDevice` to set the specific device. This gives full control over which device to capture from.
   - **Approach B (quick but hacky):** Keep AVAudioEngine but tell users to change their system default input in System Settings. Not recommended -- terrible UX and breaks other apps.
3. **For the Loopback/Jump Desktop use case specifically:** The user likely wants BOTH channels from the same Loopback virtual device (system audio routed through Loopback AND mic routed through Loopback). This may mean capturing a single stereo device rather than two separate devices. The AudioRecorder architecture (system + mic as separate captures) may need rethinking for this use case.

**Detection:**
- Device picker shows non-default device selected but `AVAudioEngine.inputNode.outputFormat` still shows the default device's format
- Audio from the wrong device appearing in recordings

**Phase to address:** Audio device selection phase. This is an architecture-level decision that must be made before building the device picker UI.

**Confidence:** HIGH -- confirmed by Apple documentation and multiple AudioKit/Apple Forum threads.

---

## Moderate Pitfalls

---

### Pitfall 6: Google OAuth Loopback Redirect Blocked by Firewall or Port Conflict

**What goes wrong:**
Google OAuth2 for desktop apps uses a loopback HTTP redirect (`http://127.0.0.1:<port>`). The flow opens the system browser, user authorizes, and Google redirects back to the local HTTP server that the app started. This fails when:
- A local firewall blocks the loopback connection
- Another app is already using the same port
- The port chosen is in a reserved range
- macOS's application firewall prompts "Do you want the application to accept incoming network connections?" -- user clicks "Deny"

**Why it happens:**
The loopback redirect requires starting a temporary HTTP server. This is the Google-recommended approach for desktop apps, but it has real-world failure modes that are rare but devastating when they occur.

**Prevention:**
1. **Bind to port 0** and let the OS assign an available port. Pass this port in the redirect_uri. Google's documentation supports dynamic port assignment for loopback redirects.
2. **Handle EADDRINUSE** by trying multiple ports (or relying on port 0).
3. **Set a timeout** (30-60 seconds) on the local server. If no redirect arrives, show an error with a "Try Again" button.
4. **Consider `ASWebAuthenticationSession`** as an alternative to the loopback server. It handles the browser flow natively on macOS and does not require a local HTTP server. However, it uses a custom URL scheme redirect which Google has deprecated for some client types -- verify compatibility with your Google Cloud Console client ID configuration.
5. **Implement PKCE** (Proof Key for Code Exchange) regardless of which redirect mechanism is used. Google requires it for native apps.

**Detection:**
- OAuth flow opens browser but Caddie never receives the redirect
- macOS firewall prompt appearing during sign-in
- User reports "I authorized but nothing happened"

**Phase to address:** OAuth implementation phase.

**Confidence:** MEDIUM -- loopback redirect is the documented standard, but edge cases depend on user's system configuration.

---

### Pitfall 7: Keychain Token Storage Survives App Deletion -- Stale Tokens After Reinstall

**What goes wrong:**
macOS Keychain items persist even after the app is uninstalled and reinstalled. If a user uninstalls Caddie (deleting the app and its Application Support data), then reinstalls, the Keychain still contains the old OAuth tokens. On first launch, the app finds valid-looking tokens in Keychain, skips the sign-in flow, and tries to use them. If the refresh token was revoked (user revoked access in Google Account settings), every API call fails with `invalid_grant` but the app thinks the user is signed in.

Conversely, if the Keychain entry is from a different bundle ID (developer changed signing identity during development), the Keychain items are inaccessible and the app silently fails to read them.

**Why it happens:**
macOS Keychain is designed to persist credentials across app reinstalls. This is usually a feature (password managers), but for OAuth tokens it creates stale state. The bundle ID and team ID must match exactly for Keychain access.

**Prevention:**
1. **On first launch** (check a UserDefaults flag), validate stored tokens by making a lightweight API call (e.g., `userinfo` endpoint or `calendarList.list` with `maxResults=1`). If the call fails, clear Keychain tokens and show the sign-in flow.
2. **Use `kSecAttrService` that includes a version identifier** so that major app updates can distinguish between token formats.
3. **Always handle `errSecItemNotFound` (-25300)** gracefully when reading from Keychain -- it is the expected state on fresh install.
4. **Handle `errSecDuplicateItem` (-25299)** when writing -- use `SecItemUpdate` instead of `SecItemAdd` when an item already exists.
5. **Include a "Sign Out" button** in Settings that explicitly deletes Keychain tokens and revokes the Google token via the revocation endpoint.

**Detection:**
- App shows "Connected to Google Calendar" but sync fails
- Keychain contains tokens from a previous installation
- `errSecDuplicateItem` errors when storing new tokens

**Phase to address:** OAuth implementation phase.

**Confidence:** HIGH -- well-documented Keychain behavior.

---

### Pitfall 8: Calendar Polling Frequency vs. API Quota -- Either Too Slow or Rate Limited

**What goes wrong:**
Google Calendar API has per-minute-per-user quotas (exact numbers vary, visible in Cloud Console). If Caddie polls too frequently:
- Hits rate limits, gets 403/429 errors
- Google may throttle the entire project if many users hit limits

If Caddie polls too infrequently:
- Misses last-minute meeting additions or time changes
- Meeting starts before Caddie knows about it
- Violates core value of reliable capture

The CalendarMonitor currently polls EventKit every 30 seconds. Applying the same frequency to Google Calendar API would be ~2,880 requests/day per user -- likely fine for quotas but wasteful.

**Why it happens:**
Google strongly recommends push notifications over polling but push notifications require a publicly accessible HTTPS endpoint, which a desktop app does not have. Push notifications need a webhook server, which contradicts the "no cloud dependency" principle.

**Prevention:**
1. **Use incremental sync with sync tokens** instead of full event list fetches. Each incremental sync is a single API call regardless of how many events changed.
2. **Smart polling frequency:**
   - Normal: every 5 minutes (sufficient for most meetings which are scheduled in advance)
   - Near meeting start (within 15 minutes of any known event): every 60 seconds
   - No upcoming meetings in next 2 hours: every 15 minutes
3. **Cache the events list locally** in the GRDB database. Only query Google for changes (sync token).
4. **Respect exponential backoff** on 403/429 responses. Do not retry immediately.
5. **Supplement Google Calendar polling with local EventKit** -- EventKit has no rate limits and reflects Google Calendar changes if the user has their Google account added to macOS Calendar. This hybrid approach gives near-instant detection with Google API as the authoritative source.
6. **Pre-fetch tomorrow's events** before midnight so morning meetings are already known.

**Detection:**
- 403/429 responses from Calendar API
- Meetings starting without Caddie detecting them
- High API quota usage visible in Google Cloud Console

**Phase to address:** Calendar sync implementation phase.

**Confidence:** HIGH -- Google's quota documentation and sync guide are authoritative.

---

### Pitfall 9: Audio Device Hot-Plug Changes Device ID -- Saved Preference Becomes Invalid

**What goes wrong:**
CoreAudio assigns `AudioDeviceID` values dynamically. They are NOT persistent across system restarts or device reconnects. If the user selects "Loopback Virtual Device" in Caddie's settings, the app saves the `AudioDeviceID` (an integer). After a restart, the same device gets a different `AudioDeviceID`. The saved preference now points to the wrong device or no device at all.

Even `AudioDeviceUID` (a string) can change for some virtual devices when the creating application (Loopback) is restarted.

**Why it happens:**
`AudioDeviceID` is a transient handle, not a stable identifier. Apple's documentation states it is valid only for the current boot session. `AudioDeviceUID` is more stable for hardware devices but virtual devices may regenerate UIDs.

**Prevention:**
1. **Store the device UID string** (`kAudioDevicePropertyDeviceUID`), NOT the `AudioDeviceID` integer.
2. **On app launch and before each recording**, resolve the stored UID to a current `AudioDeviceID` by enumerating all devices and matching UIDs.
3. **If the UID is not found**: show a clear warning ("Configured audio device not found. Using default.") and fall back to the default device or the process tap behavior.
4. **Also store the device name** as a human-readable fallback. If UID lookup fails, offer to re-select from the current device list.
5. **Listen for `kAudioHardwarePropertyDevices` changes** to detect when devices are added/removed and update the device picker dynamically.

**Detection:**
- App settings show a device name but recording captures from a different device
- `AudioObjectGetPropertyData` with the stored UID returning `kAudioObjectUnknown`
- Log messages: "Saved device UID not found in current device list"

**Phase to address:** Audio device selection phase. The persistence mechanism is part of the device picker design.

**Confidence:** HIGH -- confirmed by CoreAudio documentation and SimplyCoreAudio source code.

---

### Pitfall 10: Sample Rate Mismatch Between Loopback Virtual Device and Caddie's 16kHz Target

**What goes wrong:**
Loopback virtual devices typically operate at 44.1kHz or 48kHz. Caddie's `SystemAudioCapture` configures the AudioUnit output to 16kHz mono (`targetSampleRate = 16000.0`). CoreAudio's AudioUnit performs automatic sample rate conversion, but:
- If the source device's sample rate does not divide evenly into 16kHz, the conversion introduces artifacts
- Some virtual devices report a sample rate of 0 or an unexpected rate when first created
- If the Loopback device's sample rate changes mid-recording (user adjusts Loopback configuration), the AudioUnit may fail silently or produce garbled audio

Additionally, per community reports: macOS virtual audio devices sometimes output at 44100Hz regardless of their configured sample rate.

**Why it happens:**
CoreAudio's automatic sample rate conversion is designed for hardware devices with stable sample rates. Virtual devices are more dynamic and may report inconsistent rates.

**Prevention:**
1. **Query the selected device's actual sample rate** before creating the AudioUnit and log it.
2. **If the sample rate is 0 or unexpected**, warn the user and suggest checking Loopback configuration.
3. **Set the AudioUnit's input format to match the device's native rate**, then let the AudioUnit convert to 16kHz on output. This is what the current code does, but verify it works for all Loopback configurations.
4. **Register for `kAudioDevicePropertyNominalSampleRate` changes** on the selected device to detect mid-recording rate changes. If it changes, log a warning.
5. **Test with actual Loopback configurations** -- 44.1kHz and 48kHz at minimum.

**Detection:**
- Audio playback sounds pitched up/down (wrong sample rate)
- `AVAudioConverter` errors during format conversion
- Loopback device showing different sample rate than expected in Audio MIDI Setup

**Phase to address:** Audio device selection phase, during integration testing.

**Confidence:** MEDIUM -- CoreAudio conversion generally works, but virtual device quirks are real.

---

### Pitfall 11: Google Calendar Scope is "Sensitive" -- Requires Verification for >100 Users

**What goes wrong:**
`calendar.readonly` is classified by Google as a "sensitive scope." Apps requesting sensitive scopes must pass Google's OAuth app verification process before they can be used by more than 100 users. The verification process requires:
- A privacy policy hosted on a public URL
- A demonstration video showing the OAuth flow and how data is used
- Written justification for each scope
- Review by Google (timeline: days to weeks)

If verification is not completed before distribution, users beyond the first 100 see "This app isn't verified" with a scary warning screen, or are blocked entirely.

**Why it happens:**
Google tightened OAuth verification in response to phishing attacks. Calendar scopes are sensitive because they expose meeting titles, attendees, and schedules.

**Prevention:**
1. **Start the verification process early** -- submit during development, not after building the feature.
2. **Use "testing" mode** in Google Cloud Console during development. Add your test Google accounts as test users (up to 100).
3. **Prepare the privacy policy** as one of the first tasks. It needs a public URL.
4. **Record the demo video** showing: consent screen -> user grants access -> app reads calendar -> data stays local.
5. **If Caddie will be distributed to a small user base** (personal use / <100 users), testing mode may be sufficient permanently.

**Detection:**
- Users seeing "This app isn't verified" warning
- Users blocked from completing OAuth flow
- Google rejecting verification submission

**Phase to address:** First phase of calendar integration -- before any code.

**Confidence:** HIGH -- Google's documentation is explicit about this requirement.

---

## Minor Pitfalls

---

### Pitfall 12: EventKit CalendarMonitor and Google Calendar Produce Duplicate Meeting Detections

**What goes wrong:**
The existing `CalendarMonitor` reads from macOS EventKit (which includes Google Calendar events if the user has their Google account added to macOS Calendar). The new Google Calendar API integration reads from the same Google Calendar directly. If both monitors are active, every Google Calendar meeting is detected twice -- once via EventKit, once via the API. This triggers double recording attempts or confusing UI state.

**Prevention:**
1. **When Google Calendar is connected**, disable the EventKit monitor for Google calendars. Keep EventKit active only for non-Google calendars (iCloud, Exchange, etc.).
2. **Or**: use EventKit as the primary source and Google Calendar API only for features EventKit cannot provide (attendee details, conference links, extended properties).
3. **Deduplicate by event title + start time** if both sources remain active. Use a 5-minute window for start time matching.

**Phase to address:** Calendar integration phase, when wiring up the new Google Calendar monitor alongside the existing EventKit monitor.

**Confidence:** HIGH -- direct codebase observation. `CalendarMonitor.swift` already polls EventKit every 30 seconds.

---

### Pitfall 13: OAuth Consent Screen Shows Caddie's Developer Email to Users

**What goes wrong:**
Google's OAuth consent screen displays the developer's email address (or the support email configured in the Cloud Console) to users. If this is a personal email (e.g., `yash@gmail.com`), it looks unprofessional and may concern privacy-conscious users.

**Prevention:**
1. **Configure a support email** in the Google Cloud Console OAuth consent screen settings that looks professional.
2. **Set the app name, logo, and developer info** carefully -- users see this during authorization.
3. **Test the consent screen** in an incognito browser to see exactly what users will see.

**Phase to address:** OAuth setup phase (Google Cloud Console configuration).

**Confidence:** HIGH -- visible in every OAuth flow.

---

### Pitfall 14: Entitlements File Needs Network Access for OAuth

**What goes wrong:**
Caddie's current entitlements (`Resources/Caddie.entitlements`) include only `com.apple.security.device.audio-input` and `com.apple.security.personal-information.calendars`. The app is NOT sandboxed (no `com.apple.security.app-sandbox`), so network access is unrestricted. However, if the app is ever sandboxed for Mac App Store distribution:
- `com.apple.security.network.client` entitlement is needed for outgoing HTTP (OAuth, Calendar API)
- `com.apple.security.network.server` entitlement might be needed for the loopback OAuth redirect server
- Keychain access behavior changes in sandboxed apps (scoped to the app's container)

**Prevention:**
1. **If staying unsandboxed** (current state): no entitlement changes needed for network access. Keychain works normally.
2. **If considering sandboxing later**: plan for the entitlements now. Test OAuth flow in both sandboxed and unsandboxed modes.
3. **Document the decision** to stay unsandboxed and why (CoreAudio process taps require unsandboxed access).

**Phase to address:** Before implementation begins. This is a project-level architecture decision.

**Confidence:** HIGH -- entitlements verified from codebase.

---

### Pitfall 15: All-Day Calendar Events Trigger False Recording Starts

**What goes wrong:**
The existing `CalendarMonitor` filters out all-day events (`!event.isAllDay`). The Google Calendar API also returns all-day events in `events.list`. If the Google Calendar integration does not apply the same filter, all-day events (e.g., "PTO", "Sprint 23", "Company Holiday") trigger meeting detection and recording attempts that run all day.

Additionally, Google Calendar's incremental sync has a known issue where all-day events sometimes return empty `items` arrays, which could cause false "event ended" signals.

**Prevention:**
1. **Apply the same filters** as the existing CalendarMonitor: exclude all-day events, require 2+ attendees.
2. **Add additional filters**: exclude events the user has declined, exclude events without a conference link (optional, configurable).
3. **Test with all-day events, recurring events, and multi-day events** -- each has different behavior in the API response.

**Phase to address:** Calendar sync implementation phase.

**Confidence:** HIGH -- existing CalendarMonitor already handles this; ensure parity.

---

## Phase-Specific Warnings

| Phase Topic | Likely Pitfall | Severity | Mitigation |
|-------------|---------------|----------|------------|
| OAuth2 Setup (Cloud Console) | Sensitive scope verification delays | HIGH | Start verification process before writing code. Use testing mode during development |
| OAuth2 Implementation | Token refresh race condition | CRITICAL | Serialize all refresh attempts through a single actor. Proactive refresh before expiry |
| OAuth2 Token Storage | Keychain stale tokens after reinstall | MODERATE | Validate tokens on first launch. Handle all SecItem error codes |
| OAuth2 Redirect | Loopback HTTP server port conflicts | MODERATE | Use port 0 for OS-assigned port. Add timeout and retry |
| Calendar Sync | Sync token invalidation (410 Gone) | HIGH | Handle 410 by clearing state and performing full resync |
| Calendar Sync | Polling frequency vs. rate limits | MODERATE | Smart adaptive polling with sync tokens. Supplement with EventKit |
| Calendar Sync | Duplicate detection (EventKit + Google API) | MODERATE | Disable EventKit for Google calendars when API is connected |
| Calendar Sync | All-day / declined events triggering recording | LOW | Mirror existing CalendarMonitor filters |
| Audio Device Picker | AVAudioEngine cannot select non-default device | CRITICAL | Rewrite MicrophoneCapture to use HAL AudioUnit (same as SystemAudioCapture) |
| Audio Device Picker | Device ID not persistent across restarts | HIGH | Store device UID, resolve to ID at runtime |
| Audio Device Picker | Virtual device disappears mid-recording | HIGH | Monitor kAudioHardwarePropertyDevices + periodic validation |
| Audio Device Picker | Sample rate mismatch with virtual devices | MODERATE | Query actual rate, configure AudioUnit accordingly |
| Privacy/Trust | "Zero cloud" identity contradicted by Google OAuth | HIGH | Make integration optional. Pre-sign-in explanation. Privacy policy |
| Entitlements | Missing network entitlements if sandboxed | LOW | Document decision to stay unsandboxed |

---

## Integration Pitfalls Specific to Caddie's Architecture

| Existing Component | New Feature | Integration Risk | Mitigation |
|-------------------|-------------|------------------|------------|
| `CalendarMonitor` (EventKit) | Google Calendar API monitor | Duplicate detection, conflicting signals | Deduplicate by event + time window. Prefer Google API when connected |
| `MeetingDetector` (multi-signal) | Calendar-as-primary detection | Signal priority confusion -- which source wins? | Define clear priority: Google Calendar > EventKit > audio process + mic |
| `AudioRecorder` (system + mic) | User-selected device | MicrophoneCapture uses AVAudioEngine (no device selection) | Rewrite to HAL AudioUnit or accept default-mic-only limitation |
| `SystemAudioCapture` (process tap) | Device-based capture | Two different capture modes (process tap vs. device tap) | Abstract behind a protocol with two implementations |
| `AppState.initialize()` | OAuth token validation | More async work in an already-complex init sequence | OAuth token check should be independent of ML pipeline init |
| `RecordingCoordinator` | Calendar-triggered recording | Coordinator expects detection signals, not scheduled triggers | Add a `scheduledStart(at:)` method for pre-meeting recording start |
| `Permissions.swift` | Google OAuth permission state | New permission type that does not use macOS system prompts | Add Google Calendar connection status to permissions check flow |

---

## Recovery Strategies

| Pitfall | Recovery Cost | Recovery Steps |
|---------|---------------|----------------|
| Token refresh race | MEDIUM | Add actor-based refresh serialization. Touch all Calendar API call sites |
| Virtual device disappears | MEDIUM | Add device-list listener + periodic validation + fallback. ~100 LOC |
| Sync token 410 Gone | LOW | Add 410 handler with full resync. ~30 LOC per API call site |
| Privacy contradiction | LOW (planning) | Write privacy policy, add pre-sign-in screen, make feature optional |
| AVAudioEngine device limit | HIGH | Rewrite MicrophoneCapture to HAL AudioUnit. ~200 LOC + testing |
| Loopback redirect blocked | LOW | Use port 0, add timeout. ~20 LOC |
| Keychain stale tokens | LOW | Add first-launch validation. ~30 LOC |
| Polling frequency | LOW | Implement adaptive polling schedule. ~50 LOC |
| Device ID not persistent | LOW | Store UID instead of ID. ~20 LOC change + migration |
| Sample rate mismatch | LOW | Query rate before capture setup. ~10 LOC |
| Duplicate detection | MEDIUM | Deduplication logic + EventKit/Google priority system. ~100 LOC |
| Scope verification | LOW (process) | Submit verification early. No code change needed |

---

## "Looks Done But Isn't" Checklist

- [ ] **OAuth Flow:** User completes sign-in AND token is stored in Keychain AND a test API call succeeds. A completed browser redirect does not mean auth is working.
- [ ] **Token Refresh:** Wait 61 minutes after sign-in and verify the next Calendar API call still succeeds (access token expired and was auto-refreshed).
- [ ] **Calendar Sync:** Add a meeting to Google Calendar, wait for the next poll cycle, verify it appears in Caddie. Then delete the meeting and verify it disappears.
- [ ] **Sync Token Recovery:** Manually corrupt the stored sync token and verify the app performs a full resync without crashing.
- [ ] **Device Selection:** Select a Loopback device, start recording, verify audio comes from that device (not the default). Then quit Loopback mid-recording and verify graceful fallback.
- [ ] **Device Persistence:** Select a device, restart the app, verify the same device is still selected (UID lookup succeeds).
- [ ] **Sign Out:** Use the Sign Out button, verify Keychain tokens are deleted, Google token is revoked, and calendar data is cleared.
- [ ] **Offline Behavior:** Disconnect network, verify app does not crash, cached calendar data is used, and a clear "offline" indicator is shown.
- [ ] **Privacy Policy:** Visit the privacy policy URL from the consent screen and verify it loads correctly and describes calendar data handling.
- [ ] **Duplicate Detection:** Enable both EventKit and Google Calendar for the same Google account, verify meetings are not duplicated in Caddie's list.

---

## Sources

- [Google OAuth 2.0 for Desktop Apps](https://developers.google.com/identity/protocols/oauth2/native-app) -- loopback redirect, PKCE requirements, token refresh
- [Google Loopback IP Address Migration Guide](https://developers.google.com/identity/protocols/oauth2/resources/loopback-migration) -- deprecation status of loopback redirects
- [Google Calendar API Sync Guide](https://developers.google.com/workspace/calendar/api/guides/sync) -- sync tokens, 410 handling, incremental sync
- [Google Calendar API Quota Management](https://developers.google.com/workspace/calendar/api/guides/quota) -- per-minute limits, exponential backoff
- [Google Sensitive Scope Verification](https://developers.google.com/identity/protocols/oauth2/production-readiness/sensitive-scope-verification) -- verification process, timeline, requirements
- [Google OAuth App Verification: Costs, Timelines](https://www.nylas.com/blog/google-oauth-app-verification/) -- practical verification timeline experience
- [Apple: Storing Keys in the Keychain](https://developer.apple.com/documentation/security/certificate_key_and_trust_services/keys/storing_keys_in_the_keychain) -- Keychain best practices
- [Square Valet (Keychain wrapper)](https://github.com/square/Valet) -- Keychain patterns for macOS
- [AppAuth-iOS (OpenID Foundation)](https://github.com/openid/AppAuth-iOS) -- OAuth2 for macOS, loopback server implementation
- [AudioKit #2130: AVAudioEngine device selection limitations](https://github.com/AudioKit/AudioKit/issues/2130) -- AVAudioEngine cannot select non-default device
- [Apple Forums: Select audio device for AVAudioEngine](https://developer.apple.com/forums/thread/71008) -- confirmed limitation
- [Rogue Amoeba: Loopback audio capture details on macOS 14+](https://rogueamoeba.com/support/knowledgebase/?showArticle=Misc-ARK-Plugin-Audio-Capture-Details&product=Loopback) -- virtual device behavior on Sonoma+
- [Rogue Amoeba: ACE component repair](https://rogueamoeba.com/support/knowledgebase/?showArticle=ACE-Repair&product=Loopback) -- virtual device disappearance
- [Virtual audio routing on macOS isn't lossless](https://blog.claranguyen.me/post/2025/03/09/lossless-loopback-audio-macos/) -- sample rate quirks
- [SimplyCoreAudio](https://github.com/rnine/SimplyCoreAudio) -- device change notifications, hot-plug handling
- [OAuth2 token refresh race condition (GitHub)](https://github.com/thephpleague/oauth2-client/issues/593) -- documented race condition
- [Google OAuth invalid_grant explanation (Nango)](https://nango.dev/blog/google-oauth-invalid-grant-token-has-been-expired-or-revoked) -- token revocation scenarios
- [How to Fix Expired Token Errors in OAuth2](https://oneuptime.com/blog/post/2026-01-24-oauth2-expired-token-errors/view) -- retry and refresh patterns
- [JUCE Forum: CoreAudio deadlock on stop/restart](https://forum.juce.com/t/coreaudio-deadlock-when-stopping-and-restarting-device/51882) -- device lifecycle issues

---
*Pitfalls research for: Google Calendar OAuth2 + audio device selection (Caddie v2.0)*
*Researched: 2026-03-24*

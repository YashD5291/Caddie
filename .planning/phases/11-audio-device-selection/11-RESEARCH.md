# Phase 11: Audio Device Selection - Research

**Researched:** 2026-03-24
**Domain:** macOS audio device enumeration, SwiftUI Settings integration, UserDefaults persistence
**Confidence:** HIGH

## Summary

Phase 11 is a UI + persistence phase only. The user selects which audio input device Caddie should use, and that choice survives app restarts. No actual audio capture changes happen here -- Phase 12 handles the HAL AudioUnit rewrite of MicrophoneCapture.

The existing SimplyCoreAudio dependency (v4.1.1, already used by MicStateMonitor) provides everything needed: `allInputDevices` for enumeration, `.uid` for persistent identification, `.name`/`.manufacturer` for display, and `.deviceListChanged` notification for dynamic UI updates. No new dependencies are required.

The key design decisions are: (1) store the device UID string in UserDefaults (not the transient AudioDeviceID integer), (2) validate the stored UID on app launch and fall back to default if the device is missing, (3) create an `@Observable AudioDeviceManager` that drives the Settings UI picker and is injected into AppState for later use by the recording coordinator.

**Primary recommendation:** Build AudioDeviceManager as an `@Observable` class wrapping SimplyCoreAudio, add a Picker to SettingsView, and persist selection via UserDefaults. Keep this phase surgical -- no AudioRecorder or MicrophoneCapture changes.

## Project Constraints (from CLAUDE.md)

- **TDD:** Write tests first, always. No exceptions.
- **Small functions, each does one thing.**
- **Strict typing everywhere** -- avoid any/unknown unless justified.
- **No dead code, no commented-out code in commits.**
- **Check if something already exists before writing new logic.**
- **Never commit directly to main.**
- **Atomic commits with clear messages (what + why).**
- **No "Co-Authored-By" lines in git commit messages.**
- **YAGNI** -- don't add features not asked for.
- **Don't refactor unrelated code while fixing a bug.**
- **Don't generate placeholder/mock implementations unless specifically asked.**
- **Handle errors explicitly -- no silent catches, no empty catch blocks.**
- **GSD Workflow Enforcement** -- start work through a GSD command.

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| AUD-01 | User can select which audio input device to capture from in Settings (Loopback, built-in mic, etc.) | AudioDeviceManager wrapping SimplyCoreAudio `allInputDevices`; SwiftUI Picker in SettingsView; `.deviceListChanged` notification for live updates |
| AUD-02 | Selected audio device persists across app restarts (stored in UserDefaults) | Store device UID string (not transient AudioDeviceID) in UserDefaults; validate on launch; fallback to default device if stored UID not found |
</phase_requirements>

## Standard Stack

### Core

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| SimplyCoreAudio | 4.1.1 (existing) | Audio device enumeration, UID lookup, change notifications | Already a dependency (MicStateMonitor uses it). Provides `allInputDevices`, `AudioDevice.uid`, `AudioDevice.name`, `AudioDevice.manufacturer`, `AudioDevice.lookup(by: uid)`, and `.deviceListChanged` notification. Archived but stable -- wraps CoreAudio APIs that haven't changed. |
| SwiftUI (system) | macOS 14.2+ | Settings form UI with Picker | Already used for all views. `Picker` with `ForEach` over devices is the standard SwiftUI pattern. |
| UserDefaults (system) | macOS 14.2+ | Persist selected device UID | Already used for `hasCompletedOnboarding`. Appropriate for a single string preference. |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| SimplyCoreAudio | Raw CoreAudio `AudioObjectGetPropertyData` | More code for the same result. SCA is already linked and working. Only consider if SCA breaks on a future macOS. |
| UserDefaults | GRDB (existing database) | Overkill for a single string preference. UserDefaults is the standard macOS approach for app preferences. |
| UserDefaults | `@AppStorage` (SwiftUI) | Could use `@AppStorage` in the view directly, but the AudioDeviceManager needs access to the preference from non-view code (recording coordinator). UserDefaults is more appropriate for cross-cutting state. |

## Architecture Patterns

### Recommended Project Structure

```
Sources/
  Recording/
    AudioDeviceManager.swift     <-- NEW: device enumeration + persistence
  UI/
    Settings/
      SettingsView.swift         <-- MODIFIED: add Audio Devices section
```

### Pattern 1: @Observable AudioDeviceManager on MainActor

**What:** A new `@Observable` class that owns device enumeration state, listens for hardware changes, and manages UserDefaults persistence.

**When to use:** Whenever a SwiftUI view needs to display and interact with CoreAudio device state.

**Why MainActor:** The class drives UI (SwiftUI Picker) and observes NotificationCenter (which delivers on main queue). SimplyCoreAudio's device list access is synchronous and fast. No background work needed.

```swift
// Source: Codebase pattern analysis (AppState.swift, MicStateMonitor.swift)
@MainActor
@Observable
final class AudioDeviceManager {

    struct InputDevice: Identifiable, Hashable, Sendable {
        let id: String      // UID (persistent across restarts)
        let name: String
        let manufacturer: String
        let deviceID: AudioObjectID  // Transient, for display/debugging only
    }

    private(set) var availableInputDevices: [InputDevice] = []
    var selectedDeviceUID: String? {
        didSet { persistSelection() }
    }

    /// True when the stored UID was not found in the current device list
    private(set) var isUsingFallback: Bool = false

    private let coreAudio = SimplyCoreAudio()
    private var deviceListObserver: NSObjectProtocol?

    private static let defaultsKey = "selectedInputDeviceUID"

    func initialize() { ... }
    func refresh() { ... }

    /// Resolve the selected UID to a current AudioObjectID.
    /// Returns nil if no device selected or device not found.
    func resolvedDeviceID() -> AudioObjectID? { ... }
}
```

**Key properties of InputDevice struct:**
- `id` = `AudioDevice.uid` (String, persistent across reboots)
- `name` = `AudioDevice.name` (String, human-readable)
- `manufacturer` = `AudioDevice.manufacturer` (String, helps distinguish similar devices)
- `deviceID` = `AudioDevice.id` (AudioObjectID/UInt32, transient)

### Pattern 2: UserDefaults for Device Preference

**What:** Store the selected device UID string in UserDefaults under a well-known key.

**Why UID not AudioDeviceID:** Apple's `AudioDevice.id` (AudioObjectID) is transient and changes on reboot. `AudioDevice.uid` is a string guaranteed to persist across restarts for hardware devices. Loopback virtual devices also maintain stable UIDs as long as the virtual device configuration in Loopback is unchanged.

**Why not device name:** Device names are not unique. Two identical USB mics would have the same name but different UIDs.

```swift
// Persistence pattern (matches existing UserDefaults usage in AppState)
private func persistSelection() {
    if let uid = selectedDeviceUID {
        UserDefaults.standard.set(uid, forKey: Self.defaultsKey)
    } else {
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
    }
}

private func loadSelection() {
    selectedDeviceUID = UserDefaults.standard.string(forKey: Self.defaultsKey)
}
```

### Pattern 3: Device List Change Notification

**What:** Subscribe to `.deviceListChanged` (SimplyCoreAudio notification) to refresh the device list when hardware is added/removed.

**When:** On AudioDeviceManager initialization, subscribe; on deinit, unsubscribe.

```swift
// Source: MicStateMonitor.swift pattern
deviceListObserver = NotificationCenter.default.addObserver(
    forName: .deviceListChanged,
    object: nil,
    queue: .main
) { [weak self] _ in
    guard let self else { return }
    self.refresh()
}
```

**The notification's userInfo contains `addedDevices` and `removedDevices` arrays**, but we can ignore them and just re-enumerate -- it's fast and simpler.

### Pattern 4: Startup Validation with Fallback

**What:** On app launch, load the stored UID from UserDefaults. If the device is not in the current device list, set `isUsingFallback = true` and clear the selection (meaning "use default").

**When:** During `AudioDeviceManager.initialize()`, called from `AppState.initialize()`.

```swift
func initialize() {
    refresh()
    loadSelection()

    if let uid = selectedDeviceUID,
       !availableInputDevices.contains(where: { $0.id == uid }) {
        // Stored device not found -- fall back to default
        isUsingFallback = true
        selectedDeviceUID = nil
    }

    subscribeToDeviceChanges()
}
```

### Pattern 5: SettingsView Section with Picker

**What:** Add an "Audio Input" section to SettingsView with a SwiftUI `Picker` bound to `audioDeviceManager.selectedDeviceUID`.

```swift
// Source: Existing SettingsView pattern
Section("Audio Input") {
    Picker("Input Device", selection: $audioDeviceManager.selectedDeviceUID) {
        Text("System Default").tag(String?.none)
        ForEach(audioDeviceManager.availableInputDevices) { device in
            Text(device.name)
                .tag(Optional(device.id))
        }
    }

    if audioDeviceManager.isUsingFallback {
        Label("Previously selected device not found. Using system default.",
              systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
    }

    Text("Select which microphone Caddie records from. This does not affect system audio capture.")
        .font(.caption)
        .foregroundStyle(.tertiary)
}
```

### Anti-Patterns to Avoid

- **Storing AudioDeviceID (integer) in UserDefaults:** Transient, changes on reboot. Always store UID string.
- **Changing system default input programmatically:** `AudioObjectSetPropertyData` on `kAudioHardwarePropertyDefaultInputDevice` changes the global system setting. Affects all apps. Never do this.
- **Reaching into AudioRecorder/MicrophoneCapture in this phase:** Phase 11 is selection + persistence only. Phase 12 wires the selection to the capture engine.
- **Creating a custom NSView for the picker:** SwiftUI `Picker` in a `Form` with `.grouped` style is the correct macOS Settings pattern. No AppKit needed.
- **Filtering out aggregate/virtual devices:** Loopback devices are virtual. The user's primary use case IS a virtual device. Show all input devices.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Device enumeration | Raw CoreAudio `AudioObjectGetPropertyData` loops | `SimplyCoreAudio().allInputDevices` | Already linked, tested, provides clean Swift API. Re-implementing CoreAudio enumeration is ~80 lines of unsafe pointer code. |
| Device change monitoring | Raw `AudioObjectAddPropertyListenerBlock` on `kAudioHardwarePropertyDevices` | `.deviceListChanged` NotificationCenter notification from SimplyCoreAudio | SCA already wraps the HAL listener. One-liner subscription. |
| UID-to-device lookup | Manual enumeration + string matching | `AudioDevice.lookup(by: uid)` | SimplyCoreAudio provides this as a static method using `kAudioHardwarePropertyDeviceForUID`. |

## Common Pitfalls

### Pitfall 1: AudioDeviceID is Transient

**What goes wrong:** Storing `AudioDevice.id` (AudioObjectID/UInt32) in UserDefaults. After reboot, the same physical device gets a different ID. Saved preference points to wrong device or nothing.
**Why it happens:** CoreAudio assigns AudioDeviceID dynamically per boot session. Apple's docs explicitly state this.
**How to avoid:** Store `AudioDevice.uid` (String). Resolve to current AudioObjectID at runtime via `AudioDevice.lookup(by: uid)`.
**Warning signs:** Device picker shows correct name but recording captures from wrong device after restart.

### Pitfall 2: Loopback Virtual Device UID Stability

**What goes wrong:** Loopback virtual devices have stable UIDs as long as the Loopback configuration is unchanged. But if the user deletes and recreates a Loopback virtual device, it gets a new UID. The saved preference becomes stale.
**Why it happens:** Virtual device UIDs are generated by the host application (Loopback), not by hardware serial numbers.
**How to avoid:** The `isUsingFallback` flag and clear UI warning handle this gracefully. Store the device name alongside the UID for a human-readable "this device was previously selected" message.
**Warning signs:** User sees "Previously selected device not found" after modifying Loopback configuration.

### Pitfall 3: Picker Binding with Optional String

**What goes wrong:** SwiftUI `Picker` with `selection: Binding<String?>` and `.tag(Optional(device.id))` can be tricky. If the tag type doesn't exactly match the selection type, the picker silently fails to select anything.
**Why it happens:** Swift's type system requires exact type matching between `tag()` and `selection`. `String` and `String?` are different types.
**How to avoid:** Use `String?.none` for the "System Default" tag, and `Optional(device.id)` (which is `String?`) for device tags. The selection binding must be `Binding<String?>`.
**Warning signs:** Picker appears to have nothing selected despite a value being set.

### Pitfall 4: Thread Safety of SimplyCoreAudio

**What goes wrong:** `SimplyCoreAudio()` creates a shared `AudioHardware` instance. `allInputDevices` accesses CoreAudio properties synchronously. If called from a background thread while a device change notification fires on the main thread, there could be a race.
**Why it happens:** SimplyCoreAudio is not explicitly thread-safe.
**How to avoid:** Keep AudioDeviceManager on `@MainActor`. All device list access and notification handling happens on the main thread. This is already the pattern used by MicStateMonitor.
**Warning signs:** Sporadic crashes in `AudioObjectGetPropertyData` calls.

### Pitfall 5: Aggregate Devices in allInputDevices

**What goes wrong:** `SimplyCoreAudio.allInputDevices` returns all devices with input channels, including Caddie's own aggregate devices (created by SystemAudioCapture for process taps). These show up in the picker with cryptic names like "com.caddie.systemTap.12345".
**Why it happens:** Aggregate devices with input streams are included in `allInputDevices`.
**How to avoid:** Filter out devices whose UID starts with `"com.caddie.systemTap."`. Also consider filtering out aggregate devices entirely using `AudioDevice.isAggregateDevice` (would need to verify this property exists -- SimplyCoreAudio has `allNonAggregateDevices` which filters these). However, we should NOT filter all aggregates because some users may have legitimate aggregate devices they want to use. Filter only Caddie's own aggregate devices by UID prefix.
**Warning signs:** Picker shows extra mysterious devices during recording.

## Code Examples

### Complete AudioDeviceManager Structure

```swift
// Source: Codebase analysis of AppState.swift, MicStateMonitor.swift, SimplyCoreAudio API
import SimplyCoreAudio
import CoreAudio
import Observation
import os

@MainActor
@Observable
final class AudioDeviceManager {

    struct InputDevice: Identifiable, Hashable, Sendable {
        let id: String              // UID (persistent)
        let name: String
        let manufacturer: String
        let audioDeviceID: AudioObjectID  // Transient runtime ID
    }

    private(set) var availableInputDevices: [InputDevice] = []
    private(set) var isUsingFallback: Bool = false

    var selectedDeviceUID: String? {
        didSet { persistSelection() }
    }

    private let coreAudio = SimplyCoreAudio()
    private var observer: NSObjectProtocol?
    private let logger = Logger(subsystem: "com.caddie.app", category: "AudioDeviceManager")

    static let userDefaultsKey = "selectedInputDeviceUID"

    func initialize() {
        refresh()
        loadPersistedSelection()
        validateSelection()
        subscribeToChanges()
    }

    func refresh() {
        availableInputDevices = coreAudio.allInputDevices
            .filter { !($0.uid?.hasPrefix("com.caddie.systemTap.") ?? false) }
            .compactMap { device -> InputDevice? in
                guard let uid = device.uid else { return nil }
                return InputDevice(
                    id: uid,
                    name: device.name,
                    manufacturer: device.manufacturer ?? "Unknown",
                    audioDeviceID: device.id
                )
            }
    }

    /// Resolve selected UID to current AudioObjectID. Returns nil if using default.
    func resolvedDeviceID() -> AudioObjectID? {
        guard let uid = selectedDeviceUID else { return nil }
        return AudioDevice.lookup(by: uid)?.id
    }

    // MARK: - Private

    private func loadPersistedSelection() {
        selectedDeviceUID = UserDefaults.standard.string(forKey: Self.userDefaultsKey)
    }

    private func validateSelection() {
        guard let uid = selectedDeviceUID else {
            isUsingFallback = false
            return
        }
        if !availableInputDevices.contains(where: { $0.id == uid }) {
            logger.warning("Saved device UID '\(uid)' not found -- falling back to default")
            isUsingFallback = true
            selectedDeviceUID = nil  // triggers persistSelection -> removes from UserDefaults
        } else {
            isUsingFallback = false
        }
    }

    private func persistSelection() {
        if let uid = selectedDeviceUID {
            UserDefaults.standard.set(uid, forKey: Self.userDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.userDefaultsKey)
        }
    }

    private func subscribeToChanges() {
        observer = NotificationCenter.default.addObserver(
            forName: .deviceListChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.refresh()
            self.validateSelection()
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}
```

### SettingsView Integration

```swift
// Source: Existing SettingsView.swift pattern
// Add to SettingsView body Form, between generalSection and permissionsSection

private var audioInputSection: some View {
    Section("Audio Input") {
        Picker("Input Device", selection: $audioDeviceManager.selectedDeviceUID) {
            Text("System Default").tag(String?.none)
            ForEach(audioDeviceManager.availableInputDevices) { device in
                HStack {
                    Text(device.name)
                    if !device.manufacturer.isEmpty && device.manufacturer != "Unknown" {
                        Text("(\(device.manufacturer))")
                            .foregroundStyle(.secondary)
                    }
                }
                .tag(Optional(device.id))
            }
        }

        if audioDeviceManager.isUsingFallback {
            Label("Previously selected device not found. Using system default.",
                  systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        }

        Text("Choose which microphone Caddie records from.")
            .font(.caption)
            .foregroundStyle(.tertiary)
    }
}
```

### AppState Integration

```swift
// Source: Existing AppState.swift pattern
// Add to AppState class:
private(set) var audioDeviceManager = AudioDeviceManager()

// In initialize(), before coordinator creation:
audioDeviceManager.initialize()
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Raw CoreAudio device enumeration | SimplyCoreAudio wrapper | Stable since v4.0 (2021) | Cleaner API, handles notification wiring |
| AVAudioSession (iOS-style device selection) | Not available on macOS | N/A | macOS uses CoreAudio directly, no AVAudioSession |
| NSPopUpButton (AppKit picker) | SwiftUI Picker in Form | SwiftUI maturity ~macOS 13+ | Consistent with existing UI, less code |

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | XCTest (bundled with Xcode 15+) |
| Config file | project.yml defines `CaddieTests` target |
| Quick run command | `xcodebuild test -project Caddie.xcodeproj -scheme Caddie -only-testing CaddieTests/AudioDeviceManagerTests -destination 'platform=macOS'` |
| Full suite command | `xcodebuild test -project Caddie.xcodeproj -scheme Caddie -destination 'platform=macOS'` |

### Phase Requirements to Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| AUD-01 | Device enumeration returns input devices with UID, name, manufacturer | unit | `xcodebuild test -only-testing CaddieTests/AudioDeviceManagerTests/testRefreshPopulatesInputDevices` | Wave 0 |
| AUD-01 | Caddie aggregate devices are filtered from the list | unit | `xcodebuild test -only-testing CaddieTests/AudioDeviceManagerTests/testFiltersCaddieAggregateDevices` | Wave 0 |
| AUD-01 | Picker displays all available devices plus "System Default" | manual-only | Visual verification in Settings | N/A |
| AUD-02 | Selected UID is persisted to UserDefaults | unit | `xcodebuild test -only-testing CaddieTests/AudioDeviceManagerTests/testSelectionPersistsToUserDefaults` | Wave 0 |
| AUD-02 | Persisted UID is loaded on initialize | unit | `xcodebuild test -only-testing CaddieTests/AudioDeviceManagerTests/testInitializeLoadsPersistedSelection` | Wave 0 |
| AUD-02 | Missing device triggers fallback and clears selection | unit | `xcodebuild test -only-testing CaddieTests/AudioDeviceManagerTests/testMissingDeviceFallsBackToDefault` | Wave 0 |
| AUD-02 | Device list change triggers refresh and revalidation | unit | `xcodebuild test -only-testing CaddieTests/AudioDeviceManagerTests/testDeviceListChangeTriggersRefresh` | Wave 0 |

### Sampling Rate

- **Per task commit:** `xcodebuild test -only-testing CaddieTests/AudioDeviceManagerTests -destination 'platform=macOS'`
- **Per wave merge:** `xcodebuild test -project Caddie.xcodeproj -scheme Caddie -destination 'platform=macOS'`
- **Phase gate:** Full suite green before `/gsd:verify-work`

### Wave 0 Gaps

- [ ] `Tests/AudioDeviceManagerTests.swift` -- covers AUD-01, AUD-02 (unit tests for enumeration, persistence, fallback)
- [ ] Test approach: AudioDeviceManager tests can use a protocol-based approach to mock SimplyCoreAudio, OR test against real hardware (the machine running tests has at least one input device). Given the existing test pattern in RecordingCoordinatorTests uses real dependencies, follow the same approach. Tests should verify: refresh populates list, selection persists, missing device triggers fallback, filtering works.

**Note on testability:** SimplyCoreAudio directly queries CoreAudio hardware. Tests running on CI or a machine without audio devices may fail. The pragmatic approach (matching existing test patterns) is to test the business logic (filtering, persistence, validation) and accept that device enumeration tests require a real audio device. An alternative is to extract a protocol, but that adds complexity for minimal gain in this phase.

## Open Questions

1. **Should the picker show device manufacturer inline?**
   - What we know: SimplyCoreAudio provides `manufacturer` property. Two identical USB mics from the same manufacturer would have the same name AND manufacturer but different UIDs.
   - What's unclear: Whether the extra text clutters the picker for users with few devices.
   - Recommendation: Show manufacturer in parentheses only when non-empty and not "Apple Inc." (since all built-in devices are Apple). This disambiguates third-party devices.

2. **Should "System Default" track the actual system default device dynamically?**
   - What we know: When `selectedDeviceUID` is nil, the recording should use whatever the system default is at recording time. The default can change (user changes it in System Settings).
   - What's unclear: Whether to show the current default device name next to "System Default" in the picker.
   - Recommendation: Yes, show it -- e.g., "System Default (MacBook Pro Microphone)" using `coreAudio.defaultInputDevice?.name`. This provides clarity without requiring a selection.

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| SimplyCoreAudio | Device enumeration | Existing SPM dep | 4.1.1 | -- |
| Xcode | Build + test | Required | 15+ | -- |
| At least 1 audio input device | Device list tests | Machine-dependent | -- | Skip device-specific assertions in CI |

**Missing dependencies with no fallback:** None.

## Sources

### Primary (HIGH confidence)

- **SimplyCoreAudio source code** (checked out at `build/SourcePackages/checkouts/SimplyCoreAudio/`) -- Verified: `allInputDevices`, `AudioDevice.uid`, `AudioDevice.name`, `AudioDevice.manufacturer`, `AudioDevice.id`, `AudioDevice.lookup(by: uid)`, `.deviceListChanged` notification, `isAggregateDevice` filtering via `allNonAggregateDevices`
- **Existing codebase** -- MicStateMonitor.swift uses SimplyCoreAudio identically (notification subscription pattern, `defaultInputDevice` access). AppState.swift shows UserDefaults pattern. SettingsView.swift shows Form/Section pattern.
- **Apple CoreAudio documentation** -- `AudioDeviceUID` is persistent, `AudioDeviceID` is transient. Confirmed by SimplyCoreAudio's own doc comments.

### Secondary (MEDIUM confidence)

- **Milestone-level STACK.md research** (`.planning/research/STACK.md`) -- Confirmed SimplyCoreAudio 4.x for enumeration, device UID for persistence
- **Milestone-level ARCHITECTURE.md research** (`.planning/research/ARCHITECTURE.md`) -- AudioDeviceManager design, `@Observable` pattern, file location in `Sources/Recording/`
- **Milestone-level PITFALLS.md research** (`.planning/research/PITFALLS.md`) -- Pitfall 9 (device ID not persistent), Pitfall 2 (virtual device disappearance), Pitfall 5 (AVAudioEngine limitation, relevant to Phase 12 not 11)

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- SimplyCoreAudio is already linked and verified in source checkout. API surface confirmed by reading source code directly.
- Architecture: HIGH -- Follows exact patterns from existing codebase (MicStateMonitor for SCA usage, AppState for @Observable, SettingsView for Form/Section).
- Pitfalls: HIGH -- All pitfalls verified from SimplyCoreAudio source code comments and CoreAudio API documentation.

**Research date:** 2026-03-24
**Valid until:** 2026-04-24 (stable domain -- CoreAudio and SimplyCoreAudio APIs are mature)

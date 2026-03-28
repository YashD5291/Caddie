# Phase 12: Audio Capture Engine - Research

**Researched:** 2026-03-24
**Domain:** CoreAudio HAL AudioUnit, microphone capture rewrite, device-specific audio capture
**Confidence:** HIGH

## Summary

Phase 12 replaces MicrophoneCapture's AVAudioEngine implementation with a HAL AudioUnit implementation that can target specific input devices. This is the highest-risk phase in v2.0 because it rewrites the core audio capture path. The good news: SystemAudioCapture already implements the exact HAL AudioUnit pattern needed (render callback, 16kHz mono Int16 output, RenderContext for memory safety). MicrophoneCapture's rewrite is structurally a subset of SystemAudioCapture -- it needs the AudioUnit setup (Steps 1-7 from TN2091) but skips all the process tap and aggregate device complexity.

The phase also adds a second start path to SystemAudioCapture for direct device capture (when a device UID is provided instead of a process ID). This path skips the CATapDescription/aggregate device creation and directly opens the HAL AudioUnit on the selected device -- simpler than the existing process tap path.

AudioRecorder must be modified to accept optional device UIDs from AudioDeviceManager and pass them to the capture components. The SPSC ring buffer architecture, flush timer, and stereo interleaving remain completely unchanged.

**Primary recommendation:** Extract the shared HAL AudioUnit setup code (Steps 2-7: enable IO, set device, set format, set callback, initialize, start) into a reusable private helper or a lightweight `HALAudioUnitCapture` utility, then use it from both SystemAudioCapture (device path) and the new MicrophoneCapture (HAL path). This prevents duplicating ~100 lines of nearly identical CoreAudio boilerplate.

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| AUD-03 | MicrophoneCapture supports non-default input devices via HAL AudioUnit (replaces AVAudioEngine path when custom device selected) | HAL AudioUnit pattern fully documented in TN2091 and already proven in SystemAudioCapture. Device selection via kAudioOutputUnitProperty_CurrentDevice on Global Scope Element 0 after enabling input IO on Element 1. AVAudioEngine path preserved as fallback when no custom device selected. |
</phase_requirements>

## Project Constraints (from CLAUDE.md)

- **TDD:** Write tests first, always. No exceptions.
- **Strict typing:** Avoid any/unknown unless justified.
- **No dead code:** No commented-out code in commits.
- **YAGNI:** Don't add features not asked for.
- **Error handling:** Handle errors explicitly -- no silent catches, no empty catch blocks.
- **Final classes:** Always mark classes as `final` unless inheritance is required.
- **Custom error enums:** Always conform to `Error & LocalizedError`.
- **Git:** Atomic commits, never commit to main directly.
- **Logging:** Use CaddieLogger.recording for recording subsystem.

## Standard Stack

### Core (Already in Project -- No New Dependencies)

| Framework | Version | Purpose | Why Standard |
|-----------|---------|---------|--------------|
| CoreAudio | System | HAL AudioUnit for device-specific capture | Only API that supports targeting a specific AudioDeviceID for input. Already used by SystemAudioCapture. |
| AudioToolbox | System | AudioUnit lifecycle, AudioStreamBasicDescription, ExtAudioFile | Already used throughout Recording layer. Provides AudioComponentFindNext, AudioUnitSetProperty, etc. |
| SimplyCoreAudio | 4.1.1 (existing) | UID-to-AudioDeviceID resolution via AudioDevice.lookup(by:) | Already a dependency, used by AudioDeviceManager.resolvedDeviceID(). |

### Supporting (Already in Project)

| Component | Purpose | When to Use |
|-----------|---------|-------------|
| SPSCRingBuffer | Lock-free producer-consumer audio buffer | Unchanged -- both capture paths write to ring buffers the same way. |
| AudioDeviceManager | Provides selectedDeviceUID | Phase 11 output. resolvedDeviceID() maps UID to transient AudioObjectID. |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| HAL AudioUnit for MicrophoneCapture | AVAudioEngine + kAudioOutputUnitProperty_CurrentDevice hack | Fragile undocumented workaround. Apple forums confirm it works but is not a public API contract. HAL AudioUnit is the correct low-level approach. |
| Shared HAL helper | Duplicate setup code in both files | More code, more maintenance, more divergence risk. Extract once, reuse. |

**Installation:** No new packages. Zero SPM changes.

## Architecture Patterns

### Current Recording Architecture

```
AudioRecorder
  |-- SystemAudioCapture (HAL AudioUnit via process tap + aggregate device)
  |     |-- CATapDescription -> AudioHardwareCreateProcessTap
  |     |-- Aggregate device wrapping the tap
  |     |-- HAL Output AudioUnit pulling from aggregate device
  |     |-- Render callback -> BufferCallback -> SPSC ring buffer
  |
  |-- MicrophoneCapture (AVAudioEngine)
  |     |-- AVAudioEngine.inputNode (hardwired to system default)
  |     |-- installTap -> AVAudioConverter -> BufferCallback -> SPSC ring buffer
  |
  |-- SPSC ring buffers (system + mic)
  |-- Flush timer -> interleave -> stereo WAV file
```

### Target Recording Architecture (After Phase 12)

```
AudioRecorder (modified: accepts optional device UIDs)
  |
  |-- SystemAudioCapture (modified: two start paths)
  |     |-- Path A: start(processID:, onBuffer:)     -- v1.0 process tap (UNCHANGED)
  |     |-- Path B: start(deviceUID:, onBuffer:)      -- NEW: direct HAL device capture
  |     |       |-- Resolve UID -> AudioDeviceID
  |     |       |-- HAL Output AudioUnit with device as input
  |     |       |-- Same render callback, same 16kHz mono Int16 output
  |     |       |-- No tap, no aggregate device (simpler path)
  |
  |-- MicrophoneCapture (modified: two start paths)
  |     |-- Path A: start(onBuffer:)                   -- v1.0 AVAudioEngine (UNCHANGED)
  |     |-- Path B: start(deviceUID:, onBuffer:)       -- NEW: HAL AudioUnit for specific device
  |     |       |-- Resolve UID -> AudioDeviceID
  |     |       |-- HAL Output AudioUnit with device as input
  |     |       |-- Set output format to 16kHz mono Int16
  |     |       |-- Render callback -> BufferCallback
  |
  |-- SPSC ring buffers (UNCHANGED)
  |-- Flush timer -> interleave -> stereo WAV (UNCHANGED)
```

### Pattern 1: HAL AudioUnit Device Input (from TN2091)

**What:** Standard CoreAudio pattern for capturing from a specific audio device.
**When to use:** Any time you need audio input from a non-default device.
**Order of operations (critical -- order matters for CoreAudio):**

```swift
// Source: Apple TN2091 (https://developer.apple.com/library/archive/technotes/tn2091/)
// Verified against existing SystemAudioCapture.setupAudioUnit()

// 1. Find HAL Output component
var desc = AudioComponentDescription(
    componentType: kAudioUnitType_Output,
    componentSubType: kAudioUnitSubType_HALOutput,
    componentManufacturer: kAudioUnitManufacturer_Apple,
    componentFlags: 0, componentFlagsMask: 0
)
guard let component = AudioComponentFindNext(nil, &desc) else { ... }
var unit: AudioComponentInstance?
AudioComponentInstanceNew(component, &unit)

// 2. Enable input on bus 1
var enableIO: UInt32 = 1
AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
    kAudioUnitScope_Input, 1, &enableIO, UInt32(MemoryLayout<UInt32>.size))

// 3. Disable output on bus 0
var disableIO: UInt32 = 0
AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
    kAudioUnitScope_Output, 0, &disableIO, UInt32(MemoryLayout<UInt32>.size))

// 4. Set device (MUST be after enabling IO)
var deviceID = targetDeviceID  // resolved from UID
AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
    kAudioUnitScope_Global, 0, &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))

// 5. Set desired output format on bus 1 output scope (what render callback receives)
var outputFormat = AudioStreamBasicDescription(
    mSampleRate: 16000.0, mFormatID: kAudioFormatLinearPCM,
    mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
    mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
    mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
    kAudioUnitScope_Output, 1, &outputFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))

// 6. Set render callback
var callbackStruct = AURenderCallbackStruct(inputProc: renderCallback, inputProcRefCon: contextPtr)
AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback,
    kAudioUnitScope_Global, 0, &callbackStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size))

// 7. Initialize and start
AudioUnitInitialize(unit)
AudioOutputUnitStart(unit)
```

### Pattern 2: UID-to-AudioDeviceID Resolution

**What:** Convert a persistent device UID string to a transient AudioDeviceID at runtime.
**When to use:** Before opening any HAL AudioUnit with a user-selected device.

```swift
// Using SimplyCoreAudio (already available via AudioDeviceManager)
func resolveUID(_ uid: String) -> AudioDeviceID? {
    return AudioDevice.lookup(by: uid)?.id
}

// Alternative: Raw CoreAudio (no SimplyCoreAudio dependency)
func resolveUID(_ uid: String) -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var deviceID: AudioDeviceID = kAudioObjectUnknown
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var cfUID = uid as CFString
    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address,
        UInt32(MemoryLayout<CFString>.size), &cfUID,
        &size, &deviceID
    )
    guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
    return deviceID
}
```

### Pattern 3: RenderContext for Memory Safety (existing pattern)

**What:** Retained context object passed to render callback instead of `self`.
**When to use:** All HAL AudioUnit render callbacks.
**Why:** The render callback runs on the real-time audio thread. If `self` is deallocated during an in-flight callback, accessing `self` via `Unmanaged.passUnretained` causes use-after-free. SystemAudioCapture already uses this pattern -- MicrophoneCapture's HAL path must use it too.

```swift
// Already exists in SystemAudioCapture -- reuse pattern
fileprivate final class RenderContext {
    var audioUnit: AudioComponentInstance?
    var onBuffer: BufferCallback?
}
```

### Pattern 4: Dual Start Path (Strategy Pattern via Overload)

**What:** Two `start()` methods with different signatures, one for each capture mode.
**When to use:** When a component needs fundamentally different setup for different input sources.

```swift
// v1.0 path (no device selection)
func start(onBuffer: @escaping BufferCallback) throws  // AVAudioEngine, default device

// v2.0 path (specific device)
func start(deviceUID: String, onBuffer: @escaping BufferCallback) throws  // HAL AudioUnit
```

### Anti-Patterns to Avoid

- **Changing the system default input device:** Never call `AudioObjectSetPropertyData` on `kAudioHardwarePropertyDefaultInputDevice`. This changes the global system setting, affecting all apps.
- **Hacking AVAudioEngine's underlying AudioUnit:** Reaching into `engine.inputNode.audioUnit!` to set `kAudioOutputUnitProperty_CurrentDevice` is undocumented and fragile. Use HAL AudioUnit directly.
- **Allocating on the real-time audio thread:** The render callback must NEVER allocate memory, take locks, or call ObjC dispatch. The existing SPSC ring buffer write is safe. Logging in the render callback is NOT safe.
- **Forgetting to retain the RenderContext:** `Unmanaged.passRetained(context)` in setup, matched with `Unmanaged.passUnretained(ctx).release()` in stop. Missing either causes memory leak or crash.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| UID-to-AudioDeviceID resolution | Custom CoreAudio enumeration loop | `AudioDevice.lookup(by:)` from SimplyCoreAudio | Already available via AudioDeviceManager. Handles edge cases (device not found, etc.). |
| Sample rate conversion | Custom resampler | AudioUnit internal converter | Setting 16kHz on output scope of bus 1 triggers CoreAudio's built-in converter. Already proven in SystemAudioCapture. |
| Lock-free audio buffering | New ring buffer | Existing SPSCRingBuffer | Phase 3 output, battle-tested, zero changes needed. |
| Device alive monitoring | Custom polling loop | `kAudioDevicePropertyDeviceIsAlive` listener | Same pattern as SystemAudioCapture's `registerDeviceAliveListener()`. |

## Common Pitfalls

### Pitfall 1: AudioUnit Setup Order Matters

**What goes wrong:** Setting `kAudioOutputUnitProperty_CurrentDevice` before enabling IO on bus 1 causes OSStatus errors (-10851 or -10863). Setting format before setting the device also fails because the AudioUnit doesn't know the source device's capabilities.
**Why it happens:** CoreAudio validates properties against current state. IO must be enabled first, then device set, then format configured.
**How to avoid:** Follow TN2091 order exactly: Enable IO -> Set device -> Set format -> Set callback -> Initialize -> Start.
**Warning signs:** OSStatus != noErr from AudioUnitSetProperty. Specifically -10851 (kAudioUnitErr_InvalidPropertyValue).

### Pitfall 2: Sample Rate Mismatch with Virtual Devices

**What goes wrong:** Loopback virtual devices typically run at 44.1kHz or 48kHz. Caddie's target is 16kHz. If the AudioUnit cannot perform the conversion (e.g., device reports sample rate of 0), the capture fails or produces garbled audio.
**Why it happens:** Virtual devices are software-created. Some report unexpected sample rates on first creation. Loopback ACE component on macOS 14+ uses a newer non-kernel-extension mechanism.
**How to avoid:**
1. Query device's `kAudioDevicePropertyNominalSampleRate` before creating the AudioUnit and log it.
2. Set the AudioUnit output format to 16kHz mono Int16 -- CoreAudio's internal converter handles the downsampling.
3. If `AudioUnitSetProperty` for format returns an error, log the device's actual sample rate and fail with a clear error message.
**Warning signs:** `AudioUnitSetProperty` returning -10868 (kAudioUnitErr_FormatNotSupported) for the 16kHz output format.

### Pitfall 3: Virtual Device Disappears Mid-Recording

**What goes wrong:** If the user quits Loopback, the virtual device vanishes. `AudioUnitRender` returns errors. The existing `kAudioDevicePropertyDeviceIsAlive` listener on the aggregate device might not fire for a direct device capture (no aggregate device in the new path).
**Why it happens:** Loopback virtual devices exist only while Loopback's daemon runs. No kernel extension persistence on macOS 14.5+.
**How to avoid:**
1. Register `kAudioDevicePropertyDeviceIsAlive` directly on the selected device (not an aggregate).
2. Also register for `kAudioHardwarePropertyDevices` changes on the system object to detect device removal.
3. When device dies: call `onDisconnect` callback, same as existing SystemAudioCapture behavior.
**Warning signs:** `AudioUnitRender` returning non-zero OSStatus in the render callback.

### Pitfall 4: Forgetting v1.0 Fallback

**What goes wrong:** Rewriting MicrophoneCapture and accidentally breaking the default (no device selected) path. The AVAudioEngine path must remain functional for users who don't select a custom device.
**Why it happens:** Focus on the new HAL path, insufficient testing of the existing path.
**How to avoid:** The existing `start(onBuffer:)` method must remain unchanged. The new `start(deviceUID:, onBuffer:)` is an overload, not a replacement. Test BOTH paths.
**Warning signs:** Existing MicrophoneCapture tests failing after changes.

### Pitfall 5: RenderContext Leak or Use-After-Free

**What goes wrong:** Not matching `Unmanaged.passRetained` with exactly one `release()` call causes either a memory leak (no release) or crash (double release).
**Why it happens:** The render callback is a C function pointer. Swift ARC cannot track it. Manual retain/release is required.
**How to avoid:** Follow SystemAudioCapture's exact pattern: `passRetained` in setup, nil out context fields + `passUnretained.release()` in stop/cleanup.
**Warning signs:** Memory leak (context never deallocated) or EXC_BAD_ACCESS in the render callback.

## Code Examples

### Example 1: MicrophoneCapture HAL Path (new method)

```swift
// Based on SystemAudioCapture.setupAudioUnit() + TN2091
func start(deviceUID: String, onBuffer: @escaping BufferCallback) throws {
    guard !isRunning else { return }
    self.onBuffer = onBuffer

    // Resolve UID to transient AudioDeviceID
    guard let deviceID = AudioDevice.lookup(by: deviceUID)?.id else {
        throw CaptureError.deviceNotFound(deviceUID)
    }

    // Log device sample rate for diagnostics
    logDeviceSampleRate(deviceID)

    // Create HAL Output AudioUnit (same setup as SystemAudioCapture)
    try setupHALAudioUnit(deviceID: deviceID)
    try startAudioUnit()

    isRunning = true
    logger.info("Microphone capture started via HAL AudioUnit (device: \(deviceUID))")
}
```

### Example 2: SystemAudioCapture Device Path (new overload)

```swift
/// Start capturing from a specific device (no process tap, no aggregate device).
func start(deviceUID: String, onBuffer: @escaping BufferCallback) throws {
    guard !isRunning else { return }
    self.onBuffer = onBuffer

    guard let deviceID = AudioDevice.lookup(by: deviceUID)?.id else {
        throw CaptureError.deviceNotFound(deviceUID)
    }

    // Skip setupTap() entirely -- no tap, no aggregate device
    // Direct HAL AudioUnit on the resolved device
    try setupAudioUnitForDevice(deviceID)
    registerDeviceAliveListenerForDevice(deviceID)
    try startAudioUnit()

    isRunning = true
    logger.info("System audio capture started via direct device (UID: \(deviceUID))")
}
```

### Example 3: AudioRecorder Modified Start

```swift
func start(outputPath: URL, processID: pid_t?, systemDeviceUID: String?, micDeviceUID: String?) throws {
    // ... existing setup (WAV file, ring buffers, flush timer) ...

    // System audio capture
    do {
        if let systemUID = systemDeviceUID {
            try systemCapture.start(deviceUID: systemUID) { [weak self] ... }
        } else {
            try systemCapture.start(processID: processID) { [weak self] ... }
        }
        recordingMode = .systemAndMic
    } catch {
        recordingMode = .micOnly
        // ... existing fallback logging ...
    }

    // Microphone capture
    if let micUID = micDeviceUID {
        try micCapture.start(deviceUID: micUID) { [weak self] ... }
    } else {
        try micCapture.start { [weak self] ... }
    }
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| AVAudioEngine for mic capture | HAL AudioUnit for device-specific capture | This phase | Enables non-default device selection. AVAudioEngine stays as fallback. |
| Process tap only for system audio | Process tap + direct device capture | This phase | Enables Loopback device as system audio source. |
| AudioRecorder ignores device selection | AudioRecorder accepts device UIDs | This phase | Connects Phase 11 (AudioDeviceManager) to actual capture. |

## Open Questions

1. **CoreAudio's 16kHz conversion with Loopback devices**
   - What we know: CoreAudio's internal converter handles 44.1kHz/48kHz -> 16kHz for hardware devices. SystemAudioCapture already does this successfully.
   - What's unclear: Whether virtual devices (Loopback) have any quirks with this conversion. Community reports suggest it works but with potential minor artifacts at non-integer ratios (44.1kHz -> 16kHz = 2.75625x).
   - Recommendation: Test with actual Loopback device at 44.1kHz and 48kHz. If artifacts occur, consider using AudioConverter explicitly (match what MicrophoneCapture does with AVAudioConverter today) rather than relying on AudioUnit's built-in conversion.

2. **Single Loopback device for both channels**
   - What we know: The architecture captures system + mic as separate channels. User might route BOTH through a single Loopback virtual device.
   - What's unclear: If both SystemAudioCapture and MicrophoneCapture open the same device simultaneously, will CoreAudio share it or conflict?
   - Recommendation: Out of scope for AUD-03. The user selects ONE input device (mic device). SystemAudioCapture uses the existing process tap for system audio. Document this limitation and defer multi-device scenarios.

3. **Device alive listener on direct device (not aggregate)**
   - What we know: SystemAudioCapture registers `kAudioDevicePropertyDeviceIsAlive` on the aggregate device. The new direct device path has no aggregate device.
   - What's unclear: Whether `kAudioDevicePropertyDeviceIsAlive` fires reliably for virtual devices (Loopback) being removed.
   - Recommendation: Register on the device directly AND on `kAudioHardwarePropertyDevices` (system-level) as a belt-and-suspenders approach.

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | XCTest (bundled with Xcode 15+) |
| Config file | Caddie.xcodeproj / CaddieTests target |
| Quick run command | `xcodebuild test -project Caddie.xcodeproj -scheme Caddie -only-testing CaddieTests -quiet 2>&1` |
| Full suite command | `xcodebuild test -project Caddie.xcodeproj -scheme Caddie -quiet 2>&1` |

### Phase Requirements -> Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| AUD-03a | MicrophoneCapture HAL AudioUnit creates and configures AudioUnit correctly | unit (mock device) | `xcodebuild test -project Caddie.xcodeproj -scheme Caddie -only-testing CaddieTests/MicrophoneCaptureHALTests -quiet` | Wave 0 |
| AUD-03b | MicrophoneCapture AVAudioEngine path unchanged (v1.0 regression) | unit | `xcodebuild test -project Caddie.xcodeproj -scheme Caddie -only-testing CaddieTests/MicrophoneCaptureTests -quiet` | Wave 0 |
| AUD-03c | SystemAudioCapture device-based start path works | unit (mock device) | `xcodebuild test -project Caddie.xcodeproj -scheme Caddie -only-testing CaddieTests/SystemAudioCaptureDeviceTests -quiet` | Wave 0 |
| AUD-03d | AudioRecorder routes device UIDs to correct capture paths | unit | `xcodebuild test -project Caddie.xcodeproj -scheme Caddie -only-testing CaddieTests/AudioRecorderDeviceRoutingTests -quiet` | Wave 0 |
| AUD-03e | Existing stereo WAV output format unchanged | regression | `xcodebuild test -project Caddie.xcodeproj -scheme Caddie -only-testing CaddieTests/AudioRecorderBufferTests -quiet` | Exists |
| AUD-03f | RecordingCoordinator passes device UIDs through | unit | `xcodebuild test -project Caddie.xcodeproj -scheme Caddie -only-testing CaddieTests/RecordingCoordinatorTests -quiet` | Exists (extend) |

### Sampling Rate
- **Per task commit:** Quick test for changed files
- **Per wave merge:** Full suite
- **Phase gate:** Full suite green before verify

### Wave 0 Gaps
- [ ] `Tests/MicrophoneCaptureHALTests.swift` -- covers AUD-03a (HAL AudioUnit setup verification)
- [ ] `Tests/SystemAudioCaptureDeviceTests.swift` -- covers AUD-03c (direct device capture path)
- [ ] `Tests/AudioRecorderDeviceRoutingTests.swift` -- covers AUD-03d (device UID routing logic)

NOTE: CoreAudio AudioUnit tests are limited without actual hardware. Tests verify:
1. Error handling paths (invalid device UID, device not found)
2. Method routing (correct start path chosen based on parameters)
3. State management (isRunning, cleanup on stop)
4. Existing regression tests still pass

Live audio capture verification requires manual testing with actual Loopback device.

## Sources

### Primary (HIGH confidence)
- [Apple TN2091: Device input using the HAL Output Audio Unit](https://developer.apple.com/library/archive/technotes/tn2091/_index.html) -- Complete step-by-step for HAL AudioUnit device capture. Steps, property scopes, element numbers, order of operations.
- SystemAudioCapture.swift (existing codebase) -- Proven HAL AudioUnit implementation with RenderContext pattern, device alive listener, render callback. The template for MicrophoneCapture's rewrite.
- MicrophoneCapture.swift (existing codebase) -- Current AVAudioEngine implementation. 154 lines. Must understand to preserve v1.0 path.
- AudioRecorder.swift (existing codebase) -- Orchestrator. Ring buffer flush, stereo interleave, WAV write. None of this changes.

### Secondary (MEDIUM confidence)
- [Apple Developer Forums: AVAudioEngine device selection](https://developer.apple.com/forums/thread/71008) -- Confirms AVAudioEngine cannot select non-default device. Recommends HAL AudioUnit.
- [Rogue Amoeba: Loopback audio capture on macOS 14+](https://rogueamoeba.com/support/knowledgebase/?showArticle=Misc-ARK-Plugin-Audio-Capture-Details&product=Loopback) -- Virtual device behavior on Sonoma, ACE component details.
- [Apple: Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps) -- Process tap documentation (existing path, not new).

### Tertiary (LOW confidence)
- Community reports on Loopback sample rate quirks with CoreAudio conversion -- needs validation with actual device.

## Metadata

**Confidence breakdown:**
- HAL AudioUnit pattern: HIGH -- Apple TN2091 + existing SystemAudioCapture proves the pattern works
- MicrophoneCapture rewrite: HIGH -- structurally simpler than SystemAudioCapture (no tap, no aggregate)
- SystemAudioCapture device path: HIGH -- subset of existing code (skip tap creation, use device directly)
- AudioRecorder modifications: HIGH -- additive change (new parameters, existing logic unchanged)
- Virtual device sample rate handling: MEDIUM -- CoreAudio converter should handle it, but untested with Loopback specifically
- Device disappearance recovery: MEDIUM -- alive listener pattern exists but untested on virtual devices

**Research date:** 2026-03-24
**Valid until:** 2026-04-24 (CoreAudio APIs are stable, patterns don't change)

import AudioToolbox
import CoreAudio
import Foundation
import os

/// Captures system audio from a specific process (or all system audio) using CoreAudio Taps (macOS 14.2+).
/// Outputs raw PCM buffers (16kHz mono Int16) via callback.
///
/// CoreAudio Tap API sequence:
/// 1. Create a CATapDescription targeting a specific process or all output
/// 2. Create the tap via AudioHardwareCreateProcessTap
/// 3. Build an aggregate device that includes the tap
/// 4. Set up a HAL Output AudioUnit to pull audio from the aggregate device
/// 5. Render callback delivers 16kHz mono Int16 samples via BufferCallback
private let systemAudioCaptureLogger = Logger(subsystem: "com.caddie.app", category: "SystemAudioCapture")

final class SystemAudioCapture {

    typealias BufferCallback = (UnsafeBufferPointer<Int16>, Int) -> Void

    private let logger = Logger(subsystem: "com.caddie.app", category: "SystemAudioCapture")

    /// Retained context object passed to the render callback via Unmanaged.passRetained.
    /// Eliminates use-after-free risk: the context is retained independently of `self`,
    /// so even if SystemAudioCapture is deallocated during an in-flight callback,
    /// the callback accesses valid memory.
    fileprivate final class RenderContext {
        var audioUnit: AudioComponentInstance?
        var onBuffer: BufferCallback?
    }

    /// Called when the aggregate device dies (e.g., hardware disconnected mid-recording).
    var onDisconnect: (() -> Void)?

    private var audioUnit: AudioComponentInstance?
    private var onBuffer: BufferCallback?
    private var renderContext: RenderContext?

    private var aggregateDeviceID: AudioDeviceID = kAudioObjectUnknown
    private var tapObjectID: AudioObjectID = kAudioObjectUnknown
    private var isRunning = false

    // Target format: 16kHz mono 16-bit signed integer PCM
    private static let targetSampleRate: Float64 = 16000.0

    deinit {
        stop()
    }

    // MARK: - Stale Device Cleanup

    /// Destroy any aggregate devices left behind by previous Caddie sessions.
    /// Best-effort: logs errors but never throws. Safe to call at app launch.
    static func cleanupStaleAggregateDevices() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        )
        guard status == noErr, dataSize > 0 else { return }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs
        )
        guard status == noErr else { return }

        var removedCount = 0
        for deviceID in deviceIDs {
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uid: CFString = "" as CFString
            var uidSize = UInt32(MemoryLayout<CFString>.size)
            let uidStatus = AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &uid)
            guard uidStatus == noErr else { continue }

            let uidString = uid as String
            if uidString.hasPrefix("com.caddie.systemTap.") {
                let destroyStatus = AudioHardwareDestroyAggregateDevice(deviceID)
                if destroyStatus == noErr {
                    removedCount += 1
                } else {
                    systemAudioCaptureLogger.warning("Failed to destroy stale aggregate device \(uidString): OSStatus \(destroyStatus)")
                }
            }
        }

        if removedCount > 0 {
            systemAudioCaptureLogger.info("Cleaned up \(removedCount) stale aggregate device(s)")
        }
    }

    /// Start capturing system audio.
    /// - Parameters:
    ///   - processID: If provided, capture audio from this specific process. Otherwise capture all system output.
    ///   - onBuffer: Callback receiving Int16 PCM samples at 16kHz mono.
    func start(processID: pid_t?, onBuffer: @escaping BufferCallback) throws {
        guard !isRunning else {
            logger.warning("SystemAudioCapture already running")
            return
        }

        self.onBuffer = onBuffer

        do {
            try setupTap(processID: processID)
            try setupAudioUnit()
            try startAudioUnit()
            isRunning = true
            logger.info("System audio capture started (processID: \(processID.map { String($0) } ?? "all"))")
        } catch {
            logger.error("Failed to start system audio capture: \(error.localizedDescription)")
            cleanup()
            throw error
        }
    }

    /// Stop capturing and release all resources.
    func stop() {
        guard isRunning else { return }
        isRunning = false

        removeDeviceAliveListener()

        if let unit = audioUnit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            audioUnit = nil
        }

        // Nil out context fields to prevent further callback activity,
        // then release the retained reference we passed to the render callback.
        if let ctx = renderContext {
            ctx.audioUnit = nil
            ctx.onBuffer = nil
            Unmanaged.passUnretained(ctx).release()
            renderContext = nil
        }

        destroyAggregateDevice()
        destroyTap()

        onBuffer = nil
        logger.info("System audio capture stopped")
    }

    // MARK: - Tap Setup

    private func setupTap(processID: pid_t?) throws {
        let tapDescription: CATapDescription

        if let pid = processID {
            // Translate pid_t to an AudioObjectID for the process object
            let processObjectID = try translatePIDToProcessObject(pid)

            // Create a mono mixdown tap for the specific process
            tapDescription = CATapDescription(monoMixdownOfProcesses: [processObjectID])
        } else {
            // Create a mono global tap (all system audio, excluding nothing)
            tapDescription = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        }

        tapDescription.name = "Caddie System Audio Tap"
        tapDescription.muteBehavior = .unmuted  // Don't mute the tapped audio
        tapDescription.isPrivate = true

        // Create the tap
        var tapID: AudioObjectID = kAudioObjectUnknown
        let status = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        guard status == noErr else {
            throw CaptureError.failedToCreateTap(status)
        }
        tapObjectID = tapID
        logger.debug("Created process tap with ID \(tapID)")

        // Create an aggregate device that includes the tap
        try createAggregateDevice(tapID: tapID)
    }

    /// Translate a pid_t to the CoreAudio AudioObjectID representing that process.
    private func translatePIDToProcessObject(_ pid: pid_t) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var pidValue = pid
        var processObjectID: AudioObjectID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &pidValue,
            &size,
            &processObjectID
        )

        guard status == noErr, processObjectID != kAudioObjectUnknown else {
            throw CaptureError.failedToTranslatePID(pid, status)
        }

        return processObjectID
    }

    private func createAggregateDevice(tapID: AudioObjectID) throws {
        let uid = "com.caddie.systemTap.\(UUID().uuidString)"

        // Get the tap's UID string
        var tapUIDAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var tapUID: CFString = "" as CFString
        var tapUIDSize = UInt32(MemoryLayout<CFString>.size)
        let uidStatus = AudioObjectGetPropertyData(
            tapID,
            &tapUIDAddress,
            0,
            nil,
            &tapUIDSize,
            &tapUID
        )
        guard uidStatus == noErr else {
            throw CaptureError.failedToGetTapUID(uidStatus)
        }

        let tapUIDString = tapUID as String

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceUIDKey as String: uid,
            kAudioAggregateDeviceNameKey as String: "Caddie System Tap",
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [kAudioSubDeviceUIDKey as String: tapUIDString]
            ],
            kAudioAggregateDeviceTapListKey as String: [
                [kAudioSubTapUIDKey as String: tapUIDString]
            ],
        ]

        var aggregateID: AudioDeviceID = kAudioObjectUnknown
        let aggStatus = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary,
            &aggregateID
        )
        guard aggStatus == noErr else {
            throw CaptureError.failedToCreateAggregateDevice(aggStatus)
        }
        aggregateDeviceID = aggregateID
        logger.debug("Created aggregate device with ID \(aggregateID)")
        registerDeviceAliveListener()
    }

    // MARK: - Device Alive Listener

    private func registerDeviceAliveListener() {
        guard aggregateDeviceID != kAudioObjectUnknown else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectAddPropertyListener(
            aggregateDeviceID,
            &address,
            deviceAliveListener,
            Unmanaged.passUnretained(self).toOpaque()
        )
        if status != noErr {
            logger.warning("Failed to register device alive listener: OSStatus \(status)")
        }
    }

    private func removeDeviceAliveListener() {
        guard aggregateDeviceID != kAudioObjectUnknown else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListener(
            aggregateDeviceID,
            &address,
            deviceAliveListener,
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    // MARK: - AudioUnit Setup

    private func setupAudioUnit() throws {
        // Find the HAL Output AudioUnit
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &desc) else {
            throw CaptureError.audioComponentNotFound
        }

        var unit: AudioComponentInstance?
        var status = AudioComponentInstanceNew(component, &unit)
        guard status == noErr, let audioUnit = unit else {
            throw CaptureError.failedToCreateAudioUnit(status)
        }
        self.audioUnit = audioUnit

        // Enable input on the audio unit (bus 1)
        var enableIO: UInt32 = 1
        status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input,
            1,
            &enableIO,
            UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else {
            throw CaptureError.failedToConfigureAudioUnit(status)
        }

        // Disable output on the audio unit (bus 0) — we only want to capture, not play
        var disableIO: UInt32 = 0
        status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output,
            0,
            &disableIO,
            UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else {
            throw CaptureError.failedToConfigureAudioUnit(status)
        }

        // Set the aggregate device as the input device
        var deviceID = aggregateDeviceID
        status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw CaptureError.failedToSetDevice(status)
        }

        // Configure output format on the audio unit (what we receive in the callback):
        // 16kHz, mono, 16-bit signed integer PCM
        var outputFormat = AudioStreamBasicDescription(
            mSampleRate: Self.targetSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )

        status = AudioUnitSetProperty(
            audioUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            1, // input bus output scope = what we pull from it
            &outputFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard status == noErr else {
            throw CaptureError.failedToSetFormat(status)
        }

        // Set the render callback via a retained context object.
        // The context holds references the callback needs (audioUnit, onBuffer),
        // avoiding Unmanaged.passUnretained(self) which risks use-after-free.
        let context = RenderContext()
        context.audioUnit = audioUnit
        context.onBuffer = onBuffer
        self.renderContext = context

        var callbackStruct = AURenderCallbackStruct(
            inputProc: systemAudioRenderCallback,
            inputProcRefCon: Unmanaged.passRetained(context).toOpaque()
        )

        status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_SetInputCallback,
            kAudioUnitScope_Global,
            0,
            &callbackStruct,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        guard status == noErr else {
            throw CaptureError.failedToSetCallback(status)
        }

        // Initialize the audio unit
        status = AudioUnitInitialize(audioUnit)
        guard status == noErr else {
            throw CaptureError.failedToInitializeAudioUnit(status)
        }
    }

    private func startAudioUnit() throws {
        guard let unit = audioUnit else {
            throw CaptureError.audioUnitNotReady
        }
        let status = AudioOutputUnitStart(unit)
        guard status == noErr else {
            throw CaptureError.failedToStartAudioUnit(status)
        }
    }

    // MARK: - Cleanup

    private func cleanup() {
        removeDeviceAliveListener()

        if let unit = audioUnit {
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            audioUnit = nil
        }

        if let ctx = renderContext {
            ctx.audioUnit = nil
            ctx.onBuffer = nil
            Unmanaged.passUnretained(ctx).release()
            renderContext = nil
        }

        destroyAggregateDevice()
        destroyTap()
        onBuffer = nil
    }

    private func destroyAggregateDevice() {
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
    }

    private func destroyTap() {
        if tapObjectID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapObjectID)
            tapObjectID = kAudioObjectUnknown
        }
    }

    // MARK: - Errors

    enum CaptureError: Error, LocalizedError {
        case failedToCreateTap(OSStatus)
        case failedToTranslatePID(pid_t, OSStatus)
        case failedToGetTapUID(OSStatus)
        case failedToCreateAggregateDevice(OSStatus)
        case audioComponentNotFound
        case failedToCreateAudioUnit(OSStatus)
        case failedToConfigureAudioUnit(OSStatus)
        case failedToSetDevice(OSStatus)
        case failedToSetFormat(OSStatus)
        case failedToSetCallback(OSStatus)
        case failedToInitializeAudioUnit(OSStatus)
        case failedToStartAudioUnit(OSStatus)
        case audioUnitNotReady

        var errorDescription: String? {
            switch self {
            case .failedToCreateTap(let s): return "Failed to create process tap (OSStatus \(s))"
            case .failedToTranslatePID(let pid, let s): return "Failed to translate PID \(pid) to process object (OSStatus \(s))"
            case .failedToGetTapUID(let s): return "Failed to get tap UID (OSStatus \(s))"
            case .failedToCreateAggregateDevice(let s): return "Failed to create aggregate device (OSStatus \(s))"
            case .audioComponentNotFound: return "HAL Output AudioComponent not found"
            case .failedToCreateAudioUnit(let s): return "Failed to create AudioUnit (OSStatus \(s))"
            case .failedToConfigureAudioUnit(let s): return "Failed to configure AudioUnit (OSStatus \(s))"
            case .failedToSetDevice(let s): return "Failed to set audio device (OSStatus \(s))"
            case .failedToSetFormat(let s): return "Failed to set stream format (OSStatus \(s))"
            case .failedToSetCallback(let s): return "Failed to set render callback (OSStatus \(s))"
            case .failedToInitializeAudioUnit(let s): return "Failed to initialize AudioUnit (OSStatus \(s))"
            case .failedToStartAudioUnit(let s): return "Failed to start AudioUnit (OSStatus \(s))"
            case .audioUnitNotReady: return "AudioUnit not ready"
            }
        }
    }
}

// MARK: - Device Alive Listener (free function)

/// Called by CoreAudio when the aggregate device's alive status changes.
/// Uses Unmanaged.passUnretained(self) -- safe because removeDeviceAliveListener()
/// is called synchronously in stop()/cleanup() before self can deallocate.
private func deviceAliveListener(
    objectID: AudioObjectID,
    numberAddresses: UInt32,
    addresses: UnsafePointer<AudioObjectPropertyAddress>,
    clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData else { return noErr }
    let capture = Unmanaged<SystemAudioCapture>.fromOpaque(clientData).takeUnretainedValue()

    var isAlive: UInt32 = 1
    var size = UInt32(MemoryLayout<UInt32>.size)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsAlive,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &isAlive)

    if isAlive == 0 {
        systemAudioCaptureLogger.error("Aggregate device \(objectID) is no longer alive")
        capture.onDisconnect?()
    }

    return noErr
}

// MARK: - Render Callback (free function)

/// The render callback is invoked by the AudioUnit on the real-time audio thread.
/// It pulls samples from the aggregate device (which includes our tap) and forwards
/// them as Int16 buffers to the Swift callback.
///
/// Uses a retained RenderContext instead of Unmanaged<SystemAudioCapture> to avoid
/// use-after-free when SystemAudioCapture is deallocated during an in-flight callback.
private func systemAudioRenderCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let context = Unmanaged<SystemAudioCapture.RenderContext>.fromOpaque(inRefCon).takeUnretainedValue()

    guard let unit = context.audioUnit else { return noErr }

    // Allocate a buffer for the rendered data
    let byteSize = Int(inNumberFrames) * MemoryLayout<Int16>.size
    let buffer = UnsafeMutablePointer<Int16>.allocate(capacity: Int(inNumberFrames))
    defer { buffer.deallocate() }

    var bufferList = AudioBufferList(
        mNumberBuffers: 1,
        mBuffers: AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(byteSize),
            mData: buffer
        )
    )

    let status = AudioUnitRender(
        unit,
        ioActionFlags,
        inTimeStamp,
        1, // input bus
        inNumberFrames,
        &bufferList
    )

    guard status == noErr else { return status }

    // Forward the Int16 samples to the callback
    let sampleCount = Int(inNumberFrames)
    let bufferPtr = UnsafeBufferPointer(start: buffer, count: sampleCount)
    context.onBuffer?(bufferPtr, sampleCount)

    return noErr
}

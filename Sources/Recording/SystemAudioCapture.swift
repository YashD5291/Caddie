import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import os

/// Captures system audio from a specific process (or all system audio) using CoreAudio Taps (macOS 14.2+),
/// or directly from a specific device via HAL AudioUnit.
/// Outputs raw PCM buffers (16kHz mono Int16) via callback.
///
/// Dual start paths:
/// - `start(processID:onBuffer:)` — v1.0 process tap path via aggregate device
/// - `start(deviceUID:onBuffer:)` — direct HAL AudioUnit on a specific device (no tap, no aggregate)
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
        // Conversion path: HALOutput silently delivers native rate despite our format
        // request, so we accept native pass-through and convert ourselves.
        var converter: AVAudioConverter?
        var nativeFormat: AVAudioFormat?
        var targetFormat: AVAudioFormat?
        // Preallocated buffers reused on the realtime thread to avoid per-callback
        // heap allocation. Oversized slices fall back to a one-off allocation.
        let maxFrames: AVAudioFrameCount = 4096
        var inputPCM: AVAudioPCMBuffer?
        var outputPCM: AVAudioPCMBuffer?
    }

    /// Output buffer capacity needed to hold `inputFrames` resampled from
    /// `inputSampleRate` to `outputSampleRate`. Pure sizing math shared by both
    /// render callbacks (and unit-tested); the `+ 1` guards against rounding-down
    /// losing the final partial frame.
    static func outputCapacity(
        forInputFrames inputFrames: AVAudioFrameCount,
        inputSampleRate: Double,
        outputSampleRate: Double
    ) -> AVAudioFrameCount {
        let ratio = outputSampleRate / inputSampleRate
        return AVAudioFrameCount(Double(inputFrames) * ratio) + 1
    }

    /// Called when the aggregate device dies (e.g., hardware disconnected mid-recording).
    var onDisconnect: (() -> Void)?

    private var audioUnit: AudioComponentInstance?
    private var onBuffer: BufferCallback?
    private var renderContext: RenderContext?

    private var aggregateDeviceID: AudioDeviceID = kAudioObjectUnknown
    private var tapObjectID: AudioObjectID = kAudioObjectUnknown
    private var directDeviceID: AudioDeviceID = kAudioObjectUnknown
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

    // MARK: - Format Conversion Helper

    /// Build an `AVAudioConverter` from a CoreAudio native format to 16kHz mono Int16.
    /// Used because `kAudioUnitSubType_HALOutput` silently delivers samples at the device's
    /// native rate even when we request 16kHz on the output scope, so we convert ourselves
    /// after rendering at native rate.
    static func makeDownsamplingConverter(
        from nativeASBD: AudioStreamBasicDescription,
        toSampleRate target: Double
    ) -> (converter: AVAudioConverter, nativeFormat: AVAudioFormat, targetFormat: AVAudioFormat)? {
        var asbd = nativeASBD
        // AVAudioFormat(streamDescription:) returns nil when mChannelsPerFrame > 2 —
        // it demands an explicit channel layout. Build a Discrete-In-Order layout
        // so devices with arbitrary channel counts (multi-track virtual drivers
        // like Jump Audio's 8-channel output) can still create a converter.
        let nativeFormat: AVAudioFormat?
        if asbd.mChannelsPerFrame > 2 {
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = kAudioChannelLayoutTag_DiscreteInOrder | UInt32(asbd.mChannelsPerFrame)
            let avLayout = AVAudioChannelLayout(layout: &layout)
            nativeFormat = AVAudioFormat(streamDescription: &asbd, channelLayout: avLayout)
        } else {
            nativeFormat = AVAudioFormat(streamDescription: &asbd)
        }
        guard let nativeFormat else { return nil }
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: target,
            channels: 1,
            interleaved: true
        ) else { return nil }
        guard let converter = AVAudioConverter(from: nativeFormat, to: targetFormat) else { return nil }
        return (converter, nativeFormat, targetFormat)
    }

    /// Preallocate the reusable input/output PCM buffers on `context` so the realtime
    /// render callback never allocates on the happy path.
    private func preallocateBuffers(on context: RenderContext, nativeFormat: AVAudioFormat, targetFormat: AVAudioFormat) {
        context.inputPCM = AVAudioPCMBuffer(pcmFormat: nativeFormat, frameCapacity: context.maxFrames)
        let outCapacity = Self.outputCapacity(
            forInputFrames: context.maxFrames,
            inputSampleRate: nativeFormat.sampleRate,
            outputSampleRate: targetFormat.sampleRate
        )
        context.outputPCM = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity)
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

    /// Start capturing from a specific device directly (no process tap, no aggregate device).
    /// Used when user selects a Loopback virtual device or other input device.
    /// - Parameters:
    ///   - deviceUID: Persistent UID string of the target device.
    ///   - onBuffer: Callback receiving Int16 PCM samples at 16kHz mono.
    func start(deviceUID: String, onBuffer: @escaping BufferCallback) throws {
        guard !isRunning else {
            logger.warning("SystemAudioCapture already running")
            return
        }

        self.onBuffer = onBuffer

        guard let deviceID = Self.resolveDeviceUID(deviceUID) else {
            throw CaptureError.deviceNotFound(deviceUID)
        }

        do {
            // Skip setupTap() entirely -- no tap, no aggregate device
            // Direct HAL AudioUnit on the resolved device
            try setupAudioUnitForDevice(deviceID)
            registerDeviceAliveListenerForDevice(deviceID)
            try startAudioUnit()

            directDeviceID = deviceID
            isRunning = true
            logger.info("System audio capture started via direct device (UID: \(deviceUID))")
        } catch {
            logger.error("Failed to start direct device capture: \(error.localizedDescription)")
            cleanupDirectDevice()
            throw error
        }
    }

    /// Stop capturing and release all resources.
    func stop() {
        guard isRunning else { return }
        isRunning = false

        if directDeviceID != kAudioObjectUnknown {
            // Direct device path cleanup
            removeDeviceAliveListenerForDevice()
        } else {
            // Aggregate device path cleanup (v1.0)
            removeDeviceAliveListener()
        }

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

        if directDeviceID != kAudioObjectUnknown {
            directDeviceID = kAudioObjectUnknown
        } else {
            destroyAggregateDevice()
            destroyTap()
        }

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

        // HALOutput silently ignores 16kHz format requests on aggregate-device-with-tap input,
        // delivering at the device's native rate (typically 48kHz). Match the device's native
        // format on the output scope so HALOutput does no SRC, then convert to 16kHz Int16
        // ourselves in the render callback.
        var nativeFormat = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioUnitGetProperty(
            audioUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            1,
            &nativeFormat,
            &formatSize
        )
        guard status == noErr else {
            throw CaptureError.failedToGetFormat(status)
        }
        logger.info("System audio native format: \(nativeFormat.mSampleRate)Hz, \(nativeFormat.mChannelsPerFrame)ch")

        status = AudioUnitSetProperty(
            audioUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            1,
            &nativeFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard status == noErr else {
            throw CaptureError.failedToSetFormat(status)
        }

        guard let conv = Self.makeDownsamplingConverter(from: nativeFormat, toSampleRate: Self.targetSampleRate) else {
            throw CaptureError.failedToCreateConverter
        }

        // Set the render callback via a retained context object.
        // The context holds references the callback needs (audioUnit, onBuffer, converter, formats),
        // avoiding Unmanaged.passUnretained(self) which risks use-after-free.
        let context = RenderContext()
        context.audioUnit = audioUnit
        context.onBuffer = onBuffer
        context.converter = conv.converter
        context.nativeFormat = conv.nativeFormat
        context.targetFormat = conv.targetFormat
        preallocateBuffers(on: context, nativeFormat: conv.nativeFormat, targetFormat: conv.targetFormat)
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
        if directDeviceID != kAudioObjectUnknown {
            removeDeviceAliveListenerForDevice()
        } else {
            removeDeviceAliveListener()
        }

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

        if directDeviceID != kAudioObjectUnknown {
            directDeviceID = kAudioObjectUnknown
        } else {
            destroyAggregateDevice()
            destroyTap()
        }
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

    // MARK: - Direct Device Path

    /// Resolve a persistent device UID string to a transient AudioDeviceID via CoreAudio.
    private static func resolveDeviceUID(_ uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDeviceForUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var cfUID = uid as CFString

        var translation = AudioValueTranslation(
            mInputData: &cfUID,
            mInputDataSize: UInt32(MemoryLayout<CFString>.size),
            mOutputData: &deviceID,
            mOutputDataSize: UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        var translationSize = UInt32(MemoryLayout<AudioValueTranslation>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &translationSize,
            &translation
        )

        guard status == noErr, deviceID != kAudioObjectUnknown else {
            return nil
        }

        return deviceID
    }

    /// Set up a HAL Output AudioUnit for a specific device following TN2091 order.
    /// Same setup as `setupAudioUnit()` but uses the passed deviceID instead of aggregateDeviceID.
    private func setupAudioUnitForDevice(_ deviceID: AudioDeviceID) throws {
        // Step 1: Find HAL Output component
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

        // Step 2: Enable input on bus 1
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

        // Step 3: Disable output on bus 0
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

        // Step 4: Set device (MUST be after enabling IO)
        var devID = deviceID
        status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &devID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw CaptureError.failedToSetDevice(status)
        }

        // Step 5: Read native input format and pass it through on the output scope —
        // see comment in setupAudioUnit() for why we don't ask HALOutput to do SRC.
        var nativeFormat = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioUnitGetProperty(
            audioUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            1,
            &nativeFormat,
            &formatSize
        )
        guard status == noErr else {
            throw CaptureError.failedToGetFormat(status)
        }
        logger.info("Direct device native format: \(nativeFormat.mSampleRate)Hz, \(nativeFormat.mChannelsPerFrame)ch")

        status = AudioUnitSetProperty(
            audioUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            1,
            &nativeFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard status == noErr else {
            throw CaptureError.failedToSetFormat(status)
        }

        guard let conv = Self.makeDownsamplingConverter(from: nativeFormat, toSampleRate: Self.targetSampleRate) else {
            throw CaptureError.failedToCreateConverter
        }

        // Step 6: Set render callback via retained context object
        let context = RenderContext()
        context.audioUnit = audioUnit
        context.onBuffer = onBuffer
        context.converter = conv.converter
        context.nativeFormat = conv.nativeFormat
        context.targetFormat = conv.targetFormat
        preallocateBuffers(on: context, nativeFormat: conv.nativeFormat, targetFormat: conv.targetFormat)
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

        // Step 7: Initialize
        status = AudioUnitInitialize(audioUnit)
        guard status == noErr else {
            throw CaptureError.failedToInitializeAudioUnit(status)
        }
    }

    private func registerDeviceAliveListenerForDevice(_ deviceID: AudioDeviceID) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectAddPropertyListener(
            deviceID,
            &address,
            deviceAliveListener,
            Unmanaged.passUnretained(self).toOpaque()
        )
        if status != noErr {
            logger.warning("Failed to register direct device alive listener: OSStatus \(status)")
        }
    }

    private func removeDeviceAliveListenerForDevice() {
        guard directDeviceID != kAudioObjectUnknown else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListener(
            directDeviceID,
            &address,
            deviceAliveListener,
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    private func cleanupDirectDevice() {
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

        directDeviceID = kAudioObjectUnknown
        onBuffer = nil
    }

    // MARK: - Errors

    enum CaptureError: Error, LocalizedError {
        case failedToCreateTap(OSStatus)
        case failedToTranslatePID(pid_t, OSStatus)
        case failedToGetTapUID(OSStatus)
        case failedToCreateAggregateDevice(OSStatus)
        case deviceNotFound(String)
        case audioComponentNotFound
        case failedToCreateAudioUnit(OSStatus)
        case failedToConfigureAudioUnit(OSStatus)
        case failedToSetDevice(OSStatus)
        case failedToGetFormat(OSStatus)
        case failedToSetFormat(OSStatus)
        case failedToCreateConverter
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
            case .deviceNotFound(let uid): return "Audio device not found: \(uid)"
            case .audioComponentNotFound: return "HAL Output AudioComponent not found"
            case .failedToCreateAudioUnit(let s): return "Failed to create AudioUnit (OSStatus \(s))"
            case .failedToConfigureAudioUnit(let s): return "Failed to configure AudioUnit (OSStatus \(s))"
            case .failedToSetDevice(let s): return "Failed to set audio device (OSStatus \(s))"
            case .failedToGetFormat(let s): return "Failed to read stream format (OSStatus \(s))"
            case .failedToSetFormat(let s): return "Failed to set stream format (OSStatus \(s))"
            case .failedToCreateConverter: return "Failed to create audio format converter for system audio"
            case .failedToSetCallback(let s): return "Failed to set render callback (OSStatus \(s))"
            case .failedToInitializeAudioUnit(let s): return "Failed to initialize AudioUnit (OSStatus \(s))"
            case .failedToStartAudioUnit(let s): return "Failed to start AudioUnit (OSStatus \(s))"
            case .audioUnitNotReady: return "AudioUnit not ready"
            }
        }
    }
}

// MARK: - Device Alive Listener (free function)

/// Called by CoreAudio when a device's alive status changes.
/// Works for both aggregate devices (v1.0 path) and direct devices (v2.0 path).
/// Uses Unmanaged.passUnretained(self) -- safe because removeDeviceAliveListener()/
/// removeDeviceAliveListenerForDevice() is called synchronously in stop()/cleanup()
/// before self can deallocate.
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
/// It pulls samples at the device's native format (HALOutput won't do SRC honestly),
/// runs them through an `AVAudioConverter` to 16kHz mono Int16, and forwards them.
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

    guard let unit = context.audioUnit,
          let converter = context.converter,
          let nativeFormat = context.nativeFormat,
          let targetFormat = context.targetFormat else { return noErr }

    // Reuse the preallocated input buffer; fall back to a one-off allocation only if
    // this slice exceeds the preallocated capacity (never drop audio).
    let inputPCM: AVAudioPCMBuffer
    if let preallocated = context.inputPCM, inNumberFrames <= preallocated.frameCapacity {
        inputPCM = preallocated
    } else {
        guard let fallback = AVAudioPCMBuffer(pcmFormat: nativeFormat, frameCapacity: inNumberFrames) else {
            return noErr
        }
        inputPCM = fallback
    }
    inputPCM.frameLength = inNumberFrames

    let status = AudioUnitRender(
        unit,
        ioActionFlags,
        inTimeStamp,
        1, // input bus
        inNumberFrames,
        inputPCM.mutableAudioBufferList
    )
    guard status == noErr else { return status }

    let outputCapacity = SystemAudioCapture.outputCapacity(
        forInputFrames: inNumberFrames,
        inputSampleRate: nativeFormat.sampleRate,
        outputSampleRate: targetFormat.sampleRate
    )
    let outputPCM: AVAudioPCMBuffer
    if let preallocated = context.outputPCM, outputCapacity <= preallocated.frameCapacity {
        outputPCM = preallocated
        outputPCM.frameLength = 0
    } else {
        guard let fallback = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
            return noErr
        }
        outputPCM = fallback
    }

    var convertError: NSError?
    var hasInput = false
    converter.convert(to: outputPCM, error: &convertError) { _, outStatus in
        if hasInput {
            outStatus.pointee = .noDataNow
            return nil
        }
        hasInput = true
        outStatus.pointee = .haveData
        return inputPCM
    }

    guard convertError == nil,
          outputPCM.frameLength > 0,
          let int16Data = outputPCM.int16ChannelData else {
        return noErr
    }

    let sampleCount = Int(outputPCM.frameLength)
    let bufferPtr = UnsafeBufferPointer(start: int16Data[0], count: sampleCount)
    context.onBuffer?(bufferPtr, sampleCount)

    return noErr
}

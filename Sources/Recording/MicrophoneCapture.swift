import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import os

/// Captures microphone audio via AVAudioEngine (default device) or HAL AudioUnit (specific device).
/// Outputs raw PCM buffers (16kHz mono Int16) via callback.
///
/// Dual start paths:
/// - `start(onBuffer:)` — v1.0 AVAudioEngine path, captures from system default input
/// - `start(deviceUID:onBuffer:)` — HAL AudioUnit path, captures from a specific device by UID
final class MicrophoneCapture {

    typealias BufferCallback = (UnsafeBufferPointer<Int16>, Int) -> Void

    /// Retained context object passed to the HAL render callback via Unmanaged.passRetained.
    /// Eliminates use-after-free risk: the context is retained independently of `self`,
    /// so even if MicrophoneCapture is deallocated during an in-flight callback,
    /// the callback accesses valid memory.
    fileprivate final class RenderContext {
        var audioUnit: AudioComponentInstance?
        var onBuffer: BufferCallback?
        // HALOutput delivers samples at the device's native rate. We render at native
        // and convert to 16 kHz Int16 in the callback.
        var converter: AVAudioConverter?
        var nativeFormat: AVAudioFormat?
        var targetFormat: AVAudioFormat?
        // Preallocated buffers reused on the realtime thread to avoid per-callback
        // heap allocation. Sized for the expected maximum slice; oversized slices
        // fall back to a one-off allocation rather than dropping audio.
        let maxFrames: AVAudioFrameCount = 4096
        var inputPCM: AVAudioPCMBuffer?
        var outputPCM: AVAudioPCMBuffer?
    }

    private let logger = Logger(subsystem: "com.caddie.app", category: "MicrophoneCapture")

    // AVAudioEngine path (v1.0)
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?

    // HAL AudioUnit path
    private var halAudioUnit: AudioComponentInstance?
    private var renderContext: RenderContext?
    private var isUsingHAL = false

    // Shared state
    private var onBuffer: BufferCallback?
    private var isRunning = false

    // Target format: 16kHz mono 16-bit signed integer PCM
    private static let targetSampleRate: Double = 16000.0
    private static let targetChannels: AVAudioChannelCount = 1

    private static var targetFormat: AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: targetChannels,
            interleaved: true
        )!
    }

    deinit {
        stop()
    }

    /// Start capturing microphone audio.
    /// - Parameter onBuffer: Callback receiving Int16 PCM samples at 16kHz mono.
    func start(onBuffer: @escaping BufferCallback) throws {
        guard !isRunning else {
            logger.warning("MicrophoneCapture already running")
            return
        }

        self.onBuffer = onBuffer

        let engine = AVAudioEngine()
        self.engine = engine

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw CaptureError.noInputDevice
        }

        logger.info("Mic input format: \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount)ch")

        // Create converter from input format to target format
        let targetFormat = Self.targetFormat
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw CaptureError.failedToCreateConverter
        }
        self.converter = converter

        // Calculate how many output frames correspond to one input buffer
        let ratio = targetFormat.sampleRate / inputFormat.sampleRate

        // Install a tap on the input node
        let bufferSize: AVAudioFrameCount = 4096
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) {
            [weak self] (buffer, _) in
            guard let self else { return } // Real-time thread -- no logging
            self.processInputBuffer(buffer, ratio: ratio)
        }

        try engine.start()
        isRunning = true
        logger.info("Microphone capture started")
    }

    /// Start capturing from a specific device via HAL AudioUnit.
    /// - Parameters:
    ///   - deviceUID: Persistent UID string of the target device.
    ///   - onBuffer: Callback receiving Int16 PCM samples at 16kHz mono.
    func start(deviceUID: String, onBuffer: @escaping BufferCallback) throws {
        guard !isRunning else {
            logger.warning("MicrophoneCapture already running")
            return
        }

        self.onBuffer = onBuffer

        // Resolve UID to transient AudioDeviceID via CoreAudio
        guard let deviceID = Self.resolveDeviceUID(deviceUID) else {
            throw CaptureError.deviceNotFound(deviceUID)
        }

        do {
            // Follow TN2091 order: enable IO -> set device -> set format -> set callback -> init -> start
            try setupHALAudioUnit(deviceID: deviceID)
            try startHALAudioUnit()
            isUsingHAL = true
            isRunning = true
            logger.info("Microphone capture started via HAL AudioUnit (device: \(deviceUID))")
        } catch {
            logger.error("Failed to start HAL microphone capture for device '\(deviceUID)': \(error.localizedDescription) (\(String(describing: error)))")
            cleanupHAL()
            throw error
        }
    }

    /// Stop capturing and release resources.
    func stop() {
        guard isRunning else { return }
        isRunning = false

        if isUsingHAL {
            cleanupHAL()
            isUsingHAL = false
        } else {
            // AVAudioEngine path cleanup (v1.0)
            engine?.inputNode.removeTap(onBus: 0)
            engine?.stop()
            engine = nil
            converter = nil
        }

        onBuffer = nil
        logger.info("Microphone capture stopped")
    }

    // MARK: - Private

    private func processInputBuffer(_ inputBuffer: AVAudioPCMBuffer, ratio: Double) {
        guard let converter = self.converter else { return }

        // Calculate output frame count based on ratio
        let outputFrameCount = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 1

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: Self.targetFormat,
            frameCapacity: outputFrameCount
        ) else {
            logger.error("Failed to allocate output buffer")
            return
        }

        var error: NSError?
        var hasInput = false

        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if hasInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            hasInput = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        if let error = error {
            logger.error("Audio conversion error: \(error.localizedDescription)")
            return
        }

        guard status != .error, outputBuffer.frameLength > 0 else { return }

        // Extract Int16 samples from the output buffer
        let sampleCount = Int(outputBuffer.frameLength)
        guard let int16Data = outputBuffer.int16ChannelData else {
            logger.error("Failed to access int16 channel data")
            return
        }

        let bufferPtr = UnsafeBufferPointer(start: int16Data[0], count: sampleCount)
        onBuffer?(bufferPtr, sampleCount)
    }

    // MARK: - HAL AudioUnit Setup

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

    /// Set up a HAL Output AudioUnit for the given device following TN2091 order.
    /// Order: enable IO -> set device -> set format -> set callback -> initialize.
    ///
    /// Uses `HALOutput` (not `VoiceProcessingIO`) so any input device works — virtual /
    /// loopback / aggregate devices cannot host VPIO's internal echo-cancel aggregate.
    /// We accept HALOutput's native-rate delivery and run our own `AVAudioConverter` in
    /// the render callback.
    private func setupHALAudioUnit(deviceID: AudioDeviceID) throws {
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
        self.halAudioUnit = audioUnit

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

        // Step 5: Read native input format and pass it through on the output scope.
        // HALOutput won't honestly down-convert (see comment at top of setupHALAudioUnit),
        // so we accept native and convert ourselves with AVAudioConverter.
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
            throw CaptureError.failedToConfigureAudioUnit(status)
        }
        logger.info("Mic native format: \(nativeFormat.mSampleRate)Hz, \(nativeFormat.mChannelsPerFrame)ch")

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

        guard let conv = SystemAudioCapture.makeDownsamplingConverter(
            from: nativeFormat,
            toSampleRate: Self.targetSampleRate
        ) else {
            throw CaptureError.failedToCreateConverter
        }

        // Step 6: Set render callback via retained context object
        let context = RenderContext()
        context.audioUnit = audioUnit
        context.onBuffer = onBuffer
        context.converter = conv.converter
        context.nativeFormat = conv.nativeFormat
        context.targetFormat = conv.targetFormat
        context.inputPCM = AVAudioPCMBuffer(pcmFormat: conv.nativeFormat, frameCapacity: context.maxFrames)
        let outCapacity = SystemAudioCapture.outputCapacity(
            forInputFrames: context.maxFrames,
            inputSampleRate: conv.nativeFormat.sampleRate,
            outputSampleRate: conv.targetFormat.sampleRate
        )
        context.outputPCM = AVAudioPCMBuffer(pcmFormat: conv.targetFormat, frameCapacity: outCapacity)
        self.renderContext = context

        var callbackStruct = AURenderCallbackStruct(
            inputProc: microphoneRenderCallback,
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

    private func startHALAudioUnit() throws {
        guard let unit = halAudioUnit else {
            throw CaptureError.audioUnitNotReady
        }
        let status = AudioOutputUnitStart(unit)
        guard status == noErr else {
            throw CaptureError.failedToStartAudioUnit(status)
        }
    }

    private func cleanupHAL() {
        if let unit = halAudioUnit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            halAudioUnit = nil
        }

        if let ctx = renderContext {
            ctx.audioUnit = nil
            ctx.onBuffer = nil
            Unmanaged.passUnretained(ctx).release()
            renderContext = nil
        }
    }

    // MARK: - Errors

    enum CaptureError: Error, LocalizedError {
        case noInputDevice
        case failedToCreateConverter
        case deviceNotFound(String)
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
            case .noInputDevice: return "No audio input device available"
            case .failedToCreateConverter: return "Failed to create audio format converter"
            case .deviceNotFound(let uid): return "Audio device not found: \(uid)"
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

// MARK: - Render Callback (free function)

/// The render callback is invoked by the AudioUnit on the real-time audio thread.
/// It pulls samples from the input device and forwards them as Int16 buffers to the Swift callback.
///
/// Uses a retained RenderContext instead of Unmanaged<MicrophoneCapture> to avoid
/// use-after-free when MicrophoneCapture is deallocated during an in-flight callback.
private func microphoneRenderCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let context = Unmanaged<MicrophoneCapture.RenderContext>.fromOpaque(inRefCon).takeUnretainedValue()

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

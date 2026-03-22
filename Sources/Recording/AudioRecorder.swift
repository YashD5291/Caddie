import AudioToolbox
import Foundation
import os

enum RecordingMode: String, Sendable {
    case systemAndMic
    case micOnly
}

/// Orchestrates SystemAudioCapture + MicrophoneCapture into a stereo WAV file.
/// Left channel = system audio, Right channel = microphone.
/// Both channels are 16kHz 16-bit signed integer PCM.
///
/// Audio data flows lock-free from real-time threads:
///   render callback -> SPSCRingBuffer.write() (no locks) -> flush timer reads on main thread
final class AudioRecorder {

    /// Called when the system audio device disconnects mid-recording.
    var onDeviceDisconnected: (@Sendable () -> Void)?

    private(set) var recordingMode: RecordingMode = .systemAndMic

    private let logger = Logger(subsystem: "com.caddie.app", category: "AudioRecorder")

    private let systemCapture = SystemAudioCapture()
    private let micCapture = MicrophoneCapture()

    private var audioFile: ExtAudioFileRef?
    private var isRecording = false

    // Ring buffers: sized for ~2 seconds of audio at 16kHz (32768 = next power of 2 above 32000)
    // Producer: real-time audio thread (via callbacks). Consumer: flush timer on main thread.
    private var systemRingBuffer: SPSCRingBuffer?
    private var micRingBuffer: SPSCRingBuffer?
    private var flushTimer: DispatchSourceTimer?
    private static let ringBufferCapacity = 32768

    // Stereo WAV format: 2 channels, 16kHz, 16-bit signed integer PCM
    private static let sampleRate: Float64 = 16000.0
    private static let channels: UInt32 = 2
    private static let bitsPerChannel: UInt32 = 16

    deinit {
        stop()
    }

    /// Start recording system audio and microphone to a stereo WAV file.
    /// - Parameters:
    ///   - outputPath: URL for the output WAV file.
    ///   - processID: If provided, capture system audio from this process only.
    func start(outputPath: URL, processID: pid_t?) throws {
        guard !isRecording else {
            logger.warning("AudioRecorder already recording")
            return
        }

        // Create the stereo WAV file
        try createWAVFile(at: outputPath)

        // Create ring buffers
        systemRingBuffer = SPSCRingBuffer(capacity: Self.ringBufferCapacity)
        micRingBuffer = SPSCRingBuffer(capacity: Self.ringBufferCapacity)

        isRecording = true

        // Set up a flush timer on the main queue (100ms interval)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self else {
                CaddieLogger.recording.warning("AudioRecorder deallocated -- flush timer orphaned")
                return
            }
            self.flushRingBuffers()
        }
        timer.resume()
        flushTimer = timer

        // Start system audio capture
        do {
            try systemCapture.start(processID: processID) { [weak self] (buffer, count) in
                guard let self else { return }  // Real-time thread -- no logging
                self.handleSystemAudioBuffer(buffer, count: count)
            }
            recordingMode = .systemAndMic
            systemCapture.onDisconnect = { [weak self] in
                CaddieLogger.recording.error("System audio device disconnected mid-recording")
                // Capture callback before dispatching to avoid sending self across isolation
                let callback = self?.onDeviceDisconnected
                DispatchQueue.main.async {
                    callback?()
                }
            }
        } catch {
            recordingMode = .micOnly
            logger.error("Failed to start system audio capture: \(error.localizedDescription)")
            logger.warning("Recording will continue with microphone only (system channel will be silence)")
            // Continue without system audio -- microphone-only recording is still useful
        }

        // Start microphone capture
        try micCapture.start { [weak self] (buffer, count) in
            guard let self else { return }  // Real-time thread -- no logging
            self.handleMicBuffer(buffer, count: count)
        }

        logger.info("AudioRecorder started: \(outputPath.lastPathComponent)")
    }

    /// Stop recording and finalize the WAV file.
    func stop() {
        guard isRecording else { return }
        isRecording = false

        systemCapture.onDisconnect = nil  // Prevent disconnect callback during intentional stop
        systemCapture.stop()
        micCapture.stop()

        // Cancel the flush timer
        flushTimer?.cancel()
        flushTimer = nil

        // Final flush of any remaining samples
        flushRingBuffersFinal()

        // Close the audio file
        if let file = audioFile {
            ExtAudioFileDispose(file)
            audioFile = nil
        }

        systemRingBuffer = nil
        micRingBuffer = nil
        recordingMode = .systemAndMic

        logger.info("AudioRecorder stopped")
    }

    // MARK: - WAV File Creation

    private func createWAVFile(at url: URL) throws {
        var format = AudioStreamBasicDescription(
            mSampleRate: Self.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: Self.channels * (Self.bitsPerChannel / 8),
            mFramesPerPacket: 1,
            mBytesPerFrame: Self.channels * (Self.bitsPerChannel / 8),
            mChannelsPerFrame: Self.channels,
            mBitsPerChannel: Self.bitsPerChannel,
            mReserved: 0
        )

        var file: ExtAudioFileRef?
        let status = ExtAudioFileCreateWithURL(
            url as CFURL,
            kAudioFileWAVEType,
            &format,
            nil,
            AudioFileFlags.eraseFile.rawValue,
            &file
        )

        guard status == noErr, let audioFile = file else {
            throw RecorderError.failedToCreateFile(status)
        }

        self.audioFile = audioFile
    }

    // MARK: - Buffer Handling (lock-free)

    private func handleSystemAudioBuffer(_ buffer: UnsafeBufferPointer<Int16>, count: Int) {
        guard isRecording else { return }
        // Lock-free write -- safe on real-time audio thread
        let written = systemRingBuffer?.write(buffer, count: count) ?? 0
        if written < count {
            logger.warning("System audio ring buffer overflow: dropped \(count - written) samples")
        }
    }

    private func handleMicBuffer(_ buffer: UnsafeBufferPointer<Int16>, count: Int) {
        guard isRecording else { return }
        // Lock-free write -- safe on real-time audio thread
        let written = micRingBuffer?.write(buffer, count: count) ?? 0
        if written < count {
            logger.warning("Mic ring buffer overflow: dropped \(count - written) samples")
        }
    }

    // MARK: - Flush (main thread)

    /// Periodic flush: reads the minimum of both ring buffers to maintain stereo sync.
    private func flushRingBuffers() {
        guard let systemRB = systemRingBuffer, let micRB = micRingBuffer else { return }

        let systemAvailable = systemRB.availableToRead
        let micAvailable = micRB.availableToRead

        // Flush the minimum of both to maintain stereo sync
        let frameCount = min(systemAvailable, micAvailable)
        guard frameCount > 0 else { return }

        let systemSamples = UnsafeMutablePointer<Int16>.allocate(capacity: frameCount)
        let micSamples = UnsafeMutablePointer<Int16>.allocate(capacity: frameCount)
        defer {
            systemSamples.deallocate()
            micSamples.deallocate()
        }

        let systemRead = systemRB.read(into: systemSamples, count: frameCount)
        let micRead = micRB.read(into: micSamples, count: frameCount)
        let actualFrames = min(systemRead, micRead)
        guard actualFrames > 0 else { return }

        // Interleave: [system0, mic0, system1, mic1, ...]
        var interleaved = [Int16](repeating: 0, count: actualFrames * 2)
        for i in 0..<actualFrames {
            interleaved[i * 2] = systemSamples[i]
            interleaved[i * 2 + 1] = micSamples[i]
        }

        writeToFile(interleaved: interleaved, frameCount: UInt32(actualFrames))
    }

    /// Final flush: drains all remaining samples, padding the shorter channel with silence.
    private func flushRingBuffersFinal() {
        guard let systemRB = systemRingBuffer, let micRB = micRingBuffer else { return }

        let systemAvailable = systemRB.availableToRead
        let micAvailable = micRB.availableToRead
        let frameCount = max(systemAvailable, micAvailable)
        guard frameCount > 0 else { return }

        let systemSamples = UnsafeMutablePointer<Int16>.allocate(capacity: frameCount)
        let micSamples = UnsafeMutablePointer<Int16>.allocate(capacity: frameCount)
        defer {
            systemSamples.deallocate()
            micSamples.deallocate()
        }

        // Initialize to silence
        systemSamples.initialize(repeating: 0, count: frameCount)
        micSamples.initialize(repeating: 0, count: frameCount)

        let systemRead = systemRB.read(into: systemSamples, count: frameCount)
        let micRead = micRB.read(into: micSamples, count: frameCount)
        let actualFrames = max(systemRead, micRead)
        guard actualFrames > 0 else { return }

        var interleaved = [Int16](repeating: 0, count: actualFrames * 2)
        for i in 0..<actualFrames {
            interleaved[i * 2] = (i < systemRead) ? systemSamples[i] : 0
            interleaved[i * 2 + 1] = (i < micRead) ? micSamples[i] : 0
        }

        writeToFile(interleaved: interleaved, frameCount: UInt32(actualFrames))
    }

    private func writeToFile(interleaved: [Int16], frameCount: UInt32) {
        guard let file = audioFile else { return }

        interleaved.withUnsafeBufferPointer { bufferPtr in
            var bufferList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: Self.channels,
                    mDataByteSize: frameCount * Self.channels * (Self.bitsPerChannel / 8),
                    mData: UnsafeMutableRawPointer(mutating: bufferPtr.baseAddress)
                )
            )

            let status = ExtAudioFileWrite(file, frameCount, &bufferList)
            if status != noErr {
                logger.error("Failed to write audio data: OSStatus \(status)")
            }
        }
    }

    // MARK: - Errors

    enum RecorderError: Error, LocalizedError {
        case failedToCreateFile(OSStatus)

        var errorDescription: String? {
            switch self {
            case .failedToCreateFile(let s): return "Failed to create WAV file (OSStatus \(s))"
            }
        }
    }
}

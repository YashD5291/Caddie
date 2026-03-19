import AudioToolbox
import Foundation
import os

/// Orchestrates SystemAudioCapture + MicrophoneCapture into a stereo WAV file.
/// Left channel = system audio, Right channel = microphone.
/// Both channels are 16kHz 16-bit signed integer PCM.
final class AudioRecorder {

    private let logger = Logger(subsystem: "com.caddie.app", category: "AudioRecorder")

    private let systemCapture = SystemAudioCapture()
    private let micCapture = MicrophoneCapture()

    private var audioFile: ExtAudioFileRef?
    private var isRecording = false

    // Thread-safe buffer management
    private let lock = NSLock()
    private var systemBuffer: [Int16] = []
    private var micBuffer: [Int16] = []

    // Flush threshold: ~100ms at 16kHz
    private static let flushThreshold = 1600

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

        // Reserve buffer capacity to reduce allocations
        lock.lock()
        systemBuffer.reserveCapacity(Self.flushThreshold * 2)
        micBuffer.reserveCapacity(Self.flushThreshold * 2)
        lock.unlock()

        isRecording = true

        // Start system audio capture
        do {
            try systemCapture.start(processID: processID) { [weak self] (buffer, count) in
                self?.handleSystemAudioBuffer(buffer, count: count)
            }
        } catch {
            logger.error("Failed to start system audio capture: \(error.localizedDescription)")
            logger.warning("Recording will continue with microphone only (system channel will be silence)")
            // Continue without system audio — microphone-only recording is still useful
        }

        // Start microphone capture
        try micCapture.start { [weak self] (buffer, count) in
            self?.handleMicBuffer(buffer, count: count)
        }

        logger.info("AudioRecorder started: \(outputPath.lastPathComponent)")
    }

    /// Stop recording and finalize the WAV file.
    func stop() {
        guard isRecording else { return }
        isRecording = false

        systemCapture.stop()
        micCapture.stop()

        // Final flush of remaining samples
        lock.lock()
        flushBuffers(final: true)
        lock.unlock()

        // Close the audio file
        if let file = audioFile {
            ExtAudioFileDispose(file)
            audioFile = nil
        }

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

    // MARK: - Buffer Handling

    private func handleSystemAudioBuffer(_ buffer: UnsafeBufferPointer<Int16>, count: Int) {
        guard isRecording else { return }
        lock.lock()
        systemBuffer.append(contentsOf: buffer)
        flushIfReady()
        lock.unlock()
    }

    private func handleMicBuffer(_ buffer: UnsafeBufferPointer<Int16>, count: Int) {
        guard isRecording else { return }
        lock.lock()
        micBuffer.append(contentsOf: buffer)
        flushIfReady()
        lock.unlock()
    }

    private func flushIfReady() {
        // Both buffers need at least flushThreshold samples
        if systemBuffer.count >= Self.flushThreshold && micBuffer.count >= Self.flushThreshold {
            flushBuffers(final: false)
        }
    }

    /// Interleave system and mic samples and write to the WAV file.
    /// Must be called with lock held.
    private func flushBuffers(final: Bool) {
        // Determine how many frames we can write
        let frameCount: Int
        if final {
            // On final flush, write all available frames, padding the shorter buffer with silence
            frameCount = max(systemBuffer.count, micBuffer.count)
        } else {
            // Normal flush: only write complete pairs
            frameCount = min(systemBuffer.count, micBuffer.count)
        }

        guard frameCount > 0 else { return }

        // Interleave: [system0, mic0, system1, mic1, ...]
        var interleaved = [Int16](repeating: 0, count: frameCount * 2)
        for i in 0..<frameCount {
            let systemSample = i < systemBuffer.count ? systemBuffer[i] : 0
            let micSample = i < micBuffer.count ? micBuffer[i] : 0
            interleaved[i * 2] = systemSample
            interleaved[i * 2 + 1] = micSample
        }

        // Remove consumed samples from buffers
        let systemConsumed = min(frameCount, systemBuffer.count)
        let micConsumed = min(frameCount, micBuffer.count)
        systemBuffer.removeFirst(systemConsumed)
        micBuffer.removeFirst(micConsumed)

        // Write to the audio file
        writeToFile(interleaved: interleaved, frameCount: UInt32(frameCount))
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

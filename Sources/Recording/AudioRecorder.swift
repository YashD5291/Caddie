import AudioToolbox
import Foundation
import os

/// Captures audio from a single input device (selected device or system default)
/// into a mono 16 kHz 16-bit WAV file.
///
/// Audio data flows lock-free from the real-time audio thread:
///   render callback -> SPSCRingBuffer.write() (no locks) -> flush timer reads on main thread
final class AudioRecorder {

    /// Called when the input device disconnects mid-recording.
    var onDeviceDisconnected: (@Sendable () -> Void)?

    /// Called on the main thread with each drained batch of samples (16 kHz mono Int16),
    /// AFTER they are written to the WAV. nil when live transcription is inactive — when
    /// nil, behavior is identical to today (pure WAV write, real-time thread untouched).
    ///
    /// Main-thread only; deliberately not @Sendable — see LiveTranscriber.feed's
    /// MainActor assertion for the runtime check.
    var onSamples: (([Int16]) -> Void)?

    private let logger = Logger(subsystem: "com.caddie.app", category: "AudioRecorder")

    private let capture = MicrophoneCapture()

    private var audioFile: ExtAudioFileRef?
    private var isRecording = false
    private var currentDeviceUID: String?

    // Ring buffer sized for ~2 seconds of audio at 16 kHz (32768 = next power of 2 above 32000)
    // Producer: real-time audio thread (via callback). Consumer: flush timer on main thread.
    private var ringBuffer: SPSCRingBuffer?
    private var flushTimer: DispatchSourceTimer?
    private static let ringBufferCapacity = 32768

    // Mono WAV format: 1 channel, 16 kHz, 16-bit signed integer PCM
    private static let sampleRate: Float64 = 16000.0
    private static let channels: UInt32 = 1
    private static let bitsPerChannel: UInt32 = 16

    deinit {
        stop()
    }

    /// Start recording from a single input device.
    /// - Parameters:
    ///   - outputPath: URL for the output WAV file.
    ///   - deviceUID: Persistent UID of the input device, or nil for system default input.
    func start(outputPath: URL, deviceUID: String?) throws {
        guard !isRecording else {
            logger.warning("AudioRecorder already recording")
            return
        }

        try createWAVFile(at: outputPath)

        ringBuffer = SPSCRingBuffer(capacity: Self.ringBufferCapacity)

        isRecording = true

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self else {
                CaddieLogger.recording.warning("AudioRecorder deallocated -- flush timer orphaned")
                return
            }
            self.flushRingBuffer()
        }
        timer.resume()
        flushTimer = timer

        do {
            try startCapture(deviceUID: deviceUID)
            currentDeviceUID = deviceUID
        } catch {
            // Roll back partial state if capture fails to start.
            logger.error("Capture failed to start; rolling back: \(error.localizedDescription)")
            isRecording = false
            flushTimer?.cancel()
            flushTimer = nil
            if let file = audioFile {
                ExtAudioFileDispose(file)
                audioFile = nil
            }
            ringBuffer = nil
            throw error
        }

        logger.info("AudioRecorder started: \(outputPath.lastPathComponent)")
    }

    /// Switch to a different input device without stopping or finalizing the WAV.
    /// The audio file, ring buffer, and flush timer remain live across the switch —
    /// the resulting recording is a single continuous file with a brief silence gap
    /// while the new device's Core Audio unit comes online.
    ///
    /// On failure, attempts to revert to the previous device. If revert also fails,
    /// the recorder transitions to a stopped state and fires `onDeviceDisconnected`
    /// so the coordinator can finalize the recording cleanly.
    func switchDevice(deviceUID: String?) throws {
        guard isRecording else {
            logger.warning("AudioRecorder.switchDevice called while not recording -- ignoring")
            return
        }
        let oldUID = currentDeviceUID
        let newDesc = deviceUID ?? "system-default"
        let oldDesc = oldUID ?? "system-default"
        if oldUID == deviceUID {
            logger.info("Input device unchanged (\(newDesc)); no-op switch")
            return
        }
        logger.info("Switching input device: \(oldDesc) -> \(newDesc)")

        // Stop only the capture component. audioFile / ringBuffer / flushTimer
        // stay live so samples continue to land in the same WAV.
        capture.stop()

        do {
            try startCapture(deviceUID: deviceUID)
            currentDeviceUID = deviceUID
            logger.info("Input device switched to \(newDesc)")
        } catch {
            logger.error("Failed to start capture on \(newDesc): \(error.localizedDescription)")
            // Attempt revert to the previous device so the recording survives.
            do {
                try startCapture(deviceUID: oldUID)
                logger.warning("Reverted to previous device \(oldDesc) after switch failure")
                throw RecorderError.switchFailed(error)
            } catch {
                logger.error("Revert to \(oldDesc) also failed: \(error.localizedDescription)")
                // Both new and old device unusable — the recording cannot continue.
                // Finalize the WAV NOW (cancel flush timer, drain ring buffer, dispose
                // the file) before notifying the coordinator, so no samples are lost and
                // no live timer/file outlives this failure. A later coordinator stop()
                // then safely no-ops via the isRecording guard.
                isRecording = false
                finalizeRecording()
                onDeviceDisconnected?()
                throw RecorderError.switchAndRevertFailed(error)
            }
        }
    }

    private func startCapture(deviceUID: String?) throws {
        if let deviceUID {
            try capture.start(deviceUID: deviceUID) { [weak self] (buffer, count) in
                guard let self else { return }
                self.handleBuffer(buffer, count: count)
            }
        } else {
            try capture.start { [weak self] (buffer, count) in
                guard let self else { return }
                self.handleBuffer(buffer, count: count)
            }
        }
    }

    /// Stop recording and finalize the WAV file.
    func stop() {
        guard isRecording else { return }
        isRecording = false
        finalizeRecording()
    }

    /// Tear down capture and the WAV pipeline: stop the capture component, cancel the
    /// flush timer, drain any buffered samples, and dispose the audio file. Idempotent
    /// with respect to nil resources — safe to call once after `isRecording` is cleared.
    /// Callers MUST set `isRecording = false` first.
    private func finalizeRecording() {
        capture.stop()

        flushTimer?.cancel()
        flushTimer = nil

        // Clear the live tee BEFORE the final drain. This final flushRingBuffer() may
        // run off-main (finalizeRecording is invoked on the caller's thread, e.g. the
        // coordinator actor's executor on the switchDevice catastrophic path), and the
        // tee closure does MainActor.assumeIsolated -> it would trap off-main. The live
        // tee is display-only and the recording is ending, so the drained samples have
        // no further use for live text; clearing prevents the MainActor assumption from
        // trapping. Covers all final-drain paths (stop() and switchDevice failure).
        onSamples = nil

        // Final drain of any remaining samples
        flushRingBuffer()

        if let file = audioFile {
            ExtAudioFileDispose(file)
            audioFile = nil
        }

        ringBuffer = nil

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

    private func handleBuffer(_ buffer: UnsafeBufferPointer<Int16>, count: Int) {
        guard isRecording else { return }
        let written = ringBuffer?.write(buffer, count: count) ?? 0
        if written < count {
            logger.warning("Audio ring buffer overflow: dropped \(count - written) samples")
        }
    }

    // MARK: - Flush (main thread)

    private func flushRingBuffer() {
        guard let rb = ringBuffer else { return }
        let available = rb.availableToRead
        guard available > 0 else { return }

        let samples = UnsafeMutablePointer<Int16>.allocate(capacity: available)
        defer { samples.deallocate() }

        let read = rb.read(into: samples, count: available)
        guard read > 0 else { return }

        writeToFile(samples: samples, frameCount: UInt32(read))

        // Tee the same samples to the live transcriber after the WAV write.
        // Copy into a Swift array because the raw buffer is owned by this function
        // and freed at scope exit (via defer above). No-op allocation when onSamples is nil.
        if let onSamples {
            onSamples(Array(UnsafeBufferPointer(start: samples, count: read)))
        }
    }

    private func writeToFile(samples: UnsafeMutablePointer<Int16>, frameCount: UInt32) {
        guard let file = audioFile else { return }

        var bufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: Self.channels,
                mDataByteSize: frameCount * Self.channels * (Self.bitsPerChannel / 8),
                mData: UnsafeMutableRawPointer(samples)
            )
        )

        let status = ExtAudioFileWrite(file, frameCount, &bufferList)
        if status != noErr {
            logger.error("Failed to write audio data: OSStatus \(status)")
        }
    }

    // MARK: - Testing

    #if DEBUG
    /// Test-only: enqueue samples into the ring buffer and drain once, exercising
    /// the same flush path (WAV write skipped when no audioFile) and the onSamples tee.
    func testFeedAndFlush(_ samples: [Int16]) {
        if ringBuffer == nil {
            ringBuffer = SPSCRingBuffer(capacity: Self.ringBufferCapacity)
        }
        samples.withUnsafeBufferPointer { _ = ringBuffer?.write($0, count: samples.count) }
        flushRingBuffer()
    }
    #endif

    // MARK: - Errors

    enum RecorderError: Error, LocalizedError {
        case failedToCreateFile(OSStatus)
        case switchFailed(Error)
        case switchAndRevertFailed(Error)

        var errorDescription: String? {
            switch self {
            case .failedToCreateFile(let s): return "Failed to create WAV file (OSStatus \(s))"
            case .switchFailed(let underlying):
                return "Device switch failed (reverted to previous device): \(underlying.localizedDescription)"
            case .switchAndRevertFailed(let underlying):
                return "Device switch failed and could not revert: \(underlying.localizedDescription)"
            }
        }
    }
}

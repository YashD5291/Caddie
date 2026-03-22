import AVFoundation
import Foundation
import os

/// Captures microphone audio via AVAudioEngine.
/// Outputs raw PCM buffers (16kHz mono Int16) via callback.
final class MicrophoneCapture {

    typealias BufferCallback = (UnsafeBufferPointer<Int16>, Int) -> Void

    private let logger = Logger(subsystem: "com.caddie.app", category: "MicrophoneCapture")

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
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

    /// Stop capturing and release resources.
    func stop() {
        guard isRunning else { return }
        isRunning = false

        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        converter = nil
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

    // MARK: - Errors

    enum CaptureError: Error, LocalizedError {
        case noInputDevice
        case failedToCreateConverter

        var errorDescription: String? {
            switch self {
            case .noInputDevice: return "No audio input device available"
            case .failedToCreateConverter: return "Failed to create audio format converter"
            }
        }
    }
}

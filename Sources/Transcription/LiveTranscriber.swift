import AVFoundation
import FluidAudio
import Foundation

/// Display-only live transcriber. Wraps a StreamingTranscriptionEngine (FluidAudio
/// by default) and pushes (confirmed, volatile) text to `onUpdate` on the main actor.
///
/// Error policy (spec): nothing here ever propagates to callers. Any failure is
/// logged via CaddieLogger.transcription and the transcriber stops; recording
/// continues untouched. Lives on @MainActor because its public surface (`feed` from
/// the recorder's main-thread flush, `onUpdate` to the UI) is main-thread; it bridges
/// to the StreamingAsrManager actor with `await`.
@MainActor
final class LiveTranscriber {

    /// (confirmed, volatile) pushed on every update, on the main actor.
    var onUpdate: ((String, String) -> Void)?

    private let engine: StreamingTranscriptionEngine
    private var consumerTask: Task<Void, Never>?
    private var isRunning = false

    private var confirmedText = ""
    private var volatileText = ""

    init(engine: StreamingTranscriptionEngine) {
        self.engine = engine
    }

    /// Start streaming. The engine already holds its ASR models (bound at
    /// construction). Never throws — start failures are logged and leave the
    /// transcriber inert.
    func start() async {
        guard !isRunning else { return }
        do {
            try await engine.start()
        } catch {
            CaddieLogger.transcription.error("LiveTranscriber failed to start: \(error.localizedDescription)")
            return
        }
        isRunning = true

        let stream = engine.updates()
        consumerTask = Task { [weak self] in
            for await update in stream {
                guard let self else { break }
                self.apply(update)
            }
        }
    }

    /// Convert a drained batch of 16 kHz mono Int16 samples and hand to the engine.
    /// Non-blocking: the conversion is cheap and synchronous, but `stream(_:)` is
    /// actor-isolated, so it is dispatched on a detached-from-flush Task.
    func feed(samples: [Int16]) {
        guard isRunning, !samples.isEmpty else { return }
        let buffer = Self.makeBuffer(from: samples)
        Task { [engine] in
            await engine.stream(buffer)
        }
    }

    /// Cancel the engine and consumer task. Idempotent.
    func stop() async {
        guard isRunning else { return }
        isRunning = false
        consumerTask?.cancel()
        consumerTask = nil
        await engine.cancel()
    }

    // MARK: - Private

    private func apply(_ update: (text: String, isConfirmed: Bool)) {
        if update.isConfirmed {
            // Promote: confirmed accumulates stable text; volatile resets.
            confirmedText = update.text
            volatileText = ""
        } else {
            volatileText = update.text
        }
        onUpdate?(confirmedText, volatileText)
    }

    // MARK: - Conversion

    /// Int16 16 kHz mono -> AVAudioPCMBuffer (Float32, 16 kHz, mono).
    /// Scales by 1/32768 so Int16.min maps to exactly -1.0.
    static func makeBuffer(from samples: [Int16]) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
        let frameCount = AVAudioFrameCount(samples.count)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(frameCount, 1))!
        buffer.frameLength = frameCount
        if let channel = buffer.floatChannelData {
            let out = channel[0]
            for i in 0..<samples.count {
                out[i] = Float(samples[i]) / 32768.0
            }
        }
        return buffer
    }
}

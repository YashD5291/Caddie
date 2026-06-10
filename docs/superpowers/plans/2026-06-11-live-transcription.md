# Live Transcription Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stream live transcripts in the meeting detail view while recording, using FluidAudio StreamingAsrManager; display-only, final transcript unchanged.

**Architecture:** A new `@MainActor` `LiveTranscriber` wraps FluidAudio's `StreamingAsrManager` (`.streaming` config) behind a `StreamingTranscriptionEngine` protocol seam so update plumbing is unit-testable without models. `AudioRecorder` gains an `onSamples` tee invoked inside `flushRingBuffer()` after the WAV write; `RecordingCoordinator` starts the transcriber after `recorder.start` succeeds and wires the tee, then detaches the tee and stops the transcriber before enqueueing the batch pipeline (and on device-disconnect/error paths). `AppState` exposes observable `liveConfirmedText`/`liveVolatileText`, and `MeetingDetailView`'s recording card renders an auto-scrolling live transcript.

**Tech Stack:** Swift 6 strict concurrency, FluidAudio StreamingAsrManager (.streaming config), SwiftUI, XCTest
---

## API Facts (verified against FluidAudio checkout)

These are the real signatures every task below depends on. Do not deviate.

- `public actor StreamingAsrManager` — `init(config: StreamingAsrConfig = .default)`.
- `func start(models: AsrModels, source: AudioSource = .microphone) async throws` — reuses pre-loaded models; no extra model load.
- `func streamAudio(_ buffer: AVAudioPCMBuffer)` — **actor-isolated, NOT `nonisolated`**, so every call from outside the actor requires `await`. Therefore `LiveTranscriber.feed(...)` must NOT block the recorder's flush timer; it hops via `Task { await ... }`.
- `var transcriptionUpdates: AsyncStream<StreamingTranscriptionUpdate>` — consume with `for await`.
- `func cancel() async` — tears down without a final flush (we never call `finish()`; the batch pipeline owns the real transcript).
- `StreamingAsrConfig.streaming` — the low-latency 11-2-2 preset.
- `public struct StreamingTranscriptionUpdate: Sendable` — fields used here: `let text: String`, `let isConfirmed: Bool` (true => confirmed/stable, false => volatile/revising). Other fields (`confidence`, `timestamp`, `tokenIds`, `tokenTimings`) are ignored.
- `public enum AudioSource: Sendable { case microphone; case system }`.
- `AsrModels` is the type held by `ModelManager.asrModels` (already loaded at app launch).

Because `start`/`cancel`/`streamAudio` are all actor-isolated and async, `LiveTranscriber` is a `@MainActor final class` (its public surface is called from the main thread: `onSamples` tee and AppState UI), and it bridges to the `StreamingAsrManager` actor with `await`.

---

## Task 1 — LiveTranscriber + protocol seam + conversion/plumbing tests

**Files:**
- Create: `Sources/Transcription/StreamingTranscriptionEngine.swift`
- Create: `Sources/Transcription/LiveTranscriber.swift`
- Create: `Tests/Mocks/MockStreamingEngine.swift`
- Test: `Tests/LiveTranscriberTests.swift`

### Steps

- [ ] Write the protocol seam file `Sources/Transcription/StreamingTranscriptionEngine.swift`:

```swift
import AVFoundation
import FluidAudio

/// Abstraction over FluidAudio's StreamingAsrManager so LiveTranscriber's
/// update plumbing is unit-testable without loading CoreML models.
/// All members are async because the production conformer is an actor.
protocol StreamingTranscriptionEngine: Sendable {
    func start(models: AsrModels) async throws
    func stream(_ buffer: AVAudioPCMBuffer) async
    func updates() -> AsyncStream<(text: String, isConfirmed: Bool)>
    func cancel() async
}

/// Production conformer backing onto FluidAudio's StreamingAsrManager with the
/// low-latency `.streaming` preset. Microphone source (live view never shows
/// system audio separately).
final class FluidStreamingEngine: StreamingTranscriptionEngine, @unchecked Sendable {
    private let manager = StreamingAsrManager(config: .streaming)

    func start(models: AsrModels) async throws {
        try await manager.start(models: models, source: .microphone)
    }

    func stream(_ buffer: AVAudioPCMBuffer) async {
        await manager.streamAudio(buffer)
    }

    func updates() -> AsyncStream<(text: String, isConfirmed: Bool)> {
        let upstream = manager.transcriptionUpdates
        return AsyncStream { continuation in
            let task = Task {
                for await update in upstream {
                    continuation.yield((text: update.text, isConfirmed: update.isConfirmed))
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    func cancel() async {
        await manager.cancel()
    }
}
```

- [ ] Write the mock `Tests/Mocks/MockStreamingEngine.swift` (mirrors `Tests/Mocks/MockASREngine.swift` style):

```swift
import AVFoundation
import FluidAudio
@testable import Caddie

/// In-memory stand-in for FluidStreamingEngine. Drives the update stream
/// manually so plumbing tests run without CoreML models.
final class MockStreamingEngine: StreamingTranscriptionEngine, @unchecked Sendable {
    private(set) var startCallCount = 0
    private(set) var cancelCallCount = 0
    private(set) var streamedBuffers: [AVAudioPCMBuffer] = []
    var startError: Error?

    private var continuation: AsyncStream<(text: String, isConfirmed: Bool)>.Continuation?

    func start(models: AsrModels) async throws {
        startCallCount += 1
        if let startError { throw startError }
    }

    func stream(_ buffer: AVAudioPCMBuffer) async {
        streamedBuffers.append(buffer)
    }

    func updates() -> AsyncStream<(text: String, isConfirmed: Bool)> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    func cancel() async {
        cancelCallCount += 1
        continuation?.finish()
    }

    /// Test hook: push a synthetic update through the stream.
    func emit(text: String, isConfirmed: Bool) {
        continuation?.yield((text: text, isConfirmed: isConfirmed))
    }
}
```

- [ ] Write the failing test `Tests/LiveTranscriberTests.swift`:

```swift
import AVFoundation
import XCTest
@testable import Caddie

@MainActor
final class LiveTranscriberTests: XCTestCase {

    // MARK: - Int16 -> AVAudioPCMBuffer conversion

    func testInt16ToBufferProducesMono16kFloatBuffer() {
        let samples: [Int16] = [0, Int16.max, Int16.min, 16384]
        let buffer = LiveTranscriber.makeBuffer(from: samples)

        XCTAssertEqual(buffer.format.sampleRate, 16000)
        XCTAssertEqual(buffer.format.channelCount, 1)
        XCTAssertEqual(buffer.format.commonFormat, .pcmFormatFloat32)
        XCTAssertEqual(Int(buffer.frameLength), samples.count)

        let ch = buffer.floatChannelData![0]
        XCTAssertEqual(ch[0], 0.0, accuracy: 0.0001)
        XCTAssertEqual(ch[1], 1.0, accuracy: 0.001)        // Int16.max / 32768 ~ 0.99997
        XCTAssertEqual(ch[2], -1.0, accuracy: 0.001)       // Int16.min / 32768 == -1.0
        XCTAssertEqual(ch[3], 0.5, accuracy: 0.001)        // 16384 / 32768 == 0.5
    }

    func testEmptySamplesProduceZeroLengthBuffer() {
        let buffer = LiveTranscriber.makeBuffer(from: [])
        XCTAssertEqual(buffer.frameLength, 0)
    }

    // MARK: - Update plumbing via protocol seam

    func testConfirmedAndVolatileUpdatesReachOnUpdate() async {
        let engine = MockStreamingEngine()
        let transcriber = LiveTranscriber(engine: engine)

        var received: [(String, String)] = []
        transcriber.onUpdate = { confirmed, volatile in
            received.append((confirmed, volatile))
        }

        await transcriber.start(models: nil)
        XCTAssertEqual(engine.startCallCount, 1)

        // A volatile update arrives first (still revising).
        engine.emit(text: "hello", isConfirmed: false)
        // Then a confirmed update promotes it to stable.
        engine.emit(text: "hello world", isConfirmed: true)

        // Allow the consumer task to drain the stream.
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(received[0].0, "")              // confirmed still empty
        XCTAssertEqual(received[0].1, "hello")         // volatile shows interim text
        XCTAssertEqual(received[1].0, "hello world")   // confirmed now holds stable text
        XCTAssertEqual(received[1].1, "")              // volatile cleared after confirmation
    }

    func testStopCancelsEngineAndIsIdempotent() async {
        let engine = MockStreamingEngine()
        let transcriber = LiveTranscriber(engine: engine)
        await transcriber.start(models: nil)

        await transcriber.stop()
        await transcriber.stop()  // idempotent: no second cancel, no crash

        XCTAssertEqual(engine.cancelCallCount, 1)
    }

    func testStartErrorDoesNotPropagate() async {
        let engine = MockStreamingEngine()
        engine.startError = NSError(domain: "test", code: 1)
        let transcriber = LiveTranscriber(engine: engine)

        // Must NOT throw — errors are logged and swallowed so recording survives.
        await transcriber.start(models: nil)

        // After a failed start, feed/stop are safe no-ops.
        transcriber.feed(samples: [1, 2, 3])
        await transcriber.stop()
    }
}
```

- [ ] Run the test, expect FAIL (LiveTranscriber does not exist yet):
  `make test 2>&1 | tail -40`
  (Or scoped: `xcodebuild test -project Caddie.xcodeproj -scheme Caddie -configuration Debug -destination 'platform=macOS' -only-testing:CaddieTests/LiveTranscriberTests 2>&1 | tail -40`)

- [ ] Write the minimal implementation `Sources/Transcription/LiveTranscriber.swift`:

```swift
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

    init(engine: StreamingTranscriptionEngine = FluidStreamingEngine()) {
        self.engine = engine
    }

    /// Start streaming. Reuses already-loaded ASR models. Never throws — start
    /// failures are logged and leave the transcriber inert.
    func start(models: AsrModels?) async {
        guard !isRunning else { return }
        guard let models else {
            CaddieLogger.transcription.warning("LiveTranscriber.start skipped: ASR models absent")
            return
        }
        do {
            try await engine.start(models: models)
        } catch {
            CaddieLogger.transcription.error("LiveTranscriber failed to start: \(error.localizedDescription)")
            return
        }
        isRunning = true

        let stream = engine.updates()
        consumerTask = Task { [weak self] in
            for await update in stream {
                await self?.apply(update)
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
```

- [ ] Add the two new Sources files and the MockStreamingEngine to `Tests/Mocks` (no project.yml edit needed — `sources: [Sources]` and `sources: [Tests]` are directory globs, so new files are auto-picked-up on `xcodegen generate`, which `make test` runs).

- [ ] Run the test, expect PASS:
  `make test 2>&1 | tail -40`

- [ ] Commit:
  `git add Sources/Transcription/StreamingTranscriptionEngine.swift Sources/Transcription/LiveTranscriber.swift Tests/Mocks/MockStreamingEngine.swift Tests/LiveTranscriberTests.swift`
  `git commit -m "feat(transcription): add LiveTranscriber with StreamingTranscriptionEngine seam"`

---

## Task 2 — AudioRecorder onSamples tee + tests

**Files:**
- Modify: `Sources/Recording/AudioRecorder.swift`
- Test: `Tests/AudioRecorderTeeTests.swift`

### Steps

- [ ] Write the failing test `Tests/AudioRecorderTeeTests.swift` (style mirrors `AudioRecorderDeviceRoutingTests.swift`: compile-level + behavioral guards, no real device):

```swift
import XCTest
@testable import Caddie

final class AudioRecorderTeeTests: XCTestCase {

    /// The tee property exists, is optional, and accepts a [Int16] batch.
    func testOnSamplesPropertyIsSettableAndClearable() {
        let recorder = AudioRecorder()
        var captured: [[Int16]] = []
        recorder.onSamples = { captured.append($0) }
        XCTAssertNotNil(recorder.onSamples)
        recorder.onSamples = nil
        XCTAssertNil(recorder.onSamples)
        XCTAssertTrue(captured.isEmpty)
    }

    /// flushRingBuffer is a private main-thread drain; exercise the tee directly via
    /// the testable hook. With samples queued, the callback receives exactly the
    /// drained batch (same values written to the WAV).
    func testFlushInvokesOnSamplesWithDrainedBatch() {
        let recorder = AudioRecorder()
        var received: [Int16] = []
        recorder.onSamples = { received.append(contentsOf: $0) }

        let input: [Int16] = [10, -20, 30, -40, 32767, -32768]
        recorder.testFeedAndFlush(input)

        XCTAssertEqual(received, input)
    }

    /// nil callback = no-op: draining must not crash and must remain a pure WAV write.
    func testFlushWithNilOnSamplesIsNoOp() {
        let recorder = AudioRecorder()
        recorder.onSamples = nil
        // Should not crash when there is nothing wired.
        recorder.testFeedAndFlush([1, 2, 3])
        XCTAssertNil(recorder.onSamples)
    }
}
```

- [ ] Run the test, expect FAIL (`onSamples` and `testFeedAndFlush` do not exist):
  `xcodebuild test -project Caddie.xcodeproj -scheme Caddie -configuration Debug -destination 'platform=macOS' -only-testing:CaddieTests/AudioRecorderTeeTests 2>&1 | tail -40`

- [ ] Add the tee property to `Sources/Recording/AudioRecorder.swift`, just below `onDeviceDisconnected`:

```swift
    /// Called on the main thread with each drained batch of samples (16 kHz mono Int16),
    /// AFTER they are written to the WAV. nil when live transcription is inactive — when
    /// nil, behavior is identical to today (pure WAV write, real-time thread untouched).
    var onSamples: (([Int16]) -> Void)?
```

- [ ] Invoke the tee inside `flushRingBuffer()` AFTER the WAV write (the WAV path stays the source of truth; the tee gets the identical samples). Replace the body of `flushRingBuffer()`:

```swift
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
        // Copy into a Swift array so the callback never touches the soon-to-be
        // deallocated buffer. No-op allocation when onSamples is nil.
        if let onSamples {
            onSamples(Array(UnsafeBufferPointer(start: samples, count: read)))
        }
    }
```

- [ ] Add a testable hook at the bottom of the class (just above `// MARK: - Errors`) so tests can drive the private flush without a live audio device:

```swift
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
```

- [ ] Run the test, expect PASS:
  `xcodebuild test -project Caddie.xcodeproj -scheme Caddie -configuration Debug -destination 'platform=macOS' -only-testing:CaddieTests/AudioRecorderTeeTests 2>&1 | tail -40`

- [ ] Confirm existing recorder tests still pass (nil tee = unchanged behavior):
  `xcodebuild test -project Caddie.xcodeproj -scheme Caddie -configuration Debug -destination 'platform=macOS' -only-testing:CaddieTests/AudioRecorderDeviceRoutingTests -only-testing:CaddieTests/AudioRecorderBufferTests 2>&1 | tail -20`

- [ ] Commit:
  `git add Sources/Recording/AudioRecorder.swift Tests/AudioRecorderTeeTests.swift`
  `git commit -m "feat(recording): tee drained samples via AudioRecorder.onSamples after WAV write"`

---

## Task 3 — RecordingCoordinator lifecycle wiring + tests

**Files:**
- Modify: `Sources/Coordinator/RecordingCoordinator.swift`
- Test: `Tests/RecordingCoordinatorLiveTranscriptionTests.swift`

The coordinator currently constructs `AudioRecorder()` internally only at the AppState call site; the coordinator itself receives the recorder via init. We add an optional `liveTranscriber: LiveTranscriber?` init parameter (nil when ASR models are absent). The coordinator: starts it after `recorder.start` succeeds and sets `recorder.onSamples`; on stop/disconnect/error it detaches `onSamples` first, then `await transcriber.stop()` BEFORE enqueueing the batch pipeline.

### Steps

- [ ] Write the failing test `Tests/RecordingCoordinatorLiveTranscriptionTests.swift` (uses a spy LiveTranscriber-shaped engine; verifies start-on-record and stop-before-enqueue ordering):

```swift
import XCTest
import GRDB
@testable import Caddie

@MainActor
final class RecordingCoordinatorLiveTranscriptionTests: XCTestCase {
    var db: AppDatabase!
    var pipeline: TranscriptionPipeline!
    var engine: MockStreamingEngine!
    var transcriber: LiveTranscriber!

    override func setUpWithError() throws {
        db = try AppDatabase(inMemory: true)
        pipeline = TranscriptionPipeline(asr: MockASREngine(), diarization: MockDiarizationEngine())
        engine = MockStreamingEngine()
        transcriber = LiveTranscriber(engine: engine)
    }

    override func tearDownWithError() throws {
        db = nil; pipeline = nil; engine = nil; transcriber = nil
    }

    private func makeCoordinator() -> RecordingCoordinator {
        RecordingCoordinator(
            database: db,
            recorder: AudioRecorder(),
            pipeline: pipeline,
            detector: MeetingDetector(),
            audioDeviceManager: nil,
            liveTranscriber: transcriber
        )
    }

    private func makeMeeting() -> DetectedMeeting {
        DetectedMeeting(app: "Manual", title: "Live Test", processId: nil)
    }

    /// On manual start, the coordinator starts the live transcriber.
    func testStartRecordingStartsLiveTranscriber() async {
        let coordinator = makeCoordinator()
        await coordinator.handle(.manualStart(title: "Live Test"))

        // Allow the start side effect (recorder.start + transcriber.start) to run.
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(engine.startCallCount, 1)
    }

    /// On stop, the transcriber is cancelled before the batch pipeline finishes.
    func testStopCancelsLiveTranscriberBeforeEnqueue() async {
        let coordinator = makeCoordinator()
        await coordinator.handle(.manualStart(title: "Live Test"))
        try? await Task.sleep(for: .milliseconds(100))

        await coordinator.handle(.manualStop)
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(engine.cancelCallCount, 1)
    }
}
```

- [ ] Run the test, expect FAIL (`liveTranscriber:` init param does not exist):
  `xcodebuild test -project Caddie.xcodeproj -scheme Caddie -configuration Debug -destination 'platform=macOS' -only-testing:CaddieTests/RecordingCoordinatorLiveTranscriptionTests 2>&1 | tail -40`

- [ ] Add the dependency to `RecordingCoordinator`. In the `// MARK: - Dependencies` block, after `audioDeviceManager`:

```swift
    private let liveTranscriber: LiveTranscriber?
```

- [ ] Extend the initializer signature and body (add the parameter after `audioDeviceManager`):

```swift
    init(
        database: AppDatabase,
        recorder: AudioRecorder,
        pipeline: TranscriptionPipeline,
        detector: MeetingDetector,
        audioDeviceManager: AudioDeviceManager? = nil,
        liveTranscriber: LiveTranscriber? = nil
    ) {
        self.database = database
        self.recorder = recorder
        self.pipeline = pipeline
        self.detector = detector
        self.audioDeviceManager = audioDeviceManager
        self.liveTranscriber = liveTranscriber
    }
```

- [ ] In `executeStartRecording`, after `recorder.start(...)` succeeds and `onDeviceDisconnected` is wired, start the transcriber and wire the tee. Replace the success block (the lines from `try recorder.start(...)` through `logger.info("Recording started for meeting \(meetingId)")`) with:

```swift
            try recorder.start(outputPath: wavPath, deviceUID: selectedDeviceUID)
            recorder.onDeviceDisconnected = { [self] in
                Task { await self.handle(.deviceDisconnected) }
            }

            // Live transcription: display-only side effect of entering .recording.
            // Failure to start is logged inside LiveTranscriber and ignored — the
            // recording proceeds with no live text.
            if let liveTranscriber {
                let models = await MainActor.run { self.asrModelsForLive }
                await liveTranscriber.start(models: models)
                recorder.onSamples = { [weak liveTranscriber] samples in
                    liveTranscriber?.feed(samples: samples)
                }
            }

            NotificationManager.recordingStarted(title: meeting.title)
            logger.info("Recording started for meeting \(meetingId)")
```

  Note: `LiveTranscriber` already holds nothing about models; it needs the `AsrModels`. Pass them in by having the coordinator capture them. Add a stored `AsrModels?` to the coordinator instead of reaching back to AppState — see next step.

- [ ] Add an `asrModels` field to the coordinator so `start(models:)` has the loaded models. In `// MARK: - Dependencies`, add:

```swift
    private let asrModels: AsrModels?
```

  Add `asrModels: AsrModels? = nil` as the final init parameter (after `liveTranscriber`) and assign `self.asrModels = asrModels` in the body. Replace the `let models = await MainActor.run { self.asrModelsForLive }` line above with a direct capture:

```swift
            if let liveTranscriber {
                let models = asrModels
                await liveTranscriber.start(models: models)
                recorder.onSamples = { [weak liveTranscriber] samples in
                    liveTranscriber?.feed(samples: samples)
                }
            }
```

  (Add `import FluidAudio` at the top of `RecordingCoordinator.swift` so `AsrModels` resolves.) Update the test's `makeCoordinator()` to also pass `asrModels: nil` — `LiveTranscriber.start(models: nil)` is a logged no-op for `engine.start`, but the MockStreamingEngine test asserts `startCallCount`; therefore the mock-based test must bypass the nil guard. To keep the test honest without real models, change the test to assert behavior through a transcriber whose engine is started regardless: keep `LiveTranscriber.start(models: nil)` as a no-op, and have the test pass a non-nil sentinel. Since `AsrModels` cannot be trivially constructed in tests, instead verify ordering at the LiveTranscriber seam:

  Revised guidance — the coordinator test cannot fabricate `AsrModels`. So the two coordinator tests above assert via the transcriber's `stop()` path and start path using `models: nil`, which means `engine.start` is NOT called. Adjust the assertions: `testStartRecordingStartsLiveTranscriber` asserts the transcriber's `stop()` is reachable; replace its body assertion with `XCTAssertEqual(engine.cancelCallCount, 0)` after start (proving no premature cancel), and rely on `testStopCancelsLiveTranscriberBeforeEnqueue` to assert `cancelCallCount == 1`. Update the test file accordingly before running:

```swift
    func testStartRecordingDoesNotCancelLiveTranscriberPrematurely() async {
        let coordinator = makeCoordinator()
        await coordinator.handle(.manualStart(title: "Live Test"))
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(engine.cancelCallCount, 0)
    }
```

  And `testStopCancelsLiveTranscriberBeforeEnqueue` stays as written: it asserts `engine.cancelCallCount == 1` because `stop()` calls `engine.cancel()` unconditionally only when `isRunning`. Since `start(models: nil)` leaves `isRunning == false`, `cancel` would NOT fire. To make `stop` reach `cancel`, the coordinator's stop path must call `transcriber.stop()` regardless; `LiveTranscriber.stop()` guards on `isRunning`. Therefore, to test the coordinator's *ordering* without real models, assert instead that `recorder.onSamples` is nil after stop. Replace `testStopCancelsLiveTranscriberBeforeEnqueue` body with the detach assertion below.

> Implementer note: real `AsrModels` cannot be built in unit tests. Keep coordinator tests focused on the wiring the coordinator owns (tee attach on start, tee detach on stop) rather than on engine.start/cancel counts, which require models. Final coordinator test file:

```swift
import XCTest
import GRDB
@testable import Caddie

@MainActor
final class RecordingCoordinatorLiveTranscriptionTests: XCTestCase {
    var db: AppDatabase!
    var pipeline: TranscriptionPipeline!
    var recorder: AudioRecorder!
    var transcriber: LiveTranscriber!

    override func setUpWithError() throws {
        db = try AppDatabase(inMemory: true)
        pipeline = TranscriptionPipeline(asr: MockASREngine(), diarization: MockDiarizationEngine())
        recorder = AudioRecorder()
        transcriber = LiveTranscriber(engine: MockStreamingEngine())
    }

    override func tearDownWithError() throws {
        db = nil; pipeline = nil; recorder = nil; transcriber = nil
    }

    private func makeCoordinator() -> RecordingCoordinator {
        RecordingCoordinator(
            database: db,
            recorder: recorder,
            pipeline: pipeline,
            detector: MeetingDetector(),
            audioDeviceManager: nil,
            liveTranscriber: transcriber,
            asrModels: nil
        )
    }

    /// After stop, the tee must be detached so no further samples flow to the
    /// (now-cancelled) transcriber while the batch pipeline runs.
    func testStopDetachesOnSamplesTee() async {
        let coordinator = makeCoordinator()
        await coordinator.handle(.manualStart(title: "Live Test"))
        try? await Task.sleep(for: .milliseconds(100))

        await coordinator.handle(.manualStop)
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertNil(recorder.onSamples, "onSamples must be detached before pipeline enqueue")
    }

    /// Device-disconnect path must also detach the tee.
    func testDeviceDisconnectDetachesOnSamplesTee() async {
        let coordinator = makeCoordinator()
        await coordinator.handle(.manualStart(title: "Live Test"))
        try? await Task.sleep(for: .milliseconds(100))

        await coordinator.handle(.deviceDisconnected)
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertNil(recorder.onSamples, "onSamples must be detached on device disconnect")
    }
}
```

- [ ] In `executeStopAndTranscribe`, detach the tee and stop the transcriber BEFORE enqueueing the pipeline (frees ANE before the full-accuracy pass). Replace the top of the method:

```swift
    private func executeStopAndTranscribe(meetingId: String) async {
        recorder.onDeviceDisconnected = nil  // Clear before stop to avoid re-entrant disconnect
        recorder.onSamples = nil             // Detach live tee before stopping capture
        recorder.stop()
        await liveTranscriber?.stop()        // Cancel streaming before batch pipeline (no ANE contention)
```

  (Leave the rest of `executeStopAndTranscribe` unchanged.)

- [ ] The device-disconnect path runs through `executeStopAndTranscribe` too (`.deviceDisconnected` reduces to `.stopAndTranscribe`, confirmed in `RecordingStateTests.testRecordingDeviceDisconnectedTransitionsToTranscribing`), so the detach above covers it. For the error path, add a teardown in `executeNotifyError` at the very top so a `.recordingFailed`/`.error` transition also tears down the live tee:

```swift
    private func executeNotifyError(meetingId: String, error: Error) async {
        recorder.onSamples = nil
        await liveTranscriber?.stop()
        logger.error("Meeting \(meetingId) ended in error state: \(error.localizedDescription)")
```

  (Rest of `executeNotifyError` unchanged.)

- [ ] Run the test, expect PASS:
  `xcodebuild test -project Caddie.xcodeproj -scheme Caddie -configuration Debug -destination 'platform=macOS' -only-testing:CaddieTests/RecordingCoordinatorLiveTranscriptionTests 2>&1 | tail -40`

- [ ] Confirm existing coordinator tests still pass (init gains defaulted params, so old call sites compile):
  `xcodebuild test -project Caddie.xcodeproj -scheme Caddie -configuration Debug -destination 'platform=macOS' -only-testing:CaddieTests/RecordingCoordinatorTests 2>&1 | tail -20`

- [ ] Commit:
  `git add Sources/Coordinator/RecordingCoordinator.swift Tests/RecordingCoordinatorLiveTranscriptionTests.swift`
  `git commit -m "feat(coordinator): start/stop LiveTranscriber around recording lifecycle"`

---

## Task 4 — AppState observable wiring

**Files:**
- Modify: `Sources/App/AppState.swift`
- Test: `Tests/AppStateLiveTextTests.swift`

### Steps

- [ ] Write the failing test `Tests/AppStateLiveTextTests.swift` (verifies the observable properties exist and clear on idle/new-recording semantics via a small helper):

```swift
import XCTest
@testable import Caddie

@MainActor
final class AppStateLiveTextTests: XCTestCase {

    func testLiveTextDefaultsEmpty() {
        let state = AppState()
        XCTAssertEqual(state.liveConfirmedText, "")
        XCTAssertEqual(state.liveVolatileText, "")
    }

    func testApplyLiveUpdateSetsBothStrings() {
        let state = AppState()
        state.applyLiveTranscript(confirmed: "hello world", volatile: "and")
        XCTAssertEqual(state.liveConfirmedText, "hello world")
        XCTAssertEqual(state.liveVolatileText, "and")
    }

    func testClearLiveTranscriptResetsBothStrings() {
        let state = AppState()
        state.applyLiveTranscript(confirmed: "hello", volatile: "world")
        state.clearLiveTranscript()
        XCTAssertEqual(state.liveConfirmedText, "")
        XCTAssertEqual(state.liveVolatileText, "")
    }
}
```

- [ ] Run the test, expect FAIL (`liveConfirmedText`/`applyLiveTranscript`/`clearLiveTranscript` do not exist):
  `xcodebuild test -project Caddie.xcodeproj -scheme Caddie -configuration Debug -destination 'platform=macOS' -only-testing:CaddieTests/AppStateLiveTextTests 2>&1 | tail -40`

- [ ] Add observable properties to `AppState`, after `transcriptionProgress`:

```swift
    /// Live (display-only) transcript shown in the recording card. Confirmed text is
    /// stable; volatile is the still-revising tail. Cleared on .idle and on new record start.
    var liveConfirmedText: String = ""
    var liveVolatileText: String = ""
```

- [ ] Add the two helpers (used by the LiveTranscriber callback and by the state-change wiring). Place them in `// MARK: - UI Actions` or just above it:

```swift
    func applyLiveTranscript(confirmed: String, volatile: String) {
        liveConfirmedText = confirmed
        liveVolatileText = volatile
    }

    func clearLiveTranscript() {
        liveConfirmedText = ""
        liveVolatileText = ""
    }
```

- [ ] Construct the `LiveTranscriber` in `initialize()` only when ASR models exist, wire its `onUpdate` to `applyLiveTranscript`, and pass it (and the models) into the coordinator. Replace the coordinator construction block (step 5) with:

```swift
            // 5. Create coordinator with all dependencies -- eliminates init race (REC-04)
            // All deps are non-optional: coordinator cannot exist without a working pipeline
            guard let db = database else {
                initError = "Database failed to initialize"
                return
            }
            let deviceManager = audioDeviceManager

            // Live transcription is display-only and only available when ASR models loaded.
            var liveTranscriber: LiveTranscriber?
            if modelManager.asrModels != nil {
                let lt = LiveTranscriber()
                lt.onUpdate = { [weak self] confirmed, volatile in
                    self?.applyLiveTranscript(confirmed: confirmed, volatile: volatile)
                }
                liveTranscriber = lt
            }

            let newCoordinator = RecordingCoordinator(
                database: db,
                recorder: AudioRecorder(),
                pipeline: pipeline,
                detector: MeetingDetector(),
                audioDeviceManager: deviceManager,
                liveTranscriber: liveTranscriber,
                asrModels: modelManager.asrModels
            )
```

  (`onUpdate` is `@MainActor`-safe: `LiveTranscriber` is `@MainActor`, and `AppState` is `@MainActor`.)

- [ ] Clear live text on `.idle` and on new recording start inside the existing `setOnStateChange` closure. In the `.idle` case add `self.clearLiveTranscript()`; in the `.recording` case add `self.clearLiveTranscript()`:

```swift
                    case .idle:
                        self.status = .idle
                        self.currentMeetingTitle = nil
                        self.recordingStartTime = nil
                        self.pipelineStep = .idle
                        self.clearLiveTranscript()
                    case .recording:
                        self.status = .recording
                        self.recordingStartTime = Date()
                        self.lastRecordingError = nil
                        self.clearLiveTranscript()
```

- [ ] Run the test, expect PASS:
  `xcodebuild test -project Caddie.xcodeproj -scheme Caddie -configuration Debug -destination 'platform=macOS' -only-testing:CaddieTests/AppStateLiveTextTests 2>&1 | tail -40`

- [ ] Commit:
  `git add Sources/App/AppState.swift Tests/AppStateLiveTextTests.swift`
  `git commit -m "feat(app): wire LiveTranscriber into AppState observable live text"`

---

## Task 5 — MeetingDetailView live transcript UI

**Files:**
- Modify: `Sources/UI/MainWindow/MeetingDetailView.swift`

This task is SwiftUI rendering with no unit test (view logic; covered by manual verification). The implementer adds a live transcript area to the existing `recordingCard`.

### Steps

- [ ] Add a `liveTranscriptView` to `MeetingDetailView` and embed it in `recordingCard`. Replace `recordingCard` with:

```swift
    private var recordingCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "mic.fill")
                    .foregroundStyle(.red)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recording in progress").font(.headline)
                    TimelineView(.periodic(from: .now, by: 1.0)) { _ in
                        Text(elapsedText)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }

            liveTranscriptView

            Button {
                appState.stopManualRecording()
            } label: {
                Label("Stop Recording", systemImage: "stop.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.regular)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// Scrolling, auto-pinned-to-bottom live transcript. Confirmed text in `.primary`,
    /// volatile tail in `.secondary`. Shows "Listening…" until the first text arrives.
    @ViewBuilder
    private var liveTranscriptView: some View {
        let confirmed = appState.liveConfirmedText
        let volatile = appState.liveVolatileText
        let isEmpty = confirmed.isEmpty && volatile.isEmpty

        ScrollViewReader { proxy in
            ScrollView {
                Group {
                    if isEmpty {
                        Text("Listening…")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        (Text(confirmed).foregroundStyle(.primary)
                            + Text(confirmed.isEmpty ? "" : " ")
                            + Text(volatile).foregroundStyle(.secondary))
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .id("liveTranscriptBottom")
            }
            .frame(height: 140)
            .padding(10)
            .background(.background.opacity(0.4), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onChange(of: confirmed) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("liveTranscriptBottom", anchor: .bottom)
                }
            }
            .onChange(of: volatile) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("liveTranscriptBottom", anchor: .bottom)
                }
            }
        }
    }
```

- [ ] Build to confirm the view compiles (no unit test for SwiftUI rendering):
  `make build 2>&1 | tail -20`

- [ ] Commit:
  `git add Sources/UI/MainWindow/MeetingDetailView.swift`
  `git commit -m "feat(ui): show live transcript in the recording card"`

---

## Task 6 — Full-suite run + README update

**Files:**
- Modify: `README.md`

### Steps

- [ ] Run the full test suite, expect PASS:
  `make test 2>&1 | tail -40`

- [ ] Add a live-transcription line to the README features section. Locate the bulleted features list (search for the line mentioning on-device transcription / diarization) and add an adjacent bullet:

```markdown
- **Live transcription** — see text appear in the meeting detail view within seconds while recording, powered by FluidAudio's on-device streaming ASR. Display-only; the final saved transcript is still produced by the full-accuracy pipeline (with speaker diarization) after you stop.
```

  (Match the surrounding bullet style/indentation exactly; do not duplicate an existing transcription bullet.)

- [ ] Commit:
  `git add README.md`
  `git commit -m "docs: note live transcription in README features"`

---

## Manual Verification

Live audio needs a real microphone, so the end-to-end path is verified by hand:

1. `make build` and launch Caddie.
2. Start a manual recording (menu bar or main window). Open the meeting in the detail view.
3. Confirm the recording card shows **"Listening…"** immediately, then live text appears within a few seconds of speech.
4. Speak a few sentences. Confirm:
   - Confirmed (stable) text renders in primary color; the still-revising tail renders in secondary color.
   - The transcript auto-scrolls to the bottom as new text arrives.
5. Press **Stop Recording**. Confirm:
   - The live card is replaced by the existing **"Transcribing audio…"** progress UI.
   - Live strings clear (no leftover live text) when the meeting returns to idle.
6. When transcription finishes, confirm the persisted transcript (with speaker labels) renders as before — identical quality to today; the live text was display-only and did not alter the saved result.
7. Sanity: pull the microphone (disconnect a USB mic) mid-recording and confirm the recording finalizes cleanly and the live tee stops without errors in Console (filter category "transcription").

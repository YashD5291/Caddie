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

        await transcriber.start()
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
        await transcriber.start()

        await transcriber.stop()
        await transcriber.stop()  // idempotent: no second cancel, no crash

        XCTAssertEqual(engine.cancelCallCount, 1)
    }

    func testStartErrorDoesNotPropagate() async {
        let engine = MockStreamingEngine()
        engine.startError = NSError(domain: "test", code: 1)
        let transcriber = LiveTranscriber(engine: engine)

        // Must NOT throw — errors are logged and swallowed so recording survives.
        await transcriber.start()

        // After a failed start, feed/stop are safe no-ops.
        transcriber.feed(samples: [1, 2, 3])
        await transcriber.stop()
    }
}

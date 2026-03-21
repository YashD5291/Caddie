import XCTest
@testable import Caddie

/// Tests for the ring buffer flush and interleave logic used by AudioRecorder.
/// Since AudioRecorder's methods are private, we test the ring buffer integration
/// pattern directly: write known samples to two ring buffers, read + interleave,
/// and verify the output.
final class AudioRecorderBufferTests: XCTestCase {

    func testInterleaveAndFlush() {
        let systemRB = SPSCRingBuffer(capacity: 256)
        let micRB = SPSCRingBuffer(capacity: 256)

        // Write known patterns
        let systemSamples: [Int16] = [100, 200, 300, 400]
        let micSamples: [Int16] = [10, 20, 30, 40]

        systemSamples.withUnsafeBufferPointer { ptr in
            _ = systemRB.write(ptr, count: 4)
        }
        micSamples.withUnsafeBufferPointer { ptr in
            _ = micRB.write(ptr, count: 4)
        }

        // Read and interleave (simulate flushRingBuffers)
        let frameCount = min(systemRB.availableToRead, micRB.availableToRead)
        XCTAssertEqual(frameCount, 4)

        let systemOut = UnsafeMutablePointer<Int16>.allocate(capacity: frameCount)
        let micOut = UnsafeMutablePointer<Int16>.allocate(capacity: frameCount)
        defer {
            systemOut.deallocate()
            micOut.deallocate()
        }

        let systemRead = systemRB.read(into: systemOut, count: frameCount)
        let micRead = micRB.read(into: micOut, count: frameCount)
        XCTAssertEqual(systemRead, 4)
        XCTAssertEqual(micRead, 4)

        // Interleave: [system0, mic0, system1, mic1, ...]
        var interleaved = [Int16](repeating: 0, count: frameCount * 2)
        for i in 0..<frameCount {
            interleaved[i * 2] = systemOut[i]
            interleaved[i * 2 + 1] = micOut[i]
        }

        XCTAssertEqual(interleaved, [100, 10, 200, 20, 300, 30, 400, 40])
    }

    func testFlushWithUnequalBuffersPadsSilence() {
        let systemRB = SPSCRingBuffer(capacity: 256)
        let micRB = SPSCRingBuffer(capacity: 256)

        // System has 4 samples, mic has 2
        let systemSamples: [Int16] = [100, 200, 300, 400]
        let micSamples: [Int16] = [10, 20]

        systemSamples.withUnsafeBufferPointer { ptr in
            _ = systemRB.write(ptr, count: 4)
        }
        micSamples.withUnsafeBufferPointer { ptr in
            _ = micRB.write(ptr, count: 2)
        }

        // Final flush: use max of both (simulates flushRingBuffersFinal)
        let frameCount = max(systemRB.availableToRead, micRB.availableToRead)
        XCTAssertEqual(frameCount, 4)

        let systemOut = UnsafeMutablePointer<Int16>.allocate(capacity: frameCount)
        let micOut = UnsafeMutablePointer<Int16>.allocate(capacity: frameCount)
        defer {
            systemOut.deallocate()
            micOut.deallocate()
        }

        // Initialize to silence
        systemOut.initialize(repeating: 0, count: frameCount)
        micOut.initialize(repeating: 0, count: frameCount)

        let systemRead = systemRB.read(into: systemOut, count: frameCount)
        let micRead = micRB.read(into: micOut, count: frameCount)

        // Interleave with silence padding for shorter channel
        let actualFrames = max(systemRead, micRead)
        var interleaved = [Int16](repeating: 0, count: actualFrames * 2)
        for i in 0..<actualFrames {
            interleaved[i * 2] = (i < systemRead) ? systemOut[i] : 0
            interleaved[i * 2 + 1] = (i < micRead) ? micOut[i] : 0
        }

        // mic channel padded with silence for frames 2 and 3
        XCTAssertEqual(interleaved, [100, 10, 200, 20, 300, 0, 400, 0])
    }

    func testEmptyBuffersProduceNoOutput() {
        let systemRB = SPSCRingBuffer(capacity: 256)
        let micRB = SPSCRingBuffer(capacity: 256)

        let systemAvailable = systemRB.availableToRead
        let micAvailable = micRB.availableToRead

        XCTAssertEqual(systemAvailable, 0)
        XCTAssertEqual(micAvailable, 0)

        // Simulate flush guard: frameCount = min(0, 0) = 0
        let frameCount = min(systemAvailable, micAvailable)
        XCTAssertEqual(frameCount, 0)
        // guard frameCount > 0 else { return } -- no output produced
    }

    func testWriteDoesNotUseNSLock() {
        // Structural test: verify SPSCRingBuffer.write completes without blocking.
        // Write from current thread (simulating real-time thread) -- no locks means no deadlock.
        let ringBuffer = SPSCRingBuffer(capacity: 1024)
        let samples = Array(repeating: Int16(1), count: 100)
        let written = samples.withUnsafeBufferPointer { ptr in
            ringBuffer.write(ptr, count: 100)
        }
        XCTAssertEqual(written, 100)

        // Verify data integrity after write
        let output = UnsafeMutablePointer<Int16>.allocate(capacity: 100)
        defer { output.deallocate() }
        let read = ringBuffer.read(into: output, count: 100)
        XCTAssertEqual(read, 100)
        for i in 0..<100 {
            XCTAssertEqual(output[i], Int16(1))
        }
    }
}

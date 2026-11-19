import XCTest
import AVFoundation
import ScreenCaptureKit
@testable import Caddie

/// Exactly-once contract for `WriterSink`'s `onFinalized` signal (D-13), exercised with a
/// real `AVAssetWriter` and a directly constructed sink — no SCStream, no TCC grant, no
/// display. Every file lives in a per-test temp directory (D-15).
final class WriterSinkFinalizeTests: XCTestCase {

    private var tempDir: URL!
    private let writerQueue = DispatchQueue(label: "test.writer")

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Terminal exits

    func testStoppedFinalizeFiresOnceAfterFinishWriting() async throws {
        let (writer, input) = try makeWriter(startWriting: true)
        let log = FinalizeLog()
        let finalized = expectation(description: "onFinalized")
        finalized.assertForOverFulfill = true
        let sink = makeSink(writer: writer, input: input, log: log, expectation: finalized)

        sink.finalize(reason: .stopped)

        await fulfillment(of: [finalized], timeout: 5)
        XCTAssertNotEqual(writer.status, .writing, "onFinalized must arrive only after finishWriting completed")
        await drainWriterQueue()
        XCTAssertEqual(log.count, 1)
    }

    func testStreamErrorFinalizeFiresOnce() async throws {
        let (writer, input) = try makeWriter(startWriting: true)
        let log = FinalizeLog()
        let finalized = expectation(description: "onFinalized")
        finalized.assertForOverFulfill = true
        let sink = makeSink(writer: writer, input: input, log: log, expectation: finalized)

        sink.finalize(reason: .streamError)

        await fulfillment(of: [finalized], timeout: 5)
        await drainWriterQueue()
        XCTAssertEqual(log.count, 1)
    }

    func testDoubleFinalizeFiresOnce() async throws {
        let (writer, input) = try makeWriter(startWriting: true)
        let log = FinalizeLog()
        let finalized = expectation(description: "onFinalized")
        finalized.assertForOverFulfill = true
        let sink = makeSink(writer: writer, input: input, log: log, expectation: finalized)

        // Stream death followed by teardown stops: the idempotency guard lets only the
        // first pass reach a terminal exit, so a waiter sees exactly one signal (D-06).
        sink.finalize(reason: .stopped)
        sink.finalize(reason: .stopped)
        sink.finalize(reason: .streamError)

        await fulfillment(of: [finalized], timeout: 5)
        await drainWriterQueue()
        XCTAssertEqual(log.count, 1)
    }

    func testFinalizeWithWriterNotWritingStillFires() async throws {
        let (writer, input) = try makeWriter(startWriting: false)
        XCTAssertEqual(writer.status, .unknown)
        let log = FinalizeLog()
        let finalized = expectation(description: "onFinalized")
        finalized.assertForOverFulfill = true
        let sink = makeSink(writer: writer, input: input, log: log, expectation: finalized)

        sink.finalize(reason: .stopped)

        await fulfillment(of: [finalized], timeout: 5)
        await drainWriterQueue()
        XCTAssertEqual(log.count, 1, "The not-writing early return must still release a waiter")
    }

    func testNilOnFinalizedIsSafe() async throws {
        let (writer, input) = try makeWriter(startWriting: true)
        let sink = WriterSink(
            writer: writer,
            videoInput: input,
            queue: writerQueue,
            onFirstFrameHostTime: nil,
            onStreamStopped: nil,
            onFinalized: nil
        )

        sink.finalize(reason: .stopped)

        // finalizeOnQueue must run before the test ends.
        await drainWriterQueue()
    }

    // MARK: - Helpers

    /// Mirrors the writer setup in `ScreenRecorder.start`: `.mov`, 10 s fragments, and the
    /// production HEVC settings for the compact preset at a small size.
    private func makeWriter(startWriting: Bool) throws -> (AVAssetWriter, AVAssetWriterInput) {
        let url = tempDir.appendingPathComponent("\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: ScreenRecorder.videoSettings(for: .compact, dimensions: (width: 320, height: 240))
        )
        input.expectsMediaDataInRealTime = true
        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)
        if startWriting {
            XCTAssertTrue(writer.startWriting(), "startWriting failed: \(String(describing: writer.error))")
        }
        return (writer, input)
    }

    /// Waits for every finalize pass already queued on the sink's confining queue, so a
    /// repeat fire from a second pass lands before the count is read.
    private func drainWriterQueue() async {
        let drained = expectation(description: "writer queue drained")
        writerQueue.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 5)
    }

    private func makeSink(writer: AVAssetWriter,
                          input: AVAssetWriterInput,
                          log: FinalizeLog,
                          expectation: XCTestExpectation) -> WriterSink {
        WriterSink(
            writer: writer,
            videoInput: input,
            queue: writerQueue,
            onFirstFrameHostTime: nil,
            onStreamStopped: nil,
            onFinalized: {
                log.record()
                expectation.fulfill()
            }
        )
    }
}

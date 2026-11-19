import XCTest
import AVFoundation
@testable import Caddie

final class VideoFileInspectorTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Usability rule (D-07)

    func testUsableRequiresPlayableDurationAndVideoTrack() {
        let inspection = VideoInspection(isPlayable: true, durationSeconds: 1.0, videoTrackCount: 1)
        XCTAssertTrue(inspection.isUsable)
    }

    func testNotPlayableIsUnusable() {
        let inspection = VideoInspection(isPlayable: false, durationSeconds: 1.0, videoTrackCount: 1)
        XCTAssertFalse(inspection.isUsable)
    }

    func testZeroDurationIsUnusable() {
        let inspection = VideoInspection(isPlayable: true, durationSeconds: 0, videoTrackCount: 1)
        XCTAssertFalse(inspection.isUsable)
    }

    func testNoVideoTrackIsUnusable() {
        let inspection = VideoInspection(isPlayable: true, durationSeconds: 1.0, videoTrackCount: 0)
        XCTAssertFalse(inspection.isUsable)
    }

    func testSingleFrameDurationIsUsable() {
        let inspection = VideoInspection(isPlayable: true, durationSeconds: 0.067, videoTrackCount: 1)
        XCTAssertTrue(inspection.isUsable, "A one-frame file has usable video, so D-07 keeps it")
    }

    // MARK: - Test double

    func testMockReturnsScriptedResultsAndRecordsCalls() async {
        let mock = MockVideoInspector()
        let unknown = tempDir.appendingPathComponent("unknown.mov")
        let scripted = tempDir.appendingPathComponent("scripted.mov")
        mock.setResult(.unreadable("AVFoundationErrorDomain -11829: Cannot Open"), for: scripted)

        let unknownResult = await mock.inspect(unknown)
        let scriptedResult = await mock.inspect(scripted)

        XCTAssertEqual(unknownResult, .inspected(MockVideoInspector.usable))
        XCTAssertEqual(scriptedResult, .unreadable("AVFoundationErrorDomain -11829: Cannot Open"))
        XCTAssertEqual(mock.inspectedURLs, [unknown, scripted])
        XCTAssertEqual(mock.inspectCallCount, 2)

        mock.defaultResult = .missing
        let missingResult = await mock.inspect(unknown)
        XCTAssertEqual(missingResult, .missing)
        XCTAssertEqual(mock.inspectCallCount, 3)
    }

    // MARK: - AVFoundation inspection

    func testMissingFileReportsMissing() async {
        let url = tempDir.appendingPathComponent("absent.mov")

        let result = await AVAssetVideoInspector().inspect(url)

        XCTAssertEqual(result, .missing)
    }

    func testPlayableMovieIsUsable() async throws {
        let url = tempDir.appendingPathComponent("playable.mov")
        try await makePlayableMovie(at: url, frameCount: 15, fps: 15)

        let result = await AVAssetVideoInspector().inspect(url)

        guard case .inspected(let inspection) = result else {
            XCTFail("Expected .inspected, got \(result)")
            return
        }
        XCTAssertTrue(inspection.isPlayable)
        XCTAssertEqual(inspection.durationSeconds, 1.0, accuracy: 0.1)
        XCTAssertEqual(inspection.videoTrackCount, 1)
        XCTAssertTrue(inspection.isUsable)
    }

    func testZeroByteFileIsUnreadable() async {
        let url = tempDir.appendingPathComponent("empty.mov")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data()))

        let result = await AVAssetVideoInspector().inspect(url)

        assertUnreadable(result)
    }

    func testSessionlessWriterOutputIsUnreadable() async throws {
        let url = tempDir.appendingPathComponent("sessionless.mov")
        try await makeSessionlessMovie(at: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "A writer stopped before its first frame leaves a file on disk")

        let result = await AVAssetVideoInspector().inspect(url)

        assertUnreadable(result)
    }

    func testGarbageFileIsUnreadable() async throws {
        let url = tempDir.appendingPathComponent("garbage.mov")
        try makeGarbageFile(at: url, size: 4096)

        let result = await AVAssetVideoInspector().inspect(url)

        assertUnreadable(result)
    }

    func testInspectionNeverModifiesTheFile() async throws {
        let playable = tempDir.appendingPathComponent("playable.mov")
        let empty = tempDir.appendingPathComponent("empty.mov")
        let sessionless = tempDir.appendingPathComponent("sessionless.mov")
        let garbage = tempDir.appendingPathComponent("garbage.mov")
        try await makePlayableMovie(at: playable, frameCount: 15, fps: 15)
        XCTAssertTrue(FileManager.default.createFile(atPath: empty.path, contents: Data()))
        try await makeSessionlessMovie(at: sessionless)
        try makeGarbageFile(at: garbage, size: 4096)

        for url in [playable, empty, sessionless, garbage] {
            let sizeBefore = try fileSize(at: url)

            _ = await AVAssetVideoInspector().inspect(url)

            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                          "\(url.lastPathComponent) must still exist after inspection")
            XCTAssertEqual(try fileSize(at: url), sizeBefore,
                           "\(url.lastPathComponent) must be unchanged by inspection")
        }
    }

    // MARK: - Fixtures

    private struct FixtureError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static let fixtureWidth = 320
    private static let fixtureHeight = 240

    private func assertUnreadable(_ result: VideoInspectionResult,
                                  file: StaticString = #filePath, line: UInt = #line) {
        guard case .unreadable(let message) = result else {
            XCTFail("Expected .unreadable, got \(result)", file: file, line: line)
            return
        }
        XCTAssertFalse(message.isEmpty, "The unreadable verdict must carry the error", file: file, line: line)
    }

    private func fileSize(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? Int else {
            throw FixtureError(message: "No size attribute for \(url.lastPathComponent)")
        }
        return size
    }

    private func makeWriter(at url: URL) throws -> (AVAssetWriter, AVAssetWriterInput) {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Self.fixtureWidth,
            AVVideoHeightKey: Self.fixtureHeight
        ])
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            throw FixtureError(message: "AVAssetWriter cannot add the video input")
        }
        writer.add(input)
        return (writer, input)
    }

    private func finish(_ writer: AVAssetWriter) async {
        let finished = expectation(description: "finishWriting")
        writer.finishWriting { finished.fulfill() }
        await fulfillment(of: [finished], timeout: 10)
    }

    /// Writes `frameCount` H.264 frames at `fps`, session 0 to `frameCount / fps` seconds.
    private func makePlayableMovie(at url: URL, frameCount: Int, fps: Int32) async throws {
        let (writer, input) = try makeWriter(at: url)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Self.fixtureWidth,
                kCVPixelBufferHeightKey as String: Self.fixtureHeight
            ]
        )
        guard writer.startWriting() else {
            throw FixtureError(message: "startWriting failed: \(String(describing: writer.error))")
        }
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<frameCount {
            try await waitUntilReady(input)
            let buffer = try makePixelBuffer(from: adaptor)
            let time = CMTime(value: Int64(frame), timescale: fps)
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw FixtureError(message: "append failed at frame \(frame): \(String(describing: writer.error))")
            }
        }

        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: Int64(frameCount), timescale: fps))
        await finish(writer)
        XCTAssertEqual(writer.status, .completed, "Fixture writer error: \(String(describing: writer.error))")
    }

    /// Mirrors the engine stopped before its first frame: writing started, no session.
    private func makeSessionlessMovie(at url: URL) async throws {
        let (writer, _) = try makeWriter(at: url)
        guard writer.startWriting() else {
            throw FixtureError(message: "startWriting failed: \(String(describing: writer.error))")
        }
        await finish(writer)
    }

    private func makeGarbageFile(at url: URL, size: Int) throws {
        let bytes = (0..<size).map { _ in UInt8.random(in: .min ... .max) }
        try Data(bytes).write(to: url)
    }

    /// Bounded wait (about 2 s) so a stuck writer fails the test instead of hanging it.
    private func waitUntilReady(_ input: AVAssetWriterInput) async throws {
        for _ in 0..<200 {
            if input.isReadyForMoreMediaData { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Writer input never became ready for more media data")
        throw FixtureError(message: "Writer input not ready after 2 s")
    }

    private func makePixelBuffer(from adaptor: AVAssetWriterInputPixelBufferAdaptor) throws -> CVPixelBuffer {
        guard let pool = adaptor.pixelBufferPool else {
            throw FixtureError(message: "Pixel buffer pool unavailable")
        }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            throw FixtureError(message: "CVPixelBufferPoolCreatePixelBuffer failed: \(status)")
        }
        return buffer
    }
}

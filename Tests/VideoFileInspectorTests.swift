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
}

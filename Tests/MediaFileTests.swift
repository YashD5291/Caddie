import XCTest
@testable import Caddie

/// Media deletion tests. Every call targets a per-test temp directory, never the
/// real Application Support data directory (D-15).
final class MediaFileTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - deleteMedia

    func testDeleteMediaRemovesWavM4aAndMov() throws {
        let wav = try touch("m1.wav", in: tempDir)
        let m4a = try touch("m1.m4a", in: tempDir)
        let mov = try touch("m1.mov", in: tempDir)

        AudioFileManager.deleteMedia(meetingId: "m1", in: tempDir)

        XCTAssertFalse(exists(wav))
        XCTAssertFalse(exists(m4a))
        XCTAssertFalse(exists(mov))
    }

    func testDeleteMediaWithOnlyM4aSucceeds() throws {
        let m4a = try touch("m1.m4a", in: tempDir)

        AudioFileManager.deleteMedia(meetingId: "m1", in: tempDir)

        XCTAssertFalse(exists(m4a))
    }

    func testDeleteMediaWithNoFilesSucceeds() throws {
        AudioFileManager.deleteMedia(meetingId: "m1", in: tempDir)

        let remaining = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testDeleteMediaLeavesOtherMeetingsUntouched() throws {
        try touch("m1.wav", in: tempDir)
        try touch("m1.m4a", in: tempDir)
        try touch("m1.mov", in: tempDir)
        let otherWav = try touch("m2.wav", in: tempDir)
        let otherM4a = try touch("m2.m4a", in: tempDir)
        let otherMov = try touch("m2.mov", in: tempDir)

        AudioFileManager.deleteMedia(meetingId: "m1", in: tempDir)

        XCTAssertTrue(exists(otherWav))
        XCTAssertTrue(exists(otherM4a))
        XCTAssertTrue(exists(otherMov))
    }

    func testDeleteMediaRejectsPathTraversalIds() throws {
        let subDir = tempDir.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        let nestedDir = tempDir.appendingPathComponent("a", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)
        let escapeMov = try touch("escape.mov", in: tempDir)
        let nestedMov = try touch("b.mov", in: nestedDir)
        let bareMov = try touch(".mov", in: tempDir)

        AudioFileManager.deleteMedia(meetingId: "../escape", in: subDir)
        AudioFileManager.deleteMedia(meetingId: "a/b", in: tempDir)
        AudioFileManager.deleteMedia(meetingId: "", in: tempDir)

        XCTAssertTrue(exists(escapeMov), "A '..' id must not escape the directory")
        XCTAssertTrue(exists(nestedMov), "An id containing '/' must be rejected")
        XCTAssertTrue(exists(bareMov), "An empty id must be rejected")
    }

    // MARK: - removeFileIfPresent

    func testRemoveFileIfPresentRemovesExistingFile() throws {
        let file = try touch("present.mov", in: tempDir)

        AudioFileManager.removeFileIfPresent(at: file)

        XCTAssertFalse(exists(file))
    }

    func testRemoveFileIfPresentToleratesMissingFile() {
        let missing = tempDir.appendingPathComponent("missing.mov")

        AudioFileManager.removeFileIfPresent(at: missing)

        XCTAssertFalse(exists(missing))
    }

    // MARK: - videoPath

    func testVideoPathHonorsInjectedDirectory() {
        XCTAssertEqual(
            AudioFileManager.videoPath(for: "x", in: tempDir),
            tempDir.appendingPathComponent("x.mov")
        )
        XCTAssertEqual(AudioFileManager.videoPath(for: "x"), AudioFileManager.audioDirectory.appendingPathComponent("x.mov"))
    }

    // MARK: - Helpers

    @discardableResult
    private func touch(_ name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data("x".utf8).write(to: url, options: .atomic)
        return url
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}

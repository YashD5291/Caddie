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

    // MARK: - cleanupOrphanedVideos

    func testSweepDeletesOnlyRowlessMovFiles() throws {
        let keepMov = try touch("keep.mov", in: tempDir)
        let orphanMov = try touch("orphan.mov", in: tempDir)
        let strayWav = try touch("stray.wav", in: tempDir)
        let strayM4a = try touch("stray.m4a", in: tempDir)

        AudioFileManager.cleanupOrphanedVideos(in: tempDir) { ["keep"] }

        XCTAssertFalse(exists(orphanMov), "A .mov with no meeting row and no audio must be deleted")
        XCTAssertTrue(exists(keepMov))
        XCTAssertTrue(exists(strayWav), "The sweep only touches .mov files")
        XCTAssertTrue(exists(strayM4a), "The sweep only touches .mov files")
    }

    /// CR-01: a lost or stale-restored database still has at least one row, but every
    /// meeting it forgot keeps its audio. A row-less `.mov` with sibling audio therefore
    /// means "stale database", not "orphan", and must survive the sweep.
    func testSweepKeepsRowlessMovThatStillHasAudio() throws {
        let knownMov = try touch("known.mov", in: tempDir)
        let restoredMov = try touch("restored.mov", in: tempDir)
        try touch("restored.m4a", in: tempDir)
        let recoveredMov = try touch("recovered.mov", in: tempDir)
        try touch("recovered.wav", in: tempDir)
        let orphanMov = try touch("orphan.mov", in: tempDir)

        AudioFileManager.cleanupOrphanedVideos(in: tempDir) { ["known"] }

        XCTAssertTrue(exists(restoredMov), "A row-less .mov whose .m4a still exists must be kept")
        XCTAssertTrue(exists(recoveredMov), "A row-less .mov whose .wav still exists must be kept")
        XCTAssertFalse(exists(orphanMov), "A row-less .mov with no audio is a real orphan")
        XCTAssertTrue(exists(knownMov))
    }

    func testSweepMatchesMovExtensionCaseInsensitively() throws {
        let keepMov = try touch("keep.mov", in: tempDir)
        let upperMov = try touch("ORPHAN2.MOV", in: tempDir)

        AudioFileManager.cleanupOrphanedVideos(in: tempDir) { ["keep"] }

        XCTAssertFalse(exists(upperMov))
        XCTAssertTrue(exists(keepMov))
    }

    func testSweepSkipsWhenMeetingIdReadFails() throws {
        let keepMov = try touch("keep.mov", in: tempDir)
        let orphanMov = try touch("orphan.mov", in: tempDir)

        AudioFileManager.cleanupOrphanedVideos(in: tempDir) { throw SweepTestError() }

        XCTAssertTrue(exists(keepMov), "A failed read must never be treated as 'no meetings'")
        XCTAssertTrue(exists(orphanMov), "A failed read must never be treated as 'no meetings'")
    }

    func testSweepSkipsWhenMeetingSetIsEmpty() throws {
        let firstMov = try touch("first.mov", in: tempDir)
        let secondMov = try touch("second.mov", in: tempDir)
        let wav = try touch("first.wav", in: tempDir)

        AudioFileManager.cleanupOrphanedVideos(in: tempDir) { [] }

        XCTAssertTrue(exists(firstMov), "An empty meetings table must never wipe every video")
        XCTAssertTrue(exists(secondMov), "An empty meetings table must never wipe every video")
        XCTAssertTrue(exists(wav))
    }

    func testSweepDoesNotReadDatabaseWhenNoVideosExist() throws {
        let wav = try touch("orphan.wav", in: tempDir)
        var called = false

        AudioFileManager.cleanupOrphanedVideos(in: tempDir) {
            called = true
            return ["keep"]
        }

        XCTAssertFalse(called, "With no .mov files the meeting ids must not be read")
        XCTAssertTrue(exists(wav))
    }

    func testSweepNeverDeletesFileCreatedAfterListing() throws {
        let keepMov = try touch("keep.mov", in: tempDir)
        var lateMov: URL?

        AudioFileManager.cleanupOrphanedVideos(in: tempDir) {
            lateMov = try touch("late.mov", in: tempDir)
            return ["keep"]
        }

        let late = try XCTUnwrap(lateMov, "The ID source must run when videos exist")
        XCTAssertTrue(exists(late), "Files must be listed before ids are read")
        XCTAssertTrue(exists(keepMov))
    }

    func testSweepIgnoresDirectories() throws {
        let keepMov = try touch("keep.mov", in: tempDir)
        let folder = tempDir.appendingPathComponent("folder.mov", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let inner = try touch("inner.txt", in: folder)

        AudioFileManager.cleanupOrphanedVideos(in: tempDir) { ["keep"] }

        XCTAssertTrue(exists(folder), "Only regular files are sweep candidates")
        XCTAssertTrue(exists(inner))
        XCTAssertTrue(exists(keepMov))
    }

    func testSweepToleratesMissingDirectory() {
        let missingDir = tempDir.appendingPathComponent("does-not-exist", isDirectory: true)
        var called = false

        AudioFileManager.cleanupOrphanedVideos(in: missingDir) {
            called = true
            return ["keep"]
        }

        XCTAssertFalse(called, "An unlistable directory must skip the sweep before reading ids")
    }

    // MARK: - AppDatabase.meetingIds

    func testMeetingIdsReturnsEveryRow() throws {
        let db = try AppDatabase(inMemory: true)
        XCTAssertEqual(try db.meetingIds(), [])

        var first = Meeting(meetingId: "meeting-a", title: "Standup", date: "2026-11-19", startTime: "2026-11-19T09:00:00Z")
        var second = Meeting(meetingId: "meeting-b", title: "Review", date: "2026-11-19", startTime: "2026-11-19T14:00:00Z")
        try db.dbWriter.write { dbConn in
            try first.insert(dbConn)
            try second.insert(dbConn)
        }

        XCTAssertEqual(try db.meetingIds(), ["meeting-a", "meeting-b"])
    }

    // MARK: - Helpers

    private struct SweepTestError: Error {}

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

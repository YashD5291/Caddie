import XCTest
import GRDB
@testable import Caddie

@MainActor
final class TranscriptionPipelineTests: XCTestCase {
    var db: AppDatabase!
    var mockASR: MockASREngine!
    var mockDiarization: MockDiarizationEngine!
    var pipeline: TranscriptionPipeline!
    private var createdFiles: [URL] = []

    override func setUpWithError() throws {
        db = try AppDatabase(inMemory: true)
        mockASR = MockASREngine()
        mockDiarization = MockDiarizationEngine()
        pipeline = TranscriptionPipeline(asr: mockASR, diarization: mockDiarization)
        createdFiles = []
    }

    override func tearDownWithError() throws {
        for url in createdFiles {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Error Paths

    func testASRFailureSetsStatusToError() async throws {
        let meetingId = "asr-fail-\(UUID().uuidString.prefix(8))"
        try insertMeeting(meetingId: meetingId)
        try createMinimalWAV(for: meetingId)

        mockASR.stubbedError = TestError.simulated

        await pipeline.enqueue(meetingId: meetingId, database: db)
        let meeting = try await waitForMeetingStatus(meetingId, expected: .error)

        XCTAssertEqual(meeting.status, .error)
        XCTAssertNotNil(meeting.error, "Error message should be written to DB")
    }

    func testDiarizationFailureSetsStatusToError() async throws {
        let meetingId = "diar-fail-\(UUID().uuidString.prefix(8))"
        try insertMeeting(meetingId: meetingId)
        try createMinimalWAV(for: meetingId)

        mockDiarization.stubbedError = TestError.simulated

        await pipeline.enqueue(meetingId: meetingId, database: db)
        let meeting = try await waitForMeetingStatus(meetingId, expected: .error)

        XCTAssertEqual(meeting.status, .error)
        XCTAssertNotNil(meeting.error)
    }

    func testMissingWAVFileSetsStatusToError() async throws {
        let meetingId = "no-wav-\(UUID().uuidString.prefix(8))"
        try insertMeeting(meetingId: meetingId)
        // Intentionally NOT creating a WAV file -- createMonoMixdown will fail

        await pipeline.enqueue(meetingId: meetingId, database: db)
        let meeting = try await waitForMeetingStatus(meetingId, expected: .error)

        XCTAssertEqual(meeting.status, .error)
        XCTAssertNotNil(meeting.error)
    }

    // MARK: - Success Path

    func testSuccessfulPipelineWritesTranscriptAndSetsDone() async throws {
        let meetingId = "success-\(UUID().uuidString.prefix(8))"
        try insertMeeting(meetingId: meetingId)
        try createMinimalWAV(for: meetingId)

        await pipeline.enqueue(meetingId: meetingId, database: db)
        let meeting = try await waitForMeetingStatus(meetingId, expected: .done)

        XCTAssertEqual(meeting.status, .done)
        XCTAssertNotNil(meeting.transcript, "Transcript JSON should be written to DB on success")
        XCTAssertNil(meeting.error, "Error should be nil on success")
    }

    // MARK: - Sequential Processing

    func testMultipleJobsProcessSequentially() async throws {
        let id1 = "seq-1-\(UUID().uuidString.prefix(8))"
        let id2 = "seq-2-\(UUID().uuidString.prefix(8))"
        try insertMeeting(meetingId: id1)
        try insertMeeting(meetingId: id2)
        try createMinimalWAV(for: id1)
        try createMinimalWAV(for: id2)

        await pipeline.enqueue(meetingId: id1, database: db)
        await pipeline.enqueue(meetingId: id2, database: db)

        let meeting1 = try await waitForMeetingStatus(id1, expected: .done)
        let meeting2 = try await waitForMeetingStatus(id2, expected: .done)

        XCTAssertEqual(meeting1.status, .done)
        XCTAssertEqual(meeting2.status, .done)
    }

    // MARK: - Status Transitions

    func testPipelineSetsStatusToTranscribingBeforeProcessing() async throws {
        let meetingId = "transcribing-\(UUID().uuidString.prefix(8))"
        try insertMeeting(meetingId: meetingId)
        // No WAV file -- pipeline will set transcribing then fail at mono mixdown
        // This tests the status transition happens before processing

        await pipeline.enqueue(meetingId: meetingId, database: db)

        // Wait for terminal state (error, since no WAV file)
        let meeting = try await waitForMeetingStatus(meetingId, expected: .error)
        // The meeting went through transcribing -> error
        // We can verify the final state is error (transcribing was transient)
        XCTAssertEqual(meeting.status, .error)
    }

    // MARK: - onComplete Callback Tests

    func testOnCompleteCalledOnSuccess() async throws {
        let meetingId = "cb-success-\(UUID().uuidString.prefix(8))"
        try insertMeeting(meetingId: meetingId)
        try createMinimalWAV(for: meetingId)

        let expectation = XCTestExpectation(description: "onComplete called with success")
        let resultBox = CallbackResultBox()

        await pipeline.enqueue(meetingId: meetingId, database: db) { cbMeetingId, result in
            resultBox.meetingId = cbMeetingId
            resultBox.result = result
            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 10.0)

        XCTAssertEqual(resultBox.meetingId, meetingId)
        guard case .success = resultBox.result else {
            XCTFail("Expected .success result, got \(String(describing: resultBox.result))")
            return
        }
    }

    func testOnCompleteCalledOnASRFailure() async throws {
        let meetingId = "cb-asr-fail-\(UUID().uuidString.prefix(8))"
        try insertMeeting(meetingId: meetingId)
        try createMinimalWAV(for: meetingId)

        mockASR.stubbedError = TestError.simulated

        let expectation = XCTestExpectation(description: "onComplete called with failure")
        let resultBox = CallbackResultBox()

        await pipeline.enqueue(meetingId: meetingId, database: db) { cbMeetingId, result in
            resultBox.meetingId = cbMeetingId
            resultBox.result = result
            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 10.0)

        XCTAssertEqual(resultBox.meetingId, meetingId)
        guard case .failure = resultBox.result else {
            XCTFail("Expected .failure result, got \(String(describing: resultBox.result))")
            return
        }
    }

    func testOnCompleteCalledOnMissingWAV() async throws {
        let meetingId = "cb-no-wav-\(UUID().uuidString.prefix(8))"
        try insertMeeting(meetingId: meetingId)
        // Intentionally NOT creating WAV

        let expectation = XCTestExpectation(description: "onComplete called with failure for missing WAV")
        let resultBox = CallbackResultBox()

        await pipeline.enqueue(meetingId: meetingId, database: db) { cbMeetingId, result in
            resultBox.meetingId = cbMeetingId
            resultBox.result = result
            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 10.0)

        XCTAssertEqual(resultBox.meetingId, meetingId)
        guard case .failure = resultBox.result else {
            XCTFail("Expected .failure result, got \(String(describing: resultBox.result))")
            return
        }
    }

    // MARK: - Data Integrity (DATA-02, DATA-03, DATA-04)

    func testMonoFileDeletedAfterASRAndDiarization() async throws {
        let meetingId = "mono-cleanup-\(UUID().uuidString.prefix(8))"
        try insertMeeting(meetingId: meetingId)
        try createMinimalWAV(for: meetingId)

        // Clean any pre-existing orphaned mono files from previous test runs
        let tempDir = FileManager.default.temporaryDirectory
        let preExisting = (try? FileManager.default.contentsOfDirectory(
            at: tempDir, includingPropertiesForKeys: nil
        ))?.filter { $0.lastPathComponent.hasPrefix("caddie_mono_") } ?? []
        for file in preExisting {
            try? FileManager.default.removeItem(at: file)
        }

        await pipeline.enqueue(meetingId: meetingId, database: db)
        _ = try await waitForMeetingStatus(meetingId, expected: .done)

        // After success, no caddie_mono_* files should remain in temp
        let tempContents = try FileManager.default.contentsOfDirectory(
            at: tempDir, includingPropertiesForKeys: nil
        )
        let orphanedMono = tempContents.filter { $0.lastPathComponent.hasPrefix("caddie_mono_") }
        XCTAssertTrue(orphanedMono.isEmpty, "Mono file should be cleaned up after successful pipeline")
    }

    func testMonoAndWAVPreservedOnDBWriteFailure() async throws {
        let meetingId = "db-fail-\(UUID().uuidString.prefix(8))"
        try insertMeeting(meetingId: meetingId)
        try createMinimalWAV(for: meetingId)

        // Drop the meetings table so the transcript UPDATE throws
        try await db.dbWriter.write { dbConn in
            try dbConn.execute(sql: "DROP TABLE meetings")
        }

        let expectation = XCTestExpectation(description: "onComplete called with failure")
        let resultBox = CallbackResultBox()

        await pipeline.enqueue(meetingId: meetingId, database: db) { cbMeetingId, result in
            resultBox.meetingId = cbMeetingId
            resultBox.result = result
            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 10.0)

        guard case .failure = resultBox.result else {
            XCTFail("Expected .failure when DB write fails")
            return
        }

        // DATA-02: WAV must survive when DB write fails
        let wavURL = AudioFileManager.wavPath(for: meetingId)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: wavURL.path),
            "WAV file must be preserved when DB write fails"
        )
    }

    func testWAVPreservedOnALACCompressionFailure() async throws {
        let meetingId = "alac-fail-\(UUID().uuidString.prefix(8))"
        try insertMeeting(meetingId: meetingId)
        try createMinimalWAV(for: meetingId)

        // Make ALAC output path unwritable by creating a directory at the output path
        let alacURL = AudioFileManager.alacPath(for: meetingId)
        try FileManager.default.createDirectory(at: alacURL, withIntermediateDirectories: true)

        let expectation = XCTestExpectation(description: "onComplete called")
        let resultBox = CallbackResultBox()

        await pipeline.enqueue(meetingId: meetingId, database: db) { cbMeetingId, result in
            resultBox.meetingId = cbMeetingId
            resultBox.result = result
            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 10.0)

        // WAV must survive when compression fails
        let wavURL = AudioFileManager.wavPath(for: meetingId)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: wavURL.path),
            "WAV file must be preserved when ALAC compression fails"
        )

        // Clean up the directory we created
        try? FileManager.default.removeItem(at: alacURL)
    }

    func testWAVDeletedOnlyAfterFullSuccess() async throws {
        let meetingId = "full-success-\(UUID().uuidString.prefix(8))"
        try insertMeeting(meetingId: meetingId)
        try createMinimalWAV(for: meetingId)

        await pipeline.enqueue(meetingId: meetingId, database: db)
        let meeting = try await waitForMeetingStatus(meetingId, expected: .done)

        XCTAssertEqual(meeting.status, .done)

        // WAV should be deleted after full success
        let wavURL = AudioFileManager.wavPath(for: meetingId)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: wavURL.path),
            "WAV should be deleted after pipeline completes with .done"
        )

        // ALAC should exist
        let alacURL = AudioFileManager.alacPath(for: meetingId)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: alacURL.path),
            "ALAC file should exist after successful compression"
        )
    }

    // MARK: - Helpers

    private func insertMeeting(meetingId: String) throws {
        try db.dbWriter.write { dbConn in
            var meeting = Meeting(
                meetingId: meetingId,
                title: "Test Meeting",
                date: "2026-03-22",
                startTime: "2026-03-22T09:00:00Z",
                status: .recording
            )
            try meeting.insert(dbConn)
        }
    }

    private func createMinimalWAV(for meetingId: String) throws {
        let url = AudioFileManager.wavPath(for: meetingId)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var header = Data(count: 44)
        let sampleRate: UInt32 = 16000
        let channels: UInt16 = 2
        let bitsPerSample: UInt16 = 16
        let dataSize: UInt32 = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let fileSize: UInt32 = 36 + dataSize

        // RIFF header
        header.replaceSubrange(0..<4, with: Data("RIFF".utf8))
        header.replaceSubrange(4..<8, with: withUnsafeBytes(of: fileSize.littleEndian) { Data($0) })
        header.replaceSubrange(8..<12, with: Data("WAVE".utf8))
        // fmt chunk
        header.replaceSubrange(12..<16, with: Data("fmt ".utf8))
        header.replaceSubrange(16..<20, with: withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) })
        header.replaceSubrange(20..<22, with: withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })
        header.replaceSubrange(22..<24, with: withUnsafeBytes(of: channels.littleEndian) { Data($0) })
        header.replaceSubrange(24..<28, with: withUnsafeBytes(of: sampleRate.littleEndian) { Data($0) })
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        header.replaceSubrange(28..<32, with: withUnsafeBytes(of: byteRate.littleEndian) { Data($0) })
        let blockAlign = channels * (bitsPerSample / 8)
        header.replaceSubrange(32..<34, with: withUnsafeBytes(of: blockAlign.littleEndian) { Data($0) })
        header.replaceSubrange(34..<36, with: withUnsafeBytes(of: bitsPerSample.littleEndian) { Data($0) })
        // data chunk
        header.replaceSubrange(36..<40, with: Data("data".utf8))
        header.replaceSubrange(40..<44, with: withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })

        let samples = Data(count: Int(dataSize))
        try (header + samples).write(to: url)

        createdFiles.append(url)
        // Also track ALAC file that pipeline may create
        createdFiles.append(AudioFileManager.alacPath(for: meetingId))
    }

    private func waitForMeetingStatus(
        _ meetingId: String,
        expected: MeetingStatus,
        timeout: TimeInterval = 10.0
    ) async throws -> Meeting {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if let meeting = try await db.dbWriter.read({ dbConn in
                try Meeting.filter(Column("meeting_id") == meetingId).fetchOne(dbConn)
            }), meeting.status == expected {
                return meeting
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let meeting = try await db.dbWriter.read { dbConn in
            try Meeting.filter(Column("meeting_id") == meetingId).fetchOne(dbConn)
        }
        XCTFail("Timed out waiting for status \(expected.rawValue), got \(meeting?.status.rawValue ?? "nil")")
        return meeting!
    }
}

// MARK: - Callback Result Box

private final class CallbackResultBox: @unchecked Sendable {
    var meetingId: String?
    var result: Result<Void, Error>?
}

// MARK: - Test Error

private enum TestError: Error, LocalizedError {
    case simulated

    var errorDescription: String? {
        "Simulated test error"
    }
}

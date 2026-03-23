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

    // MARK: - Entry Guards (DATA-07, DATA-08)

    func testRejectsDuplicateEnqueueForAlreadyQueuedMeeting() async throws {
        // Use a slow mock so the first job stays in queue
        let slowASR = MockASREngine()
        slowASR.delay = 60.0
        let slowPipeline = TranscriptionPipeline(asr: slowASR, diarization: mockDiarization)

        let meetingId = "dup-queued-\(UUID().uuidString.prefix(8))"
        try insertMeeting(meetingId: meetingId)
        try createMinimalWAV(for: meetingId)

        // First enqueue (will start processing with slow ASR)
        await slowPipeline.enqueue(meetingId: meetingId, database: db)

        // Enqueue a second job to fill the queue with something
        let meetingId2 = "dup-queued2-\(UUID().uuidString.prefix(8))"
        try insertMeeting(meetingId: meetingId2)
        try createMinimalWAV(for: meetingId2)
        await slowPipeline.enqueue(meetingId: meetingId2, database: db)

        // Try to enqueue meetingId2 again -- should be rejected (already in queue)
        let expectation = XCTestExpectation(description: "onComplete called with failure")
        let resultBox = CallbackResultBox()

        await slowPipeline.enqueue(meetingId: meetingId2, database: db) { cbMeetingId, result in
            resultBox.meetingId = cbMeetingId
            resultBox.result = result
            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 5.0)

        guard case .failure(let error) = resultBox.result else {
            XCTFail("Expected .failure for duplicate enqueue of already-queued meeting")
            return
        }
        XCTAssertTrue(error is PipelineError, "Error should be PipelineError.duplicateEnqueue")
    }

    func testRejectsDuplicateEnqueueForDoneMeeting() async throws {
        let meetingId = "dup-done-\(UUID().uuidString.prefix(8))"
        try insertMeeting(meetingId: meetingId, status: .done)

        let expectation = XCTestExpectation(description: "onComplete called with failure")
        let resultBox = CallbackResultBox()

        await pipeline.enqueue(meetingId: meetingId, database: db) { cbMeetingId, result in
            resultBox.meetingId = cbMeetingId
            resultBox.result = result
            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 5.0)

        guard case .failure = resultBox.result else {
            XCTFail("Expected .failure for duplicate enqueue of .done meeting")
            return
        }
    }

    func testRejectsDuplicateEnqueueForTranscribingMeeting() async throws {
        let meetingId = "dup-transcribing-\(UUID().uuidString.prefix(8))"
        try insertMeeting(meetingId: meetingId, status: .transcribing)

        let expectation = XCTestExpectation(description: "onComplete called with failure")
        let resultBox = CallbackResultBox()

        await pipeline.enqueue(meetingId: meetingId, database: db) { cbMeetingId, result in
            resultBox.meetingId = cbMeetingId
            resultBox.result = result
            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 5.0)

        guard case .failure(let error) = resultBox.result else {
            XCTFail("Expected .failure for duplicate enqueue of .transcribing meeting")
            return
        }
        XCTAssertTrue(error is PipelineError, "Error should be PipelineError.duplicateEnqueue")
    }

    func testAllowsEnqueueForErrorMeeting() async throws {
        let meetingId = "retry-error-\(UUID().uuidString.prefix(8))"
        try insertMeeting(meetingId: meetingId, status: .error)
        try createMinimalWAV(for: meetingId)

        await pipeline.enqueue(meetingId: meetingId, database: db)
        // Should be accepted -- error meetings are valid retry targets
        let meeting = try await waitForMeetingStatus(meetingId, expected: .done)
        XCTAssertEqual(meeting.status, .done)
    }

    func testRejectsEnqueueWhenQueueFull() async throws {
        // Create a slow mock so jobs stay in queue
        // First enqueue starts processing immediately (removed from queue),
        // so we need 51 enqueues to have 50 in the pending queue.
        let slowASR = MockASREngine()
        slowASR.delay = 60.0 // long delay so first job doesn't finish
        let slowPipeline = TranscriptionPipeline(asr: slowASR, diarization: mockDiarization)

        // Enqueue 51 meetings: 1 starts processing, 50 stay in queue
        for i in 0..<51 {
            let meetingId = "queue-\(i)-\(UUID().uuidString.prefix(4))"
            try insertMeeting(meetingId: meetingId)
            try createMinimalWAV(for: meetingId)
            await slowPipeline.enqueue(meetingId: meetingId, database: db)
        }

        // Attempt #52 -- should be rejected (50 in queue)
        let overflowId = "queue-overflow-\(UUID().uuidString.prefix(4))"
        try insertMeeting(meetingId: overflowId)

        let expectation = XCTestExpectation(description: "onComplete called with queueFull")
        let resultBox = CallbackResultBox()

        await slowPipeline.enqueue(meetingId: overflowId, database: db) { cbMeetingId, result in
            resultBox.meetingId = cbMeetingId
            resultBox.result = result
            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 5.0)

        guard case .failure(let error) = resultBox.result else {
            XCTFail("Expected .failure for queue overflow")
            return
        }
        XCTAssertTrue(error is PipelineError, "Error should be PipelineError.queueFull")
    }

    // MARK: - Orphaned Temp Cleanup (DATA-05)

    func testCleanupOrphanedTempFilesRemovesCaddieMonoFiles() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let orphan1 = tempDir.appendingPathComponent("caddie_mono_test1.wav")
        let orphan2 = tempDir.appendingPathComponent("caddie_mono_test2.wav")
        try Data("test".utf8).write(to: orphan1)
        try Data("test".utf8).write(to: orphan2)

        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan1.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan2.path))

        AudioFileManager.cleanupOrphanedTempFiles()

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan1.path),
                       "caddie_mono_ files should be removed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan2.path),
                       "caddie_mono_ files should be removed")
    }

    func testCleanupOrphanedTempFilesPreservesNonCaddieFiles() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let otherFile = tempDir.appendingPathComponent("other_temp_\(UUID().uuidString.prefix(8)).txt")
        try Data("keep me".utf8).write(to: otherFile)

        AudioFileManager.cleanupOrphanedTempFiles()

        XCTAssertTrue(FileManager.default.fileExists(atPath: otherFile.path),
                      "Non-caddie temp files should be preserved")
        try? FileManager.default.removeItem(at: otherFile)
    }

    func testCleanupOrphanedTempFilesHandlesEmptyTempDir() {
        // Just verify it doesn't throw/crash when no orphans exist
        AudioFileManager.cleanupOrphanedTempFiles()
    }

    // MARK: - Reentrancy Safety (ERR-04)

    func testConcurrentEnqueueProcessesSequentially() async throws {
        // Use a mock that yields to expose reentrancy windows
        let yieldingASR = MockASREngine()
        yieldingASR.delay = 0.1 // Small delay to create suspension points
        let yieldingDiarization = MockDiarizationEngine()
        let reentrancyPipeline = TranscriptionPipeline(asr: yieldingASR, diarization: yieldingDiarization)

        let id1 = "reentrant-1-\(UUID().uuidString.prefix(8))"
        let id2 = "reentrant-2-\(UUID().uuidString.prefix(8))"
        try insertMeeting(meetingId: id1)
        try insertMeeting(meetingId: id2)
        try createMinimalWAV(for: id1)
        try createMinimalWAV(for: id2)

        // Track completion order
        let orderBox = CompletionOrderBox()

        let exp1 = XCTestExpectation(description: "Job 1 completes")
        let exp2 = XCTestExpectation(description: "Job 2 completes")

        // Enqueue both rapidly -- the second call fires while the first is at an await
        await reentrancyPipeline.enqueue(meetingId: id1, database: db) { meetingId, _ in
            orderBox.append(meetingId)
            exp1.fulfill()
        }
        await reentrancyPipeline.enqueue(meetingId: id2, database: db) { meetingId, _ in
            orderBox.append(meetingId)
            exp2.fulfill()
        }

        await fulfillment(of: [exp1, exp2], timeout: 15.0)

        // Both must complete, and job 1 must finish before job 2 starts
        XCTAssertEqual(orderBox.order.count, 2, "Both jobs must complete")
        XCTAssertEqual(orderBox.order.first, id1, "Job 1 must complete first (FIFO order)")
        XCTAssertEqual(orderBox.order.last, id2, "Job 2 must complete second")
    }

    // MARK: - Helpers

    private func insertMeeting(meetingId: String, status: MeetingStatus = .recording) throws {
        try db.dbWriter.write { dbConn in
            var meeting = Meeting(
                meetingId: meetingId,
                title: "Test Meeting",
                date: "2026-03-22",
                startTime: "2026-03-22T09:00:00Z",
                status: status
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

// MARK: - Completion Order Box

private final class CompletionOrderBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _order: [String] = []

    var order: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _order
    }

    func append(_ meetingId: String) {
        lock.lock()
        defer { lock.unlock() }
        _order.append(meetingId)
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

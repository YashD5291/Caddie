import XCTest
import GRDB
@testable import Caddie

/// Verifies the coordinator persists each meeting's video link and timing anchor, and
/// verifies the file once the engine has finalized it (STOR-01, STOR-04 storage leg):
/// link on the first frame (D-05, D-08), keep a usable file, delete and unlink an
/// unusable one (D-07), never act before the finalize signal (D-13), and leave
/// audio-only meetings untouched (D-11).
///
/// The fixture (`CoordinatorTestCase`) injects a temp `videoDir` and mock engines, so no
/// test can read or delete the user's real media (D-15).
final class RecordingCoordinatorVideoStorageTests: CoordinatorTestCase {

    // MARK: - Helpers

    private func isLinked(_ id: String) async throws -> Bool {
        try await fetchMeeting(id)?.videoFile == "\(id).mov"
    }

    private func isUnlinked(_ id: String) async throws -> Bool {
        let meeting = try await fetchMeeting(id)
        return meeting?.videoFile == nil && meeting?.videoStartOffset == nil
    }

    private func videoURL(_ id: String) -> URL {
        AudioFileManager.videoPath(for: id, in: videoDir)
    }

    private func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - D-08: offset math

    /// The anchor is the first frame minus the audio start, in seconds, on any timebase.
    func testVideoStartOffsetIsFirstFrameMinusAudioStart() {
        let unit = mach_timebase_info_data_t(numer: 1, denom: 1)
        XCTAssertEqual(
            RecordingCoordinator.videoStartOffset(audioStartTicks: 1_000_000_000,
                                                  firstFrameTicks: 1_270_000_000,
                                                  timebase: unit),
            0.27, accuracy: 1e-9)

        let appleSilicon = mach_timebase_info_data_t(numer: 125, denom: 3)
        XCTAssertEqual(
            RecordingCoordinator.videoStartOffset(audioStartTicks: 0,
                                                  firstFrameTicks: 24_000_000,
                                                  timebase: appleSilicon),
            1.0, accuracy: 1e-9)
    }

    // MARK: - D-05: link early, verify after finalize

    /// The first frame links the row with its offset while the meeting is still recording.
    func testFirstFrameLinksVideoFileAndOffset() async throws {
        let coordinator = makeCoordinator()
        guard let id = await startMeeting(coordinator, title: "Link") else {
            XCTFail("Expected the meeting to be recording")
            return
        }

        let linked = try await waitUntil { try await self.isLinked(id) }
        XCTAssertTrue(linked, "The first frame must link video_file = <id>.mov")

        let meeting = try await fetchMeeting(id)
        XCTAssertEqual(meeting?.status, .recording, "The link lands before any stop")
        let offset = try XCTUnwrap(meeting?.videoStartOffset, "The anchor offset is written with the link")
        XCTAssertGreaterThanOrEqual(offset, 0, "The first frame cannot precede the audio start")
        XCTAssertEqual(inspector.inspectCallCount, 0, "Nothing is inspected before finalize")

        await coordinator.handle(.manualStop)
    }

    /// A usable finalized video is inspected once at the injected path and stays linked.
    func testUsableFinalizedVideoStaysLinked() async throws {
        factory.createsFileOnStart = true
        let coordinator = makeCoordinator()
        guard let id = await startMeeting(coordinator, title: "Usable") else {
            XCTFail("Expected the meeting to be recording")
            return
        }
        let linked = try await waitUntil { try await self.isLinked(id) }
        XCTAssertTrue(linked)

        await coordinator.handle(.manualStop)

        let inspected = await waitUntil { self.inspector.inspectCallCount == 1 }
        XCTAssertTrue(inspected, "Finalize must trigger exactly one inspection")
        await settle(.milliseconds(300))

        XCTAssertEqual(inspector.inspectCallCount, 1)
        XCTAssertEqual(inspector.inspectedURLs, [videoURL(id)],
                       "The inspector reads the meeting's file in the injected directory")
        let meeting = try await fetchMeeting(id)
        XCTAssertEqual(meeting?.videoFile, "\(id).mov", "A usable video stays linked")
        XCTAssertNotNil(meeting?.videoStartOffset, "A usable video keeps its anchor")
        XCTAssertTrue(fileExists(videoURL(id)), "A usable video is kept on disk")
    }

    /// D-07: a zero-duration video is deleted and both columns are cleared.
    func testZeroDurationVideoIsDeletedAndUnlinked() async throws {
        factory.createsFileOnStart = true
        inspector.defaultResult = .inspected(
            VideoInspection(isPlayable: true, durationSeconds: 0, videoTrackCount: 1))
        let coordinator = makeCoordinator()
        guard let id = await startMeeting(coordinator, title: "Zero Duration") else {
            XCTFail("Expected the meeting to be recording")
            return
        }
        let linked = try await waitUntil { try await self.isLinked(id) }
        XCTAssertTrue(linked)

        await coordinator.handle(.manualStop)

        let unlinked = try await waitUntil { try await self.isUnlinked(id) }
        XCTAssertTrue(unlinked, "A zero-duration video must leave both columns NULL")
        let deleted = await waitUntil { !self.fileExists(self.videoURL(id)) }
        XCTAssertTrue(deleted, "A zero-duration video must be deleted")
    }

    /// D-07: a file AVFoundation cannot open is deleted and both columns are cleared.
    func testUnreadableVideoIsDeletedAndUnlinked() async throws {
        factory.createsFileOnStart = true
        inspector.defaultResult = .unreadable("AVFoundationErrorDomain -11829: Cannot Open")
        let coordinator = makeCoordinator()
        guard let id = await startMeeting(coordinator, title: "Unreadable") else {
            XCTFail("Expected the meeting to be recording")
            return
        }
        let linked = try await waitUntil { try await self.isLinked(id) }
        XCTAssertTrue(linked)

        await coordinator.handle(.manualStop)

        let unlinked = try await waitUntil { try await self.isUnlinked(id) }
        XCTAssertTrue(unlinked, "An unreadable video must leave both columns NULL")
        let deleted = await waitUntil { !self.fileExists(self.videoURL(id)) }
        XCTAssertTrue(deleted, "An unreadable video must be deleted")
    }

    /// WR-01: a probe failure that says nothing about the content (I/O, permissions, media
    /// services) keeps the file, the link, and the anchor. Only a content verdict deletes.
    func testInconclusiveInspectionKeepsVideoAndLink() async throws {
        factory.createsFileOnStart = true
        inspector.defaultResult = .inconclusive("NSPOSIXErrorDomain 5: Input/output error")
        let coordinator = makeCoordinator()
        guard let id = await startMeeting(coordinator, title: "Inconclusive") else {
            XCTFail("Expected the meeting to be recording")
            return
        }
        let linked = try await waitUntil { try await self.isLinked(id) }
        XCTAssertTrue(linked)

        await coordinator.handle(.manualStop)

        let inspected = await waitUntil { self.inspector.inspectCallCount == 1 }
        XCTAssertTrue(inspected, "Finalize must trigger exactly one inspection")
        await settle(.milliseconds(300))

        let meeting = try await fetchMeeting(id)
        XCTAssertEqual(meeting?.videoFile, "\(id).mov", "An inconclusive probe must keep the link")
        XCTAssertNotNil(meeting?.videoStartOffset, "An inconclusive probe must keep the anchor")
        XCTAssertTrue(fileExists(videoURL(id)), "An inconclusive probe must keep the file")
    }

    /// IN-03: an unusable video is unlinked before it is deleted. If the unlink fails, the
    /// file is kept: a link to a missing file is worse than an unusable file on disk.
    func testFailedUnlinkKeepsUnusableVideoFile() async throws {
        factory.createsFileOnStart = true
        inspector.defaultResult = .unreadable("AVFoundationErrorDomain -11829: Cannot Open")
        try await db.dbWriter.write { dbConn in
            try dbConn.execute(sql: """
                CREATE TRIGGER test_block_video_unlink
                BEFORE UPDATE OF video_file ON meetings
                WHEN NEW.video_file IS NULL AND OLD.video_file IS NOT NULL
                BEGIN SELECT RAISE(ABORT, 'video unlink blocked by test'); END
                """)
        }
        let coordinator = makeCoordinator()
        guard let id = await startMeeting(coordinator, title: "Failed Unlink") else {
            XCTFail("Expected the meeting to be recording")
            return
        }
        let linked = try await waitUntil { try await self.isLinked(id) }
        XCTAssertTrue(linked)

        await coordinator.handle(.manualStop)

        let inspected = await waitUntil { self.inspector.inspectCallCount == 1 }
        XCTAssertTrue(inspected, "Finalize must trigger exactly one inspection")
        await settle(.milliseconds(300))

        let stillLinked = try await isLinked(id)
        XCTAssertTrue(stillLinked, "The blocked unlink leaves the row linked")
        XCTAssertTrue(fileExists(videoURL(id)), "A failed unlink must keep the file the row points at")
    }

    /// End-to-end D-07 with the production inspector: the 0-byte file a stop before the
    /// first written frame leaves behind is deleted and unlinked.
    func testRealInspectorDeletesZeroByteVideo() async throws {
        factory.createsFileOnStart = true
        let coordinator = makeCoordinator(inspector: AVAssetVideoInspector())
        guard let id = await startMeeting(coordinator, title: "Real Inspector") else {
            XCTFail("Expected the meeting to be recording")
            return
        }
        let linked = try await waitUntil { try await self.isLinked(id) }
        XCTAssertTrue(linked)
        XCTAssertTrue(fileExists(videoURL(id)), "The mock leaves a 0-byte file at the injected path")

        await coordinator.handle(.manualStop)

        let unlinked = try await waitUntil(timeout: .seconds(5)) { try await self.isUnlinked(id) }
        XCTAssertTrue(unlinked, "A 0-byte video must leave both columns NULL")
        let deleted = await waitUntil { !self.fileExists(self.videoURL(id)) }
        XCTAssertTrue(deleted, "A 0-byte video must be deleted")
    }

    /// D-13: `stop()` returning is not a finalize signal. With no finalize, nothing is
    /// inspected or deleted and the link stays.
    func testNothingInspectedBeforeFinalizeSignal() async throws {
        factory.neverFinalize = true
        factory.createsFileOnStart = true
        let coordinator = makeCoordinator()
        guard let id = await startMeeting(coordinator, title: "No Finalize") else {
            XCTFail("Expected the meeting to be recording")
            return
        }
        let linked = try await waitUntil { try await self.isLinked(id) }
        XCTAssertTrue(linked)

        await coordinator.handle(.manualStop)
        await settle(.milliseconds(300))

        XCTAssertEqual(factory.latest?.stopCallCount, 1, "The engine was stopped")
        XCTAssertEqual(inspector.inspectCallCount, 0, "Nothing may inspect before the finalize signal")
        let stillLinked = try await isLinked(id)
        XCTAssertTrue(stillLinked, "Nothing may unlink before the finalize signal")
        XCTAssertTrue(fileExists(videoURL(id)), "Nothing may delete before the finalize signal")
    }

    /// D-05: a failed start (e.g. TCC denied) leaves no link, no inspection, and no file.
    func testStartFailureLeavesNoLinkAndNoFile() async throws {
        factory.startError = MockScreenRecorderError(message: "TCC denied")
        factory.createsFileOnStart = true
        let coordinator = makeCoordinator()
        guard let id = await startMeeting(coordinator, title: "Start Failure") else {
            XCTFail("A video start failure must leave the meeting in .recording")
            return
        }

        let started = await waitUntil { self.factory.latest?.startCallCount == 1 }
        XCTAssertTrue(started, "The failing start must have run (it writes its file first)")
        let removed = await waitUntil { !self.fileExists(self.videoURL(id)) }
        XCTAssertTrue(removed, "A failed start must leave no file behind")

        let unlinked = try await isUnlinked(id)
        XCTAssertTrue(unlinked, "A failed start must leave both columns NULL")
        XCTAssertEqual(inspector.inspectCallCount, 0, "A failed start is never inspected")

        await coordinator.handle(.manualStop)
        await settle(.milliseconds(300))
        let stillUnlinked = try await isUnlinked(id)
        XCTAssertTrue(stillUnlinked)
        XCTAssertEqual(inspector.inspectCallCount, 0, "Teardown after a failed start inspects nothing")
    }

    /// D-11 / SC4: with screen recording off, a meeting gets no video storage at all.
    func testAudioOnlyMeetingHasNoVideoStorage() async throws {
        let collector = VideoErrorCollector()
        let coordinator = makeCoordinator(withVideo: false)
        await coordinator.setOnVideoError { collector.append($0) }
        guard let id = await startMeeting(coordinator, title: "Audio Only") else {
            XCTFail("Expected the meeting to be recording")
            return
        }

        await coordinator.handle(.manualStop)
        await settle(.milliseconds(300))

        let unlinked = try await isUnlinked(id)
        XCTAssertTrue(unlinked, "An audio-only meeting leaves both columns NULL")
        XCTAssertEqual(factory.makeCallCount, 0, "No engine is vended with the feature off")
        XCTAssertEqual(inspector.inspectCallCount, 0, "An audio-only meeting is never inspected")
        XCTAssertTrue(collector.messages.isEmpty,
                      "An audio-only meeting surfaces no video message, got: \(collector.messages)")
        let contents = try FileManager.default.contentsOfDirectory(atPath: videoDir.path)
        XCTAssertTrue(contents.isEmpty, "An audio-only meeting performs no video file operation")
    }

    /// Finalize never gates transcription: the meeting is enqueued before its video is
    /// even final, and the inspection happens once, later.
    func testFinalizeNeverDelaysTranscription() async throws {
        factory.finalizeDelay = .seconds(2)
        let coordinator = makeCoordinator()
        guard let id = await startMeeting(coordinator, title: "Slow Finalize") else {
            XCTFail("Expected the meeting to be recording")
            return
        }
        let linked = try await waitUntil { try await self.isLinked(id) }
        XCTAssertTrue(linked)

        await coordinator.handle(.manualStop)

        let state = await coordinator.state
        guard case .transcribing = state else {
            XCTFail("The meeting must be transcribing as soon as the stop returns, got \(state)")
            return
        }
        XCTAssertEqual(inspector.inspectCallCount, 0,
                       "The meeting must be enqueued before its video finalizes")

        let inspected = await waitUntil(timeout: .seconds(5)) { self.inspector.inspectCallCount == 1 }
        XCTAssertTrue(inspected, "The late finalize must still be inspected")
        await settle(.milliseconds(300))
        XCTAssertEqual(inspector.inspectCallCount, 1, "The late finalize is inspected exactly once")
    }

    // MARK: - D-06: every finalize path reconciles its own meeting

    /// A finalize that lands after the meeting is already transcribing still reconciles
    /// that meeting's row, and the row stays linked until it does.
    func testLateFinalizeAfterTranscribingStillReconcilesRow() async throws {
        factory.finalizeDelay = .milliseconds(800)
        let coordinator = makeCoordinator()
        guard let id = await startMeeting(coordinator, title: "Late Finalize") else {
            XCTFail("Expected the meeting to be recording")
            return
        }
        inspector.setResult(.unreadable("AVFoundationErrorDomain -11829: Cannot Open"), for: videoURL(id))
        let linked = try await waitUntil { try await self.isLinked(id) }
        XCTAssertTrue(linked)

        await coordinator.handle(.manualStop)

        let state = await coordinator.state
        guard case .transcribing = state else {
            XCTFail("The meeting must be transcribing before its video finalizes, got \(state)")
            return
        }
        let linkedWhilePending = try await isLinked(id)
        XCTAssertTrue(linkedWhilePending, "The row stays linked until the finalize lands")

        let unlinked = try await waitUntil { try await self.isUnlinked(id) }
        XCTAssertTrue(unlinked, "The late finalize must still reconcile the meeting's row")
        XCTAssertEqual(inspector.inspectCallCount, 1)
    }

    /// The finalize of meeting #1 lands after meeting #2 started. It must reconcile
    /// meeting #1's row only, and meeting #2 keeps its own link through its own finalize.
    ///
    /// Meeting #1's finalize is fired by hand once meeting #2 is linked, not by a timer,
    /// so a slow host cannot reorder the two meetings.
    func testLateFinalizeAcrossSecondMeetingTargetsOwnRow() async throws {
        factory.neverFinalize = true
        let coordinator = makeCoordinator()

        guard let first = await startMeeting(coordinator, title: "Meeting One") else {
            XCTFail("Expected the first meeting to be recording")
            return
        }
        inspector.setResult(.unreadable("AVFoundationErrorDomain -11829: Cannot Open"), for: videoURL(first))
        let firstLinked = try await waitUntil { try await self.isLinked(first) }
        XCTAssertTrue(firstLinked)

        await coordinator.handle(.manualStop)
        await coordinator.handle(.transcriptionComplete(meetingId: first))

        factory.neverFinalize = false
        guard let second = await startMeeting(coordinator, title: "Meeting Two") else {
            XCTFail("Expected the second meeting to be recording")
            return
        }
        XCTAssertNotEqual(first, second)
        let secondLinked = try await waitUntil { try await self.isLinked(second) }
        XCTAssertTrue(secondLinked, "Meeting #2 links its own video")
        XCTAssertEqual(inspector.inspectCallCount, 0,
                       "Meeting #1's finalize has not been fired yet")

        let firstEngine = try XCTUnwrap(factory.instances.first)
        firstEngine.simulateFinalize()

        let firstUnlinked = try await waitUntil { try await self.isUnlinked(first) }
        XCTAssertTrue(firstUnlinked, "Meeting #1's late finalize must reconcile meeting #1's row")
        let secondStillLinked = try await isLinked(second)
        XCTAssertTrue(secondStillLinked, "Meeting #1's late finalize must not touch meeting #2's row")

        await coordinator.handle(.manualStop)
        let secondInspected = await waitUntil { self.inspector.inspectCallCount == 2 }
        XCTAssertTrue(secondInspected, "Meeting #2's finalize must be inspected too")
        await settle(.milliseconds(300))

        let secondFinal = try await isLinked(second)
        XCTAssertTrue(secondFinal, "Meeting #2's usable video stays linked")
        XCTAssertEqual(inspector.inspectedURLs, [videoURL(first), videoURL(second)],
                       "Each finalize inspects its own meeting's file, in order")
    }

    /// D-06: a stream death finalizes mid-meeting. The usable partial is verified while
    /// still recording and stays linked; teardown does not inspect it a second time.
    func testStreamDeathFinalizeReconcilesWhileRecording() async throws {
        let coordinator = makeCoordinator()
        guard let id = await startMeeting(coordinator, title: "Stream Death") else {
            XCTFail("Expected the meeting to be recording")
            return
        }
        let linked = try await waitUntil { try await self.isLinked(id) }
        XCTAssertTrue(linked)

        let engine = try XCTUnwrap(factory.latest)
        engine.simulateStreamDeath(MockScreenRecorderError(message: "-3821"))
        engine.simulateFinalize()

        let inspected = await waitUntil { self.inspector.inspectCallCount == 1 }
        XCTAssertTrue(inspected, "The mid-meeting finalize must be inspected")
        let stillRecording = await recordingMeetingId(coordinator)
        XCTAssertEqual(stillRecording, id, "A stream death leaves the audio recording running")
        await settle(.milliseconds(300))
        let partialLinked = try await isLinked(id)
        XCTAssertTrue(partialLinked, "A usable partial stays linked (D-06)")

        await coordinator.handle(.manualStop)
        await settle(.milliseconds(300))

        XCTAssertEqual(inspector.inspectCallCount, 1, "Teardown must not trigger a second inspection")
        XCTAssertEqual(engine.stopCallCount, 1, "Teardown still stops the dead stream's engine")
        let finalLinked = try await isLinked(id)
        XCTAssertTrue(finalLinked)
    }

    /// D-06: a quit (or crash) before finalize keeps the first-frame link and its anchor,
    /// and nothing inspects or deletes the partial file.
    func testNeverFinalizedVideoStaysLinked() async throws {
        factory.neverFinalize = true
        factory.createsFileOnStart = true
        let coordinator = makeCoordinator()
        guard let id = await startMeeting(coordinator, title: "Quit Mid-Meeting") else {
            XCTFail("Expected the meeting to be recording")
            return
        }
        let linked = try await waitUntil { try await self.isLinked(id) }
        XCTAssertTrue(linked)

        await coordinator.stop()
        await settle(.milliseconds(300))

        let meeting = try await fetchMeeting(id)
        XCTAssertEqual(meeting?.videoFile, "\(id).mov", "A never-finalized partial stays linked")
        XCTAssertNotNil(meeting?.videoStartOffset, "A never-finalized partial keeps its anchor")
        XCTAssertEqual(inspector.inspectCallCount, 0, "Nothing is inspected without a finalize")
        XCTAssertTrue(fileExists(videoURL(id)), "A never-finalized partial is kept on disk")
    }

    /// A finalized file that is gone from disk leaves both columns NULL.
    func testMissingFinalizedVideoUnlinksRow() async throws {
        inspector.defaultResult = .missing
        let coordinator = makeCoordinator()
        guard let id = await startMeeting(coordinator, title: "Missing Video") else {
            XCTFail("Expected the meeting to be recording")
            return
        }
        let linked = try await waitUntil { try await self.isLinked(id) }
        XCTAssertTrue(linked)

        await coordinator.handle(.manualStop)

        let unlinked = try await waitUntil { try await self.isUnlinked(id) }
        XCTAssertTrue(unlinked, "A missing finalized video must leave both columns NULL")
        XCTAssertEqual(inspector.inspectCallCount, 1)
        XCTAssertFalse(fileExists(videoURL(id)))
    }

    /// A wedged engine stop still lets the meeting reach transcription promptly, and the
    /// row stays linked while the finalize is pending (no premature unlink).
    func testWedgedStopKeepsLinkUntilFinalize() async throws {
        factory.stopDelay = .seconds(30)
        // The abandoned 30 s stop outlives this test; it must not fire a finalize into a later one.
        factory.neverFinalize = true
        let coordinator = makeCoordinator()
        guard let id = await startMeeting(coordinator, title: "Wedged Stop") else {
            XCTFail("Expected the meeting to be recording")
            return
        }
        let linked = try await waitUntil { try await self.isLinked(id) }
        XCTAssertTrue(linked)

        let clock = ContinuousClock()
        let began = clock.now
        let stopTask = Task { await coordinator.handle(.manualStop) }

        await settle(.milliseconds(200))
        let midState = await coordinator.state
        guard case .transcribing = midState else {
            XCTFail("The meeting must reach .transcribing immediately, got \(midState)")
            return
        }

        await stopTask.value
        XCTAssertLessThan(clock.now - began, .seconds(15),
                          "The bounded stop must give up long before the 30 s wedge clears")

        let stillLinked = try await isLinked(id)
        XCTAssertTrue(stillLinked, "The row stays linked while the finalize is pending")
        XCTAssertEqual(inspector.inspectCallCount, 0, "Nothing is inspected before the finalize lands")
    }

    /// Pitfall 9: deleting a meeting while it records must not crash the funnel. The
    /// writes hit zero rows, and the unusable file is still removed.
    func testMeetingDeletedMidRecordingDoesNotCrash() async throws {
        factory.createsFileOnStart = true
        let coordinator = makeCoordinator()
        guard let id = await startMeeting(coordinator, title: "Deleted Mid-Recording") else {
            XCTFail("Expected the meeting to be recording")
            return
        }
        inspector.setResult(.unreadable("AVFoundationErrorDomain -11829: Cannot Open"), for: videoURL(id))
        let linked = try await waitUntil { try await self.isLinked(id) }
        XCTAssertTrue(linked)

        let deletedRows = try await db.dbWriter.write { dbConn in
            try Meeting.filter(Column("meeting_id") == id).deleteAll(dbConn)
        }
        XCTAssertEqual(deletedRows, 1)

        await coordinator.handle(.manualStop)

        let inspected = await waitUntil { self.inspector.inspectCallCount == 1 }
        XCTAssertTrue(inspected, "The finalize of a deleted meeting is still inspected")
        let removed = await waitUntil { !self.fileExists(self.videoURL(id)) }
        XCTAssertTrue(removed, "The unusable file of a deleted meeting is still removed")
        let meeting = try await fetchMeeting(id)
        XCTAssertNil(meeting, "No write may recreate the deleted row")
    }

    /// WR-02: Delete works at every status and finalize lands after stop, so a meeting can
    /// be deleted before its video finalizes. Its usable video must not stay on disk.
    func testUsableVideoOfDeletedMeetingIsRemovedOnFinalize() async throws {
        factory.createsFileOnStart = true
        let coordinator = makeCoordinator()
        guard let id = await startMeeting(coordinator, title: "Deleted Before Finalize") else {
            XCTFail("Expected the meeting to be recording")
            return
        }
        let linked = try await waitUntil { try await self.isLinked(id) }
        XCTAssertTrue(linked)

        let deletedRows = try await db.dbWriter.write { dbConn in
            try Meeting.filter(Column("meeting_id") == id).deleteAll(dbConn)
        }
        XCTAssertEqual(deletedRows, 1)

        await coordinator.handle(.manualStop)

        let removed = await waitUntil { !self.fileExists(self.videoURL(id)) }
        XCTAssertTrue(removed, "A deleted meeting's usable video must not stay on disk")
        let meeting = try await fetchMeeting(id)
        XCTAssertNil(meeting, "No write may recreate the deleted row")
    }
}

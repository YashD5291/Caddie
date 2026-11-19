import XCTest
import GRDB
@testable import Caddie

final class MeetingModelTests: XCTestCase {
    var db: AppDatabase!

    override func setUpWithError() throws {
        db = try AppDatabase(inMemory: true)
    }

    // MARK: - Create & Fetch

    func testCreateAndFetchMeeting() throws {
        var meeting = Meeting(
            title: "Standup",
            date: "2026-03-19",
            startTime: "2026-03-19T09:00:00Z"
        )

        try db.dbWriter.write { dbConn in
            try meeting.insert(dbConn)
        }

        XCTAssertNotNil(meeting.id, "Meeting should have an id after insert")

        let fetched = try db.dbWriter.read { dbConn in
            try Meeting.fetchOne(dbConn, key: meeting.id)
        }

        XCTAssertEqual(fetched?.title, "Standup")
        XCTAssertEqual(fetched?.status, .recording)
        XCTAssertEqual(fetched?.meetingId, meeting.meetingId)
    }

    // MARK: - Status Update

    func testStatusUpdate() throws {
        var meeting = Meeting(
            title: "Sprint Review",
            date: "2026-03-19",
            startTime: "2026-03-19T14:00:00Z"
        )

        try db.dbWriter.write { dbConn in
            try meeting.insert(dbConn)
            meeting.status = .done
            meeting.durationSeconds = 1800
            try meeting.update(dbConn)
        }

        let fetched = try db.dbWriter.read { dbConn in
            try Meeting.fetchOne(dbConn, key: meeting.id)
        }

        XCTAssertEqual(fetched?.status, .done)
        XCTAssertEqual(fetched?.durationSeconds, 1800)
    }

    // MARK: - Ordering

    func testListOrderedByDate() throws {
        try db.dbWriter.write { dbConn in
            var older = Meeting(
                title: "Old Meeting",
                date: "2026-03-17",
                startTime: "2026-03-17T10:00:00Z"
            )
            try older.insert(dbConn)

            var newer = Meeting(
                title: "New Meeting",
                date: "2026-03-19",
                startTime: "2026-03-19T10:00:00Z"
            )
            try newer.insert(dbConn)

            var sameDay = Meeting(
                title: "Later Same Day",
                date: "2026-03-19",
                startTime: "2026-03-19T15:00:00Z"
            )
            try sameDay.insert(dbConn)
        }

        let meetings = try db.dbWriter.read { dbConn in
            try Meeting.orderedByDate().fetchAll(dbConn)
        }

        XCTAssertEqual(meetings.count, 3)
        XCTAssertEqual(meetings[0].title, "Later Same Day")
        XCTAssertEqual(meetings[1].title, "New Meeting")
        XCTAssertEqual(meetings[2].title, "Old Meeting")
    }

    // MARK: - FTS5 Search

    func testFTS5Search() throws {
        try db.dbWriter.write { dbConn in
            var m1 = Meeting(
                title: "Kubernetes Planning",
                date: "2026-03-19",
                startTime: "2026-03-19T09:00:00Z"
            )
            try m1.insert(dbConn)

            var m2 = Meeting(
                title: "Design Review",
                date: "2026-03-19",
                startTime: "2026-03-19T11:00:00Z"
            )
            m2.transcript = "We discussed the kubernetes deployment pipeline"
            try m2.insert(dbConn)

            var m3 = Meeting(
                title: "Budget Discussion",
                date: "2026-03-19",
                startTime: "2026-03-19T14:00:00Z"
            )
            try m3.insert(dbConn)
        }

        let results = try db.dbWriter.read { dbConn in
            try Meeting.search("kubernetes").fetchAll(dbConn)
        }

        XCTAssertEqual(results.count, 2)
        let titles = Set(results.map(\.title))
        XCTAssertTrue(titles.contains("Kubernetes Planning"))
        XCTAssertTrue(titles.contains("Design Review"))
    }

    // MARK: - Video Fields (STOR-01 / STOR-04)

    func testVideoFieldsDefaultToNil() throws {
        var meeting = Meeting(
            title: "Audio Only",
            date: "2026-03-19",
            startTime: "2026-03-19T09:00:00Z"
        )
        XCTAssertNil(meeting.videoFile)
        XCTAssertNil(meeting.videoStartOffset)

        try db.dbWriter.write { dbConn in
            try meeting.insert(dbConn)
        }

        let fetched = try db.dbWriter.read { dbConn in
            try Meeting.fetchOne(dbConn, key: meeting.id)
        }
        XCTAssertNotNil(fetched)
        XCTAssertNil(fetched?.videoFile)
        XCTAssertNil(fetched?.videoStartOffset)
    }

    func testVideoFieldsRoundTrip() throws {
        var meeting = Meeting(
            title: "Screen Share",
            date: "2026-03-19",
            startTime: "2026-03-19T10:00:00Z",
            videoFile: "abc.mov",
            videoStartOffset: 0.273
        )

        try db.dbWriter.write { dbConn in
            try meeting.insert(dbConn)
        }

        let fetched = try db.dbWriter.read { dbConn in
            try Meeting.fetchOne(dbConn, key: meeting.id)
        }
        XCTAssertEqual(fetched?.videoFile, "abc.mov")
        let offset = try XCTUnwrap(fetched?.videoStartOffset)
        XCTAssertEqual(offset, 0.273, accuracy: 1e-9)
    }

    func testSearchDecodesVideoFields() throws {
        try db.dbWriter.write { dbConn in
            var meeting = Meeting(
                title: "Design Sync",
                date: "2026-03-19",
                startTime: "2026-03-19T11:00:00Z",
                videoFile: "s.mov",
                videoStartOffset: 1.5
            )
            try meeting.insert(dbConn)
        }

        let results = try db.dbWriter.read { dbConn in
            try Meeting.search("Design").fetchAll(dbConn)
        }
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.videoFile, "s.mov")
        XCTAssertEqual(results.first?.videoStartOffset, 1.5)
    }

    // MARK: - MeetingStatus Enum

    func testMeetingStatusRawValues() {
        XCTAssertEqual(MeetingStatus.recording.rawValue, "recording")
        XCTAssertEqual(MeetingStatus.transcribing.rawValue, "transcribing")
        XCTAssertEqual(MeetingStatus.done.rawValue, "done")
        XCTAssertEqual(MeetingStatus.error.rawValue, "error")
    }
}

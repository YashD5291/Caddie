import XCTest
@testable import Caddie

final class FormattersTests: XCTestCase {
    // MARK: - duration(seconds:)

    func testDurationMinutesOnly() {
        XCTAssertEqual(Formatters.duration(seconds: 0), "0m")
        XCTAssertEqual(Formatters.duration(seconds: 59), "0m")
        XCTAssertEqual(Formatters.duration(seconds: 60), "1m")
        XCTAssertEqual(Formatters.duration(seconds: 2700), "45m")
    }

    func testDurationHoursAndMinutes() {
        XCTAssertEqual(Formatters.duration(seconds: 3600), "1h")
        XCTAssertEqual(Formatters.duration(seconds: 5400), "1h 30m")
        XCTAssertEqual(Formatters.duration(seconds: 7200), "2h")
        XCTAssertEqual(Formatters.duration(seconds: 7260), "2h 1m")
    }

    // MARK: - time(from:)

    func testTimeFromISO8601() {
        // We can't assert exact output since it depends on locale/timezone,
        // but we can verify it parses and returns a non-nil string.
        let result = Formatters.time(from: "2026-03-19T14:45:00Z")
        XCTAssertNotNil(result)
    }

    func testTimeFromInvalidString() {
        let result = Formatters.time(from: "not-a-date")
        XCTAssertNil(result)
    }

    // MARK: - dateLabel(from:)

    func testDateLabelToday() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let todayString = formatter.string(from: Date())
        XCTAssertEqual(Formatters.dateLabel(from: todayString), "Today")
    }

    func testDateLabelYesterday() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let yesterdayString = formatter.string(from: yesterday)
        XCTAssertEqual(Formatters.dateLabel(from: yesterdayString), "Yesterday")
    }

    func testDateLabelOlderDate() {
        // A date far enough in the past to not be today or yesterday
        let label = Formatters.dateLabel(from: "2026-01-15")
        XCTAssertTrue(label.contains("Jan"), "Expected month abbreviation, got: \(label)")
        XCTAssertTrue(label.contains("15"), "Expected day number, got: \(label)")
    }

    func testDateLabelInvalidInput() {
        XCTAssertEqual(Formatters.dateLabel(from: "garbage"), "garbage")
    }

    // MARK: - timestamp(seconds:)

    func testTimestamp() {
        XCTAssertEqual(Formatters.timestamp(seconds: 0), "0:00")
        XCTAssertEqual(Formatters.timestamp(seconds: 5), "0:05")
        XCTAssertEqual(Formatters.timestamp(seconds: 65), "1:05")
        XCTAssertEqual(Formatters.timestamp(seconds: 165.7), "2:45")
    }

    // MARK: - srtTimestamp(seconds:)

    func testSrtTimestamp() {
        XCTAssertEqual(Formatters.srtTimestamp(seconds: 0), "00:00:00,000")
        XCTAssertEqual(Formatters.srtTimestamp(seconds: 165.5), "00:02:45,500")
        XCTAssertEqual(Formatters.srtTimestamp(seconds: 3661.25), "01:01:01,250")
    }
}

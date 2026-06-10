import Foundation

enum Formatters {

    // MARK: - Cached Formatters

    // These formatters are configured once and only ever read afterwards. Apple
    // documents `ISO8601DateFormatter`/`DateFormatter` string<->date conversion as
    // thread-safe, so sharing immutable instances is sound; `nonisolated(unsafe)`
    // tells Swift 6's strict-concurrency checker we've reasoned about the access.

    /// Shared ISO8601 parser (with fractional seconds). Avoids the per-access
    /// allocation previously scattered across event models and views.
    private nonisolated(unsafe) static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Fallback parser for ISO8601 strings without fractional seconds.
    private nonisolated(unsafe) static let iso8601NoFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Localized short time formatter (e.g. "2:45 PM").
    private nonisolated(unsafe) static let shortTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    /// Hour:minute time formatter (e.g. "9:30 AM") used for calendar time ranges.
    private nonisolated(unsafe) static let hourMinute: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()

    /// Parses an ISO8601 datetime string into a `Date`, tolerating both
    /// fractional-second and whole-second representations.
    static func parseISO8601(_ string: String) -> Date? {
        iso8601.date(from: string) ?? iso8601NoFraction.date(from: string)
    }

    /// Formats a start/end pair into a localized range like "9:30 AM – 10:00 AM".
    static func timeRange(_ start: Date, _ end: Date) -> String {
        "\(hourMinute.string(from: start)) \u{2013} \(hourMinute.string(from: end))"
    }

    // MARK: - Durations

    /// Formats a duration in seconds into a human-readable string.
    /// Examples: "45m", "1h 30m", "0m"
    static func duration(seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        return "\(minutes)m"
    }

    /// Formats an ISO8601 datetime string into a localized time string.
    /// Example: "2:45 PM"
    static func time(from iso8601String: String) -> String? {
        guard let parsed = parseISO8601(iso8601String) else { return nil }
        return shortTime.string(from: parsed)
    }

    /// Returns "Today", "Yesterday", or a formatted date like "Mon, Mar 17".
    /// Input is an ISO8601 date string: "2026-03-19"
    static func dateLabel(from dateString: String) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")

        guard let date = dateFormatter.date(from: dateString) else {
            return dateString
        }

        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            let displayFormatter = DateFormatter()
            displayFormatter.dateFormat = "EEE, MMM d"
            return displayFormatter.string(from: date)
        }
    }

    /// Formats seconds into a timestamp like "2:45" (minutes:seconds).
    static func timestamp(seconds: Double) -> String {
        let totalSeconds = Int(seconds)
        let m = totalSeconds / 60
        let s = totalSeconds % 60
        return String(format: "%d:%02d", m, s)
    }

    /// Formats seconds into an SRT timestamp like "00:02:45,500".
    static func srtTimestamp(seconds: Double) -> String {
        let totalMs = Int(seconds * 1000)
        let h = totalMs / 3_600_000
        let m = (totalMs % 3_600_000) / 60_000
        let s = (totalMs % 60_000) / 1_000
        let ms = totalMs % 1_000
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }
}

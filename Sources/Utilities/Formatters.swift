import Foundation

enum Formatters {
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
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var date = isoFormatter.date(from: iso8601String)
        if date == nil {
            isoFormatter.formatOptions = [.withInternetDateTime]
            date = isoFormatter.date(from: iso8601String)
        }

        guard let parsed = date else { return nil }

        let timeFormatter = DateFormatter()
        timeFormatter.dateStyle = .none
        timeFormatter.timeStyle = .short
        return timeFormatter.string(from: parsed)
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

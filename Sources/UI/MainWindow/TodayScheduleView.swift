import SwiftUI

struct TodayScheduleView: View {
    let events: [GoogleCalendarEvent]

    var body: some View {
        if events.isEmpty {
            emptyState
        } else {
            ForEach(events) { event in
                CalendarEventRow(event: event)
            }
        }
    }

    private var emptyState: some View {
        Text("No events today")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
    }
}

struct CalendarEventRow: View {
    let event: GoogleCalendarEvent

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(accentColor)
                .frame(width: 3, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.summary)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(timeRangeText)
                    if event.attendeeCount > 0 {
                        Text("·")
                        Text("\(event.attendeeCount) attendees")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            Spacer()

            Text(statusText)
                .font(.system(size: 10))
                .foregroundStyle(statusColor)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .opacity(event.isPast ? 0.5 : 1.0)
        .background(event.isNow ? Color.green.opacity(0.08) : Color.clear)
        .cornerRadius(6)
    }

    private var accentColor: Color {
        if event.isPast { return Color.gray }
        if event.isNow { return Color.green }
        return Color.blue
    }

    private var statusText: String {
        if event.isPast { return "Done" }
        if event.isNow { return "Now" }
        if let interval = event.timeUntilStart {
            if interval < 3600 {
                return "in \(Int(interval / 60))m"
            }
            return "in \(Int(interval / 3600))h"
        }
        return ""
    }

    private var statusColor: Color {
        if event.isNow { return .green }
        return .secondary
    }

    private var timeRangeText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        guard let start = event.startDate, let end = event.endDate else { return "" }
        return "\(formatter.string(from: start)) – \(formatter.string(from: end))"
    }
}

import SwiftUI

struct TodayScheduleView: View {
    let events: [GoogleCalendarEvent]
    @State private var showAll = false

    private static let initialLimit = 5

    private var visibleEvents: [GoogleCalendarEvent] {
        showAll ? events : Array(events.prefix(Self.initialLimit))
    }

    private var hiddenCount: Int {
        max(0, events.count - Self.initialLimit)
    }

    var body: some View {
        if events.isEmpty {
            emptyState
        } else {
            ForEach(visibleEvents) { event in
                CalendarEventRow(event: event)
            }
            if hiddenCount > 0 {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showAll.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                            .rotationEffect(.degrees(showAll ? 180 : 0))
                        Text(showAll ? "Show less" : "Show \(hiddenCount) more")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var emptyState: some View {
        Text("No upcoming events")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
    }
}

struct CalendarEventRow: View {
    let event: GoogleCalendarEvent
    @Environment(AppState.self) private var appState

    var body: some View {
        // `event.isNow` / `event.isPast` depend on Date(); without a TimelineView
        // they only refresh when something else mutates observable state (the calendar
        // service polls every 5 min). Force a re-render at every minute boundary so the
        // green "Now" state and Record button appear right when the event starts.
        TimelineView(.everyMinute) { _ in
            rowContent
        }
    }

    @ViewBuilder
    private var rowContent: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(accentColor)
                .frame(width: 3, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.displayName)
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

            if event.isNow {
                recordButton
            } else {
                Text(statusText)
                    .font(.system(size: 10))
                    .foregroundStyle(statusColor)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .opacity(event.isPast ? 0.5 : 1.0)
        .background(event.isNow ? Color.green.opacity(0.08) : Color.clear)
        .cornerRadius(6)
    }

    @ViewBuilder
    private var recordButton: some View {
        switch appState.status {
        case .idle:
            Button {
                appState.startManualRecording(title: event.displayName)
            } label: {
                Label("Record", systemImage: "record.circle")
                    .font(.system(size: 10, weight: .semibold))
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.small)
            .help("Start recording this meeting")
            .disabled(appState.coordinator == nil)
        case .recording:
            Button {
                appState.stopManualRecording()
            } label: {
                Label("Stop", systemImage: "stop.circle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.small)
            .help("Stop recording")
        case .transcribing:
            ProgressView().controlSize(.mini)
        }
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

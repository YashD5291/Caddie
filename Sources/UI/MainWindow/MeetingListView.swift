import SwiftUI

struct MeetingListView: View {
    let meetings: [Meeting]
    @Binding var selectedMeetingId: Int64?
    @Binding var searchText: String

    var body: some View {
        List(selection: $selectedMeetingId) {
            if groupedMeetings.isEmpty {
                ContentUnavailableView(
                    "No meetings yet",
                    systemImage: "mic.badge.plus",
                    description: Text("Meetings will appear here once Caddie detects and records them.")
                )
            } else {
                ForEach(groupedMeetings, id: \.date) { group in
                    Section(header: Text(Formatters.dateLabel(from: group.date))) {
                        ForEach(group.meetings) { meeting in
                            MeetingRow(meeting: meeting)
                                .tag(meeting.id)
                        }
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search meetings")
        .navigationTitle("Caddie")
    }

    private struct DateGroup {
        let date: String
        let meetings: [Meeting]
    }

    private var filteredMeetings: [Meeting] {
        if searchText.isEmpty {
            return meetings
        }
        let query = searchText.lowercased()
        return meetings.filter {
            $0.title.lowercased().contains(query) ||
            ($0.app?.lowercased().contains(query) ?? false)
        }
    }

    private var groupedMeetings: [DateGroup] {
        let grouped = Dictionary(grouping: filteredMeetings) { $0.date }
        return grouped.keys.sorted(by: >).map { date in
            DateGroup(date: date, meetings: grouped[date]!.sorted { $0.startTime > $1.startTime })
        }
    }
}

// MARK: - MeetingRow

private struct MeetingRow: View {
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(meeting.title)
                .font(.body.bold())
                .lineLimit(1)

            HStack(spacing: 6) {
                StatusDot(status: meeting.status)

                if let app = meeting.app {
                    Text(app)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let duration = meeting.durationSeconds {
                    Text(Formatters.duration(seconds: duration))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let time = Formatters.time(from: meeting.startTime) {
                    Text(time)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

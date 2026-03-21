import SwiftUI

struct MeetingListView: View {
    let meetings: [Meeting]
    @Binding var selectedMeetingId: Int64?
    @Binding var searchText: String

    var body: some View {
        List(selection: $selectedMeetingId) {
            if groupedMeetings.isEmpty {
                emptyState
            } else {
                ForEach(groupedMeetings, id: \.date) { group in
                    Section {
                        ForEach(group.meetings) { meeting in
                            MeetingRow(meeting: meeting)
                                .tag(meeting.id)
                                .listRowSeparator(.hidden)
                        }
                    } header: {
                        Text(Formatters.dateLabel(from: group.date))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $searchText, prompt: "Search meetings")
        .navigationTitle("Caddie")
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("No meetings yet")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Meetings will appear here once Caddie detects and records them.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    // MARK: - Grouping

    private struct DateGroup {
        let date: String
        let meetings: [Meeting]
    }

    private var groupedMeetings: [DateGroup] {
        let grouped = Dictionary(grouping: meetings) { $0.date }
        return grouped.keys.sorted(by: >).map { date in
            DateGroup(date: date, meetings: (grouped[date] ?? []).sorted { $0.startTime > $1.startTime })
        }
    }
}

// MARK: - MeetingRow

private struct MeetingRow: View {
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(meeting.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                if let time = Formatters.time(from: meeting.startTime) {
                    Text(time)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }

            HStack(spacing: 6) {
                StatusDot(status: meeting.status)

                if let app = meeting.app {
                    Text(app)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let duration = meeting.durationSeconds {
                    Text("\u{00B7} \(Formatters.duration(seconds: duration))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

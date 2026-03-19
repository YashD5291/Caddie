import SwiftUI
import GRDB

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedMeetingId: Int64?
    @State private var searchText = ""
    @State private var meetings: [Meeting] = []
    @State private var observationCancellable: AnyDatabaseCancellable?

    var body: some View {
        NavigationSplitView {
            MeetingListView(
                meetings: meetings,
                selectedMeetingId: $selectedMeetingId,
                searchText: $searchText
            )
        } detail: {
            if let id = selectedMeetingId,
               let meeting = meetings.first(where: { $0.id == id }) {
                MeetingDetailView(meeting: meeting)
            } else {
                ContentUnavailableView(
                    "No Meeting Selected",
                    systemImage: "mic",
                    description: Text("Select a meeting from the sidebar to view its transcript.")
                )
            }
        }
        .frame(minWidth: 700, minHeight: 500)
        .onAppear { startObserving() }
        .onDisappear { observationCancellable?.cancel() }
        .onChange(of: searchText) { _, _ in startObserving() }
    }

    // MARK: - Database Observation

    private func startObserving() {
        guard let dbWriter = appState.database?.dbWriter else { return }
        observationCancellable?.cancel()

        let currentSearch = searchText
        let observation = ValueObservation.tracking { db -> [Meeting] in
            if currentSearch.isEmpty {
                return try Meeting
                    .order(Column("created_at").desc)
                    .fetchAll(db)
            } else {
                let escaped = currentSearch.replacingOccurrences(of: "\"", with: "\"\"")
                let ftsQuery = "\"\(escaped)\"*"
                return try Meeting
                    .filter(
                        sql: "id IN (SELECT rowid FROM meetings_fts WHERE meetings_fts MATCH ?)",
                        arguments: [ftsQuery]
                    )
                    .order(Column("created_at").desc)
                    .fetchAll(db)
            }
        }

        observationCancellable = observation.start(
            in: dbWriter,
            onError: { error in
                CaddieLogger.app.error("Database observation error: \(error.localizedDescription)")
            },
            onChange: { newMeetings in
                meetings = newMeetings
            }
        )
    }
}

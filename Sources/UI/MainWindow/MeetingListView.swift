import SwiftUI

struct MeetingListView: View {
    let meetings: [Meeting]
    @Binding var selectedMeetingId: Int64?
    @Binding var searchText: String
    @Environment(AppState.self) private var appState
    @State private var scheduleExpanded = true
    @State private var showNewRecording = false

    private var upcomingEvents: [GoogleCalendarEvent] {
        appState.todayEvents.filter { !$0.isPast }
    }

    private var ongoingMeetings: [Meeting] {
        meetings.filter { $0.status == .recording || $0.status == .transcribing }
    }

    private var finishedMeetings: [Meeting] {
        meetings.filter { $0.status == .done || $0.status == .error }
    }

    var body: some View {
        VStack(spacing: 0) {
            newRecordingButton
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)

            list
        }
    }

    // MARK: - New Recording Button + Popover

    private var isNewRecordingDisabled: Bool {
        appState.coordinator == nil || appState.status != .idle
    }

    private var newRecordingHelp: String {
        if appState.coordinator == nil { return "Loading models..." }
        switch appState.status {
        case .idle: return "Start a new recording"
        case .recording: return "A recording is already in progress — stop it from the menu bar first"
        case .transcribing: return "Processing previous recording..."
        }
    }

    private var newRecordingButton: some View {
        Button {
            showNewRecording = true
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "record.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                Text("New Recording")
                    .font(.system(size: 13, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.red.opacity(isNewRecordingDisabled ? 0.06 : 0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.red.opacity(isNewRecordingDisabled ? 0.10 : 0.20), lineWidth: 0.5)
            )
            .foregroundStyle(isNewRecordingDisabled ? Color.red.opacity(0.45) : Color.red)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isNewRecordingDisabled)
        .help(newRecordingHelp)
        .popover(isPresented: $showNewRecording, arrowEdge: .top) {
            NewRecordingForm(isPresented: $showNewRecording)
                .environment(appState)
        }
    }

    private var list: some View {
        List(selection: $selectedMeetingId) {
            if case .signedIn = appState.googleAuthState {
                Section {
                    if scheduleExpanded {
                        TodayScheduleView(events: upcomingEvents)
                    }
                } header: {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            scheduleExpanded.toggle()
                        }
                    } label: {
                        HStack {
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .rotationEffect(.degrees(scheduleExpanded ? 90 : 0))
                            Text("Today's Schedule")
                            Spacer()
                            if !upcomingEvents.isEmpty {
                                Text("\(upcomingEvents.count)")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Section("Calendar") {
                    signInPromptCard
                }
            }

            if !ongoingMeetings.isEmpty {
                Section("Ongoing") {
                    ForEach(ongoingMeetings) { meeting in
                        OngoingMeetingRow(meeting: meeting)
                            .tag(meeting.id)
                            .listRowSeparator(.hidden)
                    }
                }
            }

            Section("Recordings") {
                if finishedMeetings.isEmpty {
                    emptyState
                } else {
                    ForEach(groupedMeetings, id: \.date) { group in
                        Section(Formatters.dateLabel(from: group.date)) {
                            ForEach(group.meetings) { meeting in
                                MeetingRow(meeting: meeting)
                                    .tag(meeting.id)
                                    .listRowSeparator(.hidden)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $searchText, prompt: "Search meetings")
        .navigationTitle("Caddie")
    }

    // MARK: - Sign-In Prompt Card

    @ViewBuilder
    private var signInPromptCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "calendar.badge.plus")
                    .font(.system(size: 13))
                    .foregroundStyle(.orange)
                Text("Connect Google Calendar")
                    .font(.system(size: 12, weight: .semibold))
            }

            Text("Sign in with Google to see your schedule and detect meetings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            switch appState.googleAuthState {
            case .signingIn:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Complete sign-in in your browser.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Button("Cancel") {
                    appState.cancelGoogleSignIn()
                }
                .font(.caption2)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

            case .error(let message):
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again") {
                    appState.signInToGoogle()
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.small)

            default:
                Button("Sign in with Google") {
                    appState.signInToGoogle()
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
        .listRowSeparator(.hidden)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text(ongoingMeetings.isEmpty ? "No recordings yet" : "Nothing finished yet")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(ongoingMeetings.isEmpty
                 ? "Recordings will appear here once they finish processing."
                 : "Your recording will land here when it's done.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    // MARK: - Grouping

    private struct DateGroup {
        let date: String
        let meetings: [Meeting]
    }

    private var groupedMeetings: [DateGroup] {
        let grouped = Dictionary(grouping: finishedMeetings) { $0.date }
        return grouped.keys.sorted(by: >).map { date in
            DateGroup(date: date, meetings: (grouped[date] ?? []).sorted { $0.startTime > $1.startTime })
        }
    }
}

// MARK: - Ongoing Meeting Row

private struct OngoingMeetingRow: View {
    let meeting: Meeting
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 8) {
            statusIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                TimelineView(.periodic(from: .now, by: 1.0)) { _ in
                    Text(elapsedText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 6)
            if meeting.status == .recording {
                stopButton
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch meeting.status {
        case .recording:
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
        case .transcribing:
            ProgressView().controlSize(.mini)
        default:
            EmptyView()
        }
    }

    private var stopButton: some View {
        Button {
            appState.stopManualRecording()
        } label: {
            Image(systemName: "stop.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(.red)
                .symbolRenderingMode(.hierarchical)
        }
        .buttonStyle(.plain)
        .help("Stop recording")
    }

    private var elapsedText: String {
        switch meeting.status {
        case .recording:
            guard let start = Formatters.parseISO8601(meeting.startTime) else { return "" }
            return Formatters.duration(seconds: Int(Date().timeIntervalSince(start)))
        case .transcribing:
            return "Processing\u{2026}"
        default:
            return ""
        }
    }
}

// MARK: - New Recording Form

private struct NewRecordingForm: View {
    @Binding var isPresented: Bool
    @Environment(AppState.self) private var appState
    @State private var meetingName: String = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        @Bindable var deviceManager = appState.audioDeviceManager
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text("New Recording")
                    .font(.system(size: 15, weight: .semibold))
                Text("Captures system audio and your microphone")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 14) {
                fieldGroup(label: "Title") {
                    TextField("e.g. 1:1 with Alice", text: $meetingName)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.regular)
                        .focused($nameFocused)
                        .onSubmit(start)
                }

                fieldGroup(label: "Microphone") {
                    Picker("", selection: $deviceManager.selectedDeviceUID) {
                        Text("System Default").tag(String?.none)
                        ForEach(deviceManager.availableInputDevices) { device in
                            Text(device.name).tag(Optional(device.id))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.regular)
                }
            }

            Divider()
                .padding(.horizontal, -20)

            HStack(spacing: 8) {
                Button("Cancel") {
                    isPresented = false
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button {
                    start()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "record.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Start Recording")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.regular)
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { nameFocused = true }
    }

    @ViewBuilder
    private func fieldGroup<Content: View>(
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.4)
            content()
        }
    }

    private var trimmedName: String {
        meetingName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func start() {
        let name = trimmedName.isEmpty ? "Manual Recording" : trimmedName
        guard !name.isEmpty else { return }
        appState.startManualRecording(title: name)
        isPresented = false
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

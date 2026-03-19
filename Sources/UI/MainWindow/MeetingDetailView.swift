import SwiftUI

struct MeetingDetailView: View {
    @Environment(AppState.self) private var appState
    let meeting: Meeting
    @State private var showingExportSheet = false
    @State private var showingDeleteConfirm = false

    private let accentColor = Color(red: 0.976, green: 0.451, blue: 0.086) // #F97316

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                headerSection
                if meeting.status == .done, let transcript = decodedTranscript {
                    statsSection(transcript: transcript)
                }
                audioSection
                transcriptSection
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingExportSheet = true
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(meeting.status != .done)
            }
            ToolbarItem(placement: .destructiveAction) {
                Button(role: .destructive) {
                    showingDeleteConfirm = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .confirmationDialog("Delete Meeting?", isPresented: $showingDeleteConfirm) {
                    Button("Delete", role: .destructive) { deleteMeeting() }
                } message: {
                    Text("This will permanently delete the recording and transcript for '\(meeting.title)'.")
                }
            }
        }
        .sheet(isPresented: $showingExportSheet) {
            ExportSheet(meeting: meeting)
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(meeting.title)
                .font(.title.bold())
                .textSelection(.enabled)

            HStack(spacing: 0) {
                if let app = meeting.app {
                    metadataChip(text: app, icon: "app.fill")
                }
                if let time = Formatters.time(from: meeting.startTime) {
                    if meeting.app != nil { metadataDivider }
                    if let endTime = meeting.endTime, let end = Formatters.time(from: endTime) {
                        metadataChip(text: "\(time) \u{2013} \(end)", icon: "clock")
                    } else {
                        metadataChip(text: time, icon: "clock")
                    }
                }
                if let duration = meeting.durationSeconds {
                    metadataDivider
                    metadataChip(text: Formatters.duration(seconds: duration), icon: "timer")
                }
                if let transcript = decodedTranscript {
                    metadataDivider
                    metadataChip(text: "\(transcript.numSpeakers) speaker\(transcript.numSpeakers == 1 ? "" : "s")", icon: "person.2")
                }
            }
        }
    }

    private func metadataChip(text: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2)
            Text(text)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    private var metadataDivider: some View {
        Text("\u{00B7}")
            .font(.subheadline)
            .foregroundStyle(.quaternary)
            .padding(.horizontal, 8)
    }

    // MARK: - Stats

    private func statsSection(transcript: Transcript) -> some View {
        HStack(spacing: 12) {
            if let duration = meeting.durationSeconds {
                statCard(value: Formatters.duration(seconds: duration), label: "Duration")
            }
            statCard(value: "\(transcript.numSpeakers)", label: "Speakers")
            statCard(value: "\(transcript.fullText.split(separator: " ").count)", label: "Words")
            statCard(value: transcript.language.uppercased(), label: "Language")
        }
    }

    private func statCard(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title2.bold())
                .foregroundStyle(accentColor)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Audio

    @ViewBuilder
    private var audioSection: some View {
        if meeting.audioFile != nil {
            AudioPlayerView(audioURL: AudioFileManager.alacPath(for: meeting.meetingId))
        }
    }

    // MARK: - Transcript

    @ViewBuilder
    private var transcriptSection: some View {
        switch meeting.status {
        case .done:
            if let transcript = decodedTranscript {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Transcript")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    TranscriptView(segments: transcript.segments)
                }
            }
        case .recording:
            statusCard(icon: "mic.fill", iconColor: .red, message: "Recording in progress...")
        case .transcribing:
            statusCard(icon: "text.badge.checkmark", iconColor: .orange, message: "Transcribing audio...")
        case .error:
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Transcription Failed").font(.headline)
                        Text(meeting.error ?? "An unknown error occurred.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Button {
                    appState.retryTranscription(meetingId: meeting.meetingId)
                } label: {
                    Label("Retry Transcription", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func statusCard(icon: String, iconColor: Color, message: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(iconColor).font(.title3)
            Text(message).foregroundStyle(.secondary)
            Spacer()
            ProgressView().controlSize(.small)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Helpers

    private var decodedTranscript: Transcript? {
        guard let json = meeting.transcript,
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Transcript.self, from: data)
    }

    private func deleteMeeting() {
        guard let db = appState.database else { return }
        do {
            try db.dbWriter.write { dbConn in
                _ = try Meeting.deleteOne(dbConn, id: meeting.id)
            }
            AudioFileManager.deleteAudio(meetingId: meeting.meetingId)
        } catch {
            CaddieLogger.storage.error("Failed to delete meeting: \(error.localizedDescription)")
        }
    }
}

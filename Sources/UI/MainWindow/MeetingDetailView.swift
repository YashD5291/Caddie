import SwiftUI

struct MeetingDetailView: View {
    let meeting: Meeting
    @State private var showingExportSheet = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                audioSection
                transcriptSection
            }
            .padding()
        }
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
                    // Placeholder — wired in Task 11
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .sheet(isPresented: $showingExportSheet) {
            ExportSheet(meeting: meeting)
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(meeting.title)
                .font(.title2.bold())

            HStack(spacing: 8) {
                if let app = meeting.app {
                    Text(app)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let time = Formatters.time(from: meeting.startTime) {
                    Text(time)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let endTime = meeting.endTime, let end = Formatters.time(from: endTime),
                   let start = Formatters.time(from: meeting.startTime) {
                    Text("\(start) – \(end)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let duration = meeting.durationSeconds {
                    Text(Formatters.duration(seconds: duration))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let transcript = decodedTranscript {
                    Text("\(transcript.numSpeakers) speaker\(transcript.numSpeakers == 1 ? "" : "s")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Audio

    @ViewBuilder
    private var audioSection: some View {
        if let audioFile = meeting.audioFile {
            let url = AudioFileManager.alacPath(for: audioFile)
            AudioPlayerView(audioURL: url)
        }
    }

    // MARK: - Transcript

    @ViewBuilder
    private var transcriptSection: some View {
        switch meeting.status {
        case .done:
            if let transcript = decodedTranscript {
                TranscriptView(segments: transcript.segments)
            }
        case .recording:
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text("Recording in progress...")
                    .foregroundStyle(.secondary)
            }
        case .transcribing:
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text("Transcribing...")
                    .foregroundStyle(.secondary)
            }
        case .error:
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(meeting.error ?? "Transcription failed")
                    .foregroundStyle(.secondary)
                Button("Retry Transcription") {
                    // Placeholder — wired in Task 11
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Helpers

    private var decodedTranscript: Transcript? {
        guard let json = meeting.transcript,
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Transcript.self, from: data)
    }
}

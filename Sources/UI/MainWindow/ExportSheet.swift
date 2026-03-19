import SwiftUI
import AppKit

// MARK: - ExportFormatter

enum ExportFormatter {
    static func toTXT(segments: [TranscriptSegment]) -> String {
        TranscriptMerger.generateFullText(segments: segments)
    }

    static func toSRT(segments: [TranscriptSegment]) -> String {
        var result = ""
        for (index, segment) in segments.enumerated() {
            let number = index + 1
            let startTS = Formatters.srtTimestamp(seconds: segment.start)
            let endTS = Formatters.srtTimestamp(seconds: segment.end)
            result += "\(number)\n\(startTS) --> \(endTS)\n[\(segment.speaker)] \(segment.text)\n\n"
        }
        return result
    }
}

// MARK: - ExportSheet

struct ExportSheet: View {
    let meeting: Meeting
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                Text("Export Transcript").font(.title3.bold())
                Text(meeting.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 10) {
                Button { exportAs(format: .txt) } label: {
                    HStack { Image(systemName: "doc.text"); Text("Export as TXT") }.frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button { exportAs(format: .srt) } label: {
                    HStack { Image(systemName: "captions.bubble"); Text("Export as SRT") }.frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .frame(width: 220)

            Button("Cancel", role: .cancel) { dismiss() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.subheadline)
        }
        .padding(32)
        .frame(minWidth: 320)
    }

    private enum ExportFormat { case txt, srt }

    private func exportAs(format: ExportFormat) {
        guard let transcriptJSON = meeting.transcript,
              let data = transcriptJSON.data(using: .utf8),
              let transcript = try? JSONDecoder().decode(Transcript.self, from: data) else { return }

        let content: String
        let fileExtension: String
        switch format {
        case .txt: content = ExportFormatter.toTXT(segments: transcript.segments); fileExtension = "txt"
        case .srt: content = ExportFormatter.toSRT(segments: transcript.segments); fileExtension = "srt"
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(meeting.title).\(fileExtension)"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? content.write(to: url, atomically: true, encoding: .utf8)
        dismiss()
    }
}

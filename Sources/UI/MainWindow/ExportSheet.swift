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
            result += "\(number)\n"
            result += "\(startTS) --> \(endTS)\n"
            result += "[\(segment.speaker)] \(segment.text)\n\n"
        }
        return result
    }
}

// MARK: - ExportSheet

struct ExportSheet: View {
    let meeting: Meeting
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Export Transcript")
                .font(.headline)

            Text("Choose a format for \"\(meeting.title)\"")
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("Export as TXT") {
                    exportAs(format: .txt)
                }
                .buttonStyle(.borderedProminent)

                Button("Export as SRT") {
                    exportAs(format: .srt)
                }
                .buttonStyle(.bordered)
            }

            Button("Cancel") {
                dismiss()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(minWidth: 300)
    }

    private enum ExportFormat {
        case txt, srt
    }

    private func exportAs(format: ExportFormat) {
        guard let transcriptJSON = meeting.transcript,
              let data = transcriptJSON.data(using: .utf8),
              let transcript = try? JSONDecoder().decode(Transcript.self, from: data) else {
            return
        }

        let content: String
        let fileExtension: String

        switch format {
        case .txt:
            content = ExportFormatter.toTXT(segments: transcript.segments)
            fileExtension = "txt"
        case .srt:
            content = ExportFormatter.toSRT(segments: transcript.segments)
            fileExtension = "srt"
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(meeting.title).\(fileExtension)"
        panel.allowedContentTypes = [.plainText]

        guard panel.runModal() == .OK, let url = panel.url else { return }

        try? content.write(to: url, atomically: true, encoding: .utf8)
        dismiss()
    }
}

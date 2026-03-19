import SwiftUI

struct TranscriptView: View {
    let segments: [TranscriptSegment]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                    segmentRow(segment: segment, index: index)
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func segmentRow(segment: TranscriptSegment, index: Int) -> some View {
        let showSpeaker = index == 0 || segments[index - 1].speaker != segment.speaker

        HStack(alignment: .top, spacing: 8) {
            // Speaker label column
            Group {
                if showSpeaker {
                    SpeakerBadge(speaker: segment.speaker)
                } else {
                    Text("")
                }
            }
            .frame(width: 90, alignment: .trailing)

            // Timestamp
            Text(Formatters.timestamp(seconds: segment.start))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 40, alignment: .trailing)

            // Text content
            Text(segment.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

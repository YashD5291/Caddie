import SwiftUI

struct TranscriptView: View {
    let segments: [TranscriptSegment]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                let isNewSpeaker = index == 0 || segments[index - 1].speaker != segment.speaker

                if isNewSpeaker && index > 0 {
                    Divider().padding(.vertical, 10)
                }

                if isNewSpeaker {
                    HStack(spacing: 8) {
                        SpeakerBadge(speaker: segment.speaker)
                        Text(Formatters.timestamp(seconds: segment.start))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.bottom, 4)
                }

                HStack(alignment: .top, spacing: 8) {
                    if !isNewSpeaker {
                        Text(Formatters.timestamp(seconds: segment.start))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.quaternary)
                            .frame(width: 36, alignment: .trailing)
                    }

                    Text(segment.text)
                        .textSelection(.enabled)
                        .lineSpacing(4)
                }
            }
        }
    }
}

import SwiftUI

struct SpeakerBadge: View {
    let speaker: String

    private static let colors: [Color] = [
        .blue, .green, .purple, .orange,
        .pink, .teal, .indigo, .mint,
    ]

    var body: some View {
        Text(speaker)
            .font(.caption2.monospaced().bold())
            .foregroundStyle(color)
    }

    private var color: Color {
        let index = abs(speaker.hashValue) % Self.colors.count
        return Self.colors[index]
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 4) {
        SpeakerBadge(speaker: "Speaker 1")
        SpeakerBadge(speaker: "Speaker 2")
        SpeakerBadge(speaker: "Speaker 3")
    }
    .padding()
}

import SwiftUI

struct SpeakerBadge: View {
    let speaker: String

    private static let palette: [(Color, Color)] = [
        (Color(red: 0.27, green: 0.46, blue: 0.90), Color(red: 0.22, green: 0.38, blue: 0.78)),
        (Color(red: 0.17, green: 0.60, blue: 0.55), Color(red: 0.13, green: 0.50, blue: 0.46)),
        (Color(red: 0.80, green: 0.30, blue: 0.55), Color(red: 0.68, green: 0.24, blue: 0.46)),
        (Color(red: 0.30, green: 0.55, blue: 0.35), Color(red: 0.24, green: 0.46, blue: 0.28)),
        (Color(red: 0.75, green: 0.52, blue: 0.20), Color(red: 0.64, green: 0.44, blue: 0.16)),
        (Color(red: 0.85, green: 0.42, blue: 0.28), Color(red: 0.74, green: 0.35, blue: 0.22)),
        (Color(red: 0.50, green: 0.40, blue: 0.75), Color(red: 0.42, green: 0.33, blue: 0.65)),
        (Color(red: 0.45, green: 0.50, blue: 0.55), Color(red: 0.38, green: 0.42, blue: 0.48)),
    ]

    var body: some View {
        Text(speaker)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [colors.0, colors.1],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .fixedSize()
    }

    private var colors: (Color, Color) {
        let hash = speaker.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
        let index = abs(hash) % Self.palette.count
        return Self.palette[index]
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 6) {
        SpeakerBadge(speaker: "Speaker 1")
        SpeakerBadge(speaker: "Speaker 2")
        SpeakerBadge(speaker: "Speaker 3")
    }
    .padding()
}

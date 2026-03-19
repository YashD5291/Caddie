import SwiftUI

struct StatusDot: View {
    let status: MeetingStatus
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .shadow(color: status == .recording ? color.opacity(0.5) : .clear, radius: isPulsing ? 4 : 0)
            .scaleEffect(status == .recording && isPulsing ? 1.3 : 1.0)
            .opacity(status == .recording && isPulsing ? 0.7 : 1.0)
            .animation(
                status == .recording
                    ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                    : .default,
                value: isPulsing
            )
            .onAppear {
                if status == .recording { isPulsing = true }
            }
            .onChange(of: status) { _, newValue in
                isPulsing = newValue == .recording
            }
    }

    private var color: Color {
        switch status {
        case .done: .green
        case .recording: .red
        case .transcribing: .orange
        case .error: .red
        }
    }
}

#Preview {
    HStack(spacing: 16) {
        StatusDot(status: .recording)
        StatusDot(status: .transcribing)
        StatusDot(status: .done)
        StatusDot(status: .error)
    }
    .padding()
}

import SwiftUI

struct StatusDot: View {
    let status: MeetingStatus

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
    }

    private var color: Color {
        switch status {
        case .done:
            .green
        case .recording:
            .red
        case .transcribing:
            .orange
        case .error:
            .red
        }
    }
}

#Preview {
    HStack(spacing: 12) {
        StatusDot(status: .done)
        StatusDot(status: .recording)
        StatusDot(status: .transcribing)
        StatusDot(status: .error)
    }
    .padding()
}

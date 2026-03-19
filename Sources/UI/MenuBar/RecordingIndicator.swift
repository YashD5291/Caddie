import SwiftUI

struct RecordingIndicator: View {
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(.red)
            .frame(width: 8, height: 8)
            .shadow(color: .red.opacity(isPulsing ? 0.6 : 0), radius: 4)
            .animation(
                .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                value: isPulsing
            )
            .onAppear { isPulsing = true }
    }
}

#Preview {
    RecordingIndicator()
        .padding()
}

import SwiftUI

/// Full-window overlay shown while AppState is wiring up its dependencies
/// (database open, ASR + diarization models loading, coordinator construction).
/// Rendered above `mainContent` so the UI doesn't appear to be broken — the
/// New Recording / per-event Record buttons are correctly disabled until the
/// pipeline exists, and this surface tells the user *why*.
struct LoadingOverlay: View {

    private static let phrases: [String] = [
        "Loading speech recognition…",
        "Tuning speaker recognition…",
        "Warming up the audio pipeline…",
        "Almost ready…"
    ]

    private static let phraseInterval: TimeInterval = 2.4

    @State private var phraseIndex: Int = 0
    @State private var iconScale: CGFloat = 1.0
    @State private var rotation: Double = 0

    private let accent = Color(red: 0.976, green: 0.451, blue: 0.086) // matches detail-view accent

    var body: some View {
        ZStack {
            // Full-bleed frosted background. Material.ultraThin reads the wallpaper
            // / window content behind it, so the overlay feels integrated with macOS
            // rather than a flat scrim painted on top.
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            // Subtle radial accent behind the card so the eye lands on it.
            RadialGradient(
                colors: [accent.opacity(0.18), .clear],
                center: .center,
                startRadius: 20,
                endRadius: 320
            )
            .blendMode(.plusLighter)
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 24) {
                iconBadge
                textBlock
                progressIndicator
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 32)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.25), radius: 30, y: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
            )
        }
        .transition(.opacity.combined(with: .scale(scale: 1.02)))
        .onAppear(perform: startIconPulse)
        .task(id: "phrase-cycle", cyclePhrases)
    }

    // MARK: - Subviews

    private var iconBadge: some View {
        ZStack {
            // Soft outer glow that pulses with the icon.
            Circle()
                .fill(accent.opacity(0.18))
                .frame(width: 96, height: 96)
                .blur(radius: 18)
                .scaleEffect(iconScale)

            Circle()
                .fill(
                    LinearGradient(
                        colors: [accent.opacity(0.95), accent.opacity(0.55)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 72, height: 72)
                .shadow(color: accent.opacity(0.45), radius: 16, y: 4)

            Image(systemName: "waveform")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)
                .symbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeating)
        }
        .scaleEffect(iconScale)
    }

    private var textBlock: some View {
        VStack(spacing: 8) {
            Text("Preparing Caddie")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)

            // Cross-fade through phrases. id-based transition gives a clean swap
            // instead of mid-string character shuffle.
            Text(Self.phrases[phraseIndex])
                .id(phraseIndex)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .transition(
                    .asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .bottom)),
                        removal: .opacity.combined(with: .move(edge: .top))
                    )
                )
                .frame(minHeight: 18)
        }
        .multilineTextAlignment(.center)
    }

    private var progressIndicator: some View {
        // Three dots whose opacity ripples — feels lighter than a spinner and
        // matches the "ambient" tone of the overlay.
        TimelineView(.periodic(from: .now, by: 0.18)) { context in
            let tick = Int(context.date.timeIntervalSinceReferenceDate / 0.18) % 3
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(accent)
                        .opacity(i == tick ? 1.0 : 0.25)
                        .frame(width: 5, height: 5)
                        .animation(.easeInOut(duration: 0.18), value: tick)
                }
            }
        }
    }

    // MARK: - Animation Driver

    private func startIconPulse() {
        // Pulse the icon scale on a slow loop.
        withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
            iconScale = 1.06
        }
    }

    /// Cycle the status phrases. Driven by a `.task` modifier so the loop is
    /// automatically cancelled when the overlay is removed (init finished) — no
    /// orphaned Task survives the view. `Task.sleep` is cancellation-aware, so the
    /// loop exits promptly on teardown.
    @Sendable private func cyclePhrases() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(Self.phraseInterval * 1_000_000_000))
            if Task.isCancelled { break }
            withAnimation(.easeInOut(duration: 0.45)) {
                phraseIndex = (phraseIndex + 1) % Self.phrases.count
            }
        }
    }
}

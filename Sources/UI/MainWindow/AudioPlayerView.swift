import SwiftUI
import AVFoundation

struct AudioPlayerView: View {
    let audioURL: URL

    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var playbackSpeed: Float = 1.0
    @State private var timer: Timer?
    @State private var fileExists = false

    private let speeds: [Float] = [0.5, 1.0, 1.5, 2.0]

    var body: some View {
        if fileExists {
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    Button {
                        togglePlayback()
                    } label: {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)

                    Text(Formatters.timestamp(seconds: currentTime))
                        .font(.caption.monospacedDigit())
                        .frame(width: 40, alignment: .trailing)

                    Slider(value: $currentTime, in: 0...max(duration, 1)) { editing in
                        if !editing {
                            player?.currentTime = currentTime
                        }
                    }

                    Text(Formatters.timestamp(seconds: duration))
                        .font(.caption.monospacedDigit())
                        .frame(width: 40, alignment: .leading)

                    Picker("Speed", selection: $playbackSpeed) {
                        ForEach(speeds, id: \.self) { speed in
                            Text("\(speed, specifier: "%.1f")x").tag(speed)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                    .onChange(of: playbackSpeed) { _, newValue in
                        player?.rate = newValue
                    }
                }
            }
            .padding()
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .onAppear { loadAudio() }
            .onDisappear { stopTimer(); player?.stop() }
        } else {
            HStack {
                Image(systemName: "waveform.slash")
                    .foregroundStyle(.secondary)
                Text("Audio file not found")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }
            .onAppear {
                fileExists = FileManager.default.fileExists(atPath: audioURL.path)
            }
        }
    }

    private func loadAudio() {
        fileExists = FileManager.default.fileExists(atPath: audioURL.path)
        guard fileExists else { return }

        do {
            let audioPlayer = try AVAudioPlayer(contentsOf: audioURL)
            audioPlayer.enableRate = true
            audioPlayer.prepareToPlay()
            duration = audioPlayer.duration
            player = audioPlayer
        } catch {
            fileExists = false
        }
    }

    private func togglePlayback() {
        guard let player else { return }

        if isPlaying {
            player.pause()
            stopTimer()
        } else {
            player.rate = playbackSpeed
            player.play()
            startTimer()
        }
        isPlaying.toggle()
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            guard let player else { return }
            currentTime = player.currentTime
            if !player.isPlaying && isPlaying {
                isPlaying = false
                stopTimer()
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

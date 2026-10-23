import SwiftUI

struct PlayerControlView: View {
    @ObservedObject var playerManager: AudioPlayerManager
    @ObservedObject var playbackProgress: PlaybackProgress
    @AppStorage("selectedBackgroundTheme") private var selectedBackgroundTheme = "cream"
    @State private var isDragging: Bool = false
    @State private var dragProgress: Double? = nil

    private var selectedTheme: SoftColorTheme {
        SoftColorTheme.option(for: selectedBackgroundTheme)
    }

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                GeometryReader { geometry in
                    let width = geometry.size.width
                    let totalDuration = max(1.0, playerManager.duration)
                    let currentProgress: Double = {
                        if let drag = dragProgress {
                            return drag
                        }
                        return playbackProgress.currentTime / totalDuration
                    }()
                    let bufferProgress = playbackProgress.bufferedTime / totalDuration
                    let clampedCurrent = max(0.0, min(currentProgress, 1.0))
                    let clampedBuffer = max(0.0, min(bufferProgress, 1.0))

                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(selectedTheme.controlColor)
                            .frame(height: 6)
                        Capsule()
                            .fill(selectedTheme.accentColor.opacity(0.28))
                            .frame(width: max(0, width * CGFloat(clampedBuffer)), height: 6)
                        Capsule()
                            .fill(selectedTheme.accentColor)
                            .frame(width: max(0, width * CGFloat(clampedCurrent)), height: 6)
                        Circle()
                            .fill(selectedTheme.cardColor)
                            .frame(width: isDragging ? 18 : 14, height: isDragging ? 18 : 14)
                            .shadow(color: Color.black.opacity(0.22), radius: 3, x: 0, y: 1)
                            .offset(x: max(0, min(width - (isDragging ? 18 : 14), width * CGFloat(clampedCurrent) - (isDragging ? 9 : 7))))
                    }
                    .frame(height: 24)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                isDragging = true
                                let locationX = max(0, min(value.location.x, width))
                                dragProgress = Double(locationX / width)
                            }
                            .onEnded { value in
                                let locationX = max(0, min(value.location.x, width))
                                let progress = Double(locationX / width)
                                dragProgress = progress
                                playerManager.seek(to: progress * totalDuration)
                                isDragging = false
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    if !isDragging {
                                        dragProgress = nil
                                    }
                                }
                            }
                    )
                }
                .frame(height: 24)

                HStack {
                    let totalDuration = max(1.0, playerManager.duration)
                    let currentShownSeconds = dragProgress.map { $0 * totalDuration } ?? playbackProgress.currentTime
                    Text(formatTime(currentShownSeconds))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(selectedTheme.accentColor)
                    Spacer()
                    if playerManager.isBuffering {
                        HStack(spacing: 4) {
                            ProgressView()
                                .scaleEffect(0.6)
                            Text("缓冲中...")
                                .font(.caption2)
                                .foregroundColor(selectedTheme.accentColor.opacity(0.75))
                        }
                    }
                    Spacer()
                    Text(formatTime(playerManager.duration))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(selectedTheme.accentColor)
                }
            }

            HStack(spacing: 40) {
                Button(action: {
                    playerManager.skip(by: -15)
                }) {
                    Image(systemName: "gobackward.15")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundColor(selectedTheme.accentColor)
                }
                Button(action: {
                    playerManager.togglePlayPause()
                }) {
                    ZStack {
                        Circle()
                            .fill(selectedTheme.accentColor)
                            .frame(width: 60, height: 60)
                            .shadow(color: selectedTheme.accentColor.opacity(0.28), radius: 6, x: 0, y: 3)
                        if playerManager.isBuffering && !playerManager.isPlaying {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        } else {
                            Image(systemName: playerManager.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundColor(.white)
                                .offset(x: playerManager.isPlaying ? 0 : 2)
                        }
                    }
                }
                Button(action: {
                    playerManager.skip(by: 15)
                }) {
                    Image(systemName: "goforward.15")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundColor(selectedTheme.accentColor)
                }
            }
        }
        .padding(16)
        .background(selectedTheme.cardColor)
        .cornerRadius(16)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard !seconds.isNaN && seconds >= 0 else { return "00:00" }
        let totalSecs = Int(seconds)
        return String(format: "%02d:%02d", totalSecs / 60, totalSecs % 60)
    }
}

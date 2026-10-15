import SwiftUI

struct PlayerControlView: View {
    @ObservedObject var playerManager: AudioPlayerManager
    @State private var isDraggingSlider: Bool = false
    @State private var dragSliderValue: Double = 0

    var body: some View {
        VStack(spacing: 16) {
            // 进度条与时间
            VStack(spacing: 6) {
                Slider(
                    value: Binding(
                        get: { isDraggingSlider ? dragSliderValue : playerManager.currentTime },
                        set: { newValue in
                            dragSliderValue = newValue
                        }
                    ),
                    in: 0...max(1.0, playerManager.duration),
                    onEditingChanged: { editing in
                        isDraggingSlider = editing
                        if !editing {
                            playerManager.seek(to: dragSliderValue)
                        }
                    }
                )
                .accentColor(.blue)

                HStack {
                    Text(formatTime(isDraggingSlider ? dragSliderValue : playerManager.currentTime))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(formatTime(playerManager.duration))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            // 控制按键
            HStack(spacing: 36) {
                // 快退 15 秒
                Button(action: {
                    playerManager.skip(by: -15)
                }) {
                    Image(systemName: "gobackward.15")
                        .font(.system(size: 24))
                        .foregroundColor(.primary)
                }

                // 播放 / 暂停
                Button(action: {
                    playerManager.togglePlayPause()
                }) {
                    ZStack {
                        Circle()
                            .fill(Color.blue)
                            .frame(width: 64, height: 64)
                            .shadow(color: Color.blue.opacity(0.3), radius: 8, x: 0, y: 4)

                        if playerManager.isBuffering {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        } else {
                            Image(systemName: playerManager.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 26))
                                .foregroundColor(.white)
                                .offset(x: playerManager.isPlaying ? 0 : 2)
                        }
                    }
                }

                // 快进 15 秒
                Button(action: {
                    playerManager.skip(by: 15)
                }) {
                    Image(systemName: "goforward.15")
                        .font(.system(size: 24))
                        .foregroundColor(.primary)
                }
            }
        }
        .padding(16)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(16)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard !seconds.isNaN && seconds >= 0 else { return "00:00" }
        let totalSecs = Int(seconds)
        let m = totalSecs / 60
        let s = totalSecs % 60
        return String(format: "%02d:%02d", m, s)
    }
}

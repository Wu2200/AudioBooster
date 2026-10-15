import SwiftUI

struct PlayerControlView: View {
    @ObservedObject var playerManager: AudioPlayerManager
    @State private var isDragging: Bool = false
    @State private var dragTime: Double = 0

    var body: some View {
        VStack(spacing: 16) {
            // 自定义进度条：支持预载(缓冲)进度条显示 + 单击跳转 + 顺畅拖拽滑动
            VStack(spacing: 8) {
                GeometryReader { geometry in
                    let width = geometry.size.width
                    let totalDuration = max(1.0, playerManager.duration)
                    let currentProgress = (isDragging ? dragTime : playerManager.currentTime) / totalDuration
                    let bufferProgress = playerManager.bufferedTime / totalDuration

                    let clampedCurrent = max(0, min(currentProgress, 1.0))
                    let clampedBuffer = max(0, min(bufferProgress, 1.0))

                    ZStack(alignment: .leading) {
                        // 1. 底层槽位轨道
                        Capsule()
                            .fill(Color(UIColor.systemGray5))
                            .frame(height: 6)

                        // 2. 预载 / 缓冲进度条 (浅蓝半透明区别显示)
                        Capsule()
                            .fill(Color.blue.opacity(0.35))
                            .frame(width: max(0, width * CGFloat(clampedBuffer)), height: 6)

                        // 3. 当前播放进度条 (亮蓝高亮)
                        Capsule()
                            .fill(Color.blue)
                            .frame(width: max(0, width * CGFloat(clampedCurrent)), height: 6)

                        // 4. 进度条滑块手柄 (Thumb)
                        Circle()
                            .fill(Color.white)
                            .frame(width: isDragging ? 18 : 14, height: isDragging ? 18 : 14)
                            .shadow(color: Color.black.opacity(0.18), radius: 3, x: 0, y: 1)
                            .offset(x: max(0, min(width - (isDragging ? 18 : 14), width * CGFloat(clampedCurrent) - (isDragging ? 9 : 7))))
                    }
                    .frame(height: 24)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                isDragging = true
                                let locationX = max(0, min(value.location.x, width))
                                let progress = locationX / width
                                dragTime = Double(progress) * totalDuration
                            }
                            .onEnded { value in
                                let locationX = max(0, min(value.location.x, width))
                                let progress = locationX / width
                                let targetTime = Double(progress) * totalDuration
                                playerManager.seek(to: targetTime)
                                isDragging = false
                            }
                    )
                }
                .frame(height: 24)

                // 时间标签与缓冲提示
                HStack {
                    Text(formatTime(isDragging ? dragTime : playerManager.currentTime))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)

                    Spacer()

                    if playerManager.isBuffering {
                        HStack(spacing: 4) {
                            ProgressView()
                                .scaleEffect(0.6)
                            Text("缓冲中...")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }

                    Spacer()

                    Text(formatTime(playerManager.duration))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            // 控制按键区
            HStack(spacing: 40) {
                // 快退 15 秒
                Button(action: {
                    playerManager.skip(by: -15)
                }) {
                    Image(systemName: "gobackward.15")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundColor(.primary)
                }

                // 播放 / 暂停
                Button(action: {
                    playerManager.togglePlayPause()
                }) {
                    ZStack {
                        Circle()
                            .fill(Color.blue)
                            .frame(width: 60, height: 60)
                            .shadow(color: Color.blue.opacity(0.28), radius: 6, x: 0, y: 3)

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

                // 快进 15 秒
                Button(action: {
                    playerManager.skip(by: 15)
                }) {
                    Image(systemName: "goforward.15")
                        .font(.system(size: 24, weight: .medium))
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

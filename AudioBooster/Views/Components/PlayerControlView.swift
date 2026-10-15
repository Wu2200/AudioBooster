import SwiftUI

struct PlayerControlView: View {
    @ObservedObject var playerManager: AudioPlayerManager
    @State private var isDragging: Bool = false
    @State private var dragProgress: Double? = nil

    var body: some View {
        VStack(spacing: 16) {
            // 自定义进度条：深灰高对比预载条 + 平滑无闪烁单击与滑动
            VStack(spacing: 8) {
                GeometryReader { geometry in
                    let width = geometry.size.width
                    let totalDuration = max(1.0, playerManager.duration)

                    // 优先使用拖拽/单击的目标位置，杜绝底层异步 seek 造成的原点闪回
                    let currentProgress: Double = {
                        if let drag = dragProgress {
                            return drag
                        }
                        return playerManager.currentTime / totalDuration
                    }()
                    let bufferProgress = playerManager.bufferedTime / totalDuration

                    let clampedCurrent = max(0.0, min(currentProgress, 1.0))
                    let clampedBuffer = max(0.0, min(bufferProgress, 1.0))

                    ZStack(alignment: .leading) {
                        // 1. 底层浅灰槽位轨道
                        Capsule()
                            .fill(Color(UIColor.systemGray5))
                            .frame(height: 6)

                        // 2. 预载 / 缓冲进度条 (柔和浅灰色，清晰且不突兀)
                        Capsule()
                            .fill(Color(UIColor.systemGray4))
                            .frame(width: max(0, width * CGFloat(clampedBuffer)), height: 6)

                        // 3. 当前播放进度条 (亮蓝高亮)
                        Capsule()
                            .fill(Color.blue)
                            .frame(width: max(0, width * CGFloat(clampedCurrent)), height: 6)

                        // 4. 进度条滑块手柄 (Thumb)
                        Circle()
                            .fill(Color.white)
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
                                let progress = Double(locationX / width)
                                dragProgress = progress
                            }
                            .onEnded { value in
                                let locationX = max(0, min(value.location.x, width))
                                let progress = Double(locationX / width)
                                dragProgress = progress
                                let targetTime = progress * totalDuration
                                playerManager.seek(to: targetTime)
                                isDragging = false

                                // 延时清除临时手势进度，让 Seek 锁平稳过渡，绝不出现原点跳闪
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    if !isDragging {
                                        dragProgress = nil
                                    }
                                }
                            }
                    )
                }
                .frame(height: 24)

                // 时间标签与缓冲提示
                HStack {
                    let totalDuration = max(1.0, playerManager.duration)
                    let currentShownSeconds: Double = {
                        if let drag = dragProgress {
                            return drag * totalDuration
                        }
                        return playerManager.currentTime
                    }()

                    Text(formatTime(currentShownSeconds))
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

import SwiftUI

struct ASMRImmersionCard: View {
    @ObservedObject var playerManager: AudioPlayerManager

    let sleepTimerPresets = [0, 15, 30, 45, 60, 90]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 头部标题
            HStack {
                Label("ASMR 沉浸调音 & 助眠", systemImage: "headphones")
                    .font(.headline)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Spacer()
            }

            // MARK: - 播放双内核选择系统 (切换测试)
            VStack(alignment: .leading, spacing: 6) {
                Text("播放内核选择 (可自由切换对比)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack(spacing: 8) {
                    ForEach(PlayerEngineType.allCases) { engine in
                        Button(action: {
                            playerManager.switchEngine(to: engine)
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: engine.icon)
                                    .font(.subheadline)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(engine.rawValue)
                                        .font(.caption.bold())
                                        .lineLimit(1)
                                    Text(engine.badge)
                                        .font(.system(size: 9))
                                        .opacity(0.85)
                                        .lineLimit(1)
                                }
                                Spacer()
                                if playerManager.currentEngineType == engine {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.caption)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, minHeight: 48, maxHeight: 48)
                            .background(
                                playerManager.currentEngineType == engine ?
                                Color.blue : Color(UIColor.secondarySystemBackground)
                            )
                            .foregroundColor(
                                playerManager.currentEngineType == engine ?
                                .white : .primary
                            )
                            .cornerRadius(10)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }

                // 如果处于 DSP 缓冲状态，提示下载进度
                if let progressText = playerManager.dspBufferProgressText {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text(progressText)
                            .font(.caption2)
                            .foregroundColor(.blue)
                    }
                    .padding(.top, 2)
                }
            }

            Divider()

            // 4 大音效模式网格选择器（固定高度，杜绝尺寸跳变）
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("声学预设 (在 DSP 内核下享受硬件级滤波)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(ASMREffectMode.allCases) { mode in
                        Button(action: {
                            playerManager.setASMREffectMode(mode)
                        }) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Image(systemName: mode.icon)
                                        .font(.subheadline)
                                    Text(mode.rawValue)
                                        .font(.subheadline.bold())
                                        .lineLimit(1)
                                    Spacer()
                                    if playerManager.asmrMode == mode {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.caption)
                                    }
                                }
                                Text(mode.summary)
                                    .font(.system(size: 10))
                                    .opacity(0.85)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, minHeight: 56, maxHeight: 56, alignment: .leading)
                            .background(
                                playerManager.asmrMode == mode ?
                                Color.purple : Color(UIColor.secondarySystemBackground)
                            )
                            .foregroundColor(
                                playerManager.asmrMode == mode ?
                                .white : .primary
                            )
                            .cornerRadius(12)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
            }

            Divider()

            // 睡眠定时器与循环播放控制
            VStack(spacing: 12) {
                // 睡眠定时器
                HStack {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("睡眠定时关播")
                                .font(.subheadline)
                            if playerManager.sleepTimerMinutes > 0 {
                                Text("剩余: \(formatSeconds(playerManager.sleepTimerRemainingSeconds)) (到期平滑渐弱)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.purple)
                            } else {
                                Text("定时停止播放，防止整夜耗电")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: playerManager.sleepTimerMinutes > 0 ? "timer.circle.fill" : "timer")
                            .font(.title3)
                            .foregroundColor(playerManager.sleepTimerMinutes > 0 ? .purple : .secondary)
                    }

                    Spacer()

                    Menu {
                        ForEach(sleepTimerPresets, id: \.self) { minutes in
                            Button(action: {
                                playerManager.setSleepTimer(minutes: minutes)
                            }) {
                                HStack {
                                    Text(minutes == 0 ? "关闭定时" : "\(minutes) 分钟")
                                    if playerManager.sleepTimerMinutes == minutes {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(playerManager.sleepTimerMinutes == 0 ? "已关闭" : "\(playerManager.sleepTimerMinutes) 分钟")
                                .font(.subheadline)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(UIColor.tertiarySystemGroupedBackground))
                        .foregroundColor(.primary)
                        .cornerRadius(8)
                    }
                }

                // 单曲无缝循环开关
                Toggle(isOn: $playerManager.isLooping) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("无缝单曲循环")
                            .font(.subheadline)
                        Text("ASMR 与白噪音播放完毕自动重头起播")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .tint(.purple)

                // 防爆音软压限保护开关
                Toggle(isOn: $playerManager.isLimiterEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("防爆音软压限保护")
                            .font(.subheadline)
                        Text("大音量突破下自动平滑突发碰撞与喷麦破音")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .tint(.purple)
            }
        }
        .padding(16)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(16)
    }

    private func formatSeconds(_ secs: Int) -> String {
        let m = secs / 60
        let s = secs % 60
        return String(format: "%02d:%02d", m, s)
    }
}

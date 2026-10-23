import SwiftUI

struct ASMRImmersionCard: View {
    @ObservedObject var playerManager: AudioPlayerManager
    @AppStorage("selectedBackgroundTheme") private var selectedBackgroundTheme = "cream"

    private var selectedTheme: SoftColorTheme {
        SoftColorTheme.option(for: selectedBackgroundTheme)
    }

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

            // MARK: - 4 大 ASMR 专业声学预设模式 (网易云同款真·实时 DSP 算法)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(ASMREffectMode.allCases) { mode in
                    let isSelected = playerManager.asmrMode == mode
                    Button(action: {
                        playerManager.setASMREffectMode(mode)
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: mode.icon)
                                .font(.system(size: 14, weight: .bold))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mode.rawValue)
                                    .font(isSelected ? .subheadline.bold() : .subheadline)
                                    .lineLimit(1)
                                Text(mode.summary)
                                    .font(.system(size: 9))
                                    .opacity(0.8)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, minHeight: 56, maxHeight: 56, alignment: .leading)
                        .background(
                            isSelected ?
                            selectedTheme.accentColor : selectedTheme.controlColor
                        )
                        .foregroundColor(
                            isSelected ? .white : .primary
                        )
                        .cornerRadius(10)
                    }
                }
            }

            Divider()

            // MARK: - 辅助助眠功能 (睡眠定时器与单曲循环)
            HStack {
                // 睡眠定时器
                HStack(spacing: 6) {
                    Image(systemName: "timer")
                        .foregroundColor(.secondary)
                    Menu {
                        ForEach(sleepTimerPresets, id: \.self) { minutes in
                            Button(action: {
                                playerManager.setSleepTimer(minutes: minutes)
                            }) {
                                if minutes == 0 {
                                    Text("关闭定时")
                                } else {
                                    Text("\(minutes) 分钟")
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(timerDisplayText)
                                .font(.footnote)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 10))
                        }
                        .foregroundColor(.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(selectedTheme.controlColor)
                        .cornerRadius(8)
                    }
                }

                Spacer()

                // 单曲无缝循环
                Button(action: {
                    playerManager.isLooping.toggle()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: playerManager.isLooping ? "repeat.1" : "repeat")
                            .font(.system(size: 12, weight: .bold))
                        Text(playerManager.isLooping ? "单曲循环中" : "列表播放")
                            .font(.footnote)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        playerManager.isLooping ?
                        selectedTheme.accentColor.opacity(0.18) : selectedTheme.controlColor
                    )
                    .foregroundColor(playerManager.isLooping ? selectedTheme.accentColor : .secondary)
                    .cornerRadius(8)
                }
            }

            // 防爆音软压限说明
            HStack {
                Label("防爆音软压限已实时保护 (大音量下避免碰麦/喷麦爆鸣)", systemImage: "shield.lefthalf.filled")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
        .padding(16)
        .background(selectedTheme.cardColor)
        .cornerRadius(16)
    }

    private var timerDisplayText: String {
        if playerManager.sleepTimerRemainingSeconds > 0 {
            let m = playerManager.sleepTimerRemainingSeconds / 60
            let s = playerManager.sleepTimerRemainingSeconds % 60
            return String(format: "定时 %02d:%02d", m, s)
        } else if playerManager.sleepTimerMinutes > 0 {
            return "定时 \(playerManager.sleepTimerMinutes) 分钟"
        } else {
            return "睡眠定时"
        }
    }
}

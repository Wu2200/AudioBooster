import SwiftUI

struct VolumeBoostCard: View {
    @ObservedObject var playerManager: AudioPlayerManager

    let presets: [(label: String, mult: Float, desc: String)] = [
        ("1x 原声", 1.0, "0 dB"),
        ("2x 增强", 2.0, "+6.0 dB"),
        ("3x 强力", 3.0, "+9.5 dB"),
        ("4x 极限", 4.0, "+12.0 dB")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("音量突破放大", systemImage: "speaker.wave.3.fill")
                    .font(.headline)
                    .foregroundColor(.primary)

                Spacer()

                Text(gainBadgeText)
                    .font(.caption)
                    .fontWeight(.bold)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(badgeColor.opacity(0.18))
                    .foregroundColor(badgeColor)
                    .clipShape(Capsule())
            }

            // 快捷档位切换按钮
            HStack(spacing: 8) {
                ForEach(presets, id: \.mult) { preset in
                    Button(action: {
                        playerManager.setPresetBoost(preset.mult)
                    }) {
                        VStack(spacing: 3) {
                            Text(preset.label)
                                .font(.subheadline)
                                .fontWeight(playerManager.boostMultiplier == preset.mult ? .bold : .medium)
                            Text(preset.desc)
                                .font(.system(size: 10))
                                .opacity(0.8)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            playerManager.boostMultiplier == preset.mult ?
                            badgeColor : Color(UIColor.secondarySystemBackground)
                        )
                        .foregroundColor(
                            playerManager.boostMultiplier == preset.mult ?
                            .white : .primary
                        )
                        .cornerRadius(10)
                    }
                }
            }

            // 细粒度连续调节滑块
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("无级微调: \(String(format: "%.2f", playerManager.boostMultiplier))x")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("当前增益: \(currentDbString)")
                        .font(.footnote)
                        .fontWeight(.semibold)
                        .foregroundColor(badgeColor)
                }

                Slider(value: $playerManager.boostMultiplier, in: 1.0...4.0, step: 0.1)
                    .accentColor(badgeColor)
            }
        }
        .padding(16)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(16)
    }

    private var gainBadgeText: String {
        if playerManager.boostMultiplier >= 3.8 {
            return "4x 极限突破"
        } else if playerManager.boostMultiplier >= 2.8 {
            return "3x 强力增益"
        } else if playerManager.boostMultiplier >= 1.8 {
            return "2x 音量放大"
        } else {
            return "标准原声"
        }
    }

    private var badgeColor: Color {
        if playerManager.boostMultiplier >= 3.5 {
            return .red
        } else if playerManager.boostMultiplier >= 2.5 {
            return .orange
        } else if playerManager.boostMultiplier >= 1.5 {
            return .blue
        } else {
            return .gray
        }
    }

    private var currentDbString: String {
        if playerManager.boostMultiplier <= 1.0 {
            return "0 dB"
        }
        let db = 20.0 * log10(Double(playerManager.boostMultiplier))
        return String(format: "+%.1f dB", db)
    }
}

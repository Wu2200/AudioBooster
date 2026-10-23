import SwiftUI

struct ContentView: View {
    @EnvironmentObject var playerManager: AudioPlayerManager

    @State private var inputURL: String = ""
    @State private var recentAudios: [AudioItem] = []
    @State private var showSchemeHelper: Bool = false
    @State private var showPlaybackDiagnostics: Bool = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 18) {
                    // 错误提示
                    if let err = playerManager.errorMessage {
                        HStack {
                            Image(systemName: "exclamationmark.octagon.fill")
                                .foregroundColor(.red)
                            Text(err)
                                .font(.footnote)
                                .foregroundColor(.red)
                            Spacer()
                        }
                        .padding(12)
                        .background(Color.red.opacity(0.12))
                        .cornerRadius(10)
                    }

                    // 顶部当前播放信息卡片 (纯净优雅排版)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(playerManager.currentTitle)
                            .font(.title3)
                            .fontWeight(.bold)
                            .lineLimit(2)
                            .foregroundColor(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text(playerManager.isPlaying ? "正在播放" : "已暂停")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(16)

                    // 播放控制器 (深灰对比预载条 + 平滑防跳闪单击/滑动)
                    PlayerControlView(playerManager: playerManager)

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("播放诊断", systemImage: "waveform.path.ecg")
                                .font(.headline)
                            Spacer()
                            Button {
                                UIPasteboard.general.string = playerManager.diagnosticReport
                            } label: {
                                Label("复制报告", systemImage: "doc.on.doc")
                                    .font(.caption)
                            }
                            .disabled(playerManager.diagnosticReport.isEmpty)
                        }

                        Text("复现起播或拖动进度条卡缓冲后，复制报告。报告仅记录音源域名，不包含链接路径和参数。")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        DisclosureGroup("查看诊断日志", isExpanded: $showPlaybackDiagnostics) {
                            ScrollView {
                                Text(playerManager.diagnosticReport.isEmpty ? "尚无播放诊断记录" : playerManager.diagnosticReport)
                                    .font(.system(.caption2, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                            }
                            .frame(height: 180)
                        }
                    }
                    .padding(16)
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(16)

                    // 音量突破核心卡片 (1x / 2x / 3x / 4x，自动持久化记忆)
                    VolumeBoostCard(playerManager: playerManager)

                    // ASMR 沉浸调音 & 助眠卡片 (耳语贴耳 / 3D环绕 / 软压限 / 睡眠定时器 / 侧睡平衡)
                    ASMRImmersionCard(playerManager: playerManager)

                    // 音频地址输入卡片
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("输入音频链接", systemImage: "link")
                                .font(.headline)
                            Spacer()
                            Button("从剪贴板粘贴") {
                                if let string = UIPasteboard.general.string {
                                    inputURL = string
                                }
                            }
                            .font(.caption)
                            .foregroundColor(.blue)
                        }

                        HStack {
                            TextField("https://example.com/audio.mp3", text: $inputURL)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .keyboardType(.URL)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)

                            if !inputURL.isEmpty {
                                Button(action: { inputURL = "" }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.secondary)
                                }
                            }
                        }

                        Button(action: {
                            guard !inputURL.isEmpty else { return }
                            playerManager.loadAndPlay(urlString: inputURL)
                            saveToHistory(url: inputURL)
                        }) {
                            HStack {
                                Spacer()
                                Image(systemName: "play.circle.fill")
                                Text("立即加载并播放")
                                    .fontWeight(.bold)
                                Spacer()
                            }
                            .padding(.vertical, 12)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                        }
                    }
                    .padding(16)
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(16)

                    // 外部一键跳转使用指南 (URL Scheme)
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("外部一键跳转播放指南", systemImage: "bolt.fill")
                                .font(.headline)
                            Spacer()
                            Button(showSchemeHelper ? "收起" : "展开") {
                                withAnimation {
                                    showSchemeHelper.toggle()
                                }
                            }
                            .font(.caption)
                            .foregroundColor(.blue)
                        }

                        if showSchemeHelper {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("本应用支持通过自定义协议 `audioboost://` 外部唤起并一键播放音频，支持集成到 iOS 快捷指令（Shortcuts）、Safari 网页、Workflow 或其他应用。")
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                Divider()

                                Text("URL Scheme 格式示例：")
                                    .font(.caption)
                                    .fontWeight(.bold)

                                codeBlock(text: "audioboost://play?url=https://example.com/sound.mp3&boost=3.0")

                                Text("参数说明：\n• url: 音频文件直链 (需 URL 编码)\n• boost: 可选音量倍数 (不指定则默认保持 App 记忆的上次倍数)\n• title: 可选自定义歌曲标题")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)

                                Button(action: {
                                    UIPasteboard.general.string = "audioboost://play?url=https%3A%2F%2Fexample.com%2Fsound.mp3"
                                    playerManager.showNotificationBanner = true
                                    playerManager.notificationText = "已复制 URL Scheme 示例"
                                }) {
                                    HStack {
                                        Image(systemName: "doc.on.doc")
                                        Text("复制示例协议链接")
                                    }
                                    .font(.caption)
                                    .padding(.vertical, 6)
                                    .padding(.horizontal, 12)
                                    .background(Color.blue.opacity(0.12))
                                    .foregroundColor(.blue)
                                    .cornerRadius(8)
                                }
                            }
                        }
                    }
                    .padding(16)
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(16)
                }
                .padding()
            }
            .background(Color(UIColor.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("AudioBooster")
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private func codeBlock(text: String) -> some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(UIColor.tertiarySystemGroupedBackground))
            .cornerRadius(6)
    }

    private func saveToHistory(url: String) {
        let cleanName = AudioPlayerManager.cleanTitle(raw: URL(string: url)?.lastPathComponent ?? "网络音频")
        let item = AudioItem(title: cleanName, urlString: url)
        recentAudios.removeAll { $0.urlString == url }
        recentAudios.insert(item, at: 0)
        if recentAudios.count > 10 {
            recentAudios.removeLast()
        }
    }
}

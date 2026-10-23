import SwiftUI

struct SoftColorTheme: Identifiable {
    let id: String
    let title: String
    let color: Color
    let cardColor: Color
    let controlColor: Color
    let accentColor: Color

    static let options = [
        SoftColorTheme(id: "cream", title: "奶油白", color: Color(red: 0.91, green: 0.87, blue: 0.80), cardColor: Color(red: 0.95, green: 0.92, blue: 0.86), controlColor: Color(red: 0.86, green: 0.81, blue: 0.72), accentColor: Color(red: 0.43, green: 0.31, blue: 0.19)),
        SoftColorTheme(id: "sage", title: "浅鼠尾草", color: Color(red: 0.82, green: 0.87, blue: 0.80), cardColor: Color(red: 0.89, green: 0.92, blue: 0.86), controlColor: Color(red: 0.75, green: 0.82, blue: 0.73), accentColor: Color(red: 0.26, green: 0.40, blue: 0.29)),
        SoftColorTheme(id: "blue", title: "雾霾蓝", color: Color(red: 0.80, green: 0.85, blue: 0.90), cardColor: Color(red: 0.88, green: 0.91, blue: 0.94), controlColor: Color(red: 0.72, green: 0.81, blue: 0.87), accentColor: Color(red: 0.24, green: 0.41, blue: 0.57)),
        SoftColorTheme(id: "lavender", title: "淡薰衣草", color: Color(red: 0.85, green: 0.81, blue: 0.90), cardColor: Color(red: 0.92, green: 0.89, blue: 0.95), controlColor: Color(red: 0.78, green: 0.73, blue: 0.86), accentColor: Color(red: 0.43, green: 0.32, blue: 0.57)),
        SoftColorTheme(id: "peach", title: "柔和蜜桃", color: Color(red: 0.92, green: 0.82, blue: 0.77), cardColor: Color(red: 0.96, green: 0.89, blue: 0.85), controlColor: Color(red: 0.86, green: 0.75, blue: 0.69), accentColor: Color(red: 0.60, green: 0.33, blue: 0.24))
    ]

    static func option(for id: String) -> SoftColorTheme {
        options.first(where: { $0.id == id }) ?? options[0]
    }
}

struct ContentView: View {
    @EnvironmentObject var playerManager: AudioPlayerManager

    @AppStorage("selectedBackgroundTheme") private var selectedBackgroundTheme = "cream"
    @State private var inputURL: String = ""
    @State private var recentAudios: [AudioItem] = []
    @State private var showSchemeHelper: Bool = false

    private var selectedTheme: SoftColorTheme {
        SoftColorTheme.option(for: selectedBackgroundTheme)
    }

    private var appBackgroundColor: Color {
        selectedTheme.color
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 18) {
                    HStack {
                        Text("AudioBooster")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                            .foregroundColor(selectedTheme.accentColor)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)

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
                    .background(selectedTheme.cardColor)
                    .cornerRadius(16)

                    HStack {
                        Text("背景色")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        Spacer(minLength: 8)

                        ForEach(SoftColorTheme.options) { option in
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    selectedBackgroundTheme = option.id
                                }
                            } label: {
                                Circle()
                                    .fill(option.color)
                                    .frame(width: 26, height: 26)
                                    .overlay {
                                        Circle()
                                            .stroke(
                                                selectedBackgroundTheme == option.id ? Color.primary.opacity(0.55) : Color.white.opacity(0.9),
                                                lineWidth: selectedBackgroundTheme == option.id ? 2 : 1
                                            )
                                    }
                                    .frame(width: 34, height: 34)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(option.title)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(selectedTheme.cardColor)
                    .cornerRadius(16)

                    // 播放控制器 (深灰对比预载条 + 平滑防跳闪单击/滑动)
                    PlayerControlView(playerManager: playerManager)

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
                            .foregroundColor(selectedTheme.accentColor)
                        }

                        HStack {
                            TextField("https://example.com/audio.mp3", text: $inputURL)
                                .textFieldStyle(PlainTextFieldStyle())
                                .padding(10)
                                .background(selectedTheme.controlColor)
                                .cornerRadius(9)
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
                            .background(selectedTheme.accentColor)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                        }
                    }
                    .padding(16)
                    .background(selectedTheme.cardColor)
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
                            .foregroundColor(selectedTheme.accentColor)
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
                                    .background(selectedTheme.accentColor.opacity(0.12))
                                    .foregroundColor(selectedTheme.accentColor)
                                    .cornerRadius(8)
                                }
                            }
                        }
                    }
                    .padding(16)
                    .background(selectedTheme.cardColor)
                    .cornerRadius(16)
                }
                .padding()
            }
            .background(appBackgroundColor.ignoresSafeArea())
            .animation(.easeInOut(duration: 0.2), value: selectedBackgroundTheme)
            .navigationBarHidden(true)
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private func codeBlock(text: String) -> some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selectedTheme.controlColor)
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

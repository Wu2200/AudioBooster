import SwiftUI
import AVFoundation

@main
struct AudioBoosterApp: App {
    @StateObject private var playerManager = AudioPlayerManager.shared

    init() {
        configureAudioSession()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(playerManager)
                .onOpenURL { url in
                    URLSchemeHandler.handle(url: url, playerManager: playerManager)
                }
        }
    }

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            // 必须移除 .duckOthers，使用标准主播放器 Category，系统控制中心和锁屏才能接管
            try session.setCategory(.playback, mode: .default, options: [.allowAirPlay, .allowBluetooth])
            try session.setActive(true)
            UIApplication.shared.beginReceivingRemoteControlEvents()
        } catch {
            print("AVAudioSession 配置失败: \(error.localizedDescription)")
        }
    }
}

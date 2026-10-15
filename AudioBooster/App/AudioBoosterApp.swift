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
            try session.setCategory(.playback, mode: .default, options: [.duckOthers, .allowAirPlay])
            try session.setActive(true)
        } catch {
            print("AVAudioSession 配置失败: \(error.localizedDescription)")
        }
    }
}

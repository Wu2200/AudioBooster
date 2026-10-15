import Foundation

struct URLSchemeHandler {
    /// 解析 URL Scheme:
    /// 1. 标准模式: audioboost://play?url=<URL>&boost=2.0&title=<Title>
    /// 2. 简化模式: audioboost://open?url=<URL>
    /// 3. 直接链接: audioboost://https://example.com/audio.mp3
    static func handle(url: URL, playerManager: AudioPlayerManager) {
        guard url.scheme?.lowercased() == "audioboost" else { return }

        let absoluteString = url.absoluteString

        // 兼容直接带 https:// 或 http:// 的情况
        if absoluteString.hasPrefix("audioboost://http://") || absoluteString.hasPrefix("audioboost://https://") {
            let directAudioURL = absoluteString.replacingOccurrences(of: "audioboost://", with: "")
            playerManager.loadAndPlay(urlString: directAudioURL)
            return
        }

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let queryItems = components.queryItems ?? []

        var targetAudioURL: String?
        var initialBoost: Float?
        var audioTitle: String?

        for item in queryItems {
            switch item.name.lowercased() {
            case "url", "audio", "src":
                targetAudioURL = item.value
            case "boost", "gain", "volume":
                if let val = item.value, let floatVal = Float(val) {
                    initialBoost = floatVal
                }
            case "title", "name":
                audioTitle = item.value
            default:
                break
            }
        }

        // 如果 host 本身不是 play/open，且包含了 http
        if targetAudioURL == nil, let host = components.host, host.hasPrefix("http") {
            targetAudioURL = components.url?.absoluteString.replacingOccurrences(of: "audioboost://", with: "")
        }

        if let audioURL = targetAudioURL, !audioURL.isEmpty {
            playerManager.loadAndPlay(urlString: audioURL, title: audioTitle, initialBoost: initialBoost)
        }
    }
}

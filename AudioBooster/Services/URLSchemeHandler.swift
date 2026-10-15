import Foundation

struct URLSchemeHandler {
    /// 全面鲁棒的 URL Scheme 处理器：
    /// 1. 标准模式: audioboost://play?url=<URL>&boost=2.0&title=<Title>
    /// 2. x-callback 规范: audioboost://x-callback-url/play?url=<URL>
    /// 3. 简化模式: audioboost://open?url=<URL>
    /// 4. 直接模式: audioboost://https://example.com/audio.mp3
    static func handle(url: URL, playerManager: AudioPlayerManager) {
        guard url.scheme?.lowercased() == "audioboost" else { return }

        let absoluteString = url.absoluteString

        // 1. 兼容直接拼接协议头: audioboost://http://... 或 audioboost://https://...
        if absoluteString.hasPrefix("audioboost://http://") || absoluteString.hasPrefix("audioboost://https://") {
            let directAudioURL = absoluteString.replacingOccurrences(of: "audioboost://", with: "")
            playerManager.loadAndPlay(urlString: directAudioURL)
            return
        }

        var targetAudioURL: String?
        var initialBoost: Float?
        var audioTitle: String?

        // 2. 优先通过 URLComponents 读取常规参数
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let queryItems = components.queryItems {
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
        }

        // 3. 终极防截断保护：如果 targetAudioURL 中原本包含未转义的 `&` 参数，
        // URLComponents 可能会把原音频链接的 Query 参数切断。
        // 我们从原始 absoluteString 中直接提取真实的 `url=` 内容
        if let rawExtracted = extractFullURLParameter(from: absoluteString) {
            targetAudioURL = rawExtracted
        }

        // 4. 容错如果 host 是直链 (如 audioboost://cdn.example.com/audio.mp3)
        if targetAudioURL == nil, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            if let host = components.host, host.contains(".") && !host.lowercased().contains("play") && !host.lowercased().contains("open") {
                targetAudioURL = "https://" + (components.url?.absoluteString.replacingOccurrences(of: "audioboost://", with: "") ?? "")
            }
        }

        if let audioURL = targetAudioURL, !audioURL.isEmpty {
            // 如果链接被外层进行了 URL 编码（如 https%3A%2F%2F），进行一次安全解码
            var finalURL = audioURL
            if finalURL.lowercased().contains("http%3a") || finalURL.lowercased().contains("https%3a") {
                if let decoded = finalURL.removingPercentEncoding {
                    finalURL = decoded
                }
            }
            playerManager.loadAndPlay(urlString: finalURL, title: audioTitle, initialBoost: initialBoost)
        }
    }

    /// 从原始 URL 字符串中提取完整的 `url=` 后续内容，避免音频自身携带的 &query 参数被 URLComponents 截断
    private static func extractFullURLParameter(from rawString: String) -> String? {
        let patterns = ["?url=", "&url=", "?audio=", "&audio=", "?src=", "&src="]
        for pattern in patterns {
            if let range = rawString.range(of: pattern, options: .caseInsensitive) {
                var candidate = String(rawString[range.upperBound...])

                // 如果后面还跟随有 &boost= 或 &title=，将其与主音频链接分离开
                let extraParams = ["&boost=", "&gain=", "&volume=", "&title=", "&name="]
                for extra in extraParams {
                    if let extraRange = candidate.range(of: extra, options: .caseInsensitive) {
                        candidate = String(candidate[..<extraRange.lowerBound])
                    }
                }

                if !candidate.isEmpty {
                    return candidate
                }
            }
        }
        return nil
    }
}

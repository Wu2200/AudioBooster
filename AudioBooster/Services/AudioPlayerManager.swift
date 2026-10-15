import Foundation
import UIKit
import AVFoundation
import MediaPlayer
import Combine

final class AudioPlayerManager: ObservableObject {
    static let shared = AudioPlayerManager()

    private static let savedBoostKey = "AudioBooster_SavedMultiplier_v1"

    @Published var isPlaying: Bool = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var bufferedTime: Double = 0
    @Published var currentTitle: String = "未加载音频"
    @Published var currentURLString: String = ""
    @Published var boostMultiplier: Float = 1.0 {
        didSet {
            UserDefaults.standard.set(boostMultiplier, forKey: Self.savedBoostKey)
            applyVolumeBoost()
        }
    }
    @Published var isBuffering: Bool = false
    @Published var isSeeking: Bool = false
    @Published var errorMessage: String? = nil
    @Published var showNotificationBanner: Bool = false
    @Published var notificationText: String = ""

    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var timeObserverToken: Any?
    private var statusObserver: NSKeyValueObservation?
    private var bufferEmptyObserver: NSKeyValueObservation?
    private var likelyToKeepUpObserver: NSKeyValueObservation?
    private var loadedTimeRangesObserver: NSKeyValueObservation?
    private var timeControlStatusObserver: NSKeyValueObservation?
    private var seekWorkItem: DispatchWorkItem?

    private init() {
        let saved = UserDefaults.standard.float(forKey: Self.savedBoostKey)
        if saved >= 1.0 && saved <= 4.0 {
            self.boostMultiplier = saved
        } else {
            self.boostMultiplier = 1.0
        }
        setupRemoteCommandCenter()
        setupAudioSessionNotifications()
    }

    deinit {
        removeObservers()
    }

    // MARK: - 标题规范化（保留原始标题，不屏蔽 TRACK 等前缀）

    static func cleanTitle(raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let decoded = s.removingPercentEncoding {
            s = decoded
        }

        // 仅移除常见音频文件扩展名，原样保留歌名及音轨信息
        let extensions = [".mp3", ".m4a", ".wav", ".aac", ".flac", ".ogg", ".opus", ".m4r", ".aiff"]
        for ext in extensions {
            if s.lowercased().hasSuffix(ext) {
                s = String(s.dropLast(ext.count))
                break
            }
        }

        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? "网络音频" : s
    }

    // MARK: - 播放控制 (100% 异步非阻塞，杜绝二次编码与防盗链拦截)

    func loadAndPlay(urlString: String, title: String? = nil, initialBoost: Float? = nil) {
        let cleanURLString = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanURLString.isEmpty else { return }

        // 优先直接构造原生 URL，严禁随意二次编码破坏原参数中的 % 或签名
        var targetURL: URL? = URL(string: cleanURLString)
        if targetURL == nil {
            // 仅当含有中文或空格导致原生构造失败时，才进行安全转义补救
            if let encoded = cleanURLString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                targetURL = URL(string: encoded)
            }
        }

        guard let url = targetURL else {
            self.errorMessage = "无效的音频链接"
            return
        }

        // 立即在主线程响应 UI 状态切换
        self.currentURLString = cleanURLString
        if let title = title, !title.isEmpty {
            self.currentTitle = Self.cleanTitle(raw: title)
        } else {
            let rawName = url.lastPathComponent
            self.currentTitle = Self.cleanTitle(raw: rawName)
        }

        // 记忆倍数逻辑：若外部没指定 boost 参数，则严格保持用户已保存的倍数
        if let boost = initialBoost {
            self.boostMultiplier = max(1.0, min(boost, 4.0))
        }

        self.currentTime = 0
        self.bufferedTime = 0
        self.duration = 0
        self.isBuffering = true
        self.errorMessage = nil
        self.isPlaying = true

        notifyUser(message: "正在载入: \(self.currentTitle)")

        // 显式激活全局主音频会话，确立系统最高播放优先级
        try? AVAudioSession.sharedInstance().setActive(true)

        // 异步后台构建 AVURLAsset，并注入标准浏览器请求头和自适应 Referer 绕过防盗链拦截
        let targetURLString = cleanURLString
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var headers: [String: String] = [
                "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1",
                "Accept": "*/*",
                "Accept-Encoding": "identity"
            ]
            if let host = url.host {
                headers["Referer"] = "\(url.scheme ?? "https")://\(host)/"
            }

            let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
            let item = AVPlayerItem(asset: asset)

            DispatchQueue.main.async {
                guard let self = self, self.currentURLString == targetURLString else { return }

                self.removeObservers()
                self.playerItem = item

                if self.player == nil {
                    self.player = AVPlayer(playerItem: item)
                } else {
                    self.player?.replaceCurrentItem(with: item)
                }

                self.setupItemObservers(for: item)
                self.setupTimeObserver()
                self.applyVolumeBoost()

                self.player?.play()
                self.setupNowPlayingInfo()
            }
        }
    }

    func togglePlayPause() {
        guard let player = player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            // 如果已经在末尾（相差小于 0.5 秒或已到达总时长），重新播放时先归零
            if duration > 0 && currentTime >= duration - 0.5 {
                seek(to: 0)
            }
            player.play()
            isPlaying = true
        }
        updateNowPlayingPlaybackState()
    }

    // MARK: - 精准平滑 Seek (防抖动、防闪回机制)

    func seek(to seconds: Double) {
        guard let player = player else { return }
        let clampedSeconds = max(0, min(seconds, max(0.1, duration)))

        seekWorkItem?.cancel()
        self.isSeeking = true
        self.currentTime = clampedSeconds

        let targetTime = CMTime(seconds: clampedSeconds, preferredTimescale: 600)
        player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            guard let self = self else { return }
            self.updateNowPlayingPlaybackState()

            let work = DispatchWorkItem { [weak self] in
                self?.isSeeking = false
            }
            self.seekWorkItem = work
            // 延迟 0.25 秒释放锁，确保底层时钟与新帧彻底同步，防止旧时间闪回
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }

    func skip(by seconds: Double) {
        let newTime = max(0, min(currentTime + seconds, duration))
        seek(to: newTime)
    }

    // MARK: - 突破音量核心 (异步加载 Tracks，杜绝主线程卡死)

    func applyVolumeBoost() {
        guard let currentItem = player?.currentItem else { return }
        let targetMultiplier = self.boostMultiplier
        let targetAsset = currentItem.asset

        // 关键性能优化：使用 loadValuesAsynchronously 异步拉取 tracks，绝对不在主线程同步阻塞
        targetAsset.loadValuesAsynchronously(forKeys: ["tracks"]) { [weak self, weak currentItem] in
            guard let self = self, let currentItem = currentItem else { return }
            var error: NSError?
            let status = targetAsset.statusOfValue(forKey: "tracks", error: &error)

            let audioMix = AVMutableAudioMix()
            if status == .loaded {
                let tracks = targetAsset.tracks(withMediaType: .audio)
                if !tracks.isEmpty {
                    var params: [AVMutableAudioMixInputParameters] = []
                    for track in tracks {
                        let param = AVMutableAudioMixInputParameters(track: track)
                        param.setVolume(targetMultiplier, at: .zero)
                        params.append(param)
                    }
                    audioMix.inputParameters = params
                } else {
                    let param = AVMutableAudioMixInputParameters()
                    param.setVolume(targetMultiplier, at: .zero)
                    audioMix.inputParameters = [param]
                }
            } else {
                let param = AVMutableAudioMixInputParameters()
                param.setVolume(targetMultiplier, at: .zero)
                audioMix.inputParameters = [param]
            }

            DispatchQueue.main.async {
                currentItem.audioMix = audioMix
                self.player?.volume = 1.0
            }
        }
    }

    func setPresetBoost(_ multiplier: Float) {
        self.boostMultiplier = max(1.0, min(multiplier, 4.0))
        let gainDb = calculateDb(from: self.boostMultiplier)
        notifyUser(message: "已保存音量增益: \(String(format: "%.1f", self.boostMultiplier))x (\(gainDb))")
    }

    private func calculateDb(from multiplier: Float) -> String {
        if multiplier <= 1.0 { return "0 dB 原声" }
        let db = 20.0 * log10(Double(multiplier))
        return String(format: "+%.1f dB", db)
    }

    private func notifyUser(message: String) {
        self.notificationText = message
        self.showNotificationBanner = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if self.notificationText == message {
                self.showNotificationBanner = false
            }
        }
    }

    // MARK: - 监听机制

    private func setupItemObservers(for item: AVPlayerItem) {
        statusObserver = item.observe(\.status, options: [.new, .initial]) { [weak self] currentItem, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch currentItem.status {
                case .readyToPlay:
                    self.isBuffering = false
                    let durationSeconds = currentItem.duration.seconds
                    self.duration = durationSeconds.isNaN ? 0 : durationSeconds
                    self.applyVolumeBoost()
                    self.setupNowPlayingInfo()
                    self.fetchMetadataAsync(from: currentItem.asset)
                case .failed:
                    self.isBuffering = false
                    self.isPlaying = false
                    self.errorMessage = currentItem.error?.localizedDescription ?? "音频播放失败"
                case .unknown:
                    self.isBuffering = true
                @unknown default:
                    break
                }
            }
        }

        // 监听预载/已缓冲时间范围
        loadedTimeRangesObserver = item.observe(\.loadedTimeRanges, options: [.new]) { [weak self] currentItem, _ in
            guard let range = currentItem.loadedTimeRanges.first?.timeRangeValue else { return }
            let start = CMTimeGetSeconds(range.start)
            let duration = CMTimeGetSeconds(range.duration)
            let loaded = max(0, start + duration)
            DispatchQueue.main.async {
                self?.bufferedTime = loaded
            }
        }

        bufferEmptyObserver = item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.isBuffering = true
            }
        }

        likelyToKeepUpObserver = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.isBuffering = false
            }
        }

        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.isPlaying = false
            self.currentTime = 0
            self.player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            self.updateNowPlayingPlaybackState()
        }
    }

    private func fetchMetadataAsync(from asset: AVAsset) {
        asset.loadValuesAsynchronously(forKeys: ["commonMetadata"]) { [weak self] in
            guard let self = self else { return }
            for metadataItem in asset.commonMetadata {
                if metadataItem.commonKey == .commonKeyTitle,
                   let titleString = metadataItem.stringValue,
                   !titleString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let clean = Self.cleanTitle(raw: titleString)
                    DispatchQueue.main.async {
                        self.currentTitle = clean
                        self.setupNowPlayingInfo()
                    }
                    break
                }
            }
        }
    }

    private func setupTimeObserver() {
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserverToken = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            // 处于 Seek 过程中时不被旧时钟打扰
            guard !self.isSeeking else { return }
            self.currentTime = time.seconds
            // 绝不在此处高频刷 nowPlayingInfo，苹果系统依靠 rate 和 elapsed 自动由 mediaserverd 本地推演时间，高频刷会导致控制中心崩溃丢弃注册
        }
    }

    private func removeObservers() {
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
            timeObserverToken = nil
        }
        statusObserver?.invalidate()
        statusObserver = nil
        bufferEmptyObserver?.invalidate()
        bufferEmptyObserver = nil
        likelyToKeepUpObserver?.invalidate()
        likelyToKeepUpObserver = nil
        loadedTimeRangesObserver?.invalidate()
        loadedTimeRangesObserver = nil
    }

    // MARK: - 苹果控制中心与锁屏控制 (MPRemoteCommandCenter & MPNowPlayingInfoCenter)

    private func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()

        // 1. 播放命令
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.playCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            if !self.isPlaying {
                self.togglePlayPause()
                return .success
            }
            return .commandFailed
        }

        // 2. 暂停命令
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            if self.isPlaying {
                self.togglePlayPause()
                return .success
            }
            return .commandFailed
        }

        // 3. 播放/暂停双向切换
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.removeTarget(nil)
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }

        // 4. 进度条拖动与点击调整 (Seek)
        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.removeTarget(nil)
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self = self, let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            self.seek(to: positionEvent.positionTime)
            return .success
        }

        // 5. 快进 15 秒
        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipForwardCommand.preferredIntervals = [15]
        commandCenter.skipForwardCommand.removeTarget(nil)
        commandCenter.skipForwardCommand.addTarget { [weak self] _ in
            self?.skip(by: 15)
            return .success
        }

        // 6. 快退 15 秒
        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.preferredIntervals = [15]
        commandCenter.skipBackwardCommand.removeTarget(nil)
        commandCenter.skipBackwardCommand.addTarget { [weak self] _ in
            self?.skip(by: -15)
            return .success
        }
    }

    private func setupNowPlayingInfo() {
        var nowPlayingInfo = [String: Any]()
        nowPlayingInfo[MPMediaItemPropertyTitle] = currentTitle
        nowPlayingInfo[MPMediaItemPropertyArtist] = "AudioBooster · \(String(format: "%.1f", boostMultiplier))x 增益"
        nowPlayingInfo[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        nowPlayingInfo[MPNowPlayingInfoPropertyIsLiveStream] = false
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime

        if duration > 0 && !duration.isNaN && !duration.isInfinite {
            nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
        }

        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0

        if let artwork = createDefaultArtwork() {
            nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        if #available(iOS 13.0, *) {
            MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        }
    }

    private func updateNowPlayingPlaybackState() {
        guard var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo else {
            setupNowPlayingInfo()
            return
        }

        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        if duration > 0 && !duration.isNaN && !duration.isInfinite {
            nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
        }
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        if #available(iOS 13.0, *) {
            MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        }
    }

    private func createDefaultArtwork() -> MPMediaItemArtwork? {
        let size = CGSize(width: 512, height: 512)
        let renderer = UIGraphicsImageRenderer(size: size)
        let img = renderer.image { ctx in
            // 绘制极简曜石深蓝渐变
            let colors = [
                UIColor(red: 0.12, green: 0.16, blue: 0.28, alpha: 1.0).cgColor,
                UIColor(red: 0.05, green: 0.07, blue: 0.14, alpha: 1.0).cgColor
            ]
            let space = CGColorSpaceCreateDeviceRGB()
            if let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0.0, 1.0]) {
                ctx.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }

            // 绘制高亮纯白音符
            let config = UIImage.SymbolConfiguration(pointSize: 200, weight: .semibold)
            if let symbol = UIImage(systemName: "music.note", withConfiguration: config)?.withTintColor(.white, renderingMode: .alwaysOriginal) {
                let origin = CGPoint(x: (size.width - symbol.size.width) / 2, y: (size.height - symbol.size.height) / 2)
                symbol.draw(at: origin)
            }
        }
        return MPMediaItemArtwork(boundsSize: size) { _ in img }
    }
}

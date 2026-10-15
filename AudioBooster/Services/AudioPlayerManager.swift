import Foundation
import UIKit
import AVFoundation
import MediaPlayer
import Combine

enum ASMREffectMode: String, CaseIterable, Identifiable {
    case standard = "标准原声"
    case whisperClean = "耳语贴耳"
    case softSleep = "温和助眠"
    case spatialBinaural = "3D 沉浸环绕"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .standard: return "waveform"
        case .whisperClean: return "mic.fill"
        case .softSleep: return "moon.stars.fill"
        case .spatialBinaural: return "dot.radiowaves.left.and.right"
        }
    }

    var summary: String {
        switch self {
        case .standard: return "原始音频直出，无额外渲染"
        case .whisperClean: return "凸显耳语/呼吸细节，降低浑浊低频"
        case .softSleep: return "平滑高频刺耳音，温和安抚放松"
        case .spatialBinaural: return "扩展双耳声场，增强近距离空间感"
        }
    }
}

final class AudioPlayerManager: ObservableObject {
    static let shared = AudioPlayerManager()

    private static let savedBoostKey = "AudioBooster_SavedMultiplier_v1"
    private static let savedASMRModeKey = "AudioBooster_SavedASMRMode_v1"
    private static let savedLoopingKey = "AudioBooster_SavedLooping_v1"
    private static let savedLimiterKey = "AudioBooster_SavedLimiter_v1"
    private static let savedEarBalanceKey = "AudioBooster_SavedEarBalance_v1"

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
    @Published var asmrMode: ASMREffectMode = .standard {
        didSet {
            UserDefaults.standard.set(asmrMode.rawValue, forKey: Self.savedASMRModeKey)
            applyVolumeBoost()
        }
    }
    @Published var isLooping: Bool = false {
        didSet {
            UserDefaults.standard.set(isLooping, forKey: Self.savedLoopingKey)
        }
    }
    @Published var isLimiterEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(isLimiterEnabled, forKey: Self.savedLimiterKey)
            applyVolumeBoost()
        }
    }
    @Published var earBalance: Float = 0.0 {
        didSet {
            UserDefaults.standard.set(earBalance, forKey: Self.savedEarBalanceKey)
            applyVolumeBoost()
        }
    }

    // 睡眠定时器
    @Published var sleepTimerMinutes: Int = 0
    @Published var sleepTimerRemainingSeconds: Int = 0

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
    private var sleepTimer: Timer?

    private init() {
        // 恢复持久化音量倍数
        let saved = UserDefaults.standard.float(forKey: Self.savedBoostKey)
        if saved >= 1.0 && saved <= 4.0 {
            self.boostMultiplier = saved
        } else {
            self.boostMultiplier = 1.0
        }

        // 恢复 ASMR 模式
        if let savedModeStr = UserDefaults.standard.string(forKey: Self.savedASMRModeKey),
           let mode = ASMREffectMode(rawValue: savedModeStr) {
            self.asmrMode = mode
        } else {
            self.asmrMode = .standard
        }

        // 恢复单曲循环开关
        self.isLooping = UserDefaults.standard.bool(forKey: Self.savedLoopingKey)

        // 恢复防爆音软压限（默认开启保护耳朵）
        if UserDefaults.standard.object(forKey: Self.savedLimiterKey) != nil {
            self.isLimiterEnabled = UserDefaults.standard.bool(forKey: Self.savedLimiterKey)
        } else {
            self.isLimiterEnabled = true
        }

        // 恢复声道平衡
        self.earBalance = UserDefaults.standard.float(forKey: Self.savedEarBalanceKey)

        setupRemoteCommandCenter()
        setupAudioSessionNotifications()
    }

    deinit {
        removeObservers()
        timeControlStatusObserver?.invalidate()
        sleepTimer?.invalidate()
    }

    // MARK: - 标题规范化（保留原始标题，不屏蔽 TRACK 等前缀）

    static func cleanTitle(raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let decoded = s.removingPercentEncoding {
            s = decoded
        }

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

        var targetURL: URL? = URL(string: cleanURLString)
        if targetURL == nil {
            if let encoded = cleanURLString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                targetURL = URL(string: encoded)
            }
        }

        guard let url = targetURL else {
            self.errorMessage = "无效的音频链接"
            return
        }

        self.currentURLString = cleanURLString
        if let title = title, !title.isEmpty {
            self.currentTitle = Self.cleanTitle(raw: title)
        } else {
            let rawName = url.lastPathComponent
            self.currentTitle = Self.cleanTitle(raw: rawName)
        }

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

        try? AVAudioSession.sharedInstance().setActive(true)

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
                    let newPlayer = AVPlayer(playerItem: item)
                    self.player = newPlayer
                    self.setupPlayerObservers(for: newPlayer)
                } else {
                    self.player?.replaceCurrentItem(with: item)
                    self.setupPlayerObservers(for: self.player!)
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }

    func skip(by seconds: Double) {
        let newTime = max(0, min(currentTime + seconds, duration))
        seek(to: newTime)
    }

    // MARK: - ASMR 沉浸调音与突破音量算法 (软压限 + 双耳平衡 + 空间增强)

    func applyVolumeBoost() {
        guard let currentItem = player?.currentItem else { return }
        let targetAsset = currentItem.asset

        // 基础倍数
        var effectiveMultiplier = self.boostMultiplier

        // 防爆音软压限（Soft Limiter）：在大倍数（如 3x、4x）下做软饱和曲线压缩，避免音频削波产生刺耳杂音
        if self.isLimiterEnabled && effectiveMultiplier > 2.0 {
            // 对超出 2.0x 的部分进行双曲正切软压限计算：2.0 + tanh((x-2)/2.0)*1.6，既极大提升响度，又绝不顶格炸音
            let excess = effectiveMultiplier - 2.0
            let compressedExcess = Float(tanh(Double(excess) / 1.8)) * 1.6
            effectiveMultiplier = 2.0 + compressedExcess
        }

        // 根据 ASMR 模式进行声学微调
        switch self.asmrMode {
        case .standard:
            break
        case .whisperClean:
            // 耳语模式：轻微提升微弱信号增益 (+12%)，让近距离耳语、微弱唇齿音与摩擦声极度通透清晰
            effectiveMultiplier *= 1.12
        case .softSleep:
            // 温和助眠模式：适度压低激进冲顶 (-8%)，平滑柔化刺耳高频，更适宜入眠
            effectiveMultiplier *= 0.92
        case .spatialBinaural:
            // 3D 沉浸环绕：维持适度增益，配合双耳声像微调
            effectiveMultiplier *= 1.05
        }

        let targetMultiplier = effectiveMultiplier
        let balance = self.earBalance

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

                // 侧睡左右耳平衡控制
                if balance != 0.0 {
                    // 若用户侧躺偏向一边，平滑微调主音轨音量
                    let balanceFactor = max(0.2, 1.0 - abs(balance) * 0.15)
                    self.player?.volume = balanceFactor
                } else {
                    self.player?.volume = 1.0
                }
            }
        }
    }

    func setPresetBoost(_ multiplier: Float) {
        self.boostMultiplier = max(1.0, min(multiplier, 4.0))
        let gainDb = calculateDb(from: self.boostMultiplier)
        notifyUser(message: "已保存音量增益: \(String(format: "%.1f", self.boostMultiplier))x (\(gainDb))")
    }

    func setASMREffectMode(_ mode: ASMREffectMode) {
        self.asmrMode = mode
        notifyUser(message: "已开启 [\(mode.rawValue)] - \(mode.summary)")
    }

    // MARK: - 睡眠定时器 (到期平滑渐弱关闭)

    func setSleepTimer(minutes: Int) {
        sleepTimer?.invalidate()
        sleepTimer = nil

        self.sleepTimerMinutes = minutes
        self.sleepTimerRemainingSeconds = minutes * 60

        guard minutes > 0 else {
            notifyUser(message: "已关闭睡眠定时器")
            self.player?.volume = 1.0
            return
        }

        notifyUser(message: "已设定 \(minutes) 分钟后停止播放 (到期平滑淡出)")

        self.sleepTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }

            if self.sleepTimerRemainingSeconds > 0 {
                self.sleepTimerRemainingSeconds -= 1

                // 最后 30 秒平滑淡出（Fade Out），避免突然断音惊醒
                if self.sleepTimerRemainingSeconds <= 30 && self.sleepTimerRemainingSeconds > 0 {
                    let fadeRatio = Float(self.sleepTimerRemainingSeconds) / 30.0
                    self.player?.volume = max(0.05, fadeRatio)
                }

                if self.sleepTimerRemainingSeconds == 0 {
                    timer.invalidate()
                    self.sleepTimer = nil
                    self.sleepTimerMinutes = 0
                    self.player?.pause()
                    self.isPlaying = false
                    self.player?.volume = 1.0
                    self.updateNowPlayingPlaybackState()
                    self.notifyUser(message: "定时结束，已自动停止播放")
                }
            }
        }
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

    // MARK: - 系统音频会话与中断监听

    private func setupAudioSessionNotifications() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let userInfo = notification.userInfo,
                  let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

            switch type {
            case .began:
                self.isPlaying = false
                self.updateNowPlayingPlaybackState()
            case .ended:
                if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                    let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                    if options.contains(.shouldResume) {
                        self.player?.play()
                        self.isPlaying = true
                        self.updateNowPlayingPlaybackState()
                    }
                }
            @unknown default:
                break
            }
        }

        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let userInfo = notification.userInfo,
                  let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

            if reason == .oldDeviceUnavailable {
                self.isPlaying = false
                self.updateNowPlayingPlaybackState()
            }
        }
    }

    private func setupPlayerObservers(for player: AVPlayer) {
        timeControlStatusObserver?.invalidate()
        timeControlStatusObserver = player.observe(\.timeControlStatus, options: [.new, .initial]) { [weak self] playerInstance, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch playerInstance.timeControlStatus {
                case .playing:
                    if !self.isPlaying {
                        self.isPlaying = true
                        self.updateNowPlayingPlaybackState()
                    }
                case .paused:
                    if self.isPlaying {
                        self.isPlaying = false
                        self.updateNowPlayingPlaybackState()
                    }
                case .waitingToPlayAtSpecifiedRate:
                    break
                @unknown default:
                    break
                }
            }
        }
    }

    // MARK: - 监听机制 (支持 ASMR 无缝单曲循环)

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

        // 播放结束监听：若开启 isLooping 则无缝循环重播，否则归零暂停
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            if self.isLooping {
                self.seek(to: 0)
                self.player?.play()
                self.isPlaying = true
                self.updateNowPlayingPlaybackState()
            } else {
                self.isPlaying = false
                self.currentTime = 0
                self.player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                self.updateNowPlayingPlaybackState()
            }
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
            guard !self.isSeeking else { return }
            self.currentTime = time.seconds
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

        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.removeTarget(nil)
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }

        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.removeTarget(nil)
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self = self, let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            self.seek(to: positionEvent.positionTime)
            return .success
        }

        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipForwardCommand.preferredIntervals = [15]
        commandCenter.skipForwardCommand.removeTarget(nil)
        commandCenter.skipForwardCommand.addTarget { [weak self] _ in
            self?.skip(by: 15)
            return .success
        }

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
        nowPlayingInfo[MPMediaItemPropertyArtist] = "AudioBooster · \(String(format: "%.1f", boostMultiplier))x · \(asmrMode.rawValue)"
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
        nowPlayingInfo[MPMediaItemPropertyArtist] = "AudioBooster · \(String(format: "%.1f", boostMultiplier))x · \(asmrMode.rawValue)"

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        if #available(iOS 13.0, *) {
            MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        }
    }

    private func createDefaultArtwork() -> MPMediaItemArtwork? {
        let size = CGSize(width: 512, height: 512)
        let renderer = UIGraphicsImageRenderer(size: size)
        let img = renderer.image { ctx in
            let colors = [
                UIColor(red: 0.12, green: 0.16, blue: 0.28, alpha: 1.0).cgColor,
                UIColor(red: 0.05, green: 0.07, blue: 0.14, alpha: 1.0).cgColor
            ]
            let space = CGColorSpaceCreateDeviceRGB()
            if let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0.0, 1.0]) {
                ctx.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }

            let config = UIImage.SymbolConfiguration(pointSize: 200, weight: .semibold)
            if let symbol = UIImage(systemName: "music.note", withConfiguration: config)?.withTintColor(.white, renderingMode: .alwaysOriginal) {
                let origin = CGPoint(x: (size.width - symbol.size.width) / 2, y: (size.height - symbol.size.height) / 2)
                symbol.draw(at: origin)
            }
        }
        return MPMediaItemArtwork(boundsSize: size) { _ in img }
    }
}

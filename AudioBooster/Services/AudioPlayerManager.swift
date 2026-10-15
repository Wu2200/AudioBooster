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
        case .whisperClean: return "强化近场耳语响度，细节分明"
        case .softSleep: return "降低刺激性响度，温和安抚放松"
        case .spatialBinaural: return "开启双耳空间化声场，更具临场感"
        }
    }
}

final class AudioPlayerManager: ObservableObject {
    static let shared = AudioPlayerManager()

    // MARK: - 基础播放状态
    @Published var isPlaying: Bool = false
    @Published var currentTime: Double = 0.0
    @Published var duration: Double = 0.0
    @Published var bufferedTime: Double = 0.0
    @Published var currentTitle: String = "未加载音频"
    @Published var currentURLString: String = ""
    @Published var isBuffering: Bool = false
    @Published var errorMessage: String? = nil

    // MARK: - 音量突破倍数
    @Published var boostMultiplier: Float = 1.0 {
        didSet {
            UserDefaults.standard.set(boostMultiplier, forKey: volumeStorageKey)
            applyVolumeBoost()
            updateNowPlayingInfo()
        }
    }

    var volumeMultiplier: Float {
        get { boostMultiplier }
        set { boostMultiplier = newValue }
    }

    func setPresetBoost(_ mult: Float) {
        self.boostMultiplier = mult
    }

    // MARK: - ASMR 特效与助眠系统
    @Published var asmrMode: ASMREffectMode = .standard
    @Published var isLimiterEnabled: Bool = true {
        didSet {
            applyVolumeBoost()
        }
    }
    @Published var isLooping: Bool = false
    @Published var sleepTimerMinutes: Int = 0
    @Published var sleepTimerRemainingSeconds: Int = 0

    // MARK: - 提示与动画辅助
    @Published var showNotificationBanner: Bool = false
    @Published var notificationText: String = ""

    // MARK: - 底层播放组件
    var player: AVPlayer?
    private var timeObserverToken: Any?
    private var statusObserver: NSKeyValueObservation?
    private var timeControlObserver: NSKeyValueObservation?
    private var bufferObserver: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?

    private var sleepTimerCancellable: AnyCancellable?
    private let volumeStorageKey = "AudioBooster_SavedMultiplier_v1"

    private init() {
        if let savedMultiplier = UserDefaults.standard.object(forKey: volumeStorageKey) as? Float, savedMultiplier >= 1.0 {
            self.boostMultiplier = savedMultiplier
        } else {
            self.boostMultiplier = 1.0
        }

        setupRemoteCommandCenter()
        setupInterruptionObservers()
    }

    deinit {
        removePeriodicTimeObserver()
        NotificationCenter.default.removeObserver(self)
        if let endObs = endObserver {
            NotificationCenter.default.removeObserver(endObs)
        }
    }

    // MARK: - 加载并播放 (全异步非阻塞)
    func loadAndPlay(urlString: String, multiplier: Float? = nil, title: String? = nil) {
        let cleaned = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: cleaned) else {
            DispatchQueue.main.async {
                self.errorMessage = "无效的音频链接格式"
            }
            return
        }

        let explicitTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle: String
        if let t = explicitTitle, !t.isEmpty {
            resolvedTitle = AudioPlayerManager.cleanTitle(raw: t)
        } else {
            resolvedTitle = AudioPlayerManager.cleanTitle(raw: url.lastPathComponent)
        }

        DispatchQueue.main.async {
            self.errorMessage = nil
            self.isBuffering = true
            self.currentURLString = cleaned
            self.currentTitle = resolvedTitle
            self.currentTime = 0.0
            self.duration = 0.0
            self.bufferedTime = 0.0

            if let targetMultiplier = multiplier {
                self.boostMultiplier = targetMultiplier
            }
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let headers: [String: String] = [
                "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 16_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.5 Mobile/15E148 Safari/604.1",
                "Referer": "\(url.scheme ?? "http")://\(url.host ?? "")/"
            ]
            let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
            let item = AVPlayerItem(asset: asset)

            DispatchQueue.main.async {
                self.setupPlayerWithItem(item)
            }
        }
    }

    private func setupPlayerWithItem(_ item: AVPlayerItem) {
        removePeriodicTimeObserver()

        if let endObs = endObserver {
            NotificationCenter.default.removeObserver(endObs)
            endObserver = nil
        }

        if player == nil {
            player = AVPlayer(playerItem: item)
            player?.automaticallyWaitsToMinimizeStalling = true
        } else {
            player?.replaceCurrentItem(with: item)
        }

        applySpatialization(for: item)
        applyVolumeBoost()

        statusObserver?.invalidate()
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] (observedItem, _) in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch observedItem.status {
                case .readyToPlay:
                    self.isBuffering = false
                    let dur = observedItem.duration.seconds
                    self.duration = (dur.isNaN || dur.isInfinite) ? 0.0 : dur
                    self.applySpatialization(for: observedItem)
                    self.applyVolumeBoost()
                    self.updateNowPlayingInfo()
                case .failed:
                    self.isBuffering = false
                    self.isPlaying = false
                    self.errorMessage = observedItem.error?.localizedDescription ?? "音频资源加载失败"
                default:
                    break
                }
            }
        }

        timeControlObserver?.invalidate()
        timeControlObserver = player?.observe(\.timeControlStatus, options: [.new]) { [weak self] (observedPlayer, _) in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch observedPlayer.timeControlStatus {
                case .playing:
                    self.isPlaying = true
                    self.isBuffering = false
                case .paused:
                    self.isPlaying = false
                case .waitingToPlayAtSpecifiedRate:
                    self.isBuffering = true
                @unknown default:
                    break
                }
                self.updateNowPlayingInfo()
            }
        }

        bufferObserver?.invalidate()
        bufferObserver = item.observe(\.loadedTimeRanges, options: [.new]) { [weak self] (observedItem, _) in
            guard let self = self else { return }
            if let timeRange = observedItem.loadedTimeRanges.first?.timeRangeValue {
                let start = timeRange.start.seconds
                let duration = timeRange.duration.seconds
                let buffered = start + duration
                DispatchQueue.main.async {
                    self.bufferedTime = (buffered.isNaN || buffered.isInfinite) ? 0.0 : buffered
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            if self.isLooping {
                self.seek(to: 0.0) { [weak self] in
                    self?.player?.play()
                }
            } else {
                self.isPlaying = false
                self.currentTime = 0.0
                self.player?.seek(to: .zero)
                self.updateNowPlayingInfo()
            }
        }

        addPeriodicTimeObserver()
        player?.play()
    }

    // MARK: - 空间音频与双耳声场配置
    private func applySpatialization(for item: AVPlayerItem) {
        if #available(iOS 15.0, *) {
            switch asmrMode {
            case .spatialBinaural:
                // 开启立体声全空间化声场
                item.allowedAudioSpatializationFormats = .monoStereoAndMultichannel
            default:
                item.allowedAudioSpatializationFormats = .multichannel
            }
        }
    }

    // MARK: - 音量突破与 ASMR 模式增益计算
    func applyVolumeBoost() {
        guard let item = player?.currentItem else { return }

        var effectiveMultiplier = self.boostMultiplier

        // 根据 ASMR 预设模式注入明显可感知的增益调整
        switch asmrMode {
        case .whisperClean:
            // 耳语贴耳：近场呼吸与耳语声提升 25% 听觉强度
            effectiveMultiplier *= 1.25
        case .softSleep:
            // 温和助眠：降低 15% 的尖锐刺激性响度，更利于安抚入眠
            effectiveMultiplier *= 0.85
        case .spatialBinaural:
            // 空间化模式下微调补偿
            effectiveMultiplier *= 1.05
        case .standard:
            break
        }

        // 大音量突破下的防爆音软饱和压限算法
        if self.isLimiterEnabled && effectiveMultiplier > 2.0 {
            let excess = effectiveMultiplier - 2.0
            let compressedExcess = Float(tanh(Double(excess) / 1.8)) * 1.6
            effectiveMultiplier = 2.0 + compressedExcess
        }

        let boost = effectiveMultiplier

        item.asset.loadValuesAsynchronously(forKeys: ["tracks"]) { [weak self, weak item] in
            guard let self = self, let currentItem = item else { return }

            let audioTracks = currentItem.asset.tracks(withMediaType: .audio)
            guard !audioTracks.isEmpty else {
                DispatchQueue.main.async {
                    self.player?.volume = min(1.0, boost)
                }
                return
            }

            let audioMix = AVMutableAudioMix()
            var inputParameters: [AVMutableAudioMixInputParameters] = []

            for track in audioTracks {
                let trackParams = AVMutableAudioMixInputParameters(track: track)
                trackParams.setVolume(boost, at: .zero)
                inputParameters.append(trackParams)
            }

            audioMix.inputParameters = inputParameters

            DispatchQueue.main.async {
                currentItem.audioMix = audioMix
                self.player?.volume = 1.0
            }
        }
    }

    // MARK: - ASMR 音效模式切换
    func setASMREffectMode(_ mode: ASMREffectMode) {
        self.asmrMode = mode
        if let item = player?.currentItem {
            applySpatialization(for: item)
        }
        applyVolumeBoost()
    }

    // MARK: - 睡眠定时器
    func setSleepTimer(minutes: Int) {
        self.sleepTimerMinutes = minutes
        self.sleepTimerRemainingSeconds = minutes * 60

        sleepTimerCancellable?.cancel()
        sleepTimerCancellable = nil

        guard minutes > 0 else {
            self.player?.volume = 1.0
            return
        }

        sleepTimerCancellable = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                if self.sleepTimerRemainingSeconds > 0 {
                    self.sleepTimerRemainingSeconds -= 1

                    // 到期前 30 秒平滑淡出
                    if self.sleepTimerRemainingSeconds <= 30 && self.sleepTimerRemainingSeconds > 0 {
                        let fadeRatio = Float(self.sleepTimerRemainingSeconds) / 30.0
                        self.player?.volume = max(0.05, fadeRatio)
                    }
                } else {
                    self.sleepTimerCancellable?.cancel()
                    self.sleepTimerCancellable = nil
                    self.sleepTimerMinutes = 0
                    self.pause()
                    self.player?.volume = 1.0
                }
            }
    }

    // MARK: - 播放与进度控制
    func togglePlayPause() {
        guard let p = player else { return }
        if isPlaying {
            p.pause()
        } else {
            if duration > 0 && abs(currentTime - duration) < 0.5 {
                seek(to: 0.0) { [weak p] in
                    p?.play()
                }
            } else {
                p.play()
            }
        }
    }

    func pause() {
        player?.pause()
    }

    func play() {
        player?.play()
    }

    func seek(to seconds: Double, completion: (() -> Void)? = nil) {
        guard let p = player else {
            completion?()
            return
        }
        let targetCMTime = CMTime(seconds: seconds, preferredTimescale: 600)
        p.seek(to: targetCMTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                self?.currentTime = seconds
                self?.updateNowPlayingInfo()
                completion?()
            }
        }
    }

    func skip(seconds: Double) {
        let target = max(0.0, min(duration, currentTime + seconds))
        seek(to: target)
    }

    // MARK: - 进度监听
    private func addPeriodicTimeObserver() {
        removePeriodicTimeObserver()
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserverToken = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            let sec = time.seconds
            if !sec.isNaN && !sec.isInfinite {
                self.currentTime = sec
            }
        }
    }

    private func removePeriodicTimeObserver() {
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
            timeObserverToken = nil
        }
    }

    // MARK: - 中断监听 (其他应用抢占/来电/耳机拔出)
    private func setupInterruptionObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioInterruption),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance()
        )
    }

    @objc private func handleAudioInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        DispatchQueue.main.async {
            switch type {
            case .began:
                self.isPlaying = false
                self.updateNowPlayingInfo()
            case .ended:
                if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                    let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                    if options.contains(.shouldResume) {
                        self.play()
                    }
                }
            @unknown default:
                break
            }
        }
    }

    @objc private func handleRouteChange(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

        if reason == .oldDeviceUnavailable {
            DispatchQueue.main.async {
                self.isPlaying = false
                self.updateNowPlayingInfo()
            }
        }
    }

    // MARK: - 控制中心与锁屏控制 (MPRemoteCommandCenter)
    private func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.play()
            return .success
        }

        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }

        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }

        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipForwardCommand.preferredIntervals = [15]
        commandCenter.skipForwardCommand.addTarget { [weak self] _ in
            self?.skip(seconds: 15)
            return .success
        }

        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.preferredIntervals = [15]
        commandCenter.skipBackwardCommand.addTarget { [weak self] _ in
            self?.skip(seconds: -15)
            return .success
        }

        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: event.positionTime)
            return .success
        }
    }

    func updateNowPlayingInfo() {
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = currentTitle
        info[MPMediaItemPropertyArtist] = String(format: "AudioBooster (%.1fx 增益)", boostMultiplier)
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0

        if let artwork = createArtwork() {
            info[MPMediaItemPropertyArtwork] = artwork
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func createArtwork() -> MPMediaItemArtwork? {
        let size = CGSize(width: 512, height: 512)
        let renderer = UIGraphicsImageRenderer(size: size)
        let img = renderer.image { ctx in
            let cg = ctx.cgContext
            let colors = [
                UIColor(red: 0.10, green: 0.12, blue: 0.20, alpha: 1.0).cgColor,
                UIColor(red: 0.03, green: 0.04, blue: 0.08, alpha: 1.0).cgColor
            ]
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: [0.0, 1.0]) {
                cg.drawLinearGradient(gradient, start: CGPoint.zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }

            if let noteSymbol = UIImage(systemName: "music.note")?.withTintColor(.white, renderingMode: .alwaysOriginal) {
                let rect = CGRect(x: 156, y: 156, width: 200, height: 200)
                noteSymbol.draw(in: rect)
            }
        }
        return MPMediaItemArtwork(boundsSize: size) { _ in img }
    }

    // MARK: - 标题清洗
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
}

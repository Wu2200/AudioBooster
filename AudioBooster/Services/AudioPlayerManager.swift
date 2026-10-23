import Foundation
import UIKit
import AVFoundation
import MediaPlayer
import Combine
import MediaToolbox

enum ASMREffectMode: String, CaseIterable, Identifiable {
    case standard = "标准原声"
    case allInOne = "综合全感"
    case whisperBreath = "呼吸贴耳"
    case spatial3D = "3D 空间环绕"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .standard: return "waveform"
        case .allInOne: return "sparkles"
        case .whisperBreath: return "wind"
        case .spatial3D: return "dot.radiowaves.left.and.right"
        }
    }

    var summary: String {
        switch self {
        case .standard: return "原始音频直出，无额外渲染"
        case .allInOne: return "呼吸细节+人声饱满+底噪净化"
        case .whisperBreath: return "聚焦近距离喘息与微弱唇齿音"
        case .spatial3D: return "保留经典空间音频，沉浸声场"
        }
    }
}

final class AudioPlayerManager: ObservableObject {
    static let shared = AudioPlayerManager()

    // MARK: - 基础播放状态 (边下边播 · 秒开起播)
    @Published var isPlaying: Bool = false
    @Published var currentTime: Double = 0.0
    @Published var duration: Double = 0.0
    @Published var bufferedTime: Double = 0.0
    @Published var currentTitle: String = "未加载音频"
    @Published var currentURLString: String = ""
    @Published var isBuffering: Bool = false
    @Published var errorMessage: String? = nil

    // MARK: - 音量突破倍数 (最高支持 8.0x，实时 32位浮点动态压限)
    @Published var boostMultiplier: Float = 1.0 {
        didSet {
            UserDefaults.standard.set(boostMultiplier, forKey: volumeStorageKey)
            syncDSPParameters()
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
    @Published var asmrMode: ASMREffectMode = .allInOne {
        didSet {
            UserDefaults.standard.set(asmrMode.rawValue, forKey: asmrModeStorageKey)
            syncDSPParameters()
        }
    }

    @Published var isLimiterEnabled: Bool = true {
        didSet {
            syncDSPParameters()
        }
    }

    @Published var isLooping: Bool = false
    @Published var isRainEnabled: Bool = false {
        didSet {
            if isRainEnabled {
                do {
                    try rainAmbience.start()
                    errorMessage = nil
                } catch {
                    errorMessage = "合成雨声启动失败：\(error.localizedDescription)"
                }
            } else {
                rainAmbience.stop()
            }
        }
    }
    @Published var rainVolume: Float = 0.22 {
        didSet {
            rainAmbience.volume = rainVolume
        }
    }
    @Published var sleepTimerMinutes: Int = 0
    @Published var sleepTimerRemainingSeconds: Int = 0

    // MARK: - 提示状态
    @Published var showNotificationBanner: Bool = false
    @Published var notificationText: String = ""

    // MARK: - 底层流媒体播放引擎 (AVPlayer + CoreAudio Stream Tap 实时拦截)
    var player: AVPlayer?
    private let dspProcessor = StreamDSPProcessor.shared
    private let rainAmbience = RainAmbiencePlayer()

    private var timeObserverToken: Any?
    private var statusObserver: NSKeyValueObservation?
    private var timeControlObserver: NSKeyValueObservation?
    private var bufferObserver: NSKeyValueObservation?
    private var playbackBufferEmptyObserver: NSKeyValueObservation?
    private var pendingPlaybackTarget: Double?
    private var seekGeneration = 0
    private var endObserver: NSObjectProtocol?

    private var sleepTimerCancellable: AnyCancellable?
    private let volumeStorageKey = "AudioBooster_SavedMultiplier_v1"
    private let asmrModeStorageKey = "AudioBooster_SavedASMRMode_v1"

    private init() {
        // 启动时自动彻底清理全部历史残留缓存，保证 0 MB 冗余占用
        clearAllOldDiskCaches()

        if let savedMultiplier = UserDefaults.standard.object(forKey: volumeStorageKey) as? Float, savedMultiplier >= 1.0 {
            self.boostMultiplier = min(8.0, savedMultiplier)
        } else {
            self.boostMultiplier = 1.0
        }

        if let savedModeRaw = UserDefaults.standard.string(forKey: asmrModeStorageKey) {
            if let savedMode = ASMREffectMode(rawValue: savedModeRaw) {
                self.asmrMode = savedMode
            } else if savedModeRaw == "耳语贴耳" {
                self.asmrMode = .whisperBreath
            } else if savedModeRaw == "温软慢语" || savedModeRaw == "温和助眠" {
                self.asmrMode = .allInOne
            } else if savedModeRaw == "双耳包裹" || savedModeRaw == "3D 沉浸环绕" {
                self.asmrMode = .spatial3D
            } else {
                self.asmrMode = .allInOne
            }
        } else {
            self.asmrMode = .allInOne
        }

        syncDSPParameters()
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

    // MARK: - 同步 DSP 参数到实时音频流处理器 (零延迟无锁流转)
    private func syncDSPParameters() {
        dspProcessor.boostMultiplier = self.boostMultiplier
        dspProcessor.isLimiterEnabled = self.isLimiterEnabled
        dspProcessor.asmrMode = self.asmrMode
    }

    // MARK: - 加载并秒开播放 (全异步网络流媒体架构，边下边播)
    func loadAndPlay(urlString: String, multiplier: Float? = nil, title: String? = nil, initialBoost: Float? = nil) {
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

        let targetMultiplier = multiplier ?? initialBoost

        DispatchQueue.main.async {
            self.errorMessage = nil
            self.isBuffering = true
            self.currentURLString = cleaned
            self.currentTitle = resolvedTitle
            self.currentTime = 0.0
            self.duration = 0.0
            self.bufferedTime = 0.0

            if let targetMult = targetMultiplier {
                self.boostMultiplier = targetMult
            }
        }

        dspProcessor.resetStates()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let headers: [String: String] = [
                "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 16_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.5 Mobile/15E148 Safari/604.1",
                "Referer": "\(url.scheme ?? "http")://\(url.host ?? "")/"
            ]
            let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
            let item = AVPlayerItem(asset: asset)

            DispatchQueue.main.async {
                self.setupPlayerWithItem(item, startTime: 0.0, resumePlay: true)
            }
        }
    }

    private func setupPlayerWithItem(_ item: AVPlayerItem, startTime: Double = 0.0, resumePlay: Bool = true) {
        removePeriodicTimeObserver()
        seekGeneration += 1
        pendingPlaybackTarget = nil
        playbackBufferEmptyObserver?.invalidate()

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

        // 挂载实时 CoreAudio MTAudioProcessingTap 抽头
        attachAudioTap(to: item)

        statusObserver?.invalidate()
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] (observedItem, _) in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch observedItem.status {
                case .readyToPlay:
                    self.isBuffering = false
                    let dur = observedItem.duration.seconds
                    self.duration = (dur.isNaN || dur.isInfinite) ? 0.0 : dur
                    self.attachAudioTap(to: observedItem)
                    if startTime > 0 {
                        self.seek(to: startTime, resumePlayback: resumePlay)
                    } else if resumePlay {
                        self.play()
                    }
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
                    guard observedPlayer.currentItem?.isPlaybackBufferEmpty == false else {
                        self.isPlaying = false
                        self.isBuffering = true
                        return
                    }
                    if self.pendingPlaybackTarget != nil {
                        let actualTime = observedPlayer.currentTime().seconds
                        if actualTime.isFinite {
                            self.currentTime = actualTime
                        }
                        self.pendingPlaybackTarget = nil
                    }
                    self.isPlaying = true
                    self.isBuffering = false
                case .paused:
                    self.isPlaying = false
                    self.isBuffering = self.pendingPlaybackTarget != nil
                case .waitingToPlayAtSpecifiedRate:
                    self.isPlaying = false
                    self.isBuffering = true
                @unknown default:
                    break
                }
                self.updateNowPlayingInfo()
            }
        }

        bufferObserver?.invalidate()
        bufferObserver = item.observe(\.loadedTimeRanges, options: [.new]) { [weak self] (observedItem, _) in
            let ranges = observedItem.loadedTimeRanges.map { $0.timeRangeValue }
            let buffered = ranges.map { $0.start.seconds + $0.duration.seconds }
                .filter { $0.isFinite }
                .max() ?? 0.0
            DispatchQueue.main.async {
                guard let self = self, self.player?.currentItem === observedItem else { return }
                self.bufferedTime = buffered
            }
        }

        playbackBufferEmptyObserver = item.observe(\.isPlaybackBufferEmpty, options: [.initial, .new]) { [weak self] observedItem, _ in
            DispatchQueue.main.async {
                guard let self = self, self.player?.currentItem === observedItem else { return }
                if observedItem.isPlaybackBufferEmpty {
                    self.isPlaying = false
                    self.isBuffering = true
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
                self.seek(to: 0.0, resumePlayback: true)
            } else {
                self.isPlaying = false
                self.currentTime = 0.0
                self.player?.seek(to: .zero)
                self.updateNowPlayingInfo()
            }
        }

        addPeriodicTimeObserver()
    }

    // MARK: - 注入实时流媒体 DSP 抽头 (边下边播无需本地全量文件)
    private func attachAudioTap(to item: AVPlayerItem) {
        guard let tap = dspProcessor.makeTap() else { return }

        item.asset.loadValuesAsynchronously(forKeys: ["tracks"]) { [weak item] in
            guard let currentItem = item else { return }
            let audioTracks = currentItem.asset.tracks(withMediaType: .audio)
            guard !audioTracks.isEmpty else { return }

            let audioMix = AVMutableAudioMix()
            var inputParameters: [AVMutableAudioMixInputParameters] = []

            for track in audioTracks {
                let trackParams = AVMutableAudioMixInputParameters(track: track)
                trackParams.audioTapProcessor = tap
                // 基础直通音量，所有 8x 突破放大和防爆音软压限全部交由 StreamDSPProcessor 内部处理
                trackParams.setVolume(1.0, at: .zero)
                inputParameters.append(trackParams)
            }

            audioMix.inputParameters = inputParameters

            DispatchQueue.main.async {
                currentItem.audioMix = audioMix
            }
        }
    }

    // MARK: - ASMR 音效模式切换
    func setASMREffectMode(_ mode: ASMREffectMode) {
        self.asmrMode = mode
    }

    // MARK: - 睡眠定时器 (到期前 30 秒平滑淡出)
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

                    // 到期前 30 秒平滑淡出，绝不惊醒用户
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
        if isPlaying || pendingPlaybackTarget != nil || p.rate != 0 || p.timeControlStatus == .waitingToPlayAtSpecifiedRate {
            pause()
        } else if duration > 0 && abs(currentTime - duration) < 0.5 {
            seek(to: 0.0, resumePlayback: true)
        } else {
            play()
        }
    }

    func pause() {
        seekGeneration += 1
        pendingPlaybackTarget = nil
        player?.pause()
        isPlaying = false
        isBuffering = false
    }

    func play() {
        guard let p = player else { return }
        let seconds = p.currentTime().seconds
        let target = seconds.isFinite ? max(0.0, seconds) : max(0.0, currentTime)
        startPlaybackWhenBuffered(at: target)
    }

    func seek(to seconds: Double, resumePlayback: Bool? = nil, completion: (() -> Void)? = nil) {
        guard let p = player, let item = p.currentItem else {
            completion?()
            return
        }
        guard seconds.isFinite else {
            completion?()
            return
        }

        let target = max(0.0, duration > 0 ? min(seconds, duration) : seconds)
        let shouldResume = resumePlayback ?? (isPlaying || p.rate != 0 || p.timeControlStatus == .waitingToPlayAtSpecifiedRate)
        let generation = seekGeneration + 1
        seekGeneration = generation
        item.cancelPendingSeeks()
        pendingPlaybackTarget = shouldResume ? target : nil
        p.pause()
        isPlaying = false
        isBuffering = shouldResume
        currentTime = target
        let targetCMTime = CMTime(seconds: target, preferredTimescale: 600)

        p.seek(to: targetCMTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak p, weak item] finished in
            DispatchQueue.main.async {
                guard let self = self,
                      let p = p,
                      let item = item,
                      self.seekGeneration == generation,
                      p.currentItem === item else { return }

                if finished {
                    self.currentTime = target
                    if shouldResume {
                        self.pendingPlaybackTarget = target
                        self.isBuffering = true
                        p.play()
                    } else {
                        self.pendingPlaybackTarget = nil
                    }
                    self.updateNowPlayingInfo()
                } else {
                    self.pendingPlaybackTarget = nil
                    self.isBuffering = false
                    self.isPlaying = false
                    self.errorMessage = "无法跳转到所选位置"
                }
                completion?()
            }
        }
    }

    private func startPlaybackWhenBuffered(at seconds: Double) {
        guard let p = player, let item = p.currentItem else { return }
        pendingPlaybackTarget = seconds
        guard item.status == .readyToPlay else {
            isBuffering = item.status != .failed
            if item.status == .failed {
                errorMessage = item.error?.localizedDescription ?? "音频资源加载失败"
            }
            return
        }
        isBuffering = true
        p.play()
    }

    private func isTimeBuffered(_ seconds: Double, in item: AVPlayerItem) -> Bool {
        guard seconds.isFinite else { return false }
        return item.loadedTimeRanges.contains { value in
            let range = value.timeRangeValue
            let start = range.start.seconds
            let end = start + range.duration.seconds
            return start.isFinite && end.isFinite && seconds >= start - 0.05 && seconds <= end + 0.05
        }
    }

    func skip(seconds: Double) {
        let target = max(0.0, min(duration, currentTime + seconds))
        seek(to: target)
    }

    func skip(by seconds: Double) {
        skip(seconds: seconds)
    }

    // MARK: - AVPlayer 进度监听
    private func addPeriodicTimeObserver() {
        removePeriodicTimeObserver()
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserverToken = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self,
                  let player = self.player,
                  let item = player.currentItem,
                  player.timeControlStatus == .playing,
                  item.status == .readyToPlay,
                  !item.isPlaybackBufferEmpty,
                  self.pendingPlaybackTarget == nil else { return }
            let sec = time.seconds
            if sec.isFinite && self.isTimeBuffered(sec, in: item) {
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

    // MARK: - 中断监听与线路保护
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
        info[MPMediaItemPropertyArtist] = String(format: "AudioBooster (%.1fx 增益 · %@)", boostMultiplier, asmrMode.rawValue)
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

    // MARK: - 清理全部历史残留沙盒缓存 (保证 0 MB 冗余占用)
    private func clearAllOldDiskCaches() {
        DispatchQueue.global(qos: .utility).async {
            let fileManager = FileManager.default
            let tmp = fileManager.temporaryDirectory

            // 清理旧版 dsp 临时目录及残留文件
            let dspCacheDir = tmp.appendingPathComponent("dsp_audio_cache", isDirectory: true)
            try? fileManager.removeItem(at: dspCacheDir)

            if let files = try? fileManager.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil) {
                for f in files {
                    if f.lastPathComponent.hasPrefix("dsp_") {
                        try? fileManager.removeItem(at: f)
                    }
                }
            }

            URLCache.shared.removeAllCachedResponses()
        }
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

private final class RainNoiseState {
    private var randomState: UInt64 = 0x9E3779B97F4A7C15
    private var lowPassLeft: Float = 0
    private var lowPassRight: Float = 0
    private var midPassLeft: Float = 0
    private var midPassRight: Float = 0

    func nextSample() -> (Float, Float) {
        let noiseLeft = nextNoise()
        let noiseRight = nextNoise()
        lowPassLeft += 0.008 * (noiseLeft - lowPassLeft)
        lowPassRight += 0.008 * (noiseRight - lowPassRight)
        midPassLeft += 0.075 * (noiseLeft - midPassLeft)
        midPassRight += 0.075 * (noiseRight - midPassRight)
        let left = (lowPassLeft * 0.45 + (midPassLeft - lowPassLeft) * 0.7 + (noiseLeft - midPassLeft) * 0.2) * 0.22
        let right = (lowPassRight * 0.45 + (midPassRight - lowPassRight) * 0.7 + (noiseRight - midPassRight) * 0.2) * 0.22
        return (left, right)
    }

    private func nextNoise() -> Float {
        randomState ^= randomState << 13
        randomState ^= randomState >> 7
        randomState ^= randomState << 17
        return Float(randomState & 0x00FF_FFFF) / 8_388_607.5 - 1
    }
}

private final class RainAmbiencePlayer {
    private let engine = AVAudioEngine()
    var volume: Float = 0.22 {
        didSet {
            engine.mainMixerNode.outputVolume = min(0.8, max(0, volume))
        }
    }

    init() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let state = RainNoiseState()
        let sourceNode = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else {
                return noErr
            }
            for frame in 0..<Int(frameCount) {
                let sample = state.nextSample()
                left[frame] = sample.0
                right[frame] = sample.1
            }
            return noErr
        }
        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = volume
    }

    func start() throws {
        guard !engine.isRunning else { return }
        try engine.start()
    }

    func stop() {
        if engine.isRunning {
            engine.stop()
        }
    }
}

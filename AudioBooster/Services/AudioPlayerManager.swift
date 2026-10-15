import Foundation
import AVFoundation
import MediaPlayer
import Combine

final class AudioPlayerManager: ObservableObject {
    static let shared = AudioPlayerManager()

    @Published var isPlaying: Bool = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var bufferedTime: Double = 0
    @Published var currentTitle: String = "未加载音频"
    @Published var currentURLString: String = ""
    @Published var boostMultiplier: Float = 1.0 {
        didSet {
            applyVolumeBoost()
        }
    }
    @Published var isBuffering: Bool = false
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

    private init() {
        setupRemoteCommandCenter()
    }

    deinit {
        removeObservers()
    }

    // MARK: - 播放控制 (异步非阻塞，保证外部跳转 UI 丝滑流畅)

    func loadAndPlay(urlString: String, title: String? = nil, initialBoost: Float? = nil) {
        let cleanURLString = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let encodedURLString = cleanURLString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? URL(string: cleanURLString)?.absoluteString,
              let url = URL(string: encodedURLString) else {
            self.errorMessage = "无效的音频链接"
            return
        }

        // 立即在主线程更新 UI 状态，不产生任何卡顿
        self.currentURLString = cleanURLString
        if let title = title, !title.isEmpty {
            self.currentTitle = title
        } else {
            let lastComp = url.lastPathComponent
            self.currentTitle = lastComp.isEmpty ? "网络音频" : lastComp
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

        // 异步后台初始化网络资源，避免外部跳转时阻塞主线程
        let targetURLString = cleanURLString
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let asset = AVURLAsset(url: url)
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
            player.play()
            isPlaying = true
        }
        updateNowPlayingPlaybackState()
    }

    func seek(to seconds: Double) {
        guard let player = player else { return }
        let clampedSeconds = max(0, min(seconds, max(0.1, duration)))
        self.currentTime = clampedSeconds
        let targetTime = CMTime(seconds: clampedSeconds, preferredTimescale: 600)
        player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            self?.updateNowPlayingPlaybackState()
        }
    }

    func skip(by seconds: Double) {
        let newTime = max(0, min(currentTime + seconds, duration))
        seek(to: newTime)
    }

    // MARK: - 突破最大音量核心实现 (1.0x - 4.0x)

    func applyVolumeBoost() {
        guard let currentItem = player?.currentItem else { return }

        let audioMix = AVMutableAudioMix()
        let tracks = currentItem.asset.tracks(withMediaType: .audio)

        if !tracks.isEmpty {
            var params: [AVMutableAudioMixInputParameters] = []
            for track in tracks {
                let inputParam = AVMutableAudioMixInputParameters(track: track)
                inputParam.setVolume(self.boostMultiplier, at: .zero)
                params.append(inputParam)
            }
            audioMix.inputParameters = params
        } else {
            let inputParam = AVMutableAudioMixInputParameters()
            inputParam.setVolume(self.boostMultiplier, at: .zero)
            audioMix.inputParameters = [inputParam]
        }

        currentItem.audioMix = audioMix
        player?.volume = 1.0
    }

    func setPresetBoost(_ multiplier: Float) {
        self.boostMultiplier = max(1.0, min(multiplier, 4.0))
        let gainDb = calculateDb(from: self.boostMultiplier)
        notifyUser(message: "已设置音量增益: \(String(format: "%.1f", self.boostMultiplier))x (\(gainDb))")
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

    // MARK: - 监听机制 (包含预载/缓冲进度监听)

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
            self.player?.seek(to: .zero)
        }
    }

    private func setupTimeObserver() {
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserverToken = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            self.currentTime = time.seconds
            self.updateNowPlayingPlaybackState()
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

    // MARK: - 锁屏控制与 NowPlaying

    private func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            if !self.isPlaying {
                self.togglePlayPause()
                return .success
            }
            return .commandFailed
        }

        commandCenter.pauseCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            if self.isPlaying {
                self.togglePlayPause()
                return .success
            }
            return .commandFailed
        }

        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }

        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self = self, let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            self.seek(to: positionEvent.positionTime)
            return .success
        }
    }

    private func setupNowPlayingInfo() {
        var nowPlayingInfo = [String: Any]()
        nowPlayingInfo[MPMediaItemPropertyTitle] = currentTitle
        nowPlayingInfo[MPMediaItemPropertyArtist] = "AudioBooster 增益放大 (\(String(format: "%.1f", boostMultiplier))x)"
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    private func updateNowPlayingPlaybackState() {
        guard var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }
}

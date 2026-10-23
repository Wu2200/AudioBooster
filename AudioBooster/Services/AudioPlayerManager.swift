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

    @Published var isPlaying: Bool = false
    @Published var currentTime: Double = 0.0
    @Published var duration: Double = 0.0
    @Published var bufferedTime: Double = 0.0
    @Published var currentTitle: String = "未加载音频"
    @Published var currentURLString: String = ""
    @Published var isBuffering: Bool = false
    @Published var errorMessage: String? = nil
    @Published var diagnosticReport: String = ""

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
    @Published var sleepTimerMinutes: Int = 0
    @Published var sleepTimerRemainingSeconds: Int = 0

    @Published var showNotificationBanner: Bool = false
    @Published var notificationText: String = ""

    var player: AVPlayer?
    private let dspProcessor = StreamDSPProcessor.shared

    private var timeObserverToken: Any?
    private var statusObserver: NSKeyValueObservation?
    private var timeControlObserver: NSKeyValueObservation?
    private var bufferObserver: NSKeyValueObservation?
    private var playbackBufferEmptyObserver: NSKeyValueObservation?
    private var likelyToKeepUpObserver: NSKeyValueObservation?
    private var accessLogObserver: NSObjectProtocol?
    private var errorLogObserver: NSObjectProtocol?
    private var playbackStalledObserver: NSObjectProtocol?
    private var diagnosticEntries: [String] = []
    private var diagnosticStartedAt: TimeInterval?
    private var startupStartedAt: TimeInterval?
    private var seekStartedAt: TimeInterval?
    private var lastAccessLogEventCount = 0
    private var lastErrorLogEventCount = 0
    private var lastBufferSignature = ""
    private var pendingPlaybackTarget: Double?
    private var playbackIntent = false
    private var seekInProgress = false
    private var seekGeneration = 0
    private var endObserver: NSObjectProtocol?

    private var sleepTimerCancellable: AnyCancellable?
    private let volumeStorageKey = "AudioBooster_SavedMultiplier_v1"
    private let asmrModeStorageKey = "AudioBooster_SavedASMRMode_v1"

    private init() {
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
        removeDiagnosticObservers()
        NotificationCenter.default.removeObserver(self)
        if let endObs = endObserver {
            NotificationCenter.default.removeObserver(endObs)
        }
    }

    private func syncDSPParameters() {
        dspProcessor.boostMultiplier = self.boostMultiplier
        dspProcessor.isLimiterEnabled = self.isLimiterEnabled
        dspProcessor.asmrMode = self.asmrMode
    }

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
            self.beginDiagnosticSession(for: url)

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
        playbackIntent = resumePlay
        seekInProgress = false
        playbackBufferEmptyObserver?.invalidate()
        likelyToKeepUpObserver?.invalidate()
        removeDiagnosticObservers()
        lastAccessLogEventCount = 0
        lastErrorLogEventCount = 0
        lastBufferSignature = ""
        recordDiagnostic("播放器项目已创建")

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
                    if let started = self.startupStartedAt {
                        self.recordDiagnostic(String(format: "资源就绪，起播请求后 %.2f 秒，时长 %.2f 秒", ProcessInfo.processInfo.systemUptime - started, self.duration))
                    } else {
                        self.recordDiagnostic(String(format: "资源就绪，时长 %.2f 秒", self.duration))
                    }
                    if startTime > 0 {
                        self.seek(to: startTime, resumePlayback: resumePlay)
                    } else if resumePlay {
                        self.play()
                    }
                    self.updateNowPlayingInfo()
                case .failed:
                    self.playbackIntent = false
                    self.isBuffering = false
                    self.isPlaying = false
                    let failure = observedItem.error as NSError?
                    self.recordDiagnostic("资源加载失败 domain=\(failure?.domain ?? "unknown") code=\(failure?.code ?? 0)")
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
                    if let started = self.startupStartedAt {
                        self.recordDiagnostic(String(format: "开始播放，起播耗时 %.2f 秒", ProcessInfo.processInfo.systemUptime - started))
                        self.startupStartedAt = nil
                    }
                    if let started = self.seekStartedAt {
                        self.recordDiagnostic(String(format: "跳转后恢复播放，耗时 %.2f 秒", ProcessInfo.processInfo.systemUptime - started))
                        self.seekStartedAt = nil
                    }
                    let actualTime = observedPlayer.currentTime().seconds
                    if self.pendingPlaybackTarget != nil {
                        if actualTime.isFinite {
                            self.currentTime = actualTime
                        }
                        self.pendingPlaybackTarget = nil
                    }
                    self.playbackIntent = true
                    self.isPlaying = true
                    self.isBuffering = false
                case .paused:
                    self.recordDiagnostic("播放器状态=paused 播放意图=\(self.playbackIntent) 跳转中=\(self.seekInProgress)")
                    self.isPlaying = false
                    self.isBuffering = self.playbackIntent
                    if let item = observedPlayer.currentItem {
                        self.resumePlaybackIfPossible(on: observedPlayer, item: item)
                    }
                case .waitingToPlayAtSpecifiedRate:
                    let reason = String(describing: observedPlayer.reasonForWaitingToPlay)
                    let item = observedPlayer.currentItem
                    self.recordDiagnostic("播放器等待 reason=\(reason) 播放意图=\(self.playbackIntent) bufferEmpty=\(item?.isPlaybackBufferEmpty ?? false) likelyToKeepUp=\(item?.isPlaybackLikelyToKeepUp ?? false) ranges=\(item.map { self.bufferRangesDescription($0) } ?? "未知")")
                    self.isPlaying = false
                    self.isBuffering = self.playbackIntent
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
                let signature = self.bufferRangesDescription(observedItem)
                if signature != self.lastBufferSignature {
                    self.lastBufferSignature = signature
                    self.recordDiagnostic("缓冲区变化 ranges=\(signature) likelyToKeepUp=\(observedItem.isPlaybackLikelyToKeepUp) bufferEmpty=\(observedItem.isPlaybackBufferEmpty)")
                }
                self.recordAccessLogEntries(from: observedItem)
                self.recordErrorLogEntries(from: observedItem)
                if let player = self.player {
                    self.resumePlaybackIfPossible(on: player, item: observedItem)
                }
            }
        }

        playbackBufferEmptyObserver = item.observe(\.isPlaybackBufferEmpty, options: [.initial, .new]) { [weak self] observedItem, _ in
            DispatchQueue.main.async {
                guard let self = self, let player = self.player, player.currentItem === observedItem else { return }
                if observedItem.isPlaybackBufferEmpty {
                    if self.playbackIntent {
                        self.isPlaying = false
                        self.isBuffering = true
                    }
                } else {
                    self.resumePlaybackIfPossible(on: player, item: observedItem)
                }
            }
        }

        likelyToKeepUpObserver = item.observe(\.isPlaybackLikelyToKeepUp, options: [.initial, .new]) { [weak self] observedItem, _ in
            DispatchQueue.main.async {
                guard let self = self, self.player?.currentItem === observedItem else { return }
                self.recordDiagnostic("可持续播放=\(observedItem.isPlaybackLikelyToKeepUp) ranges=\(self.bufferRangesDescription(observedItem))")
            }
        }

        accessLogObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemNewAccessLogEntry,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            guard let self = self, let item = item, self.player?.currentItem === item else { return }
            self.recordAccessLogEntries(from: item)
        }

        errorLogObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemNewErrorLogEntry,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            guard let self = self, let item = item, self.player?.currentItem === item else { return }
            self.recordErrorLogEntries(from: item)
        }

        playbackStalledObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            guard let self = self, let item = item, self.player?.currentItem === item else { return }
            self.recordDiagnostic("系统报告播放卡顿 ranges=\(self.bufferRangesDescription(item))")
            self.recordAccessLogEntries(from: item)
            self.recordErrorLogEntries(from: item)
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
                self.playbackIntent = false
                self.isPlaying = false
                self.isBuffering = false
                self.currentTime = 0.0
                self.player?.seek(to: .zero)
                self.updateNowPlayingInfo()
            }
        }

        addPeriodicTimeObserver()
    }

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
                trackParams.setVolume(1.0, at: .zero)
                inputParameters.append(trackParams)
            }

            audioMix.inputParameters = inputParameters

            DispatchQueue.main.async {
                currentItem.audioMix = audioMix
            }
        }
    }

    func setASMREffectMode(_ mode: ASMREffectMode) {
        self.asmrMode = mode
    }

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

    func togglePlayPause() {
        guard let p = player else { return }
        if playbackIntent {
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
        playbackIntent = false
        seekInProgress = false
        player?.currentItem?.cancelPendingSeeks()
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
        let shouldResume = resumePlayback ?? playbackIntent
        let generation = seekGeneration + 1
        seekGeneration = generation
        seekStartedAt = ProcessInfo.processInfo.systemUptime
        recordDiagnostic(String(format: "跳转请求 target=%.2f resume=%@ ranges=%@", target, String(shouldResume), bufferRangesDescription(item)))
        item.cancelPendingSeeks()
        playbackIntent = shouldResume
        seekInProgress = true
        pendingPlaybackTarget = shouldResume ? target : nil
        p.pause()
        isPlaying = false
        isBuffering = shouldResume
        currentTime = target
        let targetCMTime = CMTime(seconds: target, preferredTimescale: 600)

        let seekTolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
        p.seek(to: targetCMTime, toleranceBefore: seekTolerance, toleranceAfter: seekTolerance) { [weak self, weak p, weak item] finished in
            DispatchQueue.main.async {
                guard let self = self,
                      let p = p,
                      let item = item,
                      self.seekGeneration == generation,
                      p.currentItem === item else { return }

                self.seekInProgress = false
                if finished {
                    self.recordDiagnostic(String(format: "跳转定位完成 target=%.2f，播放器时间=%.2f", target, p.currentTime().seconds))
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
                    self.recordDiagnostic(String(format: "跳转失败 target=%.2f", target))
                    self.seekStartedAt = nil
                    self.pendingPlaybackTarget = nil
                    self.playbackIntent = false
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
        playbackIntent = true
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

    private func resumePlaybackIfPossible(on player: AVPlayer, item: AVPlayerItem) {
        guard playbackIntent,
              !seekInProgress,
              player.currentItem === item,
              item.status == .readyToPlay,
              player.timeControlStatus == .paused else { return }

        guard !item.isPlaybackBufferEmpty else {
            isPlaying = false
            isBuffering = true
            return
        }

        isBuffering = true
        player.play()
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

    private func beginDiagnosticSession(for url: URL) {
        diagnosticEntries.removeAll(keepingCapacity: true)
        diagnosticStartedAt = ProcessInfo.processInfo.systemUptime
        startupStartedAt = diagnosticStartedAt
        seekStartedAt = nil
        diagnosticReport = ""
        let source = "\(url.scheme ?? "unknown")://\(url.host ?? "unknown")"
        recordDiagnostic("开始加载音源 \(source)")
    }

    private func recordDiagnostic(_ message: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.recordDiagnostic(message)
            }
            return
        }
        let elapsed = diagnosticStartedAt.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0
        diagnosticEntries.append(String(format: "[%6.1f 秒] %@", elapsed, message))
        if diagnosticEntries.count > 160 {
            diagnosticEntries.removeFirst(diagnosticEntries.count - 160)
        }
        diagnosticReport = diagnosticEntries.joined(separator: "\n")
    }

    private func bufferRangesDescription(_ item: AVPlayerItem) -> String {
        let ranges = item.loadedTimeRanges.compactMap { value -> String? in
            let range = value.timeRangeValue
            let start = range.start.seconds
            let end = start + range.duration.seconds
            guard start.isFinite, end.isFinite else { return nil }
            return String(format: "%.1f-%.1f", start, end)
        }
        return ranges.isEmpty ? "无" : ranges.joined(separator: ",")
    }

    private func recordAccessLogEntries(from item: AVPlayerItem) {
        let events = item.accessLog()?.events ?? []
        guard events.count > lastAccessLogEventCount else { return }
        for event in events.dropFirst(lastAccessLogEventCount) {
            recordDiagnostic(String(format: "网络访问 bytes=%lld requests=%ld stalls=%ld transfer=%.2fs observed=%.0f indicated=%.0f", event.numberOfBytesTransferred, event.numberOfMediaRequests, event.numberOfStalls, event.transferDuration, event.observedBitrate, event.indicatedBitrate))
        }
        lastAccessLogEventCount = events.count
    }

    private func recordErrorLogEntries(from item: AVPlayerItem) {
        let events = item.errorLog()?.events ?? []
        guard events.count > lastErrorLogEventCount else { return }
        for event in events.dropFirst(lastErrorLogEventCount) {
            recordDiagnostic("网络错误 domain=\(event.errorDomain) status=\(event.errorStatusCode)")
        }
        lastErrorLogEventCount = events.count
    }

    private func removeDiagnosticObservers() {
        if let observer = accessLogObserver {
            NotificationCenter.default.removeObserver(observer)
            accessLogObserver = nil
        }
        if let observer = errorLogObserver {
            NotificationCenter.default.removeObserver(observer)
            errorLogObserver = nil
        }
        if let observer = playbackStalledObserver {
            NotificationCenter.default.removeObserver(observer)
            playbackStalledObserver = nil
        }
    }

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
                    if options.contains(.shouldResume) && self.playbackIntent {
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
                self.playbackIntent = false
                self.isPlaying = false
                self.isBuffering = false
                self.updateNowPlayingInfo()
            }
        }
    }

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

    private func clearAllOldDiskCaches() {
        DispatchQueue.global(qos: .utility).async {
            let fileManager = FileManager.default
            let tmp = fileManager.temporaryDirectory

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

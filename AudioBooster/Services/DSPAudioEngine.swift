import Foundation
import AVFoundation

final class DSPAudioEngine {
    // MARK: - 音频引擎与核心节点
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let eqNode = AVAudioUnitEQ(numberOfBands: 3)
    private let reverbNode = AVAudioUnitReverb()
    private let volumeNode = AVAudioMixerNode()

    // MARK: - 文件与时间追踪
    private var currentAudioFile: AVAudioFile?
    private var fileDuration: Double = 0.0
    private var sampleRate: Double = 44100.0
    private var totalFrames: AVAudioFramePosition = 0

    private var seekFrameOffset: AVAudioFramePosition = 0
    private var isPlayingInternal: Bool = false
    private var isEngineConfigured: Bool = false

    private var downloadTask: URLSessionDownloadTask?
    private var progressObservation: NSKeyValueObservation?

    // 状态回调给外层 PlayerManager
    var onStateChange: ((Bool) -> Void)?
    var onTimeUpdate: ((Double, Double) -> Void)?
    var onBufferProgress: ((Float, String?) -> Void)?
    var onPlaybackEnd: (() -> Void)?
    var onError: ((String) -> Void)?

    private var displayLinkTimer: Timer?

    init() {
        setupEngineNodes()
    }

    deinit {
        stop()
        downloadTask?.cancel()
        progressObservation?.invalidate()
        displayLinkTimer?.invalidate()
    }

    // MARK: - 节点连接配置
    private func setupEngineNodes() {
        guard !isEngineConfigured else { return }

        // 挂载节点到引擎
        engine.attach(playerNode)
        engine.attach(eqNode)
        engine.attach(reverbNode)
        engine.attach(volumeNode)

        // 连接节点链:
        // PlayerNode -> EQNode (参数均衡器) -> ReverbNode (3D空间环绕) -> VolumeNode (突破增益与混音) -> mainMixerNode
        engine.connect(playerNode, to: eqNode, format: nil)
        engine.connect(eqNode, to: reverbNode, format: nil)
        engine.connect(reverbNode, to: volumeNode, format: nil)
        engine.connect(volumeNode, to: engine.mainMixerNode, format: nil)

        // 默认初始化 DSP 参数
        configureDefaultDSP()

        isEngineConfigured = true
    }

    private func configureDefaultDSP() {
        // 1. 初始化 3 段硬件 EQ
        let band0 = eqNode.bands[0]
        band0.filterType = .highPass
        band0.frequency = 120.0
        band0.bypass = true

        let band1 = eqNode.bands[1]
        band1.filterType = .parametric
        band1.frequency = 3200.0
        band1.bandwidth = 1.4
        band1.gain = 0.0
        band1.bypass = true

        let band2 = eqNode.bands[2]
        band2.filterType = .lowPass
        band2.frequency = 7500.0
        band2.bypass = true

        eqNode.bypass = true

        // 2. 初始化 Reverb 空间化
        reverbNode.loadFactoryPreset(.mediumHall)
        reverbNode.wetDryMix = 0.0
        reverbNode.bypass = true

        // 3. 初始音量
        volumeNode.outputVolume = 1.0
    }

    // MARK: - 启动引擎
    private func ensureEngineRunning() throws {
        if !engine.isRunning {
            try engine.start()
        }
    }

    // MARK: - 加载网络或本地音频
    func loadAndPlay(urlString: String, startTime: Double = 0.0, completion: (() -> Void)? = nil) {
        stop()
        downloadTask?.cancel()
        progressObservation?.invalidate()

        guard let url = URL(string: urlString) else {
            onError?("无效的音频链接")
            return
        }

        if url.isFileURL {
            loadLocalFile(url: url, startTime: startTime, completion: completion)
        } else {
            // 网络音频：下载到沙盒临时缓存并边载入边播放
            loadRemoteURL(url: url, startTime: startTime, completion: completion)
        }
    }

    private func loadRemoteURL(url: URL, startTime: Double, completion: (() -> Void)? = nil) {
        let hashName = String(url.absoluteString.hashValue)
        let ext = url.pathExtension.isEmpty ? "mp3" : url.pathExtension
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("dsp_cache_\(hashName).\(ext)")

        // 如果本地已存在该缓存文件且有效，直接秒开载入
        if FileManager.default.fileExists(atPath: tempFile.path),
           let attr = try? FileManager.default.attributesOfItem(atPath: tempFile.path),
           let size = attr[.size] as? Int64, size > 10240 {
            loadLocalFile(url: tempFile, startTime: startTime, completion: completion)
            return
        }

        onBufferProgress?(0.05, "DSP 内核建立连接中...")

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.5 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        request.setValue("\(url.scheme ?? "http")://\(url.host ?? "")/", forHTTPHeaderField: "Referer")

        let task = URLSession.shared.downloadTask(with: request) { [weak self] (tempLocation, response, error) in
            guard let self = self else { return }

            if let error = error {
                DispatchQueue.main.async {
                    self.onError?("DSP 音频下载失败: \(error.localizedDescription)")
                }
                return
            }

            guard let tempLocation = tempLocation else {
                DispatchQueue.main.async {
                    self.onError?("未接收到音频数据")
                }
                return
            }

            do {
                if FileManager.default.fileExists(atPath: tempFile.path) {
                    try FileManager.default.removeItem(at: tempFile)
                }
                try FileManager.default.moveItem(at: tempLocation, to: tempFile)

                DispatchQueue.main.async {
                    self.onBufferProgress?(1.0, nil)
                    self.loadLocalFile(url: tempFile, startTime: startTime, completion: completion)
                }
            } catch {
                DispatchQueue.main.async {
                    self.onError?("音频缓存保存失败: \(error.localizedDescription)")
                }
            }
        }

        self.progressObservation = task.progress.observe(\.fractionCompleted) { [weak self] (progress, _) in
            DispatchQueue.main.async {
                let percent = Int(progress.fractionCompleted * 100)
                self?.onBufferProgress?(Float(progress.fractionCompleted), "正在载入 DSP 缓冲 (\(percent)%)...")
            }
        }

        self.downloadTask = task
        task.resume()
    }

    private func loadLocalFile(url: URL, startTime: Double, completion: (() -> Void)? = nil) {
        do {
            let file = try AVAudioFile(forReading: url)
            self.currentAudioFile = file
            self.sampleRate = file.processingFormat.sampleRate
            self.totalFrames = file.length
            self.fileDuration = Double(file.length) / sampleRate

            try ensureEngineRunning()

            // 定位到指定时间
            schedulePlayback(from: startTime)
            play()
            completion?()
        } catch {
            onError?("音频解码失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 调度播放帧
    private func schedulePlayback(from seconds: Double) {
        guard let file = currentAudioFile else { return }

        let clampedSeconds = max(0.0, min(fileDuration, seconds))
        let targetFrame = AVAudioFramePosition(clampedSeconds * sampleRate)
        let frameCount = AVAudioFrameCount(max(0, totalFrames - targetFrame))

        guard frameCount > 0 else { return }

        playerNode.stop()
        self.seekFrameOffset = targetFrame

        playerNode.scheduleSegment(
            file,
            startingFrame: targetFrame,
            frameCount: frameCount,
            at: nil
        ) { [weak self] in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // 播放自然结束
                if self.isPlayingInternal && abs(self.currentTime - self.fileDuration) < 0.5 {
                    self.isPlayingInternal = false
                    self.onStateChange?(false)
                    self.onPlaybackEnd?()
                }
            }
        }
    }

    // MARK: - 播放控制
    func play() {
        guard currentAudioFile != nil else { return }
        do {
            try ensureEngineRunning()
            playerNode.play()
            isPlayingInternal = true
            onStateChange?(true)
            startProgressTimer()
        } catch {
            onError?("启动 DSP 引擎失败: \(error.localizedDescription)")
        }
    }

    func pause() {
        playerNode.pause()
        isPlayingInternal = false
        onStateChange?(false)
        stopProgressTimer()
    }

    func togglePlayPause() {
        if isPlayingInternal {
            pause()
        } else {
            play()
        }
    }

    func stop() {
        playerNode.stop()
        isPlayingInternal = false
        stopProgressTimer()
        onStateChange?(false)
    }

    func seek(to seconds: Double, completion: (() -> Void)? = nil) {
        guard currentAudioFile != nil else {
            completion?()
            return
        }

        let wasPlaying = isPlayingInternal
        schedulePlayback(from: seconds)
        if wasPlaying {
            playerNode.play()
            isPlayingInternal = true
            onStateChange?(true)
        }
        onTimeUpdate?(seconds, fileDuration)
        completion?()
    }

    // MARK: - 实时时间计算
    var currentTime: Double {
        guard let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else {
            return Double(seekFrameOffset) / sampleRate
        }
        let elapsed = Double(playerTime.sampleTime) / sampleRate
        let computed = (Double(seekFrameOffset) / sampleRate) + elapsed
        return min(fileDuration, max(0.0, computed))
    }

    var duration: Double {
        return fileDuration
    }

    var isPlaying: Bool {
        return isPlayingInternal
    }

    private func startProgressTimer() {
        stopProgressTimer()
        displayLinkTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let cur = self.currentTime
            self.onTimeUpdate?(cur, self.fileDuration)
        }
    }

    private func stopProgressTimer() {
        displayLinkTimer?.invalidate()
        displayLinkTimer = nil
    }

    // MARK: - DSP 音效与 ASMR 模式配置
    func applyASMRMode(_ mode: ASMREffectMode) {
        switch mode {
        case .standard:
            eqNode.bypass = true
            reverbNode.bypass = true

        case .whisperClean:
            // 【耳语贴耳】：开启 120Hz 高通切除杂音，并在 3200Hz 强力提升 +9.0dB，大幅度凸显近场呼吸与唇齿细节
            let band0 = eqNode.bands[0]
            band0.filterType = .highPass
            band0.frequency = 120.0
            band0.bypass = false

            let band1 = eqNode.bands[1]
            band1.filterType = .parametric
            band1.frequency = 3200.0
            band1.bandwidth = 1.2
            band1.gain = 9.0
            band1.bypass = false

            let band2 = eqNode.bands[2]
            band2.filterType = .lowPass
            band2.frequency = 7500.0
            band2.bypass = true

            eqNode.bypass = false
            reverbNode.bypass = true

        case .softSleep:
            // 【温和助眠】：开启 6500Hz 低通柔化刺耳高频，并在 250Hz 提供 +3.5dB 温暖包裹
            let band0 = eqNode.bands[0]
            band0.bypass = true

            let band1 = eqNode.bands[1]
            band1.filterType = .parametric
            band1.frequency = 250.0
            band1.bandwidth = 1.5
            band1.gain = 3.5
            band1.bypass = false

            let band2 = eqNode.bands[2]
            band2.filterType = .lowPass
            band2.frequency = 6500.0
            band2.bypass = false

            eqNode.bypass = false

            // 轻微温和混响
            reverbNode.loadFactoryPreset(.smallRoom)
            reverbNode.wetDryMix = 18.0
            reverbNode.bypass = false

        case .spatialBinaural:
            // 【3D 沉浸环绕】：加载大空间反射，营造开阔双耳环绕与离耳感
            eqNode.bypass = true
            reverbNode.loadFactoryPreset(.mediumHall)
            reverbNode.wetDryMix = 32.0
            reverbNode.bypass = false
        }
    }

    // MARK: - 音量突破与防爆音压限控制
    func setBoostMultiplier(_ mult: Float, isLimiterEnabled: Bool) {
        if isLimiterEnabled && mult > 2.0 {
            // 双曲正切平滑饱和软压限，防止大音量破音
            let excess = mult - 2.0
            let compressedExcess = Float(tanh(Double(excess) / 1.8)) * 1.6
            volumeNode.outputVolume = 2.0 + compressedExcess
        } else {
            volumeNode.outputVolume = mult
        }
    }
}

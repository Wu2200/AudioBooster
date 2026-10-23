import Foundation
import AVFoundation
import MediaToolbox
import CoreMedia

// MARK: - CoreAudio C-Style 回调函数 (MTAudioProcessingTap 实时音频流抽头)

private func streamTapInit(
    tap: MTAudioProcessingTap,
    clientInfo: UnsafeMutableRawPointer?,
    tapStorageOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>
) {
    tapStorageOut.pointee = clientInfo
}

private func streamTapFinalize(tap: MTAudioProcessingTap) {}

private func streamTapPrepare(
    tap: MTAudioProcessingTap,
    maxFrames: CMItemCount,
    processingFormat: UnsafePointer<AudioStreamBasicDescription>
) {}

private func streamTapUnprepare(tap: MTAudioProcessingTap) {}

private func streamTapProcess(
    tap: MTAudioProcessingTap,
    numberFrames: CMItemCount,
    flags: MTAudioProcessingTapFlags,
    bufferListInOut: UnsafeMutablePointer<AudioBufferList>,
    numberFramesOut: UnsafeMutablePointer<CMItemCount>,
    flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>
) {
    let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut)
    guard status == noErr else { return }

    let clientInfo = MTAudioProcessingTapGetStorage(tap)
    let processor = Unmanaged<StreamDSPProcessor>.fromOpaque(clientInfo).takeUnretainedValue()
    processor.processBufferList(bufferListInOut, frames: Int(numberFramesOut.pointee))
}

// MARK: - 实时流媒体 DSP 音频处理器 (综合全感 / 呼吸贴耳 / 经典 3D 空间环绕)

final class StreamDSPProcessor {
    static let shared = StreamDSPProcessor()

    // 实时控制参数 (音频实时线程直接读取，零锁开销)
    var boostMultiplier: Float = 1.0
    var isLimiterEnabled: Bool = true
    var asmrMode: ASMREffectMode = .allInOne

    // MARK: - 1. 呼吸贴耳与综合滤波状态 (IIR 一阶分频与微动态)
    private var breathFilterL: Float = 0.0
    private var breathFilterR: Float = 0.0
    // MARK: - 2. 经典 3D 空间环绕声学混响矩阵 (Schroeder 声学梳状与全通网络)
    // 梳状滤波器缓冲区 (4路不同质数延迟，消除驻波与金属染色)
    private let comb1Cap = 1116 // ~25.3ms
    private let comb2Cap = 1356 // ~30.7ms
    private let comb3Cap = 1422 // ~32.2ms
    private let comb4Cap = 1617 // ~36.6ms
    private var comb1Buf: [Float]
    private var comb2Buf: [Float]
    private var comb3Buf: [Float]
    private var comb4Buf: [Float]
    private var comb1Idx: Int = 0
    private var comb2Idx: Int = 0
    private var comb3Idx: Int = 0
    private var comb4Idx: Int = 0

    // 全通滤波器缓冲区 (2路空间相位立体声漫射)
    private let ap1Cap = 556 // ~12.6ms
    private let ap2Cap = 441 // ~10.0ms
    private var ap1Buf: [Float]
    private var ap2Buf: [Float]
    private var ap1Idx: Int = 0
    private var ap2Idx: Int = 0

    private init() {
        self.comb1Buf = [Float](repeating: 0.0, count: comb1Cap)
        self.comb2Buf = [Float](repeating: 0.0, count: comb2Cap)
        self.comb3Buf = [Float](repeating: 0.0, count: comb3Cap)
        self.comb4Buf = [Float](repeating: 0.0, count: comb4Cap)
        self.ap1Buf = [Float](repeating: 0.0, count: ap1Cap)
        self.ap2Buf = [Float](repeating: 0.0, count: ap2Cap)
    }

    func resetStates() {
        breathFilterL = 0.0
        breathFilterR = 0.0
        comb1Buf.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0.0) }
        comb2Buf.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0.0) }
        comb3Buf.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0.0) }
        comb4Buf.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0.0) }
        ap1Buf.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0.0) }
        ap2Buf.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0.0) }

        comb1Idx = 0
        comb2Idx = 0
        comb3Idx = 0
        comb4Idx = 0
        ap1Idx = 0
        ap2Idx = 0
    }

    func makeTap() -> MTAudioProcessingTap? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            init: streamTapInit,
            finalize: streamTapFinalize,
            prepare: streamTapPrepare,
            unprepare: streamTapUnprepare,
            process: streamTapProcess
        )

        var tap: Unmanaged<MTAudioProcessingTap>?
        let err = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PreEffects, &tap)
        if err == noErr, let tap = tap {
            return tap.takeRetainedValue()
        }
        return nil
    }

    func processBufferList(_ bufferListInOut: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        guard frames > 0 else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(bufferListInOut)

        let currentBoost = self.boostMultiplier
        let useLimiter = self.isLimiterEnabled
        let mode = self.asmrMode

        if buffers.count >= 2,
           let ptrL = buffers[0].mData?.assumingMemoryBound(to: Float.self),
           let ptrR = buffers[1].mData?.assumingMemoryBound(to: Float.self) {
            // 双声道非交错 (Non-interleaved)
            for i in 0..<frames {
                var (outL, outR) = processSample(sL: ptrL[i], sR: ptrR[i], mode: mode)
                ptrL[i] = applyLimit(outL * currentBoost, enabled: useLimiter)
                ptrR[i] = applyLimit(outR * currentBoost, enabled: useLimiter)
            }
        } else if buffers.count == 1,
                  let ptr = buffers[0].mData?.assumingMemoryBound(to: Float.self) {
            let channels = Int(buffers[0].mNumberChannels)
            if channels == 2 {
                // 双声道交错 (Interleaved: L, R, L, R...)
                for i in 0..<frames {
                    let idxL = i * 2
                    let idxR = i * 2 + 1
                    var (outL, outR) = processSample(sL: ptr[idxL], sR: ptr[idxR], mode: mode)
                    ptr[idxL] = applyLimit(outL * currentBoost, enabled: useLimiter)
                    ptr[idxR] = applyLimit(outR * currentBoost, enabled: useLimiter)
                }
            } else if channels == 1 {
                // 单声道 (Mono)
                for i in 0..<frames {
                    let (outL, _) = processSample(sL: ptr[i], sR: ptr[i], mode: mode)
                    ptr[i] = applyLimit(outL * currentBoost, enabled: useLimiter)
                }
            }
        }
    }

    // MARK: - 核心多模式声学渲染管线
    @inline(__always)
    private func processSample(sL: Float, sR: Float, mode: ASMREffectMode) -> (Float, Float) {
        switch mode {
        case .standard:
            // 标准原声：原始采样直出
            return (sL, sR)

        case .allInOne:
            let alpha: Float = 0.32
            breathFilterL += alpha * (sL - breathFilterL)
            breathFilterR += alpha * (sR - breathFilterR)
            let airL = sL - breathFilterL
            let airR = sR - breathFilterR
            return (breathFilterL + 1.12 * airL, breathFilterR + 1.12 * airR)

        case .whisperBreath:
            // MARK: - 【呼吸贴耳】(强力凸显耳语、喘息起伏与近距唇齿微动态)
            let alpha: Float = 0.38
            breathFilterL += alpha * (sL - breathFilterL)
            breathFilterR += alpha * (sR - breathFilterR)
            let airL = sL - breathFilterL
            let airR = sR - breathFilterR
            // 保持人声主体自然，对呼吸微弱气流与唇齿音实施 +5.2dB 针对性聚焦
            let outL = breathFilterL + 1.82 * airL
            let outR = breathFilterR + 1.82 * airR
            return (outL, outR)

        case .spatial3D:
            // MARK: - 【3D 空间环绕】(保留经典空间音频声场 · Schroeder 声学立体声混响模型)
            // 通过 4 路质数梳状延迟 + 2 路全通漫射，制造真实开阔的大空间立体声混响声场
            let inputMono = (sL + sR) * 0.5
            let rev = computeSchroederReverb(input: inputMono)

            // 干湿比混合: 72% 干声清晰人声 + 38% 空间环绕立体声漫射
            let outL = sL * 0.72 + rev.0 * 0.38
            let outR = sR * 0.72 + rev.1 * 0.38
            return (outL, outR)
        }
    }

    // MARK: - Schroeder 空间声学混响渲染算法 (经典 3D 空间音频)
    @inline(__always)
    private func computeSchroederReverb(input: Float) -> (Float, Float) {
        // 4 路并行梳状延迟滤波 (反馈系数 ~0.785)
        let c1Out = comb1Buf[comb1Idx]
        comb1Buf[comb1Idx] = input + c1Out * 0.785
        comb1Idx = (comb1Idx + 1) % comb1Cap

        let c2Out = comb2Buf[comb2Idx]
        comb2Buf[comb2Idx] = input + c2Out * 0.780
        comb2Idx = (comb2Idx + 1) % comb2Cap

        let c3Out = comb3Buf[comb3Idx]
        comb3Buf[comb3Idx] = input + c3Out * 0.772
        comb3Idx = (comb3Idx + 1) % comb3Cap

        let c4Out = comb4Buf[comb4Idx]
        comb4Buf[comb4Idx] = input + c4Out * 0.768
        comb4Idx = (comb4Idx + 1) % comb4Cap

        let combMix = (c1Out + c2Out + c3Out + c4Out) * 0.25

        // 串联全通滤波器 1 (漫射系数 0.62)
        let ap1Out = ap1Buf[ap1Idx] - 0.62 * combMix
        ap1Buf[ap1Idx] = combMix + 0.62 * ap1Out
        ap1Idx = (ap1Idx + 1) % ap1Cap

        // 串联全通滤波器 2 (漫射系数 0.62)
        let ap2Out = ap2Buf[ap2Idx] - 0.62 * ap1Out
        ap2Buf[ap2Idx] = ap1Out + 0.62 * ap2Out
        ap2Idx = (ap2Idx + 1) % ap2Cap

        // 左右耳相位立体声扩散 (左耳以 c1/c3 为主，右耳以 c2/c4 为主)
        let revL = ap2Out + (c1Out - c2Out) * 0.22
        let revR = ap2Out + (c3Out - c4Out) * 0.22
        return (revL, revR)
    }

    // MARK: - 8.0x 极限大音量双曲正切软压限保护
    @inline(__always)
    private func applyLimit(_ sample: Float, enabled: Bool) -> Float {
        guard enabled else {
            return max(-1.0, min(1.0, sample))
        }
        let threshold: Float = 0.72
        if sample > threshold {
            return threshold + (1.0 - threshold) * tanhf((sample - threshold) / (1.0 - threshold))
        } else if sample < -threshold {
            return -threshold + (1.0 - threshold) * tanhf((sample + threshold) / (1.0 - threshold))
        } else {
            return sample
        }
    }
}

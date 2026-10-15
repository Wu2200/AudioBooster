import Foundation
import AVFoundation
import MediaToolbox
import CoreMedia

// MARK: - CoreAudio C-Style Callbacks for MTAudioProcessingTap

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

// MARK: - 实时流媒体 DSP 音频处理器 (人声/喘息声/综合 ASMR 声学调谐矩阵)

final class StreamDSPProcessor {
    static let shared = StreamDSPProcessor()

    // 实时参数 (实时音频线程直接读取生效，零延迟)
    var boostMultiplier: Float = 1.0
    var isLimiterEnabled: Bool = true
    var asmrMode: ASMREffectMode = .standard

    // MARK: - 内部声学滤波器状态量 (预分配常驻内存，零 GC)
    // 呼吸贴耳 (Whisper & Breath Air EQ)
    private var breathFilterL: Float = 0.0
    private var breathFilterR: Float = 0.0

    // 温软慢语 (Warm Vocal & Tube Saturation)
    private var warmFilterL: Float = 0.0
    private var warmFilterR: Float = 0.0

    // 双耳包裹 (Mid/Side 空间声学立体声漫射)
    private let sideDelayCapacity = 2048
    private var sideDelayBuffer: [Float]
    private var sideDelayWriteIndex: Int = 0
    private let sideDelayOffset: Int = 520 // 约 11.8ms 空间泛音漫射

    private init() {
        self.sideDelayBuffer = [Float](repeating: 0.0, count: sideDelayCapacity)
    }

    func resetStates() {
        sideDelayBuffer.withUnsafeMutableBufferPointer { ptr in
            ptr.initialize(repeating: 0.0)
        }
        sideDelayWriteIndex = 0
        breathFilterL = 0.0
        breathFilterR = 0.0
        warmFilterL = 0.0
        warmFilterR = 0.0
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
                var sL = ptrL[i]
                var sR = ptrR[i]

                switch mode {
                case .standard:
                    break

                case .whisperBreath:
                    // 【呼吸贴耳】：聚焦 3.5kHz~8kHz 近场呼吸、气流与唇齿音，保留胸腔温暖基频
                    let alpha: Float = 0.35
                    breathFilterL += alpha * (sL - breathFilterL)
                    breathFilterR += alpha * (sR - breathFilterR)
                    let airL = sL - breathFilterL
                    let airR = sR - breathFilterR
                    // 保持人声主体 (breathFilter) 饱满不薄，将微弱呼吸气流 (air) 提亮 +4.5dB
                    sL = breathFilterL + 1.68 * airL
                    sR = breathFilterR + 1.68 * airR

                case .warmIntimate:
                    // 【温软慢语】：电子管偶次微谐波包浆 + 平滑齿音滚降，软糯温润易眠
                    let satL = sL + 0.08 * (sL * sL) * (sL >= 0 ? 1.0 : -1.0)
                    let satR = sR + 0.08 * (sR * sR) * (sR >= 0 ? 1.0 : -1.0)
                    let beta: Float = 0.62
                    warmFilterL += beta * (satL - warmFilterL)
                    warmFilterR += beta * (satR - warmFilterR)
                    sL = 0.82 * warmFilterL + 0.18 * satL
                    sR = 0.82 * warmFilterR + 0.18 * satR

                case .binauralAir:
                    // 【双耳包裹】：M/S 空间扩展，Mid(正中人声喘息) 100% 保持在耳旁绝不相消，Side(空气泛音) 拓宽包裹
                    let mid = (sL + sR) * 0.5
                    let side = (sL - sR) * 0.5

                    let rIdx = (sideDelayWriteIndex - sideDelayOffset + sideDelayCapacity) % sideDelayCapacity
                    let delayedSide = sideDelayBuffer[rIdx]
                    sideDelayBuffer[sideDelayWriteIndex] = side
                    sideDelayWriteIndex = (sideDelayWriteIndex + 1) % sideDelayCapacity

                    let expandedSide = side * 1.30 + delayedSide * 0.20
                    sL = mid + expandedSide
                    sR = mid - expandedSide
                }

                // 1x ~ 8x 强力突破放大与双曲正切防爆音软压限
                ptrL[i] = applyLimit(sL * currentBoost, enabled: useLimiter)
                ptrR[i] = applyLimit(sR * currentBoost, enabled: useLimiter)
            }
        } else if buffers.count == 1,
                  let ptr = buffers[0].mData?.assumingMemoryBound(to: Float.self) {
            let channels = Int(buffers[0].mNumberChannels)
            if channels == 2 {
                // 双声道交错 (Interleaved: L, R, L, R...)
                for i in 0..<frames {
                    let idxL = i * 2
                    let idxR = i * 2 + 1
                    var sL = ptr[idxL]
                    var sR = ptr[idxR]

                    switch mode {
                    case .standard:
                        break
                    case .whisperBreath:
                        let alpha: Float = 0.35
                        breathFilterL += alpha * (sL - breathFilterL)
                        breathFilterR += alpha * (sR - breathFilterR)
                        let airL = sL - breathFilterL
                        let airR = sR - breathFilterR
                        sL = breathFilterL + 1.68 * airL
                        sR = breathFilterR + 1.68 * airR
                    case .warmIntimate:
                        let satL = sL + 0.08 * (sL * sL) * (sL >= 0 ? 1.0 : -1.0)
                        let satR = sR + 0.08 * (sR * sR) * (sR >= 0 ? 1.0 : -1.0)
                        let beta: Float = 0.62
                        warmFilterL += beta * (satL - warmFilterL)
                        warmFilterR += beta * (satR - warmFilterR)
                        sL = 0.82 * warmFilterL + 0.18 * satL
                        sR = 0.82 * warmFilterR + 0.18 * satR
                    case .binauralAir:
                        let mid = (sL + sR) * 0.5
                        let side = (sL - sR) * 0.5
                        let rIdx = (sideDelayWriteIndex - sideDelayOffset + sideDelayCapacity) % sideDelayCapacity
                        let delayedSide = sideDelayBuffer[rIdx]
                        sideDelayBuffer[sideDelayWriteIndex] = side
                        sideDelayWriteIndex = (sideDelayWriteIndex + 1) % sideDelayCapacity
                        let expandedSide = side * 1.30 + delayedSide * 0.20
                        sL = mid + expandedSide
                        sR = mid - expandedSide
                    }

                    ptr[idxL] = applyLimit(sL * currentBoost, enabled: useLimiter)
                    ptr[idxR] = applyLimit(sR * currentBoost, enabled: useLimiter)
                }
            } else if channels == 1 {
                // 单声道 (Mono)
                for i in 0..<frames {
                    var s = ptr[i]
                    switch mode {
                    case .standard:
                        break
                    case .whisperBreath:
                        let alpha: Float = 0.35
                        breathFilterL += alpha * (s - breathFilterL)
                        let air = s - breathFilterL
                        s = breathFilterL + 1.68 * air
                    case .warmIntimate:
                        let sat = s + 0.08 * (s * s) * (s >= 0 ? 1.0 : -1.0)
                        warmFilterL += 0.62 * (sat - warmFilterL)
                        s = 0.82 * warmFilterL + 0.18 * sat
                    case .binauralAir:
                        break
                    }
                    ptr[i] = applyLimit(s * currentBoost, enabled: useLimiter)
                }
            }
        }
    }

    @inline(__always)
    private func applyLimit(_ sample: Float, enabled: Bool) -> Float {
        guard enabled else {
            return max(-1.0, min(1.0, sample))
        }
        // 双曲正切平滑非线性饱和：当波形超过 0.72 时平滑压缩，保证 8x 强力放大且绝不破音
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

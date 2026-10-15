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

    guard let clientInfo = MTAudioProcessingTapGetStorage(tap) else { return }
    let processor = Unmanaged<StreamDSPProcessor>.fromOpaque(clientInfo).takeUnretainedValue()
    processor.processBufferList(bufferListInOut, frames: Int(numberFramesOut.pointee))
}

// MARK: - 实时流媒体 DSP 音频处理器 (边下边播 + 32位浮点调音台)

final class StreamDSPProcessor {
    static let shared = StreamDSPProcessor()

    // 实时参数 (实时音频线程直接读取生效，零延迟)
    var boostMultiplier: Float = 1.0
    var isLimiterEnabled: Bool = true
    var asmrMode: ASMREffectMode = .standard

    // 预分配立体声延迟缓冲区 (用于 3D 沉浸环绕 Haas 效应，无动态分配)
    private let delayCapacity = 4096
    private var delayBufferL: [Float]
    private var delayBufferR: [Float]
    private var delayWriteIndex: Int = 0
    private let delayOffset: Int = 800 // 约 18ms @ 44.1kHz

    // 单极点低通滤波器状态量
    private var lowPassL: Float = 0.0
    private var lowPassR: Float = 0.0
    private var sleepFilterL: Float = 0.0
    private var sleepFilterR: Float = 0.0

    private init() {
        self.delayBufferL = [Float](repeating: 0.0, count: delayCapacity)
        self.delayBufferR = [Float](repeating: 0.0, count: delayCapacity)
    }

    func resetStates() {
        delayBufferL.withUnsafeMutableBufferPointer { ptr in
            ptr.initialize(repeating: 0.0)
        }
        delayBufferR.withUnsafeMutableBufferPointer { ptr in
            ptr.initialize(repeating: 0.0)
        }
        delayWriteIndex = 0
        lowPassL = 0.0
        lowPassR = 0.0
        sleepFilterL = 0.0
        sleepFilterR = 0.0
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
            // 双声道非交错 (Non-interleaved 独立声道)
            for i in 0..<frames {
                var sL = ptrL[i]
                var sR = ptrR[i]

                switch mode {
                case .standard:
                    break
                case .whisperClean:
                    // 【耳语贴耳】：提取高频呼吸与近场摩擦泛音，提升 +6.5dB，轻微压低低频浑浊
                    lowPassL += 0.25 * (sL - lowPassL)
                    lowPassR += 0.25 * (sR - lowPassR)
                    sL = sL + 1.25 * (sL - lowPassL) - 0.15 * lowPassL
                    sR = sR + 1.25 * (sR - lowPassR) - 0.15 * lowPassR
                case .softSleep:
                    // 【温和助眠】：低通柔化滤波，平滑全部尖锐刺耳毛刺，温润安抚
                    sleepFilterL += 0.38 * (sL - sleepFilterL)
                    sleepFilterR += 0.38 * (sR - sleepFilterR)
                    sL = sleepFilterL
                    sR = sleepFilterR
                case .spatialBinaural:
                    // 【3D 沉浸环绕】：基于 Haas 双耳效应拓宽声场宽度，打造开阔沉浸包裹感
                    let rIdx = (delayWriteIndex - delayOffset + delayCapacity) % delayCapacity
                    let dL = delayBufferL[rIdx]
                    let dR = delayBufferR[rIdx]
                    delayBufferL[delayWriteIndex] = sL
                    delayBufferR[delayWriteIndex] = sR
                    delayWriteIndex = (delayWriteIndex + 1) % delayCapacity
                    sL = sL - 0.32 * dR
                    sR = sR - 0.32 * dL
                }

                // 统一 8.0x 音量突破与防爆音双曲正切软压限
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
                    case .whisperClean:
                        lowPassL += 0.25 * (sL - lowPassL)
                        lowPassR += 0.25 * (sR - lowPassR)
                        sL = sL + 1.25 * (sL - lowPassL) - 0.15 * lowPassL
                        sR = sR + 1.25 * (sR - lowPassR) - 0.15 * lowPassR
                    case .softSleep:
                        sleepFilterL += 0.38 * (sL - sleepFilterL)
                        sleepFilterR += 0.38 * (sR - sleepFilterR)
                        sL = sleepFilterL
                        sR = sleepFilterR
                    case .spatialBinaural:
                        let rIdx = (delayWriteIndex - delayOffset + delayCapacity) % delayCapacity
                        let dL = delayBufferL[rIdx]
                        let dR = delayBufferR[rIdx]
                        delayBufferL[delayWriteIndex] = sL
                        delayBufferR[delayWriteIndex] = sR
                        delayWriteIndex = (delayWriteIndex + 1) % delayCapacity
                        sL = sL - 0.32 * dR
                        sR = sR - 0.32 * dL
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
                    case .whisperClean:
                        lowPassL += 0.25 * (s - lowPassL)
                        s = s + 1.25 * (s - lowPassL) - 0.15 * lowPassL
                    case .softSleep:
                        sleepFilterL += 0.38 * (s - sleepFilterL)
                        s = sleepFilterL
                    case .spatialBinaural:
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

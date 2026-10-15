# AudioBooster (iOS 音频突破放大与一键直连播放器)

[![Build and Package IPA](https://github.com/Wu2200/AudioBooster/actions/workflows/build-ipa.yml/badge.svg)](https://github.com/Wu2200/AudioBooster/actions/workflows/build-ipa.yml)

**AudioBooster** 是一款专为 iOS 设计的音频播放工具，支持突破系统限制的最大音量（最大可放大至 2倍 / 3倍 / 4倍，最高增益 +12.0 dB），并深度支持通过 URL Scheme 外部一键唤醒并自动播放网络音频。仓库内置 GitHub Actions 持续集成工作流，代码提交或点击即可自动打包免签 `.ipa` 文件。

---

## 🚀 核心功能

1. **突破系统最大音量限制 (2x / 3x / 4x 增益)**：
   - 采用 iOS 底层音频管线 `AVMutableAudioMix` 与信号放大增益处理。
   - 提供 4 个预置档位：
     - **1.0x 原声** (0 dB)
     - **2.0x 增强** (+6.0 dB)
     - **3.0x 强力** (+9.5 dB)
     - **4.0x 极限突破** (+12.0 dB)
   - 支持 1.0x ~ 4.0x 连续无级精细滑块调节。

2. **外部一键跳转播放 (URL Scheme)**：
   - 支持自定义协议 `audioboost://`。
   - 外部浏览器、iOS 快捷指令 (Shortcuts)、第三方 App 直接一键跳转自动加载并启动播放。
   - 支持在 URL 中指定增益倍数和标题。

3. **全功能后台与锁屏播放**：
   - 配置后台播放模式 (`UIBackgroundModes: audio`)。
   - 完美适配锁屏与控制中心卡片（NowPlaying），支持锁屏控制播放/暂停/拖动进度。

4. **GitHub Actions 自动化免签打包**：
   - 提交代码或一键触发即可在 GitHub 云端 macOS 环境中自动构建。
   - 自动打包为标准 `AudioBooster.ipa`。
   - 支持直接在 GitHub Releases / Artifacts 免费下载。
   - 适用于 TrollStore (巨魔商店)、AltStore、Sideloadly、牛蛙助手及各类自签证书安装。

---

## 🔗 外部跳转协议 (URL Scheme) 规范

注册的 URL Scheme 为：`audioboost://`

### 1. 标准调用格式
```text
audioboost://play?url=<音频直链URL>&boost=<音量倍数>&title=<标题>
```

#### 参数说明
| 参数名 | 必填 | 说明 | 示例 |
| :--- | :--- | :--- | :--- |
| `url` | 是 | 音频文件的直链地址（建议进行 URL 编码） | `https%3A%2F%2Fexample.com%2Faudio.mp3` |
| `boost`| 否 | 音量放大倍数（支持 1.0 到 4.0，默认 1.0） | `2.0`、`3.0`、`4.0` |
| `title`| 否 | 音频显示标题 | `测试歌曲` |

### 2. 实际链接示例
- **以 2 倍音量播放**：
  ```text
  audioboost://play?url=https%3A%2F%2Factions.google.com%2Fsounds%2Fv1%2Fweather%2Fwind_synthetic.ogg&boost=2.0&title=环境风声
  ```
- **以 4 倍极限音量播放**：
  ```text
  audioboost://play?url=https%3A%2F%2Fexample.com%2Falarm.mp3&boost=4.0
  ```
- **快捷直连格式**：
  ```text
  audioboost://https://example.com/audio.mp3
  ```

---

## 📦 如何下载与安装 IPA

1. 前往本仓库的 [Releases](https://github.com/Wu2200/AudioBooster/releases) 页面。
2. 下载最新发布的 `AudioBooster.ipa`。
3. 安装方式：
   - **TrollStore (巨魔)**：直接在微信/Safari中将 `.ipa` 共享给 TrollStore 安装，永久签名。
   - **AltStore / Sideloadly / 个人签名**：使用电脑端签名工具或设备端签名工具输入 Apple ID 即可完成自签安装。

---

## 🛠 本地工程生成与编译

如果你想要在本地 Mac 进行调试开发：

```bash
# 1. 安装 XcodeGen
brew install xcodegen

# 2. 生成 Xcode 工程
xcodegen generate

# 3. 双击打开生成的工程
open AudioBooster.xcodeproj
```

---

## ⚠️ 注意事项
突破系统最大音量使用了底层音频数字信号增益算法（+6dB 至 +12dB）。请在使用耳机时避免长时间处于 3x / 4x 极端高音量状态，以保护听力。

import Foundation
import CoreGraphics
import ImageIO

func generateAppIcon() {
    let size = CGSize(width: 1024, height: 1024)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

    guard let context = CGContext(
        data: nil,
        width: Int(size.width),
        height: Int(size.height),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: bitmapInfo.rawValue
    ) else {
        print("无法创建图形上下文")
        return
    }

    // 1. 背景渐变 (深邃科技深蓝至午夜蓝黑)
    let bgColors: [CGColor] = [
        CGColor(red: 0.08, green: 0.12, blue: 0.28, alpha: 1.0),
        CGColor(red: 0.04, green: 0.06, blue: 0.14, alpha: 1.0)
    ]
    let bgLocations: [CGFloat] = [0.0, 1.0]
    if let bgGradient = CGGradient(colorsSpace: colorSpace, colors: bgColors as CFArray, locations: bgLocations) {
        context.drawLinearGradient(
            bgGradient,
            start: CGPoint(x: 0, y: 1024),
            end: CGPoint(x: 1024, y: 0),
            options: []
        )
    }

    // 2. 外部声浪发光圆环 (声场扩散与音量突破)
    let center = CGPoint(x: 512, y: 512)
    context.saveGState()
    context.setLineWidth(14)
    context.setStrokeColor(CGColor(red: 0.18, green: 0.50, blue: 1.0, alpha: 0.35))
    context.addArc(center: center, radius: 420, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    context.strokePath()

    context.setLineWidth(10)
    context.setStrokeColor(CGColor(red: 0.30, green: 0.65, blue: 1.0, alpha: 0.55))
    context.addArc(center: center, radius: 360, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    context.strokePath()
    context.restoreGState()

    // 3. 绘制中央扬声器主体 (现代扁平立体风格)
    context.saveGState()
    let speakerColors: [CGColor] = [
        CGColor(red: 0.22, green: 0.58, blue: 1.0, alpha: 1.0),
        CGColor(red: 0.10, green: 0.35, blue: 0.90, alpha: 1.0)
    ]
    let speakerPath = CGMutablePath()

    // 扬声器主体矩形与号角扩展
    speakerPath.move(to: CGPoint(x: 290, y: 430))
    speakerPath.addLine(to: CGPoint(x: 390, y: 430))
    speakerPath.addLine(to: CGPoint(x: 540, y: 310))
    speakerPath.addLine(to: CGPoint(x: 540, y: 714))
    speakerPath.addLine(to: CGPoint(x: 390, y: 594))
    speakerPath.addLine(to: CGPoint(x: 290, y: 594))
    speakerPath.closeSubpath()

    context.addPath(speakerPath)
    context.clip()

    if let speakerGradient = CGGradient(colorsSpace: colorSpace, colors: speakerColors as CFArray, locations: [0.0, 1.0]) {
        context.drawLinearGradient(
            speakerGradient,
            start: CGPoint(x: 290, y: 310),
            end: CGPoint(x: 540, y: 714),
            options: []
        )
    }
    context.restoreGState()

    // 4. 绘制突破音浪弧线 (2x, 3x, 4x 声浪)
    func drawSoundWave(radius: CGFloat, lineWidth: CGFloat, color: CGColor) {
        context.saveGState()
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setStrokeColor(color)
        context.addArc(
            center: CGPoint(x: 460, y: 512),
            radius: radius,
            startAngle: -.pi / 3.8,
            endAngle: .pi / 3.8,
            clockwise: false
        )
        context.strokePath()
        context.restoreGState()
    }

    // 第 1 级音浪 (原声/2x)
    drawSoundWave(radius: 170, lineWidth: 28, color: CGColor(red: 0.20, green: 0.70, blue: 1.0, alpha: 0.95))
    // 第 2 级音浪 (3x 强力增益)
    drawSoundWave(radius: 250, lineWidth: 32, color: CGColor(red: 1.0, green: 0.65, blue: 0.15, alpha: 0.95))
    // 第 3 级音浪 (4x 极限突破)
    drawSoundWave(radius: 330, lineWidth: 36, color: CGColor(red: 1.0, green: 0.28, blue: 0.35, alpha: 0.95))

    // 5. 绘制中央电光增益突破标志 (Lightning Boost)
    context.saveGState()
    let boltPath = CGMutablePath()
    boltPath.move(to: CGPoint(x: 410, y: 640))
    boltPath.addLine(to: CGPoint(x: 330, y: 505))
    boltPath.addLine(to: CGPoint(x: 400, y: 505))
    boltPath.addLine(to: CGPoint(x: 350, y: 380))
    boltPath.addLine(to: CGPoint(x: 470, y: 525))
    boltPath.addLine(to: CGPoint(x: 405, y: 525))
    boltPath.closeSubpath()

    context.addPath(boltPath)
    context.clip()

    let boltColors: [CGColor] = [
        CGColor(red: 1.0, green: 0.92, blue: 0.25, alpha: 1.0),
        CGColor(red: 1.0, green: 0.55, blue: 0.05, alpha: 1.0)
    ]
    if let boltGradient = CGGradient(colorsSpace: colorSpace, colors: boltColors as CFArray, locations: [0.0, 1.0]) {
        context.drawLinearGradient(
            boltGradient,
            start: CGPoint(x: 330, y: 640),
            end: CGPoint(x: 470, y: 380),
            options: []
        )
    }
    context.restoreGState()

    // 6. 保存为 PNG 文件
    guard let image = context.makeImage() else {
        print("无法生成图像")
        return
    }

    let outputPath = "AudioBooster/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
    let url = URL(fileURLWithPath: outputPath)

    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        print("无法创建文件目标: \(outputPath)")
        return
    }

    CGImageDestinationAddImage(destination, image, nil)
    if CGImageDestinationFinalize(destination) {
        print("成功生成 App 图标: \(outputPath)")
    } else {
        print("生成图标保存失败")
    }
}

generateAppIcon()

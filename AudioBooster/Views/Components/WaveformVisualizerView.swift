import SwiftUI

struct WaveformVisualizerView: View {
    @AppStorage("selectedBackgroundTheme") private var selectedBackgroundTheme = "cream"
    var isPlaying: Bool
    var boostMultiplier: Float

    @State private var phase: CGFloat = 0

    private var selectedTheme: SoftColorTheme {
        SoftColorTheme.option(for: selectedBackgroundTheme)
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<18, id: \.self) { index in
                RoundedRectangle(cornerRadius: 3)
                    .fill(barColor(for: index))
                    .frame(width: 4, height: barHeight(for: index))
                    .animation(
                        isPlaying ? Animation.easeInOut(duration: 0.35)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.04) : .default,
                        value: isPlaying
                    )
            }
        }
        .frame(height: 50)
        .onAppear {
            phase = 1
        }
    }

    private func barHeight(for index: Int) -> CGFloat {
        if !isPlaying { return 6 }
        let baseHeight: CGFloat = CGFloat((index * 7 + 11) % 25 + 10)
        let boostFactor: CGFloat = CGFloat(min(boostMultiplier, 4.0)) / 2.0
        return min(50, baseHeight * boostFactor)
    }

    private func barColor(for index: Int) -> Color {
        if boostMultiplier >= 3.5 {
            return Color.red
        } else if boostMultiplier >= 2.5 {
            return Color.orange
        } else if boostMultiplier >= 1.5 {
            return Color.yellow
        } else {
            return selectedTheme.accentColor
        }
    }
}

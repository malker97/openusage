import SwiftUI

/// Fixed-size, SwiftUI-only activity indicator for Monterey. Its native ProgressView bridge can
/// report invalid layout dimensions when inserted/removed inside an animated settings row.
struct LegacyActivityIndicator: View {
    var controlSize: ControlSize = .small
    @State private var spinning = false

    private var side: CGFloat { controlSize == .mini ? 12 : 16 }

    var body: some View {
        Circle()
            .trim(from: 0.15, to: 0.85)
            .stroke(.secondary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .frame(width: side, height: side)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 0.8).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
            .onDisappear { spinning = false }
    }
}

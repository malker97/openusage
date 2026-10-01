import SwiftUI

/// Cosmetic APIs that arrived after Monterey. Keep the functional controls on macOS 12.
extension View {
    @ViewBuilder
    func numericTextTransition() -> some View {
        if #available(macOS 14, *) {
            contentTransition(.numericText())
        } else {
            self
        }
    }

    @ViewBuilder
    func copySymbolBounce(value: Bool) -> some View {
        if #available(macOS 14, *) {
            symbolEffect(.bounce, value: value)
        } else {
            self
        }
    }

    @ViewBuilder
    func circularButtonBorder() -> some View {
        if #available(macOS 14, *) {
            buttonBorderShape(.circle)
        } else {
            self
        }
    }

    @ViewBuilder
    func popoverScrollBounceBehavior() -> some View {
        if #available(macOS 13.3, *) {
            scrollBounceBehavior(.basedOnSize)
        } else {
            self
        }
    }
}

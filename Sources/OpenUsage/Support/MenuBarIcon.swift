import AppKit
import SwiftUI

/// Renders the OpenUsage brand gauge mark into a template `NSImage` for the menu bar.
/// Reuses the same SVG→`ProviderIconShape` pipeline as the provider tiles, so there is no
/// asset catalog or second SVG parser to maintain.
@MainActor
enum MenuBarIcon {
    /// Side length (points) of the menu bar glyph.
    private static let side: CGFloat = 18

    /// Cached template image, or `nil` if the brand mark fails to load/parse.
    static let image: NSImage? = render()

    private static func render() -> NSImage? {
        guard let mark = ProviderMarks.mark(for: "openusage") else { return nil }
        // The art already carries ~8% margin inside the source viewBox.
        let content = ProviderIconShape(mark: mark, inset: 0.08)
            .fill(Color.black)
            .frame(width: side, height: side)
        guard let cgImage = ViewImageRenderer.cgImage(for: content, scale: 2) else { return nil }
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: side, height: side))
        nsImage.isTemplate = true
        return nsImage
    }
}

import AppKit
import SwiftUI

/// One rasterization boundary for menu-bar images and share cards. Monterey predates ImageRenderer.
@MainActor
enum ViewImageRenderer {
    static func cgImage<Content: View>(for content: Content, scale: CGFloat) -> CGImage? {
        if #available(macOS 13, *) {
            let renderer = ImageRenderer(content: content)
            renderer.scale = scale
            guard let image = renderer.cgImage else {
                AppLog.error(.lifecycle, "view render: ImageRenderer produced no image")
                return nil
            }
            return image
        }
        return legacyCGImage(for: content, scale: scale)
    }

    /// Internal entry point so CI can exercise the Monterey renderer even on a newer host.
    /// The temporary window is never ordered on-screen and is released after this synchronous render.
    static func legacyCGImage<Content: View>(for content: Content, scale: CGFloat) -> CGImage? {
        let host = NSHostingView(rootView: content.fixedSize())
        let size = host.fittingSize
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else {
            AppLog.error(.lifecycle, "view render: invalid off-screen fitting size \(size)")
            return nil
        }
        let bounds = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = host
        host.frame = bounds
        defer {
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((size.width * scale).rounded(.up)),
            pixelsHigh: Int((size.height * scale).rounded(.up)),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else {
            AppLog.error(.lifecycle, "view render: could not allocate off-screen bitmap")
            return nil
        }
        bitmap.size = size
        host.cacheDisplay(in: bounds, to: bitmap)
        guard let image = bitmap.cgImage else {
            AppLog.error(.lifecycle, "view render: off-screen bitmap produced no image")
            return nil
        }
        return image
    }
}

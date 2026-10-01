import AppKit
import SwiftUI
import XCTest
@testable import OpenUsage

@MainActor
final class MontereyCompatibilityTests: XCTestCase {
    func testLegacyRendererPreservesScaleAndTransparency() throws {
        let content = ZStack {
            Color.clear
            Rectangle().fill(Color.black).frame(width: 8, height: 8)
        }
        .frame(width: 18, height: 18)
        let image = try XCTUnwrap(ViewImageRenderer.legacyCGImage(for: content, scale: 2))
        XCTAssertEqual(image.width, 36)
        XCTAssertEqual(image.height, 36)
        let bitmap = NSBitmapImageRep(cgImage: image)
        XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: 18, y: 18)).alphaComponent, 0.9)
        XCTAssertLessThan(try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)).alphaComponent, 0.1)
    }

    func testLegacyRendererRendersCanvasUsedByMenuBarBars() throws {
        let content = Canvas { context, _ in
            context.fill(Path(CGRect(x: 4, y: 4, width: 10, height: 10)), with: .color(.black))
        }
        .frame(width: 18, height: 18)
        let image = try XCTUnwrap(ViewImageRenderer.legacyCGImage(for: content, scale: 2))
        let bitmap = NSBitmapImageRep(cgImage: image)
        XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: 18, y: 18)).alphaComponent, 0.9)
    }

    func testLegacyRendererCanExportARealShareCard() throws {
        let provider = MockData.claude
        let card = ShareCardView(
            provider: provider, plan: "Max",
            rows: MockData.descriptors(for: provider.id).map { $0.sample }, appearance: .light
        )
        let image = try XCTUnwrap(ViewImageRenderer.legacyCGImage(for: card, scale: ShareCardRenderer.scale))
        XCTAssertEqual(image.width, Int(ShareCardView.width * ShareCardRenderer.scale))
        XCTAssertGreaterThan(image.height, 0)
        let nsImage = NSImage(cgImage: image, size: NSSize(width: ShareCardView.width, height: CGFloat(image.height) / ShareCardRenderer.scale))
        let png = try XCTUnwrap(ShareCardRenderer.pngData(from: nsImage))
        XCTAssertNotNil(NSImage(data: png))
    }

    func testLegacyBarPathKeepsItsBoundsWithAsymmetricEnds() {
        let rect = CGRect(x: 2, y: 3, width: 14, height: 5)
        let path = MenuBarBarGeometry.legacyPath(in: rect, leading: 2, trailing: 0)
        XCTAssertEqual(path.boundingRect, rect)
    }

    func testFractionalDelaysRemainExact() {
        XCTAssertEqual(DelayDuration.seconds(1.4).nanoseconds, 1_400_000_000)
        XCTAssertEqual(DelayDuration.milliseconds(180).nanoseconds, 180_000_000)
    }

    func testLongDelayStillRespondsToCancellation() async {
        let task = Task { try await AsyncDelay.sleep(for: .seconds(60)) }
        task.cancel()
        do {
            try await task.value
            XCTFail("A cancelled delay must not report successful completion")
        } catch is CancellationError {
            // Expected: cancellation must not wait out the deadline on Monterey.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testLockedStateSerializesConcurrentUpdates() {
        let value = Locked(initialState: 0)
        DispatchQueue.concurrentPerform(iterations: 1_000) { _ in value.withLock { $0 += 1 } }
        XCTAssertEqual(value.withLock { $0 }, 1_000)
    }
}

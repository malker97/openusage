import SwiftUI
import XCTest
@testable import OpenUsage

@MainActor
final class ProviderMarksTests: XCTestCase {
    func testProviderVectorMarksLoadWithoutFallbacks() throws {
        for id in ["claude", "codex", "cursor", "deepseek", "devin", "grok"] {
            let mark = try XCTUnwrap(ProviderMarks.mark(for: id), "\(id) should load a vector mark")
            XCTAssertFalse(mark.path.isEmpty, "\(id) mark must carry SVG path data")
        }
    }

    /// The shape parser handles only the commands the bundled marks use. An arc (`A`/`a`) or any other
    /// command silently truncates the mark at that point, so every shipped SVG must stay within the
    /// supported set and still parse into real geometry.
    func testEveryProviderMarkUsesOnlySupportedPathCommands() throws {
        let supported = Set("MLHVCSQTZmlhvcsqtz".map(String.init))
        let urls = try XCTUnwrap(
            Bundle.openUsageResources.urls(forResourcesWithExtension: "svg", subdirectory: "ProviderIcons"),
            "provider marks should be bundled"
        )
        XCTAssertFalse(urls.isEmpty)

        for url in urls {
            let name = url.deletingPathExtension().lastPathComponent
            let text = try String(contentsOf: url, encoding: .utf8)
            let data = Self.pathData(in: text)
            XCTAssertFalse(data.isEmpty, "\(name) should carry a path")
            let commands = Set(data.flatMap { $0.isLetter ? [String($0)] : [] })
            XCTAssertTrue(commands.isSubset(of: supported), "\(name) uses unsupported path commands: \(commands.subtracting(supported))")
            let path = SVGPath.parse(data)
            XCTAssertFalse(path.isEmpty, "\(name) should parse into a drawable path")
            XCTAssertGreaterThan(path.boundingRect.width, 1, "\(name) should span a real width")
            XCTAssertGreaterThan(path.boundingRect.height, 1, "\(name) should span a real height")
        }
    }

    /// The concatenated `d` attributes of one SVG, the same way `ProviderMarks` reads them.
    private static func pathData(in svg: String) -> String {
        var values: [String] = []
        var searchStart = svg.startIndex
        while let start = svg[searchStart...].range(of: "d=\"") {
            let rest = svg[start.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { break }
            values.append(String(rest[..<end]))
            searchStart = end
        }
        return values.joined(separator: " ")
    }
}

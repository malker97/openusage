import Foundation
import XCTest

final class MacOSSupportScriptTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func testManifestAndBundleBuildersUseTheSameMontereyFloor() throws {
        let manifest = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
        XCTAssertTrue(manifest.contains(".macOS(.v12)"))
        let support = try String(contentsOf: root.appendingPathComponent("script/macos_support.sh"), encoding: .utf8)
        XCTAssertTrue(support.contains("MIN_SYSTEM_VERSION=\"12.0\""))
        for name in ["build_and_run.sh", "release.sh", "compile_icon.sh"] {
            let script = try String(contentsOf: root.appendingPathComponent("script/\(name)"), encoding: .utf8)
            XCTAssertTrue(script.contains("source \"$ROOT_DIR/script/macos_support.sh\""), name)
        }
    }

    func testDeploymentCheckerIgnoresTheLinkerToolVersion() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageDeployment-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let contents = directory.appendingPathComponent("Fixture.app/Contents")
        for path in ["MacOS", "Helpers"] {
            try FileManager.default.createDirectory(at: contents.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        let executable = try XCTUnwrap(Bundle(for: Self.self).executableURL)
        for path in ["MacOS/OpenUsage", "Helpers/openusage"] {
            try FileManager.default.copyItem(at: executable, to: contents.appendingPathComponent(path))
        }
        let plist: [String: String] = ["LSMinimumSystemVersion": "12.0"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [root.appendingPathComponent("script/check_macos_support.sh").path,
                             directory.appendingPathComponent("Fixture.app").path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "LD's version is not the deployment target")
    }

    func testSDKStampRefusesToDisguiseANewerDeploymentTarget() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            "-c",
            """
            set -euo pipefail
            source "$1"
            xcrun() {
              if [ "$2" = "-show-build" ]; then
                printf ' minos 15.0\\n sdk 26.0\\n'
              else
                echo 'The incompatible binary must never be rewritten' >&2
                exit 99
              fi
            }
            stamp_linked_sdk /unused/OpenUsage
            """,
            "deployment-floor-test", root.appendingPathComponent("script/macos_support.sh").path
        ]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        let output = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 1)
        XCTAssertTrue(output.contains("Refusing to lower minos"))
    }
}

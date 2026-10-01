import Foundation
import XCTest
@testable import OpenUsage

final class LegacyLoginAgentTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testEnablingWritesAnAgentThatOpensThisBundleAtLogin() throws {
        let agent = makeAgent(bundlePath: "/Applications/OpenUsage.app")
        XCTAssertFalse(agent.isEnabled)

        try agent.setEnabled(true)

        XCTAssertTrue(agent.isEnabled)
        XCTAssertEqual(agent.agentURL.lastPathComponent, "com.example.openusage.launch-at-login.plist")
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: agent.agentURL), format: nil
        ) as? [String: Any])
        XCTAssertEqual(plist["Label"] as? String, "com.example.openusage.launch-at-login")
        XCTAssertEqual(plist["ProgramArguments"] as? [String], ["/usr/bin/open", "/Applications/OpenUsage.app"])
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(plist["LimitLoadToSessionType"] as? String, "Aqua")
    }

    func testAgentForAMovedCopyReadsAsOffUntilRepointed() throws {
        try makeAgent(bundlePath: "/Users/me/Downloads/OpenUsage.app").setEnabled(true)
        let installed = makeAgent(bundlePath: "/Applications/OpenUsage.app")

        XCTAssertFalse(installed.isEnabled)
        try installed.setEnabled(true)
        XCTAssertTrue(installed.isEnabled)
    }

    func testDisablingRemovesTheAgentAndIsIdempotent() throws {
        let agent = makeAgent(bundlePath: "/Applications/OpenUsage.app")
        try agent.setEnabled(true)

        try agent.setEnabled(false)
        try agent.setEnabled(false)

        XCTAssertFalse(agent.isEnabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: agent.agentURL.path))
    }

    func testUnbundledRunsCannotRegister() {
        let agent = makeAgent(bundlePath: "/Users/dev/openusage/.build/debug")
        XCTAssertThrowsError(try agent.setEnabled(true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: agent.agentURL.path))
    }

    func testUnreadableAgentReadsAsOff() throws {
        let agent = makeAgent(bundlePath: "/Applications/OpenUsage.app")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not a plist".utf8).write(to: agent.agentURL)
        XCTAssertFalse(agent.isEnabled)
    }

    func testNeverUsesTheLegacyTauriAgentName() {
        let agent = makeAgent(bundlePath: "/Applications/OpenUsage.app")
        XCTAssertNotEqual(agent.agentURL.lastPathComponent, LegacyLaunchAgentCleanup.defaultAgentURL.lastPathComponent)
    }

    private func makeAgent(bundlePath: String) -> LegacyLoginAgent {
        LegacyLoginAgent(
            bundleIdentifier: "com.example.openusage",
            bundlePath: bundlePath,
            launchAgentsDirectory: directory
        )
    }
}

import Foundation

/// Launch at Login before macOS 13, where `SMAppService` doesn't exist: a per-user LaunchAgent that
/// opens this app bundle through LaunchServices at login.
///
/// File-only, like `LegacyLaunchAgentCleanup`: launchd loads agents from disk at login, so writing or
/// deleting the plist is the whole switch and never relaunches or stops the running copy. The file is
/// named after the bundle identifier, never the legacy Tauri `OpenUsage.plist` that cleanup removes.
struct LegacyLoginAgent {
    struct NotAnAppBundle: LocalizedError {
        var errorDescription: String? { "Launch at Login needs the app to run from its .app bundle." }
    }

    let label: String
    let agentURL: URL
    let bundlePath: String

    init(
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.robinebers.openusage",
        bundlePath: String = Bundle.main.bundlePath,
        launchAgentsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    ) {
        label = "\(bundleIdentifier).launch-at-login"
        agentURL = launchAgentsDirectory.appendingPathComponent("\(label).plist")
        self.bundlePath = (bundlePath as NSString).standardizingPath
    }

    /// On only when the agent opens this exact bundle, so a moved or reinstalled copy reads as off and
    /// turning the switch back on repoints it.
    var isEnabled: Bool {
        guard FileManager.default.fileExists(atPath: agentURL.path) else { return false }
        do {
            let plist = try PropertyListSerialization.propertyList(
                from: Data(contentsOf: agentURL), format: nil
            )
            return (plist as? [String: Any])?["ProgramArguments"] as? [String] == programArguments
        } catch {
            AppLog.warn(.lifecycle, "couldn't read login agent \(agentURL.path): \(error.localizedDescription)")
            return false
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        let fileManager = FileManager.default
        guard enabled else {
            if fileManager.fileExists(atPath: agentURL.path) { try fileManager.removeItem(at: agentURL) }
            return
        }
        guard bundlePath.hasSuffix(".app") else { throw NotAnAppBundle() }
        try fileManager.createDirectory(
            at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": programArguments,
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive"
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: agentURL, options: .atomic)
    }

    private var programArguments: [String] { ["/usr/bin/open", bundlePath] }
}

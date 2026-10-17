import Foundation

/// Turns on DeepSeek for a machine where pi already has a DeepSeek API key saved.
///
/// The card reads only pi's session logs, so nothing here is sent anywhere; the key's presence is the
/// signal that this machine actually produces DeepSeek usage. Mirrors `~/.pi/agent/auth.json` (or
/// `$PI_CODING_AGENT_DIR/auth.json`), the same file pi writes when `pi` is set up with DeepSeek.
struct DeepSeekAuthStore: Sendable {
    /// The entry pi stores for its DeepSeek provider.
    static let piProviderID = "deepseek"

    var files: TextFileAccessing = LocalTextFileAccessor()
    var environment: EnvironmentReading = ProcessEnvironmentReader()
    var homeDirectory: @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser }

    /// A saved pi key counts as `{"type": "api_key", "key": "…"}`. Anything else (missing entry, `oauth`,
    /// blank key) means pi doesn't drive DeepSeek on this machine.
    func hasPiAPIKey() -> Bool {
        let path = PiPaths.agentDirectory(environment: environment, homeDirectory: homeDirectory())
            .appendingPathComponent("auth.json").path
        let object: [String: Any]
        do {
            guard let text = try files.readTextIfPresent(path),
                  let parsed = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
            else { return false }
            object = parsed
        } catch {
            // A present-but-unreadable auth file is a real problem, not a logout: log it and stay off.
            AppLog.error(.config, "DeepSeek: pi auth.json could not be read: \(error.localizedDescription)")
            return false
        }
        guard let entry = object[Self.piProviderID] as? [String: Any],
              entry["type"] as? String == "api_key",
              let key = entry["key"] as? String
        else { return false }
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

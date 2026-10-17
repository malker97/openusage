import Foundation

/// Where pi stores its session logs on this machine. Resolution mirrors pi itself: an explicit
/// `PI_CODING_AGENT_SESSION_DIR` wins, else `PI_CODING_AGENT_DIR/sessions` (the config-dir override),
/// else the default `~/.pi/agent/sessions`. Pi writes one `*.jsonl` per session under a
/// per-working-directory subfolder, so the directory is scanned recursively.
enum PiPaths {
    /// pi's agent directory (`~/.pi/agent`): where `auth.json` and its other state live.
    static func agentDirectory(environment: EnvironmentReading, homeDirectory: URL) -> URL {
        if let configDir = environment.value(for: "PI_CODING_AGENT_DIR")?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            return URL(fileURLWithPath: expandHome(configDir))
        }
        return homeDirectory.appendingPathComponent(".pi/agent")
    }

    static func sessionsDirectory(environment: EnvironmentReading, homeDirectory: URL) -> URL {
        if let override = environment.value(for: "PI_CODING_AGENT_SESSION_DIR")?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            return URL(fileURLWithPath: expandHome(override))
        }
        return agentDirectory(environment: environment, homeDirectory: homeDirectory)
            .appendingPathComponent("sessions")
    }
}

import Perception
import ServiceManagement

/// Keeps the Launch at Login switch aligned with macOS without treating a failed rollback as a
/// second user action.
@MainActor
@Perceptible
final class LaunchAtLoginSetting {
    static let failureMessage = "macOS wouldn't update Launch at Login. Check System Settings → Login Items."

    private(set) var isEnabled: Bool
    private(set) var errorMessage: String?

    private let currentStatus: () -> Bool
    private let setSystemEnabled: (Bool) throws -> Void

    init(
        currentStatus: @escaping () -> Bool = LaunchAtLoginSetting.loginItemStatus,
        setEnabled: @escaping (Bool) throws -> Void = LaunchAtLoginSetting.setLoginItem
    ) {
        self.currentStatus = currentStatus
        self.setSystemEnabled = setEnabled
        self.isEnabled = currentStatus()
    }

    /// Reconcile changes made in System Settings without registering or unregistering the login item.
    func refreshStatus() {
        let enabled = currentStatus()
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        errorMessage = nil
    }

    /// macOS 13+ uses the system login-item registry; earlier systems use a per-user LaunchAgent. A
    /// Monterey agent survives an OS upgrade, so it counts as on until any change replaces it.
    nonisolated static func loginItemStatus() -> Bool {
        let agentEnabled = LegacyLoginAgent().isEnabled
        if #available(macOS 13, *) { return agentEnabled || SMAppService.mainApp.status == .enabled }
        return agentEnabled
    }

    nonisolated static func setLoginItem(_ enabled: Bool) throws {
        guard #available(macOS 13, *) else {
            try LegacyLoginAgent().setEnabled(enabled)
            return
        }
        try LegacyLoginAgent().setEnabled(false)
        if enabled {
            try SMAppService.mainApp.register()
        } else if SMAppService.mainApp.status == .enabled {
            try SMAppService.mainApp.unregister()
        }
    }

    func update(to enabled: Bool) {
        guard enabled != isEnabled else { return }
        do {
            try setSystemEnabled(enabled)
            isEnabled = currentStatus()
            errorMessage = nil
        } catch {
            AppLog.error(
                .config,
                "Launch at Login \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)"
            )
            isEnabled = currentStatus()
            errorMessage = Self.failureMessage
        }
    }
}

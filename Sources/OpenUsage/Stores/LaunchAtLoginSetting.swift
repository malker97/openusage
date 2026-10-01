import Perception
import ServiceManagement

/// Keeps the Launch at Login switch aligned with macOS without treating a failed rollback as a
/// second user action.
@MainActor
@Perceptible
final class LaunchAtLoginSetting {
    static let failureMessage = "macOS wouldn't update Launch at Login. Check System Settings → Login Items."

    static var isSupported: Bool {
        if #available(macOS 13, *) { return true }
        return false
    }

    private(set) var isEnabled: Bool
    private(set) var errorMessage: String?

    private let currentStatus: () -> Bool
    private let setSystemEnabled: (Bool) throws -> Void

    init(
        currentStatus: @escaping () -> Bool = {
            if #available(macOS 13, *) { return SMAppService.mainApp.status == .enabled }
            return false
        },
        setEnabled: @escaping (Bool) throws -> Void = { enabled in
            guard #available(macOS 13, *) else {
                throw LaunchAtLoginUnavailable()
            }
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        }
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

    private struct LaunchAtLoginUnavailable: Error {}

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

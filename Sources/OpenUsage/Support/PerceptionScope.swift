import Combine
import Perception
import SwiftUI

/// Re-renders its content when `@Perceptible` state read inside it changes. Use it instead of
/// Perception's `WithPerceptionTracking`, which leaks on macOS 13 and earlier.
///
/// `WithPerceptionTracking` installs a new one-shot observation on every evaluation and removes an
/// earlier one only when something it read changes (pointfreeco/swift-perception#51). Views also
/// re-render for other reasons — a parent refresh, a `TimelineView` tick — so observations of rarely
/// changing state piled up, each holding a copy of the view. On Monterey, with iCloud sync rebuilding
/// the dashboard every minute or two, the app passed 750 MB in a week. Here every evaluation first
/// retires the previous observation, so a view keeps at most one.
///
/// macOS 14+ tracks `@Perceptible` models natively, so the content is evaluated directly there.
struct PerceptionScope<Content: View>: View {
    @StateObject private var session = PerceptionSession()
    private let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: Content {
        if #available(macOS 14, *) { return content() }
        return session.track(content)
    }
}

/// One view's observation of `@Perceptible` state. `track` retires the previous observation, then
/// observes whatever `apply` reads; a change publishes `objectWillChange` once.
@MainActor
final class PerceptionSession: ObservableObject {
    private let token = PerceptionSessionToken()
    /// True only while the previous observation is being retired, so its handler stays silent.
    private let retiring = Locked(initialState: false)

    func track<T>(_ apply: () -> T) -> T {
        // Every observation also reads the token, so changing it fires the pending one. Perception
        // cancels a fired observation's registrations in every model it read; its public API offers
        // no other way to cancel one.
        retiring.withLock { $0 = true }
        token.generation &+= 1
        retiring.withLock { $0 = false }

        let retiring = retiring
        return withPerceptionTracking {
            _ = token.generation
            return apply()
        } onChange: { [weak self] in
            guard !retiring.withLock({ $0 }) else { return }
            Task { @MainActor [weak self] in self?.objectWillChange.send() }
        }
    }
}

@Perceptible
private final class PerceptionSessionToken {
    var generation = 0
}

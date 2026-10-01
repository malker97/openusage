import Foundation

/// UI dwell times and refresh deadlines do not need Swift's macOS 13-only Clock/Duration APIs.
/// Keep cancellation and monotonic sleeping through Task.sleep(nanoseconds:), available on Monterey.
struct DelayDuration: Sendable, Equatable {
    let nanoseconds: UInt64

    static func seconds(_ value: Double) -> Self {
        Self(nanoseconds: UInt64((value * 1_000_000_000).rounded()))
    }

    static func milliseconds(_ value: Double) -> Self {
        Self(nanoseconds: UInt64((value * 1_000_000).rounded()))
    }

}

enum AsyncDelay {
    static func sleep(for duration: DelayDuration) async throws {
        try await Task<Never, Never>.sleep(nanoseconds: duration.nanoseconds)
    }
}

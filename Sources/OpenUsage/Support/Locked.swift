import Foundation

/// A heap-owned lock and its state. Unlike OSAllocatedUnfairLock, this is available on Monterey.
/// All state access stays inside the synchronous critical section; never suspend while holding it.
final class Locked<State>: @unchecked Sendable {
    private let lock = NSLock()
    private var state: State

    init(initialState: State) {
        state = initialState
    }

    func withLock<Result>(_ operation: (inout State) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try operation(&state)
    }
}

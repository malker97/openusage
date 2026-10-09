import Combine
import Perception
import XCTest
@testable import OpenUsage

/// Regression coverage for the Monterey memory leak: views re-render for reasons other than the
/// state they read, and every evaluation used to leave one more observation registered.
@MainActor
final class PerceptionScopeTests: XCTestCase {
    func testRepeatedEvaluationsWithoutChangesKeepOneObservation() async throws {
        let probe = Probe()
        let session = PerceptionSession()
        let changes = Locked(initialState: 0)
        let subscription = session.objectWillChange.sink { changes.withLock { $0 += 1 } }
        defer { subscription.cancel() }

        for _ in 0..<100 {
            _ = session.track { probe.value }
        }
        probe.value += 1

        try await settle()
        XCTAssertEqual(changes.withLock { $0 }, 1, "only the latest evaluation may still be observing")
    }

    func testReevaluatingRetiresObservationOfStateNoLongerRead() async throws {
        let first = Probe()
        let second = Probe()
        let session = PerceptionSession()
        let changes = Locked(initialState: 0)
        let subscription = session.objectWillChange.sink { changes.withLock { $0 += 1 } }
        defer { subscription.cancel() }

        _ = session.track { first.value }
        _ = session.track { second.value }
        first.value += 1
        try await settle()
        XCTAssertEqual(changes.withLock { $0 }, 0, "the earlier evaluation's observation must be cancelled")

        second.value += 1
        try await settle()
        XCTAssertEqual(changes.withLock { $0 }, 1)
    }

    func testRetiringTheEarlierObservationDoesNotRequestARender() async throws {
        let probe = Probe()
        let session = PerceptionSession()
        let changes = Locked(initialState: 0)
        let subscription = session.objectWillChange.sink { changes.withLock { $0 += 1 } }
        defer { subscription.cancel() }

        _ = session.track { probe.value }
        _ = session.track { probe.value }

        try await settle()
        XCTAssertEqual(changes.withLock { $0 }, 0, "re-rendering must not schedule another render")
    }

    func testObservationRearmsAfterEachChange() async throws {
        let probe = Probe()
        let session = PerceptionSession()
        let changes = Locked(initialState: 0)
        let subscription = session.objectWillChange.sink { changes.withLock { $0 += 1 } }
        defer { subscription.cancel() }

        for expected in 1...3 {
            _ = session.track { probe.value }
            probe.value += 1
            try await settle()
            XCTAssertEqual(changes.withLock { $0 }, expected)
        }
    }

    /// Documents the upstream behavior the session works around, so a future Perception fix shows up
    /// here rather than going unnoticed.
    func testPlainPerceptionTrackingAccumulatesUntilAChange() async throws {
        let probe = Probe()
        let fired = Locked(initialState: 0)
        for _ in 0..<5 {
            _ = withPerceptionTracking { probe.value } onChange: { fired.withLock { $0 += 1 } }
        }
        probe.value += 1
        XCTAssertEqual(fired.withLock { $0 }, 5)
    }

    /// Lets the main-actor tasks scheduled by change handlers run.
    private func settle() async throws {
        for _ in 0..<5 { await Task.yield() }
        try await AsyncDelay.sleep(for: .milliseconds(20))
    }
}

@Perceptible
private final class Probe {
    var value = 0
}

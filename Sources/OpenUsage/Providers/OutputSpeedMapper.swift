import Foundation

/// One finished model response, timed end to end for the Output Speed row: from the request being sent
/// to its last token. `outputTokens` includes reasoning, which is generated (and billed) like visible text.
struct ResponseTiming: Hashable, Sendable {
    var end: Date
    var duration: TimeInterval
    var outputTokens: Int
}

/// Builds the Output Speed row from the timed responses a provider's local logs record: the median
/// tokens per second of the responses that finished in the five minutes up to the latest one. Anchoring
/// on the latest response rather than the clock keeps the last session's speed on screen while you're
/// away. The timing includes the wait for the first token, so it reads below a provider's published
/// generation speed.
enum OutputSpeedMapper {
    /// The median speed of the responses in the window, and when the latest of them finished.
    struct Reading: Equatable {
        var tokensPerSecond: Double
        var latest: Date
    }

    static let label = "Output Speed"
    static let window: TimeInterval = 5 * 60
    /// Short replies mostly measure the wait for the first token, not generation.
    static let minimumOutputTokens = 50

    /// Appends nothing when no response qualifies, so the row reads "No data" rather than a made-up zero.
    /// Once the latest response is more than five minutes old the reading is the last session's, so it
    /// carries when that was and the row shows its age ("49 tok/s · 18m ago").
    static func appendOutputSpeed(_ timings: [ResponseTiming], to lines: inout [MetricLine], now: Date) {
        guard let reading = reading(timings, now: now) else { return }
        let isLastSession = now.timeIntervalSince(reading.latest) > window
        lines.append(.values(
            label: label,
            values: [MetricValue(
                number: reading.tokensPerSecond.rounded(), kind: .count, label: "tok/s",
                asOf: isLastSession ? reading.latest : nil
            )]
        ))
    }

    /// The median per-response speed, so one stalled request can't drag the reading the way an average
    /// over total time would. A response stamped after `now` (say, after the clock was set back) hasn't
    /// finished as far as this reading knows.
    static func reading(_ timings: [ResponseTiming], now: Date) -> Reading? {
        let finished = timings.filter {
            $0.end <= now && $0.duration > 0 && $0.outputTokens >= minimumOutputTokens
        }
        guard let latest = finished.map(\.end).max() else { return nil }
        let start = latest.addingTimeInterval(-window)
        let speeds = finished
            .filter { $0.end >= start }
            .map { Double($0.outputTokens) / $0.duration }
            .sorted()
        let middle = speeds.count / 2
        let median = speeds.count.isMultiple(of: 2) ? (speeds[middle - 1] + speeds[middle]) / 2 : speeds[middle]
        return Reading(tokensPerSecond: median, latest: latest)
    }
}

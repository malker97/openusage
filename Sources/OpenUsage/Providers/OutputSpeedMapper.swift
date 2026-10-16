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
    static let label = "Output Speed"
    static let window: TimeInterval = 5 * 60
    /// Short replies mostly measure the wait for the first token, not generation.
    static let minimumOutputTokens = 50

    /// Appends nothing when no response qualifies, so the row reads "No data" rather than a made-up zero.
    static func appendOutputSpeed(_ timings: [ResponseTiming], to lines: inout [MetricLine], now: Date) {
        guard let speed = medianTokensPerSecond(timings, now: now) else { return }
        lines.append(.values(
            label: label,
            values: [MetricValue(number: speed.rounded(), kind: .count, label: "tok/s")]
        ))
    }

    /// The median per-response speed, so one stalled request can't drag the reading the way an average
    /// over total time would. A response stamped after `now` (say, after the clock was set back) hasn't
    /// finished as far as this reading knows.
    static func medianTokensPerSecond(_ timings: [ResponseTiming], now: Date) -> Double? {
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
        return speeds.count.isMultiple(of: 2) ? (speeds[middle - 1] + speeds[middle]) / 2 : speeds[middle]
    }
}

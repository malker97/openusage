import Foundation

/// One finished model response, timed end to end for the Output Speed row: from the request being sent
/// to its last token. `outputTokens` includes reasoning, which is generated (and billed) like visible text.
struct ResponseTiming: Hashable, Sendable {
    var end: Date
    var duration: TimeInterval
    var outputTokens: Int
}

/// Builds the Output Speed row from the timed responses a provider's local logs record: the median
/// tokens per second of the responses that finished in the last five minutes. The timing includes the
/// wait for the first token, so it reads below a provider's published generation speed.
enum OutputSpeedMapper {
    static let label = "Output Speed"
    /// One refresh interval, so each refresh reports the responses that finished since the last one.
    static let window = RefreshSetting.interval
    /// Short replies mostly measure the wait for the first token, not generation.
    static let minimumOutputTokens = 50

    static func windowStart(now: Date) -> Date {
        now.addingTimeInterval(-window)
    }

    /// Appends nothing when no response qualifies, so the row reads "No data" rather than a made-up zero.
    static func appendOutputSpeed(_ timings: [ResponseTiming], to lines: inout [MetricLine], now: Date) {
        guard let speed = medianTokensPerSecond(timings, now: now) else { return }
        lines.append(.values(
            label: label,
            values: [MetricValue(number: speed.rounded(), kind: .count, label: "tok/s")]
        ))
    }

    /// The median per-response speed, so one stalled request can't drag the reading the way an average
    /// over total time would.
    static func medianTokensPerSecond(_ timings: [ResponseTiming], now: Date) -> Double? {
        let start = windowStart(now: now)
        let speeds = timings
            .filter { $0.end >= start && $0.duration > 0 && $0.outputTokens >= minimumOutputTokens }
            .map { Double($0.outputTokens) / $0.duration }
            .sorted()
        guard !speeds.isEmpty else { return nil }
        let middle = speeds.count / 2
        return speeds.count.isMultiple(of: 2) ? (speeds[middle - 1] + speeds[middle]) / 2 : speeds[middle]
    }
}

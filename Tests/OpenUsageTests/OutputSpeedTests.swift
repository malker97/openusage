import XCTest
@testable import OpenUsage

/// The Output Speed row: the median of the last five minutes' timed responses, and how the pi and Codex
/// log parsers time each response. Claude's transcript-chain timing lives in `ClaudeResponseTimingTests`.
final class OutputSpeedTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func timing(secondsAgo: TimeInterval = 10, duration: TimeInterval, output: Int) -> ResponseTiming {
        ResponseTiming(end: now.addingTimeInterval(-secondsAgo), duration: duration, outputTokens: output)
    }

    private func date(_ iso: String) -> Date {
        OpenUsageISO8601.date(from: iso)!
    }

    // MARK: - Mapper

    func testMedianOfResponsesThatFinishedInTheWindow() {
        // 100, 50, and 80 tok/s: the median is the middle response, not an average over total time.
        let timings = [
            timing(duration: 10, output: 1000), timing(duration: 20, output: 1000), timing(duration: 10, output: 800)
        ]
        XCTAssertEqual(OutputSpeedMapper.medianTokensPerSecond(timings, now: now), 80)
        // A stalled 3 tok/s request makes the count even: the two middle speeds average.
        XCTAssertEqual(
            OutputSpeedMapper.medianTokensPerSecond(timings + [timing(duration: 100, output: 300)], now: now), 65
        )
    }

    func testIgnoresOlderShortAndUntimedResponses() {
        let timings = [
            timing(secondsAgo: 301, duration: 1, output: 1000),
            timing(duration: 1, output: OutputSpeedMapper.minimumOutputTokens - 1),
            timing(duration: 0, output: 500),
            timing(secondsAgo: 300, duration: 10, output: 420)
        ]
        XCTAssertEqual(OutputSpeedMapper.window, 300)
        XCTAssertEqual(OutputSpeedMapper.medianTokensPerSecond(timings, now: now), 42)
        XCTAssertNil(OutputSpeedMapper.medianTokensPerSecond(Array(timings.prefix(3)), now: now))
    }

    func testRowCarriesTheRoundedSpeedInTokensPerSecond() {
        var lines: [MetricLine] = []
        OutputSpeedMapper.appendOutputSpeed([timing(duration: 7, output: 666)], to: &lines, now: now)

        let speed = MetricValue(number: 95, kind: .count, label: "tok/s")
        XCTAssertEqual(lines, [.values(label: "Output Speed", values: [speed])])
        XCTAssertEqual(MetricFormatter.string(for: speed, style: .row), "95 tok/s")
    }

    func testNoQualifyingResponseLeavesTheRowWithoutData() {
        var lines: [MetricLine] = []
        OutputSpeedMapper.appendOutputSpeed([timing(secondsAgo: 900, duration: 10, output: 1000)], to: &lines, now: now)
        XCTAssertTrue(lines.isEmpty)
    }

    func testMergedScanKeepsEverySourcesTimings() {
        var native = DailyUsageAccumulator().build()
        native.responseTimings = [timing(duration: 10, output: 1000)]
        var pi = DailyUsageAccumulator().build()
        pi.responseTimings = [timing(duration: 20, output: 1000)]

        let merged = DailyUsageAccumulator.merged([native, nil, pi])
        XCTAssertEqual(merged?.responseTimings, native.responseTimings + pi.responseTimings)
    }

    // MARK: - pi

    private func piLine(
        provider: String = "openai-codex", timestamp: String = "2026-10-15T07:00:30.000Z", message extra: String
    ) -> Data {
        Data(#"""
        {"type":"message","id":"m-\#(timestamp)","timestamp":"\#(timestamp)","message":{"role":"assistant","provider":"\#(provider)","model":"gpt-6.1-sol",\#(extra)"usage":{"input":10,"output":600,"totalTokens":610}}}
        """#.utf8)
    }

    func testPiResponseUsesItsRecordedDuration() {
        let entry = PiUsageScanner.parseLine(piLine(message: #""durationMs":6000,"timestamp":1,"stopReason":"toolUse","#))
        XCTAssertEqual(entry?.responseDuration, 6)
    }

    func testOlderPiResponseIsTimedFromItsRequestStamp() {
        // pi stamps the message when the request goes out; the entry is written as the response finishes.
        let sentMilliseconds = Int(date("2026-10-15T07:00:00.000Z").timeIntervalSince1970 * 1000)
        let entry = PiUsageScanner.parseLine(piLine(message: #""timestamp":\#(sentMilliseconds),"stopReason":"stop","#))
        XCTAssertEqual(entry?.responseDuration ?? 0, 30, accuracy: 0.001)
    }

    func testFailedAndAbortedPiResponsesAreNotTimed() {
        for reason in ["error", "aborted"] {
            let entry = PiUsageScanner.parseLine(piLine(message: #""durationMs":6000,"stopReason":"\#(reason)","#))
            XCTAssertNotNil(entry, reason)
            XCTAssertNil(entry?.responseDuration, reason)
        }
    }

    func testPiTimingsStayOnTheirCardAndInTheWindow() throws {
        let timed = #""durationMs":6000,"#
        let entries = try [
            piLine(message: timed),
            piLine(provider: "anthropic", message: timed),
            piLine(timestamp: "2026-10-15T06:50:00.000Z", message: timed)
        ].map { try XCTUnwrap(PiUsageScanner.parseLine($0)) }

        let timings = PiUsageScanner.responseTimings(
            entries: entries, cardID: "codex",
            since: OutputSpeedMapper.windowStart(now: date("2026-10-15T07:02:00.000Z"))
        )
        XCTAssertEqual(timings, [ResponseTiming(end: date("2026-10-15T07:00:30.000Z"), duration: 6, outputTokens: 600)])
    }

    // MARK: - Codex

    private func codexLine(_ timestamp: String, _ type: String, _ payload: [String: Any]) -> String {
        let object: [String: Any] = ["timestamp": timestamp, "type": type, "payload": payload]
        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private func taskStarted(_ timestamp: String) -> String {
        codexLine(timestamp, "event_msg", ["type": "task_started", "turn_id": "turn-1", "started_at": 1])
    }

    private func toolCall(_ timestamp: String) -> String {
        codexLine(timestamp, "response_item", ["type": "custom_tool_call", "call_id": "call-1", "name": "exec"])
    }

    private func toolOutput(_ timestamp: String) -> String {
        codexLine(timestamp, "response_item", [
            "type": "custom_tool_call_output", "call_id": "call-1",
            "output": #"{"timestamp":"not this one","type":"response_item"}"#
        ])
    }

    private func usageRecord(_ timestamp: String, output: Int) -> String {
        codexLine(timestamp, "token_usage_record", [
            "response_id": "resp-\(timestamp)",
            "usage": CodexLogFixture.usage(input: 1000, output: output)
        ])
    }

    private func tokenCount(_ timestamp: String, output: Int) -> String {
        CodexLogFixture.tokenCount(timestamp: timestamp, last: CodexLogFixture.usage(input: 1000, output: output))
    }

    private func parseCodex(_ lines: [String]) -> [CodexLogUsageScanner.Event] {
        CodexLogUsageScanner.parseFile(Data(lines.joined(separator: "\n").utf8))
    }

    func testCodexResponseRunsFromItsRequestToItsUsageRecord() {
        let events = parseCodex([
            taskStarted("2026-10-15T07:00:00.000Z"),
            toolCall("2026-10-15T07:00:05.000Z"),
            usageRecord("2026-10-15T07:00:05.100Z", output: 300),
            // The tool runs for minutes; its usage is only reported once it returns.
            toolOutput("2026-10-15T07:03:17.000Z"),
            tokenCount("2026-10-15T07:03:17.010Z", output: 300),
            usageRecord("2026-10-15T07:03:21.000Z", output: 120),
            tokenCount("2026-10-15T07:03:21.010Z", output: 120)
        ])

        XCTAssertEqual(events.map(\.output), [300, 120])
        XCTAssertEqual(events.map(\.responseStart), [date("2026-10-15T07:00:00.000Z"), date("2026-10-15T07:03:17.000Z")])
        XCTAssertEqual(events.map(\.responseEnd), [date("2026-10-15T07:00:05.100Z"), date("2026-10-15T07:03:21.000Z")])

        let timings = CodexLogUsageScanner.responseTimings(events: events + events, since: .distantPast)
        XCTAssertEqual(timings.map(\.outputTokens), [300, 120], "copied rollouts repeat timings that count once")
        XCTAssertEqual(timings.first?.duration ?? 0, 5.1, accuracy: 0.001)
    }

    func testCodexUsageWithoutAMatchingRecordIsNotTimed() {
        let events = parseCodex([
            taskStarted("2026-10-15T07:00:00.000Z"),
            usageRecord("2026-10-15T07:00:05.000Z", output: 300),
            tokenCount("2026-10-15T07:00:05.010Z", output: 299),
            // Older Codex writes no usage records at all.
            tokenCount("2026-10-15T07:00:09.000Z", output: 50)
        ])

        XCTAssertEqual(events.count, 2)
        XCTAssertTrue(events.allSatisfy { $0.responseStart == nil && $0.responseEnd == nil })
    }

    func testCodexChildSessionTimesOnlyItsOwnTurns() {
        // A subagent rollout replays its parent's history before its own first turn.
        let events = parseCodex([
            CodexLogFixture.subagentSessionMeta(timestamp: "2026-10-15T07:00:00.000Z"),
            taskStarted("2026-10-15T07:00:00.100Z"),
            usageRecord("2026-10-15T07:00:00.200Z", output: 500),
            tokenCount("2026-10-15T07:00:00.300Z", output: 500),
            CodexLogFixture.taskStarted(timestamp: "2026-10-15T07:00:01.000Z", startedAt: 1_792_047_601),
            usageRecord("2026-10-15T07:00:09.000Z", output: 400),
            tokenCount("2026-10-15T07:00:09.010Z", output: 400)
        ])

        XCTAssertEqual(events.map(\.output), [400])
        XCTAssertEqual(events.first?.responseStart, date("2026-10-15T07:00:01.000Z"))
        XCTAssertEqual(events.first?.responseEnd, date("2026-10-15T07:00:09.000Z"))
    }
}

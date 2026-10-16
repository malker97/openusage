import XCTest
@testable import OpenUsage

/// Claude Code logs carry no request durations, so the Output Speed row times each response from its
/// transcript chain: from the line that sent the request to the response's last content block.
final class ClaudeResponseTimingTests: XCTestCase {
    private typealias Entry = ClaudeLogUsageScanner.Entry

    /// Recent enough to sit inside the scan window whenever the suite runs; whole seconds, so ISO-8601
    /// millisecond round-trips compare exactly.
    private let base = Date(timeIntervalSince1970: Date().addingTimeInterval(-600).timeIntervalSince1970.rounded(.down))

    private func at(_ offset: TimeInterval) -> Date {
        base.addingTimeInterval(offset)
    }

    private func line(_ fields: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: fields), as: UTF8.self)
    }

    private func user(_ uuid: String, parent: String?, at offset: TimeInterval, content: Any = "Fix the bug") -> String {
        line([
            "type": "user", "uuid": uuid, "parentUuid": (parent as Any?) ?? NSNull(), "sessionId": "s-1",
            "timestamp": OpenUsageISO8601.string(from: at(offset)),
            "message": ["role": "user", "content": content] as [String: Any]
        ])
    }

    private func attachment(_ uuid: String, parent: String, at offset: TimeInterval) -> String {
        line([
            "type": "attachment", "uuid": uuid, "parentUuid": parent, "sessionId": "s-1",
            "timestamp": OpenUsageISO8601.string(from: at(offset)), "attachment": ["type": "todo_reminder"]
        ])
    }

    private func apiError(_ uuid: String, parent: String, at offset: TimeInterval, retryInMs: Int) -> String {
        line([
            "type": "system", "subtype": "api_error", "uuid": uuid, "parentUuid": parent, "sessionId": "s-1",
            "timestamp": OpenUsageISO8601.string(from: at(offset)), "retryInMs": retryInMs, "retryAttempt": 1
        ])
    }

    /// One content block of a response; every block of a response repeats its final usage.
    private func block(
        _ uuid: String, parent: String, at offset: TimeInterval, request: String?, message: String, output: Int
    ) -> String {
        var fields: [String: Any] = [
            "type": "assistant", "uuid": uuid, "parentUuid": parent, "sessionId": "s-1", "version": "2.1.270",
            "timestamp": OpenUsageISO8601.string(from: at(offset)),
            "message": [
                "id": message, "model": "claude-opus-5-5", "role": "assistant",
                "content": [
                    ["type": "tool_use", "input": ["uuid": "nested", "timestamp": "1999-01-01T00:00:00Z"]] as [String: Any]
                ],
                "usage": ["input_tokens": 10, "output_tokens": output]
            ] as [String: Any]
        ]
        if let request { fields["requestId"] = request }
        return line(fields)
    }

    private func parse(_ lines: [String]) -> [Entry] {
        ClaudeLogUsageScanner.parseFile(Data(lines.joined(separator: "\n").utf8))
    }

    // MARK: - Request starts

    func testEveryBlockOfAResponseStartsWhereItsRequestWasSent() {
        let entries = parse([
            user("u1", parent: nil, at: 0),
            block("a1", parent: "u1", at: 4, request: "r1", message: "m1", output: 400),
            block("a2", parent: "a1", at: 5, request: "r1", message: "m1", output: 400),
            // Tool results are arbitrary JSON; their nested ids and times must not be read as the line's own.
            user("u2", parent: "a2", at: 6, content: [[
                "type": "tool_result", "content": "ok",
                "meta": ["uuid": "nested", "parentUuid": "elsewhere", "timestamp": "1999-01-01T00:00:00Z"]
            ] as [String: Any]]),
            attachment("x1", parent: "u2", at: 6.5),
            block("a3", parent: "x1", at: 10.5, request: "r2", message: "m2", output: 300)
        ])

        XCTAssertEqual(entries.map(\.requestStart), [at(0), at(0), at(6.5)])
    }

    func testARetryIsTimedFromWhenItWasSent() throws {
        // The first attempt failed three minutes in; the retry went out after the announced backoff.
        let entries = parse([
            attachment("x1", parent: "root", at: 0),
            apiError("e1", parent: "x1", at: 180, retryInMs: 559),
            block("a1", parent: "e1", at: 200, request: "r1", message: "m1", output: 900)
        ])

        let start = try XCTUnwrap(entries.first?.requestStart)
        XCTAssertEqual(start.timeIntervalSince(at(180)), 0.559, accuracy: 0.000_1)
    }

    func testAResponseSentRightAfterAnotherStartsWhenThatOneFinished() {
        let entries = parse([
            user("u1", parent: nil, at: 0),
            block("a1", parent: "u1", at: 3, request: "r1", message: "m1", output: 100),
            block("b1", parent: "a1", at: 9, request: "r2", message: "m2", output: 500)
        ])

        XCTAssertEqual(entries.map(\.requestStart), [at(0), at(3)])
    }

    func testUntraceableResponsesAreNotTimed() {
        let entries = parse([
            block("a1", parent: "not-in-this-file", at: 3, request: "r1", message: "m1", output: 100),
            user("u1", parent: nil, at: 4),
            block("b1", parent: "u1", at: 9, request: nil, message: "m2", output: 500)
        ])

        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries.allSatisfy { $0.requestStart == nil })
    }

    // MARK: - Timings

    func testScanTimesEachResponseFromItsRequestToItsLastBlock() async throws {
        // The tool result outgrows one read batch, so the chain has to carry across batches.
        let largeResult = [["type": "tool_result", "content": String(repeating: "x", count: 100_000)]]
        let home = try ClaudeLogFixture.makeHome(files: ["project/session.jsonl": [
            user("u1", parent: nil, at: 0),
            block("a1", parent: "u1", at: 4, request: "r1", message: "m1", output: 400),
            block("a2", parent: "a1", at: 5, request: "r1", message: "m1", output: 400),
            user("u2", parent: "a2", at: 6, content: largeResult),
            block("a3", parent: "u2", at: 10, request: "r2", message: "m2", output: 300)
        ].joined(separator: "\n")])
        defer { try? FileManager.default.removeItem(at: home) }

        let scan = await ClaudeLogFixture.scanner(home: home).scan(now: at(60), pricing: TestPricing.bundled)

        XCTAssertEqual(scan?.responseTimings, [
            ResponseTiming(end: at(5), duration: 5, outputTokens: 400),
            ResponseTiming(end: at(10), duration: 4, outputTokens: 300)
        ])
        // An hour on, the scan still hands them over, so the row can keep the last session's speed.
        let later = await ClaudeLogFixture.scanner(home: home).scan(now: at(3_600), pricing: TestPricing.bundled)
        XCTAssertEqual(later?.responseTimings, scan?.responseTimings)
    }

    func testAReplayedMessageIsTimedOnce() {
        let original = Entry(
            timestamp: at(5), tokens: TokenBreakdown(input: 10, output: 400), messageID: "m1", requestID: "r1",
            isSidechain: false, hasSpeed: false, costUSD: nil, model: "claude-opus-5-5", requestStart: at(0)
        )
        var replay = original
        replay.requestID = "r9"
        replay.isSidechain = true
        replay.timestamp = at(30)
        replay.requestStart = at(29)
        let entries = [replay, original]

        let timings = ClaudeLogUsageScanner.responseTimings(
            entries: entries, deduped: ClaudeLogUsageScanner.dedup(entries), since: .distantPast
        )

        XCTAssertEqual(timings, [ResponseTiming(end: at(5), duration: 5, outputTokens: 400)])
    }
}

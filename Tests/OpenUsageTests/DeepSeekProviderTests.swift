import XCTest
@testable import OpenUsage

/// The DeepSeek card: one Output Speed row, read from pi's logs, with the pi key as its enablement probe.
@MainActor
final class DeepSeekProviderTests: XCTestCase {
    private let now = OpenUsageISO8601.date(from: "2026-10-17T18:30:00.000Z")!

    private func date(_ iso: String) -> Date {
        OpenUsageISO8601.date(from: iso)!
    }

    private func assistantLine(
        id: String = "d1", at iso: String = "2026-10-17T18:20:00.000Z", provider: String = "deepseek",
        model: String = "deepseek-flash", durationMs: Int = 2_000, output: Int = 200,
        stopReason: String = "stop"
    ) -> String {
        """
        {"type":"message","id":"\(id)","timestamp":"\(iso)","message":{"role":"assistant",\
        "provider":"\(provider)","model":"\(model)","durationMs":\(durationMs),\
        "stopReason":"\(stopReason)","usage":{"input":100,"output":\(output),"cacheRead":0,\
        "cacheWrite":0,"totalTokens":\(100 + output),"cost":{"total":0.0001}}}}
        """
    }

    private func makePiHome(_ lines: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-deepseek-\(UUID().uuidString)", isDirectory: true)
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try Data(lines.joined(separator: "\n").utf8)
            .write(to: sessions.appendingPathComponent("session.jsonl"))
        return root
    }

    private func provider(
        piHome: URL?, authStore: DeepSeekAuthStore = DeepSeekAuthStore(files: FakeFiles(), environment: FakeEnvironment())
    ) -> DeepSeekProvider {
        let fixedNow = now
        let environment = FakeEnvironment(piHome.map { ["PI_CODING_AGENT_SESSION_DIR": $0.path] } ?? [:])
        let scanner = PiUsageScanner(
            environment: environment,
            homeDirectory: { FileManager.default.temporaryDirectory.appendingPathComponent("openusage-no-pi-home") },
            incrementalScanner: IncrementalJSONLScanner<PiUsageScanner.Entry>()
        )
        return DeepSeekProvider(piScanner: scanner, authStore: authStore, now: { fixedNow })
    }

    // MARK: - Card shape

    func testCardIsOnlyTheOutputSpeedRow() {
        let card = provider(piHome: nil)

        XCTAssertEqual(card.provider.id, "deepseek")
        XCTAssertEqual(card.provider.displayName, "DeepSeek")
        XCTAssertEqual(card.widgetDescriptors.map(\.id), ["deepseek.outputSpeed"])
        XCTAssertEqual(card.widgetDescriptors.first?.metricLabel, "Output Speed")
        XCTAssertEqual(card.widgetDescriptors.first?.sample.title, "Output Speed")
        XCTAssertEqual(card.widgetDescriptors.first?.sample.selection, .kind(.count))
    }

    func testDeepSeekPiUsageBelongsToTheDeepSeekCard() {
        let entry = PiUsageScanner.parseLine(Data(assistantLine().utf8))

        XCTAssertEqual(entry?.cardID, "deepseek")
        XCTAssertEqual(PiProviderMapping.cardID(forPiProvider: "deepseek"), "deepseek")
    }

    // MARK: - Refresh

    func testRefreshShowsTheMedianSpeedOfDeepSeekReplies() async throws {
        let home = try makePiHome([
            // 100 tok/s and 300 tok/s: the median of the two is 200. Other providers' replies stay off this card.
            // Both finished a minute before `now`, so the reading is current and carries no age.
            assistantLine(id: "d1", at: "2026-10-17T18:29:00.000Z", durationMs: 2_000, output: 200),
            assistantLine(id: "d2", at: "2026-10-17T18:29:30.000Z", durationMs: 1_000, output: 300),
            assistantLine(id: "c1", provider: "claude-agent-sdk", model: "claude-opus-5-5", durationMs: 1_000, output: 900)
        ])
        defer { try? FileManager.default.removeItem(at: home) }

        let snapshot = await provider(piHome: home).refresh()

        XCTAssertEqual(snapshot.providerID, "deepseek")
        XCTAssertEqual(snapshot.lines, [
            .values(label: "Output Speed", values: [MetricValue(number: 200, kind: .count, label: "tok/s")])
        ])
        XCTAssertNil(snapshot.plan)
    }

    func testFailedDeepSeekRepliesAreNotTimed() async throws {
        let home = try makePiHome([
            // A failed reply with plenty of output must not count. The good reply finished ten minutes before
            // `now`, so it is the last session's reading and carries when it was taken.
            assistantLine(id: "d1", durationMs: 2_000, output: 500, stopReason: "error"),
            assistantLine(id: "d2", durationMs: 2_000, output: 200)
        ])
        defer { try? FileManager.default.removeItem(at: home) }

        let snapshot = await provider(piHome: home).refresh()

        XCTAssertEqual(snapshot.lines, [
            .values(label: "Output Speed", values: [
                MetricValue(
                    number: 100, kind: .count, label: "tok/s",
                    asOf: date("2026-10-17T18:20:00.000Z")
                )
            ])
        ])
    }

    func testNoDeepSeekRepliesReadsNoData() async throws {
        let onlyOtherProviders = try makePiHome([
            assistantLine(id: "c1", provider: "openai-codex", model: "gpt-6.1-sol", durationMs: 2_000, output: 200)
        ])
        defer { try? FileManager.default.removeItem(at: onlyOtherProviders) }
        let noPiLogs = try makePiHome([])
        defer { try? FileManager.default.removeItem(at: noPiLogs) }

        for home in [onlyOtherProviders, noPiLogs, nil] {
            let snapshot = await provider(piHome: home).refresh()
            XCTAssertEqual(snapshot.lines, [.noUsageData], "home: \(String(describing: home))")
        }
    }

    // MARK: - Enablement

    func testLocalCredentialsComeFromAPiDeepSeekKey() async {
        func store(_ auth: String) -> DeepSeekAuthStore {
            DeepSeekAuthStore(
                files: FakeFiles(["/Users/dev/.pi/agent/auth.json": auth]),
                environment: FakeEnvironment([:]),
                homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
            )
        }
        let keyedAuth = #"{"deepseek":{"type":"api_key","key":"sk-test"},"openai-codex":{"type":"oauth"}}"#

        // `await` can't live inside an XCTAssert autoclosure, so each probe lands in a local first.
        let keyed = await provider(piHome: nil, authStore: store(keyedAuth)).hasLocalCredentials()
        let otherProvider = await provider(
            piHome: nil, authStore: store(#"{"openai-codex":{"type":"oauth"}}"#)
        ).hasLocalCredentials()
        let blankKey = await provider(
            piHome: nil, authStore: store(#"{"deepseek":{"type":"api_key","key":"  "}}"#)
        ).hasLocalCredentials()
        let oauthEntry = await provider(
            piHome: nil, authStore: store(#"{"deepseek":{"type":"oauth","access":"x"}}"#)
        ).hasLocalCredentials()
        let noAuthFile = await provider(piHome: nil).hasLocalCredentials()

        XCTAssertTrue(keyed)
        XCTAssertFalse(otherProvider)
        XCTAssertFalse(blankKey)
        XCTAssertFalse(oauthEntry)
        XCTAssertFalse(noAuthFile)
    }
}

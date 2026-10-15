import Foundation

/// Parses one Claude Code session log while following its transcript chain, so each response can be
/// timed for the Output Speed row. Every line names its parent (`parentUuid`); a response is written as
/// one line per content block, chained one after another under a shared `requestId`. The line above its
/// first block — the prompt, a tool result, an attachment, or the previous response's last block — marks
/// when the request was sent. A failed attempt writes an `api_error` line in between, and the retry goes
/// out `retryInMs` after it. State lives for one file only: chains never cross session files.
struct ClaudeLogFileParser: Sendable {
    private struct Line: Sendable {
        var parent: String?
        /// Kept raw: only the few lines that turn out to send a request are ever parsed.
        var timestamp: String
        /// Set on a response's content blocks; nil on every other line.
        var requestID: String?
        var retryDelayMs: Double?
    }

    private static let usageMarker = Data(#""usage":{"#.utf8)
    private static let chainFields = ["uuid", "parentUuid", "timestamp", "type", "requestId", "retryInMs"]
    /// Far beyond any real response's block count; a chain this long is malformed, so it goes untimed.
    private static let maximumBlocksPerResponse = 1024

    private var lines: [String: Line] = [:]

    /// Usage lines are decoded in full; every other line is only skimmed for its place in the chain.
    mutating func parse(_ data: Data) -> [ClaudeLogUsageScanner.Entry] {
        var entries: [ClaudeLogUsageScanner.Entry] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard line.range(of: Self.usageMarker) != nil,
                  let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
            else {
                let fields = JSONTopLevelScalars.values(in: line, keys: Self.chainFields)
                remember(
                    uuid: fields["uuid"], parent: fields["parentUuid"], timestamp: fields["timestamp"],
                    type: fields["type"], requestID: fields["requestId"],
                    retryDelayMs: fields["retryInMs"].flatMap(Double.init)
                )
                continue
            }
            remember(
                uuid: object["uuid"] as? String, parent: object["parentUuid"] as? String,
                timestamp: object["timestamp"] as? String, type: object["type"] as? String,
                requestID: object["requestId"] as? String,
                retryDelayMs: ProviderParse.number(object["retryInMs"])
            )
            var parsed = ClaudeLogUsageScanner.entries(from: object)
            // Advisor entries ride inside the parent's request and are never timed on their own.
            if !parsed.isEmpty {
                parsed[0].requestStart = requestStart(
                    above: object["parentUuid"] as? String, requestID: parsed[0].requestID
                )
            }
            entries.append(contentsOf: parsed)
        }
        return entries
    }

    private mutating func remember(
        uuid: String?, parent: String?, timestamp: String?, type: String?, requestID: String?,
        retryDelayMs: Double?
    ) {
        guard let uuid, let timestamp else { return }
        lines[uuid] = Line(
            parent: parent,
            timestamp: timestamp,
            requestID: type == "assistant" ? requestID : nil,
            retryDelayMs: retryDelayMs
        )
    }

    /// Walk up past the response's own earlier blocks to the line that sent its request.
    private func requestStart(above parent: String?, requestID: String?) -> Date? {
        guard let requestID else { return nil }
        var cursor = parent
        for _ in 0..<Self.maximumBlocksPerResponse {
            guard let id = cursor, let line = lines[id] else { return nil }
            guard line.requestID == requestID else {
                guard let sent = OpenUsageISO8601.date(from: line.timestamp) else { return nil }
                return sent.addingTimeInterval((line.retryDelayMs ?? 0) / 1000)
            }
            cursor = line.parent
        }
        return nil
    }
}

extension ClaudeLogUsageScanner {
    // MARK: - Line parsing

    /// Parse every usage line of one session file. Entries keep their raw timestamps — the date
    /// window is applied at aggregation so a cached parse stays valid as the window slides.
    static func parseFile(_ data: Data) -> [Entry] {
        var parser = ClaudeLogFileParser()
        return parser.parse(data)
    }

    /// Decode one JSONL line into an `Entry`, mirroring what ccusage's serde model accepts: `usage`
    /// with numeric `input_tokens`/`output_tokens` is required, everything else optional, and a
    /// malformed or invalid line is skipped rather than failing the file.
    static func parseLine(_ data: Data) -> Entry? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return entries(from: object).first
    }

    /// A Claude log line can carry nested advisor work in `usage.iterations`. The top-level usage
    /// remains the main-model entry; only advisor-message iterations become additional entries,
    /// matching ccusage without recounting the ordinary message iterations that feed that total.
    fileprivate static func entries(from object: [String: Any]) -> [Entry] {
        guard let timestampRaw = object["timestamp"] as? String,
              let timestamp = OpenUsageISO8601.date(from: timestampRaw),
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              !hasUnsupportedNullField(object, message: message, usage: usage),
              let parsedUsage = tokenBreakdown(from: usage),
              isValidEntry(object, message: message)
        else { return [] }

        let model = (message["model"] as? String).flatMap { $0 == "<synthetic>" ? nil : $0 }
        let parent = Entry(
            timestamp: timestamp,
            tokens: parsedUsage.tokens,
            messageID: message["id"] as? String,
            requestID: object["requestId"] as? String,
            isSidechain: object["isSidechain"] as? Bool ?? false,
            hasSpeed: parsedUsage.hasSpeed,
            costUSD: (object["costUSD"] as? NSNumber)?.doubleValue,
            model: model
        )

        guard let iterations = usage["iterations"] as? [[String: Any]] else { return [parent] }

        var entries = [parent]
        var advisorIndex = 0
        for iteration in iterations {
            guard iteration["type"] as? String == "advisor_message",
                  let advisorModel = iteration["model"] as? String,
                  !advisorModel.isEmpty,
                  let advisorUsage = tokenBreakdown(from: iteration)
            else { continue }

            entries.append(Entry(
                timestamp: parent.timestamp,
                tokens: advisorUsage.tokens,
                messageID: parent.messageID.map { "\($0):advisor:\(advisorIndex)" },
                requestID: parent.requestID,
                isSidechain: parent.isSidechain,
                hasSpeed: advisorUsage.hasSpeed,
                costUSD: nil,
                model: advisorModel
            ))
            advisorIndex += 1
        }
        return entries
    }

    private static func tokenBreakdown(
        from usage: [String: Any]
    ) -> (tokens: TokenBreakdown, hasSpeed: Bool)? {
        guard let input = usage["input_tokens"] as? NSNumber,
              let output = usage["output_tokens"] as? NSNumber
        else { return nil }

        // Claude tags fast-mode requests with `speed`; any value outside the known set marks a log
        // shape we don't understand, so the line is skipped (ccusage's enum parse does the same).
        let speed = usage["speed"] as? String
        if let speed, speed != "fast", speed != "standard" { return nil }

        // Cache writes: the 5m/1h split when present (1h bills at 2x input), else the legacy
        // aggregate `cache_creation_input_tokens` treated as all-5m.
        var cacheWrite5m = 0
        var cacheWrite1h = 0
        if let cacheCreation = usage["cache_creation"] as? [String: Any] {
            cacheWrite5m = (cacheCreation["ephemeral_5m_input_tokens"] as? NSNumber)?.intValue ?? 0
            cacheWrite1h = (cacheCreation["ephemeral_1h_input_tokens"] as? NSNumber)?.intValue ?? 0
        } else {
            cacheWrite5m = (usage["cache_creation_input_tokens"] as? NSNumber)?.intValue ?? 0
        }

        return (TokenBreakdown(
            input: input.intValue,
            cacheWrite5m: cacheWrite5m,
            cacheWrite1h: cacheWrite1h,
            cacheRead: (usage["cache_read_input_tokens"] as? NSNumber)?.intValue ?? 0,
            output: output.intValue,
            isFast: speed == "fast"
        ), speed != nil)
    }

    /// ccusage's validity rules: a `version` that isn't semver-ish marks a foreign log format, and
    /// ids/model that are present but empty mark a malformed line.
    private static func isValidEntry(_ object: [String: Any], message: [String: Any]) -> Bool {
        if let version = object["version"] as? String, !isSemverPrefix(version) { return false }
        for value in [object["sessionId"], object["requestId"], message["id"], message["model"]] {
            if let text = value as? String, text.isEmpty { return false }
        }
        return true
    }

    /// `digits.digits.digit…` — accepts "1.0.24" and pre-release suffixes, rejects e.g. "unknown".
    static func isSemverPrefix(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        var index = 0
        func digits() -> Bool {
            let start = index
            while index < bytes.count, bytes[index].isASCIIDigit { index += 1 }
            return index > start
        }
        guard digits(), index < bytes.count, bytes[index] == UInt8(ascii: ".") else { return false }
        index += 1
        guard digits(), index < bytes.count, bytes[index] == UInt8(ascii: ".") else { return false }
        index += 1
        return index < bytes.count && bytes[index].isASCIIDigit
    }

    /// Claude never writes `null` into the schema fields we consume; a line that does is a
    /// foreign/corrupt shape that ccusage skips. The check is scoped to the exact objects we read
    /// (top level, `message`, `message.usage`) so unrelated nested keys sharing a name — such as
    /// `usage.iterations[].model`, which Claude Code 2.1.270 writes as `null` for ordinary message
    /// iterations — don't invalidate an otherwise valid record.
    static func hasUnsupportedNullField(
        _ object: [String: Any], message: [String: Any], usage: [String: Any]
    ) -> Bool {
        let levels: [([String: Any], [String])] = [
            (object, ["cwd", "costUSD", "version", "sessionId", "requestId", "isApiErrorMessage"]),
            (message, ["id", "model"]),
            (usage, ["speed", "cache_read_input_tokens", "cache_creation_input_tokens"])
        ]
        for (container, fields) in levels {
            for field in fields where container[field] is NSNull { return true }
        }
        return false
    }
}

private extension UInt8 {
    var isASCIIDigit: Bool { self >= UInt8(ascii: "0") && self <= UInt8(ascii: "9") }
}

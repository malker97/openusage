import Foundation

/// Builds daily token/cost estimates for Claude by scanning Claude Code's local session logs
/// natively (`<config dir>/projects/**/*.jsonl`), replacing the external `ccusage` CLI.
///
/// Ports ccusage's Claude adapter semantics:
/// - Roots come from `CLAUDE_CONFIG_DIR` (comma-separated; each entry is a config dir containing
///   `projects/`, or the `projects/` dir itself), else `$XDG_CONFIG_HOME/claude` and `~/.claude`.
/// - A usage line must carry `"usage":{`, parse as JSON with a valid timestamp, not carry `null` in
///   fields Claude never writes as null, and pass the validity checks (semver-ish `version`,
///   non-empty ids/model).
/// - Entries are deduplicated by `(message.id, requestId)`, with a second pass that catches
///   sidechain logs replaying a parent message under a new request id. On collision the non-sidechain
///   entry wins, then the larger token total, then the one carrying a `speed` field.
/// - Advisor-message iterations become separate entries under their own model. Other iteration
///   types stay represented only by the parent usage totals, avoiding double-counting.
/// - Cost mode "auto": a line's `costUSD` when present, else tokens priced through `ModelPricing`.
///
/// An actor so the whole scan runs off the main actor. Parsed files are cached by path + size + mtime
/// in memory and Application Support: refreshes and relaunches parse only changed files, then re-run
/// the cheap dedup + day aggregation over cached entries before local model-rate estimates.
actor ClaudeLogUsageScanner {
    private let environment: EnvironmentReading
    private let homeDirectory: @Sendable () -> URL
    private let scanner: IncrementalJSONLScanner<Entry>
    /// Scoped provider instances pass their stable parse-source identity here. Account or time filters
    /// over the same physical roots deliberately pass the same value and share whole-file records.
    private let cacheIdentityOverride: String?
    private let organizationID: String?
    private let accountID: String?
    private let additionalConfigDirectories: [String]
    private let allowsUnattributedSessions: Bool
    /// The identity Claude Code is signed in to right now, re-read every scan. The card matching it
    /// also owns the default home's sessions that record no account, which is how plain terminal
    /// sessions look; Desktop-indexed sessions stay excluded.
    private let currentDefaultLoginIdentity: @Sendable () -> String?
    private var sessionOwnership: [String: (
        size: Int, mtime: Date, identity: ClaudeSessionIdentity
    )] = [:]

    private let readOwnershipData: @Sendable (URL) throws -> Data

    /// One parsed usage line. Token buckets are pre-normalized into `TokenBreakdown`; dedup fields
    /// ride along so the global dedup pass can run over cached entries.
    struct Entry: Codable, Sendable, Equatable {
        var timestamp: Date
        var tokens: TokenBreakdown
        var messageID: String?
        var requestID: String?
        var isSidechain: Bool = false
        /// The line carried a `speed` field at all (dedup tiebreaker); `tokens.isFast` says it was "fast".
        var hasSpeed: Bool = false
        var costUSD: Double?
        /// `nil` when the line has no model or the placeholder `<synthetic>` (tokens count, cost is $0).
        var model: String?
        /// When this response's request was sent, from the transcript chain (see `ClaudeLogFileParser`);
        /// nil when the chain can't tell.
        var requestStart: Date? = nil
    }

    /// Cards that read the same Claude home share one actor, so the first scan populates both the
    /// in-memory and disk caches and the rest reuse it. Tests inject an isolated memory-only scanner.
    private static let sharedScanner = IncrementalJSONLScanner<Entry>(
        logTag: LogTag.plugin("claude"),
        // v2: accept records whose nested `usage.iterations[].model` is null (#1253); cached
        // parses from v1 silently dropped them, so every file must re-parse once.
        // v3: response timing for the Output Speed row, which reads back across the whole window.
        persistence: JSONLScanCachePersistence(namespace: "claude", schemaVersion: 3)
    )

    static func flushPersistentCacheWrites() async {
        await sharedScanner.flushPendingWrites()
    }

    init(
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        incrementalScanner: IncrementalJSONLScanner<Entry>? = nil,
        cacheIdentityOverride: String? = nil,
        accountUUID: String? = nil,
        organizationUUID: String? = nil,
        allowsUnattributedSessions: Bool = false,
        currentDefaultLoginIdentity: (@Sendable () -> String?)? = nil,
        additionalConfigDirectories: [String] = [],
        readOwnershipData: @escaping @Sendable (URL) throws -> Data = {
            try Data(contentsOf: $0, options: .mappedIfSafe)
        }
    ) {
        precondition(cacheIdentityOverride?.isEmpty != true)
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.scanner = incrementalScanner ?? Self.sharedScanner
        self.cacheIdentityOverride = cacheIdentityOverride
        self.organizationID = organizationUUID?.lowercased()
        self.accountID = accountUUID?.lowercased()
        self.additionalConfigDirectories = additionalConfigDirectories
        self.allowsUnattributedSessions = allowsUnattributedSessions
        self.currentDefaultLoginIdentity = currentDefaultLoginIdentity ?? {
            let observer = DefaultAccountObserver(environment: environment, homeDirectory: homeDirectory)
            guard case let .resolved(identityKey, _, _) = observer.observeClaude() else { return nil }
            return identityKey
        }
        self.readOwnershipData = readOwnershipData
    }

    /// Scan the last `daysBack` days of Claude logs. Returns `nil` when no Claude data directory or
    /// no log files exist (the spend tiles then render "No data"); returns an empty series when logs
    /// exist but have no usage in the window.
    func scan(daysBack: Int = 30, now: Date = Date(), pricing: ModelPricing) async -> LogUsageScan? {
        // A UUID-only login cannot claim any organization's history once multiple identities are
        // known; while it is the default login it still claims the default home's unattributed sessions.
        let claimsDefaultHome = !allowsUnattributedSessions && isCurrentDefaultLogin()
        if accountID != nil, organizationID == nil, !allowsUnattributedSessions, !claimsDefaultHome {
            AppLog.info(LogTag.plugin("claude"), "local spending excluded: login has no organization and multiple accounts are known")
            return nil
        }
        let since = JSONLScanning.sinceDate(daysBack: daysBack, now: now)
        let cacheIdentity = parseCacheIdentity()
        let roots = claudeRoots()
        guard !roots.isEmpty else {
            _ = await scanner.items(
                from: [], since: since, cacheIdentity: cacheIdentity, parse: Self.parseFile
            )
            return nil
        }

        var files = Self.usageFiles(under: roots)
        if organizationID != nil || claimsDefaultHome {
            files = ownedUsageFiles(files, claimsDefaultHome: claimsDefaultHome)
        }
        guard !Task.isCancelled else { return nil }
        guard !files.isEmpty else {
            _ = await scanner.items(
                from: [], since: since, cacheIdentity: cacheIdentity, parse: Self.parseFile
            )
            return nil
        }

        // Entries come back concatenated in path-sorted file order, so dedup's keep-first is deterministic.
        guard let entries = await scanner.items(
            from: files,
            since: since,
            cacheIdentity: cacheIdentity,
            initialState: ClaudeLogFileParser(),
            parse: { data, parser in parser.parse(data) }
        ), !Task.isCancelled else { return nil }
        let deduped = Self.dedup(entries)
        var scan = Self.aggregate(entries: deduped, since: since, pricing: pricing)
        scan.responseTimings = Self.responseTimings(entries: entries, deduped: deduped, since: since)
        return scan
    }

    /// Stable source configuration identity rather than the discovered root list: Cowork adds session
    /// roots over time, and a new session must extend the same cache instead of cold-parsing every old
    /// file. Scoped root overrides pass an explicit identity so distinct homes stay partitioned.
    private func parseCacheIdentity() -> String {
        if let cacheIdentityOverride { return cacheIdentityOverride }
        let home = homeDirectory().resolvingSymlinksInPath().path
        let allRoots = defaultConfigRoots() + additionalConfigDirectories.map { URL(fileURLWithPath: expandHome($0)) }
        let roots = Set(allRoots.map { $0.resolvingSymlinksInPath().standardizedFileURL.path })
            .sorted()
            .joined(separator: "\n")
        return "home=\(home)\nroots=\(roots)"
    }

    /// The default Claude home(s) the terminal CLI writes to: `CLAUDE_CONFIG_DIR` entries, else
    /// `$XDG_CONFIG_HOME/claude` and `~/.claude`. Swap and Cowork roots are not included.
    private func defaultConfigRoots() -> [URL] {
        if let raw = environment.value(for: "CLAUDE_CONFIG_DIR")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty
        {
            return raw.split(separator: ",").compactMap { part in
                let value = part.trimmingCharacters(in: .whitespaces)
                guard !value.isEmpty else { return nil }
                var url = URL(fileURLWithPath: expandHome(value))
                if url.lastPathComponent == "projects" { url.deleteLastPathComponent() }
                return url
            }
        } else {
            let homeURL = homeDirectory()
            let xdg = environment.value(for: "XDG_CONFIG_HOME")?.nilIfEmpty
                .map { URL(fileURLWithPath: expandHome($0)) }
                ?? homeURL.appendingPathComponent(".config")
            return [
                xdg.appendingPathComponent("claude"),
                homeURL.appendingPathComponent(".claude"),
            ]
        }
    }

    // MARK: - Root and file discovery

    /// Claude config directories that actually contain a `projects/` folder, in ccusage's order:
    /// every entry of `CLAUDE_CONFIG_DIR` when set (an invalid list logs and yields none), else
    /// `$XDG_CONFIG_HOME/claude` (default `~/.config/claude`) and `~/.claude`. Cowork's per-session
    /// `.claude` sandboxes are always appended — they live under the desktop app's own container,
    /// so `CLAUDE_CONFIG_DIR` (a terminal-CLI override) doesn't speak for them.
    private func claudeRoots() -> [URL] {
        var roots: [URL] = []
        var seen: Set<String> = []

        func addIfValid(_ url: URL) {
            guard FileManager.default.fileExists(atPath: url.appendingPathComponent("projects").path),
                  seen.insert(url.path).inserted
            else { return }
            roots.append(url)
        }

        if let raw = environment.value(for: "CLAUDE_CONFIG_DIR")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            for part in raw.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !part.isEmpty {
                var url = URL(fileURLWithPath: expandHome(part))
                // Accept the `projects/` directory itself as an alias for its parent config dir.
                if url.lastPathComponent == "projects", FileManager.default.fileExists(atPath: url.path) {
                    url.deleteLastPathComponent()
                }
                addIfValid(url)
            }
            if roots.isEmpty {
                AppLog.warn(LogTag.plugin("claude"), "CLAUDE_CONFIG_DIR is set but contains no Claude data directory with projects/: \(raw)")
            }
        } else {
            let home = homeDirectory()
            let xdg = environment.value(for: "XDG_CONFIG_HOME")?.nilIfEmpty.map { URL(fileURLWithPath: expandHome($0)) }
                ?? home.appendingPathComponent(".config")
            addIfValid(xdg.appendingPathComponent("claude"))
            addIfValid(home.appendingPathComponent(".claude"))
        }

        for directory in additionalConfigDirectories {
            addIfValid(URL(fileURLWithPath: expandHome(directory)))
        }

        for sandbox in Self.coworkClaudeDirs(
            home: homeDirectory(), organizationID: organizationID, accountID: accountID
        ) {
            addIfValid(sandbox)
        }
        return roots
    }

    /// The `.claude` dirs Cowork (the Claude desktop app's agent mode) creates, one per session,
    /// under `~/Library/Application Support/Claude/local-agent-mode-sessions/<group>/<sub>/local_*`
    /// (plus an `agent/local_*` variant one level deeper). Each holds the same `projects/**/*.jsonl`
    /// session logs as `~/.claude`, so they scan as additional roots. The walk is bounded to those
    /// known levels — session dirs contain full sandbox homes we must not recurse into.
    private static func coworkClaudeDirs(home: URL, organizationID: String?, accountID: String?) -> [URL] {
        let base = home
            .appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions")

        func subdirectories(of url: URL) -> [URL] {
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            )) ?? []
            return contents.filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            }
        }

        var dirs: [URL] = []
        for group in subdirectories(of: base) {
            guard organizationID == nil || accountID == nil || group.lastPathComponent.lowercased() == accountID
            else { continue }
            for sub in subdirectories(of: group) {
                guard organizationID == nil || sub.lastPathComponent.lowercased() == organizationID else {
                    continue
                }
                var sessions = subdirectories(of: sub)
                for holder in sessions where holder.lastPathComponent == "agent" {
                    sessions.append(contentsOf: subdirectories(of: holder))
                }
                for session in sessions {
                    dirs.append(session.appendingPathComponent(".claude"))
                }
            }
        }
        return dirs.sorted { $0.path < $1.path }
    }

    /// Every `*.jsonl` under each root's `projects/`, path-sorted so the dedup pass (keep-first wins)
    /// is deterministic — the same order ccusage scans in.
    private static func usageFiles(under roots: [URL]) -> [JSONLScanning.DiscoveredFile] {
        roots
            .flatMap { JSONLScanning.jsonlFiles(under: $0.appendingPathComponent("projects")) }
            .sorted { $0.path < $1.path }
    }

    /// Cowork roots carry their organization in the directory layout. Other sessions identify theirs
    /// in a bridge event or Desktop's account-and-organization-scoped session index; subagent files
    /// inherit their parent session's ownership. Keep this outside the shared parsed-entry cache.
    private func ownedUsageFiles(
        _ files: [JSONLScanning.DiscoveredFile],
        claimsDefaultHome: Bool
    ) -> [JSONLScanning.DiscoveredFile] {
        let coworkPrefix = homeDirectory()
            .appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions")
            .resolvingSymlinksInPath().path + "/"
        let filesByPath = Dictionary(files.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        var seenPaths: Set<String> = []
        var ownedFiles: [JSONLScanning.DiscoveredFile] = []
        var desktopSessionIDs: Set<String>?
        var allDesktopSessionIDs: Set<String>?
        let defaultProjectPrefixes = claimsDefaultHome
            ? defaultConfigRoots().map { $0.appendingPathComponent("projects").resolvingSymlinksInPath().path + "/" }
            : []
        // Optional values retain read failures for this pass without persisting them.
        var identities: [String: ClaudeSessionIdentity?] = [:]

        for file in files {
            guard !Task.isCancelled else { return [] }
            guard seenPaths.insert(file.path).inserted else { continue }
            let canonicalPath = URL(fileURLWithPath: file.path).resolvingSymlinksInPath().path
            if canonicalPath.hasPrefix(coworkPrefix) {
                let components = canonicalPath.dropFirst(coworkPrefix.count).split(separator: "/")
                if components.count > 1,
                   components[1].lowercased() == organizationID,
                   accountID == nil || components[0].lowercased() == accountID
                {
                    ownedFiles.append(file)
                }
                continue
            }

            let sessionFile = Self.owningSessionFile(for: file, filesByPath: filesByPath)
            guard let sessionFile else { continue }
            if identities[sessionFile.path] == nil {
                identities[sessionFile.path] = .some(sessionIdentity(sessionFile))
            }
            guard let result = identities[sessionFile.path], let ownership = result else { continue }
            if case .conflicted = ownership { continue }
            if case let .owned(owner, ownerAccount) = ownership {
                if owner == organizationID, accountID == nil || ownerAccount == accountID {
                    ownedFiles.append(file)
                }
            } else if allowsUnattributedSessions {
                ownedFiles.append(file)
            } else {
                let sessionID = URL(fileURLWithPath: sessionFile.path)
                    .deletingPathExtension().lastPathComponent.lowercased()
                if let accountID, let organizationID {
                    if desktopSessionIDs == nil {
                        desktopSessionIDs = indexedDesktopSessionIDs(accountID: accountID, organizationID: organizationID)
                    }
                    if desktopSessionIDs?.contains(sessionID) == true {
                        ownedFiles.append(file)
                        continue
                    }
                }
                // Desktop indexes every session it runs; an indexed session belongs to that Desktop login.
                guard defaultProjectPrefixes.contains(where: { canonicalPath.hasPrefix($0) }) else { continue }
                if allDesktopSessionIDs == nil { allDesktopSessionIDs = allIndexedDesktopSessionIDs() }
                if allDesktopSessionIDs?.contains(sessionID) != true {
                    ownedFiles.append(file)
                }
            }
        }
        return ownedFiles
    }

    /// Only a scoped card whose identity is the one Claude Code is signed in to right now.
    private func isCurrentDefaultLogin() -> Bool {
        guard let accountID, let current = currentDefaultLoginIdentity()?.lowercased() else { return false }
        return current == (organizationID.map { "\(accountID)|\($0)" } ?? accountID)
    }

    private var desktopSessionIndexRoot: URL {
        homeDirectory().appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
    }

    private func indexedDesktopSessionIDs(accountID: String, organizationID: String) -> Set<String> {
        indexedDesktopSessionIDs(
            in: desktopSessionIndexRoot.appendingPathComponent(accountID).appendingPathComponent(organizationID)
        )
    }

    private func allIndexedDesktopSessionIDs() -> Set<String> {
        func subdirectories(of url: URL) -> [URL] {
            ((try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )) ?? []).filter { $0.hasDirectoryPath }
        }
        return subdirectories(of: desktopSessionIndexRoot)
            .flatMap(subdirectories(of:))
            .reduce(into: Set<String>()) { $0.formUnion(indexedDesktopSessionIDs(in: $1)) }
    }

    private func indexedDesktopSessionIDs(in directory: URL) -> Set<String> {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return Set(files.compactMap { file in
            guard file.lastPathComponent.hasPrefix("local_"), file.pathExtension == "json",
                  let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let handle = try? FileHandle(forReadingFrom: file)
            else { return nil }
            defer { try? handle.close() }
            guard let prefix = try? handle.read(upToCount: 512),
                  let header = String(data: prefix, encoding: .utf8),
                  let field = header.range(of: #""cliSessionId"\s*:\s*""#, options: .regularExpression),
                  let end = header[field.upperBound...].firstIndex(of: "\""),
                  let sessionID = UUID(uuidString: String(header[field.upperBound..<end]))
            else { return nil }
            return sessionID.uuidString.lowercased()
        })
    }

    private func sessionIdentity(
        _ file: JSONLScanning.DiscoveredFile
    ) -> ClaudeSessionIdentity? {
        if let cached = sessionOwnership[file.path],
           cached.size == file.size, cached.mtime == file.mtime
        {
            return cached.identity
        }

        do {
            let data = try readOwnershipData(URL(fileURLWithPath: file.path))
            guard let identity = ClaudeSessionIdentity.parse(data), !Task.isCancelled else { return nil }
            sessionOwnership[file.path] = (file.size, file.mtime, identity)
            return identity
        } catch {
            AppLog.warn(LogTag.plugin("claude"), "Failed to read Claude session ownership from \(file.path): \(error)")
            return nil
        }
    }

    // MARK: - Deduplication

    private struct ExactKey: Hashable {
        var messageID: String
        var requestID: String?
    }

    /// Drop replayed usage lines, keeping ccusage's preferences. Entries are keyed by
    /// `(message.id, requestId)`; a second index on `message.id` alone catches sidechain logs that
    /// replay a parent message under a new request id. On a collision the existing entry is replaced
    /// only when the candidate wins `shouldReplace`. Entries without a message id are always kept.
    static func dedup(_ entries: [Entry]) -> [Entry] {
        var deduped: [Entry] = []
        var exactIndex: [ExactKey: Int] = [:]
        var messageIndex: [String: [Int]] = [:]

        for entry in entries {
            guard let messageID = entry.messageID else {
                deduped.append(entry)
                continue
            }
            let key = ExactKey(messageID: messageID, requestID: entry.requestID)
            let collision = exactIndex[key] ?? messageIndex[messageID]?.first(where: { index in
                entry.isSidechain || deduped[index].isSidechain
            })

            if let index = collision {
                if shouldReplace(candidate: entry, existing: deduped[index]) {
                    let old = deduped[index]
                    if let oldID = old.messageID {
                        exactIndex.removeValue(forKey: ExactKey(messageID: oldID, requestID: old.requestID))
                    }
                    deduped[index] = entry
                    exactIndex[key] = index
                }
                continue
            }

            let index = deduped.count
            deduped.append(entry)
            exactIndex[key] = index
            messageIndex[messageID, default: []].append(index)
        }
        return deduped
    }

    /// Preference order on a duplicate: the non-sidechain (parent) entry, then the larger token
    /// total, then the entry that carries a `speed` field (richer log shape).
    static func shouldReplace(candidate: Entry, existing: Entry) -> Bool {
        if candidate.isSidechain != existing.isSidechain {
            return existing.isSidechain
        }
        let candidateTotal = candidate.tokens.totalTokens
        let existingTotal = existing.tokens.totalTokens
        if candidateTotal != existingTotal {
            return candidateTotal > existingTotal
        }
        return candidate.hasSpeed && !existing.hasSpeed
    }

    // MARK: - Response timing

    /// Times every response that finished at or after `since`, for the Output Speed row. A response
    /// spans one line per content block: its request went out at the start its blocks recorded, and it
    /// finished with its last block. Only responses that survive `dedup` count, so a replayed copy of a
    /// message is never timed twice.
    static func responseTimings(entries: [Entry], deduped: [Entry], since: Date) -> [ResponseTiming] {
        var spans: [ExactKey: (start: Date, end: Date, output: Int)] = [:]
        for entry in entries where entry.timestamp >= since {
            guard let start = entry.requestStart, let messageID = entry.messageID else { continue }
            let key = ExactKey(messageID: messageID, requestID: entry.requestID)
            let span = spans[key]
            spans[key] = (
                min(span?.start ?? start, start),
                max(span?.end ?? entry.timestamp, entry.timestamp),
                max(span?.output ?? 0, entry.tokens.output)
            )
        }

        var timings: [ResponseTiming] = []
        for entry in deduped {
            guard !spans.isEmpty else { break }
            guard let messageID = entry.messageID,
                  let span = spans.removeValue(forKey: ExactKey(messageID: messageID, requestID: entry.requestID))
            else { continue }
            timings.append(ResponseTiming(
                end: span.end, duration: span.end.timeIntervalSince(span.start), outputTokens: span.output
            ))
        }
        return timings
    }

    // MARK: - Aggregation

    /// Bucket deduplicated entries into local calendar days. Cost mode "auto": a line's `costUSD`
    /// when present, else tokens priced through `pricing`.
    ///
    /// Entries that can't be priced (an unknown model, or unattributed tokens with no carried cost)
    /// are excluded from every displayed total — tokens, dollars, the trend, and the model breakdown —
    /// because mixing measured tokens with unpriceable ones makes the figures incoherent. An unknown
    /// model's name lands in `unknownModelsByDay` (the tile's warning triangle), the only place
    /// unpriceable usage surfaces.
    static func aggregate(entries: [Entry], since: Date, pricing: ModelPricing) -> LogUsageScan {
        var accumulator = DailyUsageAccumulator()

        for entry in entries where entry.timestamp >= since {
            let day = DailyUsageAccumulator.dayKey(from: entry.timestamp)
            // One trimmed slug for pricing, the unknown-model warning, and the breakdown key alike —
            // diverging spellings would let the warning triangle and the hover panel disagree.
            let trimmedModel = entry.model?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            let modelName = trimmedModel ?? ModelUsageEntry.unattributedModelName

            let cost: Double
            if let carried = entry.costUSD {
                cost = carried
            } else if let model = trimmedModel, let estimated = pricing.estimatedCostDollars(model: model, tokens: entry.tokens) {
                cost = estimated
            } else {
                if let model = trimmedModel, entry.tokens.totalTokens > 0 {
                    accumulator.addUnknownModel(day: day, model: model)
                }
                continue
            }

            accumulator.add(day: day, tokens: entry.tokens.totalTokens, cost: cost, model: modelName)
        }

        return accumulator.build()
    }
}

import Foundation

/// Coordinated access to the app-private data area of the container declared by this build.
actor ICloudUsageHistoryFileStore: UsageHistoryFileStoring {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let containerURL: @Sendable () throws -> URL
    private let downloadStatus: @Sendable (URL) throws -> URLUbiquitousItemDownloadingStatus?
    private let downloadError: @Sendable (URL) throws -> Error?
    private let requestDownload: @Sendable (URL) throws -> Void
    private let now: @Sendable () -> Date
    private var nextDownloadRequests: [URL: Date] = [:]
    private var reportedDownloadErrors: [URL: String] = [:]
    private var loggedDirectory = false

    init(
        containerURL: (@Sendable () throws -> URL)? = nil,
        downloadStatus: @escaping @Sendable (URL) throws -> URLUbiquitousItemDownloadingStatus? = {
            try $0.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus
        },
        downloadError: @escaping @Sendable (URL) throws -> Error? = {
            try $0.resourceValues(forKeys: [.ubiquitousItemDownloadingErrorKey]).ubiquitousItemDownloadingError
        },
        requestDownload: @escaping @Sendable (URL) throws -> Void = {
            try FileManager.default.startDownloadingUbiquitousItem(at: $0)
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.containerURL = containerURL ?? {
            let identifier = try Self.containerIdentifier(in: Bundle.main.infoDictionary ?? [:])
            guard let url = FileManager.default.url(forUbiquityContainerIdentifier: identifier) else {
                throw ICloudUsageSyncError.unavailable
            }
            return url
        }
        self.downloadStatus = downloadStatus
        self.downloadError = downloadError
        self.requestDownload = requestDownload
        self.now = now
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    nonisolated static func containerIdentifier(in info: [String: Any]) throws -> String {
        guard let containers = info["NSUbiquitousContainers"] as? [String: Any],
              containers.count == 1, let identifier = containers.keys.first
        else { throw ICloudUsageSyncError.misconfigured }
        return identifier
    }

    func loadDocuments() async throws -> UsageHistoryLoadResult {
        let directory = try historyDirectory(create: false)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return UsageHistoryLoadResult(documents: [], invalidFileMessages: [])
        }

        // A remote-only file is represented on disk as .<device>.json.icloud. Skipping hidden files
        // or filtering only .json silently loses Macs whose history has not been downloaded yet.
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )
        var candidates: [URL: URL] = [:]
        for entry in entries {
            if entry.pathExtension == "json", !entry.lastPathComponent.hasPrefix(".") {
                candidates[entry] = entry
            } else if entry.lastPathComponent.hasPrefix("."), entry.lastPathComponent.hasSuffix(".json.icloud") {
                let name = String(entry.lastPathComponent.dropFirst().dropLast(".icloud".count))
                let url = directory.appendingPathComponent(name)
                if candidates[url] == nil { candidates[url] = entry }
            }
        }

        var documents: [UsageHistoryDocument] = []
        var errors: [String] = []
        var failures: [UsageHistoryDownloadFailure] = []
        var pendingDownloads = 0
        for (url, metadataURL) in candidates {
            var pending = false
            var updateError: Error?
            do {
                let status = try downloadStatus(metadataURL)
                if metadataURL != url || (status != nil && status != .current) {
                    pending = true
                    updateError = try downloadError(metadataURL)
                    let date = now()
                    if nextDownloadRequests[url].map({ $0 <= date }) ?? true {
                        nextDownloadRequests[url] = date.addingTimeInterval(updateError == nil ? 5 : 60)
                        do { try requestDownload(url) }
                        catch {
                            updateError = error
                            nextDownloadRequests[url] = date.addingTimeInterval(60)
                        }
                    }
                } else {
                    nextDownloadRequests.removeValue(forKey: url)
                }
            } catch {
                pending = true
                updateError = error
            }
            if pending { pendingDownloads += 1 }
            if let updateError {
                let failure = UsageHistoryDownloadFailure(url: url, error: updateError)
                failures.append(failure)
                if reportedDownloadErrors[url] != failure.message {
                    AppLog.warn(.config, "iCloud history update delayed \(failure.filename): \(failure.message)")
                    reportedDownloadErrors[url] = failure.message
                }
            } else if reportedDownloadErrors.removeValue(forKey: url) != nil {
                AppLog.info(.config, "iCloud history download recovered: \(url.lastPathComponent)")
            }

            // A transport failure (including low disk space) does not make the already downloaded
            // JSON invalid. Keep its coordinated, validated history and explicitly report staleness.
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                let document = try decoder.decode(UsageHistoryDocument.self, from: coordinatedRead(url))
                try document.validate()
                documents.append(document)
            } catch {
                errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
                AppLog.warn(.config, "iCloud history ignored \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        nextDownloadRequests = nextDownloadRequests.filter { candidates[$0.key] != nil }
        reportedDownloadErrors = reportedDownloadErrors.filter { candidates[$0.key] != nil }
        return UsageHistoryLoadResult(
            documents: documents, invalidFileMessages: errors, pendingDownloadCount: pendingDownloads,
            downloadFailures: failures
        )
    }

    func write(_ document: UsageHistoryDocument) async throws {
        try document.validate()
        let directory = try historyDirectory(create: true)
        let url = directory.appendingPathComponent(document.deviceID).appendingPathExtension("json")
        try coordinatedWrite(encoder.encode(document), to: url)
        AppLog.info(.config, "iCloud history wrote this Mac's record (\(document.providers.count) providers)")
    }

    func delete(deviceID: String) async throws {
        let directory = try historyDirectory(create: false)
        let url = directory.appendingPathComponent(deviceID).appendingPathExtension("json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var coordinationError: NSError?
        var operationError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { coordinatedURL in
            do { try FileManager.default.removeItem(at: coordinatedURL) }
            catch { operationError = error }
        }
        if let coordinationError { throw coordinationError }
        if let operationError { throw operationError }
    }

    private func historyDirectory(create: Bool) throws -> URL {
        let container = try containerURL()
        if !loggedDirectory {
            AppLog.info(.config, "iCloud history container: \(container.lastPathComponent)")
            loggedDirectory = true
        }
        let directory = container.appendingPathComponent("OpenUsage/History/v1", isDirectory: true)
        if create {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    private func coordinatedRead(_ url: URL) throws -> Data {
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { coordinatedURL in
            result = Result { try Data(contentsOf: coordinatedURL) }
        }
        if let coordinationError { throw coordinationError }
        return try result?.get() ?? { throw CocoaError(.fileReadUnknown) }()
    }

    private func coordinatedWrite(_ data: Data, to url: URL) throws {
        var coordinationError: NSError?
        var operationError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            do { try data.write(to: coordinatedURL, options: .atomic) }
            catch { operationError = error }
        }
        if let coordinationError { throw coordinationError }
        if let operationError { throw operationError }
    }
}

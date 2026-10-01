import Foundation

/// Coordinated access to the app-private data area of the container declared by this build.
actor ICloudUsageHistoryFileStore: UsageHistoryFileStoring {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let containerURL: @Sendable () throws -> URL
    private let downloadStatus: @Sendable (URL) throws -> URLUbiquitousItemDownloadingStatus?
    private let requestDownload: @Sendable (URL) throws -> Void
    private var loggedDirectory = false

    init(
        containerURL: (@Sendable () throws -> URL)? = nil,
        downloadStatus: @escaping @Sendable (URL) throws -> URLUbiquitousItemDownloadingStatus? = { url in
            let values = try url.resourceValues(forKeys: [
                .ubiquitousItemDownloadingStatusKey, .ubiquitousItemDownloadingErrorKey
            ])
            if let error = values.ubiquitousItemDownloadingError { throw error }
            return values.ubiquitousItemDownloadingStatus
        },
        requestDownload: @escaping @Sendable (URL) throws -> Void = {
            try FileManager.default.startDownloadingUbiquitousItem(at: $0)
        }
    ) {
        self.containerURL = containerURL ?? {
            let identifier = try Self.containerIdentifier(in: Bundle.main.infoDictionary ?? [:])
            guard let url = FileManager.default.url(forUbiquityContainerIdentifier: identifier) else {
                throw ICloudUsageSyncError.unavailable
            }
            return url
        }
        self.downloadStatus = downloadStatus
        self.requestDownload = requestDownload
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
        var pendingDownloads = 0
        for (url, metadataURL) in candidates {
            do {
                let status = try downloadStatus(metadataURL)
                if metadataURL != url || (status != nil && status != .current) {
                    try requestDownload(url)
                    pendingDownloads += 1
                    if !FileManager.default.fileExists(atPath: url.path) { continue }
                }
                let document = try decoder.decode(UsageHistoryDocument.self, from: coordinatedRead(url))
                try document.validate()
                documents.append(document)
            } catch {
                errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
                AppLog.warn(.config, "iCloud history ignored \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return UsageHistoryLoadResult(
            documents: documents, invalidFileMessages: errors, pendingDownloadCount: pendingDownloads
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
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
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

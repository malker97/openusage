import Foundation
import Perception

struct UsageHistoryLoadResult: Sendable {
    var documents: [UsageHistoryDocument]
    var invalidFileMessages: [String]
    var pendingDownloadCount: Int = 0
}

protocol UsageHistoryFileStoring: Sendable {
    func loadDocuments() async throws -> UsageHistoryLoadResult
    func write(_ document: UsageHistoryDocument) async throws
    func delete(deviceID: String) async throws
}

protocol ICloudDeviceIDStoring: Sendable {
    func readDeviceID() throws -> String?
    func writeDeviceID(_ deviceID: String) throws
}

struct KeychainICloudDeviceIDStore: ICloudDeviceIDStoring {
    private let service: String
    private let keychain: any KeychainAccessing

    init(
        keychain: any KeychainAccessing = SecurityKeychainAccessor(),
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.robinebers.openusage"
    ) {
        self.keychain = keychain
        self.service = "\(bundleIdentifier).icloud-sync-device-id.v1"
    }

    func readDeviceID() throws -> String? {
        try keychain.readGenericPasswordForCurrentUser(service: service)
    }

    func writeDeviceID(_ deviceID: String) throws {
        try keychain.writeGenericPasswordForCurrentUser(service: service, value: deviceID)
    }
}

enum ICloudUsageSyncError: Error, LocalizedError {
    case unavailable
    case misconfigured
    case monitoringUnavailable

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "iCloud Drive isn’t available. Check that this Mac is signed into iCloud and iCloud Drive is on."
        case .misconfigured:
            "This build has no unambiguous iCloud history container. Reinstall OpenUsage."
        case .monitoringUnavailable:
            "OpenUsage couldn’t watch iCloud changes. Restart the app and check the log."
        }
    }
}

@MainActor
@Perceptible
final class ICloudUsageSyncStore {
    private static let enabledKey = "openusage.icloudSync.enabled.v1"
    private static let deviceIDKey = "openusage.icloudSync.deviceID.v1"

    private let defaults: UserDefaults
    private let fileStore: any UsageHistoryFileStoring
    private let identityError: String?
    private let dataStore: WidgetDataStore
    private let writeDebounce: DelayDuration
    private let observesMetadataChanges: Bool
    private var writeTask: Task<Void, Never>?
    private var downloadReloadTask: Task<Void, Never>?
    private var metadataQuery: NSMetadataQuery?
    private var notificationTokens: [NSObjectProtocol] = []
    private var syncActivityCount = 0

    let deviceID: String
    let deviceName: String
    var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            defaults.set(enabled, forKey: Self.enabledKey)
            Task { await applyEnabledChange() }
        }
    }
    private(set) var isSyncing = false
    private(set) var pendingDownloadCount = 0
    let usesDevelopmentContainer = (try? ICloudUsageHistoryFileStore.containerIdentifier(
        in: Bundle.main.infoDictionary ?? [:]
    )) == "iCloud.com.robinebers.openusage.dev"
    private var operationError: String?
    private var metadataError: String?
    var serviceError: String? { operationError ?? metadataError ?? identityError }
    private(set) var invalidFileMessages: [String] = []
    private(set) var documents: [UsageHistoryDocument] = []

    init(
        dataStore: WidgetDataStore,
        defaults: UserDefaults = .standard,
        fileStore: any UsageHistoryFileStoring = ICloudUsageHistoryFileStore(),
        deviceIDStore: any ICloudDeviceIDStoring = KeychainICloudDeviceIDStore(),
        writeDebounce: DelayDuration = .seconds(3),
        observesMetadataChanges: Bool = true
    ) {
        self.dataStore = dataStore
        self.defaults = defaults
        self.fileStore = fileStore
        self.writeDebounce = writeDebounce
        self.observesMetadataChanges = observesMetadataChanges
        let identity = Self.resolveDeviceID(defaults: defaults, store: deviceIDStore)
        self.deviceID = identity.id
        self.identityError = identity.error
        self.deviceName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        self.enabled = defaults.bool(forKey: Self.enabledKey)
        dataStore.onLocalHistoryChanged = { [weak self] in self?.scheduleWrite() }
        if enabled {
            Task { await applyEnabledChange() }
        }
    }

    var displayedDocuments: [UsageHistoryDocument] {
        documents.sorted { lhs, rhs in
            if lhs.deviceID == deviceID { return true }
            if rhs.deviceID == deviceID { return false }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    func scheduleWrite() {
        guard enabled else { return }
        writeTask?.cancel()
        writeTask = Task { [weak self] in
            guard let self else { return }
            try? await AsyncDelay.sleep(for: writeDebounce)
            guard !Task.isCancelled else { return }
            await writeNow()
        }
    }

    private func applyEnabledChange() async {
        if enabled {
            startObserving()
            await reload()
            await writeNow()
        } else {
            writeTask?.cancel()
            downloadReloadTask?.cancel()
            downloadReloadTask = nil
            pendingDownloadCount = 0
            stopObserving()
            dataStore.clearPeerHistoryDocuments()
            documents = []
            invalidFileMessages = []
            do {
                try await fileStore.delete(deviceID: deviceID)
                operationError = nil
            } catch {
                report(error, context: "disable")
            }
        }
    }

    private func writeNow() async {
        guard enabled else { return }
        await withSyncActivity {
            let document = dataStore.localHistoryDocument(
                deviceID: deviceID,
                deviceName: deviceName
            )
            do {
                try await fileStore.write(document)
                // Disabling can run while the coordinated write is in flight. If it did, remove the
                // just-finished write as well so this Mac cannot reappear in peers after opting out.
                guard enabled else {
                    try await fileStore.delete(deviceID: deviceID)
                    return
                }
                operationError = nil
                await reload()
            } catch {
                report(error, context: "write")
            }
        }
    }

    private func reload() async {
        guard enabled else { return }
        await withSyncActivity {
            do {
                let result = try await fileStore.loadDocuments()
                // A read that began while enabled must not restore peer state after sync was disabled.
                guard enabled else { return }
                let newest = UsageHistoryDocument.newestByDevice(result.documents)
                if Set(documents) != Set(newest) || pendingDownloadCount != result.pendingDownloadCount {
                    let peers = newest.filter { $0.deviceID != deviceID }.count
                    AppLog.info(.config, "iCloud history loaded \(newest.count) Macs (\(peers) peers, \(result.pendingDownloadCount) pending downloads)")
                }
                documents = newest
                pendingDownloadCount = result.pendingDownloadCount
                scheduleDownloadReload()
                invalidFileMessages = result.invalidFileMessages
                dataStore.setPeerHistoryDocuments(result.documents, ownDeviceID: deviceID)
                operationError = result.invalidFileMessages.isEmpty
                    ? nil
                    : "Some synced usage data couldn’t be read. Check the log for details."
            } catch {
                report(error, context: "read")
            }
        }
    }

    private func scheduleDownloadReload() {
        guard pendingDownloadCount > 0 else {
            downloadReloadTask?.cancel()
            downloadReloadTask = nil
            return
        }
        guard downloadReloadTask == nil else { return }
        // Metadata notifications are the primary signal. Retry while downloads are outstanding too,
        // so an initial download cannot depend on receiving a particular query notification.
        downloadReloadTask = Task { [weak self] in
            do { try await AsyncDelay.sleep(for: .seconds(5)) }
            catch { return }
            guard let self else { return }
            self.downloadReloadTask = nil
            guard self.enabled else { return }
            await self.reload()
        }
    }

    private func withSyncActivity(_ operation: () async -> Void) async {
        syncActivityCount += 1
        isSyncing = true
        await operation()
        syncActivityCount -= 1
        isSyncing = syncActivityCount > 0
    }

    private func report(_ error: Error, context: String) {
        operationError = error.localizedDescription
        AppLog.warn(.config, "iCloud history \(context) failed: \(error.localizedDescription)")
    }

    private static func resolveDeviceID(
        defaults: UserDefaults,
        store: any ICloudDeviceIDStoring
    ) -> (id: String, error: String?) {
        let saved = normalizedDeviceID(defaults.string(forKey: deviceIDKey))
        do {
            if let stored = normalizedDeviceID(try store.readDeviceID()) {
                defaults.set(stored, forKey: deviceIDKey)
                return (stored, nil)
            }

            let id = saved ?? UUID().uuidString.lowercased()
            try store.writeDeviceID(id)
            defaults.set(id, forKey: deviceIDKey)
            return (id, nil)
        } catch {
            let id = saved ?? UUID().uuidString.lowercased()
            defaults.set(id, forKey: deviceIDKey)
            let message = "OpenUsage couldn’t save this Mac’s sync identity in Keychain. "
                + "Sync may create a duplicate device if app preferences are reset."
            AppLog.warn(.keychain, "iCloud device identity failed: \(error.localizedDescription)")
            return (id, message)
        }
    }

    private static func normalizedDeviceID(_ value: String?) -> String? {
        guard let value, UUID(uuidString: value) != nil else { return nil }
        return value.lowercased()
    }

    private func startObserving() {
        guard observesMetadataChanges else { return }
        guard metadataQuery == nil else { return }
        let query = NSMetadataQuery()
        // History is app-private data, outside the container's Documents directory.
        query.searchScopes = [NSMetadataQueryUbiquitousDataScope, NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K LIKE '*.json'", NSMetadataItemFSNameKey)
        let center = NotificationCenter.default
        notificationTokens = [
            center.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.metadataQuery?.enableUpdates()
                    await self.reload()
                }
            },
            center.addObserver(forName: .NSMetadataQueryDidUpdate, object: query, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.reload() }
            }
        ]
        metadataQuery = query
        if !query.start() {
            stopObserving()
            let message = ICloudUsageSyncError.monitoringUnavailable.localizedDescription
            metadataError = message
            AppLog.warn(.config, "iCloud history monitoring failed: \(message)")
        } else {
            metadataError = nil
        }
    }

    private func stopObserving() {
        metadataQuery?.stop()
        metadataQuery = nil
        for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
        notificationTokens = []
    }
}

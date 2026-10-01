import Foundation
import XCTest
@testable import OpenUsage

final class ICloudUsageHistoryFileStoreTests: XCTestCase {
    func testContainerMustBeExplicitAndUnambiguous() throws {
        for identifier in ["iCloud.com.robinebers.openusage.dev", "iCloud.com.robinebers.openusage"] {
            XCTAssertEqual(try ICloudUsageHistoryFileStore.containerIdentifier(in: [
                "NSUbiquitousContainers": [identifier: [:]]
            ]), identifier)
        }
        XCTAssertThrowsError(try ICloudUsageHistoryFileStore.containerIdentifier(in: [:]))
        XCTAssertThrowsError(try ICloudUsageHistoryFileStore.containerIdentifier(in: [
            "NSUbiquitousContainers": ["first": [:], "second": [:]]
        ]))
    }

    func testCoordinatedWriteAndLoadRoundTrip() async throws {
        let container = try temporaryContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let store = ICloudUsageHistoryFileStore(containerURL: { container })
        let document = fixture()
        try await store.write(document)
        let result = try await store.loadDocuments()
        XCTAssertEqual(result.documents, [document])
        XCTAssertTrue(result.invalidFileMessages.isEmpty)
        XCTAssertEqual(result.pendingDownloadCount, 0)
    }

    func testRemoteOnlyPlaceholderRequestsOriginalJSONWithoutBeingReportedAsCorrupt() async throws {
        let container = try temporaryContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let history = container.appendingPathComponent("OpenUsage/History/v1")
        try Data().write(to: history.appendingPathComponent(".peer.json.icloud"))
        let requests = Locked<[URL]>(initialState: [])
        let store = ICloudUsageHistoryFileStore(
            containerURL: { container },
            downloadStatus: { _ in .notDownloaded },
            requestDownload: { url in requests.withLock { $0.append(url) } }
        )
        let result = try await store.loadDocuments()
        XCTAssertEqual(requests.withLock { $0 }, [history.appendingPathComponent("peer.json")])
        XCTAssertEqual(result.pendingDownloadCount, 1)
        XCTAssertTrue(result.documents.isEmpty)
        XCTAssertTrue(result.invalidFileMessages.isEmpty)
    }

    func testDownloadedPeerAppearsOnNextReload() async throws {
        let container = try temporaryContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let history = container.appendingPathComponent("OpenUsage/History/v1")
        let placeholder = history.appendingPathComponent(".peer.json.icloud")
        try Data().write(to: placeholder)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let document = fixture()
        let data = try encoder.encode(document)
        let store = ICloudUsageHistoryFileStore(
            containerURL: { container },
            downloadStatus: { $0.pathExtension == "icloud" ? .notDownloaded : .current },
            requestDownload: { url in
                try data.write(to: url, options: .atomic)
                try FileManager.default.removeItem(at: placeholder)
            }
        )
        _ = try await store.loadDocuments()
        let result = try await store.loadDocuments()
        XCTAssertEqual(result.documents, [document])
        XCTAssertEqual(result.pendingDownloadCount, 0)
        XCTAssertTrue(result.invalidFileMessages.isEmpty)
    }

    func testStaleDownloadedHistoryRemainsReadableWhileCurrentVersionDownloads() async throws {
        let container = try temporaryContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let document = fixture()
        let requests = Locked<[URL]>(initialState: [])
        let store = ICloudUsageHistoryFileStore(
            containerURL: { container },
            downloadStatus: { _ in .downloaded },
            requestDownload: { url in requests.withLock { $0.append(url) } }
        )
        try await store.write(document)
        let result = try await store.loadDocuments()
        XCTAssertEqual(result.documents, [document])
        XCTAssertEqual(result.pendingDownloadCount, 1)
        XCTAssertEqual(requests.withLock { $0.count }, 1)
    }

    func testFailedDownloadSurfacesAnErrorInsteadOfLookingLikeAnEmptyCloud() async throws {
        let container = try temporaryContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        try Data().write(to: container.appendingPathComponent("OpenUsage/History/v1/.peer.json.icloud"))
        let store = ICloudUsageHistoryFileStore(
            containerURL: { container },
            downloadStatus: { _ in .notDownloaded },
            requestDownload: { _ in throw CocoaError(.fileReadNoPermission) }
        )
        let result = try await store.loadDocuments()
        XCTAssertTrue(result.invalidFileMessages.isEmpty)
        XCTAssertEqual(result.downloadFailures.count, 1)
        XCTAssertEqual(result.downloadFailures[0].filename, "peer.json")
        XCTAssertEqual(result.pendingDownloadCount, 1)
    }

    func testLowDiskMetadataErrorKeepsValidatedDownloadedHistory() async throws {
        let container = try temporaryContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let document = fixture()
        let store = ICloudUsageHistoryFileStore(
            containerURL: { container },
            downloadStatus: { _ in .downloaded },
            downloadError: { _ in CocoaError(.fileWriteOutOfSpace) },
            requestDownload: { _ in }
        )
        try await store.write(document)
        let result = try await store.loadDocuments()
        XCTAssertEqual(result.documents, [document])
        XCTAssertTrue(result.invalidFileMessages.isEmpty)
        XCTAssertEqual(result.pendingDownloadCount, 1)
        XCTAssertTrue(result.downloadFailures[0].isInsufficientDiskSpace)
    }

    func testFailedDownloadRequestAlsoKeepsValidCachedHistory() async throws {
        let container = try temporaryContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let document = fixture()
        let store = ICloudUsageHistoryFileStore(
            containerURL: { container },
            downloadStatus: { _ in .downloaded },
            requestDownload: { _ in throw CocoaError(.fileWriteOutOfSpace) }
        )
        try await store.write(document)
        let result = try await store.loadDocuments()
        XCTAssertEqual(result.documents, [document])
        XCTAssertTrue(result.invalidFileMessages.isEmpty)
        XCTAssertTrue(result.downloadFailures[0].isInsufficientDiskSpace)
    }

    func testDownloadErrorsBackOffAndRecoverWithoutRestart() async throws {
        let container = try temporaryContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let clock = Locked(initialState: Date(timeIntervalSince1970: 1_700_000_000))
        let failing = Locked(initialState: true)
        let requests = Locked(initialState: 0)
        let store = ICloudUsageHistoryFileStore(
            containerURL: { container },
            downloadStatus: { _ in failing.withLock { $0 } ? .downloaded : .current },
            downloadError: { _ in failing.withLock { $0 } ? CocoaError(.fileWriteOutOfSpace) : nil },
            requestDownload: { _ in requests.withLock { $0 += 1 } },
            now: { clock.withLock { $0 } }
        )
        var document = fixture()
        try await store.write(document)
        for _ in 0..<3 {
            let result = try await store.loadDocuments()
            XCTAssertEqual(result.documents, [document])
            XCTAssertEqual(result.downloadFailures.count, 1)
        }
        XCTAssertEqual(requests.withLock { $0 }, 1)
        clock.withLock { $0.addTimeInterval(60) }
        _ = try await store.loadDocuments()
        XCTAssertEqual(requests.withLock { $0 }, 2)

        failing.withLock { $0 = false }
        document.updatedAt.addTimeInterval(60)
        try await store.write(document)
        let recovered = try await store.loadDocuments()
        XCTAssertEqual(recovered.documents, [document])
        XCTAssertEqual(recovered.pendingDownloadCount, 0)
        XCTAssertTrue(recovered.downloadFailures.isEmpty)
    }

    func testTransportErrorDoesNotMakeCorruptCachedJSONAcceptable() async throws {
        let container = try temporaryContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        try Data("not JSON".utf8).write(to: container.appendingPathComponent("OpenUsage/History/v1/peer.json"))
        let store = ICloudUsageHistoryFileStore(
            containerURL: { container },
            downloadStatus: { _ in .downloaded },
            downloadError: { _ in CocoaError(.fileWriteOutOfSpace) },
            requestDownload: { _ in }
        )
        let result = try await store.loadDocuments()
        XCTAssertTrue(result.documents.isEmpty)
        XCTAssertEqual(result.invalidFileMessages.count, 1)
        XCTAssertEqual(result.downloadFailures.count, 1)
    }

    func testUnrelatedHiddenFilesAreIgnored() async throws {
        let container = try temporaryContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let history = container.appendingPathComponent("OpenUsage/History/v1")
        for name in [".DS_Store", ".unrelated.txt.icloud", ".temporary.json"] {
            try Data().write(to: history.appendingPathComponent(name))
        }
        let store = ICloudUsageHistoryFileStore(containerURL: { container })
        let result = try await store.loadDocuments()
        XCTAssertTrue(result.documents.isEmpty)
        XCTAssertTrue(result.invalidFileMessages.isEmpty)
        XCTAssertEqual(result.pendingDownloadCount, 0)
    }

    private func temporaryContainer() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent("OpenUsage/History/v1"), withIntermediateDirectories: true
        )
        return url
    }

    private func fixture() -> UsageHistoryDocument {
        UsageHistoryDocument(deviceID: "peer", deviceName: "Peer Mac", updatedAt: Date(timeIntervalSince1970: 1_700_000_000), providers: [:])
    }
}

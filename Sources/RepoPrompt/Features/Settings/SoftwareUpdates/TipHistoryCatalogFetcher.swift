import Foundation

struct TipHistoryCatalogFetchFailure: Error {
    let reason: TipHistoryLoadError
    let retryAfter: Date?
}

protocol TipHistoryCatalogFetching: Sendable {
    func fetch(_ url: URL, repository: TipHistoryRepository, olderPage: Bool) async throws -> Data
}

/// No REST API, credentials, persistent cache, or automatic retries. The shared
/// file-backed transport enforces the envelope bound during reception.
struct TipHistoryCatalogFetcher: TipHistoryCatalogFetching {
    func fetch(_ url: URL, repository: TipHistoryRepository, olderPage: Bool) async throws -> Data {
        guard Self.trustsCatalog(url, repository: repository) else { throw TipHistoryLoadError.malformed }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TipHistoryCatalog-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("catalog.json")
            let transfer = TipHistoryTransfer(destination: file, maximumBytes: Int64(TipHistoryCatalogDecoder.maximumEnvelopeSize), expectedBytes: nil, allowsRedirect: {
                Self.trustsCatalog($0, repository: repository) || TipHistoryTransfer.allowsReleaseCDN($0)
            })
            try await transfer.receive(url, requestTimeout: 15, resourceTimeout: 15)
            try Task.checkCancellation()
            return try Data(contentsOf: file)
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as TipHistoryTransferFailure {
            if failure.httpStatus == 404 { throw olderPage ? TipHistoryLoadError.olderPageUnavailable : .notPublishedYet }
            if let status = failure.httpStatus {
                throw TipHistoryCatalogFetchFailure(reason: .httpStatus(status), retryAfter: failure.retryAfter)
            }
            if failure.reason == .timeout { throw TipHistoryLoadError.timeout }
            if failure.reason == .sizeMismatch || failure.reason == .untrustedRedirect { throw TipHistoryLoadError.integrityMismatch }
            throw TipHistoryLoadError.network
        } catch let error as TipHistoryCatalogFetchFailure {
            throw error
        } catch let error as TipHistoryLoadError {
            throw error
        } catch {
            throw TipHistoryLoadError.network
        }
    }

    static func trustsCatalog(_ url: URL, repository: TipHistoryRepository) -> Bool {
        if url == repository.headURL { return true }
        let components = url.pathComponents
        guard components.count == 7, components[3] == "releases", components[4] == "download" else { return false }
        return repository.historyPageURL(tag: components[5]) == url
    }
}

import Darwin
import Foundation
import RepoPromptShared

actor AgentSessionDiskWriter {
    struct Receipt {
        let sequence: UInt64
        let observedFileSize: Int64
        let observedFileModificationDate: Date?
    }

    private struct Write {
        let sequence: UInt64
        let data: Data
        let protectsSubscriptionBinding: Bool
    }

    private struct FileStamp: Equatable {
        let inode: UInt64
        let device: Int32
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int
        let size: Int64

        static func read(_ url: URL) throws -> Self? {
            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                if errno == ENOENT { return nil }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return Self(
                inode: info.st_ino, device: info.st_dev,
                modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanoseconds: info.st_mtimespec.tv_nsec,
                changedSeconds: info.st_ctimespec.tv_sec, changedNanoseconds: info.st_ctimespec.tv_nsec,
                size: info.st_size
            )
        }
    }

    private struct BindingHeader: Decodable {
        let subscriptionAccountBinding: AgentSessionSubscriptionBinding
    }

    enum ProtectedDestinationError: Error {
        case subscriptionAccountBinding
    }

    private struct PendingWrite {
        var pendingWrite: Write?
        var isWriting: Bool
        var waiters: [(sequence: UInt64, continuation: CheckedContinuation<Receipt?, Error>)]
    }

    private var pendingByURL: [URL: PendingWrite] = [:]
    private var idleWaitersByURL: [URL: [CheckedContinuation<Void, Never>]] = [:]
    private var sequence: UInt64 = 0
    private var knownLegacyFileStamps: [URL: FileStamp] = [:]

    #if DEBUG
        private var beforeWriteHook: (@Sendable (URL) async -> Void)?
    #endif

    /// Only the last actually committed submission receives publication authority; coalesced callers get nil.
    func enqueueAndWait(data: Data, url: URL, protectsSubscriptionBinding: Bool = false) async throws -> Receipt? {
        let url = url.standardizedFileURL
        sequence += 1
        let write = Write(sequence: sequence, data: data, protectsSubscriptionBinding: protectsSubscriptionBinding)
        return try await withCheckedThrowingContinuation { continuation in
            var pending = pendingByURL[url] ?? PendingWrite(
                pendingWrite: nil,
                isWriting: false,
                waiters: []
            )
            pending.pendingWrite = write
            pending.waiters.append((write.sequence, continuation))
            let shouldStartWriter = !pending.isWriting
            pending.isWriting = true
            pendingByURL[url] = pending
            if shouldStartWriter {
                Task { await self.drainWrites(for: url) }
            }
        }
    }

    /// A decoded snapshot may publish metadata only while it still describes the current bytes.
    /// Pending writers fail closed; checking and capturing the signature never suspend this owner.
    func metadataReceiptIfUnchanged(data: Data, url: URL) -> Receipt? {
        let url = url.standardizedFileURL
        guard pendingByURL[url] == nil,
              let current = try? Data(contentsOf: url, options: .mappedIfSafe), current == data
        else { return nil }
        sequence += 1
        return Self.receipt(sequence: sequence, data: data, url: url)
    }

    func waitUntilIdle(for url: URL) async {
        let url = url.standardizedFileURL
        guard pendingByURL[url] != nil else { return }
        await withCheckedContinuation { continuation in
            idleWaitersByURL[url, default: []].append(continuation)
        }
    }

    /// Validates and conditionally commits one prepared rehome batch without suspending the actor.
    /// A normal write already queued or in flight for any destination makes the batch fail closed.
    func commitPreparedWorkspaceSessionSidecarBatch(
        _ batch: WorkspaceSessionSidecarPreparedBatch
    ) throws {
        let sourceFolder = batch.sourceFolder.standardizedFileURL
        if let pendingSourceURL = pendingByURL.keys.first(where: { url in
            let url = url.standardizedFileURL
            return url.deletingLastPathComponent() == sourceFolder
                && url.lastPathComponent.hasPrefix(batch.filenamePrefix)
                && url.pathExtension.lowercased() == "json"
        }) {
            throw WorkspaceSessionSidecarMigrationError.sourceWriteInProgress(pendingSourceURL)
        }
        for copy in batch.copies {
            let destinationURL = copy.destinationURL.standardizedFileURL
            guard pendingByURL[destinationURL] == nil else {
                throw WorkspaceSessionSidecarMigrationError.destinationWriteInProgress(destinationURL)
            }
        }
        try WorkspaceSessionSidecarMigration.commitPreparedBatch(batch)
    }

    /// Withdraws a committed batch on the same serialized boundary that published it, so a normal
    /// save cannot interleave between the two.
    func rollbackPreparedWorkspaceSessionSidecarBatch(
        _ batch: WorkspaceSessionSidecarPreparedBatch
    ) -> [URL] {
        WorkspaceSessionSidecarMigration.rollbackPreparedBatch(batch)
    }

    #if DEBUG
        func test_setBeforeWriteHook(_ hook: (@Sendable (URL) async -> Void)?) {
            beforeWriteHook = hook
        }

        func test_pendingWriteCount(for url: URL) -> Int {
            // Preserve the admitted file URL's identity if a failure fixture replaces it with a
            // directory: re-standardizing then appends a slash and can falsely report idle.
            pendingByURL[url]?.waiters.count ?? pendingByURL[url.standardizedFileURL]?.waiters.count ?? 0
        }
    #endif

    private static func receipt(sequence: UInt64, data: Data, url: URL) -> Receipt {
        let values = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.contentModificationDateKey])
        return Receipt(
            sequence: sequence, observedFileSize: Int64(data.count),
            observedFileModificationDate: values?.contentModificationDate
        )
    }

    private func drainWrites(for url: URL) async {
        var lastError: Error?
        var lastReceipt: Receipt?
        while true {
            guard var pending = pendingByURL[url] else { return }
            guard let write = pending.pendingWrite else {
                pending.isWriting = false
                let waiters = pending.waiters
                pendingByURL.removeValue(forKey: url)
                for waiter in waiters {
                    // A failed successor cannot revoke the receipt for bytes that committed.
                    if let lastReceipt, lastReceipt.sequence == waiter.sequence {
                        waiter.continuation.resume(returning: lastReceipt)
                    } else if let lastError {
                        waiter.continuation.resume(throwing: lastError)
                    } else {
                        waiter.continuation.resume(returning: nil)
                    }
                }
                let idleWaiters = idleWaitersByURL.removeValue(forKey: url) ?? []
                for waiter in idleWaiters {
                    waiter.resume()
                }
                return
            }
            pending.pendingWrite = nil
            pendingByURL[url] = pending

            #if DEBUG
                if let beforeWriteHook {
                    await beforeWriteHook(url)
                }
            #endif

            let cachedStamp = knownLegacyFileStamps[url]
            let writeResult: Result<(Receipt, FileStamp?), Error> = await Task.detached(priority: .utility) {
                do {
                    try AppProfileLocations.current.validateMetadataFile(url)
                    if write.protectsSubscriptionBinding,
                       let stamp = try FileStamp.read(url), stamp != cachedStamp
                    {
                        let existing = try Data(contentsOf: url, options: .mappedIfSafe)
                        let header = try JSONDecoder().decode(BindingHeader.self, from: existing)
                        guard !header.subscriptionAccountBinding.blocksProviderOperations else {
                            throw ProtectedDestinationError.subscriptionAccountBinding
                        }
                    }
                    try write.data.write(to: url, options: .atomic)
                    let stamp = write.protectsSubscriptionBinding ? (try? FileStamp.read(url)) : nil
                    return .success((Self.receipt(sequence: write.sequence, data: write.data, url: url), stamp))
                } catch {
                    return .failure(error)
                }
            }.value

            switch writeResult {
            case let .success((receipt, stamp)):
                lastError = nil
                lastReceipt = receipt
                // Exact metadata avoids reparsing the transcript after our own writes. Bounded;
                // uncertainty or an external edit forces a fresh destination read.
                if knownLegacyFileStamps.count >= 256, cachedStamp == nil {
                    knownLegacyFileStamps.removeAll(keepingCapacity: true)
                }
                knownLegacyFileStamps[url] = stamp
            case let .failure(error):
                knownLegacyFileStamps.removeValue(forKey: url)
                lastError = error
            }
        }
    }
}

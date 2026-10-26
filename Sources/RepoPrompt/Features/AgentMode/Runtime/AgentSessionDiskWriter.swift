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
    }

    private struct PendingWrite {
        var pendingWrite: Write?
        var isWriting: Bool
        var waiters: [(sequence: UInt64, continuation: CheckedContinuation<Receipt?, Error>)]
    }

    private var pendingByURL: [URL: PendingWrite] = [:]
    private var idleWaitersByURL: [URL: [CheckedContinuation<Void, Never>]] = [:]
    private var sequence: UInt64 = 0

    #if DEBUG
        private var beforeWriteHook: (@Sendable (URL) async -> Void)?
    #endif

    /// Only the final committed submission receives publication authority; coalesced callers get nil.
    func enqueueAndWait(data: Data, url: URL) async throws -> Receipt? {
        let url = url.standardizedFileURL
        sequence += 1
        let write = Write(sequence: sequence, data: data)
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
            pendingByURL[url.standardizedFileURL]?.waiters.count ?? 0
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
                    if let lastError {
                        waiter.continuation.resume(throwing: lastError)
                    } else {
                        waiter.continuation.resume(
                            returning: lastReceipt?.sequence == waiter.sequence ? lastReceipt : nil
                        )
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

            let writeResult: Result<Receipt, Error> = await Task.detached(priority: .utility) {
                do {
                    try AppProfileLocations.current.validateMetadataFile(url)
                    try write.data.write(to: url, options: .atomic)
                    return .success(Self.receipt(sequence: write.sequence, data: write.data, url: url))
                } catch {
                    return .failure(error)
                }
            }.value

            switch writeResult {
            case let .success(receipt):
                lastError = nil
                lastReceipt = receipt
            case let .failure(error):
                lastError = error
            }
        }
    }
}

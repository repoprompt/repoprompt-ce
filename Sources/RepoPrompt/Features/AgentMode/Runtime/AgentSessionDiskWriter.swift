import Foundation
import RepoPromptShared

actor AgentSessionDiskWriter {
    private struct PendingWrite {
        var pendingData: Data?
        var isWriting: Bool
        var waiters: [CheckedContinuation<Void, Error>]
    }

    private var pendingByURL: [URL: PendingWrite] = [:]
    private var idleWaitersByURL: [URL: [CheckedContinuation<Void, Never>]] = [:]

    #if DEBUG
        private var beforeWriteHook: (@Sendable (URL) async -> Void)?
    #endif

    func enqueueAndWait(data: Data, url: URL) async throws {
        let url = url.standardizedFileURL
        try await withCheckedThrowingContinuation { continuation in
            var pending = pendingByURL[url] ?? PendingWrite(
                pendingData: nil,
                isWriting: false,
                waiters: []
            )
            pending.pendingData = data
            pending.waiters.append(continuation)
            let shouldStartWriter = !pending.isWriting
            pending.isWriting = true
            pendingByURL[url] = pending
            if shouldStartWriter {
                Task { await self.drainWrites(for: url) }
            }
        }
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
    #endif

    private func drainWrites(for url: URL) async {
        var lastError: Error?
        while true {
            guard var pending = pendingByURL[url] else { return }
            guard let data = pending.pendingData else {
                pending.isWriting = false
                let waiters = pending.waiters
                pendingByURL.removeValue(forKey: url)
                for waiter in waiters {
                    if let lastError {
                        waiter.resume(throwing: lastError)
                    } else {
                        waiter.resume(returning: ())
                    }
                }
                let idleWaiters = idleWaitersByURL.removeValue(forKey: url) ?? []
                for waiter in idleWaiters {
                    waiter.resume()
                }
                return
            }
            pending.pendingData = nil
            pendingByURL[url] = pending

            #if DEBUG
                if let beforeWriteHook {
                    await beforeWriteHook(url)
                }
            #endif

            let writeResult: Result<Void, Error> = await Task.detached(priority: .utility) {
                do {
                    try AppProfileLocations.current.validateMetadataFile(url)
                    try data.write(to: url, options: .atomic)
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }.value

            switch writeResult {
            case .success:
                lastError = nil
            case let .failure(error):
                lastError = error
            }
        }
    }
}

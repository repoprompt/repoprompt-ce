import Foundation

extension AgentSessionDataService {
    func agentSessionFilename(for id: UUID) -> String {
        "AgentSession-\(id.uuidString).json"
    }

    struct DeletionAttempts {
        var activeCount = 0
        var committed = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    /// Admit a turn-end image move under the same authority that fences transcript saves/deletion.
    /// Registration precedes any suspension; once deletion installs its tombstone, no new move can
    /// join. The worker stays off this actor so image decoding does not stall session operations.
    func retainConsumedAttachments(
        _ attachments: [AgentFileAttachment],
        sessionID: UUID,
        store: AgentSessionAttachmentStore,
        workspaceDirectory: URL
    ) async -> AgentSessionAttachmentStore.RetentionResult {
        let fileURL = store.rootURL.deletingLastPathComponent()
            .appendingPathComponent(agentSessionFilename(for: sessionID)).standardizedFileURL
        let empty = AgentSessionAttachmentStore.RetentionResult(retained: [:], evictedPaths: [])
        await waitForDeletionAttempts(for: fileURL)
        guard !deletedSessionFileURLs.contains(fileURL) else {
            await Task.detached(priority: .utility) {
                AgentAttachmentStore().clearConsumedLocalFiles(attachments, workspaceDirectory: workspaceDirectory)
            }.value
            return empty
        }
        let temporaryRoot = AgentAttachmentStore.managedStorageRootURL(for: workspaceDirectory)
        let predecessors = Array(attachmentFileTasksByFileURL[fileURL]?.values ?? [:].values)
        #if DEBUG
            let beforeRetention = testBeforeAttachmentRetentionHook
        #endif
        let move = Task.detached(priority: .utility) {
            for predecessor in predecessors {
                await predecessor.value
            }
            #if DEBUG
                await beforeRetention?(fileURL)
            #endif
            return store.retain(attachments, sessionID: sessionID, temporaryRoot: temporaryRoot)
        }
        let token = UUID()
        attachmentFileTasksByFileURL[fileURL, default: [:]][token] = Task { _ = await move.value }
        let result = await move.value
        removeAttachmentOperation(token, for: [fileURL])
        // A failed deletion preserves the moved images and must still publish their usable paths.
        // Wait only for deletion attempts, never for another retention caller (deletion drains the
        // worker task, not this method), so there is no retention/deletion dependency cycle.
        await waitForDeletionAttempts(for: fileURL)
        return deletedSessionFileURLs.contains(fileURL) ? empty : result
    }

    /// Copy under both session lifetimes. A parent delete waits for the independent bytes; a child
    /// delete waits before removing them and permanently fences any later copy admission.
    func copyHandoffAttachments(
        _ attachments: [AgentFileAttachment],
        sourceSessionID: UUID?,
        destinationSessionID: UUID,
        store: AgentSessionAttachmentStore,
        temporaryRoot: URL?,
        missingImagePolicy: AgentSessionAttachmentStore.HandoffMissingImagePolicy = .strict
    ) async throws -> [UUID: AgentFileAttachment] {
        let folder = store.rootURL.deletingLastPathComponent()
        let destinationURL = folder.appendingPathComponent(agentSessionFilename(for: destinationSessionID)).standardizedFileURL
        var sessionURLs = [destinationURL]
        if let sourceSessionID {
            sessionURLs.append(folder.appendingPathComponent(agentSessionFilename(for: sourceSessionID)).standardizedFileURL)
        }
        for url in sessionURLs {
            await waitForDeletionAttempts(for: url)
        }
        try Task.checkCancellation()
        guard !deletedSessionFileURLs.contains(destinationURL) else {
            throw AgentSessionDataError.sessionDeleted(destinationSessionID)
        }
        if let sourceSessionID, let sourceURL = sessionURLs.last, deletedSessionFileURLs.contains(sourceURL) {
            throw AgentSessionDataError.sessionDeleted(sourceSessionID)
        }
        // Capture every predecessor before registering either endpoint. Even opposing A->B/B->A
        // copies form a strict admission order, never a cycle through a later operation or caller.
        let predecessors = sessionURLs.flatMap { Array(attachmentFileTasksByFileURL[$0]?.values ?? [:].values) }
        #if DEBUG
            let beforeCopy = testBeforeHandoffAttachmentCopyHook
        #endif
        let copy = Task.detached(priority: .utility) {
            for predecessor in predecessors {
                await predecessor.value
            }
            #if DEBUG
                await beforeCopy?(destinationSessionID)
            #endif
            return try store.copyForHandoff(
                attachments, sourceSessionID: sourceSessionID, destinationSessionID: destinationSessionID,
                temporaryRoot: temporaryRoot, missingImagePolicy: missingImagePolicy
            )
        }
        let token = UUID()
        let completion = Task { _ = await copy.result }
        for url in sessionURLs {
            attachmentFileTasksByFileURL[url, default: [:]][token] = completion
        }
        defer { removeAttachmentOperation(token, for: sessionURLs) }
        let result = try await withTaskCancellationHandler {
            try await copy.value
        } onCancel: {
            copy.cancel()
        }
        // Deletion awaits only the worker's completion, not this method, so its settlement cannot
        // deadlock here. A failed deletion preserves the completed copy and permits publication.
        await waitForDeletionAttempts(for: destinationURL)
        guard !deletedSessionFileURLs.contains(destinationURL) else {
            throw AgentSessionDataError.sessionDeleted(destinationSessionID)
        }
        return result
    }

    private func removeAttachmentOperation(_ token: UUID, for fileURLs: [URL]) {
        for fileURL in fileURLs {
            attachmentFileTasksByFileURL[fileURL]?[token] = nil
            if attachmentFileTasksByFileURL[fileURL]?.isEmpty == true {
                attachmentFileTasksByFileURL[fileURL] = nil
            }
        }
    }

    private func waitForDeletionAttempts(for fileURL: URL) async {
        while deletionAttemptsByFileURL[fileURL]?.activeCount ?? 0 > 0 {
            await withCheckedContinuation { continuation in
                deletionAttemptsByFileURL[fileURL]?.waiters.append(continuation)
            }
        }
    }

    func finishDeletionAttempt(for fileURL: URL, committed: Bool) {
        guard var attempts = deletionAttemptsByFileURL[fileURL] else { return }
        attempts.activeCount -= 1
        attempts.committed = attempts.committed || committed
        guard attempts.activeCount == 0 else {
            deletionAttemptsByFileURL[fileURL] = attempts
            return
        }
        let waiters = attempts.waiters
        attempts.waiters = []
        if attempts.committed {
            deletionAttemptsByFileURL[fileURL] = attempts
        } else {
            deletionAttemptsByFileURL[fileURL] = nil
            deletedSessionFileURLs.remove(fileURL)
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    #if DEBUG
        func test_setBeforeAttachmentRetentionHook(_ hook: (@Sendable (URL) async -> Void)?) {
            testBeforeAttachmentRetentionHook = hook
        }

        func test_setBeforeHandoffAttachmentCopyHook(_ hook: (@Sendable (UUID) async -> Void)?) {
            testBeforeHandoffAttachmentCopyHook = hook
        }

        func test_attachmentRetentionDeletionWaiterCount(for fileURL: URL) -> Int {
            deletionAttemptsByFileURL[fileURL.standardizedFileURL]?.waiters.count ?? 0
        }
    #endif
}

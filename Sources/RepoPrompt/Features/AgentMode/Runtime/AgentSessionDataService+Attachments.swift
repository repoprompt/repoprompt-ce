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
        _ attachments: [AgentImageAttachment],
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
        #if DEBUG
            let beforeRetention = testBeforeAttachmentRetentionHook
        #endif
        let move = Task.detached(priority: .utility) {
            #if DEBUG
                await beforeRetention?(fileURL)
            #endif
            return store.retain(attachments, sessionID: sessionID, temporaryRoot: temporaryRoot)
        }
        let token = UUID()
        attachmentRetentionTasksByFileURL[fileURL, default: [:]][token] = move
        let result = await move.value
        attachmentRetentionTasksByFileURL[fileURL]?[token] = nil
        if attachmentRetentionTasksByFileURL[fileURL]?.isEmpty == true {
            attachmentRetentionTasksByFileURL[fileURL] = nil
        }
        // A failed deletion preserves the moved images and must still publish their usable paths.
        // Wait only for deletion attempts, never for another retention caller (deletion drains the
        // worker task, not this method), so there is no retention/deletion dependency cycle.
        await waitForDeletionAttempts(for: fileURL)
        return deletedSessionFileURLs.contains(fileURL) ? empty : result
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

        func test_attachmentRetentionDeletionWaiterCount(for fileURL: URL) -> Int {
            deletionAttemptsByFileURL[fileURL.standardizedFileURL]?.waiters.count ?? 0
        }
    #endif
}

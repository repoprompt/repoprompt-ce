import Foundation
import RepoPromptDomainRuntime

package struct WorkspaceDiskPayloadIdentity: Equatable {
    package let workspaceID: UUID
    package let dateModified: Date

    package init(workspaceID: UUID, dateModified: Date) {
        self.workspaceID = workspaceID
        self.dateModified = dateModified
    }
}

package struct WorkspaceDiskSelectionRecord<Key: Hashable & Sendable, Selection: Sendable, Metadata: Sendable> {
    package let key: Key
    package let revision: UInt64
    package let selection: Selection
    package let metadata: Metadata

    package init(key: Key, revision: UInt64, selection: Selection, metadata: Metadata) {
        self.key = key
        self.revision = revision
        self.selection = selection
        self.metadata = metadata
    }
}

package struct WorkspaceDiskEffectivePayload<Metadata: Sendable, Key: Hashable & Sendable> {
    package let data: Data
    package let metadata: Metadata?
    package let selectionKey: Key?
    package let effectiveSelectionRevision: UInt64
    package let shouldWrite: Bool
    package let identityPayloadCount: Int
    package let fullWorkspacePayloadCount: Int

    package init(data: Data, metadata: Metadata?, selectionKey: Key?, effectiveSelectionRevision: UInt64, shouldWrite: Bool, identityPayloadCount: Int = 0, fullWorkspacePayloadCount: Int = 0) {
        self.data = data
        self.metadata = metadata
        self.selectionKey = selectionKey
        self.effectiveSelectionRevision = effectiveSelectionRevision
        self.shouldWrite = shouldWrite
        self.identityPayloadCount = identityPayloadCount
        self.fullWorkspacePayloadCount = fullWorkspacePayloadCount
    }
}

/// The app owns workspace decoding, selection merge, stale-payload decisions,
/// and trace projection. The filesystem actor owns only serialization and I/O.
package protocol WorkspaceDiskWritePolicy: Sendable {
    associatedtype Metadata: Sendable
    associatedtype Selection: Sendable
    associatedtype SelectionKey: Hashable & Sendable

    func payloadIdentity(metadata: Metadata?, data: Data) -> WorkspaceDiskPayloadIdentity?
    func selectionKey(metadata: Metadata?) -> SelectionKey?
    func selectionRecord(metadata: Metadata?) -> WorkspaceDiskSelectionRecord<SelectionKey, Selection, Metadata>?
    func selectionRevision(metadata: Metadata) -> UInt64
    func shouldKeepExistingPayload(existing: WorkspaceDiskPayloadIdentity?, incoming: WorkspaceDiskPayloadIdentity?, metadata: Metadata?, url: URL) -> Bool
    func effectivePayloadForWrite(data: Data, identity: WorkspaceDiskPayloadIdentity?, url: URL, metadata: Metadata?, latestSelection: WorkspaceDiskSelectionRecord<SelectionKey, Selection, Metadata>?, lastWrittenRevision: UInt64) -> WorkspaceDiskEffectivePayload<Metadata, SelectionKey>
    func trace(_ event: String, metadata: Metadata?, url: URL, extra: [String: String])
}

/// Both write paths belong to the same host-selected backend. Custom backends
/// must supply both operations; neither silently falls back to physical writes.
/// File stamp checks remain filesystem-owned. Normalization must not suspend
/// between the actor's pending/stamp checks and the write.
package struct WorkspaceDiskWriteBackend {
    package let queuedAtomicWrite: @Sendable (Data, URL) async throws -> Void
    package let normalizationAtomicWrite: @Sendable (Data, URL) throws -> Void

    package init(queuedAtomicWrite: @escaping @Sendable (Data, URL) async throws -> Void, normalizationAtomicWrite: @escaping @Sendable (Data, URL) throws -> Void) {
        self.queuedAtomicWrite = queuedAtomicWrite
        self.normalizationAtomicWrite = normalizationAtomicWrite
    }

    package static let physical = WorkspaceDiskWriteBackend(
        queuedAtomicWrite: { data, url in try data.write(to: url, options: .atomic) },
        normalizationAtomicWrite: { data, url in try data.write(to: url, options: .atomic) }
    )
}

/// One process-composed writer should be injected across windows. There is no
/// library singleton and no knowledge of WorkspaceModel or a view model.
package actor WorkspaceDiskWriter<Policy: WorkspaceDiskWritePolicy> {
    private typealias SelectionRecord = WorkspaceDiskSelectionRecord<Policy.SelectionKey, Policy.Selection, Policy.Metadata>
    private typealias EffectivePayload = WorkspaceDiskEffectivePayload<Policy.Metadata, Policy.SelectionKey>

    private struct Pending {
        var newestData: Data
        var newestMetadata: Policy.Metadata?
        var newestIdentity: WorkspaceDiskPayloadIdentity?
        var newestLifecycleCorrelation: EditFlowPerf.LifecycleCorrelation?
        var task: Task<Void, Never>?
    }

    package nonisolated let policy: Policy
    private let backend: WorkspaceDiskWriteBackend
    private var pendingByURL: [URL: Pending] = [:]
    private var waitersByURL: [URL: [CheckedContinuation<Void, Never>]] = [:]
    private var latestSelectionByWorkspaceTab: [Policy.SelectionKey: SelectionRecord] = [:]
    private var lastWrittenSelectionRevisionByWorkspaceTab: [Policy.SelectionKey: UInt64] = [:]
    #if DEBUG
        private var atomicWriteGateForTesting: (@Sendable () async -> Void)?
        private var identityPayloadCount = 0
        private var fullWorkspacePayloadCount = 0
    #endif

    package init(policy: Policy, backend: WorkspaceDiskWriteBackend = .physical) {
        self.policy = policy
        self.backend = backend
    }

    package func enqueue(data: Data, url: URL) {
        enqueue(data: data, url: url, metadata: nil)
    }

    package func enqueueWorkspace(data: Data, url: URL, metadata: Policy.Metadata) {
        enqueue(data: data, url: url, metadata: metadata)
    }

    private func enqueue(data: Data, url: URL, metadata: Policy.Metadata?) {
        let correlation = EditFlowPerf.currentLifecycleCorrelation
        policy.trace("workspaceSave.enqueue", metadata: metadata, url: url, extra: [:])
        recordLatestSelectionIfNeeded(metadata)
        let identity = policy.payloadIdentity(metadata: metadata, data: data)
        #if DEBUG
            if metadata == nil, identity != nil {
                identityPayloadCount &+= 1
            }
        #endif
        if var pending = pendingByURL[url] {
            let decision: String
            if let metadata, let existing = pending.newestMetadata,
               policy.selectionRevision(metadata: metadata) > policy.selectionRevision(metadata: existing)
            {
                decision = "replacedExistingNewerSelectionRevision"
            } else if policy.shouldKeepExistingPayload(existing: pending.newestIdentity, incoming: identity, metadata: metadata, url: url) {
                policy.trace("workspaceSave.coalesce", metadata: metadata, url: url, extra: ["decision": "keptExistingNewerDate"])
                return
            } else {
                decision = "storedAsNewest"
            }
            pending.newestData = data
            pending.newestMetadata = metadata
            pending.newestIdentity = identity
            pending.newestLifecycleCorrelation = correlation ?? pending.newestLifecycleCorrelation
            pendingByURL[url] = pending
            policy.trace("workspaceSave.coalesce", metadata: metadata, url: url, extra: ["decision": decision])
            return
        }
        pendingByURL[url] = Pending(newestData: data, newestMetadata: metadata, newestIdentity: identity, newestLifecycleCorrelation: correlation, task: nil)
        runNext(for: url)
    }

    package func enqueueAndWait(data: Data, url: URL) async {
        enqueue(data: data, url: url)
        await flush(url: url)
    }

    package func writeNormalizationIfUnchanged(data: Data, url: URL, expectedFileSize: Int64, expectedModificationDate: Date, metadata: Policy.Metadata? = nil) -> Bool {
        guard pendingByURL[url] == nil else { return false }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard Int64(values.fileSize ?? -1) == expectedFileSize, values.contentModificationDate == expectedModificationDate else { return false }
            policy.trace("workspaceSave.syncWrite.begin", metadata: metadata, url: url, extra: ["path": "normalization"])
            let state = EditFlowPerf.begin(EditFlowPerf.Stage.WorkspaceDurability.atomicWrite)
            EditFlowPerf.lifecycleEvent(EditFlowPerf.Lifecycle.WorkspaceDurability.writeBegan)
            defer {
                EditFlowPerf.lifecycleEvent(EditFlowPerf.Lifecycle.WorkspaceDurability.writeEnded)
                EditFlowPerf.end(EditFlowPerf.Stage.WorkspaceDurability.atomicWrite, state)
            }
            try backend.normalizationAtomicWrite(data, url)
            recordLatestSelectionIfNeeded(metadata)
            policy.trace("workspaceSave.syncWrite.success", metadata: metadata, url: url, extra: ["path": "normalization"])
            return true
        } catch {
            policy.trace("workspaceSave.syncWrite.failure", metadata: metadata, url: url, extra: ["error": error.localizedDescription, "path": "normalization"])
            print("💾 Normalization write skipped \(url.lastPathComponent): \(error)")
            return false
        }
    }

    package func flush(url: URL) async {
        guard pendingByURL[url] != nil else { return }
        let correlation = EditFlowPerf.currentLifecycleCorrelation
        let state = EditFlowPerf.begin(EditFlowPerf.Stage.WorkspaceDurability.flushWait)
        EditFlowPerf.lifecycleEvent(EditFlowPerf.Lifecycle.WorkspaceDurability.flushBegan, correlation: correlation)
        await withCheckedContinuation { waitersByURL[url, default: []].append($0) }
        EditFlowPerf.lifecycleEvent(EditFlowPerf.Lifecycle.WorkspaceDurability.flushEnded, correlation: correlation)
        EditFlowPerf.end(EditFlowPerf.Stage.WorkspaceDurability.flushWait, state)
    }

    private func recordLatestSelectionIfNeeded(_ metadata: Policy.Metadata?) {
        guard let record = policy.selectionRecord(metadata: metadata), record.revision > 0 else { return }
        if let existing = latestSelectionByWorkspaceTab[record.key], existing.revision >= record.revision {
            return
        }
        latestSelectionByWorkspaceTab[record.key] = record
    }

    private func runNext(for url: URL) {
        guard var slot = pendingByURL[url] else { return }
        let data = slot.newestData
        let metadata = slot.newestMetadata
        let identity = slot.newestIdentity
        let correlation = slot.newestLifecycleCorrelation
        slot.newestData = Data()
        slot.newestMetadata = nil
        slot.newestIdentity = nil
        slot.newestLifecycleCorrelation = nil
        pendingByURL[url] = slot
        let key = policy.selectionKey(metadata: metadata)
        let latest = key.flatMap { latestSelectionByWorkspaceTab[$0] }
        let lastWritten = key.map { lastWrittenSelectionRevisionByWorkspaceTab[$0, default: 0] } ?? 0
        let policy = policy
        let atomicWrite = backend.queuedAtomicWrite
        #if DEBUG
            let gate = atomicWriteGateForTesting
        #endif
        let task = Task.detached(priority: .utility) { [weak self] in
            let effective = policy.effectivePayloadForWrite(data: data, identity: identity, url: url, metadata: metadata, latestSelection: latest, lastWrittenRevision: lastWritten)
            policy.trace("workspaceSave.write.begin", metadata: effective.metadata, url: url, extra: ["shouldWrite": "\(effective.shouldWrite)"])
            var succeeded = false
            do {
                if effective.shouldWrite {
                    #if DEBUG
                        await gate?()
                    #endif
                    let state = EditFlowPerf.begin(EditFlowPerf.Stage.WorkspaceDurability.atomicWrite)
                    EditFlowPerf.lifecycleEvent(EditFlowPerf.Lifecycle.WorkspaceDurability.writeBegan, correlation: correlation)
                    defer {
                        EditFlowPerf.lifecycleEvent(EditFlowPerf.Lifecycle.WorkspaceDurability.writeEnded, correlation: correlation, EditFlowPerf.Dimensions(outcome: succeeded ? "success" : "failed"))
                        EditFlowPerf.end(EditFlowPerf.Stage.WorkspaceDurability.atomicWrite, state, EditFlowPerf.Dimensions(outcome: succeeded ? "success" : "failed"))
                    }
                    try await atomicWrite(effective.data, url)
                    succeeded = true
                    policy.trace("workspaceSave.write.success", metadata: effective.metadata, url: url, extra: [:])
                }
            } catch {
                policy.trace("workspaceSave.write.failure", metadata: effective.metadata, url: url, extra: ["error": error.localizedDescription])
                print("💾 Write failed \(url.lastPathComponent): \(error)")
            }
            policy.trace("workspaceSave.write.finish", metadata: effective.metadata, url: url, extra: ["writeSucceeded": "\(succeeded)"])
            await self?.writerFinished(for: url, effective: effective, writeSucceeded: succeeded)
        }
        if var current = pendingByURL[url] {
            current.task = task
            pendingByURL[url] = current
        }
    }

    private func writerFinished(for url: URL, effective: EffectivePayload, writeSucceeded: Bool) {
        #if DEBUG
            identityPayloadCount &+= effective.identityPayloadCount
            fullWorkspacePayloadCount &+= effective.fullWorkspacePayloadCount
        #endif
        if writeSucceeded, let key = effective.selectionKey, effective.effectiveSelectionRevision > 0 {
            lastWrittenSelectionRevisionByWorkspaceTab[key] = max(lastWrittenSelectionRevisionByWorkspaceTab[key, default: 0], effective.effectiveSelectionRevision)
        }
        guard var slot = pendingByURL[url] else { return }
        if slot.newestData.isEmpty {
            pendingByURL.removeValue(forKey: url)
            if let waiters = waitersByURL.removeValue(forKey: url) {
                for waiter in waiters {
                    waiter.resume()
                }
            }
        } else {
            slot.task = nil
            pendingByURL[url] = slot
            runNext(for: url)
        }
    }

    #if DEBUG
        package func setAtomicWriteGateForTesting(_ gate: (@Sendable () async -> Void)?) {
            atomicWriteGateForTesting = gate
        }

        package func decodeWorkSnapshotForTesting() -> (identityPayloadCount: Int, fullWorkspacePayloadCount: Int) {
            (identityPayloadCount, fullWorkspacePayloadCount)
        }

        package func removeAllForTesting() {
            for pending in pendingByURL.values {
                pending.task?.cancel()
            }
            pendingByURL.removeAll()
            latestSelectionByWorkspaceTab.removeAll()
            lastWrittenSelectionRevisionByWorkspaceTab.removeAll()
            atomicWriteGateForTesting = nil
            identityPayloadCount = 0
            fullWorkspacePayloadCount = 0
            let waiters = waitersByURL.values.flatMap(\.self)
            waitersByURL.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
    #endif
}

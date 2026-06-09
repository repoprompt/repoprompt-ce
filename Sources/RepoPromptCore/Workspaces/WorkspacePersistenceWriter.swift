import Foundation

package actor WorkspacePersistenceWriter {
    private struct PendingWrite {
        var sequence: UInt64
        var data: Data
        var metadata: WorkspaceSavePayloadMetadata?
    }

    private struct Waiter {
        let cut: UInt64
        let continuation: CheckedContinuation<WorkspaceWriteCompletion, Never>
    }

    private struct URLState {
        var nextSequence: UInt64 = 0
        var completedSequence: UInt64 = 0
        var queue: [PendingWrite] = []
        var workerRunning = false
        var failures: [UInt64: String] = [:]
        var waiters: [Waiter] = []
    }

    private struct LatestSelectionRecord {
        let revision: UInt64
        let selection: StoredSelection
    }

    private struct EffectiveWritePayload {
        let data: Data
        let metadata: WorkspaceSavePayloadMetadata?
        let selectionRevisions: [WorkspaceTabSelectionKey: UInt64]
        let shouldWrite: Bool
    }

    private final class SelectionRevisionRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var nextRevision: UInt64 = 0

        func allocate() -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            nextRevision &+= 1
            return nextRevision
        }

        func reset() {
            lock.lock()
            nextRevision = 0
            lock.unlock()
        }
    }

    private nonisolated let revisionRegistry = SelectionRevisionRegistry()
    private let codec: EmbeddedWorkspaceCodecV1
    private let diagnostics: any WorkspaceRepositoryDiagnosticsSink
    private var states: [URL: URLState] = [:]
    private var diagnosticsIDByURL: [URL: UUID] = [:]
    private var latestSelectionByWorkspaceTab: [WorkspaceTabSelectionKey: LatestSelectionRecord] = [:]
    private var lastWrittenSelectionRevisionByWorkspaceTab: [WorkspaceTabSelectionKey: UInt64] = [:]

    #if DEBUG
        private var atomicWriteGateForTesting: (@Sendable () async -> Void)?
    #endif

    package init(
        codec: EmbeddedWorkspaceCodecV1 = EmbeddedWorkspaceCodecV1(),
        diagnostics: any WorkspaceRepositoryDiagnosticsSink = NoopWorkspaceRepositoryDiagnosticsSink()
    ) {
        self.codec = codec
        self.diagnostics = diagnostics
    }

    package nonisolated func allocateSelectionRevision() -> UInt64 {
        revisionRegistry.allocate()
    }

    @discardableResult
    package func enqueue(data: Data, url: URL) -> WorkspaceWriteReceipt {
        enqueue(data: data, url: url, metadata: nil)
    }

    @discardableResult
    package func enqueueWorkspace(
        data: Data,
        url: URL,
        metadata: WorkspaceSavePayloadMetadata
    ) -> WorkspaceWriteReceipt {
        enqueue(data: data, url: url, metadata: metadata)
    }

    @discardableResult
    package func enqueueWorkspace(
        _ workspace: WorkspaceModel,
        url: URL,
        metadata: WorkspaceSavePayloadMetadata
    ) throws -> WorkspaceWriteReceipt {
        let data = try codec.encode(workspace).data
        return enqueue(data: data, url: url, metadata: metadata)
    }

    package func flush(url: URL) async -> WorkspaceWriteCompletion? {
        guard let state = states[url], state.nextSequence > 0 else { return nil }
        return await flush(WorkspaceWriteReceipt(url: url, sequence: state.nextSequence))
    }

    package func flush(_ receipt: WorkspaceWriteReceipt) async -> WorkspaceWriteCompletion {
        if let state = states[receipt.url], state.completedSequence >= receipt.sequence {
            return completion(for: receipt, state: state)
        }
        emit(
            "workspaceSave.flush.begin",
            metadata: nil,
            url: receipt.url,
            fields: ["sequence": "\(receipt.sequence)"]
        )
        let completion = await withCheckedContinuation { continuation in
            var state = states[receipt.url] ?? URLState()
            state.waiters.append(Waiter(cut: receipt.sequence, continuation: continuation))
            states[receipt.url] = state
        }
        emit(
            "workspaceSave.flush.end",
            metadata: nil,
            url: receipt.url,
            fields: ["sequence": "\(receipt.sequence)"]
        )
        return completion
    }

    #if DEBUG
        package func setAtomicWriteGateForTesting(_ gate: (@Sendable () async -> Void)?) {
            atomicWriteGateForTesting = gate
        }

        package func removeAllForTesting() {
            states.removeAll()
            diagnosticsIDByURL.removeAll()
            latestSelectionByWorkspaceTab.removeAll()
            lastWrittenSelectionRevisionByWorkspaceTab.removeAll()
            atomicWriteGateForTesting = nil
            revisionRegistry.reset()
        }
    #endif

    private func enqueue(
        data: Data,
        url: URL,
        metadata: WorkspaceSavePayloadMetadata?
    ) -> WorkspaceWriteReceipt {
        recordLatestSelectionIfNeeded(metadata)
        var state = states[url] ?? URLState()
        state.nextSequence &+= 1
        let sequence = state.nextSequence
        let incoming = PendingWrite(sequence: sequence, data: data, metadata: metadata)

        // Every returned receipt identifies this exact payload. Keep it as a distinct queue item so
        // a later enqueue cannot complete an earlier receipt with different bytes.
        state.queue.append(incoming)

        let shouldStart = !state.workerRunning
        if shouldStart { state.workerRunning = true }
        states[url] = state
        emit("workspaceSave.enqueue", metadata: metadata, url: url, fields: ["sequence": "\(sequence)"])

        if shouldStart {
            Task.detached(priority: .utility) { [weak self] in
                await self?.drain(url: url)
            }
        }
        return WorkspaceWriteReceipt(url: url, sequence: sequence)
    }

    private func drain(url: URL) async {
        while let work = takeNext(url: url) {
            let selectionKeys = work.metadata.map { metadata in
                metadata.selectionRecords.map { $0.key(workspaceID: metadata.workspaceID) }
            } ?? []
            let latestRecords = Dictionary(uniqueKeysWithValues: selectionKeys.compactMap { key in
                latestSelectionByWorkspaceTab[key].map { (key, $0) }
            })
            let lastWrittenRevisions = Dictionary(uniqueKeysWithValues: selectionKeys.map { key in
                (key, lastWrittenSelectionRevisionByWorkspaceTab[key, default: 0])
            })
            let codec = codec
            #if DEBUG
                let gate = atomicWriteGateForTesting
            #endif
            let effective = await Task.detached(priority: .utility) {
                Self.effectivePayloadForWrite(
                    payload: work.data,
                    url: url,
                    metadata: work.metadata,
                    latestRecords: latestRecords,
                    lastWrittenRevisions: lastWrittenRevisions,
                    codec: codec
                )
            }.value

            var errorDescription: String?
            if effective.shouldWrite {
                emit(
                    "workspaceSave.write.begin",
                    metadata: effective.metadata,
                    url: url,
                    fields: ["sequence": "\(work.sequence)"]
                )
                #if DEBUG
                    await gate?()
                #endif
                do {
                    try effective.data.write(to: url, options: .atomic)
                } catch {
                    errorDescription = error.localizedDescription
                }
                emit(
                    "workspaceSave.write.end",
                    metadata: effective.metadata,
                    url: url,
                    fields: [
                        "sequence": "\(work.sequence)",
                        "error": errorDescription ?? ""
                    ]
                )
            }
            finish(
                url: url,
                sequence: work.sequence,
                effective: effective,
                errorDescription: errorDescription
            )
        }
    }

    private func takeNext(url: URL) -> PendingWrite? {
        guard var state = states[url] else { return nil }
        guard !state.queue.isEmpty else {
            state.workerRunning = false
            states[url] = state
            resumeSatisfiedWaiters(url: url)
            return nil
        }
        let work = state.queue.removeFirst()
        states[url] = state
        return work
    }

    private func finish(
        url: URL,
        sequence: UInt64,
        effective: EffectiveWritePayload,
        errorDescription: String?
    ) {
        if errorDescription == nil, effective.shouldWrite {
            for (key, revision) in effective.selectionRevisions where revision > 0 {
                lastWrittenSelectionRevisionByWorkspaceTab[key] = max(
                    lastWrittenSelectionRevisionByWorkspaceTab[key, default: 0],
                    revision
                )
            }
        }

        guard var state = states[url] else { return }
        state.completedSequence = max(state.completedSequence, sequence)
        if let errorDescription {
            state.failures[sequence] = errorDescription
        } else if effective.shouldWrite {
            state.failures = state.failures.filter { $0.key > sequence }
        }
        states[url] = state
        emit(
            errorDescription == nil ? "workspaceSave.write.finish" : "workspaceSave.write.failure",
            metadata: effective.metadata,
            url: url,
            fields: [
                "sequence": "\(sequence)",
                "shouldWrite": "\(effective.shouldWrite)",
                "error": errorDescription ?? ""
            ]
        )
        resumeSatisfiedWaiters(url: url)
    }

    private func resumeSatisfiedWaiters(url: URL) {
        guard var state = states[url] else { return }
        var pending: [Waiter] = []
        var ready: [Waiter] = []
        for waiter in state.waiters {
            if state.completedSequence >= waiter.cut {
                ready.append(waiter)
            } else {
                pending.append(waiter)
            }
        }
        state.waiters = pending
        states[url] = state
        for waiter in ready {
            waiter.continuation.resume(
                returning: completion(
                    for: WorkspaceWriteReceipt(url: url, sequence: waiter.cut),
                    state: state
                )
            )
        }
    }

    private func completion(for receipt: WorkspaceWriteReceipt, state: URLState) -> WorkspaceWriteCompletion {
        let failure = state.failures
            .filter { $0.key <= receipt.sequence }
            .max(by: { $0.key < $1.key })?
            .value
        return WorkspaceWriteCompletion(receipt: receipt, errorDescription: failure)
    }

    private func recordLatestSelectionIfNeeded(_ metadata: WorkspaceSavePayloadMetadata?) {
        guard let metadata else { return }
        for record in metadata.selectionRecords where record.revision > 0 {
            let key = record.key(workspaceID: metadata.workspaceID)
            if let existing = latestSelectionByWorkspaceTab[key], existing.revision >= record.revision {
                continue
            }
            latestSelectionByWorkspaceTab[key] = LatestSelectionRecord(
                revision: record.revision,
                selection: record.selection
            )
        }
    }

    private nonisolated static func effectivePayloadForWrite(
        payload: Data,
        url: URL,
        metadata: WorkspaceSavePayloadMetadata?,
        latestRecords: [WorkspaceTabSelectionKey: LatestSelectionRecord],
        lastWrittenRevisions: [WorkspaceTabSelectionKey: UInt64],
        codec: EmbeddedWorkspaceCodecV1
    ) -> EffectiveWritePayload {
        guard let metadata,
              let incomingWorkspace = try? codec.decode(payload).document,
              incomingWorkspace.id == metadata.workspaceID
        else {
            return EffectiveWritePayload(
                data: payload,
                metadata: metadata,
                selectionRevisions: [:],
                shouldWrite: !isStaleComparedWithDisk(payload: payload, url: url, codec: codec)
            )
        }

        let incomingRevisions = Dictionary(uniqueKeysWithValues: metadata.selectionRecords.map { record in
            (record.key(workspaceID: metadata.workspaceID), record.revision)
        })
        let diskWorkspace: WorkspaceModel? = if FileManager.default.fileExists(atPath: url.path),
                                                let diskData = try? Data(contentsOf: url),
                                                let decoded = try? codec.decode(diskData).document,
                                                decoded.id == incomingWorkspace.id
        {
            decoded
        } else {
            nil
        }

        if let diskWorkspace, diskWorkspace.dateModified > incomingWorkspace.dateModified {
            var merged = diskWorkspace
            var effectiveRevisions: [WorkspaceTabSelectionKey: UInt64] = [:]
            for (key, latest) in latestRecords
                where latest.revision > lastWrittenRevisions[key, default: 0]
            {
                guard let updated = workspaceByApplyingSelection(
                    latest.selection,
                    toTab: key.tabID,
                    in: merged
                ) else { continue }
                merged = updated
                effectiveRevisions[key] = latest.revision
            }
            if !effectiveRevisions.isEmpty,
               let encoded = try? codec.encode(withCurrentDate(merged)).data
            {
                return EffectiveWritePayload(
                    data: encoded,
                    metadata: metadata,
                    selectionRevisions: effectiveRevisions,
                    shouldWrite: true
                )
            }
            return EffectiveWritePayload(
                data: payload,
                metadata: metadata,
                selectionRevisions: [:],
                shouldWrite: false
            )
        }

        var merged = incomingWorkspace
        var effectiveRevisions = incomingRevisions
        var didMerge = false
        for (key, latest) in latestRecords
            where latest.revision > incomingRevisions[key, default: 0]
        {
            guard let updated = workspaceByApplyingSelection(
                latest.selection,
                toTab: key.tabID,
                in: merged
            ) else { continue }
            merged = updated
            effectiveRevisions[key] = latest.revision
            didMerge = true
        }
        let effectiveData = if didMerge, let encoded = try? codec.encode(merged).data {
            encoded
        } else {
            payload
        }
        return EffectiveWritePayload(
            data: effectiveData,
            metadata: metadata,
            selectionRevisions: effectiveRevisions,
            shouldWrite: true
        )
    }

    private nonisolated static func isStaleComparedWithDisk(
        payload: Data,
        url: URL,
        codec: EmbeddedWorkspaceCodecV1
    ) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              let incoming = try? codec.decode(payload).document,
              let diskData = try? Data(contentsOf: url),
              let disk = try? codec.decode(diskData).document,
              disk.id == incoming.id
        else { return false }
        return disk.dateModified > incoming.dateModified
    }

    private nonisolated static func workspaceByApplyingSelection(
        _ selection: StoredSelection,
        toTab tabID: UUID,
        in workspace: WorkspaceModel
    ) -> WorkspaceModel? {
        guard let tabIndex = workspace.composeTabs.firstIndex(where: { $0.id == tabID }) else { return nil }
        var updated = workspace
        updated.composeTabs[tabIndex].selection = selection
        return updated
    }

    private nonisolated static func withCurrentDate(_ workspace: WorkspaceModel) -> WorkspaceModel {
        var updated = workspace
        updated.dateModified = Date()
        return updated
    }

    private func emit(
        _ name: String,
        metadata: WorkspaceSavePayloadMetadata?,
        url: URL,
        fields: [String: String] = [:]
    ) {
        var payload = fields
        payload["url"] = url.lastPathComponent
        let standardizedURL = url.standardizedFileURL
        let urlID = diagnosticsIDByURL[standardizedURL] ?? UUID()
        diagnosticsIDByURL[standardizedURL] = urlID
        payload["urlID"] = urlID.uuidString
        if let metadata {
            payload["source"] = metadata.source.rawValue
            payload["workspaceID"] = metadata.workspaceID.uuidString
            payload["payloadID"] = metadata.payloadID.uuidString
        }
        diagnostics.record(.event(name: name, fields: payload))
    }
}

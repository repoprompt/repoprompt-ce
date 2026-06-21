import Foundation

package struct WorkspacePersistenceFileFingerprint: Equatable {
    package let size: UInt64
    package let modificationDate: Date

    package init(size: UInt64, modificationDate: Date) {
        self.size = size
        self.modificationDate = modificationDate
    }
}

package struct WorkspaceSessionPersistenceIO: @unchecked Sendable {
    package let read: @Sendable (URL) async throws -> Data?
    package let atomicWrite: @Sendable (Data, URL) async throws -> Void
    package let fingerprint: @Sendable (URL) async throws -> WorkspacePersistenceFileFingerprint?

    package init(
        read: @escaping @Sendable (URL) async throws -> Data?,
        atomicWrite: @escaping @Sendable (Data, URL) async throws -> Void,
        fingerprint: @escaping @Sendable (URL) async throws -> WorkspacePersistenceFileFingerprint?
    ) {
        self.read = read
        self.atomicWrite = atomicWrite
        self.fingerprint = fingerprint
    }

    package static let foundation = WorkspaceSessionPersistenceIO(
        read: { url in
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try Data(contentsOf: url)
        },
        atomicWrite: { data, url in
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        },
        fingerprint: { url in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? NSNumber,
                  let modified = attributes[.modificationDate] as? Date
            else { return nil }
            return WorkspacePersistenceFileFingerprint(
                size: size.uint64Value,
                modificationDate: modified
            )
        }
    )
}

package struct WorkspacePersistenceSelectionMetadata: @unchecked Sendable, Equatable {
    package let key: WorkspaceTabSelectionKey
    package let revision: UInt64
    package let selection: StoredSelection

    package init(key: WorkspaceTabSelectionKey, revision: UInt64, selection: StoredSelection) {
        self.key = key
        self.revision = revision
        self.selection = selection
    }
}

package struct WorkspaceSessionPersistenceRequest: @unchecked Sendable, Equatable {
    package let url: URL
    package let workspace: WorkspaceModel
    package let dirtyGeneration: UInt64
    package let selectionMetadata: WorkspacePersistenceSelectionMetadata?

    package init(
        url: URL,
        workspace: WorkspaceModel,
        dirtyGeneration: UInt64,
        selectionMetadata: WorkspacePersistenceSelectionMetadata? = nil
    ) {
        self.url = url
        self.workspace = workspace
        self.dirtyGeneration = dirtyGeneration
        self.selectionMetadata = selectionMetadata
    }
}

package enum WorkspacePersistenceWriteResult: Equatable {
    case written(dirtyGeneration: UInt64, selectionRevision: UInt64)
    case suppressedByNewerDisk
    case skippedEphemeral
    case normalizationCompareAndSwapFailed
    case failed(String)
}

package actor WorkspaceSessionPersistenceCoordinator {
    private struct Pending {
        var request: WorkspaceSessionPersistenceRequest
        var waiters: [CheckedContinuation<WorkspacePersistenceWriteResult, Never>]
    }

    private struct Slot {
        var pending: Pending?
        var isDraining = false
    }

    private let io: WorkspaceSessionPersistenceIO
    private var slots: [URL: Slot] = [:]
    private var latestSelections: [WorkspaceTabSelectionKey: WorkspacePersistenceSelectionMetadata] = [:]
    private var lastWrittenSelectionRevisions: [WorkspaceTabSelectionKey: UInt64] = [:]
    private var indexWritingURLs: Set<URL> = []
    private var indexWaitersByURL: [URL: [CheckedContinuation<Void, Never>]] = [:]

    package init(io: WorkspaceSessionPersistenceIO = .foundation) {
        self.io = io
    }

    package func persist(_ request: WorkspaceSessionPersistenceRequest) async -> WorkspacePersistenceWriteResult {
        if let metadata = request.selectionMetadata,
           metadata.revision > latestSelections[metadata.key]?.revision ?? 0
        {
            latestSelections[metadata.key] = metadata
        }

        return await withCheckedContinuation { continuation in
            var slot = slots[request.url, default: Slot()]
            if var pending = slot.pending {
                if candidate(request, outranks: pending.request) {
                    pending.request = request
                }
                pending.waiters.append(continuation)
                slot.pending = pending
            } else {
                slot.pending = Pending(request: request, waiters: [continuation])
            }
            let shouldStart = !slot.isDraining
            if shouldStart { slot.isDraining = true }
            slots[request.url] = slot
            if shouldStart {
                Task { await self.drain(url: request.url) }
            }
        }
    }

    package func persistIndex(
        workspaces: [WorkspaceModel],
        url: URL
    ) async -> WorkspacePersistenceWriteResult {
        await acquireIndexWrite(url: url)
        do {
            let entries = workspaces
                .filter { !$0.isEphemeral }
                .map(WorkspaceIndexEntry.init(workspace:))
            try await io.atomicWrite(JSONEncoder().encode(entries), url)
            releaseIndexWrite(url: url)
            return .written(dirtyGeneration: 0, selectionRevision: 0)
        } catch {
            releaseIndexWrite(url: url)
            return .failed(error.localizedDescription)
        }
    }

    package func loadWorkspace(url: URL) async throws -> WorkspaceModel {
        guard let data = try await io.read(url) else {
            throw WorkspaceSessionFailure("workspace file is unavailable")
        }
        return try JSONDecoder().decode(WorkspaceModel.self, from: data)
    }

    package func loadIndex(url: URL) async throws -> [WorkspaceIndexEntry] {
        guard let data = try await io.read(url) else { return [] }
        return try JSONDecoder().decode([WorkspaceIndexEntry].self, from: data)
    }

    private func acquireIndexWrite(url: URL) async {
        if indexWritingURLs.insert(url).inserted { return }
        await withCheckedContinuation { continuation in
            indexWaitersByURL[url, default: []].append(continuation)
        }
    }

    private func releaseIndexWrite(url: URL) {
        if var waiters = indexWaitersByURL[url], !waiters.isEmpty {
            let next = waiters.removeFirst()
            indexWaitersByURL[url] = waiters.isEmpty ? nil : waiters
            next.resume()
        } else {
            indexWritingURLs.remove(url)
        }
    }

    package func flush(url: URL) async {
        while slots[url]?.isDraining == true {
            await Task.yield()
        }
    }

    package func writeNormalizationIfUnchanged(
        data: Data,
        url: URL,
        expectedFingerprint: WorkspacePersistenceFileFingerprint
    ) async -> WorkspacePersistenceWriteResult {
        guard slots[url]?.isDraining != true else {
            return .normalizationCompareAndSwapFailed
        }
        do {
            guard try await io.fingerprint(url) == expectedFingerprint else {
                return .normalizationCompareAndSwapFailed
            }
            try await io.atomicWrite(data, url)
            return .written(dirtyGeneration: 0, selectionRevision: 0)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func drain(url: URL) async {
        while let pending = takePending(url: url) {
            let result = await perform(pending.request)
            for waiter in pending.waiters {
                waiter.resume(returning: result)
            }
        }
        var slot = slots[url, default: Slot()]
        slot.isDraining = false
        slots[url] = slot.pending == nil ? nil : slot
        if slot.pending != nil {
            Task { self.restartDrainIfNeeded(url: url) }
        }
    }

    private func restartDrainIfNeeded(url: URL) {
        var slot = slots[url, default: Slot()]
        guard slot.pending != nil, !slot.isDraining else { return }
        slot.isDraining = true
        slots[url] = slot
        Task { await self.drain(url: url) }
    }

    private func takePending(url: URL) -> Pending? {
        guard var slot = slots[url], let pending = slot.pending else { return nil }
        slot.pending = nil
        slots[url] = slot
        return pending
    }

    private func candidate(
        _ candidate: WorkspaceSessionPersistenceRequest,
        outranks current: WorkspaceSessionPersistenceRequest
    ) -> Bool {
        let candidateRevision = candidate.selectionMetadata?.revision ?? 0
        let currentRevision = current.selectionMetadata?.revision ?? 0
        if candidateRevision != currentRevision {
            return candidateRevision > currentRevision
        }
        if candidate.workspace.dateModified != current.workspace.dateModified {
            return candidate.workspace.dateModified > current.workspace.dateModified
        }
        return true
    }

    private func perform(_ request: WorkspaceSessionPersistenceRequest) async -> WorkspacePersistenceWriteResult {
        guard !request.workspace.isEphemeral else { return .skippedEphemeral }
        do {
            var effective = request.workspace
            let diskData = try await io.read(request.url)
            let diskWorkspace = diskData.flatMap { try? JSONDecoder().decode(WorkspaceModel.self, from: $0) }
            let requestRevision = request.selectionMetadata?.revision ?? 0
            var effectiveRevision = requestRevision

            if let diskWorkspace, diskWorkspace.dateModified > effective.dateModified {
                guard let latest = latestSelection(for: request),
                      latest.revision > lastWrittenSelectionRevisions[latest.key, default: 0],
                      apply(selection: latest, to: &effective, base: diskWorkspace)
                else {
                    return .suppressedByNewerDisk
                }
                effectiveRevision = latest.revision
            } else if let latest = latestSelection(for: request), latest.revision > requestRevision {
                _ = apply(selection: latest, to: &effective, base: effective)
                effectiveRevision = latest.revision
            }

            let data = try JSONEncoder().encode(effective)
            try await io.atomicWrite(data, request.url)
            if let key = request.selectionMetadata?.key, effectiveRevision > 0 {
                lastWrittenSelectionRevisions[key] = max(
                    lastWrittenSelectionRevisions[key, default: 0],
                    effectiveRevision
                )
            }
            return .written(
                dirtyGeneration: request.dirtyGeneration,
                selectionRevision: effectiveRevision
            )
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func latestSelection(
        for request: WorkspaceSessionPersistenceRequest
    ) -> WorkspacePersistenceSelectionMetadata? {
        guard let key = request.selectionMetadata?.key else { return nil }
        return latestSelections[key]
    }

    private func apply(
        selection metadata: WorkspacePersistenceSelectionMetadata,
        to workspace: inout WorkspaceModel,
        base: WorkspaceModel
    ) -> Bool {
        guard metadata.key.workspaceID == base.id,
              let tabIndex = base.composeTabs.firstIndex(where: { $0.id == metadata.key.tabID })
        else { return false }
        workspace = base
        workspace.composeTabs[tabIndex].selection = metadata.selection
        workspace.composeTabs[tabIndex].lastModified = Date()
        workspace.dateModified = Date()
        return true
    }
}

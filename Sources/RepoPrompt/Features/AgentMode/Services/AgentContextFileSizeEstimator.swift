import Foundation

struct AgentContextFileMetadataSnapshot: Equatable {
    let byteCount: Int64?
    let modificationDate: Date?
    let isRegularFile: Bool
}

struct AgentContextFileSizeEstimateRequest: Equatable {
    let file: AgentContextFileBrowseFile
    let rootGeneration: UInt64
}

struct AgentContextFileSizeEstimateResult: Equatable {
    let fileID: UUID
    let rootID: UUID
    let rootGeneration: UInt64
    let estimate: AgentContextFileBrowseTokenEstimate
    let modificationDate: Date?
}

actor AgentContextFileSizeEstimator {
    typealias MetadataReader = @Sendable (String) async throws -> AgentContextFileMetadataSnapshot

    private struct CacheKey: Equatable, Hashable {
        let rootID: UUID
        let fileID: UUID
        let standardizedFullPath: String
        let rootGeneration: UInt64
    }

    private struct CachedEstimate: Equatable {
        let estimate: AgentContextFileBrowseTokenEstimate
        let modificationDate: Date?
    }

    private struct QueuedReadPermit {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let metadataReader: MetadataReader
    private let maximumConcurrentReads: Int
    private var currentGenerationByRootID: [UUID: UInt64] = [:]
    private var cache: [CacheKey: CachedEstimate] = [:]
    private var pendingReadTasks: [CacheKey: Task<CachedEstimate?, Never>] = [:]
    private var activeReadPermitIDs: Set<UUID> = []
    private var queuedReadPermits: [QueuedReadPermit] = []

    init(
        maximumConcurrentReads: Int = 16,
        metadataReader: MetadataReader? = nil
    ) {
        precondition(maximumConcurrentReads > 0, "Metadata concurrency must be positive")
        self.maximumConcurrentReads = maximumConcurrentReads
        if let metadataReader {
            self.metadataReader = metadataReader
        } else {
            self.metadataReader = { @Sendable path in
                try await Self.readMetadata(path: path)
            }
        }
    }

    func estimate(
        for file: AgentContextFileBrowseFile,
        rootGeneration: UInt64
    ) async -> AgentContextFileSizeEstimateResult {
        let request = AgentContextFileSizeEstimateRequest(file: file, rootGeneration: rootGeneration)
        return await estimates(for: [request])[0]
    }

    func estimates(
        for requests: [AgentContextFileSizeEstimateRequest]
    ) async -> [AgentContextFileSizeEstimateResult] {
        guard !requests.isEmpty else { return [] }
        precondition(Self.hasOneGenerationPerRoot(requests), "A metadata batch must use one generation per root")

        for request in requests {
            invalidateRootIfNeeded(rootID: request.file.rootID, generation: request.rootGeneration)
        }

        let uniqueRequests = Dictionary(requests.map { (Self.cacheKey(for: $0), $0) }, uniquingKeysWith: { first, _ in first })
        let completed = await withTaskGroup(of: (CacheKey, CachedEstimate?).self) { group in
            for (key, request) in uniqueRequests {
                group.addTask { [weak self] in
                    guard let self else { return (key, nil) }
                    return await (key, cachedEstimate(for: request))
                }
            }
            var results: [CacheKey: CachedEstimate] = [:]
            for await (key, estimate) in group {
                results[key] = estimate
            }
            return results
        }

        return requests.map { request in
            let key = Self.cacheKey(for: request)
            let cached = completed[key] ?? cache[key]
            return AgentContextFileSizeEstimateResult(
                fileID: request.file.id,
                rootID: request.file.rootID,
                rootGeneration: request.rootGeneration,
                estimate: cached?.estimate ?? .notRequested,
                modificationDate: cached?.modificationDate
            )
        }
    }

    func readPermitStateCountForTesting() -> Int {
        activeReadPermitIDs.count + queuedReadPermits.count
    }

    func pruneCaches(retainingRootIDs: Set<UUID>) {
        cache = cache.filter { retainingRootIDs.contains($0.key.rootID) }
        currentGenerationByRootID = currentGenerationByRootID.filter { retainingRootIDs.contains($0.key) }
        for (key, task) in pendingReadTasks where !retainingRootIDs.contains(key.rootID) {
            task.cancel()
            pendingReadTasks[key] = nil
        }
    }

    private func cachedEstimate(
        for request: AgentContextFileSizeEstimateRequest
    ) async -> CachedEstimate? {
        let key = Self.cacheKey(for: request)
        guard currentGenerationByRootID[key.rootID] == key.rootGeneration else { return nil }
        if let cached = cache[key] { return cached }
        let task: Task<CachedEstimate?, Never>
        if let pending = pendingReadTasks[key] {
            task = pending
        } else {
            task = Task { [weak self, metadataReader] in
                guard let self else { return nil }
                return await performScheduledRead(
                    path: request.file.standardizedFullPath,
                    metadataReader: metadataReader
                )
            }
            pendingReadTasks[key] = task
        }

        let estimate = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if pendingReadTasks[key] != nil {
            pendingReadTasks[key] = nil
        }
        guard !Task.isCancelled,
              currentGenerationByRootID[key.rootID] == key.rootGeneration,
              let estimate
        else { return nil }
        cache[key] = estimate
        return estimate
    }

    private func performScheduledRead(
        path: String,
        metadataReader: MetadataReader
    ) async -> CachedEstimate? {
        let permitID = UUID()
        guard await acquireReadPermit(id: permitID) else { return nil }
        defer { releaseReadPermit(id: permitID) }
        guard !Task.isCancelled else { return nil }
        return await Self.readEstimate(path: path, metadataReader: metadataReader)
    }

    private func acquireReadPermit(id: UUID) async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else if activeReadPermitIDs.count < maximumConcurrentReads {
                    activeReadPermitIDs.insert(id)
                    continuation.resume(returning: true)
                } else {
                    queuedReadPermits.append(QueuedReadPermit(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelReadPermit(id: id) }
        }
    }

    private func cancelReadPermit(id: UUID) {
        guard let index = queuedReadPermits.firstIndex(where: { $0.id == id }) else { return }
        let queued = queuedReadPermits.remove(at: index)
        queued.continuation.resume(returning: false)
    }

    private func releaseReadPermit(id: UUID) {
        guard activeReadPermitIDs.remove(id) != nil,
              !queuedReadPermits.isEmpty
        else { return }
        let next = queuedReadPermits.removeFirst()
        activeReadPermitIDs.insert(next.id)
        next.continuation.resume(returning: true)
    }

    private func invalidateRootIfNeeded(rootID: UUID, generation: UInt64) {
        if let currentGeneration = currentGenerationByRootID[rootID] {
            guard generation > currentGeneration else { return }
        }
        currentGenerationByRootID[rootID] = generation
        cache = cache.filter { $0.key.rootID != rootID }
        for (key, task) in pendingReadTasks where key.rootID == rootID {
            task.cancel()
            pendingReadTasks[key] = nil
        }
    }

    private static func readEstimate(
        path: String,
        metadataReader: MetadataReader
    ) async -> CachedEstimate? {
        do {
            let metadata = try await metadataReader(path)
            guard metadata.isRegularFile,
                  let byteCount = metadata.byteCount,
                  byteCount >= 0,
                  byteCount <= Int64(Int.max)
            else {
                return CachedEstimate(estimate: .unavailable, modificationDate: metadata.modificationDate)
            }
            return CachedEstimate(
                estimate: .known(TokenCalculationService.estimateTokens(utf8ByteCount: Int(byteCount))),
                modificationDate: metadata.modificationDate
            )
        } catch is CancellationError {
            return nil
        } catch {
            return CachedEstimate(estimate: .unavailable, modificationDate: nil)
        }
    }

    private nonisolated static func readMetadata(path: String) async throws -> AgentContextFileMetadataSnapshot {
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let values = try URL(fileURLWithPath: path).resourceValues(forKeys: [
                .contentModificationDateKey,
                .fileSizeKey,
                .isRegularFileKey
            ])
            return AgentContextFileMetadataSnapshot(
                byteCount: values.fileSize.map(Int64.init),
                modificationDate: values.contentModificationDate,
                isRegularFile: values.isRegularFile == true
            )
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func cacheKey(for request: AgentContextFileSizeEstimateRequest) -> CacheKey {
        CacheKey(
            rootID: request.file.rootID,
            fileID: request.file.id,
            standardizedFullPath: request.file.standardizedFullPath,
            rootGeneration: request.rootGeneration
        )
    }

    private static func hasOneGenerationPerRoot(_ requests: [AgentContextFileSizeEstimateRequest]) -> Bool {
        Dictionary(grouping: requests, by: { $0.file.rootID }).values.allSatisfy { rootRequests in
            Set(rootRequests.map(\.rootGeneration)).count == 1
        }
    }
}

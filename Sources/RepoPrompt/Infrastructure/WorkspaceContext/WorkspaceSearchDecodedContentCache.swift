import Foundation

struct WorkspaceSearchContentCacheKey: Hashable {
    let rootID: UUID
    let fileID: UUID
    let standardizedRelativePath: String
}

struct WorkspaceSearchContentInvalidationBatch {
    private(set) var maximumEpochsByKey: [WorkspaceSearchContentCacheKey: UInt64] = [:]

    var isEmpty: Bool {
        maximumEpochsByKey.isEmpty
    }

    var count: Int {
        maximumEpochsByKey.count
    }

    mutating func record(_ key: WorkspaceSearchContentCacheKey, through invalidationEpoch: UInt64) {
        maximumEpochsByKey[key] = max(maximumEpochsByKey[key] ?? 0, invalidationEpoch)
    }

    func maximumEpoch(for key: WorkspaceSearchContentCacheKey) -> UInt64? {
        maximumEpochsByKey[key]
    }
}

struct WorkspaceSearchDecodedContentEntry {
    let content: String?
    let modificationDate: Date
    let fingerprint: FileContentFingerprint
    let revision: UInt64
}

actor WorkspaceSearchDecodedContentCache {
    #if DEBUG
        struct Snapshot: Equatable {
            let entryCount: Int
            let activeFlightCount: Int
            let waiterCount: Int
            let estimatedCost: Int
            let hitCount: Int
            let loadCount: Int
            let joinCount: Int
            let cancellationCount: Int
            let acceptedLoadCount: Int
            let latestRevision: UInt64
        }
    #endif

    private struct FlightKey: Hashable {
        let cacheKey: WorkspaceSearchContentCacheKey
        let fingerprint: FileContentFingerprint
        let invalidationEpoch: UInt64
    }

    private struct CachedEntry {
        let value: WorkspaceSearchDecodedContentEntry
        let invalidationEpoch: UInt64
        let cost: Int
        var accessOrdinal: UInt64
    }

    private struct Flight {
        let id: UUID
        let task: Task<ValidatedFileContentSnapshot, Error>
        var waiters: [UUID: CheckedContinuation<WorkspaceSearchDecodedContentEntry?, Error>]
        var publishable: Bool
    }

    private let maxEntryCount: Int
    private let maxEstimatedCost: Int
    private var entries: [WorkspaceSearchContentCacheKey: CachedEntry] = [:]
    private var flights: [FlightKey: Flight] = [:]
    private var flightKeyByWaiterID: [UUID: FlightKey] = [:]
    private var estimatedCost = 0
    private var nextAccessOrdinal: UInt64 = 0
    private var nextRevision: UInt64 = 0
    #if DEBUG
        private var hitCount = 0
        private var loadCount = 0
        private var joinCount = 0
        private var cancellationCount = 0
        private var acceptedLoadCount = 0
    #endif

    init(maxEntryCount: Int = 4096, maxEstimatedCost: Int = 128 * 1024 * 1024) {
        precondition(maxEntryCount > 0)
        precondition(maxEstimatedCost > 0)
        self.maxEntryCount = maxEntryCount
        self.maxEstimatedCost = maxEstimatedCost
    }

    func cachedSnapshot(
        for key: WorkspaceSearchContentCacheKey,
        invalidationEpoch: UInt64
    ) -> WorkspaceSearchDecodedContentEntry? {
        guard var cached = entries[key],
              cached.invalidationEpoch == invalidationEpoch
        else {
            return nil
        }
        nextAccessOrdinal &+= 1
        cached.accessOrdinal = nextAccessOrdinal
        entries[key] = cached
        #if DEBUG
            hitCount += 1
        #endif
        return cached.value
    }

    func snapshot(
        for key: WorkspaceSearchContentCacheKey,
        fingerprint: FileContentFingerprint,
        invalidationEpoch: UInt64,
        loader: @escaping @Sendable () async throws -> ValidatedFileContentSnapshot
    ) async throws -> WorkspaceSearchDecodedContentEntry? {
        try Task.checkCancellation()
        if var cached = entries[key],
           cached.value.fingerprint == fingerprint,
           cached.invalidationEpoch == invalidationEpoch
        {
            nextAccessOrdinal &+= 1
            cached.accessOrdinal = nextAccessOrdinal
            entries[key] = cached
            #if DEBUG
                hitCount += 1
            #endif
            return cached.value
        }
        removeEntry(for: key)

        let flightKey = FlightKey(
            cacheKey: key,
            fingerprint: fingerprint,
            invalidationEpoch: invalidationEpoch
        )
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enqueue(
                    waiterID: waiterID,
                    flightKey: flightKey,
                    continuation: continuation,
                    loader: loader
                )
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterID) }
        }
    }

    func invalidate(_ key: WorkspaceSearchContentCacheKey, through invalidationEpoch: UInt64) {
        var batch = WorkspaceSearchContentInvalidationBatch()
        batch.record(key, through: invalidationEpoch)
        invalidate(batch)
    }

    func invalidate(_ batch: WorkspaceSearchContentInvalidationBatch) {
        guard !batch.isEmpty else { return }
        for (key, invalidationEpoch) in batch.maximumEpochsByKey {
            if let entry = entries[key], entry.invalidationEpoch <= invalidationEpoch {
                removeEntry(for: key)
            }
        }
        markFlightsNonPublishable { flightKey in
            guard let invalidationEpoch = batch.maximumEpoch(for: flightKey.cacheKey) else { return false }
            return flightKey.invalidationEpoch <= invalidationEpoch
        }
    }

    func invalidate(rootID: UUID) {
        let keys = entries.keys.filter { $0.rootID == rootID }
        for key in keys {
            removeEntry(for: key)
        }
        markFlightsNonPublishable { $0.cacheKey.rootID == rootID }
    }

    func clear() {
        entries.removeAll(keepingCapacity: true)
        estimatedCost = 0
        markFlightsNonPublishable { _ in true }
    }

    #if DEBUG
        func snapshotForTesting() -> Snapshot {
            Snapshot(
                entryCount: entries.count,
                activeFlightCount: flights.count,
                waiterCount: flights.values.reduce(0) { $0 + $1.waiters.count },
                estimatedCost: estimatedCost,
                hitCount: hitCount,
                loadCount: loadCount,
                joinCount: joinCount,
                cancellationCount: cancellationCount,
                acceptedLoadCount: acceptedLoadCount,
                latestRevision: nextRevision
            )
        }
    #endif

    private func enqueue(
        waiterID: UUID,
        flightKey: FlightKey,
        continuation: CheckedContinuation<WorkspaceSearchDecodedContentEntry?, Error>,
        loader: @escaping @Sendable () async throws -> ValidatedFileContentSnapshot
    ) {
        if Task.isCancelled {
            continuation.resume(throwing: CancellationError())
            return
        }
        if var flight = flights[flightKey] {
            flight.waiters[waiterID] = continuation
            flights[flightKey] = flight
            flightKeyByWaiterID[waiterID] = flightKey
            #if DEBUG
                joinCount += 1
            #endif
            return
        }

        let flightID = UUID()
        let task = Task(priority: Task.currentPriority) {
            try await loader()
        }
        flights[flightKey] = Flight(
            id: flightID,
            task: task,
            waiters: [waiterID: continuation],
            publishable: true
        )
        flightKeyByWaiterID[waiterID] = flightKey
        #if DEBUG
            loadCount += 1
        #endif
        Task { [weak self] in
            let result: Result<ValidatedFileContentSnapshot, Error>
            do {
                result = try await .success(task.value)
            } catch {
                result = .failure(error)
            }
            await self?.complete(flightKey: flightKey, flightID: flightID, result: result)
        }
    }

    private func cancelWaiter(id waiterID: UUID) {
        guard let flightKey = flightKeyByWaiterID.removeValue(forKey: waiterID),
              var flight = flights[flightKey],
              let continuation = flight.waiters.removeValue(forKey: waiterID)
        else { return }
        #if DEBUG
            cancellationCount += 1
        #endif
        continuation.resume(throwing: CancellationError())
        if flight.waiters.isEmpty {
            flight.task.cancel()
            flights.removeValue(forKey: flightKey)
        } else {
            flights[flightKey] = flight
        }
    }

    private func complete(
        flightKey: FlightKey,
        flightID: UUID,
        result: Result<ValidatedFileContentSnapshot, Error>
    ) {
        guard let flight = flights[flightKey], flight.id == flightID else { return }
        flights.removeValue(forKey: flightKey)
        for waiterID in flight.waiters.keys {
            flightKeyByWaiterID.removeValue(forKey: waiterID)
        }

        switch result {
        case let .success(loaded):
            guard loaded.fingerprint == flightKey.fingerprint, flight.publishable else {
                for continuation in flight.waiters.values {
                    continuation.resume(returning: nil)
                }
                return
            }
            nextRevision &+= 1
            nextAccessOrdinal &+= 1
            let value = WorkspaceSearchDecodedContentEntry(
                content: loaded.content,
                modificationDate: loaded.modificationDate,
                fingerprint: loaded.fingerprint,
                revision: nextRevision
            )
            let cached = CachedEntry(
                value: value,
                invalidationEpoch: flightKey.invalidationEpoch,
                cost: loaded.estimatedDecodedCost,
                accessOrdinal: nextAccessOrdinal
            )
            insert(cached, for: flightKey.cacheKey)
            #if DEBUG
                acceptedLoadCount += 1
            #endif
            for continuation in flight.waiters.values {
                continuation.resume(returning: value)
            }
        case let .failure(error):
            for continuation in flight.waiters.values {
                continuation.resume(throwing: error)
            }
        }
    }

    private func insert(_ entry: CachedEntry, for key: WorkspaceSearchContentCacheKey) {
        removeEntry(for: key)
        entries[key] = entry
        estimatedCost += entry.cost
        trimToBudget()
    }

    private func removeEntry(for key: WorkspaceSearchContentCacheKey) {
        guard let removed = entries.removeValue(forKey: key) else { return }
        estimatedCost = max(0, estimatedCost - removed.cost)
    }

    private func trimToBudget() {
        guard entries.count > maxEntryCount || estimatedCost > maxEstimatedCost else { return }
        let targetEntryCount = max(0, maxEntryCount - max(1, maxEntryCount / 10))
        let targetEstimatedCost = max(0, maxEstimatedCost - max(1, maxEstimatedCost / 10))
        let evictionOrder = entries
            .map { (key: $0.key, accessOrdinal: $0.value.accessOrdinal) }
            .sorted { lhs, rhs in lhs.accessOrdinal < rhs.accessOrdinal }
        for candidate in evictionOrder {
            guard entries.count > targetEntryCount || estimatedCost > targetEstimatedCost else { break }
            removeEntry(for: candidate.key)
        }
    }

    private func markFlightsNonPublishable(where predicate: (FlightKey) -> Bool) {
        for key in flights.keys where predicate(key) {
            guard var flight = flights[key] else { continue }
            flight.publishable = false
            flights[key] = flight
        }
    }
}

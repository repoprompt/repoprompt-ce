import Foundation

struct WorkspaceInteractiveReadCacheKey: Hashable {
    let rootID: UUID
    let rootLifetimeID: UUID
    let fileID: UUID
    let standardizedRelativePath: String

    var searchContentKey: WorkspaceSearchContentCacheKey {
        WorkspaceSearchContentCacheKey(
            rootID: rootID,
            fileID: fileID,
            standardizedRelativePath: standardizedRelativePath
        )
    }
}

struct WorkspaceInteractiveReadPreparedContent: Equatable {
    let linesWithEndings: [String]

    var totalLines: Int {
        linesWithEndings.count
    }

    var estimatedCost: Int {
        linesWithEndings.reduce(into: linesWithEndings.count * MemoryLayout<String>.stride) { cost, line in
            cost += line.utf8.count + line.utf16.count * MemoryLayout<UInt16>.stride
        }
    }
}

struct WorkspaceInteractiveReadSlice: Equatable {
    let content: String
    let totalLines: Int
    let firstLine: Int
    let lastLine: Int
    let returnedLineCount: Int
    let startExceededFileLength: Bool
}

enum WorkspaceInteractiveReadRangeError: Error, Equatable {
    case limitWithNegativeStart
    case zeroStart
}

enum WorkspaceInteractiveReadProcessor {
    static func prepareOffActor(_ content: String) async -> WorkspaceInteractiveReadPreparedContent {
        let priority = Task.currentPriority
        return await Task.detached(priority: priority) {
            prepare(content)
        }.value
    }

    static func sliceOffActor(
        _ prepared: WorkspaceInteractiveReadPreparedContent,
        startLine1Based: Int?,
        lineCount: Int?
    ) async throws -> WorkspaceInteractiveReadSlice {
        let priority = Task.currentPriority
        return try await Task.detached(priority: priority) {
            try slice(prepared, startLine1Based: startLine1Based, lineCount: lineCount)
        }.value
    }

    static func prepare(_ content: String) -> WorkspaceInteractiveReadPreparedContent {
        WorkspaceInteractiveReadPreparedContent(
            linesWithEndings: String.splitContentPreservingAllLineEndings(content).map { pair in
                pair.line + pair.ending
            }
        )
    }

    static func slice(
        _ prepared: WorkspaceInteractiveReadPreparedContent,
        startLine1Based: Int?,
        lineCount: Int?
    ) throws -> WorkspaceInteractiveReadSlice {
        if let startLine1Based {
            if startLine1Based < 0, lineCount != nil {
                throw WorkspaceInteractiveReadRangeError.limitWithNegativeStart
            }
            if startLine1Based == 0 {
                throw WorkspaceInteractiveReadRangeError.zeroStart
            }
        }

        let total = prepared.totalLines
        let first: Int
        let lastExclusive: Int
        if let startLine1Based, startLine1Based < 0 {
            first = max(0, total - abs(startLine1Based))
            lastExclusive = total
        } else {
            let start = max(0, (startLine1Based ?? 1) - 1)
            first = start
            lastExclusive = if let lineCount, lineCount >= 0 {
                min(total, start + lineCount)
            } else {
                total
            }
        }

        guard first < total || total == 0 else {
            return WorkspaceInteractiveReadSlice(
                content: "",
                totalLines: total,
                firstLine: max(1, first + 1),
                lastLine: total,
                returnedLineCount: 0,
                startExceededFileLength: true
            )
        }

        let content = total == 0
            ? ""
            : prepared.linesWithEndings[first ..< lastExclusive].joined()
        let shownFirst = total == 0 ? 0 : first + 1
        let shownLast = total == 0 ? 0 : lastExclusive
        return WorkspaceInteractiveReadSlice(
            content: content,
            totalLines: total,
            firstLine: shownFirst,
            lastLine: shownLast,
            returnedLineCount: max(0, shownLast - shownFirst + (shownLast == 0 ? 0 : 1)),
            startExceededFileLength: false
        )
    }
}

struct WorkspaceInteractiveReadCacheLookup {
    let preparedContent: WorkspaceInteractiveReadPreparedContent?
    let cacheHit: Bool
}

struct WorkspaceInteractiveReadSnapshot {
    let preparedContent: WorkspaceInteractiveReadPreparedContent
    let cacheHit: Bool
}

actor WorkspaceInteractiveReadCache {
    #if DEBUG
        struct Snapshot: Equatable {
            let entryCount: Int
            let activeFlightCount: Int
            let waiterCount: Int
            let estimatedCost: Int
            let hitCount: Int
            let preparationCount: Int
            let joinCount: Int
            let cancellationCount: Int
            let acceptedPreparationCount: Int
        }
    #endif

    private struct FlightKey: Hashable {
        let cacheKey: WorkspaceInteractiveReadCacheKey
        let fingerprint: FileContentFingerprint
        let invalidationEpoch: UInt64
    }

    private struct CachedEntry {
        let preparedContent: WorkspaceInteractiveReadPreparedContent?
        let fingerprint: FileContentFingerprint
        let invalidationEpoch: UInt64
        let cost: Int
        var accessOrdinal: UInt64
    }

    private struct Flight {
        let id: UUID
        let task: Task<WorkspaceInteractiveReadPreparedContent?, Error>
        var waiters: [UUID: CheckedContinuation<WorkspaceInteractiveReadCacheLookup, Error>]
        var publishable: Bool
    }

    private let maxEntryCount: Int
    private let maxEstimatedCost: Int
    private var entries: [WorkspaceInteractiveReadCacheKey: CachedEntry] = [:]
    private var flights: [FlightKey: Flight] = [:]
    private var flightKeyByWaiterID: [UUID: FlightKey] = [:]
    private var estimatedCost = 0
    private var nextAccessOrdinal: UInt64 = 0
    #if DEBUG
        private var hitCount = 0
        private var preparationCount = 0
        private var joinCount = 0
        private var cancellationCount = 0
        private var acceptedPreparationCount = 0
    #endif

    init(maxEntryCount: Int = 512, maxEstimatedCost: Int = 64 * 1024 * 1024) {
        precondition(maxEntryCount > 0)
        precondition(maxEstimatedCost > 0)
        self.maxEntryCount = maxEntryCount
        self.maxEstimatedCost = maxEstimatedCost
    }

    func snapshot(
        for key: WorkspaceInteractiveReadCacheKey,
        fingerprint: FileContentFingerprint,
        invalidationEpoch: UInt64,
        loader: @escaping @Sendable () async throws -> WorkspaceInteractiveReadPreparedContent?
    ) async throws -> WorkspaceInteractiveReadCacheLookup {
        try Task.checkCancellation()
        if var cached = entries[key],
           cached.fingerprint == fingerprint,
           cached.invalidationEpoch == invalidationEpoch
        {
            nextAccessOrdinal &+= 1
            cached.accessOrdinal = nextAccessOrdinal
            entries[key] = cached
            #if DEBUG
                hitCount += 1
            #endif
            return WorkspaceInteractiveReadCacheLookup(
                preparedContent: cached.preparedContent,
                cacheHit: true
            )
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

    func invalidate(_ batch: WorkspaceSearchContentInvalidationBatch) {
        guard !batch.isEmpty else { return }
        let invalidatedKeys = entries.keys.filter {
            batch.maximumEpoch(for: $0.searchContentKey) != nil
        }
        for key in invalidatedKeys {
            guard let invalidationEpoch = batch.maximumEpoch(for: key.searchContentKey),
                  let entry = entries[key],
                  entry.invalidationEpoch <= invalidationEpoch
            else { continue }
            removeEntry(for: key)
        }
        markFlightsNonPublishable { flightKey in
            guard let invalidationEpoch = batch.maximumEpoch(for: flightKey.cacheKey.searchContentKey) else {
                return false
            }
            return flightKey.invalidationEpoch <= invalidationEpoch
        }
    }

    func invalidate(_ key: WorkspaceSearchContentCacheKey, through invalidationEpoch: UInt64) {
        var batch = WorkspaceSearchContentInvalidationBatch()
        batch.record(key, through: invalidationEpoch)
        invalidate(batch)
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
                preparationCount: preparationCount,
                joinCount: joinCount,
                cancellationCount: cancellationCount,
                acceptedPreparationCount: acceptedPreparationCount
            )
        }
    #endif

    private func enqueue(
        waiterID: UUID,
        flightKey: FlightKey,
        continuation: CheckedContinuation<WorkspaceInteractiveReadCacheLookup, Error>,
        loader: @escaping @Sendable () async throws -> WorkspaceInteractiveReadPreparedContent?
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
            preparationCount += 1
        #endif
        Task { [weak self] in
            let result: Result<WorkspaceInteractiveReadPreparedContent?, Error>
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
        result: Result<WorkspaceInteractiveReadPreparedContent?, Error>
    ) {
        guard let flight = flights[flightKey], flight.id == flightID else { return }
        flights.removeValue(forKey: flightKey)
        for waiterID in flight.waiters.keys {
            flightKeyByWaiterID.removeValue(forKey: waiterID)
        }

        switch result {
        case let .success(preparedContent):
            guard flight.publishable else {
                for continuation in flight.waiters.values {
                    continuation.resume(returning: WorkspaceInteractiveReadCacheLookup(
                        preparedContent: nil,
                        cacheHit: false
                    ))
                }
                return
            }
            nextAccessOrdinal &+= 1
            let entry = CachedEntry(
                preparedContent: preparedContent,
                fingerprint: flightKey.fingerprint,
                invalidationEpoch: flightKey.invalidationEpoch,
                cost: max(1, preparedContent?.estimatedCost ?? 0),
                accessOrdinal: nextAccessOrdinal
            )
            insert(entry, for: flightKey.cacheKey)
            #if DEBUG
                acceptedPreparationCount += 1
            #endif
            for continuation in flight.waiters.values {
                continuation.resume(returning: WorkspaceInteractiveReadCacheLookup(
                    preparedContent: preparedContent,
                    cacheHit: false
                ))
            }
        case let .failure(error):
            for continuation in flight.waiters.values {
                continuation.resume(throwing: error)
            }
        }
    }

    private func insert(_ entry: CachedEntry, for key: WorkspaceInteractiveReadCacheKey) {
        removeEntry(for: key)
        entries[key] = entry
        estimatedCost += entry.cost
        trimToBudget()
    }

    private func removeEntry(for key: WorkspaceInteractiveReadCacheKey) {
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

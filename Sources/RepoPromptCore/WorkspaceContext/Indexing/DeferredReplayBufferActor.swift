import Foundation

package protocol DeltaReplayPreparing: Actor {
    func prepare(
        rootKey: String,
        deltas: [FileSystemDelta],
        chunkSize: Int
    ) async -> PreparedFileSystemReplayBatch
}

private struct ImmediatePreparedIngressReservation: Equatable {
    let id: UInt64
    let rootKey: String
}

package struct PreparedImmediateReplay {
    fileprivate let reservation: ImmediatePreparedIngressReservation
    package let rootGeneration: UInt64
    package let sourceDeltas: [FileSystemDelta]
    package let preparedBatch: PreparedFileSystemReplayBatch
    package let routingVersion: UInt64

    package var rootKey: String {
        reservation.rootKey
    }
}

package enum DeferredReplayIngressResult {
    case preparedImmediate(PreparedImmediateReplay)
    case queued
    case overflowRequiresRefresh(rootKey: String)
    case droppedWhileOverflowed(rootKey: String)
    case droppedStaleGeneration(rootKey: String)
}

package struct DeferredReplayPendingWorkSnapshot: Equatable {
    package let pendingRootCount: Int
    package let pendingDeltaCount: Int
    let overflowedRootCount: Int
}

#if DEBUG
    package struct DeferredReplayBufferDiagnostics: Equatable {
        let pendingRootCount: Int
        let pendingDeltaCount: Int
        let overflowedRootCount: Int
        let routingVersion: UInt64
        let immediatePreparedIngressInFlight: Bool
        package let immediateIngressCount: UInt64
        package let deferredIngressCount: UInt64
        let overflowIngressCount: UInt64
        package let preparedDrainCount: UInt64
    }
#endif

package actor DeferredReplayBufferActor {
    private static let defaultImmediateReplayChunkSize = 100

    private let maxPendingDeltasPerRoot: Int
    private let preparationActor: any DeltaReplayPreparing
    private var pendingDeltasByRoot: [String: [FileSystemDelta]] = [:]
    private var overflowedRoots: Set<String> = []
    private var activeRootGenerations: [String: UInt64] = [:]
    private var isWindowFocused = true
    private var isReplayActive = false
    private var routingVersion: UInt64 = 0
    private var immediateReplayChunkSizeOverride: Int?
    private var immediatePreparedIngressReservation: ImmediatePreparedIngressReservation?
    private var nextImmediatePreparedIngressReservationID: UInt64 = 0

    #if DEBUG
        private var immediateIngressCount: UInt64 = 0
        private var deferredIngressCount: UInt64 = 0
        private var overflowIngressCount: UInt64 = 0
        private var preparedDrainCount: UInt64 = 0
    #endif

    package init(
        maxPendingDeltasPerRoot: Int,
        preparationActor: any DeltaReplayPreparing = DeltaReplayPreparationActor()
    ) {
        self.maxPendingDeltasPerRoot = max(maxPendingDeltasPerRoot, 1)
        self.preparationActor = preparationActor
    }

    func updateRoutingState(
        isWindowFocused: Bool,
        isReplayActive: Bool,
        routingVersion incomingRoutingVersion: UInt64
    ) {
        guard incomingRoutingVersion >= routingVersion else { return }
        self.isWindowFocused = isWindowFocused
        self.isReplayActive = isReplayActive
        routingVersion = incomingRoutingVersion
    }

    func updateImmediateReplayChunkSizeOverride(_ chunkSize: Int?) {
        if let chunkSize {
            immediateReplayChunkSizeOverride = max(chunkSize, 1)
        } else {
            immediateReplayChunkSizeOverride = nil
        }
    }

    func registerActiveRootGeneration(_ generation: UInt64, forRootKey rootKey: String) {
        activeRootGenerations[rootKey] = generation
        clearBufferedState(forRootKey: rootKey)
    }

    func unregisterActiveRootGeneration(forRootKey rootKey: String) {
        activeRootGenerations.removeValue(forKey: rootKey)
        clearBufferedState(forRootKey: rootKey)
    }

    func ingestLiveDeltas(
        _ deltas: [FileSystemDelta],
        forRootKey rootKey: String,
        rootGeneration: UInt64
    ) async -> DeferredReplayIngressResult {
        guard activeRootGenerations[rootKey] == rootGeneration else {
            return .droppedStaleGeneration(rootKey: rootKey)
        }
        return await routeIngress(deltas, forRootKey: rootKey, rootGeneration: rootGeneration)
    }

    func ingestLiveDeltas(
        _ deltas: [FileSystemDelta],
        forRootKey rootKey: String
    ) async -> DeferredReplayIngressResult {
        await routeIngress(deltas, forRootKey: rootKey, rootGeneration: nil)
    }

    private func routeIngress(
        _ deltas: [FileSystemDelta],
        forRootKey rootKey: String,
        rootGeneration: UInt64?
    ) async -> DeferredReplayIngressResult {
        guard !deltas.isEmpty else { return .queued }
        if overflowedRoots.contains(rootKey) {
            #if DEBUG
                overflowIngressCount &+= 1
            #endif
            return .droppedWhileOverflowed(rootKey: rootKey)
        }
        let hasBufferedWork = !pendingDeltasByRoot.isEmpty
        let canPrepareImmediate = isWindowFocused
            && !isReplayActive
            && !hasBufferedWork
            && immediatePreparedIngressReservation == nil
        guard canPrepareImmediate else {
            return enqueueDeferredDeltas(deltas, forRootKey: rootKey)
        }
        let reservation = reserveImmediatePreparedIngress(forRootKey: rootKey)

        let preparedBatch = await preparationActor.prepare(
            rootKey: rootKey,
            deltas: deltas,
            chunkSize: max(immediateReplayChunkSizeOverride ?? Self.defaultImmediateReplayChunkSize, 1)
        )
        if let rootGeneration,
           activeRootGenerations[rootKey] != rootGeneration
        {
            releaseImmediatePreparedIngressReservation(reservation)
            return .droppedStaleGeneration(rootKey: rootKey)
        }
        guard immediatePreparedIngressReservation == reservation else {
            return .queued
        }
        guard !preparedBatch.chunks.isEmpty else {
            releaseImmediatePreparedIngressReservation(reservation)
            return .queued
        }
        #if DEBUG
            immediateIngressCount &+= 1
        #endif
        return .preparedImmediate(
            PreparedImmediateReplay(
                reservation: reservation,
                rootGeneration: rootGeneration ?? activeRootGenerations[rootKey] ?? 0,
                sourceDeltas: deltas,
                preparedBatch: preparedBatch,
                routingVersion: routingVersion
            )
        )
    }

    func finishPreparedImmediateIngress(_ immediateReplay: PreparedImmediateReplay) {
        releaseImmediatePreparedIngressReservation(immediateReplay.reservation)
    }

    func enqueueDeferredDeltas(
        _ deltas: [FileSystemDelta],
        forRootKey rootKey: String
    ) -> DeferredReplayIngressResult {
        guard !deltas.isEmpty else { return .queued }
        if overflowedRoots.contains(rootKey) {
            #if DEBUG
                overflowIngressCount &+= 1
            #endif
            return .droppedWhileOverflowed(rootKey: rootKey)
        }
        pendingDeltasByRoot[rootKey, default: []].append(contentsOf: deltas)
        if let pendingCount = pendingDeltasByRoot[rootKey]?.count,
           pendingCount > maxPendingDeltasPerRoot
        {
            pendingDeltasByRoot[rootKey] = nil
            overflowedRoots.insert(rootKey)
            #if DEBUG
                overflowIngressCount &+= 1
            #endif
            return .overflowRequiresRefresh(rootKey: rootKey)
        }
        #if DEBUG
            deferredIngressCount &+= 1
        #endif
        return .queued
    }

    func drainPreparedBatches(
        preferredRootOrder: [String],
        chunkSize: Int
    ) async -> [PreparedFileSystemReplayBatch] {
        guard !pendingDeltasByRoot.isEmpty else { return [] }
        var drained = pendingDeltasByRoot
        pendingDeltasByRoot.removeAll(keepingCapacity: true)
        let orderedRoots = orderedRootKeys(
            for: Set(drained.keys),
            preferredRootOrder: preferredRootOrder
        )
        var batches: [PreparedFileSystemReplayBatch] = []
        batches.reserveCapacity(orderedRoots.count)
        for rootKey in orderedRoots {
            guard let deltas = drained.removeValue(forKey: rootKey), !deltas.isEmpty else { continue }
            let prepared = await preparationActor.prepare(
                rootKey: rootKey,
                deltas: deltas,
                chunkSize: chunkSize
            )
            guard !prepared.chunks.isEmpty else { continue }
            batches.append(prepared)
        }
        #if DEBUG
            if !batches.isEmpty {
                preparedDrainCount &+= 1
            }
        #endif
        return batches
    }

    func clearRoot(_ rootKey: String) {
        clearBufferedState(forRootKey: rootKey)
    }

    func clearAll() {
        pendingDeltasByRoot.removeAll(keepingCapacity: false)
        overflowedRoots.removeAll(keepingCapacity: false)
        activeRootGenerations.removeAll(keepingCapacity: false)
        immediatePreparedIngressReservation = nil
    }

    func hasPendingWork() -> Bool {
        !pendingDeltasByRoot.isEmpty
    }

    func pendingDeltaCount(forRootKey rootKey: String) -> Int {
        pendingDeltasByRoot[rootKey]?.count ?? 0
    }

    func pendingWorkSnapshot() -> DeferredReplayPendingWorkSnapshot {
        DeferredReplayPendingWorkSnapshot(
            pendingRootCount: pendingDeltasByRoot.count,
            pendingDeltaCount: pendingDeltasByRoot.values.reduce(0) { $0 + $1.count },
            overflowedRootCount: overflowedRoots.count
        )
    }

    #if DEBUG
        func diagnosticsSnapshot() -> DeferredReplayBufferDiagnostics {
            let snapshot = pendingWorkSnapshot()
            return DeferredReplayBufferDiagnostics(
                pendingRootCount: snapshot.pendingRootCount,
                pendingDeltaCount: snapshot.pendingDeltaCount,
                overflowedRootCount: snapshot.overflowedRootCount,
                routingVersion: routingVersion,
                immediatePreparedIngressInFlight: immediatePreparedIngressReservation != nil,
                immediateIngressCount: immediateIngressCount,
                deferredIngressCount: deferredIngressCount,
                overflowIngressCount: overflowIngressCount,
                preparedDrainCount: preparedDrainCount
            )
        }
    #endif

    private func clearBufferedState(forRootKey rootKey: String) {
        pendingDeltasByRoot[rootKey] = nil
        overflowedRoots.remove(rootKey)
        if immediatePreparedIngressReservation?.rootKey == rootKey {
            immediatePreparedIngressReservation = nil
        }
    }

    private func reserveImmediatePreparedIngress(
        forRootKey rootKey: String
    ) -> ImmediatePreparedIngressReservation {
        nextImmediatePreparedIngressReservationID &+= 1
        let reservation = ImmediatePreparedIngressReservation(
            id: nextImmediatePreparedIngressReservationID,
            rootKey: rootKey
        )
        immediatePreparedIngressReservation = reservation
        return reservation
    }

    private func releaseImmediatePreparedIngressReservation(
        _ reservation: ImmediatePreparedIngressReservation
    ) {
        guard immediatePreparedIngressReservation == reservation else { return }
        immediatePreparedIngressReservation = nil
    }

    private func orderedRootKeys(
        for queuedRoots: Set<String>,
        preferredRootOrder: [String]
    ) -> [String] {
        var ordered: [String] = []
        ordered.reserveCapacity(queuedRoots.count)
        var seen: Set<String> = []
        for rootKey in preferredRootOrder where queuedRoots.contains(rootKey) {
            guard seen.insert(rootKey).inserted else { continue }
            ordered.append(rootKey)
        }
        for rootKey in queuedRoots.sorted() where seen.insert(rootKey).inserted {
            ordered.append(rootKey)
        }
        return ordered
    }
}

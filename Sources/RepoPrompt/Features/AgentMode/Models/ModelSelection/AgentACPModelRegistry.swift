import Foundation

final class AgentACPModelRegistry {
    static let shared = AgentACPModelRegistry()

    private let lock = NSLock()
    private var liveSnapshotsByProvider: [ACPProviderID: ACPDiscoveredSessionModels] = [:]
    private var liveSignaturesByProvider: [ACPProviderID: ACPDynamicProviderRecord] = [:]
    private var persistedSnapshotsByProvider: [ACPProviderID: ACPDiscoveredSessionModels] = [:]
    private var standardStoreWarmTask: Task<[ACPProviderID: ACPDiscoveredSessionModels], Never>?
    private var didWarmStandardStore = false
    private var standardStoreWarmGeneration: UInt64 = 0

    private init() {}

    @discardableResult
    func updateDiscoveredModels(
        _ snapshot: ACPDiscoveredSessionModels,
        for providerID: ACPProviderID
    ) -> Bool {
        guard providerID != .grok else {
            return false
        }
        guard let providerRecord = ACPDynamicModelStore.canonicalProviderRecord(
            from: snapshot,
            providerID: providerID
        ),
            let normalizedSnapshot = ACPDynamicModelStore.snapshot(from: providerRecord)
        else {
            return false
        }

        lock.lock()
        let didChange = liveSignaturesByProvider[providerID] != providerRecord
        if didChange {
            liveSnapshotsByProvider[providerID] = normalizedSnapshot
            liveSignaturesByProvider[providerID] = providerRecord
        }
        persistedSnapshotsByProvider[providerID] = normalizedSnapshot
        lock.unlock()

        guard didChange else { return false }
        ACPDynamicModelStore.save(normalizedSnapshot, for: providerID)
        return true
    }

    func currentSnapshot(for providerID: ACPProviderID) -> ACPDiscoveredSessionModels? {
        lock.lock()
        defer { lock.unlock() }
        return liveSnapshotsByProvider[providerID]
    }

    func resolvedSnapshot(for providerID: ACPProviderID) -> ACPDiscoveredSessionModels? {
        snapshotFromMemory(for: providerID)
    }

    func warmStandardStoreIfNeeded() async {
        let task: Task<[ACPProviderID: ACPDiscoveredSessionModels], Never>
        let generation: UInt64

        lock.lock()
        if didWarmStandardStore {
            lock.unlock()
            return
        }
        generation = standardStoreWarmGeneration
        if let existing = standardStoreWarmTask {
            task = existing
        } else {
            let newTask = Task.detached(priority: .utility) {
                ACPDynamicModelStore.loadAll()
            }
            standardStoreWarmTask = newTask
            task = newTask
        }
        lock.unlock()

        let loadedSnapshots = await task.value

        lock.lock()
        guard generation == standardStoreWarmGeneration else {
            lock.unlock()
            return
        }
        persistedSnapshotsByProvider = loadedSnapshots
        didWarmStandardStore = true
        standardStoreWarmTask = nil
        lock.unlock()
    }

    func resolvedSnapshotAfterWarmingStandardStore(
        for providerID: ACPProviderID
    ) async -> ACPDiscoveredSessionModels? {
        if let snapshot = snapshotFromMemory(for: providerID) {
            return snapshot
        }
        await warmStandardStoreIfNeeded()
        return snapshotFromMemory(for: providerID)
    }

    private func snapshotFromMemory(for providerID: ACPProviderID) -> ACPDiscoveredSessionModels? {
        lock.lock()
        defer { lock.unlock() }
        return liveSnapshotsByProvider[providerID] ?? persistedSnapshotsByProvider[providerID]
    }

    #if DEBUG
        @_spi(TestSupport)
        public func test_reset(providerID: ACPProviderID) {
            lock.lock()
            liveSnapshotsByProvider.removeValue(forKey: providerID)
            liveSignaturesByProvider.removeValue(forKey: providerID)
            persistedSnapshotsByProvider.removeValue(forKey: providerID)
            standardStoreWarmTask?.cancel()
            standardStoreWarmTask = nil
            didWarmStandardStore = false
            standardStoreWarmGeneration &+= 1
            lock.unlock()
            ACPDynamicModelStore.remove(providerID: providerID)
        }

        @_spi(TestSupport)
        public func test_clearMemoryPreservingStore(providerID: ACPProviderID) {
            lock.lock()
            liveSnapshotsByProvider.removeValue(forKey: providerID)
            liveSignaturesByProvider.removeValue(forKey: providerID)
            persistedSnapshotsByProvider.removeValue(forKey: providerID)
            standardStoreWarmTask?.cancel()
            standardStoreWarmTask = nil
            didWarmStandardStore = false
            standardStoreWarmGeneration &+= 1
            lock.unlock()
        }

        @_spi(TestSupport)
        public func test_warmStandardStore() async {
            await warmStandardStoreIfNeeded()
        }

        @_spi(TestSupport)
        public func test_snapshot(providerID: ACPProviderID) -> ACPDiscoveredSessionModels? {
            resolvedSnapshot(for: providerID)
        }
    #endif
}

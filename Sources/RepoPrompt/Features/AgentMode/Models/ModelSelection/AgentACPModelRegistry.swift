import Foundation
import RepoPromptSettingsCore

final class AgentACPModelRegistry {
    static let shared = AgentACPModelRegistry()

    private let lock = NSLock()
    private var liveSnapshotsByProvider: [ACPProviderID: ACPDiscoveredSessionModels] = [:]
    private var liveSignaturesByProvider: [ACPProviderID: ACPDynamicProviderRecord] = [:]
    private var persistedSnapshotsByProvider: [ACPProviderID: ACPDiscoveredSessionModels] = [:]
    // Derived from the complete effective snapshot, including labels and parameter choices.
    // Both values are replaced under `lock`; readers never perform derivation or store I/O.
    private var devinCatalogSnapshot: ACPDiscoveredSessionModels?
    private var devinCatalog = DevinModelCatalog(snapshot: nil)
    private var standardStoreWarmTask: Task<[ACPProviderID: ACPDiscoveredSessionModels], Never>?
    private var didWarmStandardStore = false
    private var standardStoreWarmGeneration: UInt64 = 0

    private init() {}

    @discardableResult
    func updateDiscoveredModels(
        _ snapshot: ACPDiscoveredSessionModels,
        for providerID: ACPProviderID
    ) -> Bool {
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
        if providerID == .devin { refreshDevinCatalogIfNeededLocked() }
        lock.unlock()

        guard didChange else { return false }
        invalidateAdvertisedModels(for: providerID)
        ACPDynamicModelStore.save(normalizedSnapshot, for: providerID)
        return true
    }

    private func invalidateAdvertisedModels(for providerID: ACPProviderID) {
        for agent in AgentProviderKind.allCases where agent.acpProviderID == providerID {
            AgentAdvertisedModelCatalog.shared.invalidate(agent)
        }
    }

    func currentSnapshot(for providerID: ACPProviderID) -> ACPDiscoveredSessionModels? {
        lock.lock()
        defer { lock.unlock() }
        return liveSnapshotsByProvider[providerID]
    }

    func resolvedSnapshot(for providerID: ACPProviderID) -> ACPDiscoveredSessionModels? {
        snapshotFromMemory(for: providerID)
    }

    func currentDevinCatalog() -> DevinModelCatalog {
        lock.withLock { devinCatalog }
    }

    /// Caller holds `lock`. Build and publication are atomic with snapshot mutation.
    private func refreshDevinCatalogIfNeededLocked() {
        let snapshot = liveSnapshotsByProvider[.devin] ?? persistedSnapshotsByProvider[.devin]
        guard snapshot != devinCatalogSnapshot else { return }
        devinCatalog = DevinModelCatalog(snapshot: snapshot)
        devinCatalogSnapshot = snapshot
    }

    func warmStandardStoreIfNeeded(beforeCompleting: (@Sendable () async -> Void)? = nil) async {
        let plan: StandardStoreWarmPlan? = lock.withLock {
            guard !didWarmStandardStore else { return nil }

            let task: Task<[ACPProviderID: ACPDiscoveredSessionModels], Never>
            if let existing = standardStoreWarmTask {
                task = existing
            } else {
                let newTask = Task.detached(priority: .utility) {
                    ACPDynamicModelStore.loadAll()
                }
                standardStoreWarmTask = newTask
                task = newTask
            }
            return StandardStoreWarmPlan(
                task: task,
                generation: standardStoreWarmGeneration
            )
        }

        guard let plan else { return }
        let loadedSnapshots = await plan.task.value
        // Per-call scheduling seam for the shared-task completion race regression.
        if let beforeCompleting { await beforeCompleting() }

        lock.withLock {
            guard !didWarmStandardStore, plan.generation == standardStoreWarmGeneration else { return }
            for providerID in loadedSnapshots.keys {
                invalidateAdvertisedModels(for: providerID)
            }
            persistedSnapshotsByProvider = loadedSnapshots
            refreshDevinCatalogIfNeededLocked()
            didWarmStandardStore = true
            standardStoreWarmTask = nil
        }
    }

    private struct StandardStoreWarmPlan {
        let task: Task<[ACPProviderID: ACPDiscoveredSessionModels], Never>
        let generation: UInt64
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
        public func test_reset(providerID: ACPProviderID, beforeClearingMemory: (() -> Void)? = nil) {
            invalidateAdvertisedModels(for: providerID)
            beforeClearingMemory?()
            lock.lock()
            liveSnapshotsByProvider.removeValue(forKey: providerID)
            liveSignaturesByProvider.removeValue(forKey: providerID)
            persistedSnapshotsByProvider.removeValue(forKey: providerID)
            if providerID == .devin { refreshDevinCatalogIfNeededLocked() }
            standardStoreWarmTask?.cancel()
            standardStoreWarmTask = nil
            didWarmStandardStore = false
            standardStoreWarmGeneration &+= 1
            lock.unlock()
            ACPDynamicModelStore.remove(providerID: providerID)
            // Fence producers that read the old snapshot after the first invalidation.
            invalidateAdvertisedModels(for: providerID)
        }

        @_spi(TestSupport)
        public func test_clearMemoryPreservingStore(providerID: ACPProviderID, beforeClearingMemory: (() -> Void)? = nil) {
            invalidateAdvertisedModels(for: providerID)
            beforeClearingMemory?()
            lock.lock()
            liveSnapshotsByProvider.removeValue(forKey: providerID)
            liveSignaturesByProvider.removeValue(forKey: providerID)
            persistedSnapshotsByProvider.removeValue(forKey: providerID)
            if providerID == .devin { refreshDevinCatalogIfNeededLocked() }
            standardStoreWarmTask?.cancel()
            standardStoreWarmTask = nil
            didWarmStandardStore = false
            standardStoreWarmGeneration &+= 1
            lock.unlock()
            // Fence producers that read the old snapshot after the first invalidation.
            invalidateAdvertisedModels(for: providerID)
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

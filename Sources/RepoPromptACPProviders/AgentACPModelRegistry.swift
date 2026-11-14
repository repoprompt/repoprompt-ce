import Foundation
import RepoPromptAIContracts

package final class AgentACPModelRegistry {
    package struct Dependencies {
        package let loadAll: @Sendable () -> [ACPProviderID: ACPDiscoveredSessionModels]
        package let load: (ACPProviderID) -> ACPDiscoveredSessionModels?
        package let save: (ACPDiscoveredSessionModels, ACPProviderID) -> Void
        package let remove: (ACPProviderID) -> Void
        /// Synchronous; must not re-enter this registry or wait for another thread to do so.
        package let invalidate: (AgentProviderKind) -> Void

        package init(
            loadAll: @escaping @Sendable () -> [ACPProviderID: ACPDiscoveredSessionModels],
            load: @escaping (ACPProviderID) -> ACPDiscoveredSessionModels?,
            save: @escaping (ACPDiscoveredSessionModels, ACPProviderID) -> Void,
            remove: @escaping (ACPProviderID) -> Void,
            invalidate: @escaping (AgentProviderKind) -> Void
        ) {
            self.loadAll = loadAll
            self.load = load
            self.save = save
            self.remove = remove
            self.invalidate = invalidate
        }
    }

    private let dependencies: Dependencies
    private let invalidationThreadKey = "AgentACPModelRegistry.invalidation.\(UUID().uuidString)"
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

    package init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    private func preconditionNotInvalidating() {
        precondition(
            Thread.current.threadDictionary[invalidationThreadKey] == nil,
            "AgentACPModelRegistry invalidator must not synchronously re-enter the same registry"
        )
    }

    @discardableResult
    package func updateDiscoveredModels(
        _ snapshot: ACPDiscoveredSessionModels,
        for providerID: ACPProviderID
    ) -> Bool {
        preconditionNotInvalidating()
        guard let providerRecord = ACPDynamicModelCanonicalization.canonicalProviderRecord(
            from: snapshot,
            providerID: providerID
        ),
            let normalizedSnapshot = ACPDynamicModelCanonicalization.snapshot(from: providerRecord)
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
        dependencies.save(normalizedSnapshot, providerID)
        return true
    }

    private func invalidateAdvertisedModels(for providerID: ACPProviderID) {
        for agent in AgentProviderKind.allCases where agent.acpProviderID == providerID {
            preconditionNotInvalidating()
            let threadState = Thread.current.threadDictionary
            threadState[invalidationThreadKey] = true
            defer { threadState.removeObject(forKey: invalidationThreadKey) }
            dependencies.invalidate(agent)
        }
    }

    package func currentSnapshot(for providerID: ACPProviderID) -> ACPDiscoveredSessionModels? {
        preconditionNotInvalidating()
        lock.lock()
        defer { lock.unlock() }
        return liveSnapshotsByProvider[providerID]
    }

    package func resolvedSnapshot(for providerID: ACPProviderID) -> ACPDiscoveredSessionModels? {
        preconditionNotInvalidating()
        return snapshotFromMemory(for: providerID)
    }

    package func currentDevinCatalog() -> DevinModelCatalog {
        preconditionNotInvalidating()
        return lock.withLock { devinCatalog }
    }

    /// Caller holds `lock`. Build and publication are atomic with snapshot mutation.
    private func refreshDevinCatalogIfNeededLocked() {
        let snapshot = liveSnapshotsByProvider[.devin] ?? persistedSnapshotsByProvider[.devin]
        guard snapshot != devinCatalogSnapshot else { return }
        devinCatalog = DevinModelCatalog(snapshot: snapshot)
        devinCatalogSnapshot = snapshot
    }

    package func warmStandardStoreIfNeeded(beforeCompleting: (@Sendable () async -> Void)? = nil) async {
        preconditionNotInvalidating()
        let plan: StandardStoreWarmPlan? = lock.withLock {
            guard !didWarmStandardStore else { return nil }

            let task: Task<[ACPProviderID: ACPDiscoveredSessionModels], Never>
            if let existing = standardStoreWarmTask {
                task = existing
            } else {
                let loadAll = dependencies.loadAll
                let newTask = Task.detached(priority: .utility) {
                    loadAll()
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

    /// Reads saved data when memory is empty, without installing it or changing warm state.
    package func resolvedSnapshotIncludingStandardStore(for providerID: ACPProviderID) -> ACPDiscoveredSessionModels? {
        preconditionNotInvalidating()
        return snapshotFromMemory(for: providerID) ?? dependencies.load(providerID)
    }

    package func resolvedSnapshotAfterWarmingStandardStore(
        for providerID: ACPProviderID
    ) async -> ACPDiscoveredSessionModels? {
        preconditionNotInvalidating()
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
        package func test_reset(providerID: ACPProviderID, beforeClearingMemory: (() -> Void)? = nil) {
            preconditionNotInvalidating()
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
            dependencies.remove(providerID)
            // Fence producers that read the old snapshot after the first invalidation.
            invalidateAdvertisedModels(for: providerID)
        }

        package func test_clearMemoryPreservingStore(providerID: ACPProviderID, beforeClearingMemory: (() -> Void)? = nil) {
            preconditionNotInvalidating()
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

        package func test_warmStandardStore() async {
            preconditionNotInvalidating()
            await warmStandardStoreIfNeeded()
        }

        package func test_snapshot(providerID: ACPProviderID) -> ACPDiscoveredSessionModels? {
            preconditionNotInvalidating()
            return resolvedSnapshot(for: providerID)
        }
    #endif
}

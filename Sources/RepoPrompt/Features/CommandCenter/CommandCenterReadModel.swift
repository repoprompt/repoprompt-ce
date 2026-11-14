import Combine
import Foundation
import RepoPromptDomainRuntime
import RepoPromptSettingsCore

/// App-catalog projection whose subscriptions and disk work exist only while Lookout is visible.
/// Events invalidate snapshots, including sequence gaps; no event is replayed into local truth.
@MainActor
final class CommandCenterReadModel: ObservableObject {
    @Published private(set) var snapshot = CommandCenterSnapshot()
    private let subscribe: () async -> DomainWorkspaceSnapshotSubscription
    private let readCatalog: () async -> DomainWorkspaceCatalogSnapshot
    private let census: AgentSessionStatusCensus
    private let isEnabled: @MainActor () -> Bool
    private var featureObservation: AnyCancellable?
    private var mayObserve: Bool {
        isActive && isEnabled()
    }

    private let loadInventory: @Sendable (UUID, URL, Int) async -> CommandCenterProjection.SavedInventory
    private var catalog: DomainWorkspaceCatalogSnapshot?
    private var live: [AgentSessionStatusCensus.Row] = []
    private var unwitnessed: [CommandCenterSessionRow.ID: AgentSessionStatusCensus.Row] = [:]
    private var saved: [UUID: CommandCenterProjection.SavedInventory] = [:]
    private var limits: [UUID: Int] = [:]
    private var inventoryReloads: Set<UUID> = []
    private var retiredRetry: Task<Void, Never>?
    private var inventoryTasks: [UUID: Task<Void, Never>] = [:]
    private var catalogTask: Task<Void, Never>?
    private var publishTask: Task<Void, Never>?
    private var catalogRefreshTask: Task<Void, Never>?
    private var subscriptionEnded = false
    private var catalogNeedsRefetch = false
    private var generation = UUID()
    private(set) var isActive = false

    init(
        subscribe: @escaping () async -> DomainWorkspaceSnapshotSubscription,
        readCatalog: @escaping () async -> DomainWorkspaceCatalogSnapshot,
        census: AgentSessionStatusCensus,
        loadInventory: (@Sendable (UUID, URL, Int) async -> CommandCenterProjection.SavedInventory)? = nil,
        isEnabled: @escaping @MainActor () -> Bool = { GlobalSettingsStore.shared.experimentalCommandCenter() },
        enabledChanges: AnyPublisher<Void, Never>? = nil
    ) {
        self.subscribe = subscribe
        self.readCatalog = readCatalog
        self.census = census
        self.isEnabled = isEnabled
        let inventoryReader = CommandCenterInventoryReader()
        self.loadInventory = loadInventory ?? { id, directory, limit in
            await inventoryReader.load(workspaceID: id, directory: directory, limit: limit)
        }
        // Typed scalar writes notify after storage. This preference observation owns no catalog or
        // session subscription; read admission also guards against off-state/in-flight callbacks.
        featureObservation = enabledChanges?.sink { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isActive, !self.isEnabled() else { return }
                self.stop()
            }
        }
    }

    static func appModel() -> CommandCenterReadModel {
        let store = AppDomainRuntimeComposition.shared.runtime.workspaceStore
        let settings = GlobalSettingsStore.shared
        return CommandCenterReadModel(
            subscribe: { await store.subscribe() }, readCatalog: { await store.snapshot() }, census: .appCensus(),
            isEnabled: { settings.experimentalCommandCenter() }, enabledChanges: settings.objectWillChange.eraseToAnyPublisher()
        )
    }

    func start() {
        guard isEnabled(), !isActive else { return }
        isActive = true
        generation = UUID()
        let expected = generation
        census.start { [weak self] rows in
            self?.installLive(rows)
        }
        beginCatalogSubscription(expected: expected)
    }

    private func installLive(_ rows: [AgentSessionStatusCensus.Row]) {
        guard mayObserve else { return }
        let ids = Set(rows.map { CommandCenterSessionRow.ID(workspaceID: $0.sample.candidate.workspaceID, sessionID: $0.sample.candidate.sessionID) })
        var retiredWorkspaces = Set<UUID>()
        for prior in live {
            let candidate = prior.sample.candidate
            let id = CommandCenterSessionRow.ID(workspaceID: candidate.workspaceID, sessionID: candidate.sessionID)
            if !ids.contains(id) {
                unwitnessed[id] = prior
                retiredWorkspaces.insert(candidate.workspaceID)
            }
        }
        unwitnessed = unwitnessed.filter { !ids.contains($0.key) }
        live = rows
        for id in retiredWorkspaces {
            loadSaved(workspaceID: id, force: true)
        }
        scheduleRetiredRetry()
        schedulePublication()
    }

    private func beginCatalogSubscription(expected: UUID) {
        subscriptionEnded = false
        catalogTask = Task { [weak self, subscribe] in
            guard let self, mayObserve, generation == expected, !Task.isCancelled else { return }
            let subscription = await subscribe()
            guard mayObserve, generation == expected, !Task.isCancelled else { return }
            install(subscription.snapshot)
            for await _ in subscription.events {
                guard !Task.isCancelled, mayObserve, generation == expected else { return }
                scheduleCatalogRefetch(expected: expected)
            }
            guard !Task.isCancelled, mayObserve, generation == expected else { return }
            subscriptionEnded = true
            schedulePublication()
        }
    }

    private func scheduleCatalogRefetch(expected: UUID) {
        guard mayObserve else { return }
        catalogNeedsRefetch = true
        guard catalogRefreshTask == nil else { return }
        catalogRefreshTask = Task { [weak self, readCatalog] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, !Task.isCancelled, mayObserve, generation == expected else { return }
                catalogNeedsRefetch = false
                // Always authoritative, including gaps. An invalidation during this actor hop
                // schedules another bounded read; it cannot be lost behind an older snapshot.
                let current = await readCatalog()
                guard !Task.isCancelled, mayObserve, generation == expected else { return }
                install(current)
                if !catalogNeedsRefetch { break }
            }
            guard let self, generation == expected else { return }
            catalogRefreshTask = nil
        }
    }

    func stop() {
        isActive = false
        generation = UUID()
        catalogTask?.cancel()
        catalogTask = nil
        publishTask?.cancel()
        publishTask = nil
        catalogRefreshTask?.cancel()
        catalogRefreshTask = nil
        subscriptionEnded = false
        catalogNeedsRefetch = false
        inventoryTasks.values.forEach { $0.cancel() }
        inventoryTasks.removeAll()
        inventoryReloads.removeAll()
        retiredRetry?.cancel()
        retiredRetry = nil
        census.stop()
        catalog = nil
        live = []
        unwitnessed.removeAll()
        saved.removeAll()
        limits.removeAll()
        snapshot = CommandCenterSnapshot()
    }

    private func install(_ current: DomainWorkspaceCatalogSnapshot) {
        guard mayObserve else { return }
        let old = catalog
        if let old, old.runtimeIdentity == current.runtimeIdentity,
           current.publicationSequence < old.publicationSequence { return }
        catalog = current
        let ids = Set(current.workspaces.map(\.document.workspaceID))
        for id in Array(inventoryTasks.keys) where !ids.contains(id) {
            inventoryTasks.removeValue(forKey: id)?.cancel()
        }
        saved = saved.filter { ids.contains($0.key) }
        limits = limits.filter { ids.contains($0.key) }
        // A changed storage location invalidates only that workspace's cached inventory.
        for workspace in current.workspaces {
            let id = workspace.document.workspaceID
            if let previous = old?.workspaces.first(where: { $0.document.workspaceID == id }),
               previous.document.fileURL != workspace.document.fileURL
            {
                inventoryTasks.removeValue(forKey: id)?.cancel()
                saved.removeValue(forKey: id)
                if limits[id] != nil { loadSaved(workspaceID: id, force: true) }
            }
        }
        // Initial inventory demand belongs to this feature model, not a SwiftUI onChange.
        // A cold subscription may already contain the entire catalog and emit no later events.
        for workspace in current.workspaces {
            let id = workspace.document.workspaceID
            let previous = old?.workspaces.first { $0.document.workspaceID == id }
            let changed = previous != nil && previous?.document.contentDigest != workspace.document.contentDigest
            if saved[id] == nil || changed { loadSaved(workspaceID: id, force: changed) }
        }
        schedulePublication()
    }

    /// Workspace expansion, Show more, or loss of an already-displayed live witness reads metadata. At most one load per
    /// expanded workspace per refresh; 100 rows/page, hard ceiling 1,000; no per-row tasks.
    func loadSaved(workspaceID: UUID, more: Bool = false, force: Bool = false) {
        guard mayObserve else { return }
        if inventoryTasks[workspaceID] != nil { if force { inventoryReloads.insert(workspaceID) }
            return
        }
        guard let workspace = catalog?.workspaces.first(where: { $0.document.workspaceID == workspaceID })
        else { return }
        if saved[workspaceID] != nil, !more, !force { return }
        let limit = more ? min((limits[workspaceID] ?? 100) + 100, 1000) : (limits[workspaceID] ?? 100)
        limits[workspaceID] = limit
        let directory = workspace.document.fileURL.deletingLastPathComponent()
        let expected = generation
        inventoryTasks[workspaceID] = Task { [weak self, loadInventory] in
            guard let self, !Task.isCancelled, mayObserve, generation == expected else { return }
            let result = await loadInventory(workspaceID, directory, limit)
            guard !Task.isCancelled, mayObserve, generation == expected,
                  catalog?.workspaces.first(where: { $0.document.workspaceID == workspaceID })?
                  .document.fileURL.deletingLastPathComponent() == directory
            else { return }
            inventoryTasks[workspaceID] = nil
            saved[workspaceID] = result
            let established = Set(result.entries.map(\.id))
            unwitnessed = unwitnessed.filter { $0.key.workspaceID != workspaceID || !established.contains($0.key.sessionID) }
            if inventoryReloads.remove(workspaceID) != nil { loadSaved(workspaceID: workspaceID, force: true) }
            scheduleRetiredRetry()
            schedulePublication()
        }
    }

    /// A coalesced index write may land after owner retirement. One demand-owned task retries
    /// affected WORKSPACES with bounded backoff; it never scans payloads or creates per-row work.
    private func scheduleRetiredRetry() {
        guard mayObserve, retiredRetry == nil, !unwitnessed.isEmpty else { return }
        let expected = generation
        retiredRetry = Task { [weak self] in
            var delay: UInt64 = 1
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled, mayObserve, generation == expected else { return }
                let known = Set(catalog?.workspaces.map(\.document.workspaceID) ?? [])
                let affected = Set(unwitnessed.keys.map(\.workspaceID)).intersection(known)
                if affected.isEmpty { break }
                for id in affected {
                    loadSaved(workspaceID: id, force: true)
                }
                delay = min(30, delay * 2)
            }
            if let self, generation == expected { retiredRetry = nil }
        }
    }

    func refresh() async {
        guard mayObserve else { return }
        let expected = generation
        let current = await readCatalog()
        guard mayObserve, generation == expected else { return }
        install(current)
        census.refresh()
        for id in Array(limits.keys) {
            loadSaved(workspaceID: id, force: true)
        }
        if subscriptionEnded { beginCatalogSubscription(expected: expected) }
    }

    private func schedulePublication() {
        guard mayObserve, publishTask == nil else { return }
        publishTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard let self, !Task.isCancelled, mayObserve else { return }
            publishTask = nil
            guard let catalog else { return }
            var next = CommandCenterProjection.build(catalog: catalog, live: live, saved: saved, limits: limits, unwitnessed: Array(unwitnessed.values))
            if subscriptionEnded { next.catalogCoverage = "Catalog subscription ended; press Refresh to reconnect" }
            if next != snapshot { snapshot = next }
        }
    }
}

import Foundation
import RepoPromptServicePersistence
import RepoPromptWorkspaceRuntimeCore

public struct DurabilityMaintenanceSnapshot: Codable, Hashable, Sendable {
    public let reconciliation: OwnedResourceReconciliationReport?
    public let archivedSegments: Int
    public let lastErrorCode: String?
    public let observedAt: Date

    private enum CodingKeys: String, CodingKey {
        case reconciliation, archivedSegments, lastErrorCode, observedAt
    }
}

public actor DurabilityOperationsService {
    private let store: SQLiteServiceStore
    private let reconciler: OwnedResourceReconciliationService
    private let retentionPolicy: EventRetentionPolicy
    private let interval: Duration
    private var task: Task<Void, Never>?
    private var latest: DurabilityMaintenanceSnapshot?

    public init(
        store: SQLiteServiceStore,
        reconciler: OwnedResourceReconciliationService,
        retentionPolicy: EventRetentionPolicy = .init(),
        interval: Duration = .seconds(300)
    ) {
        self.store = store
        self.reconciler = reconciler
        self.retentionPolicy = retentionPolicy
        self.interval = interval
    }

    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            _ = await self.runOnce()
            while !Task.isCancelled {
                try? await Task.sleep(for: self.interval)
                guard !Task.isCancelled else { break }
                _ = await self.runOnce()
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    public func snapshot() -> DurabilityMaintenanceSnapshot? {
        latest
    }

    @discardableResult
    public func runOnce(now: Date = Date()) async -> DurabilityMaintenanceSnapshot {
        let reconciliation = await reconciler.reconcile(now: now)
        var archivedSegments = 0
        var errorCode: String?
        do {
            while try await store.enforceEventRetention(policy: retentionPolicy, now: now) != nil {
                archivedSegments += 1
            }
        } catch {
            errorCode = "retention_or_reconciliation_failed"
        }
        if reconciliation.failed > 0 {
            errorCode = "retention_or_reconciliation_failed"
        }
        let snapshot = DurabilityMaintenanceSnapshot(
            reconciliation: reconciliation,
            archivedSegments: archivedSegments,
            lastErrorCode: errorCode,
            observedAt: now
        )
        latest = snapshot
        return snapshot
    }
}

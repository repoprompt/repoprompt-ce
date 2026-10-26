import Foundation
import os

/// Indexed reads use an actor-owned, read-only WAL connection. The writer is lock-owned so a
/// MainActor session owner can revalidate and durably accept a small metadata delta without an
/// executor hop. No connection, statement, decoder, or mutable core escapes its actor/lock owner.
package actor SessionCatalogStore {
    private nonisolated let connection: OSAllocatedUnfairLock<SessionCatalogConnection>
    private let reader: SessionCatalogConnection

    package init(databaseURL: URL) throws {
        connection = try OSAllocatedUnfairLock(uncheckedState: SessionCatalogConnection(databaseURL: databaseURL))
        reader = try SessionCatalogConnection(databaseURL: databaseURL, readOnly: true)
    }

    /// For reconciliation and already owner-accepted facts, never for cached authorization.
    package func commit(operationID: UUID, mutations: [SessionCatalogMutation]) throws -> SessionCatalogCommit {
        try connection.withLockUnchecked { try $0.commit(operationID: operationID, mutations: mutations) }
    }

    /// The owner calls this in its existing MainActor commit region, then applies its in-memory
    /// delta and targeted notification in that same region. Revalidation happens after acquiring
    /// the catalog lock, so lock contention cannot separate a live lease/generation check from
    /// durable acceptance. A denial or persistence error leaves every catalog fact unchanged.
    ///
    /// `revalidate` must only read the owner's live authority and maintained membership indexes:
    /// it must not re-enter this store, perform filesystem discovery, or publish an owner mutation.
    /// This catalog locates facts; the caller remains the authority and must fail closed.
    @MainActor
    package func commitFromOwner(
        operationID: UUID,
        mutations: [SessionCatalogMutation],
        revalidate: @MainActor () throws -> Void
    ) throws -> SessionCatalogCommit {
        try connection.withLockUnchecked { core in
            try Task.checkCancellation()
            try revalidate()
            return try core.commit(operationID: operationID, mutations: mutations)
        }
    }

    package func currentGeneration() throws -> Int64 {
        try reader.currentGeneration()
    }

    package func workspace(id: UUID) throws -> SessionCatalogWorkspace? {
        try reader.workspace(id: id)
    }

    package func workspaces(named name: String) throws -> [SessionCatalogWorkspace] {
        try reader.workspaces(named: name)
    }

    package func workspaces() throws -> [SessionCatalogWorkspace] {
        try reader.workspaces()
    }

    package func session(id: UUID) throws -> SessionCatalogRecord? {
        try reader.session(id: id)
    }

    package func children(of parentID: UUID) throws -> [SessionCatalogRecord] {
        try reader.children(of: parentID)
    }

    package func sessions(workspaceID: UUID? = nil, limit: Int = 100, after cursor: SessionCatalogCursor? = nil) throws -> SessionCatalogPage {
        try reader.sessions(workspaceID: workspaceID, limit: limit, after: cursor)
    }

    package func classify(path: String, signature: String, classification: String, reconciliationGeneration: Int64) throws {
        try connection.withLockUnchecked {
            try $0.classify(path: path, signature: signature, classification: classification, reconciliationGeneration: reconciliationGeneration)
        }
    }

    package func classification(path: String, signature: String) throws -> String? {
        try reader.classification(path: path, signature: signature)
    }

    package func reconciliation() throws -> SessionCatalogReconciliation? {
        try reader.reconciliation()
    }

    package func saveReconciliation(_ progress: SessionCatalogReconciliation, expectedGeneration: Int64?) throws {
        try connection.withLockUnchecked { try $0.saveReconciliation(progress, expectedGeneration: expectedGeneration) }
    }

    package func beginReconciliation(restart: Bool = false) throws -> SessionCatalogReconciliation {
        try connection.withLockUnchecked { try $0.beginReconciliation(restart: restart) }
    }

    package func applyReconciliationBatch(
        _ batch: SessionCatalogReconciliationBatch,
        expected: SessionCatalogReconciliation
    ) throws -> SessionCatalogReconciliationReceipt {
        try connection.withLockUnchecked { try $0.applyReconciliationBatch(batch, expected: expected) }
    }

    package func readCounters() -> SessionCatalogReadCounters {
        reader.readCounters()
    }

    package func resetReadCounters() {
        reader.resetReadCounters()
    }

    package func writeCounters() -> SessionCatalogReadCounters {
        connection.withLockUnchecked { $0.readCounters() }
    }

    package func resetWriteCounters() {
        connection.withLockUnchecked { $0.resetReadCounters() }
    }
}

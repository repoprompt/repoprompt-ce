import Foundation

/// Catalog facts locate sessions. They are never delegation/link/lifecycle authority.
package struct SessionCatalogWorkspace: Codable, Equatable {
    package let id: UUID
    package var name: String
    package var directory: URL
    package var revision: Int64
    package var coverage: SessionCatalogCoverage

    package init(id: UUID, name: String, directory: URL, revision: Int64 = 0, coverage: SessionCatalogCoverage = .pending) {
        self.id = id
        self.name = name
        self.directory = directory
        self.revision = revision
        self.coverage = coverage
    }
}

package enum SessionCatalogCoverage: String, Codable {
    case pending
    case complete
    case degraded
}

/// Owner-specific metadata is encoded, not hydrated from transcripts by discovery queries.
package struct SessionCatalogRecord: Codable, Equatable {
    package let id: UUID
    package var workspaceID: UUID
    package var tabID: UUID?
    package var filename: String
    package var name: String
    package var activityAt: Date
    package var parentID: UUID?
    package var creatorID: UUID?
    package var organizationalParentID: UUID?
    package var archived: Bool
    package var metadata: Data
    package var revision: Int64

    package var effectiveParentID: UUID? {
        organizationalParentID ?? parentID ?? creatorID
    }

    package init(
        id: UUID, workspaceID: UUID, tabID: UUID? = nil, filename: String,
        name: String, activityAt: Date, parentID: UUID? = nil, creatorID: UUID? = nil,
        organizationalParentID: UUID? = nil, archived: Bool = false, metadata: Data,
        revision: Int64 = 0
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.filename = filename
        self.name = name
        self.activityAt = activityAt
        self.parentID = parentID
        self.creatorID = creatorID
        self.organizationalParentID = organizationalParentID
        self.archived = archived
        self.metadata = metadata
        self.revision = revision
    }
}

/// Persisted compare-and-swap is also the reconciliation fence: imports cannot replace newer writes.
package enum SessionCatalogExpectedRevision: Codable, Equatable {
    case absent
    case revision(Int64)
}

package enum SessionCatalogMutation: Codable, Equatable {
    case workspace(SessionCatalogWorkspace, expected: SessionCatalogExpectedRevision)
    case session(SessionCatalogRecord, expected: SessionCatalogExpectedRevision)
    case deleteSession(UUID, expected: SessionCatalogExpectedRevision)
    case deleteWorkspace(UUID, expected: SessionCatalogExpectedRevision)
    case coverage(workspaceID: UUID?, state: SessionCatalogCoverage)
}

package struct SessionCatalogCommit: Equatable {
    package let generation: Int64
    package let replayed: Bool
}

package struct SessionCatalogCursor {
    package let generation: Int64
    package let workspaceID: UUID?
    package let activityAt: Date
    package let sessionID: UUID
}

package struct SessionCatalogPage {
    package let generation: Int64
    package let coverage: SessionCatalogCoverage
    package let totalKnown: Int
    package let records: [SessionCatalogRecord]
    package let nextCursor: SessionCatalogCursor?

    package var hasMore: Bool {
        nextCursor != nil
    }

    package var authoritativeEmpty: Bool {
        coverage == .complete && totalKnown == 0
    }
}

/// Resumable worker state, independent of catalog commit generation. The worker owns the cursor
/// interpretation; queries only expose progress and never drive or await the worker.
package struct SessionCatalogReconciliation: Codable, Equatable {
    package let generation: Int64
    package var phase: String
    package var cursor: String?
    package var processed: Int64
    package var failed: Int64
    package var finished: Bool

    package init(generation: Int64, phase: String, cursor: String? = nil, processed: Int64 = 0, failed: Int64 = 0, finished: Bool = false) {
        self.generation = generation
        self.phase = phase
        self.cursor = cursor
        self.processed = processed
        self.failed = failed
        self.finished = finished
    }
}

package enum SessionCatalogError: Error, Equatable {
    case database(Int32)
    case filesystem(Int32)
    case futureSchema(Int)
    case corruptSchema
    case invalidRecord
    case unknownWorkspace
    case revisionConflict
    case deletedIdentity
    case operationConflict
    case staleGeneration
}

package struct SessionCatalogReadCounters: Equatable {
    package var statements = 0
    package var returnedRows = 0
}

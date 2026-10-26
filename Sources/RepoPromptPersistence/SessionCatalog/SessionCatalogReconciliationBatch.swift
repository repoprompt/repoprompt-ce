import Foundation

/// Discovery of storage is confined to the background source. A batch carries bounded metadata,
/// never transcripts or a permission grant. The catalog rechecks the durable job checkpoint.
package struct SessionCatalogReconciliationBatch {
    package struct Directory {
        package let path: String
        package let signature: String
        package let classification: String

        package init(path: String, signature: String, classification: String) {
            self.path = path
            self.signature = signature
            self.classification = classification
        }
    }

    /// A file belongs to the workspace location that was read before filesystem IO. A concurrent
    /// workspace move must not import an old-directory payload into the owner's new location.
    package struct Session {
        package let record: SessionCatalogRecord
        package let expectedWorkspaceRevision: SessionCatalogExpectedRevision

        package init(record: SessionCatalogRecord, expectedWorkspaceRevision: SessionCatalogExpectedRevision) {
            self.record = record
            self.expectedWorkspaceRevision = expectedWorkspaceRevision
        }
    }

    /// Completeness belongs to the exact owner revision that was read before filesystem IO.
    package struct Coverage {
        package let workspaceID: UUID
        package let expectedRevision: SessionCatalogExpectedRevision
        package let state: SessionCatalogCoverage

        package init(workspaceID: UUID, expectedRevision: SessionCatalogExpectedRevision, state: SessionCatalogCoverage) {
            self.workspaceID = workspaceID
            self.expectedRevision = expectedRevision
            self.state = state
        }
    }

    package let next: SessionCatalogReconciliation
    package let workspaces: [SessionCatalogWorkspace]
    package let sessions: [Session]
    package let directories: [Directory]
    package let coverage: [Coverage]

    package static let maximumItems = 64

    package var itemCount: Int {
        workspaces.count + sessions.count + directories.count + coverage.count
    }

    package init(
        next: SessionCatalogReconciliation,
        workspaces: [SessionCatalogWorkspace] = [],
        sessions: [Session] = [],
        directories: [Directory] = [],
        coverage: [Coverage] = []
    ) {
        self.next = next
        self.workspaces = workspaces
        self.sessions = sessions
        self.directories = directories
        self.coverage = coverage
    }
}

package struct SessionCatalogReconciliationReceipt {
    package let catalogGeneration: Int64
    package let importedWorkspaces: Int
    package let importedSessions: Int
    package let skippedOwnerFacts: Int
    package let progress: SessionCatalogReconciliation
}

/// Only the migration/drift worker owns this interface. A query never creates or awaits a source.
package protocol SessionCatalogReconciliationSource: Sendable {
    func nextBatch(after progress: SessionCatalogReconciliation, maximumItems: Int) async throws -> SessionCatalogReconciliationBatch
}

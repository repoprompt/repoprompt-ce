import Foundation

package struct RepoPromptCoreSessionConstructionKey {
    fileprivate init() {}
}

package struct RepoPromptCoreSessionOwnershipLease: Hashable {
    package let sessionID: WorkspaceSessionID
    package let leaseID: UUID

    fileprivate init(sessionID: WorkspaceSessionID, leaseID: UUID = UUID()) {
        self.sessionID = sessionID
        self.leaseID = leaseID
    }
}

package struct RepoPromptCoreSessionOwnershipSnapshot: Equatable {
    package let sessionID: WorkspaceSessionID
    package let selectedBackendCount: Int
    package let lifecycleOwnerCount: Int
    package let writerCount: Int
    package let revisionAuthorityCount: Int
    package let commandIngressCount: Int
    package let releaseCount: Int
    package let isReleased: Bool
}

package actor WorkspaceSelectionRevisionAllocator: WorkspaceSelectionRevisionAllocating {
    private var nextRevision: UInt64

    package init(firstRevision: UInt64 = 1) {
        nextRevision = max(1, firstRevision)
    }

    package func allocate() -> UInt64 {
        let revision = nextRevision
        nextRevision &+= 1
        if nextRevision == 0 { nextRevision = 1 }
        return revision
    }
}

package struct RepoPromptCoreSessionRegistration {
    package let sessionID: WorkspaceSessionID
    package let handle: RepoPromptCoreSessionHandle

    package init(sessionID: WorkspaceSessionID, handle: RepoPromptCoreSessionHandle) {
        self.sessionID = sessionID
        self.handle = handle
    }
}

package actor RepoPromptCoreHost {
    private struct OwnershipRecord {
        let lease: RepoPromptCoreSessionOwnershipLease
        var releaseCount = 0
        var isReleased = false

        var snapshot: RepoPromptCoreSessionOwnershipSnapshot {
            RepoPromptCoreSessionOwnershipSnapshot(
                sessionID: lease.sessionID,
                selectedBackendCount: 1,
                lifecycleOwnerCount: 1,
                writerCount: 1,
                revisionAuthorityCount: 1,
                commandIngressCount: 1,
                releaseCount: releaseCount,
                isReleased: isReleased
            )
        }
    }

    private let revisionAllocator: WorkspaceSelectionRevisionAllocator
    private let persistenceCoordinator: WorkspaceSessionPersistenceCoordinator
    private var sessions: [WorkspaceSessionID: RepoPromptCoreSession] = [:]
    private var ownershipRecords: [WorkspaceSessionID: OwnershipRecord] = [:]

    package init(
        persistenceIO: WorkspaceSessionPersistenceIO = .foundation,
        firstSelectionRevision: UInt64 = 1
    ) {
        revisionAllocator = WorkspaceSelectionRevisionAllocator(firstRevision: firstSelectionRevision)
        persistenceCoordinator = WorkspaceSessionPersistenceCoordinator(io: persistenceIO)
    }

    package func createSession(
        id: WorkspaceSessionID = WorkspaceSessionID(),
        dependencies: RepoPromptCoreSessionDependencies
    ) -> RepoPromptCoreSessionRegistration? {
        guard sessions[id] == nil, ownershipRecords[id] == nil else { return nil }
        let ownershipLease = RepoPromptCoreSessionOwnershipLease(sessionID: id)
        ownershipRecords[id] = OwnershipRecord(lease: ownershipLease)
        let session = RepoPromptCoreSession(
            constructionKey: RepoPromptCoreSessionConstructionKey(),
            ownershipLease: ownershipLease,
            releaseOwnership: { [weak self] lease in
                await self?.releaseOwnership(lease)
            },
            sessionID: id,
            revisionAllocator: revisionAllocator,
            persistence: persistenceCoordinator,
            dependencies: dependencies
        )
        sessions[id] = session
        return RepoPromptCoreSessionRegistration(sessionID: id, handle: session.makeHandle())
    }

    package func hydrateSession(_ id: WorkspaceSessionID) async -> WorkspaceSessionHydrationResult {
        guard let session = sessions[id] else {
            return .failed(WorkspaceSessionFailure("session is not registered"))
        }
        return await session.hydrate()
    }

    package func acknowledgeFirstSnapshotApplied(
        sessionID: WorkspaceSessionID,
        sequence: UInt64
    ) async -> WorkspaceSessionActivationResult {
        guard let session = sessions[sessionID] else {
            return .notReady(.closed)
        }
        return await session.acknowledgeFirstSnapshotApplied(sequence: sequence)
    }

    package func removeSession(_ id: WorkspaceSessionID) async {
        guard let session = sessions.removeValue(forKey: id) else { return }
        await session.shutdown()
    }

    package func shutdown() async {
        let current = sessions.values
        sessions.removeAll()
        for session in current {
            await session.shutdown()
        }
    }

    package func registeredSessionCount() -> Int {
        sessions.count
    }

    package func ownershipSnapshot(
        sessionID: WorkspaceSessionID
    ) -> RepoPromptCoreSessionOwnershipSnapshot? {
        ownershipRecords[sessionID]?.snapshot
    }

    private func releaseOwnership(_ lease: RepoPromptCoreSessionOwnershipLease) {
        guard var record = ownershipRecords[lease.sessionID], record.lease == lease else { return }
        guard !record.isReleased else {
            precondition(record.releaseCount == 1, "workspace session ownership released more than once")
            return
        }
        record.releaseCount = 1
        record.isReleased = true
        ownershipRecords[lease.sessionID] = record
        sessions.removeValue(forKey: lease.sessionID)
    }
}

import Foundation

/// Per-session serialization of writer-owned placement flushes. Only the durable write is queued;
/// the admitted writer applies in-memory placement synchronously before scheduling it.
@MainActor
enum DelegationPlacementWriteQueue {
    private static var tails: [UUID: (token: UUID, task: Task<Void, Never>)] = [:]

    /// Schedules `body` after every earlier write for `sessionID`. Scheduling itself is synchronous,
    /// so writes run in the order their placements were applied (last applied, last written).
    static func schedule(
        _ sessionID: UUID,
        _ body: @escaping @MainActor () async throws -> Void
    ) -> Task<Void, Error> {
        let previous = tails[sessionID]?.task
        let work = Task { @MainActor () throws in
            await previous?.value
            try await body()
        }
        let token = UUID()
        let tail = Task { @MainActor in
            _ = await work.result
            if tails[sessionID]?.token == token { tails.removeValue(forKey: sessionID) }
        }
        tails[sessionID] = (token, tail)
        return work
    }
}

enum DelegationPlacementPersistenceError: LocalizedError {
    case ownerChanged
    case superseded
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .ownerChanged: "The session owner changed before placement persistence completed."
        case .superseded: "A newer placement superseded this change before persistence completed."
        case let .saveFailed(message): message
        }
    }
}

/// A placement already applied in memory (the owner-validated index entry and the live tab), so
/// membership checks see it at once. Production commits always carry the owning durable write;
/// scheduling an ordinary debounced save is not a persistence acknowledgement.
struct DelegationPlacementCommit {
    let pendingWrite: Task<Void, Error>?

    /// Waits for the durable write, if one was queued.
    func persisted() async throws {
        try await pendingWrite?.value
    }
}

/// The placement facts an `agent_run start` into an existing tab is decided against.
struct DelegationSpawnTargetPlacement: Equatable {
    var organizationalParentID: UUID?
    var parentSessionID: UUID?
    var createdByOverseerSessionID: UUID?
    var delegationScopeID: UUID?

    /// Organizational parent, else spawn parent, else lane creator (the projector's tree placement).
    var effectiveOrganizationalParentID: UUID? {
        organizationalParentID ?? parentSessionID ?? createdByOverseerSessionID
    }

    /// Auto-join may stamp only a session it does not move: no placement of its own, no scope stamp,
    /// and no spawn parent or lane creator other than `creatorSessionID`.
    func admitsStamp(by creatorSessionID: UUID) -> Bool {
        organizationalParentID == nil
            && delegationScopeID == nil
            && (parentSessionID == nil || parentSessionID == creatorSessionID)
            && (createdByOverseerSessionID == nil || createdByOverseerSessionID == creatorSessionID)
    }
}

/// What an `agent_run start` targets, for scope admission. `agent_run` itself writes the creator as
/// spawn parent onto an existing session that has none, so the classification follows what that
/// write would do to the session's tree placement.
enum DelegationSpawnTarget: Equatable {
    /// A new tab or a tab with no bound session: a new session joins under the creator.
    case newSession
    /// An existing session with no tree placement at all (no organizational parent, spawn parent,
    /// or lane creator): it and its organizational subtree join under the creator.
    case unplacedSession(UUID)
    /// An existing session whose tree placement the start leaves unchanged (an organizational parent,
    /// which wins; a write-once spawn parent; or a lane of this same creator). Never stamped.
    case placedSession
    /// A lane of another creator with no spawn parent: the spawn-parent write would move it (and its
    /// subtree) from its lane creator to this creator, so it is refused whenever that changes the
    /// membership of a live scope.
    case otherCreatorsLane(UUID)

    static func classify(
        sessionID: UUID?,
        placement: DelegationSpawnTargetPlacement?,
        creatorSessionID: UUID?
    ) -> DelegationSpawnTarget {
        guard let sessionID else { return .newSession }
        guard let placement, placement.effectiveOrganizationalParentID != nil else { return .unplacedSession(sessionID) }
        if placement.organizationalParentID == nil, placement.parentSessionID == nil,
           let laneCreator = placement.createdByOverseerSessionID, laneCreator != creatorSessionID
        {
            return .otherCreatorsLane(sessionID)
        }
        return .placedSession
    }
}

extension AgentSessionRuntimeStore.Command {
    /// The caller's final authorization and this mutation are one synchronous region. Index
    /// projections are published before returning, but only this writer changes the live payload.
    func commitDelegationPlacement(
        organizationalParentID: UUID?,
        delegationScopeID: UUID?,
        project: (AgentSessionRuntimeStore.Writer) -> Void
    ) throws -> DelegationPlacementCommit {
        guard isCurrent else { throw DelegationPlacementPersistenceError.ownerChanged }
        let session = writer.session
        if session.organizationalParentID != organizationalParentID || session.delegationScopeID != delegationScopeID {
            session.organizationalParentID = organizationalParentID
            session.delegationScopeID = delegationScopeID
            session.isDirty = true
            writer.scope.persistence.scheduleSave(for: session)
        }
        project(writer)
        let writer = writer
        let write = DelegationPlacementWriteQueue.schedule(identity.sessionID) {
            let requireCurrentPlacement = {
                // Retirement closes admission, not a committed writer's required flush.
                guard writer.isCurrent else { throw DelegationPlacementPersistenceError.ownerChanged }
                guard session.organizationalParentID == organizationalParentID,
                      session.delegationScopeID == delegationScopeID
                else { throw DelegationPlacementPersistenceError.superseded }
            }
            try requireCurrentPlacement()
            if case let .failure(failure) = await writer.scope.persistence.flushSaveRequired(
                writer: writer
            ) {
                throw DelegationPlacementPersistenceError.saveFailed(failure.message)
            }
            try requireCurrentPlacement()
        }
        return DelegationPlacementCommit(pendingWrite: write)
    }
}

extension AgentModeViewModel {
    /// Compatibility entry for local creation callers; saved admin targets prepare a writer before
    /// entering their final synchronous decision region. There is no unloaded-file rewrite fallback.
    func commitDelegationPlacement(
        sessionID: UUID,
        organizationalParentID: UUID?,
        delegationScopeID: UUID?
    ) throws -> DelegationPlacementCommit? {
        guard let command = try runtimeCommand(sessionID: sessionID) else { return nil }
        return try command.commitDelegationPlacement(
            organizationalParentID: organizationalParentID, delegationScopeID: delegationScopeID
        ) { writer in
            WindowStatesManager.shared.projectDelegationPlacement(writer)
            // An isolated composition may not be registered as a window yet.
            if var entry = ownerValidatedSessionIndex[sessionID] {
                entry.organizationalParentID = organizationalParentID
                entry.delegationScopeID = delegationScopeID
                sessionIndexStore.applyLocalUpsert(entry)
            }
        }
    }

    /// Placement facts of a session this window owns: the live tab when there is one, else the
    /// owner-validated index entry; `nil` when neither is known.
    func delegationSpawnTargetPlacement(sessionID: UUID) -> DelegationSpawnTargetPlacement? {
        let live = try? authoritativeLiveSession(for: sessionID)
        let entry = ownerValidatedSessionIndex[sessionID]
        guard live != nil || entry != nil else { return nil }
        // Either source holding a fact is enough: a placement is never inferred away.
        return DelegationSpawnTargetPlacement(
            organizationalParentID: live?.organizationalParentID ?? entry?.organizationalParentID,
            parentSessionID: live?.parentSessionID ?? entry?.parentSessionID,
            createdByOverseerSessionID: live?.createdByOverseerSessionID ?? entry?.createdByOverseerSessionID,
            delegationScopeID: live?.delegationScopeID ?? entry?.delegationScopeID
        )
    }

    /// What an `agent_run start` into `tabID` by `creatorSessionID` would target, for scope admission:
    /// a new session, an existing session with no tree placement (it joins under the creator), an
    /// already-placed session that stays put (adopted, spawned, or the creator's own lane), or another
    /// creator's lane that the start would move.
    func delegationSpawnTarget(tabID: UUID?, creatorSessionID: UUID?) -> DelegationSpawnTarget {
        guard let tabID, let sessionID = boundSessionID(for: tabID) else { return .newSession }
        return DelegationSpawnTarget.classify(
            sessionID: sessionID,
            placement: delegationSpawnTargetPlacement(sessionID: sessionID),
            creatorSessionID: creatorSessionID
        )
    }

    /// Stages an auto-join stamp on the exact creating runtime, without publishing an incomplete
    /// payload through the ordinary placement writer. The creator's configured first save owns
    /// persistence; membership still sees the in-memory placement immediately.
    func stageCreationDelegationPlacementIfUnplaced(
        creationHandle: AgentSessionCreationHandle,
        sessionID: UUID,
        creatorSessionID: UUID,
        delegationScopeID: UUID
    ) throws -> Bool {
        let session = creationHandle.session
        try requireSessionConfigurationAdmission(session, creationHandle: creationHandle)
        guard session.activeAgentSessionID == sessionID else {
            throw DelegationPlacementPersistenceError.ownerChanged
        }
        let placement = DelegationSpawnTargetPlacement(
            organizationalParentID: session.organizationalParentID,
            parentSessionID: session.parentSessionID,
            createdByOverseerSessionID: session.createdByOverseerSessionID,
            delegationScopeID: session.delegationScopeID
        )
        guard placement.admitsStamp(by: creatorSessionID) else { return false }
        session.organizationalParentID = creatorSessionID
        session.delegationScopeID = delegationScopeID
        session.isDirty = true
        if var entry = ownerValidatedSessionIndex[sessionID] {
            entry.organizationalParentID = creatorSessionID
            entry.delegationScopeID = delegationScopeID
            sessionIndexStore.applyLocalUpsert(entry)
        }
        return true
    }

    /// Auto-join stamp for a session created (or taken) under `creatorSessionID`'s scope. Never
    /// overwrites an existing organizational parent or scope stamp, and never moves a session whose
    /// spawn parent or lane creator is someone else.
    ///
    /// - Returns: `nil` when the session is not owned here or must not be stamped.
    func stampDelegationPlacementIfUnplaced(
        sessionID: UUID,
        creatorSessionID: UUID,
        delegationScopeID: UUID
    ) throws -> DelegationPlacementCommit? {
        guard let placement = delegationSpawnTargetPlacement(sessionID: sessionID),
              placement.admitsStamp(by: creatorSessionID)
        else { return nil }
        return try commitDelegationPlacement(
            sessionID: sessionID,
            organizationalParentID: creatorSessionID,
            delegationScopeID: delegationScopeID
        )
    }
}

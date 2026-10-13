import Foundation

/// Per-session serialization of placement-only disk rewrites, so two administrations of the same
/// session can never interleave their load/rewrite of an unloaded session file. Only the durable
/// write is queued; the in-memory placement is applied synchronously before it is scheduled.
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
    case workspaceUnavailable
    case ownerChanged
    case superseded
    case sessionFileMissing
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .workspaceUnavailable: "The placement's owning workspace is unavailable."
        case .ownerChanged: "The session owner changed before placement persistence completed."
        case .superseded: "A newer placement superseded this change before persistence completed."
        case .sessionFileMissing: "The session file is missing; the placement was not persisted."
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

extension AgentModeViewModel {
    /// Applies organizational placement synchronously, with no suspension: the owner-validated index
    /// entry (which feeds `.tree` scope membership immediately) and the live tab when there is one —
    /// even before the session has an index entry, as for a just-created `agent_run`/`agent_manage`
    /// target. A caller that re-validates placement and then commits in one synchronous region can
    /// therefore never race another placement change (two cross re-parents, two adopts at a limit).
    ///
    /// Persistence follows through the owning required-save path for a live tab, or a queued
    /// placement-only rewrite for a session with no live tab. Spawn provenance is never written here.
    ///
    /// - Returns: `nil` when this window owns neither an index entry nor a live tab for the session.
    func commitDelegationPlacement(
        sessionID: UUID,
        organizationalParentID: UUID?,
        delegationScopeID: UUID?
    ) throws -> DelegationPlacementCommit? {
        let live = try authoritativeLiveSession(for: sessionID)
        let entry = ownerValidatedSessionIndex[sessionID]
        guard live != nil || entry != nil else { return nil }
        guard let workspace = workspaceManager?.activeWorkspace else {
            throw DelegationPlacementPersistenceError.workspaceUnavailable
        }
        if var entry, entry.organizationalParentID != organizationalParentID || entry.delegationScopeID != delegationScopeID {
            entry.organizationalParentID = organizationalParentID
            entry.delegationScopeID = delegationScopeID
            sessionIndexStore.applyLocalUpsert(entry)
        }
        if let session = live {
            if session.organizationalParentID != organizationalParentID || session.delegationScopeID != delegationScopeID {
                session.organizationalParentID = organizationalParentID
                session.delegationScopeID = delegationScopeID
                session.isDirty = true
                scheduleSave(for: session.tabID)
            }
            let binding = session.persistentSessionBindingIdentity
            let write = DelegationPlacementWriteQueue.schedule(sessionID) { [self, session] in
                // The queue may start after another placement or a workspace switch. Flush only
                // the exact owner that committed this change, never a successor on the same tab.
                let requireCurrentPlacement = {
                    guard self.workspaceManager?.activeWorkspaceID == workspace.id,
                          self.sessions[session.tabID] === session,
                          session.activeAgentSessionID == sessionID,
                          session.persistentSessionBindingIdentity == binding
                    else { throw DelegationPlacementPersistenceError.ownerChanged }
                    guard session.organizationalParentID == organizationalParentID,
                          session.delegationScopeID == delegationScopeID
                    else { throw DelegationPlacementPersistenceError.superseded }
                }
                try requireCurrentPlacement()
                if case let .failure(failure) = await flushSaveRequired(for: session.tabID, workspaceID: workspace.id) {
                    throw DelegationPlacementPersistenceError.saveFailed(failure.message)
                }
                try requireCurrentPlacement()
            }
            return DelegationPlacementCommit(pendingWrite: write)
        }
        let write = DelegationPlacementWriteQueue.schedule(sessionID) {
            try await AgentSessionDataService.shared.updateDelegationPlacement(
                id: sessionID,
                organizationalParentID: organizationalParentID,
                delegationScopeID: delegationScopeID,
                for: workspace
            )
        }
        return DelegationPlacementCommit(pendingWrite: write)
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

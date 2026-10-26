import Foundation
import RepoPromptDomainRuntime

/// Creation admission: the delegated accounting behind `agent_run start`, `agent_manage
/// create_session`, `agent_session_link create_lane`, and the shared guardrail evaluation reused by
/// `session_admin fork` and `worktree_create`. `DelegationSpawnAdmission` forwards here.
///
/// Restricted mode applies, unchanged: the guardrails of every live scope the new session will count
/// toward (each with its ancestors), joining-subtree counting, scope-anchor and scope-move refusals,
/// creator placement proofs, reservations, and auto-join stamping. Full access waives all of it
/// (`sessionQuota`, `worktreeQuota`, `creatorPlacementForAccounting`, `scopeAnchorMoveRestriction`,
/// `otherScopeMembershipMove`). Structural checks for re-parenting another creator's lane
/// (`organizationalStructure`) hold in both modes.
extension OverseerAuthorizationEngine {
    enum GuardrailScopeResolution {
        case scopes([DomainDelegationScopeRecord])
        case creatorPlacementUnresolved(String)
    }

    /// Live scopes whose guardrails bound a session or worktree created by `creator` (and placed
    /// under it), each evaluated together with its ancestor chain:
    /// - `.tree`: every scope the creator is a member of, so a worker is bounded like its overseer;
    /// - `.workspace`: only for delegated work — the creator is the scope's grantee or a session
    ///   stamped with that scope, or descends organizationally from one. Unrelated sessions that merely
    ///   live in the workspace are never limited by someone else's delegation;
    /// - `.allSessions`: never (it cannot hold `spawn`, and every session is its member).
    ///
    /// The one decision behind `admitCreation` and the fork/worktree guardrails, so the creator
    /// placement proof is demanded for exactly the scopes that could count the creation.
    func creationGuardrailScopes(
        forCreator creator: UUID,
        projector: any DelegationMembershipProjector
    ) -> GuardrailScopeResolution {
        guard let scopes, !waives(.sessionQuota) else { return .scopes([]) }
        // A full-access grant has no guardrails to count against, so it is not a delegation that can
        // bound or block a creation.
        let liveScopes = scopes.allLiveScopes().filter { !$0.grant.unrestricted }
        // These creation surfaces already have their own caller authority. With no delegation
        // anywhere, missing scope provenance cannot hide a limit or revoke that authority.
        guard !liveScopes.isEmpty else { return .scopes([]) }
        // Ambiguous ancestry can hide the scope that should count this spawn. It must never become the
        // absence of delegation and consequently an unscoped admission (`creatorPlacementForAccounting`).
        if let reason = creatorPlacementFailure(creator, projector: projector) {
            return .creatorPlacementUnresolved(reason)
        }
        return .scopes(liveScopes.filter { record in
            switch record.grant.kind {
            case .session, .allSessions:
                false
            case .workspace:
                isDelegated(creator, under: record, projector: projector)
                    && isMember(creator, ofChainFrom: record, projector: projector)
            case .tree:
                isMember(creator, ofChainFrom: record, projector: projector)
            }
        })
    }

    /// Evaluates `operation`'s guardrails (`.session` or `.worktree` use) for every record and its
    /// chain, with in-flight reservations. Returns the first denial, or the scope IDs to reserve.
    func evaluateCreationGuardrails(
        _ records: [DomainDelegationScopeRecord],
        creator: UUID,
        operation: DomainAgentSessionTargetOperation,
        joining: DelegationSpawnAdmission.Joining = .init(),
        projector: any DelegationMembershipProjector
    ) -> (denial: DomainDelegationScopeDenial?, scopeIDs: Set<UUID>) {
        // Full access: nothing is counted or reserved, even for records a caller passes in directly.
        let waived = operation.scopeGuardrailUse == .worktree ? waives(.worktreeQuota) : waives(.sessionQuota)
        guard let scopes, !waived else { return (nil, []) }
        var scopeIDs: Set<UUID> = []
        for record in records {
            var usage: [UUID: DomainDelegationScopeUsage] = [:]
            for scope in scopes.scopeChain(from: record.id) {
                scopeIDs.insert(scope.id)
                guard operation.requiresScopeUsage(for: scope.grant.guardrails) else { continue }
                guard let evidence = projector.usageEvidence(
                    of: scope.grant, spawnParentSessionID: creator,
                    requiresWorktreeAccounting: operation.scopeGuardrailUse == .worktree
                ) else {
                    return (.usageProofMissing, scopeIDs)
                }
                let projected = scopes.usageIncludingReservations(evidence)
                // The guardrail adds one; a joining subtree adds the rest of its live sessions or
                // worktrees, and its height below the joining root.
                usage[scope.id] = DomainDelegationScopeUsage(
                    scopeID: projected.scopeID,
                    liveSessionCount: projected.liveSessionCount + max(joining.liveSessions - 1, 0),
                    worktreeCount: projected.worktreeCount + max(joining.worktrees - 1, 0),
                    spawnParentDepth: projected.spawnParentDepth.map { $0 + joining.height },
                    countedWorktreeIDs: projected.countedWorktreeIDs
                )
            }
            if let denial = scopes.evaluateCreationGuardrails(scopeID: record.id, operation: operation, usageByScopeID: usage) {
                return (Self.reportingProjectedCount(denial, joining: joining), scopeIDs)
            }
        }
        return (nil, scopeIDs)
    }

    /// The creation decision for one creator and target.
    func admitCreation(
        creatorSessionID: UUID?,
        target: DelegationSpawnTarget,
        administration: any AgentSessionAdministrationService,
        projector: any DelegationMembershipProjector
    ) -> DelegationSpawnAdmission.Outcome {
        guard let creator = creatorSessionID, let scopes else { return .unscoped }
        let joiningSessionID: UUID?
        switch target {
        case .placedSession:
            return .unscoped
        case let .otherCreatorsLane(lane):
            // Whatever the creator's own scopes, the lane's current scopes would lose it.
            return laneMoveOutcome(lane, creator: creator, projector: projector)
        case .newSession:
            joiningSessionID = nil
        case let .unplacedSession(sessionID):
            joiningSessionID = sessionID
        }
        // Full access: the creation surface's own authority decides. Nothing is counted, reserved,
        // stamped, or refused for delegated placement (including a replicated creator or a target that
        // anchors another scope).
        guard !waives(.creatorPlacementForAccounting), !waives(.scopeAnchorMoveRestriction) else { return .unscoped }
        let records: [DomainDelegationScopeRecord]
        switch creationGuardrailScopes(forCreator: creator, projector: projector) {
        case let .creatorPlacementUnresolved(reason):
            return .creatorPlacementUnresolved(reason)
        case let .scopes(resolved):
            records = resolved
        }
        guard !records.isEmpty else { return .unscoped }

        var joining = DelegationSpawnAdmission.Joining()
        if let joiningSessionID {
            guard let subtree = projector.organizationalSubtree(of: joiningSessionID) else { return .targetUnresolved }
            let moved = Set(subtree.map(\.sessionID)).union([joiningSessionID])
            guard moved.isDisjoint(with: scopes.liveScopeAnchors()) else { return .targetAnchorsScope }
            // The target is about to run, so it counts as live whatever its state now.
            let others = moved.subtracting([joiningSessionID])
            joining = DelegationSpawnAdmission.Joining(
                liveSessions: 1 + others.count { projector.knownProvenance(for: $0)?.isLive ?? true },
                height: subtree.map(\.depth).max() ?? 0,
                worktrees: moved.reduce(into: Set<String>()) {
                    $0.formUnion(projector.knownProvenance(for: $1)?.boundWorktreeIDs ?? [])
                }.count
            )
        }
        let evaluation = evaluateCreationGuardrails(
            records, creator: creator, operation: .adminSpawn, joining: joining, projector: projector
        )
        if let denial = evaluation.denial { return .denied(denial) }
        if joining.worktrees > 0, let denial = evaluateCreationGuardrails(
            records, creator: creator, operation: .adminWorktreeCreate, joining: joining, projector: projector
        ).denial {
            return .denied(denial)
        }

        var stampScopeID: UUID?
        var stampLease: DomainDelegationScopeLease?
        for scope in scopes.liveScopes(grantedTo: creator) where scope.grant.capabilities.contains(.spawn) {
            let request = AgentSessionAdministrationRequest(
                operation: .adminSpawn, caller: .agentSession(creator), scopeID: scope.id, targetSessionIDs: [creator]
            )
            if case let .authorized(batch) = administration.authorize(request), let lease = batch.leases.first {
                stampScopeID = scope.id
                stampLease = lease
                break
            }
        }
        // Reserved synchronously after the checks above: nothing can interleave on the main actor.
        let reservation = scopes.reserve(
            scopeIDs: Array(evaluation.scopeIDs), sessions: joining.liveSessions, worktrees: joining.worktrees
        )
        return .admitted(DelegationSpawnAdmission.Admission(
            creatorSessionID: creator, stampScopeID: stampScopeID, stampLease: stampLease, reservation: reservation
        ))
    }

    /// Another creator's lane that `agent_run` would re-parent under `creator`: allowed (and not
    /// counted or stamped) only when no live tree scope's membership changes. Full access waives that
    /// scope-membership refusal only. The structural checks hold in both modes: both ancestries resolve
    /// without conflict, the lane is not on the creator's chain, and truncated chains are comparable
    /// (otherwise the lane could sit in the unknown part of the creator's chain, a hidden cycle).
    private func laneMoveOutcome(
        _ lane: UUID,
        creator: UUID,
        projector: any DelegationMembershipProjector
    ) -> DelegationSpawnAdmission.Outcome {
        guard let scopes,
              let laneAncestry = projector.organizationalAncestry(of: lane),
              let creatorAncestry = projector.organizationalAncestry(of: creator),
              !creatorAncestry.chain.contains(lane),
              let affected = DomainDelegationScopePlacementPolicy.affectedTreeScopes(
                  movedSessionID: lane,
                  previousAncestry: laneAncestry,
                  destinationAncestry: creatorAncestry,
                  liveTreeScopes: scopes.liveTreeScopeRoots()
              )
        else { return .targetUnresolved }
        guard !waives(.otherScopeMembershipMove) else { return .unscoped }
        return affected.isEmpty ? .unscoped : .targetMovesBetweenScopes(count: affected.count)
    }

    /// The session, or an organizational ancestor, is the scope's grantee or stamped with the scope.
    /// A chain that runs into unknown provenance stops there (not delegated by that part).
    private func isDelegated(
        _ sessionID: UUID,
        under record: DomainDelegationScopeRecord,
        projector: any DelegationMembershipProjector
    ) -> Bool {
        var cursor: UUID? = sessionID
        var seen: Set<UUID> = []
        while let id = cursor, seen.count < SpawnProvenanceDelegationMembershipProjector.maxChainLength,
              seen.insert(id).inserted
        {
            if id == record.grant.granteeSessionID { return true }
            guard let provenance = projector.knownProvenance(for: id) else { return false }
            if provenance.delegationScopeID == record.id { return true }
            cursor = provenance.effectiveOrganizationalParentID
        }
        return false
    }

    private func isMember(
        _ sessionID: UUID,
        ofChainFrom record: DomainDelegationScopeRecord,
        projector: any DelegationMembershipProjector
    ) -> Bool {
        guard let scopes else { return false }
        let chain = scopes.scopeChain(from: record.id)
        return !chain.isEmpty && chain.allSatisfy { scope in
            guard let proof = projector.membershipProof(for: sessionID, in: scope.grant) else { return false }
            return DomainDelegationScopeAuthority.isValid(proof, for: scope.grant, targetSessionID: sessionID)
        }
    }

    private func creatorPlacementFailure(_ creator: UUID, projector: any DelegationMembershipProjector) -> String? {
        if projector.pointResolutionState(for: creator) == .replicated { return "creator_replicated" }
        if projector.authorityConflictInAncestry(of: creator) { return "creator_ancestry_conflict" }
        return nil
    }

    /// `current` in a count denial is the scope's own count before the operation, not the count
    /// inflated by the joining subtree (`maxDepth` keeps the deepest depth the move would reach).
    private static func reportingProjectedCount(
        _ denial: DomainDelegationScopeDenial,
        joining: DelegationSpawnAdmission.Joining
    ) -> DomainDelegationScopeDenial {
        guard case let .guardrailExceeded(guardrail, limit, current) = denial else { return denial }
        switch guardrail {
        case .maxLiveSessions:
            return .guardrailExceeded(guardrail: guardrail, limit: limit, current: current - max(joining.liveSessions - 1, 0))
        case .maxWorktrees:
            return .guardrailExceeded(guardrail: guardrail, limit: limit, current: current - max(joining.worktrees - 1, 0))
        default:
            return denial
        }
    }
}

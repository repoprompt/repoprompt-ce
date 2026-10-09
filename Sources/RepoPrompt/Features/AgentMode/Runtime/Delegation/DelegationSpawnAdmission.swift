import Foundation
import MCP
import RepoPromptDomainRuntime

/// Spawn under scope for the existing session-creating surfaces (`agent_run start`, including an
/// empty or unplaced `tab_id`; `agent_manage create_session`; `agent_session_link create_lane`), and
/// the shared guardrail evaluation that `session_admin fork` and `worktree_create` reuse.
///
/// These surfaces keep their own authority: any routed Agent caller may already create sessions.
/// A scope only *adds* three things:
/// 1. before creation, guardrails (`maxLiveSessions`, `maxDepth`) of every live scope the new session
///    will count toward (`guardrailScopes`), each with its ancestor scopes, because their limits count
///    the whole subtree (design §2.2, §2.4). A worker inside an overseer's tree is bounded exactly like
///    the overseer. In-flight creations are reserved so concurrent spawns cannot overshoot;
/// 2. an existing, unplaced `tab_id` target joins with its whole organizational subtree, so the subtree
///    (its live sessions, height, and bound worktrees) is counted, and a target whose subtree anchors
///    any live scope is refused (it would move another overseer's scope under this one). Another
///    creator's lane that the start would re-parent is refused when that changes any live scope's
///    membership;
/// 3. after creation, auto-join stamping (`organizationalParentID` = creator, `delegationScopeID`)
///    when the creator holds a live scope with `spawn`. A stamp never overwrites existing placement.
///
/// A creator with no such scope gets `.unscoped` and every surface behaves exactly as before.
/// Administrative principals never have a creator session, so they are never affected.
@MainActor
enum DelegationSpawnAdmission {
    struct Admission: Equatable {
        let creatorSessionID: UUID
        /// The creator's own `spawn` scope that stamps auto-join, if any.
        let stampScopeID: UUID?
        let stampLease: DomainDelegationScopeLease?
        /// Counts the pending session(s) against every evaluated scope until `finish`.
        let reservation: DelegationScopeReservation
    }

    enum Outcome: Equatable {
        case unscoped
        case admitted(Admission)
        case denied(DomainDelegationScopeDenial)
        /// The existing target (or a session in its subtree) is the grantee or root of a live scope.
        case targetAnchorsScope
        /// Starting the existing target would move it between live scopes (`count` of them change).
        case targetMovesBetweenScopes(count: Int)
        /// The existing target's placement or subtree cannot be resolved.
        case targetUnresolved
    }

    /// What joins the creator's scopes: one new session, or an existing target's subtree (its live
    /// sessions once the target runs, its height below the target, and its bound worktrees).
    struct Joining: Equatable {
        var liveSessions = 1
        var height = 0
        var worktrees = 0
    }

    // MARK: - Shared guardrail evaluation

    /// Live scopes whose guardrails bound a session or worktree created by `creator` (and placed
    /// under it), each evaluated together with its ancestor chain:
    /// - `.tree`: every scope the creator is a member of, so a worker is bounded like its overseer;
    /// - `.workspace`: only for delegated work — the creator is the scope's grantee or a session
    ///   stamped with that scope, or descends organizationally from one. Unrelated sessions that merely
    ///   live in the workspace are never limited by someone else's delegation;
    /// - `.allSessions`: never (it cannot hold `spawn`, and every session is its member).
    static func guardrailScopes(
        forCreator creator: UUID,
        scopes: DelegationScopeRuntime,
        projector: any DelegationMembershipProjector
    ) -> [DomainDelegationScopeRecord] {
        scopes.allLiveScopes().filter { record in
            switch record.grant.kind {
            case .allSessions:
                false
            case .workspace:
                isDelegated(creator, under: record, projector: projector)
                    && isMember(creator, ofChainFrom: record, scopes: scopes, projector: projector)
            case .tree:
                isMember(creator, ofChainFrom: record, scopes: scopes, projector: projector)
            }
        }
    }

    /// The session, or an organizational ancestor, is the scope's grantee or stamped with the scope.
    /// A chain that runs into unknown provenance stops there (not delegated by that part).
    private static func isDelegated(
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

    /// Evaluates `operation`'s guardrails (`.session` or `.worktree` use) for every record and its
    /// chain, with in-flight reservations. Returns the first denial, or the scope IDs to reserve.
    static func evaluate(
        _ records: [DomainDelegationScopeRecord],
        creator: UUID,
        operation: DomainAgentSessionTargetOperation,
        joining: Joining = Joining(),
        scopes: DelegationScopeRuntime,
        projector: any DelegationMembershipProjector
    ) -> (denial: DomainDelegationScopeDenial?, scopeIDs: Set<UUID>) {
        var scopeIDs: Set<UUID> = []
        for record in records {
            var usage: [UUID: DomainDelegationScopeUsage] = [:]
            for scope in scopes.scopeChain(from: record.id) {
                let projected = scopes.usageIncludingReservations(
                    projector.usage(of: scope.grant, spawnParentSessionID: creator)
                )
                // The guardrail adds one; a joining subtree adds the rest of its live sessions or
                // worktrees, and its height below the joining root.
                usage[scope.id] = DomainDelegationScopeUsage(
                    scopeID: projected.scopeID,
                    liveSessionCount: projected.liveSessionCount + max(joining.liveSessions - 1, 0),
                    worktreeCount: projected.worktreeCount + max(joining.worktrees - 1, 0),
                    spawnParentDepth: projected.spawnParentDepth.map { $0 + joining.height }
                )
                scopeIDs.insert(scope.id)
            }
            if let denial = scopes.evaluateCreationGuardrails(scopeID: record.id, operation: operation, usageByScopeID: usage) {
                return (reportingProjectedCount(denial, joining: joining), scopeIDs)
            }
        }
        return (nil, scopeIDs)
    }

    /// `current` in a count denial is the scope's own count before the operation, not the count
    /// inflated by the joining subtree (`maxDepth` keeps the deepest depth the move would reach).
    private static func reportingProjectedCount(_ denial: DomainDelegationScopeDenial, joining: Joining) -> DomainDelegationScopeDenial {
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

    // MARK: - Spawn

    static func admit(
        creatorSessionID: UUID?,
        target: DelegationSpawnTarget = .newSession,
        scopes: DelegationScopeRuntime,
        administration: any AgentSessionAdministrationService,
        projector: any DelegationMembershipProjector
    ) -> Outcome {
        guard let creator = creatorSessionID else { return .unscoped }
        let joiningSessionID: UUID?
        switch target {
        case .placedSession:
            return .unscoped
        case let .otherCreatorsLane(lane):
            // Whatever the creator's own scopes, the lane's current scopes would lose it.
            return laneMoveOutcome(lane, creator: creator, scopes: scopes, projector: projector)
        case .newSession:
            joiningSessionID = nil
        case let .unplacedSession(sessionID):
            joiningSessionID = sessionID
        }
        let records = guardrailScopes(forCreator: creator, scopes: scopes, projector: projector)
        guard !records.isEmpty else { return .unscoped }

        var joining = Joining()
        if let joiningSessionID {
            guard let subtree = projector.organizationalSubtree(of: joiningSessionID) else { return .targetUnresolved }
            let moved = Set(subtree.map(\.sessionID)).union([joiningSessionID])
            guard moved.isDisjoint(with: scopes.liveScopeAnchors()) else { return .targetAnchorsScope }
            // The target is about to run, so it counts as live whatever its state now.
            let others = moved.subtracting([joiningSessionID])
            joining = Joining(
                liveSessions: 1 + others.count { projector.knownProvenance(for: $0)?.isLive ?? true },
                height: subtree.map(\.depth).max() ?? 0,
                worktrees: moved.reduce(into: Set<String>()) {
                    $0.formUnion(projector.knownProvenance(for: $1)?.boundWorktreeIDs ?? [])
                }.count
            )
        }
        let evaluation = evaluate(
            records, creator: creator, operation: .adminSpawn, joining: joining, scopes: scopes, projector: projector
        )
        if let denial = evaluation.denial { return .denied(denial) }
        if joining.worktrees > 0, let denial = evaluate(
            records, creator: creator, operation: .adminWorktreeCreate, joining: joining, scopes: scopes, projector: projector
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
        return .admitted(Admission(
            creatorSessionID: creator, stampScopeID: stampScopeID, stampLease: stampLease, reservation: reservation
        ))
    }

    /// Another creator's lane that `agent_run` would re-parent under `creator`: allowed (and not
    /// counted or stamped) only when no live tree scope's membership changes.
    private static func laneMoveOutcome(
        _ lane: UUID,
        creator: UUID,
        scopes: DelegationScopeRuntime,
        projector: any DelegationMembershipProjector
    ) -> Outcome {
        guard let laneAncestry = projector.organizationalAncestry(of: lane),
              let creatorAncestry = projector.organizationalAncestry(of: creator),
              !creatorAncestry.chain.contains(lane),
              let affected = DomainDelegationScopePlacementPolicy.affectedTreeScopes(
                  movedSessionID: lane,
                  previousAncestry: laneAncestry,
                  destinationAncestry: creatorAncestry,
                  liveTreeScopes: scopes.liveTreeScopeRoots()
              )
        else { return .targetUnresolved }
        return affected.isEmpty ? .unscoped : .targetMovesBetweenScopes(count: affected.count)
    }

    private static func isMember(
        _ sessionID: UUID,
        ofChainFrom record: DomainDelegationScopeRecord,
        scopes: DelegationScopeRuntime,
        projector: any DelegationMembershipProjector
    ) -> Bool {
        let chain = scopes.scopeChain(from: record.id)
        return !chain.isEmpty && chain.allSatisfy { scope in
            guard let proof = projector.membershipProof(for: sessionID, in: scope.grant) else { return false }
            return DomainDelegationScopeAuthority.isValid(proof, for: scope.grant, targetSessionID: sessionID)
        }
    }

    /// Production entry used by the MCP surfaces: admits or throws the recoverable scope error.
    /// Pair every non-nil result with `finish(_:)`. A `.placedSession` target is already placed: it
    /// never moves, so nothing is admitted, counted, or stamped.
    static func admitOrThrow(creatorSessionID: UUID?, target: DelegationSpawnTarget = .newSession) throws -> Admission? {
        if target == .placedSession { return nil }
        let bridge = AgentSessionLinkRuntimeBridge.shared
        switch admit(
            creatorSessionID: creatorSessionID,
            target: target,
            scopes: bridge.delegationScopes,
            administration: bridge.sessionAdministration,
            projector: SpawnProvenanceDelegationMembershipProjector.production(worktreeOwnership: bridge.worktreeOwnership)
        ) {
        case .unscoped:
            return nil
        case let .admitted(admission):
            return admission
        case let .denied(denial):
            throw error(for: denial)
        case .targetAnchorsScope:
            throw error(code: "spawn_target_anchors_scope", fields: [
                "detail": .string(
                    "The target tab's session (or one of its descendants) holds or roots a delegation scope; starting it under your scope would move that scope. Use a new tab."
                )
            ])
        case let .targetMovesBetweenScopes(count):
            // A count only: other scopes' identities are never disclosed.
            throw error(code: "placement_affects_other_scopes", fields: [
                "affected_scope_count": .int(count),
                "detail": .string(
                    "The target tab's session is another overseer's lane; starting it here would move it between delegation scopes. Use a new tab."
                )
            ])
        case .targetUnresolved:
            throw error(code: "placement_unresolved", fields: [
                "detail": .string("The target tab's session tree cannot be checked. Use a new tab.")
            ])
        }
    }

    /// Releases the in-flight reservation once the new session is visible to the projector (after the
    /// stamp) or creation failed. Idempotent.
    static func finish(
        _ admission: Admission?,
        scopes: DelegationScopeRuntime = AgentSessionLinkRuntimeBridge.shared.delegationScopes
    ) {
        scopes.release(admission?.reservation)
    }

    /// Structured, recoverable refusal: a stable code followed by a JSON object.
    static func error(for denial: DomainDelegationScopeDenial) -> MCPError {
        var fields: [String: Value] = [:]
        switch denial {
        case let .guardrailExceeded(guardrail, limit, current):
            fields["guardrail"] = .string(guardrail.rawValue)
            fields["limit"] = .int(limit)
            fields["current"] = .int(current)
            fields["detail"] = .string(
                "The new session would join a delegation scope at its limit. Retire or release sessions in that scope, or ask the user for a larger limit."
            )
        case let .capabilityMissing(capability):
            fields["capability"] = .string(capability.rawValue)
        default:
            break
        }
        return error(code: denial.publicCode ?? "scope_denied", fields: fields)
    }

    private static func error(code: String, fields: [String: Value]) -> MCPError {
        var fields = fields
        fields["code"] = .string(code)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = (try? encoder.encode(Value.object(fields))).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return MCPError.invalidParams("\(code): \(json)")
    }

    /// Auto-join after creation. Skipped silently if the scope lapsed meanwhile or the session already
    /// has a placement of its own (`stampDelegationPlacementIfUnplaced`): the session was created
    /// under the surface's own authority and simply does not join by stamp.
    @discardableResult
    static func stamp(
        _ admission: Admission?,
        newSessionID: UUID,
        viewModel: AgentModeViewModel,
        scopes: DelegationScopeRuntime = AgentSessionLinkRuntimeBridge.shared.delegationScopes
    ) async -> Bool {
        guard let admission, let scopeID = admission.stampScopeID, let lease = admission.stampLease,
              scopes.isCurrent(lease),
              let commit = try? viewModel.stampDelegationPlacementIfUnplaced(
                  sessionID: newSessionID, creatorSessionID: admission.creatorSessionID, delegationScopeID: scopeID
              )
        else { return false }
        do {
            try await commit.persisted()
            return true
        } catch {
            return false
        }
    }
}

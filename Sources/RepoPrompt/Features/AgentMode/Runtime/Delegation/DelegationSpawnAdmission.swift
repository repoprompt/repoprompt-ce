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
///
/// The decisions themselves live in `OverseerAuthorizationEngine+Creation.swift`. With Overseer full
/// access none of this delegated accounting applies: no guardrail, joining count, reservation, auto-join stamp, scope-move
/// refusal, or creator placement proof stands between a routed creator and its creation surface. Structural
/// invariants (a lane is never re-parented under itself or an unresolvable ancestry) hold in both modes.
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
        case creatorPlacementUnresolved(String)
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

    // MARK: - Decisions (owned by `OverseerAuthorizationEngine`; these entry points forward)

    /// Live scopes whose guardrails bound a session or worktree created by `creator`
    /// (`OverseerAuthorizationEngine.creationGuardrailScopes`). Throws the recoverable placement
    /// refusal when the creator's placement cannot locate them.
    static func guardrailScopes(
        forCreator creator: UUID,
        scopes: DelegationScopeRuntime,
        projector: any DelegationMembershipProjector
    ) throws -> [DomainDelegationScopeRecord] {
        switch scopes.authorization.creationGuardrailScopes(forCreator: creator, projector: projector) {
        case let .scopes(records):
            return records
        case let .creatorPlacementUnresolved(reason):
            throw error(for: .usageProofMissing, subreason: reason)
        }
    }

    /// `OverseerAuthorizationEngine.evaluateCreationGuardrails`.
    static func evaluate(
        _ records: [DomainDelegationScopeRecord],
        creator: UUID,
        operation: DomainAgentSessionTargetOperation,
        joining: Joining = Joining(),
        scopes: DelegationScopeRuntime,
        projector: any DelegationMembershipProjector
    ) -> (denial: DomainDelegationScopeDenial?, scopeIDs: Set<UUID>) {
        scopes.authorization.evaluateCreationGuardrails(
            records, creator: creator, operation: operation, joining: joining, projector: projector
        )
    }

    /// `OverseerAuthorizationEngine.admitCreation`.
    static func admit(
        creatorSessionID: UUID?,
        target: DelegationSpawnTarget = .newSession,
        scopes: DelegationScopeRuntime,
        administration: any AgentSessionAdministrationService,
        projector: any DelegationMembershipProjector
    ) -> Outcome {
        scopes.authorization.admitCreation(
            creatorSessionID: creatorSessionID, target: target, administration: administration, projector: projector
        )
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
        case let .creatorPlacementUnresolved(reason):
            throw error(for: .usageProofMissing, subreason: reason)
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
    static func error(for denial: DomainDelegationScopeDenial, subreason: String? = nil) -> MCPError {
        var fields: [String: Value] = [:]
        if let subreason { fields["subreason"] = .string(subreason) }
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
            fields["detail"] = .string("Call session_admin request_scope with capabilities including \(capability.rawValue), then wait for the user's approval. Call scope_status for the operation catalog and current grants.")
        case .usageProofMissing, .membershipProofMissing:
            fields["reason"] = .string("placement_unresolved")
            if fields["subreason"] == nil { fields["subreason"] = .string("usage_evidence_unavailable") }
            fields["detail"] = .string(placementUnresolvedDetail(subreason: fields["subreason"]?.stringValue))
        default:
            break
        }
        return error(code: denial.publicCode ?? "scope_denied", fields: fields)
    }

    /// Manual recovery for a placement proof that no tool call can supply. Shared by every surface
    /// that reports `placement_unresolved`, so the guidance never drifts between them.
    nonisolated static func placementUnresolvedDetail(subreason: String?) -> String {
        let noToolRepair = "No grant, capability, or session_admin call repairs this."
        switch subreason {
        case "creator_replicated":
            return "Your session is presented by more than one window or tab, so no single canonical owner can prove which delegation scope counts this creation. Close the duplicate presentation of this session (keep one tab), then retry. \(noToolRepair)"
        case "creator_ancestry_conflict":
            return "An organizational ancestor of your session has conflicting or unproven placement (a duplicated or stale tab binding), so the delegation scope that counts this creation cannot be proved. Close or resolve that ancestor's conflicting presentation, then retry. \(noToolRepair)"
        default:
            return "Delegation scope capacity cannot be proved: a session counted by your scope's limits has missing or conflicting placement (an unindexed, duplicated, or stale tab binding). Resolve or close that presentation, then retry. \(noToolRepair)"
        }
    }

    private static func error(code: String, fields: [String: Value]) -> MCPError {
        var fields = fields
        fields["code"] = .string(code)
        fields["retryable"] = .bool(false)
        if fields["detail"] == nil {
            fields["detail"] = .string("Scope admission was refused. Inspect scope_status and resolve the reported authority or placement check before retrying.")
        }
        if fields["subreason"] == nil { fields["subreason"] = .string(code) }
        // An unresolved placement has no executable repair; a generic next_call would only pretend
        // otherwise. Its detail carries the manual recovery.
        if code == "placement_unresolved" || fields["reason"] == .string("placement_unresolved") {
            fields["recovery"] = .string("manual")
        } else {
            fields["next_call"] = .object(["tool": .string("session_admin"), "arguments": .object(["op": .string("scope_status")])])
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = (try? encoder.encode(Value.object(fields))).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return MCPError.invalidParams("\(code): \(json)")
    }

    /// Auto-join after creation. Skipped silently if the scope lapsed meanwhile or the session already
    /// has a placement of its own (`stampDelegationPlacementIfUnplaced`): the session was created
    /// under the surface's own authority and simply does not join by stamp. For a creating target,
    /// `true` acknowledges in-memory staging under its exact owner; its configured first save
    /// persists that placement. Existing targets still acknowledge their required placement write.
    @discardableResult
    static func stamp(
        _ admission: Admission?,
        newSessionID: UUID,
        viewModel: AgentModeViewModel,
        scopes: DelegationScopeRuntime = AgentSessionLinkRuntimeBridge.shared.delegationScopes,
        creationHandle: AgentSessionCreationHandle? = nil
    ) async -> Bool {
        guard let admission, let scopeID = admission.stampScopeID, let lease = admission.stampLease,
              scopes.isCurrent(lease)
        else { return false }
        if let creationHandle {
            return (try? viewModel.stageCreationDelegationPlacementIfUnplaced(
                creationHandle: creationHandle,
                sessionID: newSessionID,
                creatorSessionID: admission.creatorSessionID,
                delegationScopeID: scopeID
            )) ?? false
        }
        guard let commit = try? viewModel.stampDelegationPlacementIfUnplaced(
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

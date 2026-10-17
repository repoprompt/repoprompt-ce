import Foundation
import RepoPromptDomainRuntime

/// Every authorization gate an Overseer / delegation operation can meet, with its fixed class.
///
/// **Permission** gates exist only to restrict what a delegated agent may do; Overseer full access
/// waives every one of them. **Integrity** gates protect identity, structure, input validity, and
/// durable state; they hold in both modes and can never be waived.
///
/// Every permission decision in production names its gate through `OverseerAuthorizationEngine`.
/// `Scripts/overseer_authorization_guardrails.py` pins which files may ask (and for which gates, how
/// often) through `Scripts/overseer_authorization_manifest.tsv`, and the gate-contract
/// tests (`OverseerAuthorizationEngineTests`) pin the classification of every case.
enum OverseerAuthorizationGate: String, CaseIterable {
    // MARK: Permission (waived by full access)

    /// A live delegation scope must cover the operation (implicit scope selection, scope grants).
    case scopeCoverage
    /// The scope chain must hold the operation's capability, including state-dependent `control`.
    case scopeCapability
    /// `.allSessions` scopes may hold only observe / organize / restructure.
    case allSessionsCapabilityCeiling
    /// Targets (and named sessions) must be members of the scope chain; membership never grows.
    case scopeMembership
    /// Batch confirmation cards (bulk threshold, always-carded, adoption).
    case confirmationRequirement
    /// `maxLiveSessions` / `maxDepth` for spawn, fork, adoption, and joining subtrees.
    case sessionQuota
    /// `maxWorktrees` for creation, binding, reactivation, and adoption.
    case worktreeQuota
    /// Creator placement proofs whose only purpose is to find the scopes that count a creation.
    case creatorPlacementForAccounting
    /// A creation may not graft a session whose subtree anchors a live scope.
    case scopeAnchorMoveRestriction
    /// A move may not change the membership of another live scope.
    case otherScopeMembershipMove
    /// A caller's own explicitly named restricted scope narrowing its authority.
    case restrictedScopeNarrowing
    /// The per-creator lane count (`AgentSessionLanePolicy.agentSessionLaneMaximumCount`).
    case creatorLaneQuota
    /// Existing `agent_run` / `agent_manage` / worktree-binding targets must be the caller's own spawns.
    case directChildOrCreatorOwnership
    /// Operations otherwise reserved for the human (`agent_manage cleanup_sessions` deletion).
    case humanOnlyForAgent
    /// A lane creator or child-target link needs an active link, activation, or exact grant.
    case linkRequired
    /// A link created under a scope must be observed by the scope's own grantee.
    case observerMustBeCaller
    /// A link created under a scope may carry no capability the scope chain lacks.
    case linkCapabilityCeiling

    // MARK: Integrity (enforced in both modes)

    /// Server-owned routing resolves the exact caller (administrative / unresolved / Agent session).
    case callerIdentityAndRoute
    /// The named target exists and is operable.
    case targetExistence
    /// Operation-specific self-targeting rules.
    case selfTargetRule
    /// An explicitly supplied scope ID is known, the caller's, live, and current.
    case explicitScopeInput
    /// A presented confirmation card exists, is approved, and is bound to exactly this request.
    case presentedConfirmationInput
    /// A mutation needs one exact owner for the state it changes.
    case canonicalMutationOwner
    /// No organizational cycle; ancestry resolvable and comparable.
    case organizationalStructure
    /// Arguments, selectors, and idempotency keys are valid.
    case argumentsAndSelectors
    /// Idempotency ledgers and single application of a card.
    case idempotencyAndSingleApplication
    /// Exact endpoint and link incarnation for transport operations.
    case transportIncarnation
    /// Bounded operational resources (in-flight tasks, ledgers, queues).
    case operationalCapacity
    /// Shutdown, deletion, and cancellation.
    case lifecycleAndCancellation
    /// Durable save outcomes are reported, never relabeled as permission.
    case persistenceOutcome

    enum Classification {
        case permission
        case integrity
    }

    var classification: Classification {
        switch self {
        case .scopeCoverage, .scopeCapability, .allSessionsCapabilityCeiling, .scopeMembership,
             .confirmationRequirement, .sessionQuota, .worktreeQuota, .creatorPlacementForAccounting,
             .scopeAnchorMoveRestriction, .otherScopeMembershipMove, .restrictedScopeNarrowing, .creatorLaneQuota,
             .directChildOrCreatorOwnership, .humanOnlyForAgent, .linkRequired, .observerMustBeCaller,
             .linkCapabilityCeiling:
            .permission
        case .callerIdentityAndRoute, .targetExistence, .selfTargetRule, .explicitScopeInput,
             .presentedConfirmationInput, .canonicalMutationOwner, .organizationalStructure,
             .argumentsAndSelectors, .idempotencyAndSingleApplication, .transportIncarnation,
             .operationalCapacity, .lifecycleAndCancellation, .persistenceOutcome:
            .integrity
        }
    }
}

/// The single authority for Overseer full access versus restricted delegation.
///
/// It alone reads the master setting (through its runtime's injectable input; production is the
/// stored user setting, `OverseerGlobalAutoApprove`), never tool arguments, prompt text, or the
/// existence of a recorded grant. Each `DelegationScopeRuntime` owns exactly one engine.
///
/// Full access waives every **permission** gate (`OverseerAuthorizationGate`); restricted mode applies
/// the delegated algorithms unchanged. **Integrity** gates hold in both modes. The administration
/// decision (scope selection, explicit-scope fallback, card validation and carry) lives here; the
/// remaining families consult `waives(_:)` by gate name from the files the guardrail manifest pins.
@MainActor
final class OverseerAuthorizationEngine {
    /// The owning runtime (weak: the runtime owns the engine). Engine extension files read it.
    private(set) weak var scopes: DelegationScopeRuntime?

    init(scopes: DelegationScopeRuntime) {
        self.scopes = scopes
    }

    /// The production engine of the shared delegation runtime.
    static var current: OverseerAuthorizationEngine {
        AgentSessionLinkRuntimeBridge.shared.delegationScopes.authorization
    }

    /// Read fresh at every decision; a detached engine is restricted.
    private var isFullAccess: Bool {
        scopes?.isGlobalAutoApproveEnabled() ?? false
    }

    /// Engine-issued link capability evidence consumed by `DomainAgentSessionLinkAuthority`. Only this
    /// engine elevates or revokes; every restricted-mode evaluation revokes all elevations, so a
    /// full-access elevation never outlives the setting at any later link fence.
    let linkCapabilityElevation = DomainAgentSessionLinkCapabilityElevation()

    /// Whether full access waives `gate`. Integrity gates are never waived.
    func waives(_ gate: OverseerAuthorizationGate) -> Bool {
        guard gate.classification == .permission else { return false }
        guard isFullAccess else {
            linkCapabilityElevation.revokeAll()
            return false
        }
        return true
    }

    /// A routed Agent session acting on a *different* session through an existing-target operation is
    /// not held to direct-child or human-only rules under full access. Administrative and unresolved
    /// callers, and self-targeting, keep their own identity rules.
    func waivesTargetOwnership(
        _ gate: OverseerAuthorizationGate,
        caller: DomainAgentSessionCallerIdentity,
        targetSessionID: UUID
    ) -> Bool {
        precondition(gate == .directChildOrCreatorOwnership || gate == .humanOnlyForAgent)
        guard waives(gate), case let .agentSession(callerSessionID) = caller else { return false }
        return callerSessionID != targetSessionID
    }

    // MARK: - Grant lifecycle (executed by `DelegationScopeRuntime`)

    /// Scope requests are validated as if answered by the full-access grant: no all-sessions
    /// capability ceiling (`allSessionsCapabilityCeiling`).
    var validatesScopeRequestsWithoutCeiling: Bool {
        waives(.allSessionsCapabilityCeiling)
    }

    /// The runtime mints and keeps the caller's full-access grant (`scopeCoverage`); when this is false
    /// it revokes every full-access grant ("off means off").
    var issuesFullAccessGrant: Bool {
        waives(.scopeCoverage)
    }

    // MARK: - Presentation

    /// The `become_overseer` next-turn guidance for the current mode.
    var bootstrapGuidance: String {
        if isFullAccess {
            return "Overseer enabled. Overseer full access: ON. For session_admin inventory/rename/retire/link, agent_session_link create_lane, or agent_run start/steer, just call the operation; full access supplies the scope and capabilities without cards. For one saved target, call become_overseer with session_id and optional message to prepare, link and dispatch automatically. session_admin scope_status lists operations and current grants. Exact routing, target readiness and user-instruction boundaries still apply."
        }
        return "Overseer enabled. Overseer full access: OFF. Use existing covering grants directly; activation alone grants no authority. Request authority only when no current grant covers the operation: for listing call session_admin {op:\"request_scope\",kind:\"workspace\",capabilities:[\"observe\"]}; add organize for renaming/grouping, and restructure for release/retire (also control for running targets). Existing standing consent may settle a request without a card. Otherwise the user sees one approval card; RepoPrompt notifies you after the decision, then continue with session_admin inventory. Do not re-request while pending. For one saved target, become_overseer with session_id and optional message requests observe + control + restructure together and automatically prepares, links and dispatches after consent. session_admin scope_status lists every operation, required capabilities and current grants."
    }

    /// The `agent_manage list_sessions` note about workspace-wide listing for the current mode.
    func childListingGuidance(workspaceID: UUID) -> String {
        isFullAccess
            ? "Overseer full access: ON. For workspace-wide listing, call become_overseer if needed, then just call session_admin inventory with filter.workspace=\(workspaceID.uuidString); no scope request or card is needed. "
            : "Overseer full access: OFF. Use existing covering grants directly. Request authority only when no current grant covers workspace-wide listing: call become_overseer if needed, then session_admin request_scope with kind=workspace, workspace=\(workspaceID.uuidString), and capabilities including observe plus needed mutation capabilities. Existing standing consent may settle it without a card. Otherwise continue after the user approves the scope card and RepoPrompt notifies you; then use session_admin inventory. "
    }

    // MARK: - Administration (session_admin and the sidebar dispatcher)

    /// The single administration decision: scope selection, the explicit-scope full-access fallback,
    /// independent card validation, and one fresh projection region per pass.
    func authorizeAdministration(
        _ request: AgentSessionAdministrationRequest,
        projector: any DelegationMembershipProjector
    ) -> AgentSessionAdministrationAuthorization {
        guard let scopes else { return .denied(.unknownScope, sessionID: nil) }
        guard let callerSessionID = request.caller.agentSessionID else {
            return .denied(.callerNotAgentSession, sessionID: nil)
        }
        // Off means off: a global grant left from an earlier "on" never outlives the setting.
        scopes.reconcileGlobalAutoApprove()
        let scope: DomainDelegationScopeRecord
        if let scopeID = request.scopeID {
            // The authority checks grantee identity before disclosing anything about this scope.
            guard let record = scopes.record(id: scopeID) else { return .denied(.unknownScope, sessionID: nil) }
            let explicit = authorize(request, scope: record, callerSessionID: callerSessionID, projector: projector)
            // Full access is never narrowed by the caller's own restricted scope, live or stale (revoked,
            // expired, regenerated): the full-access grant authorizes and becomes the placement, so the
            // agent needs no recovery call. An unknown ID (above) and another session's scope stay
            // identity/input refusals (`explicitScopeInput`) that disclose nothing about other grants.
            guard waives(.restrictedScopeNarrowing), Self.explicitPassNarrows(explicit),
                  !record.grant.unrestricted,
                  record.grant.granteeSessionID == callerSessionID,
                  let global = scopes.ensureGlobalAutoApproveScope(for: callerSessionID)
            else { return explicit }
            return fullAccessFallback(
                request, explicitScope: record, global: global, callerSessionID: callerSessionID, projector: projector
            )
        } else {
            let selection = implicitAdministrationScopes(request, callerSessionID: callerSessionID)
            guard let selected = selection.first, selection.count == 1 else {
                return selection.isEmpty ? .denied(.unknownScope, sessionID: nil)
                    : .scopeSelectionRequired(scopeIDs: selection.map(\.id))
            }
            scope = selected
        }
        return authorize(request, scope: scope, callerSessionID: callerSessionID, projector: projector)
    }

    /// Target derivation uses the same scope choice as execution, including the first full-access
    /// call before a grant has been materialized. Selection grants no access to group names: the
    /// front door still proves discovery capabilities and each carrier's membership.
    func scopeForAdministrationShaping(_ request: AgentSessionAdministrationRequest) -> DomainDelegationScopeRecord? {
        guard let scopes, let callerSessionID = request.caller.agentSessionID else { return nil }
        scopes.reconcileGlobalAutoApprove()
        if let scopeID = request.scopeID {
            guard let record = scopes.record(id: scopeID),
                  record.grant.granteeSessionID == callerSessionID else { return nil }
            if waives(.restrictedScopeNarrowing), !record.grant.unrestricted,
               let global = scopes.ensureGlobalAutoApproveScope(for: callerSessionID) { return global }
            return record.isActive ? record : nil
        }
        let selection = implicitAdministrationScopes(request, callerSessionID: callerSessionID)
        return selection.count == 1 ? selection[0] : nil
    }

    private func implicitAdministrationScopes(
        _ request: AgentSessionAdministrationRequest, callerSessionID: UUID
    ) -> [DomainDelegationScopeRecord] {
        guard let scopes else { return [] }
        if let global = scopes.ensureGlobalAutoApproveScope(for: callerSessionID) { return [global] }
        let live = scopes.liveScopes(grantedTo: callerSessionID)
        var required = request.operation.requiredScopeCapabilities(for: .idle)
        if request.operation == .adminLink { required.formUnion([.observe, .control]) }
        let capable = live.filter { record in
            scopes.scopeChain(from: record.id).allSatisfy { required.isSubset(of: $0.grant.capabilities) }
        }
        // Select by capability only; membership and every current lease are proved after shaping.
        return capable.count == 1 ? capable : live.count == 1 || capable.isEmpty ? live : capable
    }

    /// The caller's explicitly named restricted scope would not admit the whole request: a denial, a
    /// confirmation card, or targets set aside for a missing `control`. A presented card that does not
    /// match is input (`presentedConfirmationInput`), never retried.
    private static func explicitPassNarrows(_ outcome: AgentSessionAdministrationAuthorization) -> Bool {
        switch outcome {
        case let .authorized(batch):
            !batch.itemsRequiringControl.isEmpty
        case .denied(.confirmationMismatch, _):
            false
        case .confirmationRequired, .denied:
            true
        case .scopeSelectionRequired:
            false
        }
    }

    /// Re-authorizes against the full-access grant. A presented card is validated on its own against
    /// the explicit scope it was issued for (the explicit pass may have stopped before reaching it), and
    /// only an exactly bound card rides into the batch, so `perform` claims and settles it once.
    private func fullAccessFallback(
        _ request: AgentSessionAdministrationRequest,
        explicitScope: DomainDelegationScopeRecord,
        global: DomainDelegationScopeRecord,
        callerSessionID: UUID,
        projector: any DelegationMembershipProjector
    ) -> AgentSessionAdministrationAuthorization {
        let outcome = authorize(
            request.withoutConfirmation(), scope: global, callerSessionID: callerSessionID, projector: projector
        )
        guard let confirmationID = request.confirmationID else { return outcome }
        guard case let .authorized(batch) = outcome else { return outcome }
        guard let card = scopes?.confirmations.confirmation(id: confirmationID, granteeSessionID: callerSessionID)?
            .domainConfirmation,
            DomainDelegationScopeAuthority.confirmationBindingMatches(
                card, scope: explicitScope, operation: request.operation,
                idempotencyKey: request.idempotencyKey, argumentsDigest: request.argumentsDigest
            ),
            Set(batch.admittedSessionIDs).isSubset(of: card.approvedSessionIDs)
        else { return .denied(.confirmationMismatch, sessionID: nil) }
        return .authorized(AgentSessionAdministrationAuthorizedBatch(
            request: request, scope: batch.scope, leases: batch.leases, bases: batch.bases,
            itemsRequiringControl: batch.itemsRequiringControl, confirmation: card
        ))
    }

    /// Grantee identity, then one fresh projection region for the selected scope.
    private func authorize(
        _ request: AgentSessionAdministrationRequest,
        scope: DomainDelegationScopeRecord,
        callerSessionID: UUID,
        projector: any DelegationMembershipProjector
    ) -> AgentSessionAdministrationAuthorization {
        guard scope.grant.granteeSessionID == callerSessionID else {
            return .denied(.granteeMismatch, sessionID: nil)
        }
        // Scope-level reads with no target/state/usage projection must not enumerate every session.
        guard !request.targetSessionIDs.isEmpty || request.operation.scopeGuardrailUse != nil else {
            return authorize(request, scope: scope, projected: projector)
        }
        if request.operation.scopeGuardrailUse != nil {
            return projector.withSynchronousCensus { projector in
                authorize(request, scope: scope, projected: projector)
            }
        }
        return projector.withSynchronousTargets(Set(request.targetSessionIDs)) { projector in
            authorize(request, scope: scope, projected: projector)
        }
    }

    private func authorize(
        _ request: AgentSessionAdministrationRequest,
        scope: DomainDelegationScopeRecord,
        projected projector: any DelegationMembershipProjector
    ) -> AgentSessionAdministrationAuthorization {
        guard let scopes else { return .denied(.unknownScope, sessionID: nil) }
        guard let callerSessionID = request.caller.agentSessionID else {
            return .denied(.callerNotAgentSession, sessionID: nil)
        }
        // One proof per target for the scope and each ancestor: an attenuated scope never reaches a
        // session its parents could not.
        let chain = scopes.scopeChain(from: scope.id)
        var memberships: [UUID: [DomainDelegationScopeMembershipProof]] = [:]
        var replicatedMutationTarget: UUID?
        for target in request.targetSessionIDs {
            if request.operation.mutatesTarget, request.operation != .adminReorderGroups,
               !hasMutationOwner(for: target, operation: request.operation, projector: projector)
            {
                replicatedMutationTarget = replicatedMutationTarget ?? target
            }
            memberships[target] = chain.compactMap { projector.membershipProof(for: target, in: $0.grant) }
        }
        var targetStates: [UUID: DomainDelegationScopeTargetState] = [:]
        for target in request.targetSessionIDs {
            targetStates[target] = projector.targetState(for: target)
        }
        var usage: [UUID: DomainDelegationScopeUsage] = [:]
        if request.operation.scopeGuardrailUse != nil {
            for record in chain where request.operation.requiresScopeUsage(for: record.grant.guardrails) {
                // In-flight creations (spawn, fork, worktree_create) count until they settle.
                guard let evidence = projector.usageEvidence(
                    of: record.grant, spawnParentSessionID: request.targetSessionIDs.first
                ) else { return .denied(.usageProofMissing, sessionID: nil) }
                usage[record.id] = scopes.usageIncludingReservations(evidence)
            }
        }
        let confirmation = request.confirmationID.flatMap {
            scopes.confirmations.confirmation(id: $0, granteeSessionID: callerSessionID)?.domainConfirmation
        }
        // A supplied stale, consumed or unknown card is not equivalent to omitting a card.
        guard request.confirmationID == nil || confirmation != nil else {
            return .denied(.confirmationMismatch, sessionID: nil)
        }
        let outcome = scopes.authorize(DomainDelegationScopeAuthorizationRequest(
            operation: request.operation,
            caller: request.caller,
            scopeID: scope.id,
            presentedGeneration: scope.generation,
            targetSessionIDs: request.targetSessionIDs,
            memberships: memberships,
            usageByScopeID: usage,
            targetStates: targetStates,
            argumentsDigest: request.argumentsDigest,
            idempotencyKey: request.idempotencyKey,
            confirmation: confirmation
        ))
        func batch(_ items: DomainDelegationScopeAuthorizedItems) -> AgentSessionAdministrationAuthorizedBatch {
            AgentSessionAdministrationAuthorizedBatch(
                request: request,
                scope: scope,
                leases: items.leases,
                bases: items.bases,
                itemsRequiringControl: items.itemsRequiringControl,
                confirmation: confirmation
            )
        }
        switch outcome {
        case let .authorized(items):
            if let replicatedMutationTarget { return .denied(.mutationOwnerUnavailable, sessionID: replicatedMutationTarget) }
            return .authorized(batch(items))
        case let .confirmationRequired(reason, items):
            if let replicatedMutationTarget { return .denied(.mutationOwnerUnavailable, sessionID: replicatedMutationTarget) }
            return .confirmationRequired(reason, batch(items))
        case let .denied(denial, sessionID):
            return .denied(denial, sessionID: sessionID)
        }
    }
}

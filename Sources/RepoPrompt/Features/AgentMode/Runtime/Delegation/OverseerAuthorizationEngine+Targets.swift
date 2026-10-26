import Foundation
import RepoPromptDomainRuntime

/// Existing-target operations, human-only gates, and link requirements.
///
/// Callers resolve the exact caller from server-owned routing and execute; these decisions are made
/// here. Full access waives `directChildOrCreatorOwnership`, `humanOnlyForAgent`, and `linkRequired`
/// for a routed Agent session acting on another session. Administrative principals keep their own
/// external authority path, unresolved Agent routing always refuses (`callerIdentityAndRoute`), and
/// operation-specific self-target rules stay with the restricted operation authorizer
/// (`selfTargetRule`).
extension OverseerAuthorizationEngine {
    // MARK: - agent_run / agent_manage targets

    /// Whether `caller` may run `operation` on the target described by `provenance`.
    func authorizesTargetOperation(
        _ operation: DomainAgentSessionTargetOperation,
        caller: DomainAgentSessionCallerIdentity,
        provenance: DomainAgentSessionTargetProvenance
    ) -> Bool {
        if waivesTargetOwnership(.directChildOrCreatorOwnership, caller: caller, targetSessionID: provenance.targetSessionID) {
            return true
        }
        return DomainAgentSessionOperationAuthorizer.authorize(operation: operation, caller: caller, target: provenance).isAuthorized
    }

    /// `manage_worktree` binding authority for a mutation naming `targetSessionID`: an administrative
    /// principal, the target itself, its spawn parent, or an overseer whose exact endpoint holds a live
    /// Manage grant over it; full access waives the ownership restriction for routed Agent callers.
    func authorizesWorktreeBinding(
        caller: DomainAgentSessionCallerIdentity,
        targetSessionID: UUID,
        spawnParentSessionID: () async -> UUID?,
        callerHoldsManageGrant: () async -> Bool
    ) async -> Bool {
        if authorizesWorktreeBindingWithoutLink(caller: caller, targetSessionID: targetSessionID, spawnParentSessionID: nil) { return true }
        guard case let .agentSession(callerSessionID) = caller else { return false }
        if await spawnParentSessionID() == callerSessionID { return true }
        return await callerHoldsManageGrant()
    }

    /// Synchronous commit fence for authority independent of a link. Provenance is immutable;
    /// full access is deliberately read live, even if it short-circuited entry admission.
    func authorizesWorktreeBindingWithoutLink(
        caller: DomainAgentSessionCallerIdentity,
        targetSessionID: UUID,
        spawnParentSessionID: UUID?
    ) -> Bool {
        switch caller {
        case .administrativePrincipal: true
        case .unresolvedAgentRun: false
        case let .agentSession(callerSessionID):
            callerSessionID == targetSessionID || spawnParentSessionID == callerSessionID
                || waivesTargetOwnership(.directChildOrCreatorOwnership, caller: caller, targetSessionID: targetSessionID)
        }
    }

    // MARK: - Human-only for agents

    /// `agent_manage cleanup_sessions` deletes sessions: human-only for agents unless full access.
    /// Self-targeting and routing are checked by the caller before this decision.
    func authorizesAgentCleanup(caller: DomainAgentSessionCallerIdentity, targetSessionID: UUID) -> Bool {
        waivesTargetOwnership(.humanOnlyForAgent, caller: caller, targetSessionID: targetSessionID)
    }

    /// An Agent caller may delete sessions it did not create through MCP only under full access.
    func permitsAgentDeletingUnoriginatedSessions(caller: DomainAgentSessionCallerIdentity) -> Bool {
        guard case .agentSession = caller else { return false }
        return waives(.humanOnlyForAgent)
    }

    // MARK: - Links

    /// A child target is linkable by `observerSessionID` when full access waives `linkRequired`, or a
    /// live exact-session scope with current link consent covers it.
    func permitsChildLinkTarget(observerSessionID: UUID, targetSessionID: UUID, at date: Date = Date()) -> Bool {
        if waives(.linkRequired) { return true }
        guard let scopes else { return false }
        return scopes.liveScopes(grantedTo: observerSessionID).contains {
            $0.grant.kind == .session(targetSessionID: targetSessionID)
                && scopes.linkConsent.permits(scopeID: $0.id, observer: observerSessionID, target: targetSessionID, at: date)
        }
    }

    /// One more lane for a creator that already has `admittedLaneCount` (`creatorLaneQuota`, waived by
    /// full access). The in-flight lane-task bound in the bridge is operational capacity and stays.
    func admitsAdditionalLane(admittedLaneCount: Int) -> Bool {
        waives(.creatorLaneQuota) || admittedLaneCount < AgentSessionLanePolicy.agentSessionLaneMaximumCount
    }

    /// A linked-basis lane creator must still hold an active link, unless full access waives it.
    var laneCreatorRequiresActiveLink: Bool {
        !waives(.linkRequired)
    }

    /// The MCP catalog lists the full oversight surface for every eligible session from its first
    /// turn, as if activated (each operation still authorizes when it runs).
    var listsFullOversightSurface: Bool {
        waives(.linkRequired)
    }

    /// Full access: a missing link is not a permission barrier. Returns the full-access grant to use as
    /// the source scope of the ordinary managed link the bridge establishes (so turning full access off
    /// revokes that link with the grant), or `nil` in restricted mode.
    func fullAccessLinkSource(observerSessionID: UUID) -> DomainDelegationScopeRecord? {
        guard waives(.linkRequired) else { return nil }
        return scopes?.ensureGlobalAutoApproveScope(for: observerSessionID)
    }

    /// `linkCapabilityCeiling` for existing links: under full access every link the observer has is
    /// authorized at every capability. The engine issues revocable evidence the link authority reads
    /// (`linkCapabilityElevation`); the stored link is never upgraded, and restricted mode revokes it.
    /// `issue == false` only reports whether the elevation applies now.
    func elevatesLinkCapabilities(observerSessionID: UUID, issue: Bool = true) -> Bool {
        guard waives(.linkCapabilityCeiling) else { return false }
        if issue { linkCapabilityElevation.elevate(observer: observerSessionID) }
        return linkCapabilityElevation.isElevated(observer: observerSessionID)
    }

    /// The commit fence for a link established from `fullAccessLinkSource`.
    func isFullAccessLinkSourceCurrent(_ scopeID: UUID) -> Bool {
        waives(.linkRequired) && scopes?.record(id: scopeID)?.isActive == true
    }
}

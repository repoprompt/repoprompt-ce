import Foundation

/// Canonical operation identities for Agent-session control and direct-link oversight.
///
/// Target-bearing `agent_run` / `agent_manage` operations are authorized below. Target-bearing
/// `agent_session_link` operations use these identities to select a capability, but their actual
/// generation-qualified authorization and lease come from `DomainAgentSessionLinkAuthority`.
/// `monitorList` is the one targetless identity and uses `authorizeObserverScoped` below.
package enum DomainAgentSessionTargetOperation: String, CaseIterable, Hashable, Sendable {
    case runPoll = "agent_run.poll"
    case runWait = "agent_run.wait"
    case runCancel = "agent_run.cancel"
    case runSteer = "agent_run.steer"
    case runRespond = "agent_run.respond"

    case manageList = "agent_manage.list_sessions"
    case manageGetLog = "agent_manage.get_log"
    case manageExtractHandoff = "agent_manage.extract_handoff"
    case manageResume = "agent_manage.resume_session"
    case manageStop = "agent_manage.stop_session"
    case manageCleanup = "agent_manage.cleanup_sessions"

    case monitorList = "agent_session_link.list"
    case monitorCreateLane = "agent_session_link.create_lane"
    case monitorRetireLane = "agent_session_link.retire_lane"
    case monitorPoll = "agent_session_link.poll"
    case monitorWait = "agent_session_link.wait"
    case monitorRead = "agent_session_link.read"
    case monitorSend = "agent_session_link.send"
    /// Native compaction of one exact idle target, under its existing send grant.
    case monitorCompact = "agent_session_link.compact"
    /// Observer-local Auto-wake admission policy for one exact outbound lane.
    ///
    /// It names a target because the policy is per-lane, but it never reaches that target: nothing
    /// about the overseen session is read, written, resumed, or notified. The authority it needs is
    /// therefore the plain read grant the observer already holds over that lane.
    case monitorSnoozeAutoWake = "agent_session_link.snooze_auto_wake"
    /// Answers the target's exact current pending prompt on the user's behalf.
    case monitorRespond = "agent_session_link.respond"
    /// Steers the target: injects an instruction into its active run or starts its next turn.
    case monitorSteer = "agent_session_link.steer"
    /// Cancels one exact target's current run or pending start under a Manage grant.
    case monitorStop = "agent_session_link.stop"
    case monitorSetModel = "agent_session_link.set_model"
    /// Rebinds or unbinds one exact target's execution worktree through `manage_worktree`
    /// (`bind` / `select` / `unbind`, or `create` with `bind=true`) under a Manage grant.
    ///
    /// It is not an `agent_session_link` operation, but an Agent caller that is neither the target
    /// itself nor its spawn parent may redirect the target's checkout only with the user's
    /// management delegation over that exact target.
    case monitorWorktreeBinding = "manage_worktree.binding"

    package enum Family: String, Hashable, Sendable {
        /// Existing spawn-provenance control and read operations.
        case sessionControl = "session_control"
        /// New user-granted oversight operations.
        case monitor
    }

    package var family: Family {
        switch self {
        case .runPoll, .runWait, .runCancel, .runSteer, .runRespond,
             .manageList, .manageGetLog, .manageExtractHandoff,
             .manageResume, .manageStop, .manageCleanup:
            .sessionControl
        case .monitorList, .monitorCreateLane, .monitorRetireLane, .monitorPoll, .monitorWait, .monitorRead, .monitorSend, .monitorCompact,
             .monitorSnoozeAutoWake, .monitorRespond, .monitorSteer, .monitorStop, .monitorSetModel,
             .monitorWorktreeBinding:
            .monitor
        }
    }

    /// True when the operation names no target at all and is authorized against the caller's own
    /// grant set instead of a per-target proof.
    package var isObserverScoped: Bool {
        switch self {
        case .monitorList, .monitorCreateLane:
            true
        case .monitorRetireLane, .monitorPoll, .monitorWait, .monitorRead, .monitorSend, .monitorCompact,
             .monitorSnoozeAutoWake, .monitorRespond, .monitorSteer, .monitorStop, .monitorSetModel,
             .monitorWorktreeBinding,
             .runPoll, .runWait, .runCancel, .runSteer, .runRespond,
             .manageList, .manageGetLog, .manageExtractHandoff,
             .manageResume, .manageStop, .manageCleanup:
            false
        }
    }

    /// The exact oversight capability a target-bearing oversight operation requires.
    ///
    /// `monitorList` is deliberately absent: it names no target, so requiring an arbitrary target's
    /// capability proof would either invent a target or authorize the wrong one.
    package var requiredMonitorCapability: DomainAgentSessionLinkCapability? {
        switch self {
        case .monitorPoll, .monitorSnoozeAutoWake:
            .poll
        case .monitorWait:
            .wait
        case .monitorRead:
            .read
        case .monitorSend, .monitorCompact:
            .sendWhenIdle
        case .monitorRespond, .monitorSteer, .monitorStop, .monitorSetModel, .monitorRetireLane,
             .monitorWorktreeBinding:
            .manage
        case .monitorList, .monitorCreateLane,
             .runPoll, .runWait, .runCancel, .runSteer, .runRespond,
             .manageList, .manageGetLog, .manageExtractHandoff,
             .manageResume, .manageStop, .manageCleanup:
            nil
        }
    }

    /// True when the operation mutates or resumes target state rather than only reading it.
    package var mutatesTarget: Bool {
        switch self {
        case .runCancel, .runSteer, .runRespond, .manageResume, .manageStop, .manageCleanup, .monitorSend, .monitorCompact,
             .monitorRespond, .monitorSteer, .monitorStop, .monitorSetModel, .monitorRetireLane,
             .monitorWorktreeBinding:
            true
        case .runPoll, .runWait, .manageList, .manageGetLog, .manageExtractHandoff,
             .monitorList, .monitorCreateLane, .monitorPoll, .monitorWait, .monitorRead,
             .monitorSnoozeAutoWake:
            false
        }
    }
}

/// Non-spoofable caller classification.
///
/// It is derived from server-owned run routing (`RequestMetadata` → connection purpose → exact
/// run-installed/handover/pending-run tab context), never from tool arguments.
package enum DomainAgentSessionCallerIdentity: Hashable, Sendable {
    /// A non-Agent principal operating through explicitly routed window control.
    case administrativePrincipal
    /// An Agent Mode run whose exact run-scoped session identity resolved.
    case agentSession(UUID)
    /// An Agent Mode run whose routing could not be resolved exactly. Always fails closed.
    case unresolvedAgentRun

    package var agentSessionID: UUID? {
        guard case let .agentSession(sessionID) = self else { return nil }
        return sessionID
    }

    package var isAgentOrigin: Bool {
        switch self {
        case .agentSession, .unresolvedAgentRun:
            true
        case .administrativePrincipal:
            false
        }
    }
}

/// Immutable spawn provenance of the requested target.
///
/// `unknown` is used when provenance could not be established authoritatively; it never authorizes an
/// Agent-origin caller.
package enum DomainAgentSessionTargetProvenance: Hashable, Sendable {
    case known(targetSessionID: UUID, parentSessionID: UUID?)
    case unknown(targetSessionID: UUID)

    package var targetSessionID: UUID {
        switch self {
        case let .known(targetSessionID, _), let .unknown(targetSessionID):
            targetSessionID
        }
    }

    package var parentSessionID: UUID? {
        guard case let .known(_, parentSessionID) = self else { return nil }
        return parentSessionID
    }
}

/// An oversight grant presented by the link authority. Never accepted from tool arguments.
package struct DomainAgentSessionMonitorGrantProof: Hashable, Sendable {
    package let linkID: UUID
    package let generation: UInt64
    package let capability: DomainAgentSessionLinkCapability
    package let observerSessionID: UUID
    package let targetSessionID: UUID

    package init(
        linkID: UUID,
        generation: UInt64,
        capability: DomainAgentSessionLinkCapability,
        observerSessionID: UUID,
        targetSessionID: UUID
    ) {
        self.linkID = linkID
        self.generation = generation
        self.capability = capability
        self.observerSessionID = observerSessionID
        self.targetSessionID = targetSessionID
    }

    package init(lease: DomainAgentSessionLinkLease) {
        self.init(
            linkID: lease.linkID,
            generation: lease.linkGeneration,
            capability: lease.capability,
            observerSessionID: lease.observer.sessionID,
            targetSessionID: lease.target.sessionID
        )
    }
}

package enum DomainAgentSessionAuthorityBasis: Hashable, Sendable {
    case administrativePrincipal
    case directSpawnProvenance(parentSessionID: UUID)
    case monitorGrant(linkID: UUID, generation: UInt64, capability: DomainAgentSessionLinkCapability)
    /// The caller's own non-empty outbound grant set, used only by targetless oversight operations.
    case observerGrantSet
}

/// Denial reasons are diagnostic only. Callers must surface one indistinguishable user-facing message
/// so an Agent-origin caller cannot probe whether an unauthorized UUID exists.
package enum DomainAgentSessionAuthorizationDenial: String, Error, Equatable, Sendable {
    case callerRoutingUnresolved = "caller_routing_unresolved"
    case targetProvenanceUnknown = "target_provenance_unknown"
    case notDirectChild = "not_direct_child"
    case selfTarget = "self_target"
    case missingMonitorGrant = "missing_monitor_grant"
    case monitorGrantObserverMismatch = "monitor_grant_observer_mismatch"
    case monitorGrantTargetMismatch = "monitor_grant_target_mismatch"
    case monitorCapabilityMismatch = "monitor_capability_mismatch"
    case monitorRequiresAgentCaller = "monitor_requires_agent_caller"
    /// A targetless operation was routed through the target-bearing decision path, or vice versa.
    case observerScopedOperation = "observer_scoped_operation"
    case targetScopedOperation = "target_scoped_operation"
    case noActiveOutboundLink = "no_active_outbound_link"
    case noActiveLink = "no_active_link"
}

package enum DomainAgentSessionAuthorizationDecision: Equatable, Sendable {
    case authorized(DomainAgentSessionAuthorityBasis)
    case denied(DomainAgentSessionAuthorizationDenial)

    package var isAuthorized: Bool {
        guard case .authorized = self else { return false }
        return true
    }

    package var basis: DomainAgentSessionAuthorityBasis? {
        guard case let .authorized(basis) = self else { return nil }
        return basis
    }

    package var denial: DomainAgentSessionAuthorizationDenial? {
        guard case let .denied(denial) = self else { return nil }
        return denial
    }
}

/// Discovery scope for targetless enumeration operations such as `agent_manage.list_sessions`.
package enum DomainAgentSessionDiscoveryScope: Hashable, Sendable {
    case unrestricted
    case directChildren(of: UUID)
    case none
}

/// Execution-time authority for `agent_run` / `agent_manage` target operations and the targetless
/// `agent_session_link.list` inventory gate.
///
/// It is intentionally pure: routing, identity resolution, and target provenance lookup happen in the
/// app layer, and only their results reach this decision function. Nothing here consults tool
/// arguments, tool advertisement, window location, or UUID syntax.
///
/// Target-bearing `agent_session_link` calls do not enter this type in production. They are
/// authorized by `DomainAgentSessionLinkAuthority`, whose generation-qualified lease is also the
/// suspension fence. The monitor cases remain here as shared operation/capability vocabulary and for
/// pure policy parity tests; only `monitorList` uses this authorizer on the live oversight path.
package enum DomainAgentSessionOperationAuthorizer {
    package static func authorize(
        operation: DomainAgentSessionTargetOperation,
        caller: DomainAgentSessionCallerIdentity,
        target: DomainAgentSessionTargetProvenance,
        monitorGrant: DomainAgentSessionMonitorGrantProof? = nil
    ) -> DomainAgentSessionAuthorizationDecision {
        guard !operation.isObserverScoped else {
            // `authorizeObserverScoped` is the only correct path for a targetless operation.
            return .denied(.observerScopedOperation)
        }
        switch operation.family {
        case .monitor:
            return authorizeMonitorOperation(
                operation: operation,
                caller: caller,
                target: target,
                monitorGrant: monitorGrant
            )
        case .sessionControl:
            return authorizeSessionControlOperation(caller: caller, target: target)
        }
    }

    /// Authorizes a targetless oversight operation against the caller's own grant set.
    ///
    /// `list` requires an outbound link; `create_lane` accepts either direction. Neither
    /// operation may use another caller's identity or infer a grant from catalog visibility.
    package static func authorizeObserverScoped(
        operation: DomainAgentSessionTargetOperation,
        caller: DomainAgentSessionCallerIdentity,
        hasActiveOutboundLink: Bool,
        hasActiveInboundLink: Bool = false
    ) -> DomainAgentSessionAuthorizationDecision {
        guard operation.isObserverScoped else {
            return .denied(.targetScopedOperation)
        }
        guard caller.agentSessionID != nil else {
            return .denied(.monitorRequiresAgentCaller)
        }
        switch operation {
        case .monitorList where hasActiveOutboundLink:
            return .authorized(.observerGrantSet)
        case .monitorCreateLane where hasActiveOutboundLink || hasActiveInboundLink:
            return .authorized(.observerGrantSet)
        case .monitorCreateLane:
            return .denied(.noActiveLink)
        default:
            return .denied(.noActiveOutboundLink)
        }
    }

    /// Enumeration scope for Agent-origin discovery. Agent callers may only see sessions they
    /// directly spawned, so an unrelated sibling cannot be discovered before a target operation.
    package static func discoveryScope(
        for caller: DomainAgentSessionCallerIdentity
    ) -> DomainAgentSessionDiscoveryScope {
        switch caller {
        case .administrativePrincipal:
            .unrestricted
        case let .agentSession(sessionID):
            .directChildren(of: sessionID)
        case .unresolvedAgentRun:
            .none
        }
    }

    // MARK: - Private

    private static func authorizeSessionControlOperation(
        caller: DomainAgentSessionCallerIdentity,
        target: DomainAgentSessionTargetProvenance
    ) -> DomainAgentSessionAuthorizationDecision {
        // An oversight grant is never a valid authority basis for an existing control operation.
        switch caller {
        case .administrativePrincipal:
            return .authorized(.administrativePrincipal)
        case .unresolvedAgentRun:
            return .denied(.callerRoutingUnresolved)
        case let .agentSession(callerSessionID):
            guard case let .known(targetSessionID, parentSessionID) = target else {
                return .denied(.targetProvenanceUnknown)
            }
            guard targetSessionID != callerSessionID else {
                return .denied(.selfTarget)
            }
            guard let parentSessionID, parentSessionID == callerSessionID else {
                return .denied(.notDirectChild)
            }
            return .authorized(.directSpawnProvenance(parentSessionID: callerSessionID))
        }
    }

    private static func authorizeMonitorOperation(
        operation: DomainAgentSessionTargetOperation,
        caller: DomainAgentSessionCallerIdentity,
        target: DomainAgentSessionTargetProvenance,
        monitorGrant: DomainAgentSessionMonitorGrantProof?
    ) -> DomainAgentSessionAuthorizationDecision {
        // Spawn provenance never silently creates an oversight link, and administrative routing never
        // substitutes for the user's explicit grant.
        guard let callerSessionID = caller.agentSessionID else {
            return .denied(.monitorRequiresAgentCaller)
        }
        guard let monitorGrant else {
            return .denied(.missingMonitorGrant)
        }
        guard monitorGrant.observerSessionID == callerSessionID else {
            return .denied(.monitorGrantObserverMismatch)
        }
        guard monitorGrant.targetSessionID == target.targetSessionID else {
            return .denied(.monitorGrantTargetMismatch)
        }
        guard let requiredCapability = operation.requiredMonitorCapability,
              monitorGrant.capability == requiredCapability
        else {
            return .denied(.monitorCapabilityMismatch)
        }
        return .authorized(.monitorGrant(
            linkID: monitorGrant.linkID,
            generation: monitorGrant.generation,
            capability: monitorGrant.capability
        ))
    }
}

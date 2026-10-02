import Foundation

// Exact endpoint discovery and restoration readiness for oversight links.
//
// Owns the binding-qualified hydration proof (`AgentSessionRestorationReadiness`), the discovery
// epoch that fences a candidate snapshot, the `AgentSessionLinkEndpointCandidate` value, the typed
// resolve failures, and the resolver that maps a session UUID or endpoint onto exactly one live,
// generation-bearing candidate. `AgentSessionLinkRuntimeBridge` calls it on every operation and
// `AgentSessionOversightLaunchCoordinator` waits on its readiness before restoring durable intents.
// Invariant: resolution fails closed — a session UUID reused by a rebind, replacement, or namesake
// never resolves to a retired incarnation, and a candidate is offered only once its binding proof
// matches the current transition generation.

// MARK: - Restoration readiness

/// The exact binding a hydration proof was recorded against.
///
/// Both halves matter. The binding identity carries its own `generation`, so an in-place rebind to
/// the same session UUID produces a different identity; the transition generation additionally
/// separates two attempts at the *same* binding, which is what a cancelled-then-retried hydration
/// looks like.
package struct AgentSessionRestorationBindingToken: Equatable, Hashable {
    package let bindingIdentity: AgentPersistentSessionBindingIdentity
    package let bindingTransitionGeneration: UInt64

    package init(bindingIdentity: AgentPersistentSessionBindingIdentity, bindingTransitionGeneration: UInt64) {
        self.bindingIdentity = bindingIdentity
        self.bindingTransitionGeneration = bindingTransitionGeneration
    }
}

/// Binding-qualified hydration outcome, used by automatic restoration and fresh lane Add.
///
/// `hasLoadedPersistedState` cannot serve this purpose: it is a completion latch, and a missing
/// payload, a superseded source revision, and a thrown load error all set it true. Reauthorizing a
/// saved link from that flag would grant against a session whose transcript never loaded.
///
/// Launch-level persistence suppression is deliberately **not** a failure here: it means restoration
/// is unavailable, not that this session's payload is gone.
package enum AgentSessionRestorationReadiness: Equatable {
    package enum Source: Equatable {
        /// A persisted payload committed in full.
        case persistedPayloadApplied
        /// A session created this launch whose first durable session-file write succeeded.
        case freshBindingDurablyCreated
    }

    package enum Failure: Equatable {
        case missingPayload
        case loadFailed
        case sourceRevisionSuperseded
    }

    /// No durable binding to prove anything about.
    case unbound
    case pending(AgentSessionRestorationBindingToken)
    case authoritative(AgentSessionRestorationBindingToken, Source)
    case terminal(AgentSessionRestorationBindingToken, Failure)

    package var bindingToken: AgentSessionRestorationBindingToken? {
        switch self {
        case .unbound: nil
        case let .pending(token), let .authoritative(token, _), let .terminal(token, _): token
        }
    }

    package var isAuthoritative: Bool {
        if case .authoritative = self { return true }
        return false
    }

    package var terminalFailure: Failure? {
        if case let .terminal(_, failure) = self { return failure }
        return nil
    }
}

// MARK: - Restoration establishment proof

/// The exact incarnations and binding-qualified hydration outcomes carried into an Add.
///
/// Manual Add carries none of this: pasting a UUID keeps the resolver's existing behaviour. Automatic
/// restoration and fresh lane creation differ, because they are authorized on a proof read at
/// classification time and every authority hop between then and activation is a chance for that
/// endpoint to rebind, go terminal, or be replaced by an incarnation whose legacy
/// `hasLoadedPersistedState` latch is true while its proof is pending or terminal. Carrying the proof
/// into the shared establishment path — rather than letting that path re-derive readiness with the
/// resolver's manual-Add rules — is what makes those fences comparable at all.
package struct AgentSessionOversightRestorationProof: Equatable {
    package let observerEndpoint: DomainAgentSessionLinkEndpointIdentity
    package let targetEndpoint: DomainAgentSessionLinkEndpointIdentity
    package let observerReadiness: AgentSessionRestorationReadiness
    package let targetReadiness: AgentSessionRestorationReadiness
    package let requireObserverAuthoritative: Bool

    /// Restoration requires two authoritative proofs. Fresh lane creation can instead carry the
    /// observer's exact current readiness while requiring the target's fresh-save proof.
    package init?(
        observer: AgentSessionLinkEndpointCandidate,
        target: AgentSessionLinkEndpointCandidate,
        requireObserverAuthoritative: Bool = true
    ) {
        guard !requireObserverAuthoritative || observer.restorationReadiness.isAuthoritative,
              target.restorationReadiness.isAuthoritative
        else {
            return nil
        }
        observerEndpoint = observer.domainEndpoint
        targetEndpoint = target.domainEndpoint
        observerReadiness = observer.restorationReadiness
        targetReadiness = target.restorationReadiness
        self.requireObserverAuthoritative = requireObserverAuthoritative
    }

    /// Restoration keeps both complete readiness outcomes; lane creation tolerates an observer's
    /// pending-to-authoritative transition only when its exact endpoint and binding token persist.
    package func matches(
        observer: AgentSessionLinkEndpointCandidate,
        target: AgentSessionLinkEndpointCandidate
    ) -> Bool {
        observer.domainEndpoint == observerEndpoint
            && target.domainEndpoint == targetEndpoint
            && (
                observer.restorationReadiness == observerReadiness
                    || (
                        !requireObserverAuthoritative
                            && isObserverHydrationAdvance(observer.restorationReadiness)
                    )
            )
            && target.restorationReadiness == targetReadiness
    }

    private func isObserverHydrationAdvance(_ current: AgentSessionRestorationReadiness) -> Bool {
        guard case let .pending(before) = observerReadiness,
              case let .authoritative(after, _) = current
        else { return false }
        return before == after
    }

    /// Whether both proved incarnations are still present in one live candidate snapshot.
    ///
    /// Read from a single snapshot so the two endpoints can never be proved against different
    /// MainActor passes.
    package func matches(liveCandidates: [AgentSessionLinkEndpointCandidate]) -> Bool {
        guard let observer = liveCandidates.first(where: { $0.domainEndpoint == observerEndpoint }),
              let target = liveCandidates.first(where: { $0.domainEndpoint == targetEndpoint })
        else {
            return false
        }
        return matches(observer: observer, target: target)
    }
}

// MARK: - Discovery epoch

/// Opaque level snapshot of one window's binding discovery.
///
/// Deliberately not `SessionIndexOwner`: oversight only needs to know *which* level a completion
/// belongs to, so a stale workspace owner's late completion can be discarded without oversight
/// learning anything about session-index ownership.
package struct AgentSessionLinkDiscoveryEpoch: Hashable {
    package let windowID: Int
    package let workspaceID: UUID?
    package let generation: UInt64

    package init(windowID: Int, workspaceID: UUID?, generation: UInt64) {
        self.windowID = windowID
        self.workspaceID = workspaceID
        self.generation = generation
    }
}

package struct AgentSessionLinkDiscoveryState: Equatable {
    package let epoch: AgentSessionLinkDiscoveryEpoch
    package let isComplete: Bool

    package init(epoch: AgentSessionLinkDiscoveryEpoch, isComplete: Bool) {
        self.epoch = epoch
        self.isComplete = isComplete
    }
}

/// Identity-only description of one compose-tab binding in an active workspace.
///
/// This exists so a launch-loaded intent can tell "that session is present but its tab has not been
/// visited yet" apart from "that session is not open anywhere", **without** hydrating the tab. It
/// therefore carries nothing that would require reading a transcript.
package struct AgentSessionLinkComposeTabDescriptor: Hashable {
    package let windowID: Int
    package let workspaceID: UUID
    package let tabID: UUID
    package let sessionID: UUID

    package init(windowID: Int, workspaceID: UUID, tabID: UUID, sessionID: UUID) {
        self.windowID = windowID
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.sessionID = sessionID
    }
}

// MARK: - Candidate

/// Value snapshot of one live compose-tab/session binding, taken on MainActor without focusing,
/// activating, or switching the owning window.
///
/// This is deliberately a plain value: resolution is a pure decision over the full candidate set so
/// the "exactly one live eligible top-level match" rule can be tested without constructing windows.
package struct AgentSessionLinkEndpointCandidate: Equatable {
    package let windowID: Int
    package let workspaceID: UUID
    package let tabID: UUID
    package let sessionID: UUID
    package let persistentBindingGeneration: UUID?
    package let bindingTransitionGeneration: UInt64
    /// `parentSessionID == nil`. Child sessions are never overseeable endpoints.
    package let isTopLevel: Bool
    package let hasLoadedPersistedState: Bool
    package let bindingTransitionInProgress: Bool
    /// The owning window or tab is closing, or the session is being deleted.
    package let isClosing: Bool
    /// Mirrors the existing execution-location disqualifiers: an externally MCP-controlled or
    /// MCP-originated session may be a target but never an observer.
    package let isMCPControlled: Bool
    package let isMCPOriginated: Bool
    /// Whether the canonical tool policy would advertise `agent_session_link` to this session's
    /// effective role. Computed from the catalog, never assumed.
    package let roleAllowsOutboundMonitoring: Bool
    /// Compose-tab name, used for UI preview and (byte-capped) agent-facing display names.
    package let displayName: String?
    package let providerDisplayName: String?
    /// Workspace/worktree label for **UI only**. It is never placed in an agent-facing snapshot,
    /// inventory, or prompt.
    package let locationLabel: String?

    /// Binding-qualified hydration proof, already resolved against this candidate's *current*
    /// binding state by its owning window.
    ///
    /// Consumed only by automatic restoration. Manual Add keeps using the resolver's existing
    /// `hasLoadedPersistedState` gate, so pasting a UUID behaves exactly as before.
    package var restorationReadiness: AgentSessionRestorationReadiness = .unbound

    /// Whether a durable deletion of this session has begun or committed.
    ///
    /// Carried *beside* `isClosing`, never folded into it: a closing tab or window is permanent,
    /// while a deletion attempt can fail and restore the session unchanged. Everything that revokes
    /// or retires must key off the committed tombstone instead.
    package var isDeletionInProgress: Bool = false

    package init(
        windowID: Int,
        workspaceID: UUID,
        tabID: UUID,
        sessionID: UUID,
        persistentBindingGeneration: UUID?,
        bindingTransitionGeneration: UInt64,
        isTopLevel: Bool,
        hasLoadedPersistedState: Bool,
        bindingTransitionInProgress: Bool,
        isClosing: Bool,
        isMCPControlled: Bool,
        isMCPOriginated: Bool,
        roleAllowsOutboundMonitoring: Bool,
        displayName: String?,
        providerDisplayName: String?,
        locationLabel: String?,
        restorationReadiness: AgentSessionRestorationReadiness = .unbound,
        isDeletionInProgress: Bool = false
    ) {
        self.windowID = windowID
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.sessionID = sessionID
        self.persistentBindingGeneration = persistentBindingGeneration
        self.bindingTransitionGeneration = bindingTransitionGeneration
        self.isTopLevel = isTopLevel
        self.hasLoadedPersistedState = hasLoadedPersistedState
        self.bindingTransitionInProgress = bindingTransitionInProgress
        self.isClosing = isClosing
        self.isMCPControlled = isMCPControlled
        self.isMCPOriginated = isMCPOriginated
        self.roleAllowsOutboundMonitoring = roleAllowsOutboundMonitoring
        self.displayName = displayName
        self.providerDisplayName = providerDisplayName
        self.locationLabel = locationLabel
        self.restorationReadiness = restorationReadiness
        self.isDeletionInProgress = isDeletionInProgress
    }

    package var eligibilityInput: AgentSessionLinkEndpointEligibility.Input {
        AgentSessionLinkEndpointEligibility.Input(
            hasDurableBinding: persistentBindingGeneration != nil,
            hasLoadedPersistedState: hasLoadedPersistedState,
            isChildSession: !isTopLevel,
            isMCPControlled: isMCPControlled,
            isMCPOriginated: isMCPOriginated,
            bindingTransitionInProgress: bindingTransitionInProgress,
            isClosing: isClosing,
            isDeletionInProgress: isDeletionInProgress
        )
    }

    /// Falls back to the short ID so a nameless tab still renders a stable, non-empty row label.
    package var resolvedDisplayName: String {
        let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? AgentMonitorSessionIDFormatter.short(sessionID) : trimmed
    }

    /// Domain endpoint DTO for this exact incarnation.
    ///
    /// `persistentBindingGeneration` stays optional so an unexpected `nil` fails closed in the
    /// authority rather than comparing equal to another unbound endpoint.
    package var domainEndpoint: DomainAgentSessionLinkEndpointIdentity {
        DomainAgentSessionLinkEndpointIdentity(
            windowID: windowID,
            workspaceID: workspaceID,
            tabID: tabID,
            sessionID: sessionID,
            persistentBindingGeneration: persistentBindingGeneration,
            bindingTransitionGeneration: bindingTransitionGeneration
        )
    }
}

// MARK: - Failures

/// Fail-closed resolution outcomes. Every case maps to one specific inline popover message; none of
/// them leaks whether an unresolvable UUID exists somewhere the user cannot see.
package enum AgentSessionLinkResolveFailure: String, Error, Equatable {
    case malformedIdentifier = "malformed_identifier"
    case notFound = "not_found"
    case ambiguous
    case loading
    case rebinding
    case closing
    case childSession = "child_session"
    case bindingUnresolved = "binding_unresolved"
    case selfMonitor = "self_monitor"
    case alreadyMonitoring = "already_monitoring"

    package var uiMessage: String {
        switch self {
        case .malformedIdentifier:
            "That isn’t a valid session ID. Paste the full ID copied from a session."
        case .notFound:
            "No open eligible session has this ID."
        case .ambiguous:
            "That session is open in more than one window. Close the duplicate before overseeing it."
        case .loading:
            "That session is still loading. Try again in a moment."
        case .rebinding:
            "That session is changing its binding. Try again in a moment."
        case .closing:
            "That session is closing."
        case .childSession:
            "Child sessions can’t be overseen."
        case .bindingUnresolved:
            "That session doesn’t have a durable binding yet."
        case .selfMonitor:
            "This session can’t oversee itself."
        case .alreadyMonitoring:
            "You’re already overseeing this session."
        }
    }
}

// MARK: - Resolver

/// Pure, fail-closed resolution of a pasted canonical UUID to exactly one live top-level endpoint.
///
/// Ambiguity is never silently resolved: two live bindings for the same session ID mean the app has
/// two candidate incarnations and neither may be granted.
package enum AgentSessionLinkEndpointResolver {
    /// Parses only a canonical UUID. Short aliases and routing URLs are rejected by construction.
    package static func parseSessionID(_ raw: String) -> UUID? {
        UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    package static func resolve(
        sessionID: UUID,
        candidates: [AgentSessionLinkEndpointCandidate]
    ) -> Result<AgentSessionLinkEndpointCandidate, AgentSessionLinkResolveFailure> {
        let matches = candidates.filter { $0.sessionID == sessionID }
        guard !matches.isEmpty else { return .failure(.notFound) }
        guard matches.count == 1 else { return .failure(.ambiguous) }
        let match = matches[0]
        if let failure = AgentSessionLinkEndpointEligibility.targetResolveFailure(for: match) {
            return .failure(failure)
        }
        return .success(match)
    }
}

// MARK: - Endpoint eligibility

/// Shared eligibility predicate for both endpoints of an oversight link.
///
/// Copy Session ID, the Oversee popover's Add button, and the runtime bridge all consult this so a
/// row can never offer an ID that the resolver would immediately reject.
package enum AgentSessionLinkEndpointEligibility {
    package struct Input: Equatable {
        package var hasDurableBinding: Bool
        package var hasLoadedPersistedState: Bool
        package var isChildSession: Bool
        package var isMCPControlled: Bool
        package var isMCPOriginated: Bool
        package var bindingTransitionInProgress: Bool
        package var isClosing: Bool
        /// A durable deletion is running for this session.
        ///
        /// Deliberately separate from `isClosing`: a closing tab or window is permanent, whereas a
        /// deletion attempt can fail and leave the session exactly as it was. Folding the two
        /// together made a failed delete permanently disqualifying, which revoked live grants and
        /// deleted the saved rows behind them for a transcript that still exists.
        package var isDeletionInProgress: Bool

        package init(
            hasDurableBinding: Bool,
            hasLoadedPersistedState: Bool,
            isChildSession: Bool,
            isMCPControlled: Bool,
            isMCPOriginated: Bool,
            bindingTransitionInProgress: Bool,
            isClosing: Bool,
            isDeletionInProgress: Bool = false
        ) {
            self.hasDurableBinding = hasDurableBinding
            self.hasLoadedPersistedState = hasLoadedPersistedState
            self.isChildSession = isChildSession
            self.isMCPControlled = isMCPControlled
            self.isMCPOriginated = isMCPOriginated
            self.bindingTransitionInProgress = bindingTransitionInProgress
            self.isClosing = isClosing
            self.isDeletionInProgress = isDeletionInProgress
        }
    }

    /// Shown when a compose tab has no durable top-level binding yet. The popover may still open so
    /// the control stays discoverable; only Add is disabled.
    package static let noDurableBindingReason = "Send a first message to start this session, then add sessions to oversee."

    /// Shown when the effective role/tool policy denies outbound oversight.
    package static let roleDeniedReason = "This session can’t oversee other sessions."

    /// A target only has to be a live, exactly-bound, top-level session. It does **not** need
    /// outbound observer-operation eligibility, because being observed grants no outbound authority.
    ///
    /// Ordered so the most specific, most actionable reason wins. The UUID resolver owns not-found
    /// and ambiguity, then delegates its unique candidate here; exact sidebar projection and Add
    /// revalidation call the same candidate-local helper without ever choosing between incarnations.
    package static func targetResolveFailure(
        for candidate: AgentSessionLinkEndpointCandidate
    ) -> AgentSessionLinkResolveFailure? {
        targetResolveFailure(for: candidate.eligibilityInput)
    }

    /// Boolean compatibility for consumers that only need offerability. It is intentionally a thin
    /// view of the same ordered failure helper rather than a second target predicate.
    package static func isEligibleTarget(_ input: Input) -> Bool {
        targetResolveFailure(for: input) == nil
    }

    private static func targetResolveFailure(for input: Input) -> AgentSessionLinkResolveFailure? {
        // Keep this precedence synchronized with the user-facing resolver contract.
        if input.isChildSession { return .childSession }
        if input.isClosing { return .closing }
        // Transient: a running deletion refuses a new link without implying permanent endpoint loss.
        if input.isDeletionInProgress { return .closing }
        if input.bindingTransitionInProgress { return .rebinding }
        if !input.hasLoadedPersistedState { return .loading }
        if !input.hasDurableBinding { return .bindingUnresolved }
        return nil
    }

    /// Whether a live observer may still exercise an existing grant.
    ///
    /// A grant is created against an eligible observer, but eligibility is not frozen at creation:
    /// a session can later be attached to external MCP control, and role/tool policy can change. The
    /// endpoint identity does not change when that happens, so identity revalidation alone would let
    /// a now-ineligible session keep operating an old grant.
    package enum OperationEligibility: Equatable {
        /// The observer may proceed.
        case eligible
        /// A momentary state (hydrating, rebinding). Deny this operation but keep the grant: the
        /// endpoint is still the same session and is expected to settle.
        case transientlyUnavailable
        /// The observer permanently lost the capability. Revoke its outbound grants, then deny.
        case disqualified
    }

    /// Re-checks an existing grant's observer against the same disqualifiers that gate Add.
    ///
    /// Transient and permanent losses are separated deliberately: revoking on a binding transition
    /// would destroy a healthy link every time the target's user reloads a thread, while *not*
    /// revoking on MCP capture would leave an oversight capability attached to a session the user
    /// no longer drives.
    package static func observerOperationEligibility(
        _ input: Input,
        roleAllowsOutboundMonitoring: Bool
    ) -> OperationEligibility {
        if input.isChildSession
            || input.isMCPControlled
            || input.isMCPOriginated
            || !roleAllowsOutboundMonitoring
            || input.isClosing
        {
            return .disqualified
        }
        // A running deletion denies the operation and keeps the grant. Only a *committed* deletion is
        // permanent, and that arrives as a UUID-wide invalidation of its own rather than as an
        // eligibility loss inferred from an attempt that may still fail.
        if input.isDeletionInProgress
            || input.bindingTransitionInProgress
            || !input.hasDurableBinding
            || !input.hasLoadedPersistedState
        {
            return .transientlyUnavailable
        }
        return .eligible
    }

    /// Observer eligibility reuses the exact disqualifiers already enforced for execution-location
    /// mutation (`mcpControlContext != nil || isMCPOriginated || parentSessionID != nil`) and adds
    /// the durable-binding requirement plus the effective role/tool-policy gate.
    ///
    /// - Parameter roleAllowsOutboundMonitoring: whether the effective task-role/tool policy permits
    ///   `agent_session_link` for this session. Callers pass the live policy once the tool exists in
    ///   the catalog; until then a user-driven top-level session is permitted.
    package static func addDisabledReason(
        _ input: Input,
        roleAllowsOutboundMonitoring: Bool
    ) -> String? {
        if input.isClosing {
            return "This session is closing."
        }
        if input.isDeletionInProgress {
            return "This session is being deleted."
        }
        if input.isChildSession || input.isMCPControlled || input.isMCPOriginated {
            return roleDeniedReason
        }
        if !roleAllowsOutboundMonitoring {
            return roleDeniedReason
        }
        if input.bindingTransitionInProgress {
            return "This session is changing its binding. Try again in a moment."
        }
        if !input.hasDurableBinding {
            return noDurableBindingReason
        }
        if !input.hasLoadedPersistedState {
            return "Load this thread before adding sessions to oversee."
        }
        return nil
    }
}

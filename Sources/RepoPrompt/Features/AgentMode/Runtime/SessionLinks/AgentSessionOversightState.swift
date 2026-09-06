import Foundation
import RepoPromptDomainRuntime

/// Every oversight-subsystem value one exact `AgentTabSession` incarnation owns, in one place.
///
/// The Auto-wake coordinator, the per-lane snooze policy, failure suppression, and the
/// target-declared waiting context were layered onto the tab session one at a time; this struct is
/// their single mutation surface so the valid-state space is visible at a glance rather than spread
/// across unrelated stored properties. It coordinates with `AgentModeViewModel+SessionLinkAutoWake`
/// (which reads and writes the wake and snooze fields), `AgentModeViewModel+SessionLinks` (durable
/// selection and `waitingOn`), and `AgentSessionLinkDeliveryReadiness` (which snapshots
/// `hasPendingAutoWake`). Everything here is `@MainActor`-bound through its owning session; no new
/// isolation domain is introduced.
///
/// Two invariants are worth naming. Only the durable selection pair is ever persisted; every other
/// field is process-local and dies with the incarnation, which is what lets a rebind, relink, or
/// relaunch start unsnoozed and unsuppressed. And the reserved wake attempt is a single slot rather
/// than a queue: the `.cancelledBeforeDispatch` tombstone that fences an in-flight provider call
/// lives in that same slot (see `pendingAutoWakeOwnsTransportBoundary`), so nothing may clear it
/// except a path that can prove no transport call happened.
struct AgentSessionOversightState {
    // MARK: Durable Auto-wake selection

    /// Master Auto-wake preference, persisted with the session. New sessions default on and remain
    /// inert while overseeing nothing; restoration replaces this creation default with the durable
    /// saved value.
    var autoWakeOnUpdates: Bool = true
    /// Granular target UUIDs; preserved while the master setting is enabled.
    var autoWakeTargetSessionIDs: Set<UUID> = []

    // MARK: Reserved wake attempt

    /// The one automatic lane-update follow-up this exact incarnation has reserved, if any.
    ///
    /// Ephemeral by construction: it lives beside the run lifecycle it competes with, is never
    /// persisted, and dies with the incarnation. Appearing or clearing feeds the owning session's
    /// observation signal, because another observer must not `send` into a session that has already
    /// reserved a turn.
    var pendingAutoWake: AgentSessionLinkAutoWakeAttempt?

    /// Whether one queue publication was absorbed while the current Auto-wake could not schedule a
    /// reevaluation of its own.
    ///
    /// Ephemeral and one-shot. A safe attempt release drains it through the ordinary gated
    /// publication entry point; an accepted attempt discards it because applying that claim's
    /// receipt immediately republishes whatever remains owed.
    var autoWakeReevaluationOwed = false

    /// The one structural wake shape this incarnation already failed to deliver, if any.
    ///
    /// Suppression rather than backoff: there is no timer and no retry loop, so a known
    /// pre-acceptance failure simply parks that exact shape until a structurally new edge,
    /// generation, or overflow arrives — or the user cycles the setting.
    ///
    /// A single slot rather than an accumulating set, and that is load-bearing rather than tidiness:
    /// the fingerprint carries per-edge occurrence identity, so a shape that has been superseded can
    /// never recur. Keeping only the current one means suppression is released by exactly the events
    /// that should release it — the failed content being acknowledged, removed, or replaced by a
    /// genuinely new transition — instead of surviving indefinitely in a set nothing prunes.
    var suppressedWakeFingerprint: AgentSessionLinkPassiveStatusNotices.WakeEligibilityFingerprint?

    // MARK: Per-lane snooze policy

    /// Temporary per-lane Auto-wake suppression owned by *this exact* observer incarnation.
    ///
    /// Ephemeral in the strongest sense: absent from every Codable/save/restore model, never marking
    /// the session dirty, never scheduling persistence, and bounded by the observer's current
    /// outbound link references. Keyed by endpoint *and* generation-qualified reference so a rebind,
    /// an unlink/relink, or a namesake replacement can never inherit a predecessor's policy.
    ///
    /// Content changes feed the owning session's observation signal, because the monitor renders
    /// the active subrow from it. Task/token changes deliberately do not: they publish no
    /// user-visible state.
    var autoWakeSnoozes: [AgentSessionLinkAutoWakeSnoozeKey: AgentSessionLinkAutoWakeSnoozeRecord] = [:]

    /// The single nearest-deadline task for this session, plus the never-reused token that fences it.
    ///
    /// One task rather than one per record: a replacement always cancels its predecessor, and the
    /// token is what makes a cancelled-but-already-resumed callback fail closed instead of expiring a
    /// record the newer arming is responsible for.
    var snoozeDeadlineTask: Task<Void, Never>?
    var snoozeTaskToken: UUID?
    /// Injected monotonic seam. Production is `ContinuousClock`; tests advance it explicitly.
    var snoozeClock: AgentSessionLinkAutoWakeSnoozeClock = .continuous

    // MARK: Target-declared context

    /// Ephemeral, agent-declared dependency metadata shared with current inbound observers.
    var waitingOn: DomainAgentSessionWaitingOn?

    // MARK: Derived

    /// Whether routine status and overflow from this lane may admit a wake under the durable
    /// selection: the master setting covers every lane, and a granular selection covers its own.
    ///
    /// This is the one rule the wake coordinator admits lanes by and the dashboard overlays
    /// `isEffectivelySelected` from. It says nothing about snooze or purposeful attention; those are
    /// layered on top in `AgentModeViewModel+SessionLinkAutoWake`.
    func isLaneEffectivelySelected(targetSessionID: UUID) -> Bool {
        autoWakeOnUpdates || autoWakeTargetSessionIDs.contains(targetSessionID)
    }

    /// The exact lane references currently snoozed for this observer, evaluated against the
    /// monotonic clock rather than dictionary membership.
    ///
    /// An elapsed record is inactive here whether or not the deadline task has removed it yet, so a
    /// delayed task can never keep a lane suppressed past its own deadline.
    func activeSnoozedReferences(
        observerEndpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> Set<DomainAgentSessionLinkReference> {
        guard !autoWakeSnoozes.isEmpty else { return [] }
        let now = snoozeClock.now()
        return Set(
            autoWakeSnoozes.values
                .filter { $0.key.observerEndpoint == observerEndpoint && $0.isActive(at: now) }
                .map(\.key.reference)
        )
    }

    /// The nearest strictly-future snooze deadline for this observer, if any.
    ///
    /// Strictly-future only, which is what guarantees the deadline handler makes progress: after its
    /// cleanup, every remaining record is still ahead of `now`.
    func nextActiveSnoozeDeadline(
        observerEndpoint: DomainAgentSessionLinkEndpointIdentity,
        now: ContinuousClock.Instant
    ) -> ContinuousClock.Instant? {
        autoWakeSnoozes.values
            .filter { $0.key.observerEndpoint == observerEndpoint && $0.isActive(at: now) }
            .map(\.deadline)
            .min()
    }

    /// Whether this incarnation has reserved its one automatic follow-up.
    ///
    /// The nil/non-nil transition is the only part of the attempt an outside observer can act on;
    /// attempt-internal churn does not change what an overseeing caller may do.
    var hasPendingAutoWake: Bool {
        pendingAutoWake != nil
    }

    /// Whether the reserved attempt currently owns the provider transport boundary.
    ///
    /// True in `.preparingDispatch`, `.cancelledBeforeDispatch`, and `.dispatching`. This is the
    /// single predicate behind the dispatch-ID rewrite that fences an in-flight Auto-wake
    /// (`agentSessionLinkEffectiveDispatchID`, `dispatchRequiresLaneBatch`) and behind the
    /// Codex catalog-repair quiescence gate: a wake that may already own a physical call must not
    /// have its provider retired underneath it, and must not lose the rewrite that fences it.
    var pendingAutoWakeOwnsTransportBoundary: Bool {
        pendingAutoWake?.phase.ownsTransportBoundary ?? false
    }

    // MARK: Mutation

    /// Cancels the deadline task and drops every snooze record.
    ///
    /// Retirement, never transfer: an endpoint that is going away must not leave a task that could
    /// resume against the incarnation replacing it.
    mutating func retireSnoozeState() {
        snoozeDeadlineTask?.cancel()
        snoozeDeadlineTask = nil
        snoozeTaskToken = nil
        autoWakeSnoozes.removeAll()
    }
}

extension AgentSessionLinkAutoWakeAttempt.Phase {
    /// Whether an attempt in this phase may already have crossed, or be about to cross, the provider
    /// transport boundary.
    ///
    /// `.scheduled` and `.awaitingSettlement` own no provider boundary and can be retired freely.
    /// The other three are the fence: preparation may acquire at any moment, a tombstone keeps the
    /// dispatch-ID rewrite alive until preparation's finalizer proves no call happened, and
    /// dispatching may already be in flight.
    var ownsTransportBoundary: Bool {
        switch self {
        case .preparingDispatch, .cancelledBeforeDispatch, .dispatching:
            true
        case .scheduled, .awaitingSettlement:
            false
        }
    }
}

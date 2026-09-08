import Combine
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
/// Two invariants are worth naming. Only the durable preferences — selection, routine limiting, and
/// periodic idle waking — are ever persisted; every other field is process-local and dies with
/// the incarnation, which is what lets a rebind or relaunch start unsnoozed, unsuppressed, and
/// untimed. (Within one incarnation the wake stamp is observer-scoped, so unlinking and relinking a
/// target does not reset it.) And the reserved wake attempt is a single slot rather than a queue: the
/// `.cancelledBeforeDispatch` tombstone that fences an in-flight provider call lives in that same
/// slot (see `pendingAutoWakeOwnsTransportBoundary`), so nothing may clear it except a path that can
/// prove no transport call happened.
struct AgentSessionOversightState {
    // MARK: Durable Auto-wake selection

    /// Master Auto-wake preference, persisted with the session. New sessions default on and remain
    /// inert while overseeing nothing; restoration replaces this creation default with the durable
    /// saved value.
    var autoWakeOnUpdates: Bool = true
    /// Granular target UUIDs; preserved while the master setting is enabled.
    var autoWakeTargetSessionIDs: Set<UUID> = []

    // MARK: Durable routine wake interval

    /// Minimum spacing between *routine* automatic wakes. Off by default; exact purposeful attention
    /// and the user's own `Wake now` bypass it without changing it.
    var routineWakeIntervalEnabled: Bool = false
    /// The chosen interval, retained while limiting is off. Read through
    /// `normalizedRoutineWakeIntervalSeconds`: a decoded value is never trusted raw.
    var routineWakeIntervalSeconds: Int = AgentSessionLinkRoutineWakeInterval.defaultSeconds

    /// Durable periodic-idle policy only; storing or restoring it does not arm a wake.
    var periodicIdleWakeEnabled: Bool = false
    var periodicIdleWakeIntervalSeconds: Int = AgentSessionLinkPeriodicWakeInterval.defaultSeconds

    /// Scheduling only: execution is owned by the existing pendingAutoWake slot.
    var periodicEndpoint: DomainAgentSessionLinkEndpointIdentity?
    var periodicObservation: AnyCancellable?
    var periodicIdleSince: ContinuousClock.Instant?
    var periodicDeadline: ContinuousClock.Instant?
    var periodicDeadlineToken: UUID?
    var periodicDeadlineTask: Task<Void, Never>?

    mutating func invalidatePeriodicIdleSpan() {
        periodicDeadlineTask?.cancel()
        periodicDeadlineTask = nil
        periodicDeadlineToken = nil
        periodicDeadline = nil
        periodicIdleSince = nil
    }

    mutating func retirePeriodicScheduling() {
        invalidatePeriodicIdleSpan()
        periodicObservation = nil
        periodicEndpoint = nil
    }

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
    ///
    /// Shared with the routine wake interval, which arms the same slot; `nextAutoWakeDeadline` picks
    /// whichever comes first.
    var snoozeDeadlineTask: Task<Void, Never>?
    var snoozeTaskToken: UUID?
    /// Injected monotonic seam. Production is `ContinuousClock`; tests advance it explicitly.
    var snoozeClock: AgentSessionLinkAutoWakeSnoozeClock = .continuous

    // MARK: Ephemeral wake timing

    /// The last physical oversight dispatch this incarnation acquired — routine, attention, or
    /// manual alike, and recorded even while limiting is off so enabling it measures from the wake
    /// that actually happened. Monotonic, so a clock change moves the display and never admission.
    var lastOversightWakeDispatch: AgentSessionLinkOversightWakeDispatch?

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

    /// The chosen interval, clamped to the approved options.
    var normalizedRoutineWakeIntervalSeconds: Int {
        AgentSessionLinkRoutineWakeInterval.normalized(routineWakeIntervalSeconds)
    }

    /// When routine status and overflow may next admit a wake, or `nil` when nothing delays them.
    ///
    /// Endpoint-qualified, so a retired incarnation's stamp fails open exactly like a missing one.
    func routineWakeIntervalDeadline(
        observerEndpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> ContinuousClock.Instant? {
        guard routineWakeIntervalEnabled,
              let stamp = lastOversightWakeDispatch,
              stamp.observerEndpoint == observerEndpoint
        else {
            return nil
        }
        return stamp.instant.advanced(by: .seconds(normalizedRoutineWakeIntervalSeconds))
    }

    /// The strictly-future deadline currently deferring routine admission, or `nil`.
    ///
    /// An elapsed interval is inactive whether or not the deadline task has fired, exactly like an
    /// elapsed snooze record.
    func routineWakeIntervalDeferral(
        observerEndpoint: DomainAgentSessionLinkEndpointIdentity,
        now: ContinuousClock.Instant
    ) -> ContinuousClock.Instant? {
        guard let deadline = routineWakeIntervalDeadline(observerEndpoint: observerEndpoint),
              deadline > now
        else {
            return nil
        }
        return deadline
    }

    /// The earliest observer-policy deadline that owes one reevaluation, snooze or interval.
    func nextAutoWakeDeadline(
        observerEndpoint: DomainAgentSessionLinkEndpointIdentity,
        now: ContinuousClock.Instant,
        includeRoutineInterval: Bool
    ) -> ContinuousClock.Instant? {
        let snooze = nextActiveSnoozeDeadline(observerEndpoint: observerEndpoint, now: now)
        guard includeRoutineInterval,
              let interval = routineWakeIntervalDeferral(observerEndpoint: observerEndpoint, now: now)
        else {
            return snooze
        }
        guard let snooze else { return interval }
        return min(snooze, interval)
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

    /// Cancels the shared deadline task and drops every observer-local policy record, including the
    /// wake stamp.
    ///
    /// Retirement, never transfer: an endpoint that is going away must not leave a task that could
    /// resume against the incarnation replacing it.
    mutating func retireSnoozeState() {
        snoozeDeadlineTask?.cancel()
        snoozeDeadlineTask = nil
        snoozeTaskToken = nil
        autoWakeSnoozes.removeAll()
        lastOversightWakeDispatch = nil
    }
}

/// One physical oversight dispatch, qualified by the exact incarnation that acquired it, so a rebind
/// cannot inherit its predecessor's timing.
struct AgentSessionLinkOversightWakeDispatch: Equatable {
    let observerEndpoint: DomainAgentSessionLinkEndpointIdentity
    let instant: ContinuousClock.Instant
}

/// The approved routine-wake interval durations and the one normalization every writer shares —
/// decode paths, the durable setter, restoration, and the picker.
///
/// Ceiling to an approved option: a stored 61 becomes 5 minutes rather than 1, and anything past the
/// largest option is capped rather than rejected.
enum AgentSessionLinkRoutineWakeInterval {
    static let optionsSeconds = [60, 300, 600, 900, 1800, 3600, 10800]
    static let defaultSeconds = 300
    static let maximumSeconds = 10800

    static func normalized(_ seconds: Int) -> Int {
        for option in optionsSeconds where option >= seconds {
            return option
        }
        return maximumSeconds
    }
}

/// Approved periodic-idle durations. Unsupported values round up to the next option, capped at six hours.
enum AgentSessionLinkPeriodicWakeInterval {
    static let optionsSeconds = [600, 1800, 3600, 7200, 21600]
    static let defaultSeconds = 1800
    static let maximumSeconds = 21600

    static func normalized(_ seconds: Int) -> Int {
        for option in optionsSeconds where option >= seconds {
            return option
        }
        return maximumSeconds
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

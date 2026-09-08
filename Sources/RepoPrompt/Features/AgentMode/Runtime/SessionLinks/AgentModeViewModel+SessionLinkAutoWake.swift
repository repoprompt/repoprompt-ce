import Foundation

// The wake coordinator: temporary admission policy for one observer's automatic lane-update turns.
//
// Owns the single reserved `AgentSessionLinkAutoWakeAttempt` slot on each `AgentTabSession.oversight`,
// the admission decision (`AgentSessionLinkWakeAdmissionDecision`), failure suppression, the
// per-lane snooze mutation/expiry bookkeeping, and the physical-dispatch acquisition fence. It owns
// no authority, no queue, and no prompt text: `DomainAgentSessionLinkAuthority` decides grants,
// `AgentSessionLinkPassiveStatusNotices` is the canonical queue it reads, and
// `AgentSessionLinkPromptContext` renders the immutable claim it reserves before any provider call.
// Invariants worth reading twice: snooze suppresses routine *admission*, never delivery; exact
// purposeful attention bypasses selection and snooze but no other gate; and a
// `.cancelledBeforeDispatch` tombstone is a transport fence, not dead state — only a path that can
// prove no transport call happened may release it, and `cancelAgentSessionLinkAutoWake` is not
// idempotent across phases.

// MARK: - Attempt state

/// The single automatic lane-update follow-up one exact observer incarnation may reserve.
///
/// Deliberately tiny. It stores an identity, a position in the queue, a phase, and a cancellable
/// task — never entries, previews, or overflow details. The bridge-owned reducer stays the only
/// authority on what the turn will actually say, so a scheduled wake can never ship a stale payload
/// it captured at scheduling time.
enum AgentSessionLinkPhysicalDispatchOutcome: Equatable {
    /// The dispatch was retracted before its provider transport boundary.
    case notAttempted
    /// The provider's existing acceptance signal settled the claim.
    case accepted
    /// The physical call began, but no definitive acceptance or rejection was observed.
    case ambiguous
}

struct AgentSessionLinkAutoWakeAttempt {
    enum Phase: Equatable {
        /// Gates passed; waiting for the observer to become dispatchable.
        case scheduled
        /// Parked behind an active run, a terminal commit, or an accepted successor.
        case awaitingSettlement
        /// The coordinator is preparing provider input, but no physical call is owned yet.
        case preparingDispatch
        /// Preparation lost ownership; retained only to make every late provider seam fail closed.
        case cancelledBeforeDispatch
        /// The provider call may be in flight. A local user send no longer cancels it.
        case dispatching
    }

    let wakeID: UUID
    let observerEndpoint: DomainAgentSessionLinkEndpointIdentity
    struct QueueEvidence {
        let epoch: UUID
        var revision: UInt64
        var fingerprint: AgentSessionLinkPassiveStatusNotices.WakeEligibilityFingerprint
    }

    /// Periodic admission has no queue evidence. Notification admission always supplies it.
    var queue: QueueEvidence?
    var queueEpoch: UUID? {
        queue?.epoch
    }

    var wakeFingerprint: AgentSessionLinkPassiveStatusNotices.WakeEligibilityFingerprint? {
        queue?.fingerprint
    }

    /// Captured producer identity, independent of whether a supplement was owed.
    var periodicProducerDispatchID: AgentSessionLinkPromptDispatchID?
    var periodicStartReturned = false
    var periodicComposerAttemptID: UUID?
    var periodicProducerTask: Task<Void, Never>?
    /// Why this attempt was admitted: ordinary routine content, one exact purposeful-attention
    /// occurrence, or the user's own one-shot `Wake now`.
    ///
    /// Selected immediately before the claim is reserved. Once preparation begins it is left alone;
    /// the immutable claim, not later queue absorption, decides what the physical call attempted.
    ///
    /// Stored rather than re-derived because every later gate evaluates the *same* basis the
    /// reservation was made under, and a manual basis has no queue state that could recover it.
    var admissionBasis: AgentSessionLinkWakeAdmissionDecision.Basis
    /// Frozen only at the physical boundary, so a later edge can never be suppressed as though it
    /// had been included in already-immutable provider text.
    var attemptedFingerprint: AgentSessionLinkPassiveStatusNotices.WakeEligibilityFingerprint?
    var physicalOutcome: AgentSessionLinkPhysicalDispatchOutcome
    var phase: Phase
    var task: Task<Void, Never>?

    /// The exact occurrence whose routine-policy exception this attempt requires, or `nil` for a
    /// routine or manual basis. Projection of `admissionBasis`, never a second stored truth.
    var requiredAttentionOccurrence:
        AgentSessionLinkPassiveStatusNotices.AttentionOccurrenceIdentity?
    {
        admissionBasis.requiredAttentionOccurrence
    }

    /// Whether the user's own `Wake now` reserved this attempt.
    var isManual: Bool {
        admissionBasis == .manual
    }

    var isPeriodic: Bool {
        admissionBasis == .periodic
    }

    init(
        wakeID: UUID,
        observerEndpoint: DomainAgentSessionLinkEndpointIdentity,
        queueEpoch: UUID?,
        queueRevision: UInt64,
        wakeFingerprint: AgentSessionLinkPassiveStatusNotices.WakeEligibilityFingerprint?,
        admissionBasis: AgentSessionLinkWakeAdmissionDecision.Basis,
        attemptedFingerprint: AgentSessionLinkPassiveStatusNotices.WakeEligibilityFingerprint?,
        physicalOutcome: AgentSessionLinkPhysicalDispatchOutcome,
        phase: Phase,
        task: Task<Void, Never>?
    ) {
        self.wakeID = wakeID
        self.observerEndpoint = observerEndpoint
        if let queueEpoch, let wakeFingerprint {
            queue = QueueEvidence(epoch: queueEpoch, revision: queueRevision, fingerprint: wakeFingerprint)
        }
        self.admissionBasis = admissionBasis
        self.attemptedFingerprint = attemptedFingerprint
        self.physicalOutcome = physicalOutcome
        self.phase = phase
        self.task = task
    }

    var queueRevision: UInt64 {
        queue?.revision ?? 0
    }
}

/// Why an unaccepted attempt was released.
enum AgentSessionLinkAutoWakeCancellationReason: String {
    case settingDisabled = "setting_disabled"
    case endpointInvalidated = "endpoint_invalidated"
    case queueCleared = "queue_cleared"
    case naturalDeliveryWon = "natural_delivery_won"
    case localUserWon = "local_user_won"
    case eligibilityLost = "eligibility_lost"
    case shutdown
    /// The required lane claim disappeared before any provider call could begin.
    case requiredClaimUnavailable = "required_claim_unavailable"

    /// Whether this reason definitively proves that no physical provider call occurred.
    ///
    /// Queue changes do not prove that once dispatch ownership has been acquired: a natural receipt,
    /// unlink, or transient publication can race a suspended provider call. Only the dispatch path's
    /// own pre-call refusal or definitive return may release that identity.
    var definitivelyNoPhysicalCall: Bool {
        switch self {
        case .requiredClaimUnavailable: true
        default: false
        }
    }
}

// MARK: - Admission decision

/// The one answer the wake coordinator gives a fresh queue publication: may this lane state start an
/// automatic turn right now, and if not, which gate said no.
///
/// Read top-down, the pipeline is three questions in a fixed order:
///
/// 1. **Basis** — is there a selected, unsnoozed routine status entry, admissible unattributed
///    overflow, or one exact pending purposeful-attention occurrence? Attention is the named
///    bypass of master Auto-wake, that lane's own toggle, and that lane's snooze; it changes none of
///    them and broadens nothing else.
/// 2. **Suppression** — is that basis exactly the structural shape a prior attempt already failed?
/// 3. **Prompt eligibility** — can the observer's provider context carry a supplement at all?
///
/// Hitchhikers are deliberately outside this decision. A snoozed or unselected lane's coalesced rows
/// ride along in whatever claim an admitted wake, or a turn the observer's own user started, renders
/// (`AgentSessionLinkAutoWakeAdmission.routineLaneAdmits` is the predicate that tells the two
/// apart at the physical fence); this type answers only whether a turn may start.
enum AgentSessionLinkWakeAdmissionDecision: Equatable {
    enum Basis: Equatable {
        /// A selected, unsnoozed lane has a pending status entry, or unattributed overflow may wake
        /// on its own.
        case routineStatusOrOverflow
        /// One exact pending purposeful-attention occurrence admits in spite of master Auto-wake,
        /// that lane's own toggle, that lane's snooze, and the routine wake interval — without
        /// changing any of them. The occurrence is frozen onto the attempt so preparation and
        /// physical acquisition can fail closed if it stops being pending under the exact current
        /// grant.
        case purposefulAttention(AgentSessionLinkPassiveStatusNotices.AttentionOccurrenceIdentity)
        /// The observer's own user asked for pending updates to be processed now.
        ///
        /// Ignores routine selection, snooze, the interval, and failure suppression for this attempt
        /// only, changing none of them; every hard gate still applies, and the permission dies with
        /// the attempt.
        case manual
        /// A due idle timer, never inferred from queue content.
        case periodic
    }

    /// Raw values are the DEBUG gate-log vocabulary, single-sourced here.
    enum SuppressionReason: String, Equatable {
        /// No selected, unsnoozed routine content and no exact attention occurrence.
        case noAdmissionBasis = "blocked.noAdmissionBasis"
        /// The only basis is the exact structural shape already parked in failure suppression.
        case failureSuppressed = "suppressed"
        /// Routine content would admit, but this observer's minimum routine wake interval has not
        /// elapsed. Reported only when nothing else would have refused the wake anyway.
        case routineIntervalDeferred = "blocked.routineInterval"
        /// The observer's provider context cannot carry a supplement right now.
        case promptIneligible = "blocked.ineligible"
    }

    case admit(Basis)
    case suppress(SuppressionReason)
}

extension AgentSessionLinkWakeAdmissionDecision.Basis {
    /// What the reserved attempt must carry: the exact occurrence for an attention-admitted wake,
    /// nothing for a routine or manual one.
    var requiredAttentionOccurrence: AgentSessionLinkPassiveStatusNotices.AttentionOccurrenceIdentity? {
        switch self {
        case .routineStatusOrOverflow, .manual, .periodic: nil
        case let .purposefulAttention(occurrence): occurrence
        }
    }
}

// MARK: - Coordinator

@MainActor
extension AgentModeViewModel {
    /// Endpoint-addressed scheduling hint, driven by every authoritative queue publication.
    ///
    /// There is no timer and no event bus: a dropped publication is recovered by the next complete
    /// projection refresh, which is the same invariant that lets the reducer skip polling.
    func agentSessionLinkNoteAutoWakeOpportunity(
        _ snapshot: AgentSessionLinkPassiveStatusNotices.Snapshot,
        endpoint: DomainAgentSessionLinkEndpointIdentity
    ) {
        guard let session = agentSessionLinkAutoWakeSession(for: endpoint) else { return }

        // The explicit snooze cleanup boundary, ahead of every read of the map: due records are
        // removed, references this snapshot no longer carries are pruned, and the one nearest-deadline
        // task is re-armed. This publication *is* the reevaluation the cleanup owes, so nothing here
        // re-enters the pipeline — a recursive submission would be a second evaluation of one edge.
        agentSessionLinkReconcileAutoWakeSnoozes(
            endpoint: endpoint,
            session: session,
            currentReferences: Set(snapshot.autoWakeLanes.map(\.reference))
        )

        if let attempt = session.oversight.pendingAutoWake,
           attempt.isPeriodic,
           attempt.observerEndpoint == endpoint
        {
            session.oversight.autoWakeReevaluationOwed = true
            agentSessionLinkFenceAutoWakeSelectionChange(for: endpoint)
            return
        }

        // Content gone: a natural turn claimed it, or membership moved. Release the reservation
        // without a transcript row — nothing was ever delivered under this wake's name.
        guard snapshot.isDeliverable, snapshot.hasDeliverableContent else {
            // Once content is acknowledged or removed, an old failure must not suppress a later
            // independent edge with the same shape. A dispatching attempt retains its identity until
            // its own physical outcome settles; `cancel` deliberately refuses this queue-side race.
            session.oversight.suppressedWakeFingerprint = nil
            if session.oversight.pendingAutoWake?.phase != .cancelledBeforeDispatch {
                cancelAgentSessionLinkAutoWake(for: endpoint, reason: .naturalDeliveryWon)
            }
            return
        }

        let fingerprint = snapshot.wakeEligibilityFingerprint
        // Manual permission belongs only to the attempt's original endpoint and queue epoch.
        let reservationBasis = session.oversight.pendingAutoWake.flatMap { attempt in
            attempt.observerEndpoint == endpoint && attempt.queueEpoch == snapshot.queueEpoch
                ? attempt.admissionBasis : nil
        }
        let admission = agentSessionLinkAutoWakeAdmission(
            snapshot,
            session: session,
            endpoint: endpoint,
            basis: reservationBasis
        )
        let requiredAttentionOccurrence = admission.requiredAttentionOccurrence(
            fingerprint: fingerprint,
            suppressed: session.oversight.suppressedWakeFingerprint
        )
        let hasUnsuppressedAdmissionBasis = admission.hasUnsuppressedAdmissionBasis(
            fingerprint: fingerprint,
            suppressed: session.oversight.suppressedWakeFingerprint
        )

        // A tombstoned attempt is deliberately *not* retired here, however dead it looks.
        //
        // It is the fence. Providers do not mint the wake's dispatch ID — they use their own, and
        // `agentSessionLinkEffectiveDispatchID` rewrites it to the wake's only while an attempt exists
        // in `.preparingDispatch`, `.cancelledBeforeDispatch`, or `.dispatching`. Clearing the
        // tombstone while a provider path is still preparing would make that rewrite stop firing, so
        // `agentSessionLinkAcquirePhysicalDispatch` would take its ordinary-dispatch early return and
        // wave the call through unfenced — delivering lane content with no claim, admission basis, or
        // provenance row. The reevaluation this publication owes is replayed once the tombstone's
        // own finalizer settles instead; see `agentSessionLinkAwaitPhysicalDispatchSettlement`.

        // One attempt absorbs newer revisions. A metadata-only revision deliberately does not clear a
        // failed attempt's suppression, so improving payload fidelity cannot re-trigger a provider
        // that already refused.
        if var attempt = session.oversight.pendingAutoWake {
            if attempt.observerEndpoint != endpoint || attempt.queueEpoch != snapshot.queueEpoch {
                if agentSessionLinkAutoWakeAttemptCanScheduleReevaluation(attempt) {
                    // A scheduled/parked attempt owns no provider boundary. Retire it and let this
                    // same publication continue through the empty-slot path below, so a one-shot
                    // attention in the replacement epoch does not need a second publication.
                    cancelAgentSessionLinkAutoWake(
                        for: attempt.observerEndpoint,
                        reason: .endpointInvalidated
                    )
                } else {
                    // Preparation/transport still owns the old identity. Keep (or install) its
                    // fence, and remember that the replacement publication must be evaluated once a
                    // provable release occurs.
                    session.oversight.autoWakeReevaluationOwed = true
                    if attempt.phase != .cancelledBeforeDispatch {
                        cancelAgentSessionLinkAutoWake(
                            for: attempt.observerEndpoint,
                            reason: .endpointInvalidated
                        )
                    }
                    return
                }
            } else {
                let revision = max(attempt.queueRevision, snapshot.queueRevision)
                attempt.queue?.revision = revision
                attempt.queue?.fingerprint = fingerprint
                if agentSessionLinkAutoWakeAttemptCanScheduleReevaluation(attempt), !attempt.isManual {
                    // Do not let a required attention basis disappear into the mutable status
                    // attempt race unless a genuinely unsuppressed ordinary basis replaced it.
                    // Pure status attempts keep the mutable behavior they had before purposeful
                    // attention existed. A manual basis is never rewritten by absorption: nothing in
                    // the queue can recover the user's request, and downgrading it would silently
                    // re-apply the policy the click bypassed.
                    if requiredAttentionOccurrence != nil
                        || attempt.requiredAttentionOccurrence == nil
                        || hasUnsuppressedAdmissionBasis
                    {
                        attempt.admissionBasis = requiredAttentionOccurrence
                            .map(AgentSessionLinkWakeAdmissionDecision.Basis.purposefulAttention)
                            ?? .routineStatusOrOverflow
                    }
                }
                session.oversight.pendingAutoWake = attempt
                // Unlike automatic admission, a manual one-shot cancels rather than parking if
                // readiness is lost. Preserve publications it absorbs for ordinary reevaluation.
                if attempt.isManual || !agentSessionLinkAutoWakeAttemptCanScheduleReevaluation(attempt) {
                    session.oversight.autoWakeReevaluationOwed = true
                }
                // Immediate reevaluation rather than leaving it to the run loop: a snooze installed while
                // this attempt was scheduled must retract it here if it was the attempt's only basis, and
                // must leave it alone when another unsnoozed lane still admits. `cancel` owns the phase
                // rules — `.preparingDispatch` becomes `.cancelledBeforeDispatch`, `.dispatching` is never
                // touched.
                guard admission.hasAdmissionBasis else {
                    // A tombstone is *already* cancelled, and cancelling it again is not idempotent:
                    // `cancel` only converts `.preparingDispatch` into a tombstone, so a second call
                    // falls through and clears the slot outright — which deletes the dispatch-ID rewrite
                    // that keeps a still-preparing provider path fenced. Losing the basis twice is the
                    // ordinary case here, not an exotic one: the snoozed lane publishing again, an
                    // extension, or even a repeated `already_snoozed` re-drives this path while the
                    // tombstone stands. Leave the release to the finalizer that can prove no transport
                    // call happened.
                    if attempt.phase != .cancelledBeforeDispatch {
                        cancelAgentSessionLinkAutoWake(for: endpoint, reason: .eligibilityLost)
                    }
                    agentSessionLinkLogAutoWakeGate(
                        endpoint,
                        fingerprint,
                        "absorbed.basisLost"
                    )
                    return
                }
                agentSessionLinkScheduleAutoWakeReevaluation(wakeID: attempt.wakeID, endpoint: endpoint)
                agentSessionLinkLogAutoWakeGate(endpoint, fingerprint, "absorbed")
                return
            }
        }

        let admittedBasis: AgentSessionLinkWakeAdmissionDecision.Basis
        switch agentSessionLinkWakeAdmissionDecision(admission, fingerprint: fingerprint, session: session) {
        case let .suppress(reason):
            agentSessionLinkLogAutoWakeGate(endpoint, fingerprint, reason.rawValue)
            return
        case let .admit(basis):
            admittedBasis = basis
        }

        agentSessionLinkReserveAutoWakeAttempt(
            basis: admittedBasis,
            snapshot: snapshot,
            endpoint: endpoint,
            session: session
        )
    }

    /// Reserves this incarnation's one attempt and schedules its first evaluation.
    ///
    /// The single construction site for a wake identity, shared by ordinary admission and `Wake now`.
    /// Not a second dispatch path: everything after scheduling is the existing pipeline, evaluated
    /// under the basis recorded here.
    private func agentSessionLinkReserveAutoWakeAttempt(
        basis: AgentSessionLinkWakeAdmissionDecision.Basis,
        snapshot: AgentSessionLinkPassiveStatusNotices.Snapshot,
        endpoint: DomainAgentSessionLinkEndpointIdentity,
        session: TabSession
    ) {
        let attempt = AgentSessionLinkAutoWakeAttempt(
            wakeID: UUID(),
            observerEndpoint: endpoint,
            queueEpoch: snapshot.queueEpoch,
            queueRevision: snapshot.queueRevision,
            wakeFingerprint: snapshot.wakeEligibilityFingerprint,
            admissionBasis: basis,
            attemptedFingerprint: nil,
            physicalOutcome: .notAttempted,
            phase: .scheduled,
            task: nil
        )
        session.oversight.pendingAutoWake = attempt
        agentSessionLinkScheduleAutoWakeReevaluation(wakeID: attempt.wakeID, endpoint: endpoint)
        agentSessionLinkLogAutoWakeGate(
            endpoint,
            snapshot.wakeEligibilityFingerprint,
            basis == .manual ? "scheduled.manual" : "scheduled"
        )
    }

    /// Releases an unaccepted attempt. Never retracts a provider call that may already be in flight.
    func cancelAgentSessionLinkAutoWake(
        for endpoint: DomainAgentSessionLinkEndpointIdentity,
        reason: AgentSessionLinkAutoWakeCancellationReason
    ) {
        guard let session = sessions[endpoint.tabID],
              let attempt = session.oversight.pendingAutoWake,
              attempt.observerEndpoint == endpoint
        else {
            return
        }
        // Past the ownership boundary the physical call may already have happened, so an "ambiguous
        // cancellation" would be a lie in both directions. Let it settle instead — unless this is one
        // of the coordinator's own pre-dispatch decisions, which provably retracts nothing.
        guard attempt.phase != .dispatching || reason.definitivelyNoPhysicalCall else { return }
        if attempt.phase == .cancelledBeforeDispatch, !reason.definitivelyNoPhysicalCall { return }
        if attempt.phase == .preparingDispatch, !reason.definitivelyNoPhysicalCall {
            // Preparation owns the only finalizer that can prove the transport was never called.
            // Mark cancellation intent, but do not cancel that finalizer out from under the attempt.
            var cancelledAttempt = attempt
            cancelledAttempt.phase = .cancelledBeforeDispatch
            session.oversight.pendingAutoWake = cancelledAttempt
            agentSessionLinkLogAutoWakeGate(
                endpoint,
                attempt.wakeFingerprint,
                "cancelled.preDispatch.\(reason.rawValue)"
            )
            return
        }
        attempt.task?.cancel()
        session.oversight.pendingAutoWake = nil
        // The dashboard renders "a wake is already pending" from this slot, so its disappearance has
        // to reach the pill in the same step the slot is cleared.
        requestUIRefresh(tabID: endpoint.tabID)
        agentSessionLinkLogAutoWakeGate(endpoint, attempt.wakeFingerprint, "cancelled.\(reason.rawValue)")
        // Periodic and manual reservations can absorb attention before preparation starts.
        // Once definitively released, they must return that opportunity to automatic admission.
        if attempt.isPeriodic || attempt.isManual {
            agentSessionLinkDrainAutoWakeReevaluationIfOwed(session: session)
        }
    }

    /// Clears suppression so an explicit off/on cycle can retry a known failure.
    ///
    /// Suppression is the only thing it clears. Admission still has to come from somewhere — a
    /// selected, unsnoozed routine basis or exact purposeful-attention occurrence — so this can retry
    /// a known failure but cannot manufacture a wake out of a queue that has nothing new in it.
    func agentSessionLinkClearAutoWakeSuppression(for endpoint: DomainAgentSessionLinkEndpointIdentity) {
        sessions[endpoint.tabID]?.oversight.suppressedWakeFingerprint = nil
    }

    // MARK: Dispatch

    func agentSessionLinkScheduleAutoWakeReevaluation(
        wakeID: UUID,
        endpoint: DomainAgentSessionLinkEndpointIdentity
    ) {
        guard let session = agentSessionLinkAutoWakeSession(for: endpoint),
              var attempt = session.oversight.pendingAutoWake,
              attempt.wakeID == wakeID,
              attempt.phase == .scheduled || attempt.phase == .awaitingSettlement,
              attempt.task == nil
        else {
            return
        }
        attempt.task = Task { @MainActor [weak self] in
            await self?.agentSessionLinkRunAutoWake(wakeID: wakeID, endpoint: endpoint)
        }
        session.oversight.pendingAutoWake = attempt
    }

    private func agentSessionLinkAutoWakeAttemptCanScheduleReevaluation(
        _ attempt: AgentSessionLinkAutoWakeAttempt
    ) -> Bool {
        attempt.phase == .scheduled || attempt.phase == .awaitingSettlement
    }

    private func agentSessionLinkRunAutoWake(
        wakeID: UUID,
        endpoint: DomainAgentSessionLinkEndpointIdentity
    ) async {
        while !Task.isCancelled {
            guard let session = agentSessionLinkAutoWakeSession(for: endpoint),
                  let attempt = session.oversight.pendingAutoWake,
                  attempt.wakeID == wakeID
            else {
                return
            }
            guard agentSessionLinkAutoWakeAttemptIsStillEligible(attempt, session: session) else {
                cancelAgentSessionLinkAutoWake(for: endpoint, reason: .eligibilityLost)
                return
            }

            if attempt.isPeriodic {
                await agentSessionLinkRunPeriodicAttempt(attempt, session: session)
                return
            }
            guard let route = agentSessionLinkAutoWakeRoute(session) else {
                // A manual reservation is a one-shot answer to "can this run right now?", which the
                // entry point already answered. If the observer stopped being dispatchable before
                // preparation, release it rather than parking it: the user would otherwise get a
                // silent wake at an unpredictable later moment they never asked for.
                guard agentSessionLinkAutoWakeMayStillSettle(session), !attempt.isManual else {
                    cancelAgentSessionLinkAutoWake(for: endpoint, reason: .eligibilityLost)
                    return
                }
                agentSessionLinkSetAutoWakePhase(.awaitingSettlement, wakeID: wakeID, endpoint: endpoint)
                // One owned task subscribes to the next readiness event and is cancelled with the
                // attempt. There is no yield loop, timer, or second queue authority.
                for await _ in session.monitorReadinessChangePublisher.values {
                    break
                }
                continue
            }

            let dispatchID = AgentSessionLinkPromptDispatchID.autoWake(wakeID: wakeID)
            if route == .waitingContinuation, session.selectedAgent == .codexExec {
                let expectedWaitID = session.instructionWaitID
                let expectedControllerID = session.codexController.map(ObjectIdentifier.init)
                let readiness = await ensureProviderInputCatalogReady(for: session)
                guard readiness == .ready || readiness == .notRequired,
                      let current = agentSessionLinkAutoWakeSession(for: endpoint),
                      current === session,
                      current.oversight.pendingAutoWake?.wakeID == wakeID,
                      current.instructionWaitID == expectedWaitID,
                      current.codexController.map(ObjectIdentifier.init) == expectedControllerID,
                      agentSessionLinkAutoWakeRoute(current) == .waitingContinuation
                else {
                    agentSessionLinkRecordPhysicalDispatchNotAttempted(for: session, dispatchID: dispatchID)
                    return
                }
            }
            guard agentSessionLinkSelectAutoWakeAdmissionBasis(
                wakeID: wakeID,
                endpoint: endpoint
            ) else {
                cancelAgentSessionLinkAutoWake(for: endpoint, reason: .eligibilityLost)
                return
            }
            // Reserve the exact rendered lane batch before provider preparation. Budget omission,
            // receipt competition, revocation, and membership drift therefore remain definite
            // no-call outcomes.
            let monitoring = agentSessionLinkDecoratedProviderText(
                "",
                session: session,
                dispatchID: dispatchID
            )
            guard !monitoring.mustAbortDispatch, let reservedClaim = monitoring.claim else {
                agentSessionLinkRecordPhysicalDispatchNotAttempted(for: session, dispatchID: dispatchID)
                cancelAgentSessionLinkAutoWake(for: endpoint, reason: .requiredClaimUnavailable)
                return
            }
            guard agentSessionLinkReservedClaimContainsRequiredAttention(
                reservedClaim,
                wakeID: wakeID,
                session: session
            ) else {
                abandonAgentSessionLinkPromptClaim(reservedClaim)
                agentSessionLinkRecordPhysicalDispatchNotAttempted(
                    for: session,
                    dispatchID: dispatchID
                )
                cancelAgentSessionLinkAutoWake(for: endpoint, reason: .requiredClaimUnavailable)
                return
            }

            agentSessionLinkPrepareAutoWakeDispatch(wakeID: wakeID, endpoint: endpoint)
            switch route {
            case .idleFollowUp:
                let startOutcome = await startAgentRun(
                    tabID: endpoint.tabID,
                    initialMessage: "",
                    directStartOptions: .laneUpdate(wakeID: wakeID)
                )
                if case .some(.queuedFallback) = startOutcome {
                    // Codex owns a durable queued submission. Keep the wake identity attached until
                    // that queue reaches its physical boundary and reports acceptance or ambiguity.
                    if var queuedAttempt = session.oversight.pendingAutoWake,
                       queuedAttempt.wakeID == wakeID
                    {
                        queuedAttempt.task = nil
                        session.oversight.pendingAutoWake = queuedAttempt
                    }
                    return
                }
            case .waitingContinuation:
                agentSessionLinkResumeWaitingContinuationForAutoWake(
                    claim: reservedClaim,
                    wakeID: wakeID,
                    endpoint: endpoint
                )
            }

            await agentSessionLinkAwaitPhysicalDispatchSettlement(
                wakeID: wakeID,
                endpoint: endpoint
            )
            return
        }
    }

    /// Freezes the basis this dispatch is about to be attempted under.
    ///
    /// Called immediately before claim reservation, after every readiness suspension. Status and
    /// overflow preserve their existing precedence: attention is required only when neither already
    /// admits the turn. The occurrence is exact and immutable; later publications may update the
    /// attempt's high-water fingerprint but never replace this prepared basis. A manual reservation
    /// keeps its basis and is only re-checked for content that still admits under manual policy.
    private func agentSessionLinkSelectAutoWakeAdmissionBasis(
        wakeID: UUID,
        endpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> Bool {
        guard let session = agentSessionLinkAutoWakeSession(for: endpoint),
              var attempt = session.oversight.pendingAutoWake,
              attempt.wakeID == wakeID,
              attempt.phase == .scheduled || attempt.phase == .awaitingSettlement,
              let snapshot = agentSessionLinkCurrentPassiveSnapshot(for: endpoint),
              snapshot.queueEpoch == attempt.queueEpoch
        else {
            return false
        }
        let admission = agentSessionLinkAutoWakeAdmission(
            snapshot,
            session: session,
            endpoint: endpoint,
            basis: attempt.admissionBasis
        )
        let fingerprint = snapshot.wakeEligibilityFingerprint
        guard admission.hasAdmissionBasis else {
            return false
        }
        if attempt.isManual {
            agentSessionLinkLogAutoWakeGate(endpoint, attempt.wakeFingerprint, "basis.manual")
            return true
        }
        let requiredAttentionOccurrence = admission.requiredAttentionOccurrence(
            fingerprint: fingerprint,
            suppressed: session.oversight.suppressedWakeFingerprint
        )
        if attempt.requiredAttentionOccurrence != nil,
           requiredAttentionOccurrence == nil,
           !admission.hasUnsuppressedAdmissionBasis(
               fingerprint: fingerprint,
               suppressed: session.oversight.suppressedWakeFingerprint
           )
        {
            // This attempt was admitted only by purposeful attention, but that exact structural
            // escape is gone. Do not silently downgrade it to the mutable suppressed-status race.
            return false
        }
        attempt.admissionBasis = requiredAttentionOccurrence
            .map(AgentSessionLinkWakeAdmissionDecision.Basis.purposefulAttention)
            ?? .routineStatusOrOverflow
        session.oversight.pendingAutoWake = attempt
        agentSessionLinkLogAutoWakeGate(
            endpoint,
            attempt.wakeFingerprint,
            requiredAttentionOccurrence == nil
                ? "basis.statusOrOverflow"
                : "basis.attention"
        )
        return true
    }

    /// The wake may cross into provider preparation only if the exact attention occurrence whose
    /// snooze was bypassed is present in the immutable rendered claim.
    private func agentSessionLinkReservedClaimContainsRequiredAttention(
        _ claim: AgentSessionLinkOutboundPromptClaim,
        wakeID: UUID,
        session: TabSession
    ) -> Bool {
        guard let attempt = session.oversight.pendingAutoWake,
              attempt.wakeID == wakeID
        else {
            return false
        }
        guard let required = attempt.requiredAttentionOccurrence else { return true }
        guard claim.dispatchID == .autoWake(wakeID: wakeID),
              let passive = claim.passive,
              passive.observerEndpoint == attempt.observerEndpoint,
              passive.receipt.queueEpoch == attempt.queueEpoch
        else {
            return false
        }
        return passive.receipt.deliveredAttentionOccurrences.contains(required)
    }

    /// Acquires the actual transport boundary for an auto-wake. Ordinary dispatches pass through.
    /// Providers call this after final prompt composition and immediately before their physical call.
    ///
    /// Classification is by **reserved family first, identity second**, and that order is the whole
    /// fail-closed property. A value that claims `lane.autowake:` but does not parse is refused
    /// rather than waved through: if a constructor and the parser ever disagreed, the `nil` identity
    /// would otherwise take the ordinary-dispatch early return and turn a fenced lane update into an
    /// unfenced provider call with no claim, no provenance row, and no snooze/selection check.
    @discardableResult
    func agentSessionLinkAcquirePhysicalDispatch(
        for session: TabSession,
        dispatchID: AgentSessionLinkPromptDispatchID
    ) -> Bool {
        let effectiveID = agentSessionLinkEffectiveDispatchID(for: session, dispatchID: dispatchID)
        guard effectiveID.isAutoWakeFamily else { return true }
        guard let wakeID = effectiveID.autoWakeID else { return false }
        guard var attempt = session.oversight.pendingAutoWake,
              attempt.wakeID == wakeID
        else { return false }
        if attempt.isPeriodic {
            guard attempt.periodicProducerDispatchID == dispatchID else { return false }
            if attempt.phase == .cancelledBeforeDispatch { return false }
            guard attempt.phase == .preparingDispatch || attempt.phase == .dispatching else { return false }
            if attempt.phase == .preparingDispatch {
                guard agentSessionLinkPeriodicWakeIsEligible(session, endpoint: attempt.observerEndpoint),
                      agentSessionLinkPeriodicPreparationIsUnblocked(session) else { return false }
                attempt.phase = .dispatching
                attempt.physicalOutcome = .ambiguous
                session.oversight.pendingAutoWake = attempt
                session.noteMonitorObservationInputsChanged()
            }
            return true
        }
        if attempt.phase == .cancelledBeforeDispatch {
            if let claim = agentSessionLinkPromptClaimStore.pendingClaim(
                dispatchID: effectiveID,
                observerSessionID: attempt.observerEndpoint.sessionID
            ) {
                agentSessionLinkPromptClaimStore.abandon(claim)
            }
            attempt.task?.cancel()
            session.oversight.pendingAutoWake = nil
            requestUIRefresh(tabID: session.tabID)
            agentSessionLinkDrainAutoWakeReevaluationIfOwed(session: session)
            return false
        }
        guard attempt.phase == .preparingDispatch || attempt.phase == .dispatching else {
            return false
        }
        if attempt.phase != .dispatching {
            // The acceptance fence, evaluated exactly once and only on this side of the transport
            // boundary. A re-entrant acquire for an attempt that is already `dispatching` must not
            // consult it: the physical call may already have happened, so retracting the identity
            // here would report "no call" for a turn the provider is running.
            guard agentSessionLinkAutoWakeAttemptIsStillEligible(attempt, session: session) else {
                if let claim = agentSessionLinkPromptClaimStore.pendingClaim(
                    dispatchID: effectiveID,
                    observerSessionID: attempt.observerEndpoint.sessionID
                ) {
                    agentSessionLinkPromptClaimStore.abandon(claim)
                }
                attempt.task?.cancel()
                session.oversight.pendingAutoWake = nil
                requestUIRefresh(tabID: session.tabID)
                agentSessionLinkDrainAutoWakeReevaluationIfOwed(session: session)
                return false
            }
            guard let claim = agentSessionLinkPromptClaimStore.pendingClaim(
                dispatchID: effectiveID,
                observerSessionID: attempt.observerEndpoint.sessionID
            ) else {
                attempt.task?.cancel()
                session.oversight.pendingAutoWake = nil
                requestUIRefresh(tabID: session.tabID)
                agentSessionLinkDrainAutoWakeReevaluationIfOwed(session: session)
                return false
            }
            guard agentSessionLinkAutoWakeClaimSupportsPhysicalAcquisition(
                claim,
                attempt: attempt,
                session: session
            ) else {
                agentSessionLinkPromptClaimStore.abandon(claim)
                attempt.task?.cancel()
                session.oversight.pendingAutoWake = nil
                requestUIRefresh(tabID: session.tabID)
                agentSessionLinkDrainAutoWakeReevaluationIfOwed(session: session)
                return false
            }
            guard let fingerprint = attempt.wakeFingerprint else { return false }
            attempt.phase = .dispatching
            attempt.attemptedFingerprint = AgentSessionLinkPassiveStatusNotices
                .WakeEligibilityFingerprint(
                    queueEpoch: fingerprint.queueEpoch,
                    // Deliberately preserve the pre-attention status-side behavior: only the
                    // attention component is frozen from the immutable claim at this assignment.
                    edges: fingerprint.edges,
                    attentionOccurrences: claim.passive?.receipt
                        .deliveredAttentionOccurrences ?? [],
                    overflowProduced: fingerprint.overflowProduced
                )
            attempt.physicalOutcome = .ambiguous
            session.oversight.pendingAutoWake = attempt
            // The interval measures from the transport boundary for notification/manual wakes;
            // periodic wakes return above without stamping it. Both notification routes cross once per
            // attempt: a re-entrant acquire is already `.dispatching` and takes the early return.
            session.oversight.lastOversightWakeDispatch = AgentSessionLinkOversightWakeDispatch(
                observerEndpoint: attempt.observerEndpoint,
                instant: session.oversight.snoozeClock.now()
            )
            agentSessionLinkRearmAutoWakeSnoozeDeadlineTask(
                endpoint: attempt.observerEndpoint,
                session: session
            )
            session.monitorObservationSignal.send(())
            requestUIRefresh(tabID: session.tabID)
            agentSessionLinkLogAutoWakeGate(
                attempt.observerEndpoint,
                attempt.attemptedFingerprint,
                "dispatching"
            )
        }
        return true
    }

    /// Revalidates the purposeful-attention exception against the immutable rendered claim and the
    /// exact current grant at the physical transport boundary.
    ///
    /// If the required occurrence disappeared after composition, only another basis that was both
    /// rendered in this same claim and remains independently admissible may save the call. Newly
    /// absorbed queue state is intentionally insufficient: it belongs to the owed reevaluation.
    private func agentSessionLinkAutoWakeClaimSupportsPhysicalAcquisition(
        _ claim: AgentSessionLinkOutboundPromptClaim,
        attempt: AgentSessionLinkAutoWakeAttempt,
        session: TabSession
    ) -> Bool {
        guard claim.dispatchID == .autoWake(wakeID: attempt.wakeID),
              let passive = claim.passive,
              passive.observerEndpoint == attempt.observerEndpoint,
              passive.receipt.queueEpoch == attempt.queueEpoch,
              let snapshot = agentSessionLinkCurrentPassiveSnapshot(
                  for: attempt.observerEndpoint
              ),
              let context = agentSessionLinkPromptContext(for: session),
              context.epoch.endpoint == attempt.observerEndpoint,
              context.epoch.allowsSupplement
        else {
            return false
        }
        let lanesByReference = agentSessionLinkAutoWakeLanesByReference(snapshot)
        // Under the reservation's own basis, so the fence asks what admission asked. A manual attempt
        // still requires rendered content that is live under exact current membership.
        let currentAdmission = agentSessionLinkAutoWakeAdmission(
            snapshot,
            session: session,
            endpoint: attempt.observerEndpoint,
            basis: attempt.admissionBasis
        )
        if let required = attempt.requiredAttentionOccurrence {
            if passive.receipt.deliveredAttentionOccurrences.contains(required),
               agentSessionLinkAttentionOccurrenceIsLive(
                   required,
                   snapshot: snapshot,
                   inventory: context.inventory,
                   lanesByReference: lanesByReference
               )
            {
                return true
            }
        }

        // A rendered attention occurrence is an independent exact-lane basis only when it was not
        // already part of the failure parked in suppression. Routine Auto-wake selection and the
        // exact lane's snooze are deliberately irrelevant, while grant identity is not. A
        // post-composition successor is absent from the receipt and therefore cannot qualify here.
        let unsuppressedAttentionOccurrences = Set(
            currentAdmission.unsuppressedAdmittingAttentionOccurrences(
                suppressed: session.oversight.suppressedWakeFingerprint
            )
        )
        if passive.receipt.deliveredAttentionOccurrences.contains(where: { occurrence in
            unsuppressedAttentionOccurrences.contains(occurrence)
                && agentSessionLinkAttentionOccurrenceIsLive(
                    occurrence,
                    snapshot: snapshot,
                    inventory: context.inventory,
                    lanesByReference: lanesByReference
                )
        }) {
            return true
        }

        guard attempt.requiredAttentionOccurrence == nil
            || !currentAdmission.ordinaryAdmissionBasisIsSuppressed(
                fingerprint: snapshot.wakeEligibilityFingerprint,
                suppressed: session.oversight.suppressedWakeFingerprint
            )
        else {
            // The rendered status/overflow shape is exactly the previously failed one. Attention
            // was the only exact structural change that re-armed this attempt, so losing or omitting
            // it cannot let the suppressed ordinary basis call the provider again.
            return false
        }

        // Only a rendered row from a routine-admitting lane is a basis. Every other rendered status
        // row is a hitchhiker — delivered because the batch is immutable, but never the reason the
        // provider gets called.
        let hasRenderedStatusBasis = passive.receipt.deliveredStatuses.contains { delivered in
            guard let entry = snapshot.entries.first(where: {
                $0.reference == delivered.reference
                    && $0.toStatus == delivered.toStatus
            }),
                currentAdmission.routineLaneAdmits(entry.reference)
            else {
                return false
            }
            // A same-status metadata refresh advances receipt sequencing but preserves the status
            // occurrence fingerprint. The purposeful-attention fence must not turn that pre-existing
            // status behavior into a definite no-call merely because the rendered line gained
            // fresher presentation detail.
            return context.inventory.items.contains {
                $0.targetSessionID == entry.targetSessionID
                    && ($0.reference == nil || $0.reference == entry.reference)
            }
        }
        if hasRenderedStatusBasis {
            return true
        }

        return snapshot.linkSetRevision == context.inventory.linkSetRevision
            && passive.includesUnattributedOverflow
            && currentAdmission.overflowAloneMayWake
    }

    /// The single exact-current-lane predicate shared by admission and physical liveness.
    private func agentSessionLinkAttentionRequestMatchesExactCurrentLane(
        _ request: AgentSessionLinkPassiveStatusNotices.PendingAttentionRequest,
        snapshot: AgentSessionLinkPassiveStatusNotices.Snapshot,
        lanesByReference:
        [DomainAgentSessionLinkReference: AgentSessionLinkPassiveStatusNotices.AutoWakeLane]
    ) -> Bool {
        guard request.occurrence.queueEpoch == snapshot.queueEpoch,
              let lane = lanesByReference[request.reference]
        else {
            return false
        }
        return lane.targetEndpoint == request.targetEndpoint
            && lane.targetSessionID == request.targetSessionID
    }

    private func agentSessionLinkAttentionOccurrenceIsLive(
        _ occurrence: AgentSessionLinkPassiveStatusNotices.AttentionOccurrenceIdentity,
        snapshot: AgentSessionLinkPassiveStatusNotices.Snapshot,
        inventory: AgentSessionLinkPromptInventory,
        lanesByReference:
        [DomainAgentSessionLinkReference: AgentSessionLinkPassiveStatusNotices.AutoWakeLane]
    ) -> Bool {
        guard let request = snapshot.attentionRequests.first(where: {
            $0.occurrence == occurrence
        }),
            agentSessionLinkAttentionRequestMatchesExactCurrentLane(
                request,
                snapshot: snapshot,
                lanesByReference: lanesByReference
            )
        else {
            return false
        }
        return inventory.items.contains {
            $0.reference == request.reference
                && $0.targetSessionID == request.targetSessionID
        }
    }

    /// Settles a prepared wake when the provider path definitively exits before its transport call.
    ///
    /// Idempotent by wake identity. It installs no failure suppression, because the provider received
    /// nothing and the lane batch remains owed.
    func agentSessionLinkRecordPhysicalDispatchNotAttempted(
        for session: TabSession,
        dispatchID: AgentSessionLinkPromptDispatchID
    ) {
        let effectiveID = agentSessionLinkEffectiveDispatchID(for: session, dispatchID: dispatchID)
        guard let wakeID = effectiveID.autoWakeID,
              let attempt = session.oversight.pendingAutoWake,
              attempt.wakeID == wakeID,
              attempt.phase != .dispatching,
              attempt.physicalOutcome == .notAttempted
        else {
            return
        }
        if attempt.isPeriodic, attempt.periodicProducerDispatchID != dispatchID { return }
        attempt.task?.cancel()
        session.oversight.pendingAutoWake = nil
        session.monitorObservationSignal.send(())
        requestUIRefresh(tabID: session.tabID)
        agentSessionLinkLogAutoWakeGate(
            attempt.observerEndpoint,
            attempt.wakeFingerprint,
            "settled.notAttempted"
        )
        agentSessionLinkDrainAutoWakeReevaluationIfOwed(session: session)
    }

    func agentSessionLinkRecordPhysicalDispatchFailure(
        for session: TabSession,
        dispatchID: AgentSessionLinkPromptDispatchID
    ) {
        let effectiveID = agentSessionLinkEffectiveDispatchID(for: session, dispatchID: dispatchID)
        guard let wakeID = effectiveID.autoWakeID,
              let attempt = session.oversight.pendingAutoWake,
              attempt.wakeID == wakeID,
              attempt.physicalOutcome == .ambiguous
        else {
            return
        }
        // Periodic producers may still enter the existing Codex fallback/auth recovery path.
        // Keep their identity until acceptance or proven producer settlement, without suppression.
        if attempt.isPeriodic { return }
        agentSessionLinkSettleAmbiguousAutoWake(attempt, session: session)
    }

    private func agentSessionLinkPrepareAutoWakeDispatch(
        wakeID: UUID,
        endpoint: DomainAgentSessionLinkEndpointIdentity
    ) {
        guard let session = sessions[endpoint.tabID],
              var attempt = session.oversight.pendingAutoWake,
              attempt.wakeID == wakeID
        else { return }
        attempt.phase = .preparingDispatch
        attempt.attemptedFingerprint = nil
        attempt.physicalOutcome = .notAttempted
        session.oversight.pendingAutoWake = attempt
    }

    func agentSessionLinkAwaitPhysicalDispatchSettlement(
        wakeID: UUID,
        endpoint: DomainAgentSessionLinkEndpointIdentity
    ) async {
        // This is the sole preparation finalizer. It must observe cancellation intent even when its
        // task was cancelled by an older caller, so termination is driven by explicit settlement.
        while true {
            guard let session = sessions[endpoint.tabID],
                  let attempt = session.oversight.pendingAutoWake,
                  attempt.wakeID == wakeID,
                  attempt.observerEndpoint == endpoint
            else { return }

            if attempt.isPeriodic {
                if agentSessionLinkPeriodicProducerHasSettled(session) {
                    await attempt.periodicProducerTask?.value
                    guard session.oversight.pendingAutoWake?.wakeID == wakeID,
                          agentSessionLinkPeriodicProducerHasSettled(session) else { continue }
                    attempt.task?.cancel()
                    session.oversight.pendingAutoWake = nil
                    session.noteMonitorObservationInputsChanged()
                    agentSessionLinkDrainAutoWakeReevaluationIfOwed(session: session)
                    return
                }
                for await _ in session.monitorReadinessChangePublisher.values {
                    break
                }
                continue
            }
            if attempt.phase == .cancelledBeforeDispatch {
                cancelAgentSessionLinkAutoWake(for: endpoint, reason: .requiredClaimUnavailable)
                agentSessionLinkDrainAutoWakeReevaluationIfOwed(session: session)
                return
            }
            switch attempt.physicalOutcome {
            case .accepted:
                return
            case .notAttempted where !session.runState.isActive:
                cancelAgentSessionLinkAutoWake(for: endpoint, reason: .requiredClaimUnavailable)
                agentSessionLinkDrainAutoWakeReevaluationIfOwed(session: session)
                return
            case .ambiguous where !session.runState.isActive:
                agentSessionLinkSettleAmbiguousAutoWake(attempt, session: session)
                return
            case .notAttempted, .ambiguous:
                // The run still owns preparation/call settlement. Await the next readiness or
                // physical-boundary publication; cancellation tears down this exact subscription.
                for await _ in session.monitorReadinessChangePublisher.values {
                    break
                }
            }
        }
    }

    private func agentSessionLinkSettleAmbiguousAutoWake(
        _ attempt: AgentSessionLinkAutoWakeAttempt,
        session: TabSession
    ) {
        attempt.task?.cancel()
        session.oversight.pendingAutoWake = nil
        // The provider may have accepted the turn, so the structural shape it was attempted under
        // stays suppressed. Nothing durable changes here: the lane receipt intentionally remains
        // owed, and there is no session state an ambiguous outcome could truthfully write.
        // A manual retry bypasses automatic suppression without replacing that policy state.
        if !attempt.isPeriodic, !attempt.isManual {
            session.oversight.suppressedWakeFingerprint = attempt.attemptedFingerprint
        }
        session.noteMonitorObservationInputsChanged()
        requestUIRefresh(tabID: session.tabID)
        agentSessionLinkLogAutoWakeGate(
            attempt.observerEndpoint,
            attempt.attemptedFingerprint,
            "settled.ambiguous"
        )
        agentSessionLinkDrainAutoWakeReevaluationIfOwed(session: session)
    }

    /// Replays exactly one queue evaluation that could not be scheduled while an attempt owned the
    /// provider-preparation/transport boundary.
    ///
    /// The marker is cleared before re-entry. Any successor publication arriving during the replay
    /// either schedules normally or records a fresh debt against its own non-schedulable attempt.
    func agentSessionLinkDrainAutoWakeReevaluationIfOwed(session: TabSession) {
        guard session.oversight.autoWakeReevaluationOwed else { return }
        session.oversight.autoWakeReevaluationOwed = false
        guard sessions[session.tabID] === session,
              let endpoint = agentSessionLinkObserverEndpoint(tabID: session.tabID),
              let snapshot = agentSessionLinkCurrentPassiveSnapshot(for: endpoint)
        else {
            return
        }
        agentSessionLinkNoteAutoWakeOpportunity(snapshot, endpoint: endpoint)
    }

    /// Re-drives this observer's already-published passive snapshot through the ordinary Auto-wake
    /// entry point, without changing anything about the queue.
    ///
    /// Used after a Codex session-link catalog repair leaves the session cold. The repair retires the
    /// process run, so `agentSessionLinkPromptContext`'s existing cold-bootstrap exception
    /// (`session.runID == nil`) can finally admit the unchanged snapshot that the stale false catalog
    /// had been blocking. Every ordinary gate — routine selection, purposeful attention, snooze,
    /// suppression, authority, budget, physical acquisition — still decides whether a turn starts.
    ///
    /// It deliberately creates no second queue, moves no queue revision, writes no receipt, does not
    /// manufacture `agentSessionLinkAutoWakeReevaluationOwed` (that debt belongs to publications an
    /// attempt absorbed), and never polls for readiness.
    func agentSessionLinkRedriveCurrentPassiveSnapshot(for session: TabSession) {
        guard sessions[session.tabID] === session,
              let endpoint = agentSessionLinkObserverEndpoint(tabID: session.tabID),
              let snapshot = agentSessionLinkCurrentPassiveSnapshot(for: endpoint)
        else {
            return
        }
        agentSessionLinkNoteAutoWakeOpportunity(snapshot, endpoint: endpoint)
    }

    /// Records one physically accepted auto-wake, in the order the plan requires.
    ///
    /// Called from the shared claim-acceptance path, so every provider family reaches it through the
    /// physical-acceptance signal it already reports and no acceptance boundary moves earlier.
    ///
    /// The wake is identified by the **claim**, not by whatever the session happens to hold when the
    /// provider signals. `dispatchID` was stamped `lane.autowake:<wakeID>` when the claim was
    /// reserved, so a late acceptance from a superseded wake cannot settle the current one, and an
    /// ordinary turn that merely happened to carry a lane batch is not a wake at all.
    func agentSessionLinkRecordAcceptedAutoWake(
        _ claim: AgentSessionLinkOutboundPromptClaim,
        acceptedAt: Date = Date()
    ) {
        guard let wakeID = claim.dispatchID.autoWakeID,
              let endpoint = claim.passive?.observerEndpoint,
              let session = sessions[endpoint.tabID],
              agentSessionLinkObserverEndpoint(tabID: endpoint.tabID) == endpoint,
              !session.items.contains(where: { $0.id == wakeID })
        else {
            return
        }
        // Matched by wake ID alone. A late acceptance that arrives after a local user submission is
        // still truthful — it appends its one provenance row — and there is no session state left
        // for it to overwrite.
        if var acceptedAttempt = session.oversight.pendingAutoWake,
           acceptedAttempt.wakeID == wakeID
        {
            acceptedAttempt.physicalOutcome = .accepted
            acceptedAttempt.task?.cancel()
            session.oversight.pendingAutoWake = nil
        }
        // Acceptance's receipt is applied immediately after this callback and republishes whatever
        // the immutable claim did not consume, so replaying before that receipt would duplicate the
        // attempted batch. The receipt publication owns this one settlement path.
        session.oversight.autoWakeReevaluationOwed = false
        session.oversight.suppressedWakeFingerprint = nil
        agentSessionLinkClearWaitingOnAfterAcceptedTurn(session)
        // Attribution comes from the claim — the immutable batch the provider actually accepted — and
        // never from live links, live selection, or current snooze state. Snoozed and unselected
        // hitchhikers therefore appear because they were *rendered*, and a rename or unlink after
        // construction cannot change what the row says.
        session.appendItem(AgentChatItem.laneUpdateAutoWake(
            wakeID: wakeID,
            acceptedAt: acceptedAt,
            sequenceIndex: session.nextSequenceIndex,
            displayAttribution: claim.passive?.displayAttribution
        ))
        session.isDirty = true
        requestUIRefresh(tabID: endpoint.tabID)
        scheduleSave(for: endpoint.tabID)
    }

    /// Delivers one lane update into an already-waiting run's one-shot instruction continuation.
    ///
    /// The cheaper of the two routes and the correct one here: the run is already in flight and is
    /// asking what to do next, so starting a second run alongside it would be both wasteful and a
    /// race. Successful `resume(returning:)` is the physical acceptance boundary, exactly as it is
    /// for an ordinary instruction — no new acceptance point is introduced.
    ///
    /// It resumes with a lane origin and no user text, so nothing downstream can mistake it for the
    /// user's answer: no `.user` row, no `lastUserMessageAt` move, no handoff consumption.
    private func agentSessionLinkResumeWaitingContinuationForAutoWake(
        claim: AgentSessionLinkOutboundPromptClaim,
        wakeID: UUID,
        endpoint: DomainAgentSessionLinkEndpointIdentity
    ) {
        guard let session = agentSessionLinkAutoWakeSession(for: endpoint),
              session.oversight.pendingAutoWake?.wakeID == wakeID,
              agentSessionLinkAutoWakeRoute(session) == .waitingContinuation
        else {
            return
        }
        guard agentSessionLinkAcquirePhysicalDispatch(for: session, dispatchID: claim.dispatchID) else {
            return
        }
        _ = resumeWaitingInstructionContinuation(
            session: session,
            providerText: claim.fragment,
            claim: claim,
            origin: .laneUpdateAutoWake(wakeID: wakeID)
        )
    }

    // MARK: - Routine wake interval

    /// The interval deadline that currently owes one reevaluation for this observer.
    ///
    /// Evaluated under *automatic* policy even while a manual attempt occupies the slot: the question
    /// is when routine content may next wake the observer.
    private func agentSessionLinkRoutineIntervalDeferral(
        endpoint: DomainAgentSessionLinkEndpointIdentity,
        session: TabSession
    ) -> ContinuousClock.Instant? {
        guard let snapshot = agentSessionLinkCurrentPassiveSnapshot(for: endpoint),
              snapshot.isDeliverable,
              snapshot.hasDeliverableContent
        else {
            return nil
        }
        let admission = agentSessionLinkAutoWakeAdmission(
            snapshot,
            session: session,
            endpoint: endpoint
        )
        return admission.routineDeferralOwingReevaluation(
            fingerprint: snapshot.wakeEligibilityFingerprint,
            suppressed: session.oversight.suppressedWakeFingerprint,
            promptEligible: {
                agentSessionLinkPromptContext(for: session)?.epoch.allowsSupplement == true
            }
        )
    }

    /// Re-evaluates one observer after its routine-interval preference changed.
    ///
    /// The same shape every other policy change uses: fence an attempt the change made ineligible,
    /// then replay exactly one evaluation of the retained snapshot. It fabricates no snapshot and
    /// clears no suppression; with nothing published it only re-arms the shared deadline.
    func agentSessionLinkNoteRoutineWakeIntervalChanged(
        for endpoint: DomainAgentSessionLinkEndpointIdentity
    ) {
        guard let session = agentSessionLinkAutoWakeSession(for: endpoint) else { return }
        agentSessionLinkFenceAutoWakeSelectionChange(for: endpoint)
        guard let snapshot = agentSessionLinkCurrentPassiveSnapshot(for: endpoint) else {
            agentSessionLinkRearmAutoWakeSnoozeDeadlineTask(endpoint: endpoint, session: session)
            return
        }
        agentSessionLinkNoteAutoWakeOpportunity(snapshot, endpoint: endpoint)
    }

    // MARK: - Wake now

    /// Why the user's `Wake now` cannot run right now, or `nil` when it can.
    ///
    /// One predicate behind both the button and the countdown, so the dashboard cannot offer a wake
    /// the coordinator would refuse. Reads live state only.
    private func agentSessionLinkWakeNowRefusal(
        session: TabSession,
        endpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> AgentMonitorWakeNowRefusal? {
        guard let snapshot = agentSessionLinkCurrentPassiveSnapshot(for: endpoint),
              snapshot.isDeliverable,
              snapshot.hasDeliverableContent
        else {
            return .noPendingUpdates
        }
        // Including a tombstone: the slot is the single reservation, and a manual request must never
        // promote, replace, or race the identity that fences an in-flight provider call.
        if session.oversight.pendingAutoWake != nil { return .alreadyWaking }
        guard agentSessionLinkAutoWakeRoute(session) != nil else { return .sessionBusy }
        guard agentSessionLinkPromptContext(for: session)?.epoch.allowsSupplement == true else {
            return .notReady
        }
        guard agentSessionLinkAutoWakeAdmission(
            snapshot,
            session: session,
            endpoint: endpoint,
            basis: .manual
        ).hasAdmissionBasis else {
            return .noPendingUpdates
        }
        return nil
    }

    /// Reserves one manual wake for pending updates, or explains why it cannot.
    ///
    /// Changes no preference: selection, snoozes, the interval, and the stored failure fingerprint
    /// are read and never written. `.scheduled` means a reservation was accepted, not that a provider
    /// call happened.
    @discardableResult
    func agentSessionLinkRequestManualWakeNow(
        for endpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> AgentMonitorWakeNowOutcome {
        guard let session = agentSessionLinkAutoWakeSession(for: endpoint) else {
            return .refused(.observerUnavailable)
        }
        if let refusal = agentSessionLinkWakeNowRefusal(session: session, endpoint: endpoint) {
            return .refused(refusal)
        }
        guard let snapshot = agentSessionLinkCurrentPassiveSnapshot(for: endpoint) else {
            return .refused(.noPendingUpdates)
        }
        agentSessionLinkReserveAutoWakeAttempt(
            basis: .manual,
            snapshot: snapshot,
            endpoint: endpoint,
            session: session
        )
        session.monitorObservationSignal.send(())
        requestUIRefresh(tabID: endpoint.tabID)
        return .scheduled
    }

    /// The dashboard's read-only view of this observer's pending queue.
    ///
    /// Presentation only: it receipts, baselines, and removes nothing, and never re-enters the wake
    /// pipeline.
    func agentSessionLinkPendingUpdatesProjection(
        for endpoint: DomainAgentSessionLinkEndpointIdentity,
        outbound: [AgentMonitorPillProps.Outbound]
    ) -> AgentMonitorPendingUpdates {
        guard let session = agentSessionLinkAutoWakeSession(for: endpoint) else {
            return AgentMonitorPendingUpdates.unavailable
        }
        let snapshot = agentSessionLinkCurrentPassiveSnapshot(for: endpoint)
        let refusal = agentSessionLinkWakeNowRefusal(session: session, endpoint: endpoint)
        return AgentMonitorPendingUpdates.make(
            snapshot: snapshot,
            outbound: outbound,
            wakeNowRefusal: refusal,
            routineWakeDeferredUntil: agentSessionLinkRoutineWakeDeferredUntil(
                endpoint: endpoint,
                session: session,
                snapshot: snapshot,
                refusal: refusal
            )
        )
    }

    /// The wall-clock instant the countdown may name, or `nil` when no countdown would be truthful.
    ///
    /// Requires that `Wake now` would be accepted, that no attention occurrence is pending (it would
    /// admit immediately), and that the deadline is still ahead. Derived from the monotonic remainder
    /// against wall time like the snooze projection, so a clock change moves only the display.
    private func agentSessionLinkRoutineWakeDeferredUntil(
        endpoint: DomainAgentSessionLinkEndpointIdentity,
        session: TabSession,
        snapshot: AgentSessionLinkPassiveStatusNotices.Snapshot?,
        refusal: AgentMonitorWakeNowRefusal?
    ) -> Date? {
        guard refusal == nil,
              let snapshot,
              snapshot.attentionRequests.isEmpty,
              let deadline = agentSessionLinkRoutineIntervalDeferral(
                  endpoint: endpoint,
                  session: session
              )
        else {
            return nil
        }
        let clock = session.oversight.snoozeClock
        let remaining = clock.now().duration(to: deadline)
        guard remaining > .zero else { return nil }
        let components = remaining.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        // Quantized to a whole second so two reads a few milliseconds apart do not produce unequal
        // props and repaint the dashboard for nothing.
        return Date(timeIntervalSince1970: (clock.wallNow().timeIntervalSince1970 + seconds).rounded())
    }

    // MARK: - Auto-wake snooze

    /// Pure, observational read of one exact lane's snooze.
    ///
    /// It removes nothing, arms nothing, publishes nothing, and never re-enters the wake pipeline. An
    /// elapsed record answers `success(nil)`: expiry is decided by the monotonic deadline, not by
    /// whether bookkeeping has caught up.
    func agentSessionLinkAutoWakeSnoozeProjection(
        endpoint: DomainAgentSessionLinkEndpointIdentity,
        targetSessionID: UUID,
        expectedReference: DomainAgentSessionLinkReference
    ) -> Result<AgentSessionLinkAutoWakeSnoozeProjection?, AgentSessionLinkAutoWakeSnoozeFailure> {
        guard let session = agentSessionLinkAutoWakeSession(for: endpoint) else {
            return .failure(.observerUnavailable)
        }
        let snapshot = agentSessionLinkCurrentPassiveSnapshot(for: endpoint)
        if let snapshot,
           let lane = snapshot.autoWakeLanes.first(where: { $0.reference == expectedReference }),
           lane.targetSessionID != targetSessionID
        {
            return .failure(.staleReference)
        }
        let clock = session.oversight.snoozeClock
        let key = AgentSessionLinkAutoWakeSnoozeKey(
            observerEndpoint: endpoint,
            reference: expectedReference
        )
        return .success(AgentSessionLinkAutoWakeSnoozeProjection.make(
            record: session.oversight.autoWakeSnoozes[key],
            now: clock.now(),
            wallNow: clock.wallNow()
        ))
    }

    /// Applies one set/extend/clear to the exact observer incarnation that owns the policy.
    ///
    /// The mutation is observer-local by construction. It never applies a receipt, removes or
    /// baselines a passive entry, mutates durable Auto-wake selection, touches link authority or target
    /// state, disturbs failure suppression, or writes a transcript row.
    ///
    /// Every accepted command re-drives the current authoritative snapshot through the ordinary
    /// pipeline exactly once. That is a reevaluation promise and nothing more: normal
    /// authority/readiness/suppression gates stay in charge, and already receipted or net-reverted
    /// content produces no turn at all.
    func agentSessionLinkMutateAutoWakeSnooze(
        endpoint: DomainAgentSessionLinkEndpointIdentity,
        targetSessionID: UUID,
        expectedReference: DomainAgentSessionLinkReference,
        command: AgentSessionLinkAutoWakeSnoozeCommand,
        origin: AgentSessionLinkAutoWakeSnoozeOrigin
    ) -> Result<AgentSessionLinkAutoWakeSnoozeMutationOutcome, AgentSessionLinkAutoWakeSnoozeFailure> {
        guard let session = agentSessionLinkAutoWakeSession(for: endpoint) else {
            return .failure(.observerUnavailable)
        }
        let snapshot = agentSessionLinkCurrentPassiveSnapshot(for: endpoint)
        let lane = snapshot?.autoWakeLanes.first { $0.reference == expectedReference }
        if let lane, lane.targetSessionID != targetSessionID {
            return .failure(.staleReference)
        }
        if case .set = command {
            // Set/extend is only meaningful for a lane that could otherwise admit a turn, so it
            // requires a current snapshot carrying the lane and a live effective selection. Clear
            // deliberately requires neither: a lane deselected or master-disabled after being snoozed
            // must still be releasable.
            guard let snapshot, let lane else { return .failure(.staleReference) }
            let selectedLanes = agentSessionLinkLiveSelectedAutoWakeLanes(snapshot, session: session)
            guard selectedLanes[lane.reference] != nil else {
                return .failure(.laneNotEffectivelySelected)
            }
        }

        let clock = session.oversight.snoozeClock
        let now = clock.now()
        var records = AgentSessionLinkAutoWakeSnooze.retainedRecords(
            session.oversight.autoWakeSnoozes,
            observerEndpoint: endpoint,
            currentReferences: snapshot.map { Set($0.autoWakeLanes.map(\.reference)) },
            now: now
        )
        let key = AgentSessionLinkAutoWakeSnoozeKey(
            observerEndpoint: endpoint,
            reference: expectedReference
        )
        let existing = records[key]
        let change: AgentSessionLinkAutoWakeSnoozeChange
        switch command {
        case let .set(durationSeconds):
            // The cap is a per-operation *remaining horizon*, never a lifetime cap: the deadline only
            // ever moves forward, so repeated operations may extend indefinitely while no single one
            // of them leaves more than an hour on the clock.
            let candidate = now.advanced(
                by: .seconds(AgentSessionLinkAutoWakeSnooze.clampedDurationSeconds(durationSeconds))
            )
            if let existing {
                if candidate > existing.deadline {
                    // Only an operation that moves the deadline later takes over the origin.
                    records[key] = AgentSessionLinkAutoWakeSnoozeRecord(
                        key: key,
                        deadline: candidate,
                        origin: origin
                    )
                    change = .extended
                } else {
                    change = .alreadySnoozed
                }
            } else {
                records[key] = AgentSessionLinkAutoWakeSnoozeRecord(
                    key: key,
                    deadline: candidate,
                    origin: origin
                )
                change = .snoozed
            }
        case .clear:
            if existing == nil {
                change = .alreadyClear
            } else {
                records.removeValue(forKey: key)
                change = .cleared
            }
        }

        // Truthful about the one thing a mutation cannot undo. Past this boundary the provider call
        // may already be running: a set applies only to later admission, and a clear cannot retract it.
        let currentDispatchAlreadyStarted = session.oversight.pendingAutoWake.map {
            $0.observerEndpoint == endpoint && $0.phase == .dispatching
        } ?? false

        agentSessionLinkCommitAutoWakeSnoozes(records, endpoint: endpoint, session: session)
        agentSessionLinkRearmAutoWakeSnoozeDeadlineTask(endpoint: endpoint, session: session)
        let projection = AgentSessionLinkAutoWakeSnoozeProjection.make(
            record: records[key],
            now: now,
            wallNow: clock.wallNow()
        )
        // Exactly one normal-pipeline reevaluation of the retained authoritative snapshot, for every
        // accepted command including `.alreadySnoozed` and `.alreadyClear`. No snapshot is fabricated:
        // with none published, the next authoritative publication performs the same evaluation.
        if let snapshot {
            agentSessionLinkNoteAutoWakeOpportunity(snapshot, endpoint: endpoint)
        }
        return .success(AgentSessionLinkAutoWakeSnoozeMutationOutcome(
            change: change,
            projection: projection,
            currentDispatchAlreadyStarted: currentDispatchAlreadyStarted
        ))
    }

    /// Drops snooze state whose exact observer incarnation is no longer live.
    ///
    /// Retirement, never transfer: an unlink, rebind, replacement, or teardown must leave the
    /// successor unsnoozed, and it must invalidate the task token so a resumed deadline callback
    /// cannot expire records the replacement never created.
    func agentSessionLinkPruneAutoWakeSnoozeState() {
        for (tabID, session) in sessions {
            guard !session.oversight.autoWakeSnoozes.isEmpty
                || session.oversight.snoozeTaskToken != nil
                || session.oversight.lastOversightWakeDispatch != nil
            else { continue }
            guard let endpoint = agentSessionLinkObserverEndpoint(tabID: tabID) else {
                session.oversight.retireSnoozeState()
                continue
            }
            // The wake stamp is endpoint-qualified, so a predecessor's timing already imposes no
            // delay; dropping it here keeps the state from outliving the incarnation that earned it.
            if let stamp = session.oversight.lastOversightWakeDispatch,
               stamp.observerEndpoint != endpoint
            {
                session.oversight.lastOversightWakeDispatch = nil
            }
            let retained = session.oversight.autoWakeSnoozes
                .filter { $0.key.observerEndpoint == endpoint }
            agentSessionLinkCommitAutoWakeSnoozes(retained, endpoint: endpoint, session: session)
            agentSessionLinkRearmAutoWakeSnoozeDeadlineTask(endpoint: endpoint, session: session)
        }
    }

    /// The one mutating cleanup boundary: remove due and stale records, re-arm, repaint if changed.
    ///
    /// It never invokes the wake pipeline. Every caller owns its own single reevaluation, which is
    /// what keeps "expiry causes exactly one evaluation" true even when cleanup runs twice.
    private func agentSessionLinkReconcileAutoWakeSnoozes(
        endpoint: DomainAgentSessionLinkEndpointIdentity,
        session: TabSession,
        currentReferences: Set<DomainAgentSessionLinkReference>?
    ) {
        // Deliberately broader than "are there snoozes?": the same task now also carries the routine
        // interval deadline, so an observer with no snooze records at all may still owe an arming.
        guard !session.oversight.autoWakeSnoozes.isEmpty
            || session.oversight.snoozeTaskToken != nil
            || session.oversight.lastOversightWakeDispatch != nil
        else { return }
        let cleaned = AgentSessionLinkAutoWakeSnooze.retainedRecords(
            session.oversight.autoWakeSnoozes,
            observerEndpoint: endpoint,
            currentReferences: currentReferences,
            now: session.oversight.snoozeClock.now()
        )
        agentSessionLinkCommitAutoWakeSnoozes(cleaned, endpoint: endpoint, session: session)
        agentSessionLinkRearmAutoWakeSnoozeDeadlineTask(endpoint: endpoint, session: session)
    }

    /// Publishes one map change through the existing monitor seams, or nothing at all.
    ///
    /// The single commit boundary for every snooze change — set, extend, clear, deadline expiry, and
    /// membership pruning all land here — which is exactly why the authoritative repaint belongs
    /// here and nowhere else. `requestUIRefresh` only re-renders the *cached* monitor props, and the
    /// snooze a row displays is overlaid when those props are published, so expiry without the
    /// projection refresh below would correctly release the lane while the row went on claiming it
    /// was snoozed until some unrelated target event happened along.
    @discardableResult
    private func agentSessionLinkCommitAutoWakeSnoozes(
        _ records: [AgentSessionLinkAutoWakeSnoozeKey: AgentSessionLinkAutoWakeSnoozeRecord],
        endpoint: DomainAgentSessionLinkEndpointIdentity,
        session: TabSession
    ) -> Bool {
        guard session.oversight.autoWakeSnoozes != records else { return false }
        // The setter feeds `noteMonitorObservationInputsChanged`; the repaint is this side's job.
        session.oversight.autoWakeSnoozes = records
        AgentSessionLinkRuntimeBridge.shared.requestObserverLocalPolicyRepaint(for: endpoint)
        requestUIRefresh(tabID: endpoint.tabID)
        return true
    }

    /// Maintains exactly one nearest-deadline task per observer session, for both policy deadlines.
    ///
    /// Snooze and interval expiry owe the same thing — one ordinary reevaluation of the retained
    /// snapshot — so they share one task, the earlier deadline wins, and simultaneous deadlines
    /// produce one evaluation.
    private func agentSessionLinkRearmAutoWakeSnoozeDeadlineTask(
        endpoint: DomainAgentSessionLinkEndpointIdentity,
        session: TabSession
    ) {
        let clock = session.oversight.snoozeClock
        let now = clock.now()
        let nextDeadline = session.oversight.nextAutoWakeDeadline(
            observerEndpoint: endpoint,
            now: now,
            includeRoutineInterval: agentSessionLinkRoutineIntervalDeferral(
                endpoint: endpoint,
                session: session
            ) != nil
        )
        session.oversight.snoozeDeadlineTask?.cancel()
        session.oversight.snoozeDeadlineTask = nil
        session.oversight.snoozeTaskToken = nil
        guard let nextDeadline else { return }
        let token = UUID()
        session.oversight.snoozeTaskToken = token
        session.oversight.snoozeDeadlineTask = Task { @MainActor [weak self] in
            do {
                try await clock.sleepUntil(nextDeadline)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.agentSessionLinkHandleAutoWakeSnoozeDeadline(
                endpoint: endpoint,
                token: token,
                deadline: nextDeadline
            )
        }
    }

    /// Fails closed on every axis before mutating anything.
    ///
    /// The token proves both that this task is the current arming *and* that the same session object
    /// still owns the state, because a replacement incarnation never inherits a token. A stale or
    /// superseded callback performs no cleanup and no reevaluation.
    private func agentSessionLinkHandleAutoWakeSnoozeDeadline(
        endpoint: DomainAgentSessionLinkEndpointIdentity,
        token: UUID,
        deadline: ContinuousClock.Instant
    ) {
        guard let session = agentSessionLinkAutoWakeSession(for: endpoint),
              session.oversight.snoozeTaskToken == token
        else { return }
        guard session.oversight.snoozeClock.now() >= deadline else {
            // Resumed early. Nothing is due, so re-arm rather than expire anything.
            agentSessionLinkRearmAutoWakeSnoozeDeadlineTask(endpoint: endpoint, session: session)
            return
        }
        session.oversight.snoozeDeadlineTask = nil
        session.oversight.snoozeTaskToken = nil
        guard let snapshot = agentSessionLinkCurrentPassiveSnapshot(for: endpoint) else {
            // No authoritative snapshot to reevaluate. Do the bookkeeping and stop: fabricating a
            // snapshot or a status edge here would invent content the queue never held.
            agentSessionLinkReconcileAutoWakeSnoozes(
                endpoint: endpoint,
                session: session,
                currentReferences: nil
            )
            return
        }
        // One explicit reevaluation of the retained authoritative snapshot, through the ordinary
        // publication entry point — which is also where the due records are removed and the next
        // deadline is armed.
        agentSessionLinkNoteAutoWakeOpportunity(snapshot, endpoint: endpoint)
    }

    private func agentSessionLinkCurrentPassiveSnapshot(
        for endpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> AgentSessionLinkPassiveStatusNotices.Snapshot? {
        guard let snapshot = agentSessionLinkPassiveNoticesBySessionID[endpoint.sessionID],
              snapshot.observerEndpoint == endpoint
        else { return nil }
        return snapshot
    }

    // MARK: Gates

    private func agentSessionLinkAutoWakeSession(
        for endpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> TabSession? {
        guard agentSessionLinkObserverEndpoint(tabID: endpoint.tabID) == endpoint,
              let session = sessions[endpoint.tabID]
        else {
            return nil
        }
        return session
    }

    /// The two routes a wake may take, or `nil` while the observer is not dispatchable at all.
    enum AutoWakeRoute: Equatable {
        /// Fully idle: start one typed system-origin follow-up run.
        case idleFollowUp
        /// Waiting for its own user's next instruction: resume that one-shot continuation instead of
        /// starting a second run alongside it.
        case waitingContinuation
    }

    /// ACP's prompt return is terminal, not an initial-send receipt. Its own ordinary instruction
    /// wait therefore yields execution ownership before that return; optional receipts stay with the
    /// captured transport callback. Never release a preparation/cancellation fence or a foreign run.
    func agentSessionLinkReleasePeriodicACPContinuationSlot(for session: TabSession) {
        guard let attempt = session.oversight.pendingAutoWake,
              attempt.isPeriodic, attempt.phase == .dispatching,
              attempt.physicalOutcome == .ambiguous,
              session.selectedAgent.acpProviderID != nil,
              let runAttemptID = session.activeRunAttemptID,
              attempt.periodicProducerDispatchID == .acpPromptTurn(runAttemptID: runAttemptID),
              sessions[session.tabID] === session,
              agentSessionLinkObserverEndpoint(tabID: session.tabID) == attempt.observerEndpoint,
              !session.hasPendingCodexHookReviewWait, !session.hasActiveCodexHookGateOperation,
              agentSessionLinkAutoWakeRoute(session) == .waitingContinuation else { return }
        // This is the reservation coordinator, not the producer. Do not cancel periodicProducerTask.
        attempt.task?.cancel()
        session.oversight.pendingAutoWake = nil
        session.noteMonitorObservationInputsChanged()
        agentSessionLinkDrainAutoWakeReevaluationIfOwed(session: session)
    }

    /// Which route, if any, this observer can take right now.
    ///
    /// Deliberately one function for both, so "is it safe to wake?" and "how would we wake?" cannot
    /// drift. A pending approval, question, input request, permission prompt, or review is never a
    /// route: answering one is a different capability than delivering an update, and lane data is
    /// never an interaction response.
    private func agentSessionLinkAutoWakeRoute(_ session: TabSession) -> AutoWakeRoute? {
        guard agentSessionLinkAutoWakeIsUnblocked(session) else { return nil }
        // `waitingPrompt`/`instructionContinuation` is ordinary "what next?" state, which the shared
        // blocker set above has already proven carries no interaction of its own.
        if session.instructionContinuation != nil, session.runState == .waitingForUser {
            return .waitingContinuation
        }
        guard !session.runState.isActive, session.runState != .waitingForUser else { return nil }
        return .idleFollowUp
    }

    /// Every blocker an inbound `send` has to clear, minus the two that describe the wake itself.
    ///
    /// Reused rather than restated so a blocker can never be enforced for one caller and forgotten
    /// for the other. `pendingOversightAutoWake` is excluded because *this* attempt is it, and the
    /// waiting-prompt pair is excluded because it is a route rather than a blocker.
    private func agentSessionLinkAutoWakeIsUnblocked(_ session: TabSession) -> Bool {
        session.hasLoadedPersistedState
            && !session.bindingTransitionInProgress
            && !session.terminalCommitInProgress
            && !session.mcpFollowUpRunPending
            && !session.isComposerSubmissionInFlight
            && !session.isPreparingInitialWorktree
            && !session.isChangingExecutionLocation
            && session.pendingInstructions.isEmpty
            && session.pendingACPSteeringInstructions.isEmpty
            && session.pendingClaudeSteeringInstructions.isEmpty
            && session.pendingAskUser == nil
            && session.pendingUserInputRequest == nil
            && session.pendingApproval == nil
            && session.pendingPermissionsRequest == nil
            && session.pendingMCPElicitationRequest == nil
            && session.pendingApplyEditsReview == nil
            && session.pendingWorktreeMergeReview == nil
    }

    /// All exact lanes carried by this authoritative queue publication, regardless of routine
    /// Auto-wake selection.
    private func agentSessionLinkAutoWakeLanesByReference(
        _ snapshot: AgentSessionLinkPassiveStatusNotices.Snapshot
    ) -> [DomainAgentSessionLinkReference: AgentSessionLinkPassiveStatusNotices.AutoWakeLane] {
        // Last wins rather than trapping if a malformed publication duplicates a reference. Every
        // attention occurrence still has to match the surviving lane's exact target identity.
        snapshot.autoWakeLanes.reduce(into: [:]) { lanes, lane in
            lanes[lane.reference] = lane
        }
    }

    /// The lanes this observer has selected for routine status/overflow Auto-wake **right now**.
    ///
    /// The snapshot supplies the lanes; the selection comes from the session, never from the lane's
    /// own `isEffectivelySelected`. That flag is a projection frozen when the lane was last
    /// published, and a toggle the user just flipped reaches it only on the next authoritative
    /// refresh. Scheduling and the acceptance fence both run on the same main actor as the selection
    /// write, so reading the setting directly is what linearizes them: routine status from a
    /// deselected lane cannot cross the transport boundary on the strength of a stale republication,
    /// and a freshly selected one is not left waiting for one.
    private func agentSessionLinkLiveSelectedAutoWakeLanes(
        _ snapshot: AgentSessionLinkPassiveStatusNotices.Snapshot,
        session: TabSession
    ) -> [DomainAgentSessionLinkReference: AgentSessionLinkPassiveStatusNotices.AutoWakeLane] {
        let oversight = session.oversight
        return snapshot.autoWakeLanes.reduce(into: [:]) { lanes, lane in
            guard oversight.isLaneEffectivelySelected(targetSessionID: lane.targetSessionID) else { return }
            lanes[lane.reference] = lane
        }
    }

    /// Whether the queue's unattributed overflow may reserve a wake on its own.
    ///
    /// `unacknowledgedOverflowCount` is a whole-queue count: it records that status edges were
    /// dropped, never which lane produced them. Treating "some lane is selected" as sufficient
    /// therefore lets an unselected target's dropped edges start an autonomous turn about a session
    /// the user deliberately excluded — the one thing per-target selection exists to prevent.
    ///
    /// The conservative rule, deliberately chosen over attributing overflow per link: overflow counts
    /// only when *every* live lane is selected, so the dropped edges provably cannot have come from
    /// an excluded one. Master-on satisfies it by construction, so the whole-observer case is
    /// unchanged. The cost is a missed wake for pure overflow while any lane is unselected, and the
    /// content stays owed to the next natural turn either way.
    ///
    /// One predicate for both scheduling and the acceptance fence: an attempt that could be reserved
    /// under a rule the fence does not share would be scheduled and then silently refused, or worse,
    /// accepted on a broader rule than the one that admitted it.
    private func agentSessionLinkOverflowAloneMayWake(
        _ snapshot: AgentSessionLinkPassiveStatusNotices.Snapshot,
        selectedLanes: [DomainAgentSessionLinkReference: AgentSessionLinkPassiveStatusNotices.AutoWakeLane],
        snoozedReferences: Set<DomainAgentSessionLinkReference>
    ) -> Bool {
        guard snapshot.unacknowledgedOverflowCount > 0, !snapshot.autoWakeLanes.isEmpty else {
            return false
        }
        // An active snooze on *any* live lane blocks pure overflow for exactly the reason an
        // unselected lane does: the dropped edges are unattributed, so they may have come from the
        // lane the user just silenced. The content stays owed to a natural turn either way.
        return snapshot.autoWakeLanes.allSatisfy {
            selectedLanes[$0.reference] != nil && !snoozedReferences.contains($0.reference)
        }
    }

    // MARK: Admission

    /// Everything one publication says about whether a wake may be admitted.
    ///
    /// One value rather than five recomputations: reservation, absorption, selection fencing, snooze
    /// mutation, deadline expiry, readiness settlement, and the physical-acquisition fence all read
    /// this, so an attempt can never be admitted under a rule the fence does not share.
    private struct AgentSessionLinkAutoWakeAdmission {
        /// The lanes that would admit routine status under selection and snooze alone — or, for a
        /// manual attempt, every exact live lane. Every other live lane is a hitchhiker: its rows
        /// still render in an admitted claim, but they are never the reason a turn starts.
        ///
        /// Deliberately *pre-interval*, because the timer and the countdown need the counterfactual.
        let routineLanesBeforeInterval:
            [DomainAgentSessionLinkReference: AgentSessionLinkPassiveStatusNotices.AutoWakeLane]
        /// At least one pending entry belongs to a pre-interval routine-admitting lane.
        let hasConcreteEntryBeforeInterval: Bool
        let overflowAloneMayWakeBeforeInterval: Bool
        /// Purposeful attention belongs to an exact live lane and deliberately ignores routine
        /// Auto-wake selection, that lane's snooze, and the routine interval. The request remains
        /// generation-qualified; it does not broaden status or overflow admission for that lane.
        let admittingAttentionOccurrences:
            [AgentSessionLinkPassiveStatusNotices.AttentionOccurrenceIdentity]
        /// The strictly-future routine-interval deadline currently deferring routine admission, or
        /// `nil` when limiting is off, elapsed, stamped by another incarnation, or bypassed.
        let routineDeferredUntil: ContinuousClock.Instant?
        /// Whether this calculation was made for the user's own `Wake now`.
        let isManual: Bool

        /// The lanes that may admit routine status *right now*.
        ///
        /// Emptied rather than merely reported while the interval defers: `routineLaneAdmits` is what
        /// the physical fence uses to tell a basis from a hitchhiker, so a boolean-only gate would
        /// still let a deferred rendered row justify a provider call.
        var routineAdmittingLanes:
            [DomainAgentSessionLinkReference: AgentSessionLinkPassiveStatusNotices.AutoWakeLane]
        {
            routineDeferredUntil == nil ? routineLanesBeforeInterval : [:]
        }

        var hasConcreteAdmittingEntry: Bool {
            routineDeferredUntil == nil && hasConcreteEntryBeforeInterval
        }

        var overflowAloneMayWake: Bool {
            routineDeferredUntil == nil && overflowAloneMayWakeBeforeInterval
        }

        var hasAdmissionBasis: Bool {
            hasConcreteAdmittingEntry
                || overflowAloneMayWake
                || !admittingAttentionOccurrences.isEmpty
        }

        /// Whether a status row from this lane counts as a routine basis rather than a hitchhiker.
        func routineLaneAdmits(_ reference: DomainAgentSessionLinkReference) -> Bool {
            routineAdmittingLanes[reference] != nil
        }

        /// The interval deadline that currently owes exactly one reevaluation, or `nil`.
        ///
        /// One truth behind both the armed deadline and the countdown: routine content would admit
        /// but for the interval, is not the shape already parked in suppression, and the provider
        /// context could carry it. Anything else would arm a timer for a wake that cannot happen.
        func routineDeferralOwingReevaluation(
            fingerprint: AgentSessionLinkPassiveStatusNotices.WakeEligibilityFingerprint,
            suppressed: AgentSessionLinkPassiveStatusNotices.WakeEligibilityFingerprint?,
            promptEligible: () -> Bool
        ) -> ContinuousClock.Instant? {
            guard let routineDeferredUntil,
                  hasConcreteEntryBeforeInterval || overflowAloneMayWakeBeforeInterval
            else {
                return nil
            }
            if let suppressed,
               admissionFingerprint(suppressed) == admissionFingerprint(fingerprint)
            {
                return nil
            }
            guard promptEligible() else { return nil }
            return routineDeferredUntil
        }

        /// The full fresh-reservation verdict, in the fixed order the pipeline asks its questions.
        ///
        /// `promptEligible` is a closure so the provider-context read happens only once the cheaper
        /// basis and suppression gates have passed, exactly as the inline guards it replaced did.
        func decision(
            fingerprint: AgentSessionLinkPassiveStatusNotices.WakeEligibilityFingerprint,
            suppressed: AgentSessionLinkPassiveStatusNotices.WakeEligibilityFingerprint?,
            promptEligible: () -> Bool
        ) -> AgentSessionLinkWakeAdmissionDecision {
            guard hasAdmissionBasis else {
                // Truthful only when the interval is the *sole* remaining delay; a suppressed or
                // prompt-ineligible queue keeps reporting the gate that would have refused it anyway.
                if routineDeferralOwingReevaluation(
                    fingerprint: fingerprint,
                    suppressed: suppressed,
                    promptEligible: promptEligible
                ) != nil {
                    return .suppress(.routineIntervalDeferred)
                }
                return .suppress(.noAdmissionBasis)
            }
            guard hasUnsuppressedAdmissionBasis(fingerprint: fingerprint, suppressed: suppressed) else {
                return .suppress(.failureSuppressed)
            }
            guard promptEligible() else { return .suppress(.promptIneligible) }
            // The user asked for this one explicitly, so it is neither a routine nor an attention
            // basis and must not be re-derived from queue state that deliberately did not admit it.
            if isManual { return .admit(.manual) }
            if let occurrence = requiredAttentionOccurrence(
                fingerprint: fingerprint,
                suppressed: suppressed
            ) {
                return .admit(.purposefulAttention(occurrence))
            }
            return .admit(.routineStatusOrOverflow)
        }

        private var hasOrdinaryAdmissionBasis: Bool {
            hasConcreteAdmittingEntry || overflowAloneMayWake
        }

        private var admittingAttentionOccurrenceSet:
            Set<AgentSessionLinkPassiveStatusNotices.AttentionOccurrenceIdentity>
        {
            Set(admittingAttentionOccurrences)
        }

        private func admissionFingerprint(
            _ fingerprint: AgentSessionLinkPassiveStatusNotices.WakeEligibilityFingerprint
        ) -> AgentSessionLinkPassiveStatusNotices.WakeEligibilityFingerprint {
            let admitted = admittingAttentionOccurrenceSet
            return AgentSessionLinkPassiveStatusNotices.WakeEligibilityFingerprint(
                queueEpoch: fingerprint.queueEpoch,
                edges: fingerprint.edges,
                attentionOccurrences: fingerprint.attentionOccurrences.filter(admitted.contains),
                overflowProduced: fingerprint.overflowProduced
            )
        }

        private func attentionFreeFingerprint(
            _ fingerprint: AgentSessionLinkPassiveStatusNotices.WakeEligibilityFingerprint
        ) -> AgentSessionLinkPassiveStatusNotices.WakeEligibilityFingerprint {
            AgentSessionLinkPassiveStatusNotices.WakeEligibilityFingerprint(
                queueEpoch: fingerprint.queueEpoch,
                edges: fingerprint.edges,
                attentionOccurrences: [],
                overflowProduced: fingerprint.overflowProduced
            )
        }

        func unsuppressedAdmittingAttentionOccurrences(
            suppressed: AgentSessionLinkPassiveStatusNotices.WakeEligibilityFingerprint?
        ) -> [AgentSessionLinkPassiveStatusNotices.AttentionOccurrenceIdentity] {
            guard !isManual, let suppressed else { return admittingAttentionOccurrences }
            let suppressedOccurrences = Set(suppressed.attentionOccurrences)
            return admittingAttentionOccurrences.filter {
                !suppressedOccurrences.contains($0)
            }
        }

        func ordinaryAdmissionBasisIsSuppressed(
            fingerprint: AgentSessionLinkPassiveStatusNotices.WakeEligibilityFingerprint,
            suppressed: AgentSessionLinkPassiveStatusNotices.WakeEligibilityFingerprint?
        ) -> Bool {
            guard hasOrdinaryAdmissionBasis, let suppressed else { return false }
            return attentionFreeFingerprint(suppressed) == attentionFreeFingerprint(fingerprint)
        }

        /// Whether the publication has a basis that is not the exact structural failure already
        /// parked in suppression.
        ///
        /// An attention occurrence without matching exact live lane membership is deliberately absent
        /// from `admittingAttentionOccurrences`, so stale authority cannot re-arm an otherwise
        /// suppressed status shape merely by changing the queue's full fingerprint.
        ///
        /// A manual attempt ignores suppression for itself alone, and neither clears nor rewrites the
        /// stored fingerprint, so a later automatic publication of the same shape stays suppressed.
        func hasUnsuppressedAdmissionBasis(
            fingerprint: AgentSessionLinkPassiveStatusNotices.WakeEligibilityFingerprint,
            suppressed: AgentSessionLinkPassiveStatusNotices.WakeEligibilityFingerprint?
        ) -> Bool {
            guard hasAdmissionBasis else { return false }
            if isManual { return true }
            guard let suppressed else { return true }
            return admissionFingerprint(suppressed) != admissionFingerprint(fingerprint)
        }

        /// Attention is required when no ordinary basis admits, or when attention is the only thing
        /// that makes an otherwise failure-suppressed ordinary shape new.
        func requiredAttentionOccurrence(
            fingerprint: AgentSessionLinkPassiveStatusNotices.WakeEligibilityFingerprint,
            suppressed: AgentSessionLinkPassiveStatusNotices.WakeEligibilityFingerprint?
        ) ->
            AgentSessionLinkPassiveStatusNotices.AttentionOccurrenceIdentity?
        {
            guard let first = admittingAttentionOccurrences.first else { return nil }
            let newlyAdmitting = unsuppressedAdmittingAttentionOccurrences(
                suppressed: suppressed
            )
            if !hasOrdinaryAdmissionBasis {
                if let newlyAdmitting = newlyAdmitting.first {
                    return newlyAdmitting
                }
                guard let suppressed else { return first }
                // If the queue reverted to the exact projected failure, the old occurrence is not
                // a replacement basis. Returning nil preserves the already-required successor so
                // preparation fails closed. A distinct non-attention structural change retains the
                // legacy fingerprint re-arm and may still use the rendered occurrence.
                guard admissionFingerprint(suppressed) != admissionFingerprint(fingerprint) else {
                    return nil
                }
                return first
            }
            guard ordinaryAdmissionBasisIsSuppressed(
                fingerprint: fingerprint,
                suppressed: suppressed
            ) else { return nil }
            return newlyAdmitting.first
        }
    }

    /// Resolves the admission calculation against live session state and the monotonic clock.
    ///
    /// Elapsed records are treated as inactive here, before any cleanup runs, so a delayed deadline
    /// task — snooze or interval — can never keep a lane suppressed past its own deadline.
    ///
    /// `basis` is the reservation this evaluation belongs to, or `nil` for ordinary policy. Only
    /// `.manual` changes it, and only three inputs: every exact live lane admits, snoozes do not
    /// filter, and the interval does not defer. None of the three is written.
    private func agentSessionLinkAutoWakeAdmission(
        _ snapshot: AgentSessionLinkPassiveStatusNotices.Snapshot,
        session: TabSession,
        endpoint: DomainAgentSessionLinkEndpointIdentity,
        basis: AgentSessionLinkWakeAdmissionDecision.Basis? = nil
    ) -> AgentSessionLinkAutoWakeAdmission {
        let lanesByReference = agentSessionLinkAutoWakeLanesByReference(snapshot)
        let isManual = basis == .manual
        let selectedLanes = isManual
            ? lanesByReference
            : agentSessionLinkLiveSelectedAutoWakeLanes(snapshot, session: session)
        let snoozedReferences = isManual
            ? []
            : session.oversight.activeSnoozedReferences(observerEndpoint: endpoint)
        let routineLanes = selectedLanes.filter { !snoozedReferences.contains($0.key) }
        return AgentSessionLinkAutoWakeAdmission(
            routineLanesBeforeInterval: routineLanes,
            hasConcreteEntryBeforeInterval: snapshot.entries.contains {
                routineLanes[$0.reference] != nil
            },
            overflowAloneMayWakeBeforeInterval: agentSessionLinkOverflowAloneMayWake(
                snapshot,
                selectedLanes: selectedLanes,
                snoozedReferences: snoozedReferences
            ),
            admittingAttentionOccurrences: snapshot.attentionRequests.compactMap { request in
                guard agentSessionLinkAttentionRequestMatchesExactCurrentLane(
                    request,
                    snapshot: snapshot,
                    lanesByReference: lanesByReference
                ) else {
                    return nil
                }
                return request.occurrence
            },
            routineDeferredUntil: isManual
                ? nil
                : session.oversight.routineWakeIntervalDeferral(
                    observerEndpoint: endpoint,
                    now: session.oversight.snoozeClock.now()
                ),
            isManual: isManual
        )
    }

    /// Resolves the fresh-reservation verdict for one publication, reading the provider context only
    /// if the basis and suppression gates pass.
    private func agentSessionLinkWakeAdmissionDecision(
        _ admission: AgentSessionLinkAutoWakeAdmission,
        fingerprint: AgentSessionLinkPassiveStatusNotices.WakeEligibilityFingerprint,
        session: TabSession
    ) -> AgentSessionLinkWakeAdmissionDecision {
        admission.decision(
            fingerprint: fingerprint,
            suppressed: session.oversight.suppressedWakeFingerprint,
            promptEligible: { agentSessionLinkPromptContext(for: session)?.epoch.allowsSupplement == true }
        )
    }

    /// Linearizes one Auto-wake selection change with scheduling and the acceptance fence.
    ///
    /// Runs synchronously, in the same main-actor step as the setting write, so it retracts a routine
    /// attempt the change just made ineligible rather than leaving it alive until something else
    /// happens to re-evaluate it. An exact attention-backed attempt remains eligible by design.
    func agentSessionLinkFenceAutoWakeSelectionChange(
        for endpoint: DomainAgentSessionLinkEndpointIdentity
    ) {
        // Also the interval fence: a limit switched on while a routine attempt is merely scheduled
        // retracts it here, in the same main-actor step as the write, rather than leaving it alive
        // until some unrelated publication happens along. Attention-backed and manual attempts are
        // evaluated under their own basis and survive by design.
        guard let session = agentSessionLinkAutoWakeSession(for: endpoint),
              let attempt = session.oversight.pendingAutoWake,
              attempt.phase != .cancelledBeforeDispatch,
              !agentSessionLinkAutoWakeAttemptIsStillEligible(attempt, session: session)
        else { return }
        cancelAgentSessionLinkAutoWake(for: endpoint, reason: .eligibilityLost)
    }

    /// The shared final fence, evaluated identically at readiness settlement, selection changes, and
    /// the physical-acquisition boundary.
    ///
    /// It reads live selection and live snoozes for routine status/overflow. Exact purposeful
    /// attention deliberately bypasses those two policy controls but must still satisfy every exact
    /// occurrence, authority, claim, readiness, and transport gate represented here.
    func agentSessionLinkAutoWakeAttemptIsStillEligible(
        _ attempt: AgentSessionLinkAutoWakeAttempt,
        session: TabSession
    ) -> Bool {
        if attempt.isPeriodic {
            return agentSessionLinkPeriodicWakeIsEligible(session, endpoint: attempt.observerEndpoint, requiresReadyCatalog: false)
        }
        guard sessions[attempt.observerEndpoint.tabID] === session,
              agentSessionLinkObserverEndpoint(tabID: attempt.observerEndpoint.tabID)
              == attempt.observerEndpoint,
              let snapshot = agentSessionLinkPassiveNoticesBySessionID[attempt.observerEndpoint.sessionID],
              snapshot.observerEndpoint == attempt.observerEndpoint,
              snapshot.queueEpoch == attempt.queueEpoch,
              snapshot.isDeliverable,
              snapshot.hasDeliverableContent
        else { return false }
        let admission = agentSessionLinkAutoWakeAdmission(
            snapshot,
            session: session,
            endpoint: attempt.observerEndpoint,
            basis: attempt.admissionBasis
        )
        return admission.hasAdmissionBasis
    }

    /// Whether an undispatchable observer is merely busy rather than gone.
    private func agentSessionLinkAutoWakeMayStillSettle(_ session: TabSession) -> Bool {
        guard let attempt = session.oversight.pendingAutoWake else { return false }
        return agentSessionLinkAutoWakeAttemptIsStillEligible(attempt, session: session)
    }

    private func agentSessionLinkSetAutoWakePhase(
        _ phase: AgentSessionLinkAutoWakeAttempt.Phase,
        wakeID: UUID,
        endpoint: DomainAgentSessionLinkEndpointIdentity
    ) {
        guard let session = sessions[endpoint.tabID],
              var attempt = session.oversight.pendingAutoWake,
              attempt.wakeID == wakeID
        else {
            return
        }
        guard attempt.phase != phase else { return }
        attempt.phase = phase
        session.oversight.pendingAutoWake = attempt
    }

    private func agentSessionLinkLogAutoWakeGate(
        _ endpoint: DomainAgentSessionLinkEndpointIdentity,
        _ fingerprint: AgentSessionLinkPassiveStatusNotices.WakeEligibilityFingerprint?,
        _ decision: String
    ) {
        #if DEBUG
            // Identity, structural shape, and decision only. Never a name, a preview, or any other
            // target-derived content.
            AgentModePerfDiagnostics.event(
                "sessionLink.autoWake",
                tabID: endpoint.tabID,
                fields: [
                    "session": endpoint.sessionID.uuidString,
                    "edges": String(fingerprint?.edges.count ?? 0),
                    "attention": String(fingerprint?.attentionOccurrences.count ?? 0),
                    "overflow": String(fingerprint?.overflowProduced ?? 0),
                    "decision": decision
                ]
            )
        #else
            _ = (endpoint, fingerprint, decision)
        #endif
    }
}

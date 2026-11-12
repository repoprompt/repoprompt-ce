import Foundation
import RepoPromptInstrumentation

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
    /// Periodic producer fence captured at reservation. Notification wakes capture at preparation.
    var stopFence: AgentRunStartStopFence?
    var queueEpoch: UUID? {
        queue?.epoch
    }

    var wakeFingerprint: AgentSessionLinkPassiveStatusNotices.WakeEligibilityFingerprint? {
        queue?.fingerprint
    }

    /// Captured producer identity, independent of whether a supplement was owed.
    /// Nonsemantic shared lifetime, never claim/cache identity. Provider locals retain it across awaits.
    var quietMarkerProducerLifetime: AgentQuietMarkerProducerLifetime?
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
    /// Original idle-route candidacy, not catalog proof. Can upgrade only before acquisition.
    var routineQuietCandidate = false
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
        task: Task<Void, Never>?,
        stopFence: AgentRunStartStopFence? = nil
    ) {
        self.wakeID = wakeID
        self.observerEndpoint = observerEndpoint
        self.stopFence = stopFence
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
    /// User or managed Stop: never proves a physical provider call was absent.
    case userStop = "user_stop"
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
    typealias AutoWakeRoute = AgentSessionLinkExecutionRuntime.AutoWakeRoute
}

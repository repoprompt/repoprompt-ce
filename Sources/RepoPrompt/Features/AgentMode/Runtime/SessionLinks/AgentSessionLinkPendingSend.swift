import Foundation
import RepoPromptDomainRuntime

// MARK: - Pending entry

/// One pre-authorized send waiting for its target to become sendable.
///
/// Ephemeral by construction. It exists only in the bridge's main-actor map, is keyed by the exact
/// link ID **and generation** it was admitted under, and is never written anywhere durable: unlink,
/// rebind, endpoint drift, either side closing, shutdown, and relaunch all end it rather than
/// migrate it. There is at most one per link generation, and no scheduler, timer, or queue manager
/// owns it — every drain is triggered by an event that already exists.
///
/// An entry is not proof that some particular local user turn authorized this message. It is a
/// grant-authorized request accepted into the one-slot convenience queue under the trusted prompt
/// contract: the user's exact direct grant is the delegation, and the observer is responsible for
/// only queueing in service of an explicit current or standing instruction from its own user.
///
/// The values captured here are frozen on purpose. `workflow` in particular is resolved once, at
/// admission, so a later rename or delete cannot change what a queued message runs under.
struct AgentSessionLinkPendingSend: Equatable {
    /// How far the entry has travelled toward the authority commit fence.
    ///
    /// `committing` is the cancellation cutoff. It is taken on the bridge's main actor immediately
    /// before the authority hop, so a cancel or replace arriving while that hop is suspended reports
    /// `too_late` rather than claiming to have stopped a delivery that is already settling.
    enum Phase: Equatable {
        case pending
        case draining
        case committing
        case committed

        /// Whether replace/cancel may still invalidate this entry.
        var isCancellable: Bool {
            switch self {
            case .pending, .draining: true
            case .committing, .committed: false
            }
        }
    }

    /// Why the entry is waiting, and therefore which event may retrigger it.
    ///
    /// This is bookkeeping for event routing, never a retry timer: nothing re-drains an entry until
    /// one of these facts actually changes.
    enum ParkReason: Equatable, Hashable {
        /// Freshly queued, or returned by a target that was busy or still loading. The next accepted
        /// readiness publication for that target retriggers it.
        case targetReadiness
        /// Another send on this same link is still settling. Settlement on that link retriggers it.
        case sendInProgress
        /// The authority-wide in-flight send ceiling is saturated. Any send settlement, on any link,
        /// may free a slot and therefore retriggers it.
        case ledgerSaturated
    }

    /// Identifies this exact entry incarnation.
    ///
    /// A replacement allocates a new one rather than mutating in place, so a drain suspended across
    /// the replacement compares out and can never commit the message it superseded.
    let revision: UUID
    let reference: DomainAgentSessionLinkReference
    /// The exact granted observer incarnation, not merely its session UUID: the drain reauthorizes
    /// against this, and a duplicate live incarnation of the same UUID must not inherit the entry.
    let observerEndpoint: DomainAgentSessionLinkEndpointIdentity
    let targetSessionID: UUID
    let message: String
    let idempotencyKey: String
    /// Message bytes plus the caller's canonical workflow selector — never the resolved workflow's
    /// mutable contents, so an idempotent retry survives an edit to the template it names.
    let requestDigest: String
    /// Resolved once, at admission, and never re-read.
    let workflow: AgentWorkflowDefinition?
    let queuedAt: Date
    var phase: Phase
    var parkReason: ParkReason
    /// Drain triggers that arrived while this entry was suspended in `.draining`.
    ///
    /// A drain reads the target and the ledger once and only decides how to park several awaits
    /// later. An event that lands inside that window finds an entry that is not `.pending`, so it
    /// has nothing to schedule — and it may be the only edge the resulting park will ever wait for.
    /// With no timer and no polling behind it, dropping that edge strands the message permanently.
    ///
    /// Recorded here and consumed by the park it raced. Deliberately a set of park reasons rather
    /// than a single "something happened" flag: only a trigger that releases the park actually taken
    /// may re-drive it. A coarser record would let two entries draining over each other re-drive one
    /// another on their own settlements, which is a livelock rather than a fence.
    var missedDrainTriggers: Set<ParkReason>

    init(
        revision: UUID,
        reference: DomainAgentSessionLinkReference,
        observerEndpoint: DomainAgentSessionLinkEndpointIdentity,
        targetSessionID: UUID,
        message: String,
        idempotencyKey: String,
        requestDigest: String,
        workflow: AgentWorkflowDefinition?,
        queuedAt: Date,
        phase: Phase = .pending,
        parkReason: ParkReason = .targetReadiness,
        missedDrainTriggers: Set<ParkReason> = []
    ) {
        self.revision = revision
        self.reference = reference
        self.observerEndpoint = observerEndpoint
        self.targetSessionID = targetSessionID
        self.message = message
        self.idempotencyKey = idempotencyKey
        self.requestDigest = requestDigest
        self.workflow = workflow
        self.queuedAt = queuedAt
        self.phase = phase
        self.parkReason = parkReason
        self.missedDrainTriggers = missedDrainTriggers
    }

    // MARK: Lossless drain triggers

    /// The park reasons one accepted target-readiness publication releases.
    ///
    /// Every reason, not just `.targetReadiness`: an entry may have parked on the ledger while the
    /// target happened to be busy, and proof that the target moved is worth re-evaluating whatever
    /// it parked on. This is the same breadth the immediate trigger has always had.
    static let parkReasonsReleasedByTargetReadiness: Set<ParkReason> = [
        .targetReadiness,
        .sendInProgress,
        .ledgerSaturated
    ]

    /// The park reasons one settled send releases for an entry on `reference`.
    ///
    /// Same-link settlement releases an entry parked behind that link's in-flight send; settlement
    /// on *any* link may free an authority-wide slot, so ledger-saturated entries are re-evaluated
    /// across links. A target-readiness park is untouched: nothing about the target changed, and its
    /// own readiness publication is still coming.
    static func parkReasonsReleased(
        bySendSettlementOn settled: DomainAgentSessionLinkReference,
        forEntryOn reference: DomainAgentSessionLinkReference
    ) -> Set<ParkReason> {
        settled == reference ? [.sendInProgress, .ledgerSaturated] : [.ledgerSaturated]
    }

    /// Opens a drain window: everything recorded so far is about to be observed first-hand.
    mutating func beginDrainWindow() {
        phase = .draining
        missedDrainTriggers = []
    }

    /// Records triggers that raced this entry's in-flight drain.
    mutating func noteMissedDrainTriggers(_ reasons: Set<ParkReason>) {
        missedDrainTriggers.formUnion(reasons)
    }

    /// Parks the entry and reports whether the edge it is now waiting for already passed.
    ///
    /// The record is cleared either way. A trigger that does not release *this* park is genuinely
    /// spent: the entry is now waiting on a different fact, whose own event has not happened yet and
    /// will be delivered normally.
    mutating func park(reason: ParkReason) -> Bool {
        phase = .pending
        parkReason = reason
        let releasedMidDrain = missedDrainTriggers.contains(reason)
        missedDrainTriggers = []
        return releasedMidDrain
    }

    /// Bounded single-line preview for the queue owner's own `poll`.
    ///
    /// Reuses the same normalizer every other agent-facing text field goes through, so a queued body
    /// cannot smuggle control characters or newlines into a response through this field.
    var messagePreview: String? {
        DomainAgentSessionLinkTextBudget.normalized(
            message,
            maxBytes: DomainAgentSessionLinkTextBudget.assistantPreviewMaxBytes
        )
    }

    // MARK: Slot arbitration

    /// What one `when_sendable` admission does to the link's single slot.
    enum SlotDecision: Equatable {
        /// Same key, same effective payload: an idempotent replay of the entry already installed.
        /// Nothing is re-resolved, so a retry survives a workflow the user renamed in between.
        case replay(revision: UUID)
        /// Same key, different effective payload. Delivers neither.
        case conflict
        /// A different entry holds the slot and no replacement was requested.
        case occupied
        /// The current entry already crossed its commit cutoff, so it cannot be displaced.
        case tooLate
        case install(replaced: Bool)
    }

    /// Pure arbitration for the one slot, decided from the current entry alone.
    ///
    /// Factored out because the caller has to run it twice — once before it resolves anything, and
    /// again after those awaits — and the two evaluations must be the same rules rather than two
    /// hand-written approximations of them.
    static func slotDecision(
        current: AgentSessionLinkPendingSend?,
        idempotencyKey: String,
        requestDigest: String,
        replacePending: Bool
    ) -> SlotDecision {
        guard let current else { return .install(replaced: false) }
        guard current.idempotencyKey != idempotencyKey else {
            return current.requestDigest == requestDigest
                ? .replay(revision: current.revision)
                : .conflict
        }
        guard replacePending else { return .occupied }
        guard current.phase.isCancellable else { return .tooLate }
        return .install(replaced: true)
    }
}

// MARK: - Terminal outcome

/// Ledger rejections a queued entry settles on.
///
/// A strict subset of the immediate-send rejections: the transient ones (`send_already_in_progress`,
/// `delivery_ledger_full`) park the entry and wait for a settlement instead of ending it, and the
/// authorization failures end the link rather than the entry.
enum AgentSessionLinkPendingSendRejection: String, Equatable {
    case idempotencyConflict = "idempotency_conflict"
    /// Not transient: retained outcomes are released only when a link generation is revoked or the
    /// runtime restarts, so re-queuing can only be re-rejected.
    case deliveryLedgerExhausted = "delivery_ledger_exhausted"

    /// The immediate-send rejection this corresponds to.
    ///
    /// Mapped rather than duplicated so a queued failure and the identical immediate one keep one
    /// set of wire strings, one retryability rule, and one explanatory sentence.
    var sendRejection: AgentSessionLinkRuntimeBridge.SendRejection {
        switch self {
        case .idempotencyConflict: .idempotencyConflict
        case .deliveryLedgerExhausted: .deliveryLedgerExhausted
        }
    }
}

/// How one queued entry finished.
enum AgentSessionLinkPendingSendOutcome: Equatable {
    case delivered(DomainAgentSessionLinkSendReceipt)
    /// The target transaction ran and refused.
    case failed(AgentSessionLinkSendFailure)
    /// The authority ledger refused permanently, before the target was touched.
    case rejected(AgentSessionLinkPendingSendRejection)
}

/// The single terminal outcome one link retains for its observer's `poll`.
///
/// Deliberately one overwritable slot rather than a history or a notification subsystem: it is
/// replaced by the next queue mutation, dropped with the link, and never persisted.
struct AgentSessionLinkPendingSendResult: Equatable {
    /// The entry incarnation this outcome settled. Lets an admission that just ran a drain tell its
    /// *own* terminal outcome apart from one an earlier entry left behind.
    let revision: UUID
    let idempotencyKey: String
    let outcome: AgentSessionLinkPendingSendOutcome
    let settledAt: Date
}

/// One link's observer-facing queue state, read for `poll` and `wait`.
///
/// Scoped to an exact link generation, so a re-added pair starts empty and no observer can ever see
/// another observer's queue: the only way to obtain one is through a lease this observer holds.
struct AgentSessionLinkPendingSendProjection: Equatable {
    let pending: AgentSessionLinkPendingSend?
    let lastResult: AgentSessionLinkPendingSendResult?

    static let empty = AgentSessionLinkPendingSendProjection(pending: nil, lastResult: nil)

    var isEmpty: Bool {
        pending == nil && lastResult == nil
    }
}

// MARK: - Queue results

/// Stable queue-state results. Raw values are the wire strings `agent_session_link` returns.
enum AgentSessionLinkQueueResult: String, Equatable {
    /// The entry is pending. `replaced`/`duplicate` are reported beside it.
    case queued
    /// A different entry already occupies this link's one slot and `replace_pending` was not set.
    case pendingSendExists = "pending_send_exists"
    case cancelled
    case notPending = "not_pending"
    /// The supplied key does not identify the current entry, so a stale cancel cannot remove a
    /// newer replacement.
    case pendingSendMismatch = "pending_send_mismatch"
    /// The drain crossed the main-actor commit cutoff; the target transaction owns the result.
    case tooLate = "too_late"
}

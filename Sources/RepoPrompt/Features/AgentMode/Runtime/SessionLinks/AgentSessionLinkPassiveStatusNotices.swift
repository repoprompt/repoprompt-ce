import Foundation
import RepoPromptDomainRuntime

/// Observer-local, process-memory coalescing for passive target status notices.
///
/// This is the canonical observer-local queue — one of the four deliberately disjoint owners of
/// the oversight subsystem. It coordinates with `AgentModeViewModel+SessionLinks` (which
/// reconciles authoritative samples into it), `AgentSessionLinkPromptContext` (which renders a
/// snapshot and applies the occurrence-qualified receipt back), and
/// `AgentModeViewModel+SessionLinkAutoWake` (which reads `wakeEligibilityFingerprint` and the
/// lanes to decide admission). Invariants: one coalesced first-to-final status interval per lane
/// with no event history, so the only honest summary of a snoozed lane is "the current coalesced
/// state"; attention occurrences are separate, non-lossy, hard-capped at enqueue, and never evict
/// or consume a status interval; and a receipt removes only what its own rendered batch named.
///
/// This reducer owns no authority and performs no delivery. Callers reconcile authoritative samples,
/// publish `snapshot`, and apply only receipts produced by an accepted provider dispatch.
struct AgentSessionLinkPassiveStatusNotices {
    static let maximumPendingTargetCount = 16
    /// Attention is accepted only while a free slot exists. Unlike status detail, it is never
    /// evicted into unattributed overflow after the target was told its request was accepted.
    static let maximumPendingAttentionRequestCount = 16

    enum Status: String, CaseIterable, Hashable {
        case idle
        case running
        case waiting
        case unavailable
    }

    struct AutoWakeLane: Hashable {
        let reference: DomainAgentSessionLinkReference
        let targetEndpoint: DomainAgentSessionLinkEndpointIdentity
        let targetSessionID: UUID
        /// The observer's routine status/overflow Auto-wake selection for this lane **as of
        /// publication**.
        ///
        /// A projection, not the authority: selection is live session state the user can flip at any
        /// time, and this snapshot is republished only on the next authoritative refresh. The
        /// auto-wake coordinator therefore reads the session's own selection for routine admission
        /// rather than this flag. Exact purposeful attention deliberately ignores routine selection;
        /// it still uses this lane's exact reference and target identity as hard authority gates.
        let isEffectivelySelected: Bool
    }

    struct Sample: Hashable {
        let reference: DomainAgentSessionLinkReference
        let targetEndpoint: DomainAgentSessionLinkEndpointIdentity
        let targetSessionID: UUID
        let displayName: String?
        let status: Status
        /// The target's readiness at this observation. A point-in-time fact, never a reservation.
        ///
        /// Forced false unless the sample is idle: a running or waiting target is not sendable, and
        /// letting an upstream projection assert otherwise would put a claim in the prompt that the
        /// send admission matrix would immediately refuse.
        let idleForSend: Bool
        let idleSince: Date?
        let waitingOn: DomainAgentSessionWaitingOn?
        let latestVisibleAssistantPreview: String?
        /// Proof from this exact publication only; nil never means zero.
        var runFacts: AgentRunQuietFacts?

        init(
            reference: DomainAgentSessionLinkReference,
            targetEndpoint: DomainAgentSessionLinkEndpointIdentity,
            targetSessionID: UUID,
            displayName: String?,
            status: Status,
            idleForSend: Bool = false,
            idleSince: Date? = nil,
            waitingOn: DomainAgentSessionWaitingOn? = nil,
            latestVisibleAssistantPreview: String? = nil,
            runFacts: AgentRunQuietFacts? = nil
        ) {
            self.runFacts = runFacts
            self.reference = reference
            self.targetEndpoint = targetEndpoint
            self.targetSessionID = targetSessionID
            self.displayName = DomainAgentSessionLinkTextBudget.normalized(
                displayName,
                maxBytes: DomainAgentSessionLinkTextBudget.displayNameMaxBytes
            )
            self.status = status
            self.idleForSend = status == .idle && idleForSend
            self.idleSince = status == .idle ? idleSince : nil
            self.waitingOn = waitingOn
            self.latestVisibleAssistantPreview = DomainAgentSessionLinkTextBudget.normalized(
                latestVisibleAssistantPreview,
                maxBytes: DomainAgentSessionLinkTextBudget.assistantPreviewMaxBytes
            )
        }
    }

    struct PendingEntry: Hashable {
        let reference: DomainAgentSessionLinkReference
        let targetEndpoint: DomainAgentSessionLinkEndpointIdentity
        let targetSessionID: UUID
        let displayName: String?
        /// First status of the still-pending interval, never overwritten by a later edge.
        let fromStatus: Status
        /// Status at the newest authoritative observation.
        let toStatus: Status
        /// When this reducer processed the newest sample represented by the line.
        ///
        /// Deliberately the reducer's own clock rather than the target's `lastActivityAt`: the agent
        /// is being told when RepoPrompt observed the status/readiness metadata it is about to use.
        /// A same-status metadata refresh updates this time without changing `edgeSequence`.
        let observedAt: Date
        let idleForSend: Bool
        let idleSince: Date?
        let waitingOn: DomainAgentSessionWaitingOn?
        let latestVisibleAssistantPreview: String?
        let changeSequence: UInt64
        /// Identity of the *status edge* that created or last advanced this entry.
        ///
        /// Distinct from `changeSequence`, which also advances for a metadata-only refresh. This one
        /// moves only when a status transition creates or advances the interval, so it answers the
        /// question failure suppression actually asks: "is this the same occurrence I already failed
        /// to deliver, or a genuinely new one that happens to have the same shape?"
        ///
        /// Without it, an acknowledged `running → idle` followed later by an independent
        /// `running → idle` for the same target produces a byte-identical structural fingerprint
        /// inside one queue epoch, and a single failed attempt would suppress every future identical
        /// transition for the life of the link.
        let edgeSequence: UInt64
        /// This row's current paired proof. Never filled from the observation cache or old receipt.
        let runFacts: AgentRunQuietFacts?
        /// The immutable payable cutoff; a same-status unpaired refresh may retain an older one.
        let receiptSettledThrough: UInt64?
        /// Known same-endpoint coverage survives unknown current proof.
        let ordinaryThrough: UInt64?
        /// Opening cutoff from a preceding fresh observation, preserved through coalescing.
        /// Never reconstructed from the representation cache or a later closing cutoff.
        let openingSettledThrough: UInt64?

        /// Read-only snapshot projection of the reducer's ONE live position, not another counter,
        /// receipt cutoff, or debt flag. Only snapshot construction writes this value copy.
        fileprivate var deliveredThroughAtSnapshot: UInt64?

        var isStatusEdge: Bool {
            Self.isStatusEdge(from: fromStatus, to: toStatus)
        }

        var isRoutineWakeEligible: Bool {
            let freshIdle = toStatus == .idle && runFacts != nil
            let unpaid = ordinaryThrough.map { ordinary in
                deliveredThroughAtSnapshot.map { ordinary > $0 } ?? true
            } ?? false
            if freshIdle, let runFacts, let openingSettledThrough,
               runFacts.settledThrough > openingSettledThrough,
               let deliveredThroughAtSnapshot, runFacts.ordinaryThrough <= deliveredThroughAtSnapshot
            {
                return false
            }
            return isStatusEdge || (freshIdle && unpaid)
        }

        fileprivate static func isStatusEdge(from: Status, to: Status) -> Bool {
            from != to && (
                (from == .running && to == .idle)
                    || (to == .waiting && from != .unavailable)
                    || (from == .waiting && to == .idle)
            )
        }

        /// Explicit rather than memberwise so the enriched fields can default.
        ///
        /// The reducer always supplies all of them; the defaults exist so a caller that only cares
        /// about the transition — a renderer fixture, say — does not have to invent a timestamp and a
        /// readiness bit to state one. `edgeSequence` defaults to `changeSequence` because a freshly
        /// stated entry has had exactly one edge and no refresh.
        init(
            reference: DomainAgentSessionLinkReference,
            targetEndpoint: DomainAgentSessionLinkEndpointIdentity,
            targetSessionID: UUID,
            displayName: String?,
            fromStatus: Status,
            toStatus: Status,
            observedAt: Date = Date(),
            idleForSend: Bool = false,
            idleSince: Date? = nil,
            waitingOn: DomainAgentSessionWaitingOn? = nil,
            latestVisibleAssistantPreview: String? = nil,
            changeSequence: UInt64,
            edgeSequence: UInt64? = nil,
            runFacts: AgentRunQuietFacts? = nil,
            receiptSettledThrough: UInt64? = nil,
            ordinaryThrough: UInt64? = nil,
            openingSettledThrough: UInt64? = nil
        ) {
            self.runFacts = runFacts
            self.receiptSettledThrough = receiptSettledThrough ?? runFacts?.settledThrough
            self.ordinaryThrough = ordinaryThrough ?? runFacts?.ordinaryThrough
            self.openingSettledThrough = openingSettledThrough
            self.edgeSequence = edgeSequence ?? changeSequence
            self.reference = reference
            self.targetEndpoint = targetEndpoint
            self.targetSessionID = targetSessionID
            self.displayName = displayName
            self.fromStatus = fromStatus
            self.toStatus = toStatus
            self.observedAt = observedAt
            self.idleForSend = idleForSend
            self.idleSince = idleSince
            self.waitingOn = waitingOn
            self.latestVisibleAssistantPreview = latestVisibleAssistantPreview
            self.changeSequence = changeSequence
        }

        fileprivate func hasSameFinalMetadata(as sample: Sample) -> Bool {
            displayName == sample.displayName
                && idleForSend == sample.idleForSend
                && idleSince == sample.idleSince
                && waitingOn == sample.waitingOn
                && latestVisibleAssistantPreview == sample.latestVisibleAssistantPreview
        }
    }

    /// Immutable identity of one accepted attention occurrence.
    ///
    /// The queue epoch fences reducer replacement, the generation-qualified reference fences
    /// unlink/relink, and the sequence distinguishes a successor request on the same live grant from
    /// an older occurrence whose receipt may still arrive.
    struct AttentionOccurrenceIdentity: Hashable {
        let queueEpoch: UUID
        let reference: DomainAgentSessionLinkReference
        let attentionSequence: UInt64
    }

    /// One first-wins request for the observer to notice this exact oversight lane.
    ///
    /// `occurrence` and `requestedAt` never change. Everything else is current presentation context
    /// refreshed by authoritative status reconciliation, so a standalone request can become richer
    /// without becoming a new request or changing failure-suppression identity.
    struct PendingAttentionRequest: Hashable {
        let occurrence: AttentionOccurrenceIdentity
        let targetEndpoint: DomainAgentSessionLinkEndpointIdentity
        let targetSessionID: UUID
        let requestedAt: Date
        let displayName: String?
        let status: Status
        let observedAt: Date
        let idleForSend: Bool
        let idleSince: Date?
        let waitingOn: DomainAgentSessionWaitingOn?
        let latestVisibleAssistantPreview: String?

        var reference: DomainAgentSessionLinkReference {
            occurrence.reference
        }

        init(
            occurrence: AttentionOccurrenceIdentity,
            targetEndpoint: DomainAgentSessionLinkEndpointIdentity,
            targetSessionID: UUID,
            requestedAt: Date,
            displayName: String? = nil,
            status: Status,
            observedAt: Date? = nil,
            idleForSend: Bool = false,
            idleSince: Date? = nil,
            waitingOn: DomainAgentSessionWaitingOn? = nil,
            latestVisibleAssistantPreview: String? = nil
        ) {
            self.occurrence = occurrence
            self.targetEndpoint = targetEndpoint
            self.targetSessionID = targetSessionID
            self.requestedAt = requestedAt
            self.displayName = displayName
            self.status = status
            self.observedAt = observedAt ?? requestedAt
            self.idleForSend = status == .idle && idleForSend
            self.idleSince = status == .idle ? idleSince : nil
            self.waitingOn = waitingOn
            self.latestVisibleAssistantPreview = latestVisibleAssistantPreview
        }

        fileprivate func refreshed(from sample: Sample, observedAt: Date) -> PendingAttentionRequest {
            PendingAttentionRequest(
                occurrence: occurrence,
                targetEndpoint: targetEndpoint,
                targetSessionID: targetSessionID,
                requestedAt: requestedAt,
                displayName: sample.displayName,
                status: sample.status,
                observedAt: observedAt,
                idleForSend: sample.idleForSend,
                idleSince: sample.idleSince,
                waitingOn: sample.waitingOn,
                latestVisibleAssistantPreview: sample.latestVisibleAssistantPreview
            )
        }

        fileprivate func hasSameCurrentMetadata(as sample: Sample) -> Bool {
            displayName == sample.displayName
                && status == sample.status
                && idleForSend == sample.idleForSend
                && idleSince == sample.idleSince
                && waitingOn == sample.waitingOn
                && latestVisibleAssistantPreview == sample.latestVisibleAssistantPreview
        }
    }

    enum AttentionRequestResult: Equatable {
        /// Deliberately identical for a newly stored request and a duplicate already pending one.
        case accepted
        case atCapacity
        case unavailable
    }

    /// The structural shape a failed auto-wake attempt is suppressed against.
    ///
    /// Deliberately excludes name, preview, timestamp, readiness, metadata sequence, and queue
    /// revision: a metadata refresh improves the payload a future dispatch would carry, but
    /// re-attempting a provider call that already failed for the same set of occurrences would be a
    /// failure loop. A structurally new edge or attention occurrence, a new link generation, or newly
    /// produced overflow is a different notice and may re-arm exactly one attempt.
    ///
    /// It deliberately *includes* `edgeSequence`, which is the difference between "the same failed
    /// notice, refreshed" and "this target did the same thing again". Excluding it made suppression
    /// permanent: once a `running → idle` failed, every later `running → idle` for that link inside
    /// the same queue epoch hashed identically and stayed suppressed for the life of the link.
    struct WakeEligibilityFingerprint: Hashable {
        struct Edge: Hashable {
            let reference: DomainAgentSessionLinkReference
            let targetEndpoint: DomainAgentSessionLinkEndpointIdentity
            let fromStatus: Status
            let toStatus: Status
            /// Occurrence identity of this exact transition. Stable across metadata refreshes,
            /// strictly advancing for a genuinely new transition.
            let edgeSequence: UInt64
            var ordinaryThrough: UInt64?

            /// A coverage row's displayed pair may rebase without becoming a new occurrence.
            /// Real edges always advance edgeSequence; legacy unknown-only rows keep shape identity.
            static func == (lhs: Self, rhs: Self) -> Bool {
                lhs.reference == rhs.reference && lhs.targetEndpoint == rhs.targetEndpoint
                    && lhs.edgeSequence == rhs.edgeSequence && lhs.ordinaryThrough == rhs.ordinaryThrough
                    && (
                        lhs.ordinaryThrough != nil
                            || (lhs.fromStatus == rhs.fromStatus && lhs.toStatus == rhs.toStatus)
                    )
            }

            func hash(into hasher: inout Hasher) {
                hasher.combine(reference)
                hasher.combine(targetEndpoint)
                hasher.combine(edgeSequence)
                hasher.combine(ordinaryThrough)
                if ordinaryThrough == nil {
                    hasher.combine(fromStatus)
                    hasher.combine(toStatus)
                }
            }
        }

        let queueEpoch: UUID
        let edges: [Edge]
        let attentionOccurrences: [AttentionOccurrenceIdentity]
        let overflowProduced: UInt64

        init(
            queueEpoch: UUID,
            edges: [Edge],
            attentionOccurrences: [AttentionOccurrenceIdentity] = [],
            overflowProduced: UInt64
        ) {
            self.queueEpoch = queueEpoch
            // One occurrence per exact reference; display metadata order is not failure identity.
            // Canonicalize only this fingerprint, never the rendered rows or receipt subset.
            self.edges = edges.sorted {
                ($0.reference.linkID.uuidString, $0.reference.generation)
                    < ($1.reference.linkID.uuidString, $1.reference.generation)
            }
            self.attentionOccurrences = attentionOccurrences
            self.overflowProduced = overflowProduced
        }
    }

    struct Snapshot: Hashable {
        let observerEndpoint: DomainAgentSessionLinkEndpointIdentity
        let queueEpoch: UUID
        let queueRevision: UInt64
        let linkSetRevision: UInt64
        let isEnabled: Bool
        let isDeliverable: Bool
        let entries: [PendingEntry]
        let attentionRequests: [PendingAttentionRequest]
        /// What the envelope shows the agent: how many dropped changes are still unaccounted for.
        ///
        /// A *delta*, and therefore never an acknowledgement value. It falls back to zero as receipts
        /// land, so a receipt echoing it would acknowledge less overflow on every cycle than the queue
        /// has actually produced, and the shortfall would compound.
        let unacknowledgedOverflowCount: UInt64
        /// What a receipt acknowledges: the producer-side absolute count of dropped changes at the
        /// moment this snapshot was taken.
        ///
        /// Monotonic for the life of the epoch, so acknowledging it is idempotent, order-independent,
        /// and safe to compare against overflow produced after the claim was reserved.
        let overflowProduced: UInt64
        let autoWakeLanes: [AutoWakeLane]

        init(
            observerEndpoint: DomainAgentSessionLinkEndpointIdentity,
            queueEpoch: UUID,
            queueRevision: UInt64,
            linkSetRevision: UInt64,
            isEnabled: Bool,
            isDeliverable: Bool,
            entries: [PendingEntry],
            attentionRequests: [PendingAttentionRequest] = [],
            unacknowledgedOverflowCount: UInt64,
            overflowProduced: UInt64,
            autoWakeLanes: [AutoWakeLane] = []
        ) {
            self.observerEndpoint = observerEndpoint
            self.queueEpoch = queueEpoch
            self.queueRevision = queueRevision
            self.linkSetRevision = linkSetRevision
            self.isEnabled = isEnabled
            self.isDeliverable = isDeliverable
            self.entries = entries
            self.attentionRequests = attentionRequests
            self.unacknowledgedOverflowCount = unacknowledgedOverflowCount
            self.overflowProduced = overflowProduced
            self.autoWakeLanes = autoWakeLanes
        }

        /// The lanes this snapshot was published believing were selected, keyed for lookup.
        ///
        /// Reporting only. Routine status/overflow scheduling and acceptance must resolve selection
        /// against the live session instead; see `isEffectivelySelected`. Purposeful attention is not
        /// governed by routine selection.
        ///
        /// Built by reduction rather than `Dictionary(uniqueKeysWithValues:)` so a duplicated
        /// reference degrades to a last-wins lookup instead of trapping on the main actor.
        var effectivelySelectedAutoWakeLanesByReference: [DomainAgentSessionLinkReference: AutoWakeLane] {
            autoWakeLanes.reduce(into: [:]) { lanes, lane in
                guard lane.isEffectivelySelected else { return }
                lanes[lane.reference] = lane
            }
        }

        /// Whether this snapshot has anything worth putting in front of the agent.
        ///
        /// Overflow alone qualifies: "changes happened that you will never see the detail of" is the
        /// one honest thing the queue can say once it has dropped entries, and withholding it until
        /// some unrelated entry arrives would leave the count permanently unacknowledged.
        var hasDeliverableContent: Bool {
            !entries.isEmpty || !attentionRequests.isEmpty || unacknowledgedOverflowCount > 0
        }

        /// Structural identity of what this snapshot would ask a provider to be woken for.
        var wakeEligibilityFingerprint: WakeEligibilityFingerprint {
            WakeEligibilityFingerprint(
                queueEpoch: queueEpoch,
                edges: entries.map {
                    WakeEligibilityFingerprint.Edge(
                        reference: $0.reference,
                        targetEndpoint: $0.targetEndpoint,
                        fromStatus: $0.fromStatus,
                        toStatus: $0.toStatus,
                        edgeSequence: $0.edgeSequence,
                        ordinaryThrough: $0.ordinaryThrough
                    )
                },
                attentionOccurrences: attentionRequests.map(\.occurrence),
                overflowProduced: overflowProduced
            )
        }
    }

    struct DeliveredStatus: Hashable {
        let reference: DomainAgentSessionLinkReference
        let targetEndpoint: DomainAgentSessionLinkEndpointIdentity
        let settledThrough: UInt64?
        let toStatus: Status
        let changeSequence: UInt64

        init(entry: PendingEntry) {
            targetEndpoint = entry.targetEndpoint
            settledThrough = entry.receiptSettledThrough
            reference = entry.reference
            toStatus = entry.toStatus
            changeSequence = entry.changeSequence
        }
    }

    struct Receipt: Hashable {
        let queueEpoch: UUID
        let queueRevision: UInt64
        let deliveredStatuses: [DeliveredStatus]
        let deliveredAttentionOccurrences: [AttentionOccurrenceIdentity]
        /// The absolute `overflowProduced` watermark the delivered envelope accounted for.
        ///
        /// Absolute rather than incremental so a duplicate, delayed, or out-of-order receipt can only
        /// ever re-state a position the queue has already passed.
        let overflowProducedThrough: UInt64

        init(
            queueEpoch: UUID,
            queueRevision: UInt64,
            deliveredStatuses: [DeliveredStatus],
            deliveredAttentionOccurrences: [AttentionOccurrenceIdentity] = [],
            overflowProducedThrough: UInt64
        ) {
            self.queueEpoch = queueEpoch
            self.queueRevision = queueRevision
            self.deliveredStatuses = deliveredStatuses
            self.deliveredAttentionOccurrences = deliveredAttentionOccurrences
            self.overflowProducedThrough = overflowProducedThrough
        }

        init(
            snapshot: Snapshot,
            deliveredEntries: [PendingEntry]? = nil,
            deliveredAttentionRequests: [PendingAttentionRequest]? = nil,
            overflowProducedThrough: UInt64? = nil
        ) {
            self.init(
                queueEpoch: snapshot.queueEpoch,
                queueRevision: snapshot.queueRevision,
                deliveredStatuses: (deliveredEntries ?? snapshot.entries).map(DeliveredStatus.init),
                deliveredAttentionOccurrences: (deliveredAttentionRequests ?? snapshot.attentionRequests)
                    .map(\.occurrence),
                overflowProducedThrough: overflowProducedThrough ?? snapshot.overflowProduced
            )
        }
    }

    private struct Observation: Hashable {
        let sample: Sample
        let observedAt: Date
        let lastKnownRunFacts: AgentRunQuietFacts?

        var targetEndpoint: DomainAgentSessionLinkEndpointIdentity {
            sample.targetEndpoint
        }

        var targetSessionID: UUID {
            sample.targetSessionID
        }

        var status: Status {
            sample.status
        }

        init(sample: Sample, observedAt: Date, lastKnownRunFacts: AgentRunQuietFacts? = nil) {
            self.sample = sample
            self.observedAt = observedAt
            self.lastKnownRunFacts = sample.runFacts ?? lastKnownRunFacts
        }

        /// The latest sample time enriches a future attention occurrence but is not itself queue
        /// content. Re-observing byte-identical state must not advance the reducer revision.
        static func == (lhs: Observation, rhs: Observation) -> Bool {
            lhs.sample == rhs.sample && lhs.lastKnownRunFacts == rhs.lastKnownRunFacts
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(sample)
            hasher.combine(lastKnownRunFacts)
        }
    }

    let observerEndpoint: DomainAgentSessionLinkEndpointIdentity
    let queueEpoch: UUID

    private(set) var isEnabled = false
    private(set) var isDeliverable = false
    private(set) var linkSetRevision: UInt64 = 0
    private(set) var queueRevision: UInt64 = 0
    private(set) var lastAcceptedReceiptRevision: UInt64 = 0
    private(set) var overflowProduced: UInt64 = 0
    private(set) var overflowAcknowledged: UInt64 = 0
    /// Current Auto-wake membership for this observer, held on the reducer rather than applied at
    /// each publish.
    ///
    /// Every published snapshot is an input to the Auto-wake acceptance fence, including the one a
    /// receipt produces. Decorating only the authoritative pass would let a receipt publish a
    /// lane-less snapshot, which the fence would read as "no lane is selected any more" and use to
    /// retract a live attempt and reset every consumed-epoch watermark.
    private(set) var autoWakeLanes: [AutoWakeLane] = []

    private struct DeliveredRunPosition {
        let target: DomainAgentSessionLinkEndpointIdentity
        var through: UInt64?
        /// Ordinary watermark this lane's evicted rows already disclosed as anonymous overflow.
        /// Representation-only: it never pays, and a late exact receipt still advances `through`.
        /// A quiet close may not re-represent this debt as a fresh occurrence; only a newer ordinary
        /// watermark can, which keeps quiet churn from inflating overflow or failure identity.
        var overflowDisclosedOrdinaryThrough: UInt64?
    }

    /// One position per live lane, not per pending row. Target unreadability does not retire it.
    private var deliveredRunThrough: [DomainAgentSessionLinkReference: DeliveredRunPosition] = [:]

    func deliveredRunThrough(for reference: DomainAgentSessionLinkReference) -> UInt64? {
        deliveredRunThrough[reference]?.through
    }

    /// Disclosure-only frontiers. Never included in snapshots, receipts, revisions or wake identity.
    var localInputFrontiers: [DomainAgentSessionLinkReference: LocalInputFrontier] = [:]

    private var nextChangeSequence: UInt64 = 0
    private var nextAttentionSequence: UInt64 = 0
    private var lastObservedStatus: [DomainAgentSessionLinkReference: Observation] = [:]
    private var pendingByReference: [DomainAgentSessionLinkReference: PendingEntry] = [:]
    private var pendingAttentionByReference:
        [DomainAgentSessionLinkReference: PendingAttentionRequest] = [:]

    init(
        observerEndpoint: DomainAgentSessionLinkEndpointIdentity,
        queueEpoch: UUID = UUID()
    ) {
        self.observerEndpoint = observerEndpoint
        self.queueEpoch = queueEpoch
    }

    /// Same inclusion as attentionRequests, without sorting or acknowledging any occurrence.
    var pendingAttentionOccurrenceCount: Int {
        pendingAttentionByReference.count
    }

    var snapshot: Snapshot {
        // Reuse the existing <=16 sorted entry buffer. Projection does not mutate the queue or own
        // payment state; admission must see payment even when status cleanup intentionally retained
        // a newer row. No per-claim position map or extra index travels with the snapshot.
        var entries = orderedPendingEntries
        for index in entries.indices {
            if let position = deliveredRunThrough[entries[index].reference], position.target == entries[index].targetEndpoint {
                entries[index].deliveredThroughAtSnapshot = position.through
            }
        }
        return Snapshot(
            observerEndpoint: observerEndpoint,
            queueEpoch: queueEpoch,
            queueRevision: queueRevision,
            linkSetRevision: linkSetRevision,
            isEnabled: isEnabled,
            isDeliverable: isEnabled && isDeliverable,
            entries: entries,
            attentionRequests: orderedPendingAttentionRequests,
            unacknowledgedOverflowCount: overflowProduced - overflowAcknowledged,
            overflowProduced: overflowProduced,
            autoWakeLanes: autoWakeLanes
        )
    }

    /// Replaces the Auto-wake membership carried by every subsequent snapshot of this reducer.
    mutating func setAutoWakeLanes(_ lanes: [AutoWakeLane]) {
        autoWakeLanes = lanes
    }

    /// Starts collecting and silently baselines the current authoritative target states.
    ///
    /// `isEnabled` is an internal "this exact endpoint currently has collectable direct links"
    /// invariant, not a user preference: collection is an always-on property of a live, eligible
    /// direct oversight relationship.
    mutating func enable(
        samples: [Sample],
        linkSetRevision: UInt64,
        deliverable: Bool = true,
        observedAt: Date = Date()
    ) {
        guard !samples.isEmpty else {
            invalidateLastLink(linkSetRevision: linkSetRevision)
            return
        }

        if isEnabled {
            reconcile(
                samples: samples,
                linkSetRevision: linkSetRevision,
                deliverable: deliverable,
                observedAt: observedAt
            )
            return
        }

        localInputFrontiers.removeAll()
        isEnabled = true
        isDeliverable = deliverable
        self.linkSetRevision = linkSetRevision
        pendingByReference.removeAll()
        pendingAttentionByReference.removeAll()
        lastObservedStatus = baselines(from: samples, observedAt: observedAt)
        resetDeliveredPositions(samples)
        advanceQueueRevision()
    }

    /// Disables delivery immediately and discards all observer-local queue state.
    mutating func disable(linkSetRevision: UInt64) {
        let changed = isEnabled
            || isDeliverable
            || self.linkSetRevision != linkSetRevision
            || !lastObservedStatus.isEmpty
            || !pendingByReference.isEmpty
            || !pendingAttentionByReference.isEmpty
            || overflowProduced != overflowAcknowledged

        localInputFrontiers.removeAll()
        isEnabled = false
        isDeliverable = false
        self.linkSetRevision = linkSetRevision
        lastObservedStatus.removeAll()
        deliveredRunThrough.removeAll()
        pendingByReference.removeAll()
        pendingAttentionByReference.removeAll()
        overflowAcknowledged = overflowProduced

        if changed {
            advanceQueueRevision()
        }
    }

    /// Reconciles one full authoritative target sample set.
    ///
    /// New references and references returning from `unavailable` are baselined. When delivery is
    /// temporarily unavailable, all current targets are continuously rebaselined and no history is
    /// accumulated.
    mutating func reconcile(
        samples: [Sample],
        linkSetRevision: UInt64,
        deliverable: Bool,
        observedAt: Date = Date()
    ) {
        guard isEnabled else {
            if self.linkSetRevision != linkSetRevision {
                self.linkSetRevision = linkSetRevision
                advanceQueueRevision()
            }
            return
        }
        guard !samples.isEmpty else {
            invalidateLastLink(linkSetRevision: linkSetRevision)
            return
        }

        if !deliverable || !isDeliverable {
            let newBaselines = baselines(from: samples, observedAt: observedAt)
            let changed = self.linkSetRevision != linkSetRevision
                || isDeliverable != deliverable
                || lastObservedStatus != newBaselines
                || !pendingByReference.isEmpty
                || !pendingAttentionByReference.isEmpty
                || overflowProduced != overflowAcknowledged
            self.linkSetRevision = linkSetRevision
            localInputFrontiers.removeAll()
            isDeliverable = deliverable
            lastObservedStatus = newBaselines
            resetDeliveredPositions(samples)
            pendingByReference.removeAll()
            pendingAttentionByReference.removeAll()
            overflowAcknowledged = overflowProduced
            if changed {
                advanceQueueRevision()
            }
            return
        }

        var changed = self.linkSetRevision != linkSetRevision
        self.linkSetRevision = linkSetRevision

        let currentByReference = samplesByReference(samples)
        let currentReferences = Set(currentByReference.keys)
        let removedReferences = Set(deliveredRunThrough.keys).subtracting(currentReferences)
            .union(Set(lastObservedStatus.keys).subtracting(currentReferences))
            .union(Set(pendingByReference.keys).subtracting(currentReferences))
            .union(Set(pendingAttentionByReference.keys).subtracting(currentReferences))
        if !removedReferences.isEmpty {
            changed = true
            for reference in removedReferences {
                deliveredRunThrough.removeValue(forKey: reference)
                lastObservedStatus.removeValue(forKey: reference)
                pendingByReference.removeValue(forKey: reference)
                pendingAttentionByReference.removeValue(forKey: reference)
            }
        }

        for var sample in sortedSamples(currentByReference.values) {
            let reference = sample.reference
            let priorPosition = deliveredRunThrough[reference]
            let isNewLane = priorPosition?.target != sample.targetEndpoint
            if isNewLane {
                deliveredRunThrough[reference] = DeliveredRunPosition(target: sample.targetEndpoint, through: nil)
                lastObservedStatus.removeValue(forKey: reference)
                pendingByReference.removeValue(forKey: reference)
                pendingAttentionByReference.removeValue(forKey: reference)
                changed = true
            }
            if sample.status == .unavailable {
                // Remove public detail/attention, not the same-endpoint monotonic cache. An
                // unavailable placeholder has NO fresh pair and cannot baseline, close, or pay;
                // its existing Observation cache rejects a regressing first return without a resume
                // flag or a second map. Default-unknown hosts keep their upstream removal behavior.
                if let known = lastObservedStatus[reference]?.lastKnownRunFacts {
                    sample.runFacts = nil
                    let unavailable = Observation(sample: sample, observedAt: observedAt, lastKnownRunFacts: known)
                    changed = lastObservedStatus[reference] != unavailable || changed
                    lastObservedStatus[reference] = unavailable
                } else {
                    changed = lastObservedStatus.removeValue(forKey: reference) != nil || changed
                }
                changed = pendingByReference.removeValue(forKey: reference) != nil || changed
                changed = pendingAttentionByReference.removeValue(forKey: reference) != nil || changed
                continue
            }

            let preceding = lastObservedStatus[reference]
            if let incoming = sample.runFacts, let known = preceding?.lastKnownRunFacts,
               incoming.settledThrough < known.settledThrough || incoming.ordinaryThrough < known.ordinaryThrough
            {
                sample.runFacts = nil
            }
            if let incoming = sample.runFacts, let delivered = deliveredRunThrough[reference]?.through,
               incoming.settledThrough < delivered { sample.runFacts = nil }
            let priorStatus = preceding?.status == .unavailable ? sample.status : preceding?.status ?? sample.status
            let statusChanged = priorStatus != sample.status
            let immediateEdge = PendingEntry.isStatusEdge(from: priorStatus, to: sample.status)
            let oldEntry = pendingByReference[reference]
            let known = sample.runFacts ?? preceding?.lastKnownRunFacts
            // First proof baselines a fresh lane, never an already-observed unpaid status edge.
            let isBaseline = deliveredRunThrough[reference]?.through == nil && sample.runFacts != nil
                && oldEntry == nil && !immediateEdge
            if isBaseline {
                deliveredRunThrough[reference]?.through = sample.runFacts?.settledThrough
            }
            let delivered = deliveredRunThrough[reference]?.through
            let owesCoverage = known.map { facts in
                delivered.map { facts.ordinaryThrough > $0 } ?? (oldEntry != nil || immediateEdge)
            } ?? false
            let overflowDisclosed = deliveredRunThrough[reference]?.overflowDisclosedOrdinaryThrough
            let owesUndisclosedCoverage = owesCoverage
                && known.map { facts in overflowDisclosed.map { facts.ordinaryThrough > $0 } ?? true } ?? false
            let freshIdleDebt = sample.status == .idle && sample.runFacts != nil && owesCoverage
            let newOrdinary = sample.runFacts.map { $0.ordinaryThrough > (preceding?.lastKnownRunFacts?.ordinaryThrough ?? 0) } ?? false
            let reacquired = sample.runFacts != nil && preceding?.sample.runFacts == nil
            changed = changed || statusChanged
            let quietInterval: Bool = if let opening = preceding?.sample.runFacts, let closing = sample.runFacts {
                closing.settledThrough > opening.settledThrough
                    && closing.ordinaryThrough == opening.ordinaryThrough
            } else {
                false
            }
            lastObservedStatus[reference] = Observation(
                sample: sample, observedAt: observedAt, lastKnownRunFacts: known
            )
            if let attention = pendingAttentionByReference[reference], !attention.hasSameCurrentMetadata(as: sample) {
                pendingAttentionByReference[reference] = attention.refreshed(from: sample, observedAt: observedAt)
                changed = true
            }
            // A first observation is a silent baseline, but a surviving position returning from an
            // unavailable/proof gap must recover owed work BEFORE same-status early return.
            let recoverDebt = freshIdleDebt && owesUndisclosedCoverage && !isBaseline && (newOrdinary || reacquired)
            if preceding == nil && !recoverDebt { continue }
            let quietClose = sample.status == .idle && quietInterval
            var origin = oldEntry?.fromStatus ?? priorStatus
            if sample.status == .waiting, statusChanged, let oldEntry, !oldEntry.isStatusEdge {
                // A retained coverage-only waiting row cannot swallow the next real waiting edge.
                origin = priorStatus
            }
            let coalescedEdge = PendingEntry.isStatusEdge(from: origin, to: sample.status)
            let retainsCoverage = oldEntry != nil && owesCoverage
            // A quiet successor may be the first observed close after ordinary coverage was
            // sampled only while running. Quiet proof cannot suppress that still-unpaid coverage,
            // but debt an eviction already disclosed as overflow is not a fresh occurrence.
            let shouldRepresent = retainsCoverage || recoverDebt || (oldEntry != nil && !statusChanged)
                || (statusChanged && coalescedEdge && (!quietClose || owesUndisclosedCoverage))
            if !shouldRepresent {
                if statusChanged, oldEntry != nil {
                    pendingByReference.removeValue(forKey: reference)
                    changed = true
                }
                continue
            }

            let advancesEdge = recoverDebt && newOrdinary
                || (statusChanged && !quietClose && ((sample.status == .idle && immediateEdge) || coalescedEdge))
            let cutoff = sample.runFacts?.settledThrough ?? (!statusChanged ? oldEntry?.receiptSettledThrough : nil)
            // A frozen old cutoff is payable, but cannot masquerade as current fresh idle proof.
            let opening: UInt64? = if advancesEdge || oldEntry == nil {
                // A new occurrence uses its immediately preceding frame, not the retained display
                // origin. Quiet refresh/coalescing preserves the old occurrence's boundary.
                preceding?.sample.runFacts?.settledThrough
            } else {
                // Positive quiet evidence can supply an unknown occurrence opening, without
                // replacing an earlier known boundary or acknowledging the pending ordinary work.
                oldEntry?.openingSettledThrough ?? (quietClose ? preceding?.sample.runFacts?.settledThrough : nil)
            }
            if quietClose, let oldEntry { origin = oldEntry.fromStatus }
            // A facts-only refresh cannot turn the same positively paid idle occurrence into a
            // new status debt. A real intervening edge still follows the ordinary path above.
            if !statusChanged, sample.status == .idle, !owesCoverage,
               let oldEntry, oldEntry.hasSameFinalMetadata(as: sample),
               oldEntry.runFacts != sample.runFacts, let closing = oldEntry.runFacts,
               let opening = oldEntry.openingSettledThrough, closing.settledThrough > opening,
               let delivered, closing.ordinaryThrough <= delivered
            {
                origin = .idle
            }
            let ordinary = known?.ordinaryThrough ?? oldEntry?.ordinaryThrough
            if let oldEntry, !statusChanged, !advancesEdge,
               oldEntry.hasSameFinalMetadata(as: sample), oldEntry.runFacts == sample.runFacts,
               oldEntry.receiptSettledThrough == cutoff,
               oldEntry.ordinaryThrough == ordinary, oldEntry.openingSettledThrough == opening
            { continue }
            // Losing only proof freshness does not change the status the frozen receipt rendered.
            // Keep that receipt applicable; real edges and visible metadata changes still advance it.
            let preservesStatusReceipt = !statusChanged && !advancesEdge && sample.runFacts == nil
                && oldEntry?.hasSameFinalMetadata(as: sample) == true
            nextChangeSequence += 1
            pendingByReference[reference] = PendingEntry(
                reference: reference, targetEndpoint: sample.targetEndpoint, targetSessionID: sample.targetSessionID,
                displayName: sample.displayName, fromStatus: origin, toStatus: sample.status,
                observedAt: observedAt, idleForSend: sample.idleForSend, idleSince: sample.idleSince,
                waitingOn: sample.waitingOn, latestVisibleAssistantPreview: sample.latestVisibleAssistantPreview,
                changeSequence: preservesStatusReceipt ? oldEntry?.changeSequence ?? nextChangeSequence : nextChangeSequence,
                edgeSequence: advancesEdge ? nextChangeSequence : oldEntry?.edgeSequence ?? nextChangeSequence,
                runFacts: sample.runFacts, receiptSettledThrough: cutoff,
                ordinaryThrough: ordinary, openingSettledThrough: opening
            )
            changed = true
        }

        let overflowCount = enforcePendingBound()
        if overflowCount > 0 {
            overflowProduced += UInt64(overflowCount)
            changed = true
        }

        if changed {
            advanceQueueRevision()
        }
    }

    /// Stores one target-originated request under the already-baselined exact observer queue.
    ///
    /// This method never enables or rebaselines a reducer. The bridge must first prove that the
    /// reducer exists for the current exact grant and link-set revision; otherwise success here would
    /// be erased by the next `enable` and the target would have been lied to.
    mutating func requestAttention(
        reference: DomainAgentSessionLinkReference,
        targetEndpoint: DomainAgentSessionLinkEndpointIdentity,
        targetSessionID: UUID,
        linkSetRevision: UInt64,
        requestedAt: Date = Date()
    ) -> AttentionRequestResult {
        guard isEnabled,
              isDeliverable,
              self.linkSetRevision == linkSetRevision,
              let observation = lastObservedStatus[reference],
              observation.targetEndpoint == targetEndpoint,
              observation.targetSessionID == targetSessionID,
              observation.status != .unavailable
        else {
            return .unavailable
        }
        guard pendingAttentionByReference[reference] == nil else {
            // First wins until receipt or lifecycle invalidation. No timestamp, ordering, revision,
            // or fingerprint movement: the wire response intentionally reveals no coalescing state.
            return .accepted
        }
        guard pendingAttentionByReference.count < Self.maximumPendingAttentionRequestCount else {
            return .atCapacity
        }

        nextAttentionSequence &+= 1
        let occurrence = AttentionOccurrenceIdentity(
            queueEpoch: queueEpoch,
            reference: reference,
            attentionSequence: nextAttentionSequence
        )
        pendingAttentionByReference[reference] = PendingAttentionRequest(
            occurrence: occurrence,
            targetEndpoint: targetEndpoint,
            targetSessionID: targetSessionID,
            requestedAt: requestedAt,
            displayName: observation.sample.displayName,
            status: observation.status,
            observedAt: observation.observedAt,
            idleForSend: observation.sample.idleForSend,
            idleSince: observation.sample.idleSince,
            waitingOn: observation.sample.waitingOn,
            latestVisibleAssistantPreview: observation.sample.latestVisibleAssistantPreview
        )
        advanceQueueRevision()
        return .accepted
    }

    /// Applies an accepted provider receipt monotonically within this reducer's queue epoch.
    mutating func apply(_ receipt: Receipt) {
        guard receipt.queueEpoch == queueEpoch,
              receipt.queueRevision <= queueRevision
        else { return }

        var changed = false

        // Attention is occurrence-qualified and settles independently of the aggregate
        // receipt watermark. An older claim may physically arrive after a newer receipt that did
        // not render this occurrence; refusing it solely for age would leave accepted attention owed.
        for occurrence in receipt.deliveredAttentionOccurrences {
            guard let current = pendingAttentionByReference[occurrence.reference],
                  current.occurrence == occurrence
            else { continue }
            pendingAttentionByReference.removeValue(forKey: occurrence.reference)
            changed = true
        }

        // Each receipt names only rendered rows; a newer partial receipt may omit these statuses.
        for delivered in receipt.deliveredStatuses {
            guard var position = deliveredRunThrough[delivered.reference], position.target == delivered.targetEndpoint else { continue }
            // An actual rendered receipt may establish an unknown position; proof alone cannot.
            if let cutoff = delivered.settledThrough, position.through.map({ cutoff > $0 }) ?? true {
                position.through = cutoff
                deliveredRunThrough[delivered.reference] = position
                changed = true
            }
            guard let current = pendingByReference[delivered.reference], current.targetEndpoint == delivered.targetEndpoint else { continue }
            let exact = current.toStatus == delivered.toStatus && current.changeSequence <= delivered.changeSequence
            let unpaid = current.ordinaryThrough.map { ordinary in position.through.map { ordinary > $0 } ?? true } ?? false
            if !unpaid, exact || (!current.isStatusEdge && current.ordinaryThrough != nil) {
                pendingByReference.removeValue(forKey: delivered.reference)
                changed = true
            } else if exact, unpaid, delivered.settledThrough == nil {
                // Settle the shown status, not its unpaid coverage. This inert hitchhiker can only
                // independently readmit after fresh idle proof; no payment is invented.
                nextChangeSequence += 1
                pendingByReference[delivered.reference] = PendingEntry(
                    reference: current.reference, targetEndpoint: current.targetEndpoint,
                    targetSessionID: current.targetSessionID, displayName: current.displayName,
                    fromStatus: current.toStatus, toStatus: current.toStatus, observedAt: current.observedAt,
                    idleForSend: current.idleForSend, idleSince: current.idleSince, waitingOn: current.waitingOn,
                    latestVisibleAssistantPreview: current.latestVisibleAssistantPreview,
                    changeSequence: nextChangeSequence, edgeSequence: current.edgeSequence,
                    ordinaryThrough: current.ordinaryThrough
                )
                changed = true
            }
        }

        if receipt.queueRevision > lastAcceptedReceiptRevision {
            lastAcceptedReceiptRevision = receipt.queueRevision

            overflowAcknowledged = max(
                overflowAcknowledged,
                min(receipt.overflowProducedThrough, overflowProduced)
            )
            changed = true
        }

        if changed {
            advanceQueueRevision()
        }
    }

    private var orderedPendingEntries: [PendingEntry] {
        pendingByReference.values.sorted(by: Self.entryPrecedes)
    }

    private var orderedPendingAttentionRequests: [PendingAttentionRequest] {
        pendingAttentionByReference.values.sorted(by: Self.attentionRequestPrecedes)
    }

    private mutating func invalidateLastLink(linkSetRevision: UInt64) {
        disable(linkSetRevision: linkSetRevision)
    }

    private mutating func advanceQueueRevision() {
        queueRevision += 1
    }

    private func baselines(
        from samples: [Sample],
        observedAt: Date
    ) -> [DomainAgentSessionLinkReference: Observation] {
        var result: [DomainAgentSessionLinkReference: Observation] = [:]
        for sample in sortedSamples(samples) where sample.status != .unavailable {
            result[sample.reference] = Observation(sample: sample, observedAt: observedAt)
        }
        return result
    }

    private func samplesByReference(
        _ samples: [Sample]
    ) -> [DomainAgentSessionLinkReference: Sample] {
        var result: [DomainAgentSessionLinkReference: Sample] = [:]
        for sample in sortedSamples(samples) {
            result[sample.reference] = sample
        }
        return result
    }

    private func sortedSamples(_ samples: some Sequence<Sample>) -> [Sample] {
        samples.sorted {
            let leftTarget = $0.targetSessionID.uuidString
            let rightTarget = $1.targetSessionID.uuidString
            if leftTarget != rightTarget {
                return leftTarget < rightTarget
            }
            let leftLink = $0.reference.linkID.uuidString
            let rightLink = $1.reference.linkID.uuidString
            if leftLink != rightLink {
                return leftLink < rightLink
            }
            if $0.reference.generation != $1.reference.generation {
                return $0.reference.generation < $1.reference.generation
            }
            return $0.status.rawValue < $1.status.rawValue
        }
    }

    private mutating func resetDeliveredPositions(_ samples: [Sample]) {
        deliveredRunThrough = [:]
        for sample in samples {
            deliveredRunThrough[sample.reference] = DeliveredRunPosition(
                target: sample.targetEndpoint, through: sample.status == .unavailable ? nil : sample.runFacts?.settledThrough
            )
        }
    }

    private mutating func enforcePendingBound() -> Int {
        let overflowCount = max(0, pendingByReference.count - Self.maximumPendingTargetCount)
        guard overflowCount > 0 else { return 0 }
        for entry in orderedPendingEntries.prefix(overflowCount) {
            pendingByReference.removeValue(forKey: entry.reference)
            if let ordinary = entry.ordinaryThrough, var position = deliveredRunThrough[entry.reference],
               position.target == entry.targetEndpoint
            {
                position.overflowDisclosedOrdinaryThrough = max(position.overflowDisclosedOrdinaryThrough ?? 0, ordinary)
                deliveredRunThrough[entry.reference] = position
            }
        }
        return overflowCount
    }

    private static func entryPrecedes(_ lhs: PendingEntry, _ rhs: PendingEntry) -> Bool {
        if lhs.changeSequence != rhs.changeSequence {
            return lhs.changeSequence < rhs.changeSequence
        }
        return lhs.targetSessionID.uuidString < rhs.targetSessionID.uuidString
    }

    private static func attentionRequestPrecedes(
        _ lhs: PendingAttentionRequest,
        _ rhs: PendingAttentionRequest
    ) -> Bool {
        if lhs.occurrence.attentionSequence != rhs.occurrence.attentionSequence {
            return lhs.occurrence.attentionSequence < rhs.occurrence.attentionSequence
        }
        if lhs.targetSessionID != rhs.targetSessionID {
            return lhs.targetSessionID.uuidString < rhs.targetSessionID.uuidString
        }
        if lhs.reference.linkID != rhs.reference.linkID {
            return lhs.reference.linkID.uuidString < rhs.reference.linkID.uuidString
        }
        return lhs.reference.generation < rhs.reference.generation
    }
}

import Foundation

/// Process-local cumulative proof. Unknown is represented by nil, never saturated fresh facts.
struct AgentRunQuietFacts: Equatable, Hashable {
    let settledThrough: UInt64
    let ordinaryThrough: UInt64

    init?(settledThrough: UInt64, ordinaryThrough: UInt64) {
        guard ordinaryThrough <= settledThrough else { return nil }
        self.settledThrough = settledThrough
        self.ordinaryThrough = ordinaryThrough
    }

    static let zero = AgentRunQuietFacts(settledThrough: 0, ordinaryThrough: 0)!
}

/// Owned by one live source binding. The existing lifecycle facade remains the attempt authority;
/// this value never looks up a session, repairs history, publishes, persists, or starts work.
@MainActor
struct AgentRunQuietLedger {
    struct Seal: Equatable {
        let ownership: AgentRunOwnership
        let isQuiet: Bool
        let facts: AgentRunQuietFacts?
    }

    private struct Attempt {
        let owner: AgentRunOwnership
        let serial: UInt64?
        let startKey: Int
        let provider: AgentSessionLinkPromptProviderContext
        let openingFacts: AgentRunQuietFacts?
        var routineWakeID: UUID?
        var markerProducerFinished = false
        var hasOccurrence = false
        var rangeIsComplete = true
        var seal: Seal?
    }

    private var attempt: Attempt?
    private var lastEndedOwner: AgentRunOwnership?
    private(set) var facts: AgentRunQuietFacts?
    private(set) var hostMarkerIDs: Set<UUID> = []
    private(set) var hiddenSourceIDs: Set<UUID> = []
    private(set) var displayMaskRevision: UInt64 = 0

    /// Nonzero initial facts are useful for deterministic exhaustion tests, not restoration.
    init(initialFacts: AgentRunQuietFacts = .zero) {
        facts = initialFacts
    }

    func usesQuietMessageBoundaries(owner: AgentRunOwnership) -> Bool {
        candidateStartKey(owner: owner) != nil && attempt?.provider == .claudeCode
    }

    func candidateStartKey(owner: AgentRunOwnership) -> Int? {
        guard let current = attempt, current.owner == owner, current.seal == nil,
              current.routineWakeID != nil, !current.hasOccurrence, current.rangeIsComplete,
              facts != nil, AgentSessionLinkPrompts.supportsQuietCheckIn(current.provider)
        else { return nil }
        return current.startKey
    }

    func startKey(owner: AgentRunOwnership) -> Int? {
        attempt?.owner == owner && attempt?.seal == nil ? attempt?.startKey : nil
    }

    mutating func noteAcceptedStream(_ result: AIStreamResult, owner: AgentRunOwnership) {
        guard let current = attempt, current.owner == owner, current.seal == nil else { return }
        let neutral: Bool = switch result.type {
        case "content", "final_content", "reasoning", "usage", "message_stop", "transport_activity":
            true
        case "lifecycle":
            ["initialized", "completed"].contains(result.text ?? "")
        case "session_state_changed":
            ["running", "idle"].contains(result.text?.lowercased() ?? "")
        case "system":
            ["Agent initialized", "Agent completed", "Agent cancelled"].contains(result.text ?? "")
        case "event":
            false // Unknown activity is never evidence of silence, even without text.
        case "status":
            current.provider == .claudeCode && result.text?.hasPrefix("Permission mode:") == true
        default:
            false
        }
        if !neutral { noteOccurrence(owner: owner) }
    }

    func isOpen(owner: AgentRunOwnership) -> Bool {
        attempt?.owner == owner && attempt?.seal == nil
    }

    /// Only the authoritative begin funnel calls this. Re-entry cannot clear accepted occurrences.
    mutating func begin(owner: AgentRunOwnership, startKey: Int, provider: AgentSessionLinkPromptProviderContext) {
        guard attempt?.owner != owner, lastEndedOwner != owner else { return }
        if let previous = attempt, previous.seal == nil { advance(quiet: false) }
        let serial = facts.flatMap { value -> UInt64? in
            let (next, overflow) = value.settledThrough.addingReportingOverflow(1)
            return overflow ? nil : next
        }
        if serial == nil { facts = nil }
        attempt = Attempt(owner: owner, serial: serial, startKey: startKey, provider: provider, openingFacts: facts)
    }

    /// Qualification (idleFollowUp, no attention, first physical acquisition, no replay) belongs to
    /// the winning physical fence. Non-routine/replayed dispatch must noteOccurrence instead.
    mutating func markRoutineWake(owner: AgentRunOwnership, wakeID: UUID) {
        guard isOpen(owner: owner) else { return }
        if let marked = attempt?.routineWakeID, marked != wakeID {
            attempt?.hasOccurrence = true
        } else {
            attempt?.routineWakeID = wakeID
        }
    }

    /// The existing winning transport fence is the authority; no dispatch/owner journal is kept.
    mutating func recordPhysicalDispatch(owner: AgentRunOwnership, wakeID: UUID, routineQuietCheckIn: Bool, alreadyAcquired: Bool) {
        guard let current = attempt, current.owner == owner, current.seal == nil else { return }
        if alreadyAcquired {
            // Same-owner/same-wake reentry is idempotent. An acquired replay onto any other owner
            // cannot borrow the prior owner's origin, even when its frozen claim still qualifies.
            if current.routineWakeID != wakeID { noteOccurrence(owner: owner) }
        } else if routineQuietCheckIn, AgentSessionLinkPrompts.supportsQuietCheckIn(current.provider) {
            markRoutineWake(owner: owner, wakeID: wakeID)
        } else {
            noteOccurrence(owner: owner)
        }
    }

    mutating func noteOccurrence(owner: AgentRunOwnership) {
        guard isOpen(owner: owner) else { return }
        attempt?.hasOccurrence = true
    }

    mutating func invalidateRange(owner: AgentRunOwnership) {
        guard isOpen(owner: owner) else { return }
        attempt?.rangeIsComplete = false
    }

    /// Synchronous terminal-barrier operation. Default false until each native ingress is qualified.
    /// The caller has already passed its second exact ownership/drain guard; there is no await here.
    @discardableResult
    mutating func settle(
        owner: AgentRunOwnership,
        terminalState: AgentSessionRunState,
        classifiesQuietCheckIn: Bool = false,
        hasSuccessor: Bool = false,
        endKey: Int,
        rangeIsComplete: Bool = false,
        rows: some Collection<AgentChatItem>
    ) -> Seal? {
        guard let current = attempt, current.owner == owner else { return nil }
        if let seal = current.seal { return seal }
        var quiet = false
        if facts != nil, current.serial != nil,
           classifiesQuietCheckIn, terminalState == .completed, !hasSuccessor,
           !current.hasOccurrence, current.rangeIsComplete,
           AgentSessionLinkPrompts.supportsQuietCheckIn(current.provider),
           let wakeID = current.routineWakeID,
           case let .quiet(hiddenIDs) = AgentQuietCheckInClassifier.classify(
               rows: rows,
               startKey: current.startKey,
               endKey: endKey,
               rangeIsComplete: rangeIsComplete,
               routineWakeID: wakeID,
               hostMarkerIDs: hostMarkerIDs
           )
        {
            quiet = true
            var changed = false
            for id in hiddenIDs {
                if id == wakeID, current.markerProducerFinished, !hostMarkerIDs.contains(wakeID) { continue }
                changed = hiddenSourceIDs.insert(id).inserted || changed
            }
            if changed { displayMaskRevision &+= 1 }
        }
        advance(quiet: quiet)
        let seal = Seal(ownership: owner, isQuiet: quiet, facts: facts)
        attempt?.seal = seal
        return seal
    }

    /// Call from the successful central lifecycle end with its captured authoritative owner.
    /// That proof is required even with a missing ledger begin; a stale end is not a known end.
    /// No unbounded ended-attempt journal is needed because the lifecycle rejects old ownership.
    @discardableResult
    mutating func end(owner: AgentRunOwnership, authoritativeOwner: AgentRunOwnership?) -> Bool {
        guard authoritativeOwner == owner, lastEndedOwner != owner else { return false }
        if let current = attempt {
            guard current.owner == owner else { return false }
            if current.seal == nil { advance(quiet: false) }
        } else {
            advance(quiet: false)
        }
        attempt = nil
        lastEndedOwner = owner
        return true
    }

    /// Status, not ownership release, selects the cutoff during synchronous terminal handoff.
    func sourceFacts(owner: AgentRunOwnership?, capturedState: AgentSessionRunState) -> AgentRunQuietFacts? {
        if let current = attempt, capturedState.isActive {
            guard current.owner == owner else { return nil }
            return current.openingFacts
        }
        return facts
    }

    /// Only the endpoint/readiness-fenced captured acceptance registers canonical host provenance.
    @discardableResult
    mutating func registerHostMarker(_ row: AgentChatItem) -> Bool {
        guard row.kind == .system, row.text == AgentLaneUpdateDisplayAttribution.canonicalSystemText else { return false }
        return hostMarkerIDs.insert(row.id).inserted
    }

    /// Mutation owner proves these materialized source rows AND retained source anchors retired.
    /// Pass only actual retired row/anchor IDs, never absent IDs found by scanning this projection.
    /// Absence from a working suffix, claim store or pending-wake slot is not retirement proof.
    mutating func retireSourceIDs(_ ids: Set<UUID>) {
        let count = hiddenSourceIDs.count
        hiddenSourceIDs.subtract(ids)
        hostMarkerIDs.subtract(ids)
        if hiddenSourceIDs.count != count { displayMaskRevision &+= 1 }
    }

    /// Producer settlement proves no admissible callback (including queued MainActor work) remains.
    mutating func retireUnmaterializedWake(_ wakeID: UUID) {
        if attempt?.routineWakeID == wakeID { attempt?.markerProducerFinished = true }
        guard !hostMarkerIDs.contains(wakeID) else { return }
        if hiddenSourceIDs.remove(wakeID) != nil { displayMaskRevision &+= 1 }
    }

    /// Existing mutation owners supply indexed materialization/retention proof, not a history scan.
    /// Never infer retirement for an unmaterialized wake from its absence in a source projection.
    mutating func reconcileSourceIDs(wasMaterialized: (UUID) -> Bool, isRetained: (UUID) -> Bool) {
        guard !hiddenSourceIDs.isEmpty || !hostMarkerIDs.isEmpty else { return }
        let count = hiddenSourceIDs.count
        hiddenSourceIDs = hiddenSourceIDs.filter { !wasMaterialized($0) || isRetained($0) }
        hostMarkerIDs = hostMarkerIDs.filter { !wasMaterialized($0) || isRetained($0) }
        if hiddenSourceIDs.count != count { displayMaskRevision &+= 1 }
    }

    /// Reload loses MATERIALIZED verdict proof; rows reappear. Still-admissible unmaterialized
    /// marker exclusions remain in this same projection until their producer or binding retires.
    /// A surviving binding must NOT reset its aggregate facts.
    mutating func discardSourceProof(isMaterialized: (UUID) -> Bool) {
        let registered = hostMarkerIDs
        let count = hiddenSourceIDs.count
        hiddenSourceIDs = hiddenSourceIDs.filter { !registered.contains($0) && !isMaterialized($0) }
        hostMarkerIDs.removeAll()
        if hiddenSourceIDs.count != count { displayMaskRevision &+= 1 }
        if attempt?.seal == nil { attempt?.rangeIsComplete = false }
    }

    private mutating func advance(quiet: Bool) {
        guard let previous = facts else { return }
        let (next, overflow) = previous.settledThrough.addingReportingOverflow(1)
        guard !overflow else {
            facts = nil
            return
        }
        facts = AgentRunQuietFacts(settledThrough: next, ordinaryThrough: quiet ? previous.ordinaryThrough : next)
    }
}

import Foundation
import RepoPromptDomainRuntime

/// Owned by one live source binding. The existing lifecycle facade remains the attempt authority;
/// this value never looks up a session, repairs history, publishes, persists, or starts work.
@MainActor
struct AgentRunQuietLedger {
    struct Seal: Equatable {
        let ownership: AgentRunOwnership
        let isQuiet: Bool
        let facts: AgentRunQuietFacts?
    }

    /// One candidate slot on the existing attempt, not a registry. A second distinct call or host
    /// execution irreversibly invalidates this exactly-one proof, even if transcript dedup merges it.
    private struct CodexAssociation {
        let callID: String
        let threadID: String
        let turnID: String
        let runID: UUID
        var hostID: UUID?
        var nativeID: UUID?
        var nativeCallSeen = false
        var nativeResultSeen = false
        var hostCallSeen = false
        var hostResultSeen = false
        var invalid = false
    }

    struct Baseline {
        let turnID: UUID
        let local: AgentTranscriptQuietLocalTurn
        let sourceRevision: Int
    }

    private struct Attempt {
        let owner: AgentRunOwnership
        let serial: UInt64?
        let startKey: Int
        let provider: AgentSessionLinkPromptProviderContext
        let openingFacts: AgentRunQuietFacts?
        var baseline: Baseline?
        var routineWakeID: UUID?
        var markerProducerFinished = false
        var hasOccurrence = false
        var rangeIsComplete = true
        var seal: Seal?
        var codexAssociation: CodexAssociation?
        var declarationBodyEntries: UInt8 = 0
        var declarationHostInvocationID: UUID?
        var acceptedDeclarationInvocationID: UUID?
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

    /// A transient input to local projection, derived from the sole attempt authority.
    /// It is never a certificate and never enters canonical source or persistence.
    struct DisplayCandidate: Equatable {
        let owner: AgentRunOwnership
        let startKey: Int
        let wakeID: UUID
        let turnID: UUID
        let local: AgentTranscriptQuietLocalTurn
    }

    var displayCandidate: DisplayCandidate? {
        guard let current = attempt, let start = candidateStartKey(owner: current.owner),
              let wakeID = current.routineWakeID, let baseline = current.baseline else { return nil }
        return .init(owner: current.owner, startKey: start, wakeID: wakeID, turnID: baseline.turnID, local: baseline.local)
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
        case "harness_empty_output_reprompt_candidate":
            current.provider == .claudeCode && candidateStartKey(owner: owner) != nil
                && current.declarationBodyEntries == 1 && current.acceptedDeclarationInvocationID != nil
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
    mutating func begin(owner: AgentRunOwnership, startKey: Int, provider: AgentSessionLinkPromptProviderContext, baseline: Baseline? = nil) {
        guard attempt?.owner != owner, lastEndedOwner != owner else { return }
        if let previous = attempt, previous.seal == nil { advance(quiet: false) }
        let serial = facts.flatMap { value -> UInt64? in
            let (next, overflow) = value.settledThrough.addingReportingOverflow(1)
            return overflow ? nil : next
        }
        if serial == nil {
            facts = nil
        }
        attempt = Attempt(owner: owner, serial: serial, startKey: startKey, provider: provider, openingFacts: facts, baseline: baseline)
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
    mutating func recordPhysicalDispatch(owner: AgentRunOwnership, wakeID: UUID, routineQuietCheckIn: Bool, alreadyAcquired: Bool, sourceRevision: Int? = nil) {
        guard let current = attempt, current.owner == owner, current.seal == nil else { return }
        if alreadyAcquired {
            // Same-owner/same-wake reentry is idempotent. An acquired replay onto any other owner
            // cannot borrow the prior owner's origin, even when its frozen claim still qualifies.
            if current.routineWakeID != wakeID { noteOccurrence(owner: owner) }
        } else if routineQuietCheckIn, AgentSessionLinkPrompts.supportsQuietCheckIn(current.provider) {
            if current.baseline?.sourceRevision != sourceRevision {
                attempt?.baseline = nil
            }
            markRoutineWake(owner: owner, wakeID: wakeID)
        } else {
            noteOccurrence(owner: owner)
        }
    }

    mutating func noteOccurrence(owner: AgentRunOwnership) {
        guard isOpen(owner: owner) else { return }
        attempt?.hasOccurrence = true
    }

    /// Body entry, before quiet eligibility checks. Registration and canonical deduplication do not count.
    @discardableResult
    mutating func enterDeclarationBody(owner: AgentRunOwnership, hostInvocationID: UUID) -> Bool {
        guard isOpen(owner: owner) else { return false }
        let entries = min(2, (attempt?.declarationBodyEntries ?? 0) + 1)
        attempt?.declarationBodyEntries = entries
        guard attempt?.declarationBodyEntries == 1 else { noteOccurrence(owner: owner)
            return false
        }
        attempt?.declarationHostInvocationID = hostInvocationID
        return true
    }

    /// The caller supplies its captured registration origin and independently resolved live endpoint.
    /// Acceptance records intent only; the terminal observation cut independently proves completion.
    @discardableResult
    mutating func acceptDeclarationBody(
        owner: AgentRunOwnership,
        hostInvocationID: UUID,
        wakeID: UUID,
        origin: AgentSelfMCPCallOrigin,
        currentEndpoint: DomainAgentSessionLinkEndpointIdentity,
        currentRunID: UUID?
    ) -> Bool {
        guard isOpen(owner: owner) else { return false }
        guard candidateStartKey(owner: owner) != nil, attempt?.routineWakeID == wakeID,
              attempt?.declarationBodyEntries == 1, attempt?.declarationHostInvocationID == hostInvocationID,
              origin.endpoint == currentEndpoint, origin.runID == currentRunID, origin.runAttemptID == owner.attemptID,
              currentEndpoint.tabID == owner.binding.tabID, currentEndpoint.sessionID == owner.binding.persistentSessionID,
              currentEndpoint.persistentBindingGeneration == owner.binding.persistentBindingGeneration,
              currentEndpoint.bindingTransitionGeneration == owner.binding.bindingTransitionGeneration
        else { noteOccurrence(owner: owner)
            return false
        }
        attempt?.acceptedDeclarationInvocationID = hostInvocationID
        return true
    }

    func routineWakeID(owner: AgentRunOwnership) -> UUID? {
        attempt?.owner == owner ? attempt?.routineWakeID : nil
    }

    func acceptedDeclarationInvocationID(owner: AgentRunOwnership) -> UUID? {
        attempt?.owner == owner ? attempt?.acceptedDeclarationInvocationID : nil
    }

    func hasOrdinaryOccurrence(owner: AgentRunOwnership) -> Bool {
        attempt?.owner != owner || attempt?.hasOccurrence != false
    }

    func declarationBodyEntryCardinality(owner: AgentRunOwnership) -> UInt8? {
        attempt?.owner == owner ? attempt?.declarationBodyEntries : nil
    }

    mutating func noteDeclarationAssistantText(owner: AgentRunOwnership, text: String) {
        guard isOpen(owner: owner), !text.isEmpty else { return }
        if attempt?.acceptedDeclarationInvocationID == nil { noteOccurrence(owner: owner) }
    }

    func declarationMaySeal(owner: AgentRunOwnership, canonicalInvocations: [UUID]) -> Bool {
        guard candidateStartKey(owner: owner) != nil, attempt?.declarationBodyEntries == 1,
              let accepted = attempt?.acceptedDeclarationInvocationID,
              attempt?.declarationHostInvocationID == accepted else { return false }
        return canonicalInvocations == [accepted]
    }

    private mutating func codexAssociation(
        owner: AgentRunOwnership,
        runID: UUID?,
        threadID: String?,
        callID: String?,
        turnID: String?
    ) -> CodexAssociation? {
        guard let current = attempt, current.owner == owner, current.seal == nil,
              current.provider == .codexExec, current.routineWakeID != nil else { return nil }
        guard let runID, let threadID, !threadID.isEmpty, let callID, !callID.isEmpty,
              let turnID, !turnID.isEmpty
        else { noteOccurrence(owner: owner)
            return nil
        }
        if var existing = current.codexAssociation {
            guard existing.runID == runID, existing.threadID == threadID,
                  existing.turnID == turnID, existing.callID == callID
            else {
                existing.invalid = true
                attempt?.codexAssociation = existing
                noteOccurrence(owner: owner)
                return nil
            }
            return existing
        }
        return CodexAssociation(callID: callID, threadID: threadID, turnID: turnID, runID: runID)
    }

    /// Native identity is correlation evidence only. The accepted host H and captured origin are
    /// still required independently. Missing/result-before-call/ambiguity cannot be repaired later.
    @discardableResult
    mutating func observeCodexNative(
        owner: AgentRunOwnership,
        runID: UUID?,
        currentThreadID: String?,
        currentTurnID: String?,
        identity: CodexNativeSessionController.MCPToolIdentity?,
        nativeID: UUID?,
        isResult: Bool,
        isError: Bool
    ) -> Bool {
        guard isOpen(owner: owner) else { return false }
        guard let identity, let nativeID,
              identity.threadID == currentThreadID, identity.turnID == currentTurnID,
              let raw = ToolInvocationContext.correlationString(.string(identity.callID)),
              var pair = codexAssociation(
                  owner: owner,
                  runID: runID,
                  threadID: currentThreadID,
                  callID: raw,
                  turnID: currentTurnID
              )
        else { noteOccurrence(owner: owner)
            return false
        }
        if (pair.nativeID != nil && pair.nativeID != nativeID) || (isResult && !pair.nativeCallSeen) || isError {
            pair.invalid = true
            noteOccurrence(owner: owner)
        }
        pair.nativeID = nativeID
        pair.nativeCallSeen = pair.nativeCallSeen || !isResult
        pair.nativeResultSeen = pair.nativeResultSeen || isResult
        attempt?.codexAssociation = pair
        return !pair.invalid
    }

    @discardableResult
    mutating func observeCodexHost(
        owner: AgentRunOwnership,
        runID: UUID?,
        currentThreadID: String?,
        currentTurnID: String?,
        context: ToolInvocationContext?,
        hostID: UUID,
        isResult: Bool,
        isError: Bool
    ) -> Bool {
        guard isOpen(owner: owner) else { return false }
        guard let context, context.invocationID == hostID, context.metadata.invocationID == hostID,
              context.codexThreadID == currentThreadID
        else { noteOccurrence(owner: owner)
            return false
        }
        // Normal terminal drain retires the active turn before queued host delivery. A delayed
        // first host call may use only this attempt's accepted H and already exact native call +
        // result as its retired-turn witness. The association below still joins raw call/thread/run;
        // neither a signature nor an orphan host/native result can manufacture that proof.
        let nativePair = attempt?.codexAssociation
        let exactRetiredCall = !isResult && attempt?.acceptedDeclarationInvocationID == hostID
            && nativePair?.nativeCallSeen == true && nativePair?.nativeResultSeen == true
            && nativePair?.invalid == false
        let turnID = currentTurnID ?? ((isResult || exactRetiredCall) ? nativePair?.turnID : nil)
        guard var pair = codexAssociation(
            owner: owner,
            runID: runID,
            threadID: currentThreadID,
            callID: context.codexCallID,
            turnID: turnID
        ) else { return false }
        if (pair.hostID != nil && pair.hostID != hostID) || (isResult && !pair.hostCallSeen) || isError {
            pair.invalid = true
            noteOccurrence(owner: owner)
        }
        pair.hostID = hostID
        pair.hostCallSeen = pair.hostCallSeen || !isResult
        pair.hostResultSeen = pair.hostResultSeen || isResult
        attempt?.codexAssociation = pair
        return !pair.invalid
    }

    func codexAssociationHasNativeResult(
        owner: AgentRunOwnership,
        hostID: UUID,
        runID: UUID?,
        threadID: String?
    ) -> Bool {
        guard isOpen(owner: owner), let pair = attempt?.codexAssociation,
              pair.runID == runID, pair.threadID == threadID, pair.hostID == hostID else { return false }
        return !pair.invalid && pair.hostCallSeen && pair.nativeCallSeen && pair.nativeResultSeen
    }

    func codexAssociationIsComplete(
        owner: AgentRunOwnership,
        hostID: UUID,
        runID: UUID?,
        threadID: String?
    ) -> Bool {
        codexAssociationHasNativeResult(owner: owner, hostID: hostID, runID: runID, threadID: threadID)
            && attempt?.codexAssociation?.hostResultSeen == true
    }

    mutating func invalidateRange(owner: AgentRunOwnership) {
        guard isOpen(owner: owner) else { return }
        attempt?.rangeIsComplete = false
    }

    func baseline(owner: AgentRunOwnership) -> Baseline? {
        attempt?.owner == owner ? attempt?.baseline : nil
    }

    func canCertify(owner: AgentRunOwnership, terminalState: AgentSessionRunState, normal: Bool, hasSuccessor: Bool, endKey: Int, rangeIsComplete: Bool, rows: some Collection<AgentChatItem>) -> Bool {
        guard let current = attempt, current.owner == owner, current.seal == nil else { return false }
        return facts != nil && current.serial != nil && normal && terminalState == .completed && !hasSuccessor
            && !current.hasOccurrence && current.rangeIsComplete
            && AgentSessionLinkPrompts.supportsQuietCheckIn(current.provider) && current.routineWakeID != nil
            && declarationRangeIsComplete(owner: owner, endKey: endKey, rangeIsComplete: rangeIsComplete, rows: rows)
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
        if let seal = current.seal {
            return seal
        }
        let quiet = canCertify(
            owner: owner,
            terminalState: terminalState,
            normal: classifiesQuietCheckIn,
            hasSuccessor: hasSuccessor,
            endKey: endKey,
            rangeIsComplete: rangeIsComplete,
            rows: rows
        )
        if quiet, let wakeID = current.routineWakeID,
           hostMarkerIDs.contains(wakeID) || !current.markerProducerFinished,
           hiddenSourceIDs.insert(wakeID).inserted
        {
            displayMaskRevision &+= 1
        }
        advance(quiet: quiet)
        let seal = Seal(ownership: owner, isQuiet: quiet, facts: facts)
        attempt?.seal = seal
        return seal
    }

    /// Use the canonical tool identity rule on the bounded attempt source, without rebuilding a
    /// transcript. Call/result echoes of one explicit invocation count once, independently of body
    /// cardinality. Missing/heuristically acquired identity cannot be repaired here.
    private func declarationRangeIsComplete(
        owner: AgentRunOwnership, endKey: Int, rangeIsComplete: Bool,
        rows: some Collection<AgentChatItem>
    ) -> Bool {
        guard let current = attempt, current.owner == owner, rangeIsComplete,
              let accepted = current.acceptedDeclarationInvocationID,
              current.startKey >= 0, endKey >= current.startKey else { return false }
        var expectedKey = current.startKey
        var sawEnd = false
        var sourceIDs: Set<UUID> = []
        var executions: Set<UUID> = []
        var sawResult = false
        for row in rows {
            guard !sawEnd, row.sequenceIndex == expectedKey, row.sequenceIndex <= endKey,
                  !row.isStreaming, sourceIDs.insert(row.id).inserted else { return false }
            sawEnd = row.sequenceIndex == endKey
            if !sawEnd {
                let (next, overflow) = expectedKey.addingReportingOverflow(1)
                guard !overflow else { return false }
                expectedKey = next
            }
            switch row.kind {
            case .toolCall, .toolResult:
                guard AgentTranscriptToolNormalizer.normalizedToolName(row.toolName) == MCPWindowToolName.selfNoop,
                      let invocationID = row.toolInvocationID, invocationID == accepted,
                      row.toolIsError != true else { return false }
                executions.insert(invocationID)
                if row.kind == .toolResult, row.toolResultJSON != nil { sawResult = true }
            case .assistant, .assistantInline:
                // Semantic ingress irreversibly latches text before accepted body intent. Queued
                // host callbacks can materialize canonical H after allowed closing text; source-row
                // order is not a second temporal authority. Range/identity/result checks still apply.
                break
            case .thinking:
                break
            case .system:
                guard hostMarkerIDs.contains(row.id),
                      row.text == AgentLaneUpdateDisplayAttribution.canonicalSystemText else { return false }
            case .user, .error:
                return false
            }
        }
        return sawEnd && sawResult && declarationMaySeal(owner: owner, canonicalInvocations: Array(executions))
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

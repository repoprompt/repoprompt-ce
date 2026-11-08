import Foundation
import RepoPromptDomainRuntime
import RepoPromptInstrumentation

enum AgentSourceItemsMutation {
    case append(index: Int, itemKind: AgentChatItemKind)
    case replace(index: Int, previousKind: AgentChatItemKind, currentKind: AgentChatItemKind)
    case mutate(index: Int, itemKind: AgentChatItemKind)
    case remove(index: Int, itemKind: AgentChatItemKind)
    case replaceAll
    case structural
    case metadataRange(ClosedRange<Int>)

    var changedIndexRange: ClosedRange<Int>? {
        switch self {
        case let .append(index, _),
             let .replace(index, _, _),
             let .mutate(index, _),
             let .remove(index, _):
            index ... index
        case let .metadataRange(range):
            range
        case .replaceAll, .structural:
            nil
        }
    }

    var touchesUserItem: Bool {
        switch self {
        case let .append(_, itemKind),
             let .mutate(_, itemKind),
             let .remove(_, itemKind):
            itemKind == .user
        case let .replace(_, previousKind, currentKind):
            previousKind == .user || currentKind == .user
        case .metadataRange:
            false
        case .replaceAll, .structural:
            true
        }
    }

    var isStructural: Bool {
        switch self {
        case .remove, .replaceAll, .structural:
            true
        case .append, .replace, .mutate, .metadataRange:
            false
        }
    }
}

struct AgentPendingSourceItemsMutationSummary: Equatable {
    var earliestChangedIndex: Int
    var latestChangedIndex: Int
    var containsRemoval: Bool
    var containsReplaceAll: Bool
    var containsUserMutation: Bool
    var containsStructuralMutation: Bool

    init(_ mutation: AgentSourceItemsMutation) {
        let changedRange = mutation.changedIndexRange
        earliestChangedIndex = changedRange?.lowerBound ?? 0
        latestChangedIndex = changedRange?.upperBound ?? Int.max
        containsRemoval = {
            if case .remove = mutation { return true }
            return false
        }()
        containsReplaceAll = {
            if case .replaceAll = mutation { return true }
            return false
        }()
        containsUserMutation = mutation.touchesUserItem
        containsStructuralMutation = mutation.isStructural
    }

    mutating func merge(_ mutation: AgentSourceItemsMutation) {
        if let changedRange = mutation.changedIndexRange {
            earliestChangedIndex = min(earliestChangedIndex, changedRange.lowerBound)
            latestChangedIndex = max(latestChangedIndex, changedRange.upperBound)
        } else {
            earliestChangedIndex = 0
            latestChangedIndex = Int.max
        }
        if case .remove = mutation {
            containsRemoval = true
        }
        if case .replaceAll = mutation {
            containsReplaceAll = true
        }
        containsUserMutation = containsUserMutation || mutation.touchesUserItem
        containsStructuralMutation = containsStructuralMutation || mutation.isStructural
    }

    var allowsIncrementalFinalTurnRebuild: Bool {
        !containsRemoval
            && !containsReplaceAll
            && !containsUserMutation
            && !containsStructuralMutation
    }
}

/// Owns source/run observation and coalesced transcript work. Optional presentation is not a
/// prerequisite for persistence or control publication. Existing session and save owners retain
/// their lifecycle, binding, restoration and durable-effect authority.
@MainActor
final class AgentSessionObservationRuntime {
    private weak var scope: AgentSessionRuntimeStore.Scope?
    var coalescesDerivedRefresh: () -> Bool = { true }

    init(scope: AgentSessionRuntimeStore.Scope) {
        self.scope = scope
    }

    func install(on session: AgentTabSession) {
        session.onSourceItemsChanged = { [self] session, mutation in
            guard let scope, scope.sessions[session.tabID] === session, !scope.hasReleasedWriterClaims else { return }
            // Source mutations never release a restoration baseline. Durability starts from the
            // canonical source itself, not from a subsequent presentation refresh.
            scope.persistence.scheduleSave(for: session)
            scheduleDerivedTranscriptRefresh(for: session, reason: .liveMutation, mutation: mutation)
        }
        session.onQuietDisplayMaskChanged = { [self] session in
            scope?.presentation.requestUIRefresh(for: session, scope: .transcriptRuntime)
        }
        session.onOverseerActivationRetired = { [self] session, retired in
            // Notify the existing discovery owner synchronously for the retired identity.
            // Only presentation is deferred past the enclosing binding/provenance mutation.
            AgentSessionLinkInvalidationSink.overseerActivationRetired?(retired.endpoint.sessionID)
            scheduleOversightPresentation(for: session)
        }
        session.onBindingTransitionSettled = { [self] session in
            scheduleOversightPresentation(for: session)
        }
        session.onRunStateChanged = { [self] session in
            guard let scope else { return }
            if !session.runState.isActive {
                _ = scope.turnTiming.completeNextAgentTurnRuntimeFooterIfNeeded(for: session, endedAt: Date())
            }
            if scope.sessions[session.tabID] === session, !scope.hasReleasedWriterClaims,
               session.hasLoadedPersistedState, session.runState != .idle,
               scope.persistence.composition?.isSuppressed() == false,
               scope.persistence.composition?.isRestoringConfiguration() == false
            {
                session.isDirty = true
                scope.persistence.scheduleSave(for: session)
            }
            scope.presentation.runStateChanged(session)
        }
        scope?.mcp.installStateObservation(for: session)
    }

    private func scheduleOversightPresentation(for session: AgentTabSession) {
        Task { @MainActor [weak self, weak session] in
            guard let self, let session, let scope, scope.sessions[session.tabID] === session else { return }
            scope.presentation.oversightBindingChanged(session)
        }
    }

    private func refreshDerivedTranscriptState(for session: AgentTabSession, reason: AgentDerivedTranscriptRefreshReason) {
        AgentSessionTranscriptRefreshRuntime.refreshDerivedTranscriptState(for: session, reason: reason)
        scope?.presentation.derivedTranscriptChanged(session)
    }

    private func scheduleDerivedTranscriptRefresh(
        for session: AgentTabSession,
        reason: AgentDerivedTranscriptRefreshReason,
        mutation: AgentSourceItemsMutation? = nil
    ) {
        guard let owner = scope else { return }
        let scheduleSignpost = EditFlowPerf.begin(
            EditFlowPerf.Stage.Transcript.scheduleRefresh,
            EditFlowPerf.Dimensions(
                status: reason.rawValue,
                sourceItemCount: session.items.count
            )
        )
        if reason == .liveMutation, let mutation {
            if var pendingSummary = session.pendingSourceItemsMutationSummary {
                pendingSummary.merge(mutation)
                session.pendingSourceItemsMutationSummary = pendingSummary
            } else {
                session.pendingSourceItemsMutationSummary = AgentPendingSourceItemsMutationSummary(mutation)
            }
        } else if reason != .liveMutation {
            session.pendingSourceItemsMutationSummary = nil
        }
        #if DEBUG || EDIT_FLOW_PERF
            session.transcriptPerformanceSnapshot.refreshRequestCount += 1
        #endif

        if session.terminalCommitInProgress, case .metadataRange? = mutation {
            EditFlowPerf.end(
                EditFlowPerf.Stage.Transcript.scheduleRefresh,
                scheduleSignpost,
                EditFlowPerf.Dimensions(status: reason.rawValue, outcome: "terminal-metadata-fold")
            )
            session.pendingDerivedTranscriptRefreshReason = .liveMutation
            return
        }

        guard reason == .liveMutation, coalescesDerivedRefresh() else {
            EditFlowPerf.end(
                EditFlowPerf.Stage.Transcript.scheduleRefresh,
                scheduleSignpost,
                EditFlowPerf.Dimensions(status: reason.rawValue, outcome: "immediate")
            )
            session.pendingDerivedTranscriptRefreshReason = nil
            session.derivedTranscriptRefreshGeneration &+= 1
            session.derivedTranscriptRefreshTask?.cancel()
            session.derivedTranscriptRefreshTask = nil
            #if DEBUG || EDIT_FLOW_PERF
                session.transcriptPerformanceSnapshot.refreshImmediateCount += 1
            #endif
            refreshDerivedTranscriptState(for: session, reason: reason)
            return
        }

        if session.derivedTranscriptRefreshTask != nil {
            EditFlowPerf.end(
                EditFlowPerf.Stage.Transcript.scheduleRefresh,
                scheduleSignpost,
                EditFlowPerf.Dimensions(status: reason.rawValue, outcome: "coalesced")
            )
            #if DEBUG || EDIT_FLOW_PERF
                session.transcriptPerformanceSnapshot.refreshCoalescedCount += 1
            #endif
            session.pendingDerivedTranscriptRefreshReason = .liveMutation
            return
        }

        EditFlowPerf.end(
            EditFlowPerf.Stage.Transcript.scheduleRefresh,
            scheduleSignpost,
            EditFlowPerf.Dimensions(status: reason.rawValue, outcome: "scheduled")
        )
        session.pendingDerivedTranscriptRefreshReason = .liveMutation
        session.derivedTranscriptRefreshGeneration &+= 1
        let scheduledGeneration = session.derivedTranscriptRefreshGeneration
        session.derivedTranscriptRefreshTask = Task { @MainActor [self, owner, session] in
            defer {
                if session.derivedTranscriptRefreshGeneration == scheduledGeneration {
                    session.derivedTranscriptRefreshTask = nil
                }
            }
            guard !Task.isCancelled else { return }
            guard owner.sessions[session.tabID] === session, !owner.hasReleasedWriterClaims else { return }
            guard session.derivedTranscriptRefreshGeneration == scheduledGeneration else { return }
            let scheduledReason = session.pendingDerivedTranscriptRefreshReason ?? .liveMutation
            session.pendingDerivedTranscriptRefreshReason = nil
            session.derivedTranscriptRefreshTask = nil
            refreshDerivedTranscriptState(for: session, reason: scheduledReason)
        }
    }
}

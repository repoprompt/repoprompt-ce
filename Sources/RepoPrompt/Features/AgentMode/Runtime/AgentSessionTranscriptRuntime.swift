import Foundation
import RepoPromptAIContracts

/// Runtime hydration/build values. Neither is persisted or reflected into a wire schema;
/// view-model aliases preserve source compatibility while loaders no longer name a VM.
struct AgentBuiltTranscriptPresentation {
    var localInputSeed = AgentSessionLinkRetainedLocalInputIndex.Seed()
    let transcript: AgentTranscript
    let baseProjection: AgentTranscriptProjection
    let fullProjection: AgentTranscriptProjection
    let workingProjection: AgentTranscriptProjection
    let projection: AgentTranscriptProjection
    let turnProjectionCaches: [UUID: AgentTranscriptTurnProjectionCache]
    let archivedSnapshot: AgentArchivedTranscriptSnapshot
    /// Semantic reuse evidence from the validated sanitizer prefix, not a claim that
    /// building the archive projection avoided traversal or reused its storage.
    let reusesPreviousArchive: Bool
    let projectionProtection: AgentTranscriptProjectionProtection
    let canonicalVisibleRowCount: Int
    let projectionCounts: AgentTranscriptProjectionCounts
    let analyticsSnapshot: AgentTranscriptAnalyticsSnapshot
    let sanitizedActivityCount: Int
    let performanceSnapshot: AgentTranscriptPerformanceSnapshot
    let rawToolResultPayloadRenderRevisionByItemID: [UUID: Int]
}

struct AgentDerivedTranscriptSyncState: Equatable {
    let sourceItemsRevision: Int
    let nextSequenceIndex: Int
    let runState: AgentSessionRunState
    let selectedAgent: AgentProviderKind
    let hidePendingQuestionToolCall: Bool
    let projectionProtection: AgentTranscriptProjectionProtection
}

/// The single synchronous application of a built transcript to runtime state. No active
/// tab, UI publication, workspace model or provider factory participates in hydration.
@MainActor
enum AgentSessionTranscriptRuntime {
    static func materializedProjection(for session: AgentTabSession) -> AgentTranscriptProjection {
        let projection = session.isCompressedHistoryRevealed ? session.fullTranscriptProjection : session.workingTranscriptProjection
        return AgentTranscriptProjectionBuilder.tailWindowedProjection(
            from: projection, transcript: session.transcript, isExpanded: session.isTranscriptWindowExpanded
        )
    }

    static func syncState(
        for session: AgentTabSession,
        projectionProtection: AgentTranscriptProjectionProtection
    ) -> AgentDerivedTranscriptSyncState {
        .init(
            sourceItemsRevision: session.sourceItemsRevision,
            nextSequenceIndex: session.nextSequenceIndex,
            runState: session.runState,
            selectedAgent: session.selectedAgent,
            hidePendingQuestionToolCall: session.hasPendingQuestionUI,
            projectionProtection: projectionProtection
        )
    }

    @discardableResult
    static func apply(
        _ presentation: AgentBuiltTranscriptPresentation,
        sourceItems: [AgentChatItem]? = nil,
        reconcilesQuietSourceRetirement: Bool = true,
        isLiveRefresh: Bool = false,
        to session: AgentTabSession
    ) -> Bool {
        guard sourceItems == nil || sourceItems == session.items else {
            session.compactSummaryOnlyToolResultsAndAlignEphemeralPayloadMap()
            return false
        }
        let previousQuietSourceAnchors = reconcilesQuietSourceRetirement ? session.fullTranscriptProjection.rowAnchorIndex : [:]
        session.transcript = presentation.transcript
        session.installLocalInputSeed(presentation.localInputSeed)
        session.baseTranscriptProjection = presentation.baseProjection
        session.fullTranscriptProjection = presentation.fullProjection
        session.workingTranscriptProjection = presentation.workingProjection
        session.turnProjectionCaches = presentation.turnProjectionCaches
        // Only a synchronous live refresh may retain the installed archive. Explicit
        // apply/hydration, replacement and reset remain writers, even at the same revision.
        if !isLiveRefresh || !presentation.reusesPreviousArchive {
            session.archivedTranscriptSnapshot = presentation.archivedSnapshot
        } else {
            #if DEBUG
                assert(presentation.archivedSnapshot == session.archivedTranscriptSnapshot, "Live refresh archive reuse must preserve the installed snapshot")
            #endif
        }
        session.transcriptProjection = materializedProjection(for: session)
        if reconcilesQuietSourceRetirement { session.reconcileQuietSourceIDs(previousAnchors: previousQuietSourceAnchors) }
        session.transcriptProjectionProtection = presentation.projectionProtection
        session.transcriptCanonicalVisibleRowCount = presentation.canonicalVisibleRowCount
        session.transcriptProjectionCounts = presentation.projectionCounts
        session.transcriptAnalyticsSnapshot = presentation.analyticsSnapshot
        session.rawToolResultPayloadRenderRevisionByItemID = presentation.rawToolResultPayloadRenderRevisionByItemID
        #if DEBUG || EDIT_FLOW_PERF
            session.transcriptPerformanceSnapshot = presentation.performanceSnapshot
        #else
            session.transcriptPerformanceSnapshot = .empty
        #endif
        session.derivedTranscriptSyncState = syncState(for: session, projectionProtection: presentation.projectionProtection)
        return true
    }
}

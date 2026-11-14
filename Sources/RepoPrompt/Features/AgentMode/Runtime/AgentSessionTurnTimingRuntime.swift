import Foundation

struct AgentTurnUserAnchorRollbackState {
    struct CompletedFooter {
        let anchor: AgentTabSession.AgentTurnRuntimeAnchor
        let footerItemID: UUID?
        let previousFooter: AgentMessageRuntimeFooter?
        let writtenFooter: AgentMessageRuntimeFooter?
    }

    let userItemID: UUID
    let previousActiveAgentRunStartedAt: Date?
    var completedFooters: [CompletedFooter] = []
    var restartedElapsedTimerAt: Date?
}

/// Shared turn timing and conditional rollback; presentation only observes mutations.
@MainActor
final class AgentSessionTurnTimingRuntime {
    typealias TabSession = AgentTabSession
    let presentation: AgentSessionPresentationRuntime
    init(presentation: AgentSessionPresentationRuntime) {
        self.presentation = presentation
    }

    func recordAgentTurnUserAnchor(
        for session: TabSession,
        userItem: AgentChatItem
    ) -> AgentTurnUserAnchorRollbackState {
        var rollback = AgentTurnUserAnchorRollbackState(
            userItemID: userItem.id,
            previousActiveAgentRunStartedAt: session.activeAgentRunStartedAt
        )
        if session.runState == .running {
            if let completedFooter = completeNextAgentTurnRuntimeFooterIfNeeded(
                for: session,
                endedAt: userItem.timestamp,
                maxSequenceIndexExclusive: userItem.sequenceIndex
            ) {
                rollback.completedFooters.append(completedFooter)
            }
        }

        if shouldRestartActiveAgentRunElapsedTimer(for: session) {
            let startedAtBeforeRestart = session.activeAgentRunStartedAt
            restartActiveAgentRunElapsedTimer(for: session, startedAt: userItem.timestamp)
            if session.activeAgentRunStartedAt != startedAtBeforeRestart {
                rollback.restartedElapsedTimerAt = session.activeAgentRunStartedAt
            }
        }

        let anchor = TabSession.AgentTurnRuntimeAnchor(
            userItemID: userItem.id,
            userSequenceIndex: userItem.sequenceIndex,
            startedAt: userItem.timestamp
        )
        if session.runState == .waitingForUser,
           !session.pendingTurnRuntimeAnchors.isEmpty
        {
            if let completedFooter = completeNextAgentTurnRuntimeFooterIfNeeded(
                for: session,
                endedAt: userItem.timestamp,
                maxSequenceIndexExclusive: userItem.sequenceIndex
            ) {
                rollback.completedFooters.append(completedFooter)
            }
        }
        session.pendingTurnRuntimeAnchors.append(anchor)
        return rollback
    }

    func rollbackAgentTurnUserAnchor(
        _ rollback: AgentTurnUserAnchorRollbackState,
        session: TabSession
    ) {
        session.pendingTurnRuntimeAnchors.removeAll { $0.userItemID == rollback.userItemID }
        for completedFooter in rollback.completedFooters.reversed() {
            if let footerItemID = completedFooter.footerItemID {
                guard let writtenFooter = completedFooter.writtenFooter,
                      session.agentMessageRuntimeFootersByItemID[footerItemID] == writtenFooter
                else {
                    // A newer runtime mutation won this footer. Keep the
                    // consumed anchor consumed as part of the same atomic
                    // decision so it cannot be attributed a second time.
                    continue
                }
                session.agentMessageRuntimeFootersByItemID[footerItemID] = completedFooter.previousFooter
            }
            // Reinsert the consumed anchor only while its user item and active
            // turn still exist. A back-to-back rejected submission may have
            // already removed that optimistic bubble, while a terminal runtime
            // transition may have made the anchor no longer pending work.
            if session.runState.isActive,
               session.items.contains(where: { $0.id == completedFooter.anchor.userItemID }),
               !session.pendingTurnRuntimeAnchors.contains(where: {
                   $0.userItemID == completedFooter.anchor.userItemID
               })
            {
                session.pendingTurnRuntimeAnchors.insert(completedFooter.anchor, at: 0)
            }
        }
        if let restartedElapsedTimerAt = rollback.restartedElapsedTimerAt {
            if session.activeAgentRunStartedAt == restartedElapsedTimerAt {
                let restoredStartedAt: Date? = if let deferredRollback = session.deferredActiveAgentRunTimerRollback {
                    deferredRollback.originalStartedAt
                } else {
                    rollback.previousActiveAgentRunStartedAt
                }
                session.deferredActiveAgentRunTimerRollback = nil
                session.activeAgentRunStartedAt = restoredStartedAt
                presentation.elapsedTimeChanged(session)
            } else if session.deferredActiveAgentRunTimerRollback == nil,
                      let activeAgentRunStartedAt = session.activeAgentRunStartedAt,
                      session.pendingTurnRuntimeAnchors.contains(where: {
                          $0.startedAt == activeAgentRunStartedAt
                      })
            {
                // A later optimistic submission owns the visible timer. Carry
                // this rejection's original baseline forward so rejection of
                // that later submission skips this already-rejected timestamp.
                session.deferredActiveAgentRunTimerRollback = .init(
                    originalStartedAt: rollback.previousActiveAgentRunStartedAt
                )
            }
        }
        presentation.requestUIRefresh(for: session, urgent: true)
    }

    func shouldRestartActiveAgentRunElapsedTimer(for session: TabSession) -> Bool {
        session.runState == .running
    }

    func restartActiveAgentRunElapsedTimer(for session: TabSession, startedAt: Date) {
        guard session.activeAgentRunStartedAt != startedAt else { return }
        session.activeAgentRunStartedAt = startedAt
        presentation.elapsedTimeChanged(session)
        presentation.requestUIRefresh(for: session, urgent: true)
    }

    func completeNextAgentTurnRuntimeFooterIfNeeded(
        for session: TabSession,
        endedAt: Date,
        maxSequenceIndexExclusive explicitMaxSequenceIndexExclusive: Int? = nil
    ) -> AgentTurnUserAnchorRollbackState.CompletedFooter? {
        guard !session.pendingTurnRuntimeAnchors.isEmpty else { return nil }
        let anchor = session.pendingTurnRuntimeAnchors.removeFirst()
        let nextAnchorUpperBound = session.pendingTurnRuntimeAnchors.first?.userSequenceIndex
        let upperBound = explicitMaxSequenceIndexExclusive ?? nextAnchorUpperBound
        guard let target = session.items.last(where: { item in
            guard item.sequenceIndex > anchor.userSequenceIndex else { return false }
            if let upperBound, item.sequenceIndex >= upperBound {
                return false
            }
            return item.hasDisplayableAssistantBody
        }) else {
            return AgentTurnUserAnchorRollbackState.CompletedFooter(
                anchor: anchor,
                footerItemID: nil,
                previousFooter: nil,
                writtenFooter: nil
            )
        }
        let previousFooter = session.agentMessageRuntimeFootersByItemID[target.id]
        let writtenFooter = AgentMessageRuntimeFooter(
            itemID: target.id,
            anchorDate: anchor.startedAt,
            completedDate: max(endedAt, anchor.startedAt),
            statusText: "Worked for"
        )
        session.agentMessageRuntimeFootersByItemID[target.id] = writtenFooter
        presentation.requestUIRefresh(for: session, urgent: true)
        return AgentTurnUserAnchorRollbackState.CompletedFooter(
            anchor: anchor,
            footerItemID: target.id,
            previousFooter: previousFooter,
            writtenFooter: writtenFooter
        )
    }
}

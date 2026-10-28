import CoreGraphics
import Foundation

struct AgentTranscriptScrollRuntimeState {
    let armingState: AgentModeViewModel.AgentTranscriptAutoFollowArmingState
    let isPinnedToLiveBottom: Bool
    let isDetachedFromLiveBottom: Bool
    let isUserInteractingWithScroll: Bool
    let isInteractionBlocked: Bool
    let isRehydrateRestoreActive: Bool
    let isProgrammaticScrollInFlight: Bool
    let canScrollTowardHistory: Bool
    let canScrollTowardLiveBottom: Bool
    let distanceToBottom: CGFloat
}

struct AgentTranscriptViewportProgress {
    let baselineDistanceToBottom: CGFloat
    let currentDistanceToBottom: CGFloat
    let baselineVisibleMinY: CGFloat
    let currentVisibleMinY: CGFloat
}

enum AgentTranscriptManualDetachOverridePolicy {
    static func isActive(until: Date?, now: Date) -> Bool {
        guard let until else { return false }
        return now < until
    }

    static func shouldSuppressActualBottomRepin(until: Date?, now: Date) -> Bool {
        isActive(until: until, now: now)
    }

    static func shouldSuppressDetachedRevisionImmediateRepin(until: Date?, now: Date) -> Bool {
        isActive(until: until, now: now)
    }

    static func shouldSuppressGeometryRepin(until: Date?, now: Date) -> Bool {
        isActive(until: until, now: now)
    }
}

enum AgentTranscriptRehydrateRestoreLayoutPolicy {
    static func hasValidLayoutSample(_ metrics: AgentTranscriptScrollMetrics) -> Bool {
        metrics.viewportHeight > 0
    }

    static func canCompleteLiveBottomRestore(
        currentLayoutSampleKey: AgentTranscriptRehydrateRetryKey?,
        tabID: UUID,
        presentationRevision: Int,
        layoutPassToken: UInt64,
        isNearBottom: Bool
    ) -> Bool {
        guard isNearBottom else { return false }
        return currentLayoutSampleKey == AgentTranscriptRehydrateRetryKey(
            tabID: tabID,
            presentationRevision: presentationRevision,
            layoutPassToken: layoutPassToken
        )
    }
}

enum AgentTranscriptActivationRepaintRemountPolicy {
    static let maximumRemountsPerActivation = 2

    static func remountKey(
        oldSignal: AgentTranscriptRestoreSignal,
        newSignal: AgentTranscriptRestoreSignal,
        currentTabID: UUID?,
        rehydratePhase: AgentTranscriptRehydrateRestorePhase,
        lastRemountKey: AgentTranscriptRehydrateRetryKey?,
        remountCount: Int,
        layoutPassToken: UInt64
    ) -> AgentTranscriptRehydrateRetryKey? {
        guard let currentTabID,
              newSignal.tabID == currentTabID,
              newSignal.bindingsHydrated,
              rehydratePhase.tabID == currentTabID,
              rehydratePhase.isActive,
              rehydratePhase.target == .liveBottom,
              remountCount < maximumRemountsPerActivation
        else {
            return nil
        }

        let enteredTab = oldSignal.tabID != newSignal.tabID
        let becameHydrated = oldSignal.tabID == newSignal.tabID
            && !oldSignal.bindingsHydrated
            && newSignal.bindingsHydrated
        let revisionChanged = oldSignal.tabID == newSignal.tabID
            && oldSignal.presentationRevision != newSignal.presentationRevision
        let isAwaitingHydrationOrLayout = switch rehydratePhase {
        case .awaitingHydration, .awaitingLayout:
            true
        case .idle, .driving:
            false
        }

        guard enteredTab || becameHydrated || (revisionChanged && isAwaitingHydrationOrLayout) else {
            return nil
        }

        let key = AgentTranscriptRehydrateRetryKey(
            tabID: currentTabID,
            presentationRevision: newSignal.presentationRevision,
            layoutPassToken: layoutPassToken
        )
        if lastRemountKey?.tabID == currentTabID,
           lastRemountKey?.presentationRevision == newSignal.presentationRevision
        {
            return nil
        }
        return key
    }
}

enum AgentTranscriptBottomScrollOutcomeLayoutPolicy {
    static func hasMaterialLayoutMutation(
        oldMetrics: AgentTranscriptScrollMetrics,
        newMetrics: AgentTranscriptScrollMetrics,
        contentHeightThreshold: CGFloat,
        viewportHeightThreshold: CGFloat
    ) -> Bool {
        let contentHeightDelta = abs(newMetrics.contentHeight - oldMetrics.contentHeight)
        let viewportHeightDelta = abs(newMetrics.viewportHeight - oldMetrics.viewportHeight)
        return contentHeightDelta >= contentHeightThreshold
            || viewportHeightDelta >= viewportHeightThreshold
    }

    static func remainingQuietDelay(
        lastLayoutMutationAt: Date?,
        now: Date,
        quietPeriod: TimeInterval
    ) -> TimeInterval? {
        guard quietPeriod > 0,
              let lastLayoutMutationAt
        else {
            return nil
        }
        let elapsed = now.timeIntervalSince(lastLayoutMutationAt)
        guard elapsed < quietPeriod else { return nil }
        return quietPeriod - max(0, elapsed)
    }
}

enum AgentTranscriptIdleBoundaryProgressResolver {
    static func resolve(
        activeSession: AgentTranscriptUserScrollSession?,
        lastCompletedSession: AgentTranscriptCompletedUserScrollSession?,
        currentMetrics: AgentTranscriptScrollMetrics,
        now: Date,
        freshnessWindow: TimeInterval
    ) -> (hasTowardHistoryManualIntent: Bool, progress: AgentTranscriptViewportProgress)? {
        if let activeSession {
            return (
                hasTowardHistoryManualIntent: activeSession.latestIntent == .towardHistory,
                progress: AgentTranscriptViewportProgress(
                    baselineDistanceToBottom: activeSession.baselineMetrics.distanceToBottom,
                    currentDistanceToBottom: max(currentMetrics.distanceToBottom, activeSession.latestMetrics.distanceToBottom),
                    baselineVisibleMinY: activeSession.baselineMetrics.visibleMinY,
                    currentVisibleMinY: min(currentMetrics.visibleMinY, activeSession.latestMetrics.visibleMinY)
                )
            )
        }
        guard let lastCompletedSession,
              freshnessWindow > 0,
              now.timeIntervalSince(lastCompletedSession.endedAt) <= freshnessWindow
        else {
            return nil
        }
        return (
            hasTowardHistoryManualIntent: lastCompletedSession.latestIntent == .towardHistory,
            progress: AgentTranscriptViewportProgress(
                baselineDistanceToBottom: lastCompletedSession.baselineMetrics.distanceToBottom,
                currentDistanceToBottom: max(currentMetrics.distanceToBottom, lastCompletedSession.finalMetrics.distanceToBottom),
                baselineVisibleMinY: lastCompletedSession.baselineMetrics.visibleMinY,
                currentVisibleMinY: min(currentMetrics.visibleMinY, lastCompletedSession.finalMetrics.visibleMinY)
            )
        )
    }
}

enum AgentTranscriptPinnedBottomProtectionPolicy {
    static func shouldArmOnBottomSettle(
        runtime: AgentTranscriptScrollRuntimeState,
        nearBottomThreshold: CGFloat
    ) -> Bool {
        runtime.isPinnedToLiveBottom
            && !runtime.isDetachedFromLiveBottom
            && !runtime.isUserInteractingWithScroll
            && !runtime.isInteractionBlocked
            && !runtime.isRehydrateRestoreActive
            && runtime.distanceToBottom <= nearBottomThreshold
    }

    static func shouldRemainActiveAfterSmoothSendCompletion(
        runtime: AgentTranscriptScrollRuntimeState
    ) -> Bool {
        runtime.isPinnedToLiveBottom
            && !runtime.isDetachedFromLiveBottom
            && !runtime.isUserInteractingWithScroll
            && !runtime.isInteractionBlocked
            && !runtime.isRehydrateRestoreActive
    }

    static func shouldPreserveLastResolvedScrollView(
        hasExistingScrollView: Bool,
        hasNewlyResolvedScrollView: Bool
    ) -> Bool {
        hasExistingScrollView && !hasNewlyResolvedScrollView
    }
}

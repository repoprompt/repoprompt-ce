import CoreGraphics
import Foundation
@testable import RepoPromptApp
import XCTest

final class AgentTranscriptActivationRepaintRemountPolicyTests: XCTestCase {
    func testEnteredHydratedLiveBottomActivationProducesRemountKey() {
        let tabID = UUID()
        let key = AgentTranscriptActivationRepaintRemountPolicy.remountKey(
            oldSignal: AgentTranscriptRestoreSignal(tabID: UUID(), bindingsHydrated: true, presentationRevision: 1),
            newSignal: AgentTranscriptRestoreSignal(tabID: tabID, bindingsHydrated: true, presentationRevision: 7),
            currentTabID: tabID,
            rehydratePhase: .awaitingHydration(tabID: tabID, target: .liveBottom),
            lastRemountKey: nil,
            remountCount: 0,
            layoutPassToken: 42
        )

        XCTAssertEqual(key, AgentTranscriptRehydrateRetryKey(tabID: tabID, presentationRevision: 7, layoutPassToken: 42))
    }

    func testDuplicateRevisionExceededLimitDetachedOrIdleActivationSuppressesRemount() {
        let tabID = UUID()
        let oldSignal = AgentTranscriptRestoreSignal(tabID: nil, bindingsHydrated: false, presentationRevision: 0)
        let newSignal = AgentTranscriptRestoreSignal(tabID: tabID, bindingsHydrated: true, presentationRevision: 3)
        let previousKey = AgentTranscriptRehydrateRetryKey(tabID: tabID, presentationRevision: 3, layoutPassToken: 1)

        XCTAssertNil(AgentTranscriptActivationRepaintRemountPolicy.remountKey(
            oldSignal: oldSignal,
            newSignal: newSignal,
            currentTabID: tabID,
            rehydratePhase: .awaitingLayout(tabID: tabID, presentationRevision: 3, target: .liveBottom),
            lastRemountKey: previousKey,
            remountCount: 0,
            layoutPassToken: 2
        ))
        XCTAssertNil(AgentTranscriptActivationRepaintRemountPolicy.remountKey(
            oldSignal: oldSignal,
            newSignal: newSignal,
            currentTabID: tabID,
            rehydratePhase: .awaitingLayout(tabID: tabID, presentationRevision: 3, target: .liveBottom),
            lastRemountKey: nil,
            remountCount: AgentTranscriptActivationRepaintRemountPolicy.maximumRemountsPerActivation,
            layoutPassToken: 2
        ))
        XCTAssertNil(AgentTranscriptActivationRepaintRemountPolicy.remountKey(
            oldSignal: oldSignal,
            newSignal: newSignal,
            currentTabID: tabID,
            rehydratePhase: .awaitingHydration(tabID: tabID, target: .detached(nil)),
            lastRemountKey: nil,
            remountCount: 0,
            layoutPassToken: 0
        ))
        XCTAssertNil(AgentTranscriptActivationRepaintRemountPolicy.remountKey(
            oldSignal: oldSignal,
            newSignal: newSignal,
            currentTabID: tabID,
            rehydratePhase: .idle,
            lastRemountKey: nil,
            remountCount: 0,
            layoutPassToken: 0
        ))
    }
}

/// Pure scroll-policy contracts behind Agent Mode transcript auto-follow, detach and restore.
final class AgentTranscriptScrollPolicyTests: XCTestCase {
    private let referenceDate = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func runtime(
        isPinnedToLiveBottom: Bool = true,
        isDetachedFromLiveBottom: Bool = false,
        isUserInteractingWithScroll: Bool = false,
        isInteractionBlocked: Bool = false,
        isRehydrateRestoreActive: Bool = false,
        isProgrammaticScrollInFlight: Bool = false,
        canScrollTowardLiveBottom: Bool = false,
        distanceToBottom: CGFloat = 0
    ) -> AgentTranscriptScrollRuntimeState {
        AgentTranscriptScrollRuntimeState(
            armingState: .armed,
            isPinnedToLiveBottom: isPinnedToLiveBottom,
            isDetachedFromLiveBottom: isDetachedFromLiveBottom,
            isUserInteractingWithScroll: isUserInteractingWithScroll,
            isInteractionBlocked: isInteractionBlocked,
            isRehydrateRestoreActive: isRehydrateRestoreActive,
            isProgrammaticScrollInFlight: isProgrammaticScrollInFlight,
            canScrollTowardHistory: true,
            canScrollTowardLiveBottom: canScrollTowardLiveBottom,
            distanceToBottom: distanceToBottom
        )
    }

    private func progress(visibleMinYFrom baseline: CGFloat, to current: CGFloat) -> AgentTranscriptViewportProgress {
        AgentTranscriptViewportProgress(
            baselineDistanceToBottom: 0,
            currentDistanceToBottom: 0,
            baselineVisibleMinY: baseline,
            currentVisibleMinY: current
        )
    }

    private func metrics(
        distanceToBottom: CGFloat = 0,
        visibleMinY: CGFloat = 0,
        contentHeight: CGFloat = 2000,
        viewportHeight: CGFloat = 600
    ) -> AgentTranscriptScrollMetrics {
        AgentTranscriptScrollMetrics(
            distanceToBottom: distanceToBottom,
            visibleMinY: visibleMinY,
            contentHeight: contentHeight,
            viewportHeight: viewportHeight
        )
    }

    // MARK: - AgentTranscriptAutoFollowRearmPolicy

    func testDetachRequiresUserTowardHistoryGestureThatEscapesTheThreshold() {
        let interacting = runtime(isUserInteractingWithScroll: true)
        func shouldDetach(
            _ state: AgentTranscriptScrollRuntimeState,
            intent: DetachedManualScrollDirection = .towardHistory,
            escape: CGFloat,
            suppressGeometry: Bool = false
        ) -> Bool {
            AgentTranscriptAutoFollowRearmPolicy.shouldDetachFromLiveBottom(
                runtime: state,
                latestManualIntent: intent,
                progress: progress(visibleMinYFrom: 1400, to: 1400 - escape),
                minimumViewportEscapeDistance: 24,
                suppressGeometryDetach: suppressGeometry,
                suppressRepinGraceDetach: false
            )
        }

        XCTAssertTrue(shouldDetach(interacting, escape: 24))
        XCTAssertFalse(shouldDetach(interacting, escape: 23), "sub-threshold movement must not detach")
        XCTAssertFalse(shouldDetach(interacting, intent: .towardLiveBottom, escape: 200))
        XCTAssertFalse(shouldDetach(runtime(), escape: 200), "content growth without a gesture never detaches")
        XCTAssertFalse(shouldDetach(interacting, escape: 200, suppressGeometry: true))
    }

    func testIdleTransitionDetachHonorsArmingAndRestoreState() {
        func shouldDetach(
            _ state: AgentTranscriptScrollRuntimeState,
            armed: Bool = true,
            towardHistory: Bool = true
        ) -> Bool {
            AgentTranscriptAutoFollowRearmPolicy.shouldDetachFromLiveBottomAfterRunBecomesIdle(
                runtime: state,
                idleTransitionArmed: armed,
                hasTowardHistoryManualIntent: towardHistory,
                progress: progress(visibleMinYFrom: 900, to: 850),
                minimumEscapeDistance: 6
            )
        }

        XCTAssertTrue(shouldDetach(runtime()))
        XCTAssertFalse(shouldDetach(runtime(), armed: false))
        XCTAssertFalse(shouldDetach(runtime(), towardHistory: false))
        XCTAssertFalse(shouldDetach(runtime(isRehydrateRestoreActive: true)))
        XCTAssertFalse(shouldDetach(runtime(isPinnedToLiveBottom: false, isDetachedFromLiveBottom: true)))
    }

    func testDetachedViewportAtActualBottomForcesRepinOnlyWhenNothingElseMovesIt() {
        let detachedAtBottom = runtime(isPinnedToLiveBottom: false, isDetachedFromLiveBottom: true, distanceToBottom: 1)
        XCTAssertTrue(AgentTranscriptAutoFollowRearmPolicy.shouldForceRepinDetachedAtActualBottom(
            runtime: detachedAtBottom,
            actualBottomDistanceThreshold: 1
        ))
        XCTAssertFalse(AgentTranscriptAutoFollowRearmPolicy.shouldForceRepinDetachedAtActualBottom(
            runtime: runtime(isPinnedToLiveBottom: false, isDetachedFromLiveBottom: true, distanceToBottom: 2),
            actualBottomDistanceThreshold: 1
        ))
        XCTAssertFalse(AgentTranscriptAutoFollowRearmPolicy.shouldForceRepinDetachedAtActualBottom(
            runtime: runtime(
                isPinnedToLiveBottom: false,
                isDetachedFromLiveBottom: true,
                isProgrammaticScrollInFlight: true,
                distanceToBottom: 0
            ),
            actualBottomDistanceThreshold: 1
        ))
        XCTAssertFalse(AgentTranscriptAutoFollowRearmPolicy.shouldForceRepinDetachedAtActualBottom(
            runtime: runtime(
                isPinnedToLiveBottom: false,
                isDetachedFromLiveBottom: true,
                canScrollTowardLiveBottom: true,
                distanceToBottom: 0
            ),
            actualBottomDistanceThreshold: 1
        ))
    }

    // MARK: - AgentTranscriptScrollProgressPolicy / UserScrollIntentResolver

    func testManualScrollDistanceDeltaIgnoresRelayout() {
        let before = metrics(distanceToBottom: 100)
        XCTAssertEqual(
            AgentTranscriptScrollProgressPolicy.effectiveDistanceDeltaForManualScroll(
                oldMetrics: before,
                newMetrics: metrics(distanceToBottom: 160),
                layoutMutationThreshold: 2
            ),
            60
        )
        XCTAssertEqual(
            AgentTranscriptScrollProgressPolicy.effectiveDistanceDeltaForManualScroll(
                oldMetrics: before,
                newMetrics: metrics(distanceToBottom: 400, contentHeight: 2300),
                layoutMutationThreshold: 2
            ),
            0,
            "content growth must not read as a manual scroll toward history"
        )
        XCTAssertEqual(
            AgentTranscriptScrollProgressPolicy.effectiveDistanceDeltaForManualScroll(
                oldMetrics: before,
                newMetrics: metrics(distanceToBottom: 130, viewportHeight: 570),
                layoutMutationThreshold: 2
            ),
            0
        )
    }

    func testIntentResolverDirectionsAndPinnedDistanceGrowthGuard() {
        XCTAssertEqual(
            AgentTranscriptUserScrollIntentResolver.resolve(distanceDelta: 24, visibleMinYDelta: 0, distanceThreshold: 24, visibleMinYThreshold: 12),
            .towardHistory
        )
        XCTAssertEqual(
            AgentTranscriptUserScrollIntentResolver.resolve(distanceDelta: 0, visibleMinYDelta: 12, distanceThreshold: 24, visibleMinYThreshold: 12),
            .towardLiveBottom
        )
        XCTAssertEqual(
            AgentTranscriptUserScrollIntentResolver.resolve(distanceDelta: 23, visibleMinYDelta: -11, distanceThreshold: 24, visibleMinYThreshold: 12),
            .unknown
        )
        // While pinned, distance growth alone (streaming content) is never upward intent.
        XCTAssertEqual(
            AgentTranscriptUserScrollIntentResolver.resolvePinnedLiveBottomFollowIntent(
                distanceDelta: 500,
                visibleMinYDelta: 0,
                distanceThreshold: 24,
                visibleMinYThreshold: 12
            ),
            .unknown
        )
        XCTAssertEqual(
            AgentTranscriptUserScrollIntentResolver.resolvePinnedLiveBottomFollowIntent(
                distanceDelta: 0,
                visibleMinYDelta: -12,
                distanceThreshold: 24,
                visibleMinYThreshold: 12
            ),
            .towardHistory
        )
        XCTAssertEqual(AgentTranscriptUserScrollIntentResolver.resolve(verticalVelocity: 0.5), .unknown)
        XCTAssertEqual(AgentTranscriptUserScrollIntentResolver.resolve(verticalVelocity: 3), .towardHistory)
        XCTAssertEqual(AgentTranscriptUserScrollIntentResolver.resolve(verticalVelocity: -3), .towardLiveBottom)
        XCTAssertEqual(
            AgentTranscriptUserScrollIntentResolver.resolveFromCumulativeViewportMovement(visibleMinYDelta: -6, visibleMinYThreshold: 6),
            .towardHistory
        )
    }

    func testMeaningfulManualProgressUsesViewportOriginInTheIntendedDirection() {
        let movedUp = progress(visibleMinYFrom: 1000, to: 990)
        XCTAssertTrue(AgentTranscriptScrollProgressPolicy.hasMeaningfulManualProgress(
            direction: .towardHistory,
            progress: movedUp,
            distanceThreshold: 8,
            visibleMinYThreshold: 6
        ))
        XCTAssertFalse(AgentTranscriptScrollProgressPolicy.hasMeaningfulManualProgress(
            direction: .towardLiveBottom,
            progress: movedUp,
            distanceThreshold: 8,
            visibleMinYThreshold: 6
        ))
        XCTAssertTrue(AgentTranscriptScrollProgressPolicy.hasMeaningfulManualProgress(
            direction: .unknown,
            progress: movedUp,
            distanceThreshold: 8,
            visibleMinYThreshold: 6
        ))
        XCTAssertFalse(AgentTranscriptScrollProgressPolicy.hasTowardHistoryViewportEscape(
            progress: movedUp,
            visibleMinYThreshold: 0
        ), "a zero threshold disables escape detection")
    }

    // MARK: - AgentTranscriptRehydrateRestoreLayoutPolicy

    func testLiveBottomRestoreCompletesOnlyForTheCurrentLayoutPassAtTheBottom() {
        let tabID = UUID()
        let sampleKey = AgentTranscriptRehydrateRetryKey(tabID: tabID, presentationRevision: 4, layoutPassToken: 9)
        func canComplete(revision: Int = 4, token: UInt64 = 9, nearBottom: Bool = true) -> Bool {
            AgentTranscriptRehydrateRestoreLayoutPolicy.canCompleteLiveBottomRestore(
                currentLayoutSampleKey: sampleKey,
                tabID: tabID,
                presentationRevision: revision,
                layoutPassToken: token,
                isNearBottom: nearBottom
            )
        }

        XCTAssertTrue(canComplete())
        XCTAssertFalse(canComplete(nearBottom: false))
        XCTAssertFalse(canComplete(revision: 5), "a newer presentation needs its own layout sample")
        XCTAssertFalse(canComplete(token: 10), "a stale layout pass must not complete the restore")
        XCTAssertFalse(AgentTranscriptRehydrateRestoreLayoutPolicy.hasValidLayoutSample(metrics(viewportHeight: 0)))
        XCTAssertTrue(AgentTranscriptRehydrateRestoreLayoutPolicy.hasValidLayoutSample(metrics(viewportHeight: 1)))
    }

    // MARK: - AgentTranscriptPinnedBottomProtectionPolicy

    func testPinnedBottomProtectionArmsOnlyForUndisturbedPinnedSettles() {
        XCTAssertTrue(AgentTranscriptPinnedBottomProtectionPolicy.shouldArmOnBottomSettle(
            runtime: runtime(distanceToBottom: 24),
            nearBottomThreshold: 24
        ))
        XCTAssertFalse(AgentTranscriptPinnedBottomProtectionPolicy.shouldArmOnBottomSettle(
            runtime: runtime(distanceToBottom: 25),
            nearBottomThreshold: 24
        ))
        XCTAssertFalse(AgentTranscriptPinnedBottomProtectionPolicy.shouldArmOnBottomSettle(
            runtime: runtime(isUserInteractingWithScroll: true),
            nearBottomThreshold: 24
        ))
        XCTAssertFalse(AgentTranscriptPinnedBottomProtectionPolicy.shouldArmOnBottomSettle(
            runtime: runtime(isInteractionBlocked: true),
            nearBottomThreshold: 24
        ))
        XCTAssertTrue(AgentTranscriptPinnedBottomProtectionPolicy.shouldRemainActiveAfterSmoothSendCompletion(
            runtime: runtime(distanceToBottom: 400)
        ))
        XCTAssertFalse(AgentTranscriptPinnedBottomProtectionPolicy.shouldRemainActiveAfterSmoothSendCompletion(
            runtime: runtime(isPinnedToLiveBottom: false, isDetachedFromLiveBottom: true)
        ))
        XCTAssertTrue(AgentTranscriptPinnedBottomProtectionPolicy.shouldPreserveLastResolvedScrollView(
            hasExistingScrollView: true,
            hasNewlyResolvedScrollView: false
        ))
        XCTAssertFalse(AgentTranscriptPinnedBottomProtectionPolicy.shouldPreserveLastResolvedScrollView(
            hasExistingScrollView: true,
            hasNewlyResolvedScrollView: true
        ))
    }

    // MARK: - AgentTranscriptBottomScrollOutcomeLayoutPolicy

    func testBottomScrollOutcomeWaitsForLayoutToGoQuiet() {
        let base = metrics()
        XCTAssertFalse(AgentTranscriptBottomScrollOutcomeLayoutPolicy.hasMaterialLayoutMutation(
            oldMetrics: base,
            newMetrics: metrics(distanceToBottom: 300, contentHeight: 2001.9),
            contentHeightThreshold: 2,
            viewportHeightThreshold: 2
        ), "offset-only movement is not a layout mutation")
        XCTAssertTrue(AgentTranscriptBottomScrollOutcomeLayoutPolicy.hasMaterialLayoutMutation(
            oldMetrics: base,
            newMetrics: metrics(contentHeight: 2002),
            contentHeightThreshold: 2,
            viewportHeightThreshold: 2
        ))
        XCTAssertTrue(AgentTranscriptBottomScrollOutcomeLayoutPolicy.hasMaterialLayoutMutation(
            oldMetrics: base,
            newMetrics: metrics(viewportHeight: 598),
            contentHeightThreshold: 2,
            viewportHeightThreshold: 2
        ))

        let mutationAt = referenceDate
        XCTAssertNil(AgentTranscriptBottomScrollOutcomeLayoutPolicy.remainingQuietDelay(
            lastLayoutMutationAt: nil,
            now: mutationAt,
            quietPeriod: 0.12
        ))
        let remaining = AgentTranscriptBottomScrollOutcomeLayoutPolicy.remainingQuietDelay(
            lastLayoutMutationAt: mutationAt,
            now: mutationAt.addingTimeInterval(0.05),
            quietPeriod: 0.12
        )
        XCTAssertEqual(try XCTUnwrap(remaining), 0.07, accuracy: 0.0001)
        XCTAssertNil(AgentTranscriptBottomScrollOutcomeLayoutPolicy.remainingQuietDelay(
            lastLayoutMutationAt: mutationAt,
            now: mutationAt.addingTimeInterval(0.13),
            quietPeriod: 0.12
        ))
    }

    // MARK: - AgentTranscriptIdleBoundaryProgressResolver

    func testIdleBoundaryProgressUsesActiveOrFreshCompletedSessionOnly() throws {
        let baseline = metrics(distanceToBottom: 0, visibleMinY: 1400)
        let active = AgentTranscriptUserScrollSession(
            startedAt: referenceDate,
            baselineMetrics: baseline,
            latestMetrics: metrics(distanceToBottom: 80, visibleMinY: 1320),
            latestIntent: .towardHistory,
            lastIntentAt: referenceDate,
            observedProgress: true
        )
        let fromActive = try XCTUnwrap(AgentTranscriptIdleBoundaryProgressResolver.resolve(
            activeSession: active,
            lastCompletedSession: nil,
            currentMetrics: metrics(distanceToBottom: 40, visibleMinY: 1360),
            now: referenceDate,
            freshnessWindow: 1.2
        ))
        XCTAssertTrue(fromActive.hasTowardHistoryManualIntent)
        // The furthest-from-bottom observation wins so a settling bounce cannot erase intent.
        XCTAssertEqual(fromActive.progress.currentDistanceToBottom, 80)
        XCTAssertEqual(fromActive.progress.currentVisibleMinY, 1320)

        let completed = AgentTranscriptCompletedUserScrollSession(
            startedAt: referenceDate,
            endedAt: referenceDate,
            baselineMetrics: baseline,
            finalMetrics: metrics(distanceToBottom: 60, visibleMinY: 1340),
            latestIntent: .towardLiveBottom,
            observedProgress: true
        )
        let fresh = try XCTUnwrap(AgentTranscriptIdleBoundaryProgressResolver.resolve(
            activeSession: nil,
            lastCompletedSession: completed,
            currentMetrics: metrics(distanceToBottom: 10, visibleMinY: 1390),
            now: referenceDate.addingTimeInterval(1.1),
            freshnessWindow: 1.2
        ))
        XCTAssertFalse(fresh.hasTowardHistoryManualIntent)
        XCTAssertEqual(fresh.progress.currentVisibleMinY, 1340)

        XCTAssertNil(AgentTranscriptIdleBoundaryProgressResolver.resolve(
            activeSession: nil,
            lastCompletedSession: completed,
            currentMetrics: baseline,
            now: referenceDate.addingTimeInterval(1.3),
            freshnessWindow: 1.2
        ), "stale completed gestures must not detach at the idle boundary")
    }

    // MARK: - AgentTranscriptManualDetachOverridePolicy

    func testManualDetachOverrideIsActiveStrictlyBeforeItsDeadline() {
        let until = referenceDate.addingTimeInterval(0.75)
        XCTAssertTrue(AgentTranscriptManualDetachOverridePolicy.isActive(until: until, now: referenceDate))
        XCTAssertFalse(AgentTranscriptManualDetachOverridePolicy.isActive(until: until, now: until))
        XCTAssertFalse(AgentTranscriptManualDetachOverridePolicy.isActive(until: nil, now: referenceDate))
        XCTAssertTrue(AgentTranscriptManualDetachOverridePolicy.shouldSuppressActualBottomRepin(until: until, now: referenceDate))
        XCTAssertTrue(AgentTranscriptManualDetachOverridePolicy.shouldSuppressDetachedRevisionImmediateRepin(until: until, now: referenceDate))
        XCTAssertFalse(AgentTranscriptManualDetachOverridePolicy.shouldSuppressGeometryRepin(until: until, now: until.addingTimeInterval(0.01)))
    }
}

final class TranscriptScrollAnchorModelTests: XCTestCase {
    private let turnA = UUID()
    private let turnB = UUID()
    private let viewportHeight: CGFloat = 400

    /// Rows stacked top to bottom with no gaps. Each spec is (blockID, turnID, height).
    private func layout(_ specs: [(String, UUID?, CGFloat)]) -> TranscriptScrollAnchorLayout {
        var y: CGFloat = 0
        var rows: [TranscriptScrollAnchorRowFrame] = []
        for (blockID, turnID, height) in specs {
            rows.append(.init(blockID: blockID, turnID: turnID, minY: y, height: height))
            y += height
        }
        return TranscriptScrollAnchorLayout(rows: rows, contentHeight: y, viewportHeight: viewportHeight)
    }

    /// 10 rows x 200pt = 2000pt content, max clip origin 1600.
    private var baseSpecs: [(String, UUID?, CGFloat)] {
        (0 ..< 10).map { index in ("b\(index)", index < 5 ? turnA : turnB, 200) }
    }

    // MARK: - Transitions and threshold

    func testUserScrollWithinFollowThresholdFollowsAndBeyondItReadsTopVisibleRow() {
        let base = layout(baseSpecs)
        var model = TranscriptScrollAnchorModel()

        model.userDidScroll(clipOriginY: base.maxClipOriginY - 24, layout: base)
        XCTAssertEqual(model.mode, .following, "exactly at the 24pt threshold still follows")

        model.userDidScroll(clipOriginY: base.maxClipOriginY - 25, layout: base)
        // clip origin 1575 sits inside b7 (1400..<1600): its top is 175pt above the viewport.
        XCTAssertEqual(model.mode, .reading(anchorBlockID: "b7", offsetFromViewportTop: -175))

        model.userDidScroll(clipOriginY: base.maxClipOriginY, layout: base)
        XCTAssertTrue(model.isFollowing, "scrolling back to the bottom re-follows")
    }

    // MARK: - Compensation math

    func testHeightChangeAboveAnchorShiftsClipOriginByTheDelta() {
        let old = layout(baseSpecs)
        var model = TranscriptScrollAnchorModel()
        model.userDidScroll(clipOriginY: 900, layout: old) // inside b4, offset -100

        var grown = baseSpecs
        grown[1].2 = 350 // b1 (above the anchor) grows by 150
        let adjustment = model.layoutDidChange(from: old, to: layout(grown), clipOriginY: 900)

        XCTAssertEqual(adjustment, .setClipOrigin(1050))
        XCTAssertEqual(adjustment.delta(from: 900), 150)
        XCTAssertEqual(model.mode, .reading(anchorBlockID: "b4", offsetFromViewportTop: -100))
    }

    func testHeightChangeBelowAnchorLeavesReadingViewportAlone() {
        let old = layout(baseSpecs)
        var model = TranscriptScrollAnchorModel()
        model.userDidScroll(clipOriginY: 900, layout: old)

        var grown = baseSpecs
        grown[8].2 = 600
        XCTAssertEqual(model.layoutDidChange(from: old, to: layout(grown), clipOriginY: 900), .none)
    }

    func testAppendWhileReadingDoesNotMoveAndAppendWhileFollowingPinsToNewBottom() {
        let old = layout(baseSpecs)
        let appended = layout(baseSpecs + [("b10", turnB, 300)])

        var reading = TranscriptScrollAnchorModel()
        reading.userDidScroll(clipOriginY: 600, layout: old)
        XCTAssertEqual(reading.didAppend(from: old, to: appended, clipOriginY: 600), .none)
        XCTAssertFalse(reading.isFollowing)

        var following = TranscriptScrollAnchorModel()
        XCTAssertEqual(
            following.didAppend(from: old, to: appended, clipOriginY: old.maxClipOriginY),
            .setClipOrigin(appended.maxClipOriginY)
        )
        XCTAssertEqual(appended.maxClipOriginY, 1900)
    }

    func testStreamingGrowthDoesNotMoveReaderButPinsFollower() {
        var streamingSpecs = baseSpecs
        let old = layout(streamingSpecs)
        streamingSpecs[9].2 = 640 // the last (streaming) row grows by 440
        let grown = layout(streamingSpecs)

        var reader = TranscriptScrollAnchorModel()
        reader.userDidScroll(clipOriginY: 1000, layout: old)
        XCTAssertEqual(reader.streamingDidGrow(from: old, to: grown, clipOriginY: 1000), .none)

        // Anchored just above the streaming row: nothing above the anchor changed, so no move.
        var nearStreamingRow = TranscriptScrollAnchorModel()
        nearStreamingRow.userDidScroll(clipOriginY: 1500, layout: old)
        XCTAssertEqual(nearStreamingRow.mode, .reading(anchorBlockID: "b7", offsetFromViewportTop: -100))
        XCTAssertEqual(nearStreamingRow.streamingDidGrow(from: old, to: grown, clipOriginY: 1500), .none)

        var follower = TranscriptScrollAnchorModel()
        XCTAssertEqual(
            follower.streamingDidGrow(from: old, to: grown, clipOriginY: old.maxClipOriginY),
            .setClipOrigin(2040)
        )
    }

    func testWidthChangeKeepsTheSameFractionOfTheAnchorRowAtViewportTop() {
        let old = layout(baseSpecs)
        var model = TranscriptScrollAnchorModel()
        model.userDidScroll(clipOriginY: 850, layout: old) // a quarter into b4 (800..<1000)

        // Narrower viewport: every row reflows to 1.5x height.
        let narrow = layout(baseSpecs.map { ($0.0, $0.1, $0.2 * 1.5) })
        let adjustment = model.widthDidChange(from: old, to: narrow, clipOriginY: 850)

        // b4 now spans 1200..<1500; a quarter into it (75pt) keeps the same reading position.
        XCTAssertEqual(adjustment, .setClipOrigin(1275))
        XCTAssertEqual(model.mode, .reading(anchorBlockID: "b4", offsetFromViewportTop: -75))
    }

    func testFoldAndUnfoldAboveAnchorRoundTripsToTheOriginalClipOrigin() {
        let expanded = layout(baseSpecs)
        var model = TranscriptScrollAnchorModel()
        model.userDidScroll(clipOriginY: 1210, layout: expanded) // inside b6

        var foldedSpecs = baseSpecs
        foldedSpecs[2].2 = 40 // b2 folds from 200 to 40
        let folded = layout(foldedSpecs)

        let foldAdjustment = model.layoutDidChange(from: expanded, to: folded, clipOriginY: 1210)
        XCTAssertEqual(foldAdjustment, .setClipOrigin(1050))
        let unfoldAdjustment = model.layoutDidChange(from: folded, to: expanded, clipOriginY: 1050)
        XCTAssertEqual(unfoldAdjustment, .setClipOrigin(1210))
    }

    // MARK: - Anchor fallback

    func testRemovedAnchorFallsBackToNearestSurvivingRowInSameTurn() {
        var specs = baseSpecs
        specs[2].2 = 100 // b2: 400..<500, b3: 500..<700, b4: 700..<900
        let old = layout(specs)
        var model = TranscriptScrollAnchorModel()
        model.userDidScroll(clipOriginY: 650, layout: old) // inside b3 (turn A)

        // b3 disappears (e.g. merged away); turn A still has b2 (100 away) and b4 (200 away).
        let new = layout(specs.filter { $0.0 != "b3" })
        let adjustment = model.layoutDidChange(from: old, to: new, clipOriginY: 650)

        // b2 was 250pt above the viewport top and stays exactly there.
        XCTAssertEqual(model.mode, .reading(anchorBlockID: "b2", offsetFromViewportTop: -250))
        XCTAssertEqual(adjustment, .none)
    }

    func testRemovedAnchorWithNoSurvivingTurnRowsFallsBackToBottom() {
        let old = layout(baseSpecs)
        var model = TranscriptScrollAnchorModel()
        model.userDidScroll(clipOriginY: 250, layout: old) // inside b1 (turn A)

        let new = layout(baseSpecs.filter { $0.1 != turnA })
        let adjustment = model.layoutDidChange(from: old, to: new, clipOriginY: 250)

        XCTAssertTrue(model.isFollowing)
        XCTAssertEqual(adjustment, .setClipOrigin(new.maxClipOriginY))
    }

    // MARK: - Explicit jumps

    func testJumpsToTopBlockAndBottom() {
        let base = layout(baseSpecs)
        var model = TranscriptScrollAnchorModel()

        XCTAssertEqual(model.jump(to: .top, layout: base, clipOriginY: 1600), .setClipOrigin(0))
        XCTAssertEqual(model.mode, .reading(anchorBlockID: "b0", offsetFromViewportTop: 0))

        XCTAssertEqual(model.jump(to: .block("b5"), layout: base, clipOriginY: 0), .setClipOrigin(1000))
        XCTAssertEqual(model.mode, .reading(anchorBlockID: "b5", offsetFromViewportTop: 0))

        // A block whose top cannot reach the viewport top lands at the bottom and follows.
        XCTAssertEqual(model.jump(to: .block("b9"), layout: base, clipOriginY: 1000), .setClipOrigin(1600))
        XCTAssertTrue(model.isFollowing)

        XCTAssertEqual(model.jump(to: .block("missing"), layout: base, clipOriginY: 1600), .none)

        model.userDidScroll(clipOriginY: 200, layout: base)
        XCTAssertEqual(model.jump(to: .bottom, layout: base, clipOriginY: 200), .setClipOrigin(1600))
        XCTAssertTrue(model.isFollowing)
    }

    // MARK: - Persistence

    func testCodableRoundTripPreservesModeAndThreshold() throws {
        let reading = TranscriptScrollAnchorModel(
            mode: .reading(anchorBlockID: "turn-3:conclusion", offsetFromViewportTop: -42.5),
            followThreshold: 32
        )
        let following = TranscriptScrollAnchorModel()

        for model in [reading, following] {
            let data = try JSONEncoder().encode(model)
            XCTAssertEqual(try JSONDecoder().decode(TranscriptScrollAnchorModel.self, from: data), model)
        }
    }
}

#if DEBUG
    /// Stress-harness reading telemetry: position shifts while reading and frame-interval percentiles.
    final class AgentChatStressReadingTelemetryTests: XCTestCase {
        private let steadyReading = AgentChatStressReadingPositionTracker.Context(
            isDetachedReading: true,
            hasUserScrollInput: false,
            isProgrammaticScrollInFlight: false
        )

        func testShiftIsCountedOnlyForSteadyReadingMovementBeyondOnePoint() {
            var tracker = AgentChatStressReadingPositionTracker()
            tracker.refreshAnchor(
                frames: [
                    "above": CGRect(x: 0, y: -300, width: 10, height: 200), // fully above the viewport
                    "top": CGRect(x: 0, y: -40, width: 10, height: 200),
                    "next": CGRect(x: 0, y: 172, width: 10, height: 200)
                ],
                context: steadyReading
            )
            XCTAssertEqual(tracker.anchorBlockID, "top")

            XCTAssertNil(tracker.recordFrame(blockID: "next", minY: 400, context: steadyReading), "non-anchor rows are ignored")
            XCTAssertNil(tracker.recordFrame(blockID: "top", minY: -39.5, context: steadyReading), "sub-point jitter is ignored")
            XCTAssertEqual(tracker.recordFrame(blockID: "top", minY: 80, context: steadyReading), 119.5)

            var userScrolling = steadyReading
            userScrolling.hasUserScrollInput = true
            XCTAssertNil(tracker.recordFrame(blockID: "top", minY: 300, context: userScrolling), "user scrolling rebaselines")
            var following = steadyReading
            following.isDetachedReading = false
            XCTAssertNil(tracker.recordFrame(blockID: "top", minY: 10, context: following))

            XCTAssertEqual(tracker.positionShiftWhileReadingCount, 1)
            XCTAssertEqual(tracker.maxPositionShiftWhileReading, 119.5)
        }

        func testAnchorIsKeptWhileSteadyReadingAndReselectedOtherwise() {
            var tracker = AgentChatStressReadingPositionTracker()
            let frames: [String: CGRect] = [
                "a": CGRect(x: 0, y: -10, width: 10, height: 100),
                "b": CGRect(x: 0, y: 90, width: 10, height: 100)
            ]
            tracker.refreshAnchor(frames: frames, context: steadyReading)
            XCTAssertEqual(tracker.anchorBlockID, "a")

            // Content shifted so "b" is now topmost; steady reading keeps measuring "a".
            let shifted: [String: CGRect] = [
                "a": CGRect(x: 0, y: 200, width: 10, height: 100),
                "b": CGRect(x: 0, y: -50, width: 10, height: 100)
            ]
            tracker.refreshAnchor(frames: shifted, context: steadyReading)
            XCTAssertEqual(tracker.anchorBlockID, "a")

            var userScrolling = steadyReading
            userScrolling.hasUserScrollInput = true
            tracker.refreshAnchor(frames: shifted, context: userScrolling)
            XCTAssertEqual(tracker.anchorBlockID, "b")
            XCTAssertEqual(tracker.anchorMinY, -50)
        }

        func testFrameIntervalPercentilesUseNearestRankOverTheRingBuffer() throws {
            var recorder = AgentChatStressFrameIntervalRecorder(capacity: 100)
            var timestamp: CFTimeInterval = 10
            recorder.recordFrame(at: timestamp) // baseline only
            for index in 1 ... 100 {
                timestamp += Double(index) / 1000 // intervals 1ms...100ms
                recorder.recordFrame(at: timestamp)
            }
            let summary = try XCTUnwrap(recorder.summary())
            XCTAssertEqual(summary.sampleCount, 100)
            XCTAssertEqual(summary.p50MS, 50, accuracy: 0.001)
            XCTAssertEqual(summary.p95MS, 95, accuracy: 0.001)
            XCTAssertEqual(summary.p99MS, 99, accuracy: 0.001)

            // A pause in collection must not be recorded as one huge frame.
            recorder.breakSequence()
            recorder.recordFrame(at: timestamp + 30)
            XCTAssertEqual(recorder.sampleCount, 100)

            // Ring buffer: 100 further 16ms frames evict every earlier interval.
            timestamp += 30
            for _ in 0 ..< 100 {
                timestamp += 0.016
                recorder.recordFrame(at: timestamp)
            }
            let steady = try XCTUnwrap(recorder.summary())
            XCTAssertEqual(steady.sampleCount, 100)
            XCTAssertEqual(steady.p99MS, 16, accuracy: 0.01)
        }
    }
#endif

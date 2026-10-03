import Combine
import Foundation
@testable import RepoPromptApp
import XCTest

/// Table-driven precedence for the pure Agent transcript pane classifier (§4.4).
final class AgentTranscriptPanePresentationTests: XCTestCase {
    private final class SessionObject {}

    private let workspaceID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    private let tabID = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!
    private let savedSessionID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!
    private let bindingGeneration = UUID(uuidString: "00000000-0000-0000-0000-0000000000D1")!
    private let attemptID = UUID(uuidString: "00000000-0000-0000-0000-0000000000E1")!
    private let replacementAttemptID = UUID(uuidString: "00000000-0000-0000-0000-0000000000E2")!
    private let otherTabID = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!
    private let incomingWorkspaceID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!
    private let session = SessionObject()

    private var owner: AgentWorkspaceSessionIndexStore.SessionIndexOwner {
        .init(workspaceID: workspaceID, activationEpoch: 1)
    }

    private var savedScope: AgentSessionPresentationScope {
        boundScope(generation: bindingGeneration, transition: 1)
    }

    /// Same tab and saved-session UUID, new binding incarnation: a same-ID rebind.
    private var reboundSavedScope: AgentSessionPresentationScope {
        boundScope(generation: UUID(uuidString: "00000000-0000-0000-0000-0000000000D2")!, transition: 2)
    }

    private func boundScope(generation: UUID, transition: UInt64) -> AgentSessionPresentationScope {
        AgentSessionPresentationScope(
            owner: owner,
            tabID: tabID,
            sessionIdentity: ObjectIdentifier(session),
            binding: AgentPersistentSessionBindingIdentity(
                tabID: tabID,
                sessionID: savedSessionID,
                generation: generation
            ),
            bindingTransitionGeneration: transition
        )
    }

    private func attempt(_ scope: AgentSessionPresentationScope) -> AgentPersistedLoadAttempt {
        AgentPersistedLoadAttempt(scope: scope, attemptID: attemptID, sourceItemsRevision: 7)
    }

    private func savedLoadingRecord(_ scope: AgentSessionPresentationScope) -> AgentSessionPresentationRecord {
        AgentSessionPresentationRecord(scope: scope, origin: .saved, phase: .loading(attempt(scope)))
    }

    private func savedSettledRecord(
        _ scope: AgentSessionPresentationScope,
        _ exit: AgentPersistedLoadExit
    ) -> AgentSessionPresentationRecord {
        AgentSessionPresentationRecord(scope: scope, origin: .saved, phase: .settled(attempt(scope), exit))
    }

    private func resolve(
        target: AgentTranscriptPaneTarget,
        content: AgentTranscriptPaneContentFacts? = nil,
        liveRunScope: AgentSessionPresentationScope? = nil,
        isDiscoveryPending: Bool = false,
        currentAttemptID: UUID? = UUID(uuidString: "00000000-0000-0000-0000-0000000000E1")!,
        record: AgentSessionPresentationRecord? = nil
    ) -> AgentTranscriptPanePresentation? {
        AgentTranscriptPanePresentation.resolve(
            .init(
                target: target,
                content: content,
                liveRunScope: liveRunScope,
                isDiscoveryPending: isDiscoveryPending,
                currentAttemptID: currentAttemptID,
                record: record
            )
        )
    }

    private func target(scope: AgentSessionPresentationScope?) -> AgentTranscriptPaneTarget {
        AgentTranscriptPaneTarget(
            owner: .owner(owner),
            tabID: tabID,
            sessionActivationGeneration: 1,
            scope: scope
        )
    }

    func testSavedPayloadLoadingWithNoContentRestoresInsteadOfWelcome() {
        let scope = savedScope
        let presentation = resolve(
            target: target(scope: scope),
            content: AgentTranscriptPaneContentFacts(scope: scope, hasUsableContent: false),
            record: savedLoadingRecord(scope)
        )

        XCTAssertEqual(presentation, .restoring)
    }

    /// §4.4 row 1: rows from the previous incarnation of a same-ID rebind are stale.
    func testContentFromPreviousBindingIncarnationIsNotPresentedForReboundTarget() {
        let current = reboundSavedScope
        let presentation = resolve(
            target: target(scope: current),
            content: AgentTranscriptPaneContentFacts(scope: savedScope, hasUsableContent: true),
            record: savedLoadingRecord(current)
        )

        XCTAssertEqual(presentation, .restoring)
    }

    /// §4.4 row 3: a current run or pending interaction with no rows is not restoring/welcome.
    func testCurrentRunWithoutRowsPresentsRunningDuringSavedLoad() {
        let scope = savedScope
        let presentation = resolve(
            target: target(scope: scope),
            content: AgentTranscriptPaneContentFacts(scope: scope, hasUsableContent: false),
            liveRunScope: scope,
            record: savedLoadingRecord(scope)
        )

        XCTAssertEqual(presentation, .runningOrWaiting)
    }

    /// §4.4 row 4: an unmaterialized tab whose binding discovery is unresolved is not fresh.
    func testPendingDiscoveryForUnmaterializedTabRestoresInsteadOfWelcome() {
        XCTAssertEqual(resolve(target: target(scope: nil), isDiscoveryPending: true), .restoring)
    }

    /// §4.4 row 8: a saved payload that settled missing, with no content, is explicit and retryable.
    func testSavedMissingPayloadWithoutContentIsUnavailableWithRetry() {
        let scope = savedScope
        let paneTarget = target(scope: scope)
        let presentation = resolve(
            target: paneTarget,
            content: AgentTranscriptPaneContentFacts(scope: scope, hasUsableContent: false),
            record: savedSettledRecord(scope, .missingPayload)
        )

        let expectedRetry = AgentTranscriptRetryTarget(target: paneTarget, attemptID: attemptID, sourceItemsRevision: 7)
        XCTAssertEqual(presentation, .unavailable(.missing, retry: expectedRetry))
    }

    /// §4.4 row 8: a failed read is distinguished from a missing payload.
    func testSavedLoadFailureWithoutContentIsUnavailableWithDistinctReason() {
        let scope = savedScope
        let paneTarget = target(scope: scope)
        let presentation = resolve(
            target: paneTarget,
            content: AgentTranscriptPaneContentFacts(scope: scope, hasUsableContent: false),
            record: savedSettledRecord(scope, .loadFailed)
        )

        let expectedRetry = AgentTranscriptRetryTarget(target: paneTarget, attemptID: attemptID, sourceItemsRevision: 7)
        XCTAssertEqual(presentation, .unavailable(.loadFailed, retry: expectedRetry))
    }

    /// §4.3/§4.4 row 8: cancelling the current saved attempt with no successor is interrupted, not fresh.
    func testCancelledCurrentSavedAttemptWithoutSuccessorIsInterruptedWithRetry() {
        let scope = savedScope
        let paneTarget = target(scope: scope)
        let presentation = resolve(
            target: paneTarget,
            content: AgentTranscriptPaneContentFacts(scope: scope, hasUsableContent: false),
            record: savedSettledRecord(scope, .cancelled)
        )

        let expectedRetry = AgentTranscriptRetryTarget(target: paneTarget, attemptID: attemptID, sourceItemsRevision: 7)
        XCTAssertEqual(presentation, .unavailable(.interrupted, retry: expectedRetry))
    }

    /// §4.4 row 9: suppressed persistence is explicit and offers no Retry.
    func testSavedTargetWithSuppressedPersistenceIsUnavailableWithoutRetry() {
        let scope = savedScope
        let presentation = resolve(
            target: target(scope: scope),
            content: AgentTranscriptPaneContentFacts(scope: scope, hasUsableContent: false),
            record: savedSettledRecord(scope, .persistenceSuppressed)
        )

        XCTAssertEqual(presentation, .unavailable(.persistenceSuppressed, retry: nil))
    }

    /// §4.4 row 9: a still-current saved target whose workspace became unusable settles explicitly.
    func testSavedTargetWithUnavailableWorkspaceIsUnavailableWithoutRetry() {
        let scope = savedScope
        let presentation = resolve(
            target: target(scope: scope),
            record: savedSettledRecord(scope, .workspaceUnavailable)
        )

        XCTAssertEqual(presentation, .unavailable(.workspaceUnavailable, retry: nil))
    }

    /// §4.4 row 1: load evidence from the previous incarnation is rejected, never shown as a failure.
    func testPreviousIncarnationLoadOutcomeIsRejectedForReboundTarget() {
        let current = reboundSavedScope
        let presentation = resolve(
            target: target(scope: current),
            content: AgentTranscriptPaneContentFacts(scope: current, hasUsableContent: false),
            record: savedSettledRecord(savedScope, .missingPayload)
        )

        XCTAssertNil(presentation)
    }

    /// §4.2: empty rows on a bound target with no lifecycle record never authorize welcome.
    func testBoundTargetWithoutPresentationRecordIsNotInferredFresh() {
        let scope = savedScope
        let presentation = resolve(
            target: target(scope: scope),
            content: AgentTranscriptPaneContentFacts(scope: scope, hasUsableContent: false)
        )

        XCTAssertNil(presentation)
    }

    /// §4.4 row 6: an applied payload is not welcome until this scope's projection has committed.
    func testAppliedPayloadAwaitingCurrentProjectionKeepsRestoring() {
        let scope = savedScope
        let presentation = resolve(
            target: target(scope: scope),
            content: AgentTranscriptPaneContentFacts(scope: reboundSavedScope, hasUsableContent: false),
            record: savedSettledRecord(scope, .payloadApplied)
        )

        XCTAssertEqual(presentation, .restoring)
    }

    /// §4.3/§4.4 row 10: a source-superseded load reclassifies only from this scope's local projection.
    func testSourceSupersededLoadAwaitingCurrentLocalProjectionKeepsRestoring() {
        let scope = savedScope
        let presentation = resolve(
            target: target(scope: scope),
            content: AgentTranscriptPaneContentFacts(scope: reboundSavedScope, hasUsableContent: false),
            record: savedSettledRecord(scope, .sourceRevisionSuperseded)
        )

        XCTAssertEqual(presentation, .restoring)
    }

    /// §4.5: a switch target whose owner is not installed yet restores instead of showing welcome.
    func testAwaitingOwnerDuringSwitchRestoresInsteadOfWelcome() {
        let awaiting = AgentTranscriptPaneTarget(
            owner: .awaitingOwner(workspaceID: workspaceID),
            tabID: tabID,
            sessionActivationGeneration: 1,
            scope: nil
        )

        XCTAssertEqual(resolve(target: awaiting), .restoring)
    }

    /// §4.4 row 1: a target carrying an outgoing owner's scope is inconsistent; its rows are not shown.
    func testTargetScopeFromDifferentOwnerIsRejected() {
        let outgoing = savedScope
        let incomingOwner = AgentWorkspaceSessionIndexStore.SessionIndexOwner(workspaceID: workspaceID, activationEpoch: 2)
        let inconsistent = AgentTranscriptPaneTarget(
            owner: .owner(incomingOwner),
            tabID: tabID,
            sessionActivationGeneration: 1,
            scope: outgoing
        )
        let presentation = resolve(
            target: inconsistent,
            content: AgentTranscriptPaneContentFacts(scope: outgoing, hasUsableContent: true),
            record: savedLoadingRecord(outgoing)
        )

        XCTAssertNil(presentation)
    }

    /// §4.4 row 1: a target whose scope belongs to another tab (outgoing selection) is rejected.
    func testTargetScopeFromDifferentTabIsRejected() {
        let outgoingTabScope = savedScope
        let selectedTabID = otherTabID
        let inconsistent = AgentTranscriptPaneTarget(
            owner: .owner(owner),
            tabID: selectedTabID,
            sessionActivationGeneration: 2,
            scope: outgoingTabScope
        )
        let presentation = resolve(
            target: inconsistent,
            content: AgentTranscriptPaneContentFacts(scope: outgoingTabScope, hasUsableContent: true),
            record: savedLoadingRecord(outgoingTabScope)
        )

        XCTAssertNil(presentation)
    }

    /// §4.4 row 1: a failure recorded by a replaced attempt is not shown for the current attempt.
    func testFailureFromReplacedAttemptIsRejected() {
        let scope = savedScope
        let presentation = resolve(
            target: target(scope: scope),
            content: AgentTranscriptPaneContentFacts(scope: scope, hasUsableContent: false),
            currentAttemptID: replacementAttemptID,
            record: savedSettledRecord(scope, .loadFailed)
        )

        XCTAssertNil(presentation)
    }

    /// §4.4 row 1: loading evidence from a replaced attempt is discarded, not treated as current work.
    func testLoadingPhaseFromReplacedAttemptIsRejected() {
        let scope = savedScope
        let presentation = resolve(
            target: target(scope: scope),
            content: AgentTranscriptPaneContentFacts(scope: scope, hasUsableContent: false),
            currentAttemptID: replacementAttemptID,
            record: savedLoadingRecord(scope)
        )

        XCTAssertNil(presentation)
    }

    /// §4.4 row 2: archived-only history is usable content and is not hidden behind a failure.
    func testArchivedOnlyHistoryDuringFailureIsPresentedAsTranscript() {
        let scope = savedScope
        let presentation = resolve(
            target: target(scope: scope),
            content: AgentTranscriptPaneContentFacts(scope: scope, hasUsableContent: false, hasArchivedHistory: true),
            record: savedSettledRecord(scope, .loadFailed)
        )

        XCTAssertEqual(presentation, .transcript)
    }

    /// §4.4 row 6: a scheduled-but-not-started saved load restores; no content alone is not welcome.
    func testScheduledSavedLoadNotYetStartedRestores() {
        let scope = savedScope
        let presentation = resolve(
            target: target(scope: scope),
            content: AgentTranscriptPaneContentFacts(scope: scope, hasUsableContent: false),
            currentAttemptID: nil,
            record: AgentSessionPresentationRecord(scope: scope, origin: .saved, phase: .notStarted)
        )

        XCTAssertEqual(presentation, .restoring)
    }

    /// §4.3 alreadyLoaded: a saved scope settled by local state with a committed empty projection is welcome.
    func testSavedScopeSettledLocallyWithCommittedEmptyProjectionIsWelcome() {
        let scope = savedScope
        let presentation = resolve(
            target: target(scope: scope),
            content: AgentTranscriptPaneContentFacts(scope: scope, hasUsableContent: false),
            currentAttemptID: nil,
            record: AgentSessionPresentationRecord(scope: scope, origin: .saved, phase: .settledLocal)
        )

        XCTAssertEqual(presentation, .welcome)
    }

    /// §4.3 alreadyLoaded: local settlement is not welcome until this scope's projection is current.
    func testSavedScopeSettledLocallyAwaitingCurrentProjectionKeepsRestoring() {
        let scope = savedScope
        let presentation = resolve(
            target: target(scope: scope),
            content: AgentTranscriptPaneContentFacts(scope: reboundSavedScope, hasUsableContent: false),
            currentAttemptID: nil,
            record: AgentSessionPresentationRecord(scope: scope, origin: .saved, phase: .settledLocal)
        )

        XCTAssertEqual(presentation, .restoring)
    }

    /// §4.4 row 1/§4.5: while awaiting workspace B's owner, workspace A's outgoing rows are not shown.
    func testAwaitingOwnerRejectsOutgoingWorkspaceScope() {
        let outgoing = savedScope
        let awaiting = AgentTranscriptPaneTarget(
            owner: .awaitingOwner(workspaceID: incomingWorkspaceID),
            tabID: tabID,
            sessionActivationGeneration: 2,
            scope: outgoing
        )
        let presentation = resolve(
            target: awaiting,
            content: AgentTranscriptPaneContentFacts(scope: outgoing, hasUsableContent: true),
            record: savedLoadingRecord(outgoing)
        )

        XCTAssertNil(presentation)
    }

    /// §4.5: same-workspace owner replacement; the old owner's scope is not authorized before installation.
    func testAwaitingOwnerRejectsPreviousOwnerScopeOfSameWorkspace() {
        let previousOwnerScope = savedScope
        let awaiting = AgentTranscriptPaneTarget(
            owner: .awaitingOwner(workspaceID: workspaceID),
            tabID: tabID,
            sessionActivationGeneration: 2,
            scope: previousOwnerScope
        )
        let presentation = resolve(
            target: awaiting,
            content: AgentTranscriptPaneContentFacts(scope: previousOwnerScope, hasUsableContent: true),
            record: savedLoadingRecord(previousOwnerScope)
        )

        XCTAssertNil(presentation)
    }

    /// §4.4 row 1: load evidence must be the full qualified attempt for this scope, not just its UUID.
    func testAttemptQualifiedForAnotherIncarnationIsNotLoadEvidence() {
        let scope = savedScope
        let foreignAttempt = AgentPersistedLoadAttempt(
            scope: reboundSavedScope,
            attemptID: attemptID,
            sourceItemsRevision: 7
        )
        let emptyContent = AgentTranscriptPaneContentFacts(scope: scope, hasUsableContent: false)

        let loading = resolve(
            target: target(scope: scope),
            content: emptyContent,
            record: AgentSessionPresentationRecord(scope: scope, origin: .saved, phase: .loading(foreignAttempt))
        )
        let settled = resolve(
            target: target(scope: scope),
            content: emptyContent,
            record: AgentSessionPresentationRecord(
                scope: scope,
                origin: .saved,
                phase: .settled(foreignAttempt, .loadFailed)
            )
        )
        let withCurrentContent = resolve(
            target: target(scope: scope),
            content: AgentTranscriptPaneContentFacts(scope: scope, hasUsableContent: true),
            record: AgentSessionPresentationRecord(
                scope: scope,
                origin: .saved,
                phase: .settled(foreignAttempt, .loadFailed)
            )
        )

        XCTAssertNil(loading, "loading")
        XCTAssertNil(settled, "settled")
        XCTAssertEqual(withCurrentContent, .transcript, "current content wins over stale load evidence")
    }

    /// §4.1/§4.5: a settled no-workspace target cannot carry an outgoing materialized scope.
    func testNoWorkspaceTargetRejectsOutgoingScope() {
        let outgoing = savedScope
        let noWorkspace = AgentTranscriptPaneTarget(
            owner: .noWorkspace,
            tabID: tabID,
            sessionActivationGeneration: 3,
            scope: outgoing
        )
        let presentation = resolve(
            target: noWorkspace,
            content: AgentTranscriptPaneContentFacts(scope: outgoing, hasUsableContent: true),
            record: savedLoadingRecord(outgoing)
        )

        XCTAssertNil(presentation)
    }

    /// §4.5 mandated unavailable copy, independent of any error description.
    func testUnavailableReasonsUseSpecifiedCopy() {
        XCTAssertEqual(AgentTranscriptPanePresentation.UnavailableReason.missing.message, "This saved conversation could not be found.")
        XCTAssertEqual(AgentTranscriptPanePresentation.UnavailableReason.loadFailed.message, "This saved conversation could not be loaded.")
        XCTAssertEqual(AgentTranscriptPanePresentation.UnavailableReason.interrupted.message, "Conversation restoration was interrupted.")
        XCTAssertEqual(
            AgentTranscriptPanePresentation.UnavailableReason.persistenceSuppressed.message,
            "Saved conversations are unavailable while session persistence is disabled."
        )
        XCTAssertEqual(
            AgentTranscriptPanePresentation.UnavailableReason.workspaceUnavailable.message,
            "This conversation’s workspace is unavailable."
        )
    }

    /// §4.5: a settled, unowned workspace whose selected tab has an explicit saved binding is unavailable
    /// (no Retry), never an indefinite spinner and never fresh welcome.
    func testSettledUnownedSavedSelectionIsUnavailableWithoutRetry() {
        let unowned = AgentTranscriptPaneTarget(
            owner: .settledUnowned(workspaceID: workspaceID, hasSelectedSavedBinding: true),
            tabID: tabID,
            sessionActivationGeneration: 1,
            scope: nil
        )

        XCTAssertEqual(resolve(target: unowned), .unavailable(.workspaceUnavailable, retry: nil))
    }

    /// §4.5: with no existing status visible, the running/waiting pane shows Starting… or Waiting for input…
    /// from current run facts; an existing indicator or card is never duplicated.
    func testRunningOrWaitingFallbackCopy() {
        XCTAssertEqual(
            AgentTranscriptPanePresentation.runningOrWaitingFallback(
                isWaitingForInput: false, isRunIndicatorVisible: false, isInteractionCardVisible: false
            ),
            "Starting\u{2026}"
        )
        XCTAssertEqual(
            AgentTranscriptPanePresentation.runningOrWaitingFallback(
                isWaitingForInput: true, isRunIndicatorVisible: false, isInteractionCardVisible: false
            ),
            "Waiting for input\u{2026}"
        )
        XCTAssertNil(AgentTranscriptPanePresentation.runningOrWaitingFallback(
            isWaitingForInput: false, isRunIndicatorVisible: true, isInteractionCardVisible: false
        ))
        XCTAssertNil(AgentTranscriptPanePresentation.runningOrWaitingFallback(
            isWaitingForInput: true, isRunIndicatorVisible: false, isInteractionCardVisible: true
        ))
    }

    // MARK: - Preservation controls (already-correct precedence; green on first run)

    /// §4.1: a new attempt within the same binding scope does not invalidate current content.
    func testCurrentContentSurvivesAttemptReplacementWithinSameScope() {
        let scope = savedScope
        let presentation = resolve(
            target: target(scope: scope),
            content: AgentTranscriptPaneContentFacts(scope: scope, hasUsableContent: true),
            currentAttemptID: replacementAttemptID,
            record: savedSettledRecord(scope, .loadFailed)
        )

        XCTAssertEqual(presentation, .transcript)
    }

    /// §4.4 row 2: partial/unsaved rows stay visible during a load.
    func testPartialRowsDuringSavedLoadArePresentedAsTranscript() {
        let scope = savedScope
        let presentation = resolve(
            target: target(scope: scope),
            content: AgentTranscriptPaneContentFacts(scope: scope, hasUsableContent: true),
            record: savedLoadingRecord(scope)
        )

        XCTAssertEqual(presentation, .transcript)
    }

    /// §4.4 row 1: rows from a different session object on the same tab are not shown.
    func testContentFromDifferentSessionObjectIsNotPresented() {
        let otherSession = SessionObject()
        let scope = savedScope
        let otherObjectScope = AgentSessionPresentationScope(
            owner: owner,
            tabID: tabID,
            sessionIdentity: ObjectIdentifier(otherSession),
            binding: scope.binding,
            bindingTransitionGeneration: scope.bindingTransitionGeneration
        )
        let presentation = resolve(
            target: target(scope: scope),
            content: AgentTranscriptPaneContentFacts(scope: otherObjectScope, hasUsableContent: true),
            record: savedLoadingRecord(scope)
        )

        XCTAssertEqual(presentation, .restoring)
    }

    /// §4.4 row 1: rows from an earlier binding transition of the same binding are not shown.
    func testContentFromEarlierBindingTransitionIsNotPresented() {
        let scope = savedScope
        let earlierTransition = AgentSessionPresentationScope(
            owner: owner,
            tabID: tabID,
            sessionIdentity: scope.sessionIdentity,
            binding: scope.binding,
            bindingTransitionGeneration: 0
        )
        let presentation = resolve(
            target: target(scope: scope),
            content: AgentTranscriptPaneContentFacts(scope: earlierTransition, hasUsableContent: true),
            record: savedLoadingRecord(scope)
        )

        XCTAssertEqual(presentation, .restoring)
    }

    /// §4.4 row 3: a run belonging to the previous incarnation is not the current run.
    func testRunFromPreviousIncarnationIsNotPresentedAsRunning() {
        let current = reboundSavedScope
        let presentation = resolve(
            target: target(scope: current),
            content: AgentTranscriptPaneContentFacts(scope: current, hasUsableContent: false),
            liveRunScope: savedScope,
            record: savedLoadingRecord(current)
        )

        XCTAssertEqual(presentation, .restoring)
    }

    /// §4.4 row 3 over row 8: a current run without rows wins over a settled failure.
    func testCurrentRunWithoutRowsWinsOverSettledFailure() {
        let scope = savedScope
        let presentation = resolve(
            target: target(scope: scope),
            content: AgentTranscriptPaneContentFacts(scope: scope, hasUsableContent: false),
            liveRunScope: scope,
            record: savedSettledRecord(scope, .loadFailed)
        )

        XCTAssertEqual(presentation, .runningOrWaiting)
    }

    /// §4.4 row 2 over row 4: usable current rows are shown while discovery is pending.
    func testUsableContentWinsOverPendingDiscovery() {
        let scope = savedScope
        let presentation = resolve(
            target: target(scope: scope),
            content: AgentTranscriptPaneContentFacts(scope: scope, hasUsableContent: true),
            isDiscoveryPending: true,
            record: savedLoadingRecord(scope)
        )

        XCTAssertEqual(presentation, .transcript)
    }

    /// §4.4 row 5: a fresh chat that allocated a binding but is not durable yet is welcome.
    func testFreshBoundUndurableChatIsWelcome() {
        let scope = savedScope
        let presentation = resolve(
            target: target(scope: scope),
            content: AgentTranscriptPaneContentFacts(scope: scope, hasUsableContent: false),
            currentAttemptID: nil,
            record: AgentSessionPresentationRecord(scope: scope, origin: .fresh, phase: .settledLocal)
        )

        XCTAssertEqual(presentation, .welcome)
    }

    /// §4.4 row 5: a fresh chat's cold-load missing outcome is not a saved failure.
    func testFreshColdLoadMissingIsWelcome() {
        let scope = savedScope
        let presentation = resolve(
            target: target(scope: scope),
            content: AgentTranscriptPaneContentFacts(scope: scope, hasUsableContent: false),
            record: AgentSessionPresentationRecord(
                scope: scope,
                origin: .fresh,
                phase: .settled(attempt(scope), .missingPayload)
            )
        )

        XCTAssertEqual(presentation, .welcome)
    }

    /// §4.2/§4.4 row 5: completed discovery with no binding is settled-unbound, i.e. welcome.
    func testSettledUnboundTabIsWelcome() {
        let unbound = AgentSessionPresentationScope(
            owner: owner,
            tabID: tabID,
            sessionIdentity: ObjectIdentifier(session),
            binding: nil,
            bindingTransitionGeneration: 0
        )
        XCTAssertEqual(resolve(target: target(scope: unbound)), .welcome)
        XCTAssertEqual(resolve(target: target(scope: nil)), .welcome)
    }

    /// §4.3: a cancelled attempt that transferred to its successor keeps restoring for the successor.
    func testCancelledAttemptWithSuccessorKeepsRestoring() {
        let scope = savedScope
        let successor = AgentPersistedLoadAttempt(
            scope: scope,
            attemptID: replacementAttemptID,
            sourceItemsRevision: 7
        )
        let presentation = resolve(
            target: target(scope: scope),
            content: AgentTranscriptPaneContentFacts(scope: scope, hasUsableContent: false),
            currentAttemptID: successor.attemptID,
            record: AgentSessionPresentationRecord(scope: scope, origin: .saved, phase: .loading(successor))
        )

        XCTAssertEqual(presentation, .restoring)
    }

    /// §4.4 row 11: settled no-workspace and no-selection targets are ordinary welcome.
    func testSettledNoWorkspaceAndNoSelectionAreWelcome() {
        let noWorkspace = AgentTranscriptPaneTarget(
            owner: .noWorkspace,
            tabID: nil,
            sessionActivationGeneration: 3,
            scope: nil
        )
        let noSelection = AgentTranscriptPaneTarget(
            owner: .owner(owner),
            tabID: nil,
            sessionActivationGeneration: 3,
            scope: nil
        )

        XCTAssertEqual(resolve(target: noWorkspace), .welcome)
        XCTAssertEqual(resolve(target: noSelection), .welcome)
    }

    /// §4.4 row 7: an applied payload whose current empty projection committed is genuinely empty.
    func testAppliedPayloadWithCommittedEmptyProjectionIsWelcome() {
        let scope = savedScope
        let presentation = resolve(
            target: target(scope: scope),
            content: AgentTranscriptPaneContentFacts(scope: scope, hasUsableContent: false),
            record: savedSettledRecord(scope, .payloadApplied)
        )

        XCTAssertEqual(presentation, .welcome)
    }

    /// §4.3 source superseded: reclassify from current local facts (content, run, committed emptiness).
    func testSourceSupersededReclassifiesFromCurrentLocalFacts() {
        let scope = savedScope
        let superseded = savedSettledRecord(scope, .sourceRevisionSuperseded)

        let withLocalContent = resolve(
            target: target(scope: scope),
            content: AgentTranscriptPaneContentFacts(scope: scope, hasUsableContent: true),
            record: superseded
        )
        let withCurrentRun = resolve(
            target: target(scope: scope),
            content: AgentTranscriptPaneContentFacts(scope: scope, hasUsableContent: false),
            liveRunScope: scope,
            record: superseded
        )
        let withCommittedEmptiness = resolve(
            target: target(scope: scope),
            content: AgentTranscriptPaneContentFacts(scope: scope, hasUsableContent: false),
            record: superseded
        )

        XCTAssertEqual(withLocalContent, .transcript, "nonempty local content")
        XCTAssertEqual(withCurrentRun, .runningOrWaiting, "current run")
        XCTAssertEqual(withCommittedEmptiness, .welcome, "committed intentional emptiness")
    }
}

// MARK: - Shared real-restoration fixtures (used by the lifecycle and snapshot publication suites)

private actor PrepareGate {
    private var entryCount = 0
    private var isOpen = false
    private var holdLimit = Int.max
    private var entryWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    /// Held preparations in arrival order.
    private var held: [CheckedContinuation<Void, Error>] = []

    func hold() async throws {
        entryCount += 1
        let ready = entryWaiters.filter { $0.count <= entryCount }
        entryWaiters.removeAll { $0.count <= entryCount }
        ready.forEach { $0.continuation.resume() }
        guard !isOpen, entryCount <= holdLimit else { return }
        try await withCheckedThrowingContinuation { held.append($0) }
    }

    /// Later preparations pass straight through (fixture control only).
    func holdOnlyFirst() {
        holdLimit = 1
    }

    /// Releases only the earliest held preparation.
    func releaseNext() {
        guard !held.isEmpty else { return }
        held.removeFirst().resume()
    }

    /// Waits until the real preparation boundary has been reached `count` times.
    func waitUntilEntered(count: Int = 1) async {
        guard entryCount < count else { return }
        await withCheckedContinuation { entryWaiters.append((count, $0)) }
    }

    var entries: Int {
        entryCount
    }

    /// Holds the next preparation again (fixture control only).
    func rearm() {
        isOpen = false
    }

    /// Fails the currently held prepare with `error` (exercises the loader's real catch path).
    func fail(_ error: Error) {
        guard !held.isEmpty else { return }
        held.removeFirst().resume(throwing: error)
    }

    /// Opens permanently, so a cancelled or late prepare can never stay suspended.
    func open() {
        isOpen = true
        let waiting = held
        held.removeAll()
        waiting.forEach { $0.resume() }
    }
}

/// Records actual `onTabChanged` activation-task completions via the passive DEBUG hook.
private final class ActivationCompletions {
    private var completed: Set<String> = []
    private var waiters: [String: CheckedContinuation<Void, Never>] = [:]
    private var firstGenerationByTab: [UUID: Int] = [:]
    private var firstWaiters: [UUID: CheckedContinuation<Int, Never>] = [:]

    func record(tabID: UUID, generation: Int) {
        let key = "\(tabID)#\(generation)"
        completed.insert(key)
        waiters.removeValue(forKey: key)?.resume()
        if firstGenerationByTab[tabID] == nil {
            firstGenerationByTab[tabID] = generation
            firstWaiters.removeValue(forKey: tabID)?.resume(returning: generation)
        }
    }

    /// The first actual activation continuation to finish for `tabID`, whatever generation it ran under.
    @MainActor
    func waitForFirst(tabID: UUID) async -> Int {
        if let generation = firstGenerationByTab[tabID] { return generation }
        return await withCheckedContinuation { firstWaiters[tabID] = $0 }
    }

    @MainActor
    func wait(tabID: UUID, generation: Int) async {
        let key = "\(tabID)#\(generation)"
        guard !completed.contains(key) else { return }
        await withCheckedContinuation { waiters[key] = $0 }
    }
}

private struct Fixture {
    let completions: ActivationCompletions
    let viewModel: AgentModeViewModel
    let manager: WorkspaceManagerViewModel
    let tabID: UUID
    let sessionID: UUID
    let gate: PrepareGate
}

private struct RealObserverFixture {
    let viewModel: AgentModeViewModel
    let manager: WorkspaceManagerViewModel
    let prompt: PromptViewModel
    let workspace: WorkspaceModel
    let tabID: UUID
    let sessionID: UUID
    let gate: PrepareGate
    let completions: ActivationCompletions
}

@MainActor
private extension XCTestCase {
    func withSavedSelectedTab(
        bound: Bool = true,
        suppressPersistence: Bool = false,
        beforeSwitch: ((AgentModeViewModel) -> Void)? = nil,
        _ body: (Fixture) async throws -> Void
    ) async throws {
        let sandbox = try WorkspaceTestProcessSandbox.validate()
        let root = sandbox.appendingPathComponent("restoration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dataService = AgentSessionDataService.shared
        await dataService.test_setWorkspaceRootOverride(root)
        let gate = PrepareGate()
        let tabID = UUID()
        let sessionID = UUID()
        await dataService.test_setAfterHydrationPrepareHook { preparedSessionID in
            guard preparedSessionID == sessionID else { return }
            try await gate.hold()
        }
        let viewModel = AgentModeViewModel(
            testWindowID: 1112,
            testWorkspacePath: root.path,
            codexControllerFactory: { _, _, _, _, _, _ in
                LifecycleNoopCodexController(recorder: LifecycleRecorder())
            },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
            mcpServerEnabler: { true }
        )
        if suppressPersistence {
            viewModel.test_setSuppressesAgentSessionPersistence(true)
        }
        let manager = AgentSessionLinkEndpointTestSupport.installWorkspace(
            on: viewModel,
            tabID: tabID,
            name: "Restoration"
        )
        var workspace = manager.workspaces[0]
        workspace.composeTabs = [ComposeTabState(id: tabID, name: "Saved", activeAgentSessionID: bound ? sessionID : nil)]
        manager.workspaces = [workspace]
        manager.activeWorkspace = workspace
        let completions = ActivationCompletions()
        viewModel.test_afterTabActivationContinuation = { tabID, generation in
            completions.record(tabID: tabID, generation: generation)
        }
        beforeSwitch?(viewModel)
        var firstError: Error?
        do {
            await viewModel.handleWorkspaceSwitch(workspace)
            try await body(Fixture(
                completions: completions,
                viewModel: viewModel,
                manager: manager,
                tabID: tabID,
                sessionID: sessionID,
                gate: gate
            ))
        } catch {
            firstError = error
        }
        // Teardown order: real loader tasks unwind before the window closes, and shared
        // DataService state is reset only after nothing can still reach it.
        let pendingLoads = viewModel.sessions.values.compactMap(\.persistedLoadTask)
        pendingLoads.forEach { $0.cancel() }
        await gate.open()
        for task in pendingLoads {
            await task.value
        }
        await viewModel.test_waitForSessionListCacheRefresh()
        do {
            try await viewModel.test_drainWorkspaceSwitchBackgroundCleanup()
        } catch {
            firstError = firstError ?? error
        }
        await viewModel.prepareForWindowClose()
        // Reset only after every producer/index/activation path has drained.
        viewModel.test_setSuppressesAgentSessionPersistence(nil)
        viewModel.test_afterTabActivationContinuation = nil
        await dataService.test_setAfterHydrationPrepareHook(nil)
        await dataService.test_setWorkspaceRootOverride(nil)
        do {
            try FileManager.default.removeItem(at: root)
        } catch {
            firstError = firstError ?? error
        }
        if let firstError {
            throw firstError
        }
    }

    func withRealObserverSavedTab(bound: Bool = true, _ body: (RealObserverFixture) async throws -> Void) async throws {
        let sandbox = try WorkspaceTestProcessSandbox.validate()
        let root = sandbox.appendingPathComponent("restoration-observer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dataService = AgentSessionDataService.shared
        await dataService.test_setWorkspaceRootOverride(root)
        let gate = PrepareGate()
        let tabID = UUID()
        let sessionID = UUID()
        await dataService.test_setAfterHydrationPrepareHook { preparedSessionID in
            guard preparedSessionID == sessionID else { return }
            try await gate.hold()
        }
        let viewModel = AgentModeViewModel(
            testWindowID: -1,
            testWorkspacePath: root.path,
            codexControllerFactory: { _, _, _, _, _, _ in
                LifecycleNoopCodexController(recorder: LifecycleRecorder())
            },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
            mcpServerEnabler: { true }
        )
        let manager = AgentSessionLinkEndpointTestSupport.installWorkspace(on: viewModel, tabID: tabID, name: "Restored")
        let prompt = manager.promptViewModel
        var workspace = manager.workspaces[0]
        workspace.composeTabs = [ComposeTabState(id: tabID, name: "Saved", activeAgentSessionID: bound ? sessionID : nil)]
        workspace.activeComposeTabID = tabID
        manager.workspaces = [workspace]
        manager.activeWorkspace = workspace
        viewModel.test_setCurrentTabIDOverride(nil)
        viewModel.promptManager = prompt
        viewModel.test_setupObservers()
        let completions = ActivationCompletions()
        viewModel.test_afterTabActivationContinuation = { tabID, generation in
            completions.record(tabID: tabID, generation: generation)
        }
        var firstError: Error?
        do {
            try await body(RealObserverFixture(
                viewModel: viewModel,
                manager: manager,
                prompt: prompt,
                workspace: workspace,
                tabID: tabID,
                sessionID: sessionID,
                gate: gate,
                completions: completions
            ))
        } catch {
            firstError = error
        }
        let pendingLoads = viewModel.sessions.values.compactMap(\.persistedLoadTask)
        pendingLoads.forEach { $0.cancel() }
        await gate.open()
        for task in pendingLoads {
            await task.value
        }
        await viewModel.test_waitForSessionListCacheRefresh()
        do {
            try await viewModel.test_drainWorkspaceSwitchBackgroundCleanup()
        } catch {
            firstError = firstError ?? error
        }
        await viewModel.prepareForWindowClose()
        viewModel.test_afterTabActivationContinuation = nil
        viewModel.test_afterWorkspaceSwitchAdoptionQueued = nil
        viewModel.test_afterWorkspaceSwitchAdoptionCompleted = nil
        await dataService.test_setAfterHydrationPrepareHook(nil)
        await dataService.test_setWorkspaceRootOverride(nil)
        do {
            try FileManager.default.removeItem(at: root)
        } catch {
            firstError = firstError ?? error
        }
        withExtendedLifetime((manager, prompt)) {}
        if let firstError {
            throw firstError
        }
    }
}

/// Real restoration lifecycle: workspace switch → Agent Mode activation → actual persisted loader,
/// observed at `makeTranscriptUISnapshot` → `AgentTranscriptUIStore.update(_:)` (§4.2–4.6).
@MainActor
final class AgentTranscriptRestorationLifecycleTests: XCTestCase {
    // Deterministic passive gate for the real hydration-preparation boundary.

    /// A saved selected conversation whose payload is still being prepared is restoring, never welcome.
    func testSelectedSavedConversationWhilePayloadPreparesPublishesRestoring() async throws {
        try await withSavedSelectedTab { fixture in
            fixture.viewModel.setAgentModeActive(true)
            await fixture.gate.waitUntilEntered()

            XCTAssertEqual(fixture.manager.activeWorkspaceID, fixture.manager.workspaces.first?.id, "fixture workspace active")
            XCTAssertNotNil(fixture.viewModel.currentPaneOwner, "fixture owner installed")
            XCTAssertEqual(
                fixture.viewModel.sessions[fixture.tabID]?.persistentSessionBindingIdentity?.sessionID,
                fixture.sessionID,
                "fixture session bound"
            )
            XCTAssertEqual(fixture.viewModel.ui.transcript.snapshot.panePresentation, .restoring)
        }
    }

    /// A saved selected conversation whose payload is missing is explicit and retryable, never welcome.
    func testSelectedSavedConversationWithMissingPayloadIsUnavailableWithRetry() async throws {
        try await withSavedSelectedTab { fixture in
            fixture.viewModel.setAgentModeActive(true)
            await fixture.gate.waitUntilEntered()
            let loadTask = try XCTUnwrap(fixture.viewModel.sessions[fixture.tabID]?.persistedLoadTask)

            await fixture.gate.open()
            await loadTask.value

            guard case let .unavailable(.missing, retry) = fixture.viewModel.ui.transcript.snapshot.panePresentation else {
                return XCTFail("expected missing, got \(fixture.viewModel.ui.transcript.snapshot.panePresentation)")
            }
            XCTAssertEqual(retry?.target.tabID, fixture.tabID)
            XCTAssertEqual(retry?.target.scope?.binding?.sessionID, fixture.sessionID)
        }
    }

    private struct InjectedLoadFailure: Error {}

    /// A saved selected conversation whose payload fails to load is explicit, distinct and retryable.
    func testSelectedSavedConversationWhoseLoadFailsIsUnavailableWithRetry() async throws {
        try await withSavedSelectedTab { fixture in
            fixture.viewModel.setAgentModeActive(true)
            await fixture.gate.waitUntilEntered()
            let loadTask = try XCTUnwrap(fixture.viewModel.sessions[fixture.tabID]?.persistedLoadTask)

            await fixture.gate.fail(InjectedLoadFailure())
            await loadTask.value

            guard case let .unavailable(.loadFailed, retry) = fixture.viewModel.ui.transcript.snapshot.panePresentation else {
                return XCTFail("expected loadFailed, got \(fixture.viewModel.ui.transcript.snapshot.panePresentation)")
            }
            XCTAssertEqual(retry?.target.tabID, fixture.tabID)
        }
    }

    /// §4.3: cancellation is checked before a nil payload; a cancelled current attempt with no
    /// successor is interrupted, never "missing", and does not newly latch completion.
    func testCancelledCurrentSavedLoadIsInterruptedNotMissing() async throws {
        try await withSavedSelectedTab { fixture in
            fixture.viewModel.setAgentModeActive(true)
            await fixture.gate.waitUntilEntered()
            let session = try XCTUnwrap(fixture.viewModel.sessions[fixture.tabID])
            let loadTask = try XCTUnwrap(session.persistedLoadTask)

            fixture.viewModel.cancelPersistedLoad(for: session)
            await fixture.gate.open()
            await loadTask.value

            guard case .unavailable(.interrupted, _) = fixture.viewModel.ui.transcript.snapshot.panePresentation else {
                return XCTFail("expected interrupted, got \(fixture.viewModel.ui.transcript.snapshot.panePresentation)")
            }
            XCTAssertFalse(session.hasLoadedPersistedState, "cancellation must not newly latch completion")
            XCTAssertNil(session.qualifiedRestorationReadiness.terminalFailure, "no missing/failed proof")
        }
    }

    /// §4.4 row 7: a saved conversation that is genuinely empty is welcome only after its payload
    /// applied and the current projection committed.
    func testSavedEmptyConversationIsWelcomeAfterPayloadApplies() async throws {
        try await withSavedSelectedTab { fixture in
            let workspace = try XCTUnwrap(fixture.manager.activeWorkspace)
            _ = try await AgentSessionDataService.shared.saveAgentSession(
                AgentSession(id: fixture.sessionID, name: "Saved", savedAt: Date()),
                for: workspace
            )
            fixture.viewModel.setAgentModeActive(true)
            let activationGeneration = fixture.viewModel.test_sessionActivationGeneration
            await fixture.gate.waitUntilEntered()
            let loadTask = try XCTUnwrap(fixture.viewModel.sessions[fixture.tabID]?.persistedLoadTask)
            XCTAssertEqual(fixture.viewModel.ui.transcript.snapshot.panePresentation, .restoring)

            await fixture.gate.open()
            await loadTask.value
            // The scope's projection commits through the actual activation continuation.
            await fixture.completions.wait(tabID: fixture.tabID, generation: activationGeneration)

            XCTAssertTrue(fixture.viewModel.sessions[fixture.tabID]?.qualifiedRestorationReadiness.isAuthoritative == true)
            XCTAssertEqual(fixture.viewModel.ui.transcript.snapshot.panePresentation, .welcome)
        }
    }

    /// §4.3 source superseded: a local mutation during preparation keeps local items, and the pane
    /// reclassifies from the current local projection (here: usable content), not the disk result.
    func testLocalMutationDuringPreparationReclassifiesFromLocalProjection() async throws {
        try await withSavedSelectedTab { fixture in
            let workspace = try XCTUnwrap(fixture.manager.activeWorkspace)
            let persistedItemID = UUID()
            var saved = AgentSession(id: fixture.sessionID, name: "Saved", savedAt: Date())
            saved.items = [AgentChatItemPersist(
                from: AgentChatItem(id: persistedItemID, timestamp: Date(), kind: .user, text: "Persisted on disk")
            )]
            _ = try await AgentSessionDataService.shared.saveAgentSession(saved, for: workspace)
            fixture.viewModel.setAgentModeActive(true)
            await fixture.gate.waitUntilEntered()
            let session = try XCTUnwrap(fixture.viewModel.sessions[fixture.tabID])
            let loadTask = try XCTUnwrap(session.persistedLoadTask)
            let localItem = AgentChatItem(id: UUID(), timestamp: Date(), kind: .user, text: "Sent while restoring")

            session.appendItem(localItem)
            await fixture.gate.open()
            await loadTask.value

            XCTAssertEqual(
                session.qualifiedRestorationReadiness.terminalFailure,
                .sourceRevisionSuperseded,
                "a real payload whose source changed during preparation settles source-superseded"
            )
            XCTAssertEqual(session.items.map(\.id), [localItem.id], "local items kept; disk payload not applied")
            XCTAssertEqual(fixture.viewModel.ui.transcript.snapshot.panePresentation, .transcript)
        }
    }

    /// §4.3/§4.4: a cancelled current attempt first reclassifies current local facts. Usable local
    /// content is presented as transcript, without newly latching completion or recording proof.
    func testCancelledCurrentLoadWithLocalContentPresentsTranscriptWithoutLatchOrProof() async throws {
        try await withSavedSelectedTab { fixture in
            let workspace = try XCTUnwrap(fixture.manager.activeWorkspace)
            _ = try await AgentSessionDataService.shared.saveAgentSession(
                AgentSession(id: fixture.sessionID, name: "Saved", savedAt: Date()),
                for: workspace
            )
            fixture.viewModel.setAgentModeActive(true)
            let activationGeneration = fixture.viewModel.test_sessionActivationGeneration
            await fixture.gate.waitUntilEntered()
            let session = try XCTUnwrap(fixture.viewModel.sessions[fixture.tabID])
            let loadTask = try XCTUnwrap(session.persistedLoadTask)

            let localItem = AgentChatItem(id: UUID(), timestamp: Date(), kind: .user, text: "Sent while restoring")
            session.appendItem(localItem)
            fixture.viewModel.cancelPersistedLoad(for: session)
            await fixture.gate.open()
            await loadTask.value
            // Final state after the actual activation continuation, not the immediate loader frame.
            await fixture.completions.wait(tabID: fixture.tabID, generation: activationGeneration)

            XCTAssertEqual(session.items.map(\.id), [localItem.id], "local item preserved")
            XCTAssertEqual(fixture.viewModel.ui.transcript.snapshot.panePresentation, .transcript)
            XCTAssertFalse(session.hasLoadedPersistedState, "cancellation must not newly latch completion")
            XCTAssertNil(session.qualifiedRestorationReadiness.terminalFailure, "no proof from a cancelled loader")
        }
    }

    /// §4.3/§4.5 forced re-entry: re-presenting a tab whose cancelled load left newer local content must
    /// not automatically retry disk and overwrite those local items.
    func testReactivationAfterCancelledLoadWithLocalContentDoesNotOverwriteLocalItems() async throws {
        try await withSavedSelectedTab { fixture in
            let workspace = try XCTUnwrap(fixture.manager.activeWorkspace)
            var saved = AgentSession(id: fixture.sessionID, name: "Saved", savedAt: Date())
            saved.items = [AgentChatItemPersist(
                from: AgentChatItem(id: UUID(), timestamp: Date(), kind: .user, text: "Persisted on disk")
            )]
            _ = try await AgentSessionDataService.shared.saveAgentSession(saved, for: workspace)
            fixture.viewModel.setAgentModeActive(true)
            await fixture.gate.waitUntilEntered()
            let session = try XCTUnwrap(fixture.viewModel.sessions[fixture.tabID])
            let firstLoad = try XCTUnwrap(session.persistedLoadTask)
            let heldAttempt = try XCTUnwrap(fixture.viewModel.persistedLoadAttemptByTabID[fixture.tabID])
            let localItem = AgentChatItem(id: UUID(), timestamp: Date(), kind: .user, text: "Sent while restoring")
            session.appendItem(localItem)
            let attemptAfterAppend = fixture.viewModel.persistedLoadAttemptByTabID[fixture.tabID]
            fixture.viewModel.cancelPersistedLoad(for: session)
            let attemptAfterCancel = fixture.viewModel.persistedLoadAttemptByTabID[fixture.tabID]
            await fixture.gate.open()
            await firstLoad.value
            let attemptAfterUnwind = fixture.viewModel.persistedLoadAttemptByTabID[fixture.tabID]
            let entriesAfterUnwind = await fixture.gate.entries
            XCTAssertEqual(
                attemptAfterUnwind?.attemptID,
                heldAttempt.attemptID,
                "attempt identity: held=\(heldAttempt.attemptID)/rev\(heldAttempt.sourceItemsRevision) "
                    + "afterAppend=\(String(describing: attemptAfterAppend?.attemptID))/rev\(String(describing: attemptAfterAppend?.sourceItemsRevision)) "
                    + "afterCancel=\(String(describing: attemptAfterCancel?.attemptID)) "
                    + "afterUnwind=\(String(describing: attemptAfterUnwind?.attemptID))/rev\(String(describing: attemptAfterUnwind?.sourceItemsRevision)) "
                    + "liveTask=\(session.persistedLoadTask != nil) entries=\(entriesAfterUnwind)"
            )
            await fixture.gate.rearm()
            let settledPhase = fixture.viewModel.transcriptPresentationRecordsByTabID[fixture.tabID]?.phase
            if case .settled(_, .cancelled) = settledPhase {} else {
                let recordAttemptID: UUID? = if case let .loading(attempt) = settledPhase { attempt.attemptID } else { nil }
                XCTFail(
                    "precondition: cancelled load settled; recordLoadingAttempt=\(String(describing: recordAttemptID)) "
                        + "currentAttempt=\(String(describing: fixture.viewModel.persistedLoadAttemptByTabID[fixture.tabID]?.attemptID)) "
                        + "pendingLoadTask=\(session.persistedLoadTask != nil) "
                        + "pane=\(fixture.viewModel.ui.transcript.snapshot.panePresentation) "
                        + "presentedRows=\(fixture.viewModel.activeTranscriptPresentation.workingRows.map(\.id)) "
                        + "revision=\(session.sourceItemsRevision) currentTab=\(String(describing: fixture.viewModel.currentTabID == fixture.tabID)) "
                        + "owner=\(fixture.viewModel.currentPaneOwner != nil)"
                )
            }
            XCTAssertFalse(session.hasLoadedPersistedState, "precondition: no latch")

            fixture.viewModel.setAgentModeActive(false)
            fixture.viewModel.setAgentModeActive(true)
            let scheduledReload = fixture.viewModel.activeSessionLoadInProgressTabID == fixture.tabID
            if scheduledReload {
                await fixture.gate.waitUntilEntered(count: 2)
                let reload = fixture.viewModel.sessions[fixture.tabID]?.persistedLoadTask
                await fixture.gate.open()
                await reload?.value
            }

            XCTAssertFalse(scheduledReload, "no automatic disk retry after newer local content")
            XCTAssertEqual(session.items.map(\.id), [localItem.id], "local items are not overwritten")
            XCTAssertEqual(fixture.viewModel.ui.transcript.snapshot.panePresentation, .transcript)
        }
    }
}

/// §4.3 attempt-owned cleanup: an old attempt's unwind cannot clear its successor's loader task.
@MainActor
extension AgentTranscriptRestorationLifecycleTests {
    func testOldAttemptUnwindDoesNotClearSuccessorLoadTaskAfterRebind() async throws {
        try await withSavedSelectedTab { fixture in
            fixture.viewModel.setAgentModeActive(true)
            let activationGeneration = fixture.viewModel.test_sessionActivationGeneration
            await fixture.gate.waitUntilEntered()
            let session = try XCTUnwrap(fixture.viewModel.sessions[fixture.tabID])
            let oldLoad = try XCTUnwrap(session.persistedLoadTask)

            // Real rebind to a new incarnation (new scope), then admit its load through the real entry.
            fixture.viewModel.cancelPersistedLoad(for: session)
            session.testInstallPersistentSessionBinding(sessionID: fixture.sessionID)
            let successorCall = Task { await fixture.viewModel.ensureSessionReady(tabID: fixture.tabID) }
            await fixture.gate.waitUntilEntered(count: 2)
            let successorLoad = try XCTUnwrap(session.persistedLoadTask)

            await fixture.gate.releaseNext()
            await oldLoad.value
            await fixture.completions.wait(tabID: fixture.tabID, generation: activationGeneration)

            XCTAssertTrue(session.persistedLoadTask == successorLoad, "successor's loader task survives the old unwind")
            await fixture.gate.open()
            _ = await successorCall.value
        }
    }
}

/// §4.3/§4.5: no automatic successor is minted while the current attempt's producer is unwinding.
@MainActor
extension AgentTranscriptRestorationLifecycleTests {
    func testAutomaticLoadDoesNotAdmitSuccessorWhileCurrentAttemptUnwinds() async throws {
        try await withSavedSelectedTab { fixture in
            let workspace = try XCTUnwrap(fixture.manager.activeWorkspace)
            var saved = AgentSession(id: fixture.sessionID, name: "Saved", savedAt: Date())
            saved.items = [AgentChatItemPersist(
                from: AgentChatItem(id: UUID(), timestamp: Date(), kind: .user, text: "Persisted on disk")
            )]
            _ = try await AgentSessionDataService.shared.saveAgentSession(saved, for: workspace)
            await fixture.gate.holdOnlyFirst()
            fixture.viewModel.setAgentModeActive(true)
            await fixture.gate.waitUntilEntered()
            let session = try XCTUnwrap(fixture.viewModel.sessions[fixture.tabID])
            let heldAttempt = try XCTUnwrap(fixture.viewModel.persistedLoadAttemptByTabID[fixture.tabID])
            let localItem = AgentChatItem(id: UUID(), timestamp: Date(), kind: .user, text: "Sent while restoring")
            session.appendItem(localItem)
            fixture.viewModel.cancelPersistedLoad(for: session)

            // Automatic loader entry while the cancelled producer is still held at preparation.
            _ = await fixture.viewModel.ensureSessionReady(tabID: fixture.tabID)

            XCTAssertEqual(
                fixture.viewModel.persistedLoadAttemptByTabID[fixture.tabID]?.attemptID,
                heldAttempt.attemptID,
                "no successor attempt minted while the current attempt unwinds"
            )
            let entries = await fixture.gate.entries
            XCTAssertEqual(entries, 1, "no second disk preparation")
            XCTAssertEqual(session.items.map(\.id), [localItem.id], "local items are not overwritten")
        }
    }
}

/// §4.3: after a cancelled load settled with newer local content, automatic loaders never retry disk.
@MainActor
extension AgentTranscriptRestorationLifecycleTests {
    func testAutomaticLoadAfterCancelledLocalDriftSettlesDoesNotRetryDisk() async throws {
        try await withSavedSelectedTab { fixture in
            let workspace = try XCTUnwrap(fixture.manager.activeWorkspace)
            var saved = AgentSession(id: fixture.sessionID, name: "Saved", savedAt: Date())
            saved.items = [AgentChatItemPersist(
                from: AgentChatItem(id: UUID(), timestamp: Date(), kind: .user, text: "Persisted on disk")
            )]
            _ = try await AgentSessionDataService.shared.saveAgentSession(saved, for: workspace)
            await fixture.gate.holdOnlyFirst()
            fixture.viewModel.setAgentModeActive(true)
            let activationGeneration = fixture.viewModel.test_sessionActivationGeneration
            await fixture.gate.waitUntilEntered()
            let session = try XCTUnwrap(fixture.viewModel.sessions[fixture.tabID])
            let cancelledLoad = try XCTUnwrap(session.persistedLoadTask)
            let heldAttempt = try XCTUnwrap(fixture.viewModel.persistedLoadAttemptByTabID[fixture.tabID])
            let localItem = AgentChatItem(id: UUID(), timestamp: Date(), kind: .user, text: "Sent while restoring")
            session.appendItem(localItem)
            fixture.viewModel.cancelPersistedLoad(for: session)
            await fixture.gate.releaseNext()
            await cancelledLoad.value
            await fixture.completions.wait(tabID: fixture.tabID, generation: activationGeneration)

            _ = await fixture.viewModel.ensureSessionReady(tabID: fixture.tabID)

            XCTAssertEqual(
                fixture.viewModel.persistedLoadAttemptByTabID[fixture.tabID]?.attemptID,
                heldAttempt.attemptID,
                "no automatic successor after the cancelled attempt settled"
            )
            let entries = await fixture.gate.entries
            XCTAssertEqual(entries, 1, "no automatic disk retry")
            XCTAssertEqual(session.items.map(\.id), [localItem.id], "local items are not overwritten")
            XCTAssertFalse(session.hasLoadedPersistedState, "no completion latch")
        }
    }
}

/// §4.3/§5.5: a prepare that throws after revision-only source drift still settles its current attempt
/// from the local projection; it must never strand the pane or the sidebar join in loading.
@MainActor
extension AgentTranscriptRestorationLifecycleTests {
    func testThrownPrepareAfterSourceDriftSettlesFromLocalProjection() async throws {
        try await withSavedSelectedTab { fixture in
            await fixture.gate.holdOnlyFirst()
            fixture.viewModel.setAgentModeActive(true)
            let activationGeneration = fixture.viewModel.test_sessionActivationGeneration
            await fixture.gate.waitUntilEntered()
            let session = try XCTUnwrap(fixture.viewModel.sessions[fixture.tabID])
            let loadTask = try XCTUnwrap(session.persistedLoadTask)
            let localItem = AgentChatItem(id: UUID(), timestamp: Date(), kind: .user, text: "Sent while restoring")
            session.appendItem(localItem)
            await fixture.gate.fail(InjectedLoadFailure())
            await loadTask.value
            await fixture.completions.wait(tabID: fixture.tabID, generation: activationGeneration)

            XCTAssertNotEqual(fixture.viewModel.selectedRestorationSettlement(), .pending, "attempt settled, not stranded")
            XCTAssertEqual(fixture.viewModel.test_ownerValidatedSidebarRestoreJoin?.selected.isSettled ?? true, true)
            XCTAssertEqual(session.items.map(\.id), [localItem.id], "local items are not overwritten")
            XCTAssertEqual(fixture.viewModel.ui.transcript.snapshot.panePresentation, .transcript)
        }
    }
}

/// §4.3: ongoing local sends after a cancelled-drift settlement keep reaching the UI, not a one-off frame.
@MainActor
extension AgentTranscriptRestorationLifecycleTests {
    func testSubsequentLocalMutationAfterCancelledDriftReachesTranscriptUI() async throws {
        try await withSavedSelectedTab { fixture in
            let workspace = try XCTUnwrap(fixture.manager.activeWorkspace)
            _ = try await AgentSessionDataService.shared.saveAgentSession(
                AgentSession(id: fixture.sessionID, name: "Saved", savedAt: Date()),
                for: workspace
            )
            fixture.viewModel.setAgentModeActive(true)
            let activationGeneration = fixture.viewModel.test_sessionActivationGeneration
            await fixture.gate.waitUntilEntered()
            let session = try XCTUnwrap(fixture.viewModel.sessions[fixture.tabID])
            let loadTask = try XCTUnwrap(session.persistedLoadTask)
            session.appendItem(AgentChatItem(id: UUID(), timestamp: Date(), kind: .user, text: "Sent while restoring"))
            fixture.viewModel.cancelPersistedLoad(for: session)
            await fixture.gate.open()
            await loadTask.value
            await fixture.completions.wait(tabID: fixture.tabID, generation: activationGeneration)

            let laterItem = AgentChatItem(id: UUID(), timestamp: Date(), kind: .user, text: "Sent afterwards")
            session.appendItem(laterItem)

            let presentedIDs = fixture.viewModel.ui.transcript.snapshot.presentation.workingRows.map(\.id)
            XCTAssertTrue(presentedIDs.contains(laterItem.id), "later local send is presented; got \(presentedIDs)")
            XCTAssertEqual(fixture.viewModel.ui.transcript.snapshot.panePresentation, .transcript)
            XCTAssertFalse(session.hasLoadedPersistedState, "no completion latch")
        }
    }
}

/// §4.3: a cancellation thrown by preparation is not a failure and does not newly latch completion.
@MainActor
extension AgentTranscriptRestorationLifecycleTests {
    func testCancellationThrownDuringPreparationIsInterruptedWithoutLatch() async throws {
        try await withSavedSelectedTab { fixture in
            fixture.viewModel.setAgentModeActive(true)
            let activationGeneration = fixture.viewModel.test_sessionActivationGeneration
            await fixture.gate.waitUntilEntered()
            let session = try XCTUnwrap(fixture.viewModel.sessions[fixture.tabID])
            let loadTask = try XCTUnwrap(session.persistedLoadTask)

            fixture.viewModel.cancelPersistedLoad(for: session)
            await fixture.gate.fail(CancellationError())
            await loadTask.value
            await fixture.completions.wait(tabID: fixture.tabID, generation: activationGeneration)

            XCTAssertFalse(session.hasLoadedPersistedState, "cancellation must not newly latch completion")
            XCTAssertNil(session.qualifiedRestorationReadiness.terminalFailure, "no failure proof")
            guard case .unavailable(.interrupted, _) = fixture.viewModel.ui.transcript.snapshot.panePresentation else {
                return XCTFail("expected interrupted, got \(fixture.viewModel.ui.transcript.snapshot.panePresentation)")
            }
        }
    }
}

/// §4.2 provenance: a deliberately created fresh chat (bound, not yet durable) is welcome, never restoring.
@MainActor
extension AgentTranscriptRestorationLifecycleTests {
    func testFreshlyCreatedBoundChatIsWelcome() async throws {
        try await withSavedSelectedTab { fixture in
            let session = fixture.viewModel.session(for: fixture.tabID)
            XCTAssertEqual(session.persistentSessionBindingIdentity?.sessionID, fixture.sessionID, "bound, not durable")

            fixture.viewModel.markSessionAsFreshlyCreated(session)

            XCTAssertEqual(fixture.viewModel.ui.transcript.snapshot.panePresentation, .welcome)
        }
    }
}

/// §4.2 route activation: a routed rebind to another saved conversation settles its applied payload.
@MainActor
extension AgentTranscriptRestorationLifecycleTests {
    func testRouteActivationOfSavedConversationPresentsAppliedTranscript() async throws {
        try await withSavedSelectedTab { fixture in
            let workspace = try XCTUnwrap(fixture.manager.activeWorkspace)
            let routedSessionID = UUID()
            var routed = AgentSession(id: routedSessionID, name: "Routed", savedAt: Date())
            routed.items = [AgentChatItemPersist(
                from: AgentChatItem(id: UUID(), timestamp: Date(), kind: .user, text: "Routed conversation")
            )]
            _ = try await AgentSessionDataService.shared.saveAgentSession(routed, for: workspace)

            let result = await fixture.viewModel.activateRoutedAgentSession(
                tabID: fixture.tabID,
                sessionID: routedSessionID,
                workspace: workspace
            )

            XCTAssertEqual(result, .ready)
            XCTAssertEqual(fixture.viewModel.sessions[fixture.tabID]?.activeAgentSessionID, routedSessionID)
            XCTAssertEqual(fixture.viewModel.ui.transcript.snapshot.panePresentation, .transcript)
        }
    }
}

@MainActor
extension AgentTranscriptRestorationLifecycleTests {
    /// §4.2/§4.4 row 7: an empty routed saved conversation is welcome once its payload applied.
    func testRouteActivationOfEmptySavedConversationIsWelcomeAfterApply() async throws {
        try await withSavedSelectedTab { fixture in
            let workspace = try XCTUnwrap(fixture.manager.activeWorkspace)
            let routedSessionID = UUID()
            _ = try await AgentSessionDataService.shared.saveAgentSession(
                AgentSession(id: routedSessionID, name: "Routed empty", savedAt: Date()),
                for: workspace
            )

            let result = await fixture.viewModel.activateRoutedAgentSession(
                tabID: fixture.tabID,
                sessionID: routedSessionID,
                workspace: workspace
            )

            XCTAssertEqual(result, .ready)
            XCTAssertEqual(fixture.viewModel.ui.transcript.snapshot.panePresentation, .welcome)
        }
    }
}

@MainActor
extension AgentTranscriptRestorationLifecycleTests {
    /// §4.2/§4.5: the real transition of a settled saved tab to unbound publishes settled-unbound welcome;
    /// the previous scope's missing outcome is not presented for the new unbound scope.
    func testRealUnbindTransitionPublishesSettledUnboundWelcome() async throws {
        try await withSavedSelectedTab { fixture in
            fixture.viewModel.setAgentModeActive(true)
            let activationGeneration = fixture.viewModel.test_sessionActivationGeneration
            await fixture.gate.waitUntilEntered()
            let session = try XCTUnwrap(fixture.viewModel.sessions[fixture.tabID])
            let loadTask = try XCTUnwrap(session.persistedLoadTask)
            await fixture.gate.open()
            await loadTask.value
            await fixture.completions.wait(tabID: fixture.tabID, generation: activationGeneration)
            guard case .unavailable(.missing, _) = fixture.viewModel.ui.transcript.snapshot.panePresentation else {
                return XCTFail("precondition: saved outcome missing")
            }

            _ = fixture.viewModel.test_installPersistentSessionBinding(
                sessionID: nil,
                on: session,
                updateWorkspaceMetadata: true
            )

            XCTAssertNil(session.persistentSessionBindingIdentity, "session unbound")
            XCTAssertNil(fixture.manager.activeAgentSessionID(forTabID: fixture.tabID), "workspace tab unbound")
            XCTAssertTrue(fixture.viewModel.agentSessionLinkDiscoveryState.isComplete, "discovery settled")
            XCTAssertEqual(fixture.viewModel.ui.transcript.snapshot.panePresentation, .welcome)
        }
    }
}

@MainActor
extension AgentTranscriptRestorationLifecycleTests {
    /// §4.4 row 3: a current run with no rows yet is presented as running, not restoring/welcome.
    func testCurrentRunWithoutRowsDuringRestorationPresentsRunning() async throws {
        try await withSavedSelectedTab { fixture in
            fixture.viewModel.setAgentModeActive(true)
            await fixture.gate.waitUntilEntered()
            let session = try XCTUnwrap(fixture.viewModel.sessions[fixture.tabID])
            XCTAssertEqual(fixture.viewModel.ui.transcript.snapshot.panePresentation, .restoring)

            session.runState = .running

            XCTAssertEqual(fixture.viewModel.ui.transcript.snapshot.panePresentation, .runningOrWaiting)
            session.runState = .idle
        }
    }
}

@MainActor
extension AgentTranscriptRestorationLifecycleTests {
    /// §4.2/§4.4 rows 4–5: for a genuinely unbound selected tab, unresolved discovery of the current
    /// workspace is restoring; settling that discovery publishes settled-unbound welcome.
    func testUnboundSelectedTabRestoresWhileDiscoveryPendingThenWelcome() async throws {
        try await withSavedSelectedTab(bound: false) { fixture in
            let workspaceID = try XCTUnwrap(fixture.manager.activeWorkspace?.id)
            XCTAssertNil(fixture.manager.activeAgentSessionID(forTabID: fixture.tabID), "no saved binding")
            // The live runtime session (if materialized) is the target and must itself be unbound.
            let runtime = fixture.viewModel.sessions[fixture.tabID]
            XCTAssertNil(runtime?.persistentSessionBindingIdentity, "live runtime session unbound")
            XCTAssertTrue(runtime.map { fixture.viewModel.activeSession === $0 } ?? true, "live dictionary identity")
            XCTAssertTrue(runtime?.items.isEmpty ?? true, "no usable content")
            XCTAssertFalse(runtime?.runState.isActive ?? false, "no current run")
            XCTAssertEqual(fixture.viewModel.currentPaneOwner?.workspaceID, workspaceID, "current owner/workspace")
            XCTAssertTrue(fixture.viewModel.agentSessionLinkDiscoveryState.isComplete, "switch epoch settled")

            let epoch = fixture.viewModel.beginAgentSessionLinkDiscoveryEpoch(workspaceID: workspaceID)
            XCTAssertEqual(fixture.viewModel.ui.transcript.snapshot.panePresentation, .restoring)

            fixture.viewModel.completeAgentSessionLinkDiscoveryEpoch(epoch)
            XCTAssertEqual(fixture.viewModel.ui.transcript.snapshot.panePresentation, .welcome)
        }
    }
}

@MainActor
extension AgentTranscriptRestorationLifecycleTests {
    /// §4.3/§4.4 row 11: a real switch to no workspace settles ordinary welcome; an earlier saved
    /// target's restoring/unavailable state never survives into the settled no-workspace pane.
    func testRealSwitchToNoWorkspaceSettlesWelcome() async throws {
        try await withSavedSelectedTab { fixture in
            fixture.viewModel.setAgentModeActive(true)
            let activationGeneration = fixture.viewModel.test_sessionActivationGeneration
            await fixture.gate.waitUntilEntered()
            let loadTask = try XCTUnwrap(fixture.viewModel.sessions[fixture.tabID]?.persistedLoadTask)
            await fixture.gate.open()
            await loadTask.value
            await fixture.completions.wait(tabID: fixture.tabID, generation: activationGeneration)
            guard case .unavailable(.missing, _) = fixture.viewModel.ui.transcript.snapshot.panePresentation else {
                return XCTFail("precondition: saved outcome missing")
            }

            fixture.manager.activeWorkspace = nil
            fixture.viewModel.test_setCurrentTabIDOverride(nil)
            await fixture.viewModel.handleWorkspaceSwitch(nil)

            XCTAssertNil(fixture.manager.activeWorkspaceID, "no active workspace")
            XCTAssertTrue(fixture.viewModel.sessions.isEmpty, "no live sessions")
            XCTAssertEqual(fixture.viewModel.ui.transcript.snapshot.panePresentation, .welcome)
        }
    }
}

@MainActor
extension AgentTranscriptRestorationLifecycleTests {
    /// §4.3/§4.4 row 9: with session persistence suppressed, an expected saved target with no content is
    /// explicit unavailable with no Retry, never restoring or welcome.
    func testSuppressedPersistenceSavedTargetIsUnavailableWithoutRetry() async throws {
        try await withSavedSelectedTab(suppressPersistence: true) { fixture in
            fixture.viewModel.setAgentModeActive(true)
            let activationGeneration = fixture.viewModel.test_sessionActivationGeneration
            await fixture.completions.wait(tabID: fixture.tabID, generation: activationGeneration)

            let entries = await fixture.gate.entries
            XCTAssertEqual(entries, 0, "suppressed branch never prepares disk")
            XCTAssertEqual(
                fixture.viewModel.ui.transcript.snapshot.panePresentation,
                .unavailable(.persistenceSuppressed, retry: nil)
            )
        }
    }
}

@MainActor
extension AgentTranscriptRestorationLifecycleTests {
    /// §4.3 control: with persistence suppressed, a deliberately created fresh chat stays usable.
    func testSuppressedPersistenceFreshChatStaysWelcome() async throws {
        try await withSavedSelectedTab(suppressPersistence: true) { fixture in
            let session = fixture.viewModel.session(for: fixture.tabID)
            fixture.viewModel.markSessionAsFreshlyCreated(session)

            XCTAssertEqual(fixture.viewModel.ui.transcript.snapshot.panePresentation, .welcome)
        }
    }
}

@MainActor
extension AgentTranscriptRestorationLifecycleTests {
    /// §4.4 row 1/§4.5: after a real canonical rebind to another saved session, the previous
    /// incarnation's rows are not presented for the new scope, which restores until its own attempt.
    func testRebindDoesNotPresentPreviousIncarnationRows() async throws {
        try await withSavedSelectedTab { fixture in
            let workspace = try XCTUnwrap(fixture.manager.activeWorkspace)
            var saved = AgentSession(id: fixture.sessionID, name: "Saved", savedAt: Date())
            let oldItemID = UUID()
            saved.items = [AgentChatItemPersist(
                from: AgentChatItem(id: oldItemID, timestamp: Date(), kind: .user, text: "Previous incarnation")
            )]
            _ = try await AgentSessionDataService.shared.saveAgentSession(saved, for: workspace)
            fixture.viewModel.setAgentModeActive(true)
            let activationGeneration = fixture.viewModel.test_sessionActivationGeneration
            await fixture.gate.waitUntilEntered()
            let session = try XCTUnwrap(fixture.viewModel.sessions[fixture.tabID])
            let loadTask = try XCTUnwrap(session.persistedLoadTask)
            await fixture.gate.open()
            await loadTask.value
            await fixture.completions.wait(tabID: fixture.tabID, generation: activationGeneration)
            XCTAssertEqual(fixture.viewModel.ui.transcript.snapshot.panePresentation, .transcript, "precondition")

            let newSessionID = UUID()
            let installed = try XCTUnwrap(fixture.viewModel.test_installPersistentSessionBinding(
                sessionID: newSessionID,
                on: session,
                updateWorkspaceMetadata: true
            ))
            XCTAssertEqual(installed.sessionID, newSessionID, "canonical rebind installed")
            XCTAssertEqual(session.persistentSessionBindingIdentity?.sessionID, newSessionID, "runtime rebound")
            XCTAssertEqual(fixture.manager.activeAgentSessionID(forTabID: fixture.tabID), newSessionID, "selected metadata rebound")

            let presentedIDs = fixture.viewModel.ui.transcript.snapshot.presentation.workingRows.map(\.id)
            XCTAssertFalse(presentedIDs.contains(oldItemID), "previous incarnation rows not presented")
            XCTAssertEqual(fixture.viewModel.ui.transcript.snapshot.panePresentation, .restoring)
        }
    }
}

/// §4.6 explicit Retry on the same VM, observed at the UI store.
@MainActor
extension AgentTranscriptRestorationLifecycleTests {
    func testRetryOfMissingSavedConversationAdmitsReplacementAttemptAndRestores() async throws {
        try await withSavedSelectedTab { fixture in
            fixture.viewModel.setAgentModeActive(true)
            let activationGeneration = fixture.viewModel.test_sessionActivationGeneration
            await fixture.gate.waitUntilEntered()
            let session = try XCTUnwrap(fixture.viewModel.sessions[fixture.tabID])
            let firstLoad = try XCTUnwrap(session.persistedLoadTask)
            await fixture.gate.open()
            await firstLoad.value
            await fixture.completions.wait(tabID: fixture.tabID, generation: activationGeneration)
            guard case let .unavailable(.missing, retry?) = fixture.viewModel.ui.transcript.snapshot.panePresentation else {
                return XCTFail("precondition: missing with Retry")
            }
            let bindingBefore = session.persistentSessionBindingIdentity
            let revisionBefore = session.sourceItemsRevision
            session.draftText = "Unsent draft"

            let result = fixture.viewModel.retryTranscriptRestoration(retry)

            XCTAssertEqual(result, .started)
            XCTAssertEqual(fixture.viewModel.ui.transcript.snapshot.panePresentation, .restoring)
            XCTAssertNotEqual(fixture.viewModel.persistedLoadAttemptByTabID[fixture.tabID]?.attemptID, retry.attemptID)
            XCTAssertTrue(fixture.viewModel.sessions[fixture.tabID] === session, "same session object")
            XCTAssertEqual(session.persistentSessionBindingIdentity, bindingBefore, "binding unchanged")
            XCTAssertEqual(session.sourceItemsRevision, revisionBefore, "source items unchanged")
            XCTAssertEqual(session.draftText, "Unsent draft", "draft unchanged")
            // The admitted replacement reaches the real preparation boundary once; await its loader.
            await fixture.gate.waitUntilEntered(count: 2)
            await session.persistedLoadTask?.value
        }
    }
}

@MainActor
extension AgentTranscriptRestorationLifecycleTests {
    private func settleMissing(_ fixture: Fixture) async throws -> (AgentModeViewModel.TabSession, AgentTranscriptRetryTarget) {
        fixture.viewModel.setAgentModeActive(true)
        let activationGeneration = fixture.viewModel.test_sessionActivationGeneration
        await fixture.gate.waitUntilEntered()
        let session = try XCTUnwrap(fixture.viewModel.sessions[fixture.tabID])
        let firstLoad = try XCTUnwrap(session.persistedLoadTask)
        await fixture.gate.open()
        await firstLoad.value
        await fixture.completions.wait(tabID: fixture.tabID, generation: activationGeneration)
        var missingRetry: AgentTranscriptRetryTarget?
        if case let .unavailable(.missing, retry) = fixture.viewModel.ui.transcript.snapshot.panePresentation {
            missingRetry = retry
        }
        let retry = try XCTUnwrap(missingRetry, "precondition: saved outcome missing with a Retry target")
        return (session, retry)
    }

    /// §4.6 controls: repeated clicks join the admitted replacement; an obsolete target is stale.
    func testRetryDeduplicatesRepeatedClicksAndRejectsObsoleteTarget() async throws {
        try await withSavedSelectedTab { fixture in
            let (session, retry) = try await settleMissing(fixture)

            XCTAssertEqual(fixture.viewModel.retryTranscriptRestoration(retry), .started)
            let admitted = fixture.viewModel.persistedLoadAttemptByTabID[fixture.tabID]?.attemptID
            XCTAssertEqual(fixture.viewModel.retryTranscriptRestoration(retry), .alreadyLoading)
            XCTAssertEqual(fixture.viewModel.persistedLoadAttemptByTabID[fixture.tabID]?.attemptID, admitted, "one admission")
            await fixture.gate.waitUntilEntered(count: 2)
            await session.persistedLoadTask?.value

            XCTAssertEqual(fixture.viewModel.retryTranscriptRestoration(retry), .stale, "obsolete attempt target")
        }
    }

    /// §4.6 control: newer local content makes Retry unsafe; it is rejected and local items survive.
    func testRetryRejectsNewerLocalContent() async throws {
        try await withSavedSelectedTab { fixture in
            let (session, retry) = try await settleMissing(fixture)
            let localItem = AgentChatItem(id: UUID(), timestamp: Date(), kind: .user, text: "Local after missing")
            session.appendItem(localItem)

            XCTAssertEqual(fixture.viewModel.retryTranscriptRestoration(retry), .notRetryable)
            XCTAssertEqual(session.items.map(\.id), [localItem.id])
        }
    }
}

@MainActor
extension AgentTranscriptRestorationLifecycleTests {
    /// §4.6: safety is revalidated before deduplication; a newer local revision rejects a re-click even
    /// while the admitted replacement is loading.
    func testRetryReclickAfterNewerLocalRevisionIsNotRetryableWhileLoading() async throws {
        try await withSavedSelectedTab { fixture in
            let (session, retry) = try await settleMissing(fixture)
            await fixture.gate.rearm()
            XCTAssertEqual(fixture.viewModel.retryTranscriptRestoration(retry), .started)
            await fixture.gate.waitUntilEntered(count: 2)

            session.appendItem(AgentChatItem(id: UUID(), timestamp: Date(), kind: .user, text: "Local during retry"))

            XCTAssertEqual(fixture.viewModel.retryTranscriptRestoration(retry), .notRetryable)
            await fixture.gate.open()
            await session.persistedLoadTask?.value
        }
    }
}

@MainActor
extension AgentTranscriptRestorationLifecycleTests {
    /// §4.6: deduplication joins only the request the replacement was admitted for; a foreign
    /// attempt identity is stale.
    func testRetryWithForeignAttemptIdentityWhileLoadingIsStale() async throws {
        try await withSavedSelectedTab { fixture in
            let (session, retry) = try await settleMissing(fixture)
            await fixture.gate.rearm()
            XCTAssertEqual(fixture.viewModel.retryTranscriptRestoration(retry), .started)
            await fixture.gate.waitUntilEntered(count: 2)
            let foreign = AgentTranscriptRetryTarget(
                target: retry.target,
                attemptID: UUID(),
                sourceItemsRevision: retry.sourceItemsRevision
            )

            XCTAssertEqual(fixture.viewModel.retryTranscriptRestoration(foreign), .stale)
            XCTAssertEqual(fixture.viewModel.retryTranscriptRestoration(retry), .alreadyLoading, "original request joins")
            await fixture.gate.open()
            await session.persistedLoadTask?.value
        }
    }
}

@MainActor
extension AgentTranscriptRestorationLifecycleTests {
    /// §4.6: Retry revalidates the full captured target (owner kind included), not the scope alone.
    func testRetryWithMismatchedOwnerKindIsStale() async throws {
        try await withSavedSelectedTab { fixture in
            let (_, retry) = try await settleMissing(fixture)
            let wrongOwner = AgentTranscriptRetryTarget(
                target: AgentTranscriptPaneTarget(
                    owner: .noWorkspace,
                    tabID: retry.target.tabID,
                    sessionActivationGeneration: retry.target.sessionActivationGeneration,
                    scope: retry.target.scope
                ),
                attemptID: retry.attemptID,
                sourceItemsRevision: retry.sourceItemsRevision
            )

            XCTAssertEqual(fixture.viewModel.retryTranscriptRestoration(wrongOwner), .stale)
            XCTAssertEqual(fixture.viewModel.persistedLoadAttemptByTabID[fixture.tabID]?.attemptID, retry.attemptID, "nothing admitted")
        }
    }
}

@MainActor
extension AgentTranscriptRestorationLifecycleTests {
    /// §4.6: the existing loader adopts the SAME admitted replacement (no second mint), and the prior
    /// terminal proof stays fail-closed until a real outcome.
    func testRetryLoaderAdoptsAdmittedReplacementWithoutSecondMintOrProofChange() async throws {
        try await withSavedSelectedTab { fixture in
            let (session, retry) = try await settleMissing(fixture)
            await fixture.gate.rearm()
            XCTAssertEqual(fixture.viewModel.retryTranscriptRestoration(retry), .started)
            let replacementID = try XCTUnwrap(fixture.viewModel.persistedLoadAttemptByTabID[fixture.tabID]?.attemptID)

            await fixture.gate.waitUntilEntered(count: 2)
            let producer = try XCTUnwrap(session.persistedLoadTask, "actual prepared producer")
            XCTAssertEqual(fixture.viewModel.persistedLoadAttemptByTabID[fixture.tabID]?.attemptID, replacementID)
            XCTAssertEqual(session.qualifiedRestorationReadiness.terminalFailure, .missingPayload, "proof unchanged")
            await fixture.gate.open()
            await producer.value

            let settled = fixture.viewModel.transcriptPresentationRecordsByTabID[fixture.tabID]?.phase
            guard case let .settled(attempt, .missingPayload) = settled else {
                return XCTFail("expected settled missing, got \(String(describing: settled))")
            }
            XCTAssertEqual(attempt.attemptID, replacementID, "same admitted replacement settled")
            let entries = await fixture.gate.entries
            XCTAssertEqual(entries, 2, "no second mint/preparation")
        }
    }
}

@MainActor
extension AgentTranscriptRestorationLifecycleTests {
    /// §4.5: the published snapshot carries the actual current pane target it was classified against.
    func testSnapshotCarriesCurrentPaneTargetDuringRestoration() async throws {
        try await withSavedSelectedTab { fixture in
            fixture.viewModel.setAgentModeActive(true)
            await fixture.gate.waitUntilEntered()
            let session = try XCTUnwrap(fixture.viewModel.sessions[fixture.tabID])
            let expectedScope = try XCTUnwrap(fixture.viewModel.transcriptPresentationScope(for: session))

            let target = fixture.viewModel.ui.transcript.snapshot.paneTarget
            XCTAssertEqual(target.tabID, fixture.tabID)
            XCTAssertEqual(target.scope, expectedScope)
            XCTAssertEqual(target.sessionActivationGeneration, fixture.viewModel.test_sessionActivationGeneration)
            XCTAssertEqual(target.owner, try .owner(XCTUnwrap(fixture.viewModel.currentPaneOwner)))
        }
    }
}

@MainActor
extension AgentTranscriptRestorationLifecycleTests {
    /// §4.2: allocating the first persistent binding for a fresh unbound chat preserves fresh origin.
    func testFirstBindingOfFreshUnboundChatStaysWelcome() async throws {
        try await withSavedSelectedTab(bound: false) { fixture in
            let session = fixture.viewModel.session(for: fixture.tabID)
            XCTAssertNil(session.persistentSessionBindingIdentity, "precondition: unbound")
            XCTAssertEqual(fixture.viewModel.ui.transcript.snapshot.panePresentation, .welcome, "precondition")

            let allocated = try XCTUnwrap(fixture.viewModel.test_ensureSessionBoundToTab(session))

            XCTAssertEqual(session.persistentSessionBindingIdentity?.sessionID, allocated, "first binding allocated")
            XCTAssertEqual(fixture.viewModel.ui.transcript.snapshot.panePresentation, .welcome)
        }
    }
}

@MainActor
extension AgentTranscriptRestorationLifecycleTests {
    /// §4.2 atomicity control: first-binding allocation publishes no transient restoring frame.
    func testFirstBindingAllocationPublishesNoTransientRestoringFrame() async throws {
        try await withSavedSelectedTab(bound: false) { fixture in
            let session = fixture.viewModel.session(for: fixture.tabID)
            var published: [AgentTranscriptUISnapshot] = []
            let subscription = fixture.viewModel.ui.transcript.$snapshot
                .dropFirst()
                .sink { published.append($0) }

            let allocated = try XCTUnwrap(fixture.viewModel.test_ensureSessionBoundToTab(session))
            subscription.cancel()

            let last = try XCTUnwrap(published.last, "at least one publication")
            XCTAssertFalse(published.map(\.panePresentation).contains(.restoring), "published: \(published.map(\.panePresentation))")
            XCTAssertEqual(last.panePresentation, .welcome)
            XCTAssertEqual(last.paneTarget.scope?.binding?.sessionID, allocated, "final target is the allocated scope")
            XCTAssertEqual(last.paneTarget.scope, fixture.viewModel.transcriptPresentationScope(for: session), "current scope")
        }
    }
}

/// §4.5 D1 on real observers: a workspace open's forced activation followed by the prompt manager's own
/// selection publication must preserve the restoration continuation's generation and let it settle.
@MainActor
extension AgentTranscriptRestorationLifecycleTests {
    func testWorkspaceOpenSelectionPublicationPreservesRestorationContinuation() async throws {
        let sandbox = try WorkspaceTestProcessSandbox.validate()
        let root = sandbox.appendingPathComponent("restoration-d1-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dataService = AgentSessionDataService.shared
        await dataService.test_setWorkspaceRootOverride(root)
        let gate = PrepareGate()
        let tabID = UUID()
        let sessionID = UUID()
        await dataService.test_setAfterHydrationPrepareHook { preparedSessionID in
            guard preparedSessionID == sessionID else { return }
            try await gate.hold()
        }
        // windowID -1 matches the helper's PromptViewModel so the real observer's window guard applies.
        let viewModel = AgentModeViewModel(
            testWindowID: -1,
            testWorkspacePath: root.path,
            codexControllerFactory: { _, _, _, _, _, _ in
                LifecycleNoopCodexController(recorder: LifecycleRecorder())
            },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
            mcpServerEnabler: { true }
        )
        let manager = AgentSessionLinkEndpointTestSupport.installWorkspace(
            on: viewModel,
            tabID: UUID(),
            name: "Origin"
        )
        let prompt = manager.promptViewModel
        viewModel.test_setCurrentTabIDOverride(nil)
        viewModel.promptManager = prompt
        viewModel.test_setupObservers()
        let completions = ActivationCompletions()
        viewModel.test_afterTabActivationContinuation = { tabID, generation in
            completions.record(tabID: tabID, generation: generation)
        }
        let target = WorkspaceModel(
            name: "Restored",
            repoPaths: [],
            ephemeralFlag: true,
            composeTabs: [ComposeTabState(id: tabID, name: "Saved", activeAgentSessionID: sessionID)],
            activeComposeTabID: tabID
        )
        manager.workspaces.append(target)
        var firstError: Error?
        do {
            viewModel.setAgentModeActive(true)
            let generationBeforeOpen = viewModel.test_sessionActivationGeneration
            _ = await manager.switchWorkspace(to: target, saveState: false, reason: "restorationD1")
            await gate.waitUntilEntered()
            let session = try XCTUnwrap(viewModel.sessions[tabID])
            let loadTask = try XCTUnwrap(session.persistedLoadTask)
            XCTAssertEqual(prompt.activeComposeTabID, tabID, "precondition: prompt manager published the selection")
            XCTAssertEqual(viewModel.currentTabID, tabID, "precondition: real current tab, no override")

            await gate.open()
            await loadTask.value
            let completedGeneration = await completions.waitForFirst(tabID: tabID)
            let generationAfter = viewModel.test_sessionActivationGeneration

            XCTAssertEqual(
                completedGeneration,
                generationAfter,
                "restoration continuation's generation preserved (before open \(generationBeforeOpen))"
            )
            XCTAssertNil(viewModel.ui.transcript.snapshot.activeSessionLoadInProgressTabID, "load-in-progress settled")
        } catch {
            firstError = error
        }
        let pendingLoads = viewModel.sessions.values.compactMap(\.persistedLoadTask)
        pendingLoads.forEach { $0.cancel() }
        await gate.open()
        for task in pendingLoads {
            await task.value
        }
        await viewModel.test_waitForSessionListCacheRefresh()
        do {
            try await viewModel.test_drainWorkspaceSwitchBackgroundCleanup()
        } catch {
            firstError = firstError ?? error
        }
        await viewModel.prepareForWindowClose()
        viewModel.test_afterTabActivationContinuation = nil
        await dataService.test_setAfterHydrationPrepareHook(nil)
        await dataService.test_setWorkspaceRootOverride(nil)
        do {
            try FileManager.default.removeItem(at: root)
        } catch {
            firstError = firstError ?? error
        }
        withExtendedLifetime((manager, prompt)) {}
        if let firstError {
            throw firstError
        }
    }
}

/// §4.5 D1 regression on real observers: a forced workspace activation followed by the prompt manager's
/// real selection publication of the same tab must not advance the activation generation or strand the
/// restoration continuation.
@MainActor
extension AgentTranscriptRestorationLifecycleTests {
    func testForcedActivationThenRealSelectionPublicationPreservesContinuation() async throws {
        let sandbox = try WorkspaceTestProcessSandbox.validate()
        let root = sandbox.appendingPathComponent("restoration-d1-forced-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dataService = AgentSessionDataService.shared
        await dataService.test_setWorkspaceRootOverride(root)
        let gate = PrepareGate()
        let tabID = UUID()
        let sessionID = UUID()
        await dataService.test_setAfterHydrationPrepareHook { preparedSessionID in
            guard preparedSessionID == sessionID else { return }
            try await gate.hold()
        }
        let viewModel = AgentModeViewModel(
            testWindowID: -1,
            testWorkspacePath: root.path,
            codexControllerFactory: { _, _, _, _, _, _ in
                LifecycleNoopCodexController(recorder: LifecycleRecorder())
            },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
            mcpServerEnabler: { true }
        )
        let manager = AgentSessionLinkEndpointTestSupport.installWorkspace(on: viewModel, tabID: tabID, name: "Restored")
        let prompt = manager.promptViewModel
        var workspace = manager.workspaces[0]
        workspace.composeTabs = [ComposeTabState(id: tabID, name: "Saved", activeAgentSessionID: sessionID)]
        workspace.activeComposeTabID = tabID
        manager.workspaces = [workspace]
        manager.activeWorkspace = workspace
        viewModel.test_setCurrentTabIDOverride(nil)
        viewModel.promptManager = prompt
        viewModel.test_setupObservers()
        let completions = ActivationCompletions()
        viewModel.test_afterTabActivationContinuation = { tabID, generation in
            completions.record(tabID: tabID, generation: generation)
        }
        var publications: [(windowID: Int?, tabID: UUID?)] = []
        let publicationObserver = NotificationCenter.default.publisher(for: .activeComposeTabChanged)
            .sink { publications.append(($0.userInfo?["windowID"] as? Int, $0.userInfo?["tabID"] as? UUID)) }
        var firstError: Error?
        do {
            viewModel.setAgentModeActive(true)
            XCTAssertNil(prompt.activeComposeTabID, "precondition: prompt selection not yet published")
            await viewModel.handleWorkspaceSwitch(workspace)
            await gate.waitUntilEntered()
            let session = try XCTUnwrap(viewModel.sessions[tabID])
            let loadTask = try XCTUnwrap(session.persistedLoadTask)
            let generationAfterForcedEntry = viewModel.test_sessionActivationGeneration

            await prompt.switchComposeTab(tabID)
            XCTAssertTrue(
                publications.contains { $0.windowID == -1 && $0.tabID == tabID },
                "precondition: real selection publication observed; got \(publications)"
            )
            XCTAssertEqual(prompt.activeComposeTabID, tabID, "precondition: prompt selection")
            XCTAssertEqual(viewModel.currentTabID, tabID, "precondition: real current tab")

            await gate.open()
            await loadTask.value
            let completedGeneration = await completions.waitForFirst(tabID: tabID)

            XCTAssertEqual(
                viewModel.test_sessionActivationGeneration,
                generationAfterForcedEntry,
                "duplicate selection must not advance the activation generation"
            )
            XCTAssertEqual(completedGeneration, viewModel.test_sessionActivationGeneration, "continuation ran current")
            XCTAssertNil(viewModel.ui.transcript.snapshot.activeSessionLoadInProgressTabID, "load-in-progress settled")
        } catch {
            firstError = error
        }
        publicationObserver.cancel()
        let pendingLoads = viewModel.sessions.values.compactMap(\.persistedLoadTask)
        pendingLoads.forEach { $0.cancel() }
        await gate.open()
        for task in pendingLoads {
            await task.value
        }
        await viewModel.test_waitForSessionListCacheRefresh()
        do {
            try await viewModel.test_drainWorkspaceSwitchBackgroundCleanup()
        } catch {
            firstError = firstError ?? error
        }
        await viewModel.prepareForWindowClose()
        viewModel.test_afterTabActivationContinuation = nil
        await dataService.test_setAfterHydrationPrepareHook(nil)
        await dataService.test_setWorkspaceRootOverride(nil)
        do {
            try FileManager.default.removeItem(at: root)
        } catch {
            firstError = firstError ?? error
        }
        withExtendedLifetime((manager, prompt)) {}
        if let firstError {
            throw firstError
        }
    }
}

@MainActor
extension AgentTranscriptRestorationLifecycleTests {
    /// §4.5 forced re-entry (setAgentModeActive reset): re-presenting the same complete target that already
    /// has live restoration work joins it; the existing continuation is not abandoned.
    func testAgentModeReactivationJoinsLiveRestorationOfSameTarget() async throws {
        try await withSavedSelectedTab { fixture in
            fixture.viewModel.setAgentModeActive(true)
            await fixture.gate.waitUntilEntered()
            let session = try XCTUnwrap(fixture.viewModel.sessions[fixture.tabID])
            let loadTask = try XCTUnwrap(session.persistedLoadTask)
            let generationWithLiveWork = fixture.viewModel.test_sessionActivationGeneration

            fixture.viewModel.setAgentModeActive(true)

            XCTAssertEqual(
                fixture.viewModel.test_sessionActivationGeneration,
                generationWithLiveWork,
                "same complete target with live work joins; generation preserved"
            )
            await fixture.gate.open()
            await loadTask.value
            let completedGeneration = await fixture.completions.waitForFirst(tabID: fixture.tabID)
            XCTAssertEqual(completedGeneration, fixture.viewModel.test_sessionActivationGeneration, "original continuation current")
            XCTAssertNil(fixture.viewModel.ui.transcript.snapshot.activeSessionLoadInProgressTabID)
        }
    }
}

@MainActor
extension AgentTranscriptRestorationLifecycleTests {
    /// §4.5 forced re-entry (index batch resume): an index batch for the selected tab while its restoration
    /// is live joins that work; repeated batches never abandon the settling continuation.
    /// §4.5 join window: an index batch queued ahead of the activation continuation's first turn resumes
    /// before that continuation has installed its load. It must join the current activation, never mint a
    /// successor generation that abandons it (the intermittent ordering behind the test below).
    func testIndexResumeBeforeContinuationFirstTurnJoinsCurrentActivation() async throws {
        try await withSavedSelectedTab { fixture in
            let viewModel = fixture.viewModel
            viewModel.setAgentModeActive(true)
            let activationGeneration = viewModel.test_sessionActivationGeneration
            let session = try XCTUnwrap(viewModel.sessions[fixture.tabID])
            XCTAssertNil(session.persistedLoadTask, "precondition: continuation has not taken its first turn")

            XCTAssertTrue(viewModel.test_resumePendingActiveSessionLoadIfNeeded(updatedTabIDs: [fixture.tabID]))
            XCTAssertEqual(viewModel.test_sessionActivationGeneration, activationGeneration, "resume joined")

            await fixture.gate.waitUntilEntered()
            let loadTask = try XCTUnwrap(session.persistedLoadTask)
            await fixture.gate.open()
            await loadTask.value
            let completedGeneration = await fixture.completions.waitForFirst(tabID: fixture.tabID)
            XCTAssertEqual(completedGeneration, activationGeneration, "the joined continuation completed")
            let entries = await fixture.gate.entries
            XCTAssertEqual(entries, 1, "one load for the joined activation")
        }
    }

    func testIndexBatchResumeJoinsLiveRestorationOfSameTarget() async throws {
        try await withSavedSelectedTab { fixture in
            let workspace = try XCTUnwrap(fixture.manager.activeWorkspace)
            var saved = AgentSession(id: fixture.sessionID, name: "Saved", savedAt: Date())
            saved.composeTabID = fixture.tabID
            saved.workspaceID = workspace.id
            _ = try await AgentSessionDataService.shared.saveAgentSession(saved, for: workspace)
            fixture.viewModel.setAgentModeActive(true)
            await fixture.gate.waitUntilEntered()
            let session = try XCTUnwrap(fixture.viewModel.sessions[fixture.tabID])
            let loadTask = try XCTUnwrap(session.persistedLoadTask)
            let generationWithLiveWork = fixture.viewModel.test_sessionActivationGeneration

            await fixture.viewModel.test_waitForSessionListCacheRefresh()

            XCTAssertNotNil(fixture.viewModel.test_ownerValidatedSessionIndex[fixture.sessionID], "precondition: index batch applied")
            XCTAssertEqual(fixture.viewModel.test_sessionActivationGeneration, generationWithLiveWork, "resume joined")
            // Capture the current generation synchronously at the original continuation's actual completion,
            // forwarding to the fixture's recorder unchanged.
            var currentGenerationAtCompletion: Int?
            let forward = fixture.viewModel.test_afterTabActivationContinuation
            fixture.viewModel.test_afterTabActivationContinuation = { tabID, generation in
                if tabID == fixture.tabID, currentGenerationAtCompletion == nil {
                    currentGenerationAtCompletion = fixture.viewModel.test_sessionActivationGeneration
                }
                forward?(tabID, generation)
            }
            await fixture.gate.open()
            await loadTask.value
            let completedGeneration = await fixture.completions.waitForFirst(tabID: fixture.tabID)
            XCTAssertEqual(completedGeneration, generationWithLiveWork, "restoration continuation ran joined")
            XCTAssertEqual(
                currentGenerationAtCompletion,
                generationWithLiveWork,
                "joined continuation was still current when it completed"
            )
            XCTAssertNil(fixture.viewModel.ui.transcript.snapshot.activeSessionLoadInProgressTabID)
        }
    }
}

/// Real-observer fixture: headless VM with the real prompt manager attached and the real production
/// observers installed (`test_setupObservers`), windowID -1 matching the helper's prompt manager, no
/// current-tab override. Sandbox first; bounded teardown before shared state resets.
@MainActor
extension AgentTranscriptRestorationLifecycleTests {
    /// §4.5: the same complete IDs with no live attempt or continuation start a real activation that
    /// reapplies current bindings; the selection publication is never ignored by tab ID alone.
    func testSameTabSelectionWithoutLiveWorkReappliesCurrentBindings() async throws {
        try await withRealObserverSavedTab { fixture in
            var saved = AgentSession(id: fixture.sessionID, name: "Saved", savedAt: Date())
            saved.items = [AgentChatItemPersist(
                from: AgentChatItem(id: UUID(), timestamp: Date(), kind: .user, text: "Saved content")
            )]
            _ = try await AgentSessionDataService.shared.saveAgentSession(saved, for: fixture.workspace)
            fixture.viewModel.setAgentModeActive(true)
            XCTAssertNil(fixture.prompt.activeComposeTabID, "precondition: selection not yet published")
            await fixture.viewModel.handleWorkspaceSwitch(fixture.workspace)
            await fixture.gate.waitUntilEntered()
            let session = try XCTUnwrap(fixture.viewModel.sessions[fixture.tabID])
            let loadTask = try XCTUnwrap(session.persistedLoadTask)
            await fixture.gate.open()
            await loadTask.value
            _ = await fixture.completions.waitForFirst(tabID: fixture.tabID)
            XCTAssertTrue(session.hasLoadedPersistedState, "precondition: payload applied, no live work")
            let generationBeforePublication = fixture.viewModel.test_sessionActivationGeneration

            await fixture.prompt.switchComposeTab(fixture.tabID)

            XCTAssertEqual(fixture.viewModel.currentTabID, fixture.tabID, "precondition: real publication")
            XCTAssertGreaterThan(fixture.viewModel.test_sessionActivationGeneration, generationBeforePublication)
            XCTAssertEqual(fixture.viewModel.ui.transcript.snapshot.panePresentation, .transcript)
        }
    }
}

@MainActor
extension AgentTranscriptRestorationLifecycleTests {
    /// §4.3/§4.5: a forced re-entry still activates, but never implicitly reloads a fully current saved
    /// cancelled (no-content) outcome; it stays interrupted with an explicit Retry.
    func testForcedReactivationDoesNotAutoRetryCurrentCancelledOutcome() async throws {
        try await withSavedSelectedTab { fixture in
            fixture.viewModel.setAgentModeActive(true)
            let firstGeneration = fixture.viewModel.test_sessionActivationGeneration
            await fixture.gate.waitUntilEntered()
            let session = try XCTUnwrap(fixture.viewModel.sessions[fixture.tabID])
            let loadTask = try XCTUnwrap(session.persistedLoadTask)
            fixture.viewModel.cancelPersistedLoad(for: session)
            await fixture.gate.open()
            await loadTask.value
            await fixture.completions.wait(tabID: fixture.tabID, generation: firstGeneration)
            XCTAssertFalse(session.hasLoadedPersistedState, "precondition: cancellation did not latch")
            guard case .unavailable(.interrupted, _) = fixture.viewModel.ui.transcript.snapshot.panePresentation else {
                return XCTFail("precondition: interrupted")
            }
            await fixture.gate.rearm()
            await fixture.gate.holdOnlyFirst()

            fixture.viewModel.setAgentModeActive(false)
            fixture.viewModel.setAgentModeActive(true)
            let reactivationGeneration = fixture.viewModel.test_sessionActivationGeneration
            XCTAssertGreaterThan(reactivationGeneration, firstGeneration, "real activation")
            await fixture.completions.wait(tabID: fixture.tabID, generation: reactivationGeneration)

            let entries = await fixture.gate.entries
            XCTAssertEqual(entries, 1, "no implicit disk reload")
            guard case .unavailable(.interrupted, _?) = fixture.viewModel.ui.transcript.snapshot.panePresentation else {
                return XCTFail("expected interrupted with Retry, got \(fixture.viewModel.ui.transcript.snapshot.panePresentation)")
            }
        }
    }
}

@MainActor
extension AgentTranscriptRestorationLifecycleTests {
    /// §4.3 control: an obsolete cancelled scope never blocks a genuinely changed incarnation's load.
    func testCancelledOutcomeDoesNotBlockLoadOfChangedIncarnation() async throws {
        try await withSavedSelectedTab { fixture in
            fixture.viewModel.setAgentModeActive(true)
            let firstGeneration = fixture.viewModel.test_sessionActivationGeneration
            await fixture.gate.waitUntilEntered()
            let session = try XCTUnwrap(fixture.viewModel.sessions[fixture.tabID])
            let loadTask = try XCTUnwrap(session.persistedLoadTask)
            fixture.viewModel.cancelPersistedLoad(for: session)
            await fixture.gate.open()
            await loadTask.value
            await fixture.completions.wait(tabID: fixture.tabID, generation: firstGeneration)

            let reboundSessionID = UUID()
            let installed = try XCTUnwrap(fixture.viewModel.test_installPersistentSessionBinding(
                sessionID: reboundSessionID,
                on: session,
                updateWorkspaceMetadata: true
            ))
            XCTAssertEqual(installed.sessionID, reboundSessionID, "precondition: changed incarnation")
            _ = await fixture.viewModel.ensureSessionReady(tabID: fixture.tabID)

            let entries = await fixture.gate.entries
            XCTAssertEqual(entries, 1, "only the cancelled attempt reached the gate")
            XCTAssertNotEqual(fixture.viewModel.persistedLoadAttemptByTabID[fixture.tabID]?.scope.binding?.sessionID, fixture.sessionID)
            XCTAssertEqual(fixture.viewModel.persistedLoadAttemptByTabID[fixture.tabID]?.scope.binding?.sessionID, reboundSessionID, "changed incarnation admitted its own load")
        }
    }
}

@MainActor
extension AgentTranscriptRestorationLifecycleTests {
    /// §4.6 control: explicit Retry of a current cancelled (no-content) target still admits its replacement
    /// through the real loader, which settles that same attempt with its real outcome.
    func testExplicitRetryOfCancelledOutcomeAdmitsReplacementThroughLoader() async throws {
        try await withSavedSelectedTab { fixture in
            fixture.viewModel.setAgentModeActive(true)
            let firstGeneration = fixture.viewModel.test_sessionActivationGeneration
            await fixture.gate.waitUntilEntered()
            let session = try XCTUnwrap(fixture.viewModel.sessions[fixture.tabID])
            let loadTask = try XCTUnwrap(session.persistedLoadTask)
            fixture.viewModel.cancelPersistedLoad(for: session)
            await fixture.gate.open()
            await loadTask.value
            await fixture.completions.wait(tabID: fixture.tabID, generation: firstGeneration)
            var interruptedRetry: AgentTranscriptRetryTarget?
            if case let .unavailable(.interrupted, retry) = fixture.viewModel.ui.transcript.snapshot.panePresentation {
                interruptedRetry = retry
            }
            let retry = try XCTUnwrap(interruptedRetry, "precondition: interrupted with Retry")
            XCTAssertNil(session.qualifiedRestorationReadiness.terminalFailure, "precondition: no proof from cancellation")

            XCTAssertEqual(fixture.viewModel.retryTranscriptRestoration(retry), .started)
            let replacementID = try XCTUnwrap(fixture.viewModel.persistedLoadAttemptByTabID[fixture.tabID]?.attemptID)
            XCTAssertNotEqual(replacementID, retry.attemptID)
            await fixture.gate.waitUntilEntered(count: 2)
            await session.persistedLoadTask?.value

            let settled = fixture.viewModel.transcriptPresentationRecordsByTabID[fixture.tabID]?.phase
            guard case let .settled(attempt, .missingPayload) = settled else {
                return XCTFail("expected settled missing, got \(String(describing: settled))")
            }
            XCTAssertEqual(attempt.attemptID, replacementID, "same admitted replacement settled")
            XCTAssertEqual(session.qualifiedRestorationReadiness.terminalFailure, .missingPayload, "real outcome proof only")
        }
    }
}

@MainActor
extension AgentTranscriptRestorationLifecycleTests {
    /// §4.5 early invalidation: at the switch's active-ID publication the pane already targets the incoming
    /// workspace as awaiting its owner (restoring), without minting an owner or starting a load.
    func testActiveWorkspaceIDPublicationInvalidatesOutgoingPaneBeforeOwnerInstall() async throws {
        try await withRealObserverSavedTab { fixture in
            var saved = AgentSession(id: fixture.sessionID, name: "Saved", savedAt: Date())
            saved.items = [AgentChatItemPersist(
                from: AgentChatItem(id: UUID(), timestamp: Date(), kind: .user, text: "Outgoing content")
            )]
            _ = try await AgentSessionDataService.shared.saveAgentSession(saved, for: fixture.workspace)
            fixture.viewModel.setAgentModeActive(true)
            await fixture.viewModel.handleWorkspaceSwitch(fixture.workspace)
            await fixture.gate.waitUntilEntered()
            let loadTask = try XCTUnwrap(fixture.viewModel.sessions[fixture.tabID]?.persistedLoadTask)
            await fixture.gate.open()
            await loadTask.value
            await fixture.prompt.switchComposeTab(fixture.tabID)
            XCTAssertEqual(fixture.viewModel.ui.transcript.snapshot.panePresentation, .transcript, "precondition: outgoing")

            let incomingTabID = UUID()
            let incoming = WorkspaceModel(
                name: "Incoming",
                repoPaths: [],
                ephemeralFlag: true,
                composeTabs: [ComposeTabState(id: incomingTabID, name: "Incoming", activeAgentSessionID: UUID())],
                activeComposeTabID: incomingTabID
            )
            fixture.manager.workspaces.append(incoming)
            let switchGate = PrepareGate()
            fixture.manager.setWorkspaceRootHydrationWillSpawnHandlerForTesting { workspaceID in
                guard workspaceID == incoming.id else { return }
                try? await switchGate.hold()
            }
            let switchTask = Task { await fixture.manager.switchWorkspace(to: incoming, saveState: false, reason: "earlyOwner") }
            await switchGate.waitUntilEntered()

            XCTAssertEqual(fixture.manager.activeWorkspaceID, incoming.id, "precondition: active ID published")
            XCTAssertNotEqual(fixture.viewModel.sessionIndexOwner?.workspaceID, incoming.id, "no owner installed yet")
            XCTAssertNil(fixture.viewModel.sessions[incomingTabID], "observer created no session/load")
            XCTAssertEqual(fixture.viewModel.ui.transcript.snapshot.paneTarget.owner, .awaitingOwner(workspaceID: incoming.id))
            XCTAssertEqual(fixture.viewModel.ui.transcript.snapshot.panePresentation, .restoring)

            await switchGate.open()
            _ = await switchTask.value
            fixture.manager.setWorkspaceRootHydrationWillSpawnHandlerForTesting(nil)
        }
    }
}

@MainActor
extension AgentTranscriptRestorationLifecycleTests {
    /// §3/§4.5: an authority-only active-ID change (no switch, no queued adoption) settles; a selected
    /// saved binding with no owning runtime is unavailable, never an indefinite restoring spinner.
    func testAuthorityOnlyActiveIDChangeSettlesSavedSelectionUnowned() async throws {
        try await withRealObserverSavedTab { fixture in
            var saved = AgentSession(id: fixture.sessionID, name: "Saved", savedAt: Date())
            saved.items = [AgentChatItemPersist(
                from: AgentChatItem(id: UUID(), timestamp: Date(), kind: .user, text: "Outgoing content")
            )]
            _ = try await AgentSessionDataService.shared.saveAgentSession(saved, for: fixture.workspace)
            fixture.viewModel.setAgentModeActive(true)
            await fixture.viewModel.handleWorkspaceSwitch(fixture.workspace)
            await fixture.gate.waitUntilEntered()
            let loadTask = try XCTUnwrap(fixture.viewModel.sessions[fixture.tabID]?.persistedLoadTask)
            await fixture.gate.open()
            await loadTask.value
            await fixture.prompt.switchComposeTab(fixture.tabID)
            XCTAssertEqual(fixture.viewModel.ui.transcript.snapshot.panePresentation, .transcript, "precondition: outgoing")

            let unownedTabID = UUID()
            let unowned = WorkspaceModel(
                name: "Unowned",
                repoPaths: [],
                ephemeralFlag: true,
                composeTabs: [ComposeTabState(id: unownedTabID, name: "Saved elsewhere", activeAgentSessionID: UUID())],
                activeComposeTabID: unownedTabID
            )
            fixture.manager.workspaces.append(unowned)

            fixture.manager.activeWorkspace = unowned

            XCTAssertEqual(fixture.manager.activeWorkspaceID, unowned.id, "precondition: authority-only ID change")
            XCTAssertFalse(fixture.manager.isSwitchingWorkspace, "precondition: no switch")
            XCTAssertNotEqual(fixture.viewModel.sessionIndexOwner?.workspaceID, unowned.id, "no owner minted")
            XCTAssertNil(fixture.viewModel.sessions[unownedTabID], "no session/load created")
            XCTAssertEqual(
                fixture.viewModel.ui.transcript.snapshot.paneTarget.owner,
                .settledUnowned(workspaceID: unowned.id, hasSelectedSavedBinding: true)
            )
            XCTAssertEqual(fixture.viewModel.ui.transcript.snapshot.panePresentation, .unavailable(.workspaceUnavailable, retry: nil))
        }
    }
}

@MainActor
extension AgentTranscriptRestorationLifecycleTests {
    /// §3/§4.5 queued adoption: between the real listener queuing owner adoption and its installation,
    /// the incoming workspace has a pending adoption (pane awaiting); after installation it is current.
    func testRealSwitchQueuedOwnerAdoptionIsPendingUntilInstalled() async throws {
        try await withRealObserverSavedTab { fixture in
            // The queued window does not need the outgoing hydration held; let it settle unhindered.
            await fixture.gate.open()
            fixture.viewModel.setAgentModeActive(true)
            await fixture.viewModel.handleWorkspaceSwitch(fixture.workspace)
            if let outgoingLoad = fixture.viewModel.sessions[fixture.tabID]?.persistedLoadTask {
                await outgoingLoad.value
            }
            let incomingTabID = UUID()
            let incoming = WorkspaceModel(
                name: "Incoming",
                repoPaths: [],
                ephemeralFlag: true,
                composeTabs: [ComposeTabState(id: incomingTabID, name: "Incoming")],
                activeComposeTabID: incomingTabID
            )
            fixture.manager.workspaces.append(incoming)
            var queuedOwner: AgentWorkspaceSessionIndexStore.SessionIndexOwner?
            var pendingWhenQueued = false
            var targetOwnerWhenQueued: AgentTranscriptPaneTarget.Owner?
            fixture.viewModel.test_afterWorkspaceSwitchAdoptionQueued = { owner in
                queuedOwner = owner
                pendingWhenQueued = fixture.viewModel.hasPendingOwnerAdoption(forWorkspaceID: incoming.id)
                targetOwnerWhenQueued = fixture.viewModel.ui.transcript.snapshot.paneTarget.owner
            }

            _ = await fixture.manager.switchWorkspace(to: incoming, saveState: false, reason: "queuedAdoption")
            fixture.viewModel.test_afterWorkspaceSwitchAdoptionQueued = nil
            await fixture.viewModel.test_waitForSessionListCacheRefresh()

            let owner = try XCTUnwrap(queuedOwner, "precondition: real listener queued adoption")
            XCTAssertEqual(owner.workspaceID, incoming.id)
            XCTAssertTrue(pendingWhenQueued, "pending adoption observed in the queued window")
            XCTAssertEqual(targetOwnerWhenQueued, .awaitingOwner(workspaceID: incoming.id))
            XCTAssertEqual(fixture.viewModel.currentPaneOwner, owner, "installed after the queued task ran")
            XCTAssertFalse(fixture.viewModel.hasPendingOwnerAdoption(forWorkspaceID: incoming.id), "no longer pending")
        }
    }
}

@MainActor
extension AgentTranscriptRestorationLifecycleTests {
    /// Latch for the actual queued adoption task's completion (passive DEBUG callback).
    private final class AdoptionCompletion {
        private var completed: Set<String> = []
        private var waiters: [String: CheckedContinuation<Void, Never>] = [:]

        func record(_ owner: AgentWorkspaceSessionIndexStore.SessionIndexOwner) {
            let key = "\(String(describing: owner.workspaceID))#\(owner.activationEpoch)"
            completed.insert(key)
            waiters.removeValue(forKey: key)?.resume()
        }

        func wait(for owner: AgentWorkspaceSessionIndexStore.SessionIndexOwner) async {
            let key = "\(String(describing: owner.workspaceID))#\(owner.activationEpoch)"
            guard !completed.contains(key) else { return }
            await withCheckedContinuation { waiters[key] = $0 }
        }
    }

    /// §3/§4.5: when queued adoption bails because the active ID moved back by authority-only projection,
    /// nothing remains pending and the pane settles for the current ID instead of awaiting forever.
    func testQueuedAdoptionBailoutSettlesInsteadOfAwaitingForever() async throws {
        try await withRealObserverSavedTab { fixture in
            await fixture.gate.open()
            fixture.viewModel.setAgentModeActive(true)
            await fixture.viewModel.handleWorkspaceSwitch(fixture.workspace)
            if let outgoingLoad = fixture.viewModel.sessions[fixture.tabID]?.persistedLoadTask {
                await outgoingLoad.value
            }
            let incomingTabID = UUID()
            let incoming = WorkspaceModel(
                name: "Incoming",
                repoPaths: [],
                ephemeralFlag: true,
                composeTabs: [ComposeTabState(id: incomingTabID, name: "Incoming")],
                activeComposeTabID: incomingTabID
            )
            fixture.manager.workspaces.append(incoming)
            let adoption = AdoptionCompletion()
            fixture.viewModel.test_afterWorkspaceSwitchAdoptionCompleted = { owner in adoption.record(owner) }
            var queuedOwner: AgentWorkspaceSessionIndexStore.SessionIndexOwner?
            fixture.viewModel.test_afterWorkspaceSwitchAdoptionQueued = { owner in
                queuedOwner = owner
                // Real authority-only projection back to the outgoing workspace before adoption runs.
                fixture.manager.activeWorkspace = fixture.workspace
            }

            _ = await fixture.manager.switchWorkspace(to: incoming, saveState: false, reason: "queuedBailout")
            let owner = try XCTUnwrap(queuedOwner, "precondition: adoption queued")
            await adoption.wait(for: owner)

            XCTAssertEqual(owner.workspaceID, incoming.id)
            XCTAssertEqual(fixture.manager.activeWorkspaceID, fixture.workspace.id, "precondition: ID moved back")
            XCTAssertNotEqual(fixture.viewModel.sessionIndexOwner?.workspaceID, incoming.id, "precondition: adoption bailed")
            XCTAssertFalse(fixture.viewModel.hasPendingOwnerAdoption(forWorkspaceID: incoming.id))
            XCTAssertFalse(fixture.viewModel.hasPendingOwnerAdoption(forWorkspaceID: fixture.workspace.id))
            XCTAssertEqual(
                fixture.viewModel.ui.transcript.snapshot.paneTarget.owner,
                .settledUnowned(workspaceID: fixture.workspace.id, hasSelectedSavedBinding: true)
            )
            XCTAssertEqual(fixture.viewModel.ui.transcript.snapshot.panePresentation, .unavailable(.workspaceUnavailable, retry: nil))
        }
    }
}

/// Snapshot publication at `makeTranscriptUISnapshot` → `AgentTranscriptUIStore.update(_:)` (§4.5):
/// content ownership travels with the published projection, status-only changes publish, identical
/// values deduplicate, and outgoing auxiliary state never survives target replacement.
@MainActor
final class AgentTranscriptPaneSnapshotPublicationTests: XCTestCase {
    /// A loading frame published after a non-empty saved payload applied is not that scope's committed
    /// projection; content ownership is not re-guessed from the selected session.
    func testLoadingFrameAfterAppliedContentIsRestoringNotWelcome() async throws {
        try await withSavedSelectedTab { fixture in
            var saved = AgentSession(id: fixture.sessionID, name: "Saved", savedAt: Date())
            saved.items = [AgentChatItemPersist(
                from: AgentChatItem(id: UUID(), timestamp: Date(), kind: .user, text: "Saved content")
            )]
            _ = try await AgentSessionDataService.shared.saveAgentSession(saved, for: XCTUnwrap(fixture.manager.activeWorkspace))
            fixture.viewModel.setAgentModeActive(true)
            let activationGeneration = fixture.viewModel.test_sessionActivationGeneration
            await fixture.gate.waitUntilEntered()
            let loadTask = try XCTUnwrap(fixture.viewModel.sessions[fixture.tabID]?.persistedLoadTask)
            await fixture.gate.open()
            await loadTask.value
            await fixture.completions.wait(tabID: fixture.tabID, generation: activationGeneration)
            XCTAssertEqual(fixture.viewModel.ui.transcript.snapshot.panePresentation, .transcript, "precondition")

            fixture.viewModel.test_publishLoadingTranscriptPresentation(tabID: fixture.tabID)

            XCTAssertTrue(fixture.viewModel.ui.transcript.snapshot.presentation.workingRows.isEmpty, "precondition: loading frame")
            XCTAssertEqual(fixture.viewModel.ui.transcript.snapshot.panePresentation, .restoring)
        }
    }
}

extension AgentTranscriptPaneSnapshotPublicationTests {
    /// §4.5: when the target is replaced (awaiting the incoming owner), the published snapshot carries
    /// none of the outgoing conversation's rows.
    func testTargetReplacementDropsOutgoingRowsFromPublishedSnapshot() async throws {
        try await withRealObserverSavedTab { fixture in
            var saved = AgentSession(id: fixture.sessionID, name: "Saved", savedAt: Date())
            saved.items = [AgentChatItemPersist(
                from: AgentChatItem(id: UUID(), timestamp: Date(), kind: .user, text: "Outgoing content")
            )]
            _ = try await AgentSessionDataService.shared.saveAgentSession(saved, for: fixture.workspace)
            await fixture.gate.open()
            fixture.viewModel.setAgentModeActive(true)
            await fixture.viewModel.handleWorkspaceSwitch(fixture.workspace)
            if let loadTask = fixture.viewModel.sessions[fixture.tabID]?.persistedLoadTask {
                await loadTask.value
            }
            await fixture.prompt.switchComposeTab(fixture.tabID)
            XCTAssertFalse(fixture.viewModel.ui.transcript.snapshot.presentation.workingRows.isEmpty, "precondition: outgoing rows")

            let incomingTabID = UUID()
            let incoming = WorkspaceModel(
                name: "Incoming",
                repoPaths: [],
                ephemeralFlag: true,
                composeTabs: [ComposeTabState(id: incomingTabID, name: "Incoming", activeAgentSessionID: UUID())],
                activeComposeTabID: incomingTabID
            )
            fixture.manager.workspaces.append(incoming)
            let switchGate = PrepareGate()
            fixture.manager.setWorkspaceRootHydrationWillSpawnHandlerForTesting { workspaceID in
                guard workspaceID == incoming.id else { return }
                try? await switchGate.hold()
            }
            let switchTask = Task { await fixture.manager.switchWorkspace(to: incoming, saveState: false, reason: "auxFilter") }
            await switchGate.waitUntilEntered()

            let snapshot = fixture.viewModel.ui.transcript.snapshot
            XCTAssertEqual(snapshot.paneTarget.owner, .awaitingOwner(workspaceID: incoming.id), "precondition: target replaced")
            XCTAssertTrue(snapshot.presentation.workingRows.isEmpty, "outgoing working rows dropped")
            XCTAssertTrue(snapshot.presentation.visibleRows.isEmpty, "outgoing visible rows dropped")

            await switchGate.open()
            _ = await switchTask.value
            fixture.manager.setWorkspaceRootHydrationWillSpawnHandlerForTesting(nil)
        }
    }
}

extension AgentTranscriptPaneSnapshotPublicationTests {
    /// §4.5 controls: an attempt-only status change publishes the new Retry identity; re-synchronizing
    /// identical facts publishes nothing.
    func testRetryIdentityChangePublishesAndIdenticalSyncDeduplicates() async throws {
        try await withSavedSelectedTab { fixture in
            fixture.viewModel.setAgentModeActive(true)
            let activationGeneration = fixture.viewModel.test_sessionActivationGeneration
            await fixture.gate.waitUntilEntered()
            let session = try XCTUnwrap(fixture.viewModel.sessions[fixture.tabID])
            let firstLoad = try XCTUnwrap(session.persistedLoadTask)
            await fixture.gate.open()
            await firstLoad.value
            await fixture.completions.wait(tabID: fixture.tabID, generation: activationGeneration)
            var firstMissingRetry: AgentTranscriptRetryTarget?
            if case let .unavailable(.missing, retry) = fixture.viewModel.ui.transcript.snapshot.panePresentation {
                firstMissingRetry = retry
            }
            let firstRetry = try XCTUnwrap(firstMissingRetry, "precondition: missing with Retry")

            XCTAssertEqual(fixture.viewModel.retryTranscriptRestoration(firstRetry), .started)
            await fixture.gate.waitUntilEntered(count: 2)
            await session.persistedLoadTask?.value
            guard case let .unavailable(.missing, secondRetry?) = fixture.viewModel.ui.transcript.snapshot.panePresentation else {
                return XCTFail("expected missing again, got \(fixture.viewModel.ui.transcript.snapshot.panePresentation)")
            }
            XCTAssertNotEqual(secondRetry.attemptID, firstRetry.attemptID, "new Retry identity published")

            var publications = 0
            let subscription = fixture.viewModel.ui.transcript.$snapshot.dropFirst().sink { _ in publications += 1 }
            fixture.viewModel.syncTranscriptUIState()
            fixture.viewModel.syncTranscriptUIState()
            subscription.cancel()
            XCTAssertEqual(publications, 0, "identical facts deduplicate")
        }
    }
}

@MainActor
extension AgentTranscriptRestorationLifecycleTests {
    /// §4.1 teardown: window close drops the ephemeral presentation records and admitted attempts.
    func testWindowCloseDropsEphemeralPresentationRecords() async throws {
        try await withSavedSelectedTab { fixture in
            fixture.viewModel.setAgentModeActive(true)
            let activationGeneration = fixture.viewModel.test_sessionActivationGeneration
            await fixture.gate.waitUntilEntered()
            let loadTask = try XCTUnwrap(fixture.viewModel.sessions[fixture.tabID]?.persistedLoadTask)
            await fixture.gate.open()
            await loadTask.value
            await fixture.completions.wait(tabID: fixture.tabID, generation: activationGeneration)
            XCTAssertNotNil(fixture.viewModel.transcriptPresentationRecordsByTabID[fixture.tabID], "precondition: record")
            XCTAssertNotNil(fixture.viewModel.persistedLoadAttemptByTabID[fixture.tabID], "precondition: attempt")

            await fixture.viewModel.prepareForWindowClose()

            XCTAssertTrue(fixture.viewModel.transcriptPresentationRecordsByTabID.isEmpty, "records dropped")
            XCTAssertTrue(fixture.viewModel.persistedLoadAttemptByTabID.isEmpty, "attempts dropped")
        }
    }
}

@MainActor
extension AgentTranscriptRestorationLifecycleTests {
    /// §4.1 teardown: owner discard on a real workspace switch drops the discarded tabs' records/attempts.
    func testOwnerDiscardOnWorkspaceSwitchDropsDiscardedRecords() async throws {
        try await withSavedSelectedTab { fixture in
            fixture.viewModel.setAgentModeActive(true)
            let activationGeneration = fixture.viewModel.test_sessionActivationGeneration
            await fixture.gate.waitUntilEntered()
            let loadTask = try XCTUnwrap(fixture.viewModel.sessions[fixture.tabID]?.persistedLoadTask)
            await fixture.gate.open()
            await loadTask.value
            await fixture.completions.wait(tabID: fixture.tabID, generation: activationGeneration)
            XCTAssertNotNil(fixture.viewModel.transcriptPresentationRecordsByTabID[fixture.tabID], "precondition: record")

            let otherTabID = UUID()
            let other = WorkspaceModel(
                name: "Other",
                repoPaths: [],
                ephemeralFlag: true,
                composeTabs: [ComposeTabState(id: otherTabID, name: "Other")],
                activeComposeTabID: otherTabID
            )
            fixture.manager.workspaces.append(other)
            fixture.manager.activeWorkspace = other
            fixture.viewModel.test_setCurrentTabIDOverride(otherTabID)
            await fixture.viewModel.handleWorkspaceSwitch(other)

            XCTAssertNil(fixture.viewModel.sessions[fixture.tabID], "precondition: session discarded")
            XCTAssertNil(fixture.viewModel.transcriptPresentationRecordsByTabID[fixture.tabID], "discarded record dropped")
            XCTAssertNil(fixture.viewModel.persistedLoadAttemptByTabID[fixture.tabID], "discarded attempt dropped")
        }
    }
}

@MainActor
extension AgentTranscriptRestorationLifecycleTests {
    /// §4.1 teardown: real compose-tab removal drops that tab's presentation record and attempt.
    func testComposeTabRemovalDropsItsPresentationRecord() async throws {
        try await withSavedSelectedTab { fixture in
            fixture.viewModel.setAgentModeActive(true)
            let activationGeneration = fixture.viewModel.test_sessionActivationGeneration
            await fixture.gate.waitUntilEntered()
            let loadTask = try XCTUnwrap(fixture.viewModel.sessions[fixture.tabID]?.persistedLoadTask)
            await fixture.gate.open()
            await loadTask.value
            await fixture.completions.wait(tabID: fixture.tabID, generation: activationGeneration)
            XCTAssertNotNil(fixture.viewModel.transcriptPresentationRecordsByTabID[fixture.tabID], "precondition: record")

            var workspace = try XCTUnwrap(fixture.manager.activeWorkspace)
            workspace.composeTabs.removeAll { $0.id == fixture.tabID }
            fixture.manager.workspaces = [workspace]
            fixture.manager.activeWorkspace = workspace
            _ = await fixture.viewModel.handleComposeTabsDidRemove([fixture.tabID], reason: .close, workspaceID: workspace.id)

            XCTAssertNil(fixture.viewModel.sessions[fixture.tabID], "precondition: session removed")
            XCTAssertNil(fixture.viewModel.transcriptPresentationRecordsByTabID[fixture.tabID], "record dropped")
            XCTAssertNil(fixture.viewModel.persistedLoadAttemptByTabID[fixture.tabID], "attempt dropped")
        }
    }
}

extension AgentTranscriptPaneSnapshotPublicationTests {
    /// §8 owning equality at the real store: with every legacy field (including transcript revision)
    /// identical, each single qualified pane change publishes once; the identical value never does.
    func testStorePublishesEachQualifiedPaneChangeWithIdenticalLegacyFields() async throws {
        try await withSavedSelectedTab { fixture in
            fixture.viewModel.setAgentModeActive(true)
            await fixture.gate.waitUntilEntered()
            let base = fixture.viewModel.makeTranscriptUISnapshot()
            let target = base.paneTarget
            let scope = try XCTUnwrap(target.scope, "precondition: scoped production target")
            let binding = try XCTUnwrap(scope.binding, "precondition: bound production scope")
            let retry = AgentTranscriptRetryTarget(target: target, attemptID: UUID(), sourceItemsRevision: 1)
            let retryNewAttempt = AgentTranscriptRetryTarget(target: target, attemptID: UUID(), sourceItemsRevision: 1)
            // Same owner/tab/session object/session UUID; new binding nonce and transition only.
            let reboundTarget = AgentTranscriptPaneTarget(
                owner: target.owner,
                tabID: target.tabID,
                sessionActivationGeneration: target.sessionActivationGeneration,
                scope: AgentSessionPresentationScope(
                    owner: scope.owner,
                    tabID: scope.tabID,
                    sessionIdentity: scope.sessionIdentity,
                    binding: AgentPersistentSessionBindingIdentity(tabID: binding.tabID, sessionID: binding.sessionID),
                    bindingTransitionGeneration: scope.bindingTransitionGeneration &+ 1
                )
            )
            let regeneratedTarget = AgentTranscriptPaneTarget(
                owner: target.owner,
                tabID: target.tabID,
                sessionActivationGeneration: target.sessionActivationGeneration &+ 1,
                scope: target.scope
            )
            func variant(
                _ pane: AgentTranscriptPanePresentation,
                target paneTarget: AgentTranscriptPaneTarget? = nil
            ) -> AgentTranscriptUISnapshot {
                var copy = base
                copy.panePresentation = pane
                copy.paneTarget = paneTarget ?? target
                return copy
            }
            let sequence: [(String, AgentTranscriptUISnapshot)] = [
                ("status", variant(.restoring)),
                ("status to unavailable", variant(.unavailable(.missing, retry: retry))),
                ("reason only", variant(.unavailable(.loadFailed, retry: retry))),
                ("retry availability only", variant(.unavailable(.loadFailed, retry: nil))),
                ("retry restored", variant(.unavailable(.loadFailed, retry: retry))),
                ("attempt identity only", variant(.unavailable(.loadFailed, retry: retryNewAttempt))),
                ("status back to restoring", variant(.restoring)),
                ("binding incarnation only", variant(.restoring, target: reboundTarget)),
                ("original target restored", variant(.restoring)),
                ("activation generation only", variant(.restoring, target: regeneratedTarget))
            ]
            let store = AgentTranscriptUIStore()
            store.update(variant(.welcome))
            var publications = 0
            let subscription = store.$snapshot.dropFirst().sink { _ in publications += 1 }
            for (index, (label, snapshot)) in sequence.enumerated() {
                XCTAssertEqual(snapshot.presentationRevision, base.presentationRevision, "legacy revision identical")
                store.update(snapshot)
                XCTAssertEqual(publications, index + 1, "\(label) publishes once")
                store.update(snapshot)
                XCTAssertEqual(publications, index + 1, "\(label) identical repeat deduplicates")
            }
            subscription.cancel()
        }
    }
}

/// §5.5 shared selected-settlement facts for the sidebar join, from the same records/exits as the pane.
@MainActor
extension AgentTranscriptRestorationLifecycleTests {
    func testSelectedSettlementIsPendingWhileLoadingAndSettledMissingAfterExit() async throws {
        try await withSavedSelectedTab { fixture in
            fixture.viewModel.setAgentModeActive(true)
            let activationGeneration = fixture.viewModel.test_sessionActivationGeneration
            await fixture.gate.waitUntilEntered()
            XCTAssertEqual(fixture.viewModel.selectedRestorationSettlement(), .pending, "loading is pending")
            let loadTask = try XCTUnwrap(fixture.viewModel.sessions[fixture.tabID]?.persistedLoadTask)

            await fixture.gate.open()
            await loadTask.value
            await fixture.completions.wait(tabID: fixture.tabID, generation: activationGeneration)

            XCTAssertEqual(fixture.viewModel.selectedRestorationSettlement(), .settled(.missing))
        }
    }
}

@MainActor
extension AgentTranscriptRestorationLifecycleTests {
    /// §5.5: an applied payload settles the selected side only after the scope's projection commits.
    func testSelectedSettlementForAppliedPayloadWaitsForProjectionCommit() async throws {
        try await withSavedSelectedTab { fixture in
            _ = try await AgentSessionDataService.shared.saveAgentSession(
                AgentSession(id: fixture.sessionID, name: "Saved", savedAt: Date()),
                for: XCTUnwrap(fixture.manager.activeWorkspace)
            )
            fixture.viewModel.setAgentModeActive(true)
            let activationGeneration = fixture.viewModel.test_sessionActivationGeneration
            await fixture.gate.waitUntilEntered()
            let loadTask = try XCTUnwrap(fixture.viewModel.sessions[fixture.tabID]?.persistedLoadTask)
            await fixture.gate.open()
            await loadTask.value
            await fixture.completions.wait(tabID: fixture.tabID, generation: activationGeneration)
            XCTAssertEqual(fixture.viewModel.ui.transcript.snapshot.panePresentation, .welcome, "precondition: committed")

            XCTAssertEqual(fixture.viewModel.selectedRestorationSettlement(), .settled(.payloadApplied))
        }
    }
}

@MainActor
extension AgentTranscriptRestorationLifecycleTests {
    /// §4.3/§5.5: projection currency is independent of display precedence; with the applied scope's
    /// projection replaced by a loading frame, a current run (pane runningOrWaiting) leaves the selected
    /// side pending.
    func testSelectedSettlementPendingWhileAppliedProjectionUncommittedDuringRun() async throws {
        try await withSavedSelectedTab { fixture in
            _ = try await AgentSessionDataService.shared.saveAgentSession(
                AgentSession(id: fixture.sessionID, name: "Saved", savedAt: Date()),
                for: XCTUnwrap(fixture.manager.activeWorkspace)
            )
            fixture.viewModel.setAgentModeActive(true)
            let activationGeneration = fixture.viewModel.test_sessionActivationGeneration
            await fixture.gate.waitUntilEntered()
            let session = try XCTUnwrap(fixture.viewModel.sessions[fixture.tabID])
            let loadTask = try XCTUnwrap(session.persistedLoadTask)
            await fixture.gate.open()
            await loadTask.value
            await fixture.completions.wait(tabID: fixture.tabID, generation: activationGeneration)
            XCTAssertEqual(fixture.viewModel.selectedRestorationSettlement(), .settled(.payloadApplied), "precondition")

            // Run first (its real hook republishes the committed projection), then replace the projection
            // with a scope-less loading frame: applied record, uncommitted projection, current run.
            session.runState = .running
            fixture.viewModel.test_publishLoadingTranscriptPresentation(tabID: fixture.tabID)
            XCTAssertEqual(fixture.viewModel.ui.transcript.snapshot.panePresentation, .runningOrWaiting, "precondition: run shown")
            let input = fixture.viewModel.transcriptPaneInput(tabID: fixture.tabID, session: session)
            XCTAssertNil(input.content, "precondition: no committed projection for the scope")
            var appliedForCurrentTarget = false
            if let record = input.record, record.scope == input.target.scope,
               case .settled(_, .payloadApplied) = record.phase
            {
                appliedForCurrentTarget = true
            }
            XCTAssertTrue(appliedForCurrentTarget, "precondition: applied record of the current target")

            XCTAssertEqual(fixture.viewModel.selectedRestorationSettlement(), .pending, "projection uncommitted")
            session.runState = .idle
        }
    }
}

@MainActor
extension AgentTranscriptRestorationLifecycleTests {
    /// §5.5: a deliberately created fresh selection settles the selected side immediately.
    func testSelectedSettlementForFreshChatIsSettledFresh() async throws {
        try await withSavedSelectedTab { fixture in
            let session = fixture.viewModel.session(for: fixture.tabID)
            fixture.viewModel.markSessionAsFreshlyCreated(session)
            XCTAssertEqual(fixture.viewModel.ui.transcript.snapshot.panePresentation, .welcome, "precondition")

            XCTAssertEqual(fixture.viewModel.selectedRestorationSettlement(), .settled(.fresh))
        }
    }
}

@MainActor
extension AgentTranscriptRestorationLifecycleTests {
    /// §5.5: an installed owner with no selected tab settles the selected side immediately.
    func testSelectedSettlementWithNoSelectionIsSettledNoSelection() async throws {
        try await withSavedSelectedTab { fixture in
            fixture.viewModel.test_setCurrentTabIDOverride(nil)
            XCTAssertNil(fixture.viewModel.currentTabID, "precondition: no selection")
            XCTAssertNotNil(fixture.viewModel.currentPaneOwner, "precondition: owner installed")

            XCTAssertEqual(fixture.viewModel.selectedRestorationSettlement(), .settled(.noSelection))
        }
    }
}

@MainActor
extension AgentTranscriptRestorationLifecycleTests {
    private struct SettlementLoadFailure: Error {}

    /// §5.5: a real thrown load failure settles the selected side as load-failed.
    func testSelectedSettlementForThrownLoadFailureIsSettledLoadFailed() async throws {
        try await withSavedSelectedTab { fixture in
            fixture.viewModel.setAgentModeActive(true)
            let activationGeneration = fixture.viewModel.test_sessionActivationGeneration
            await fixture.gate.waitUntilEntered()
            let loadTask = try XCTUnwrap(fixture.viewModel.sessions[fixture.tabID]?.persistedLoadTask)
            await fixture.gate.fail(SettlementLoadFailure())
            await loadTask.value
            await fixture.completions.wait(tabID: fixture.tabID, generation: activationGeneration)

            XCTAssertEqual(fixture.viewModel.selectedRestorationSettlement(), .settled(.loadFailed))
        }
    }
}

@MainActor
extension AgentTranscriptRestorationLifecycleTests {
    /// §5.5: a current saved load cancelled with no successor settles the selected side as interrupted.
    func testSelectedSettlementForCancelledLoadIsSettledInterrupted() async throws {
        try await withSavedSelectedTab { fixture in
            fixture.viewModel.setAgentModeActive(true)
            let activationGeneration = fixture.viewModel.test_sessionActivationGeneration
            await fixture.gate.waitUntilEntered()
            let session = try XCTUnwrap(fixture.viewModel.sessions[fixture.tabID])
            let loadTask = try XCTUnwrap(session.persistedLoadTask)
            fixture.viewModel.cancelPersistedLoad(for: session)
            await fixture.gate.open()
            await loadTask.value
            await fixture.completions.wait(tabID: fixture.tabID, generation: activationGeneration)

            XCTAssertEqual(fixture.viewModel.selectedRestorationSettlement(), .settled(.interrupted))
        }
    }
}

@MainActor
extension AgentTranscriptRestorationLifecycleTests {
    /// §5.5: suppressed persistence settles the selected side as persistence-suppressed.
    func testSelectedSettlementForSuppressedPersistenceIsSettledSuppressed() async throws {
        try await withSavedSelectedTab(suppressPersistence: true) { fixture in
            fixture.viewModel.setAgentModeActive(true)
            let activationGeneration = fixture.viewModel.test_sessionActivationGeneration
            await fixture.completions.wait(tabID: fixture.tabID, generation: activationGeneration)

            XCTAssertEqual(fixture.viewModel.selectedRestorationSettlement(), .settled(.persistenceSuppressed))
        }
    }
}

@MainActor
extension AgentTranscriptRestorationLifecycleTests {
    /// §5.5: a settled-unowned saved selection (authority-only projection) settles the selected side.
    func testSelectedSettlementForSettledUnownedWorkspaceIsWorkspaceUnavailable() async throws {
        try await withRealObserverSavedTab { fixture in
            await fixture.gate.open()
            fixture.viewModel.setAgentModeActive(true)
            await fixture.viewModel.handleWorkspaceSwitch(fixture.workspace)
            if let loadTask = fixture.viewModel.sessions[fixture.tabID]?.persistedLoadTask {
                await loadTask.value
            }
            let unownedTabID = UUID()
            let unowned = WorkspaceModel(
                name: "Unowned",
                repoPaths: [],
                ephemeralFlag: true,
                composeTabs: [ComposeTabState(id: unownedTabID, name: "Saved elsewhere", activeAgentSessionID: UUID())],
                activeComposeTabID: unownedTabID
            )
            fixture.manager.workspaces.append(unowned)
            fixture.manager.activeWorkspace = unowned
            XCTAssertEqual(
                fixture.viewModel.ui.transcript.snapshot.paneTarget.owner,
                .settledUnowned(workspaceID: unowned.id, hasSelectedSavedBinding: true),
                "precondition: settled-unowned target"
            )

            XCTAssertEqual(fixture.viewModel.selectedRestorationSettlement(), .settled(.workspaceUnavailable))
        }
    }
}

/// §4.2/§4.3: `renameSession` on an initially unbound live tab attaches the sidebar index's preferred
/// saved session (`boundSessionID` falls back to the index). The attached saved conversation must restore
/// through the existing qualified loader, never strand the pane or save the empty placeholder over it.
@MainActor
extension AgentTranscriptRestorationLifecycleTests {
    private func indexEntry(sessionID: UUID, tabID: UUID) -> AgentSessionIndexEntry {
        AgentSessionIndexEntry(
            id: sessionID, tabID: tabID, name: "Saved", lastUserMessageAt: Date(), savedAt: Date(),
            lastRunStateRaw: nil, itemCount: 1, agentKindRaw: nil, agentModelRaw: nil, agentReasoningEffortRaw: nil,
            autoEditEnabled: false, parentSessionID: nil, hasUnknownConversationContent: false,
            isMCPOriginated: false, worktreeBindingSummaries: [], activeWorktreeMergeSummaries: []
        )
    }

    /// Seeds the index with the tab's preferred saved entry through the real refresh consumer.
    private func seedPreferredIndexEntry(_ fixture: Fixture) async throws -> WorkspaceModel {
        let workspace = try XCTUnwrap(fixture.manager.activeWorkspace)
        let entry = indexEntry(sessionID: fixture.sessionID, tabID: fixture.tabID)
        let open = PrepareGate()
        await open.open()
        let builders = gatedSidebarIndexBuilders(open, entries: { [entry.id: entry] })
        fixture.viewModel.test_setSidebarIndexBuilders(prioritized: builders.0, stream: builders.1)
        fixture.viewModel.test_refreshSessionListCache(for: workspace)
        await fixture.viewModel.test_waitForSessionListCacheRefresh()
        XCTAssertEqual(fixture.viewModel.boundSessionID(for: fixture.tabID), fixture.sessionID, "precondition: index-preferred")
        return workspace
    }

    private func savePersistedHistory(_ fixture: Fixture, workspace: WorkspaceModel) async throws {
        var saved = AgentSession(id: fixture.sessionID, name: "Saved", savedAt: Date())
        saved.composeTabID = fixture.tabID
        saved.items = [AgentChatItemPersist(
            from: AgentChatItem(id: UUID(), timestamp: Date(), kind: .user, text: "Persisted history")
        )]
        _ = try await AgentSessionDataService.shared.saveAgentSession(saved, for: workspace)
    }

    private func persistedItemCount(_ fixture: Fixture, workspace: WorkspaceModel) async throws -> Int? {
        try await AgentSessionDataService.shared.loadAgentSession(id: fixture.sessionID, for: workspace)?.items.count
    }

    func testRenameAttachingIndexDerivedSavedSessionRestoresWithoutOverwritingHistory() async throws {
        try await withSavedSelectedTab(bound: false) { fixture in
            let viewModel = fixture.viewModel
            let workspace = try await seedPreferredIndexEntry(fixture)
            try await savePersistedHistory(fixture, workspace: workspace)
            viewModel.setAgentModeActive(true)
            let session = try XCTUnwrap(viewModel.sessions[fixture.tabID])
            XCTAssertNil(session.activeAgentSessionID, "precondition: unbound live target")

            viewModel.renameSession(tabID: fixture.tabID, to: "Renamed")
            let activationGeneration = viewModel.test_sessionActivationGeneration
            XCTAssertEqual(session.activeAgentSessionID, fixture.sessionID, "attached the index-derived saved session")
            XCTAssertEqual(viewModel.test_ownerValidatedSessionIndex[fixture.sessionID]?.name, "Renamed", "rename applied")
            // No placeholder save may replace the saved history, before or after restoration.
            await viewModel.flushSave(for: fixture.tabID)
            let countAfterRename = try await persistedItemCount(fixture, workspace: workspace)
            XCTAssertEqual(countAfterRename, 1, "history not overwritten")

            let loadTask = try XCTUnwrap(session.persistedLoadTask, "the existing qualified loader restores it")
            await fixture.gate.waitUntilEntered()
            XCTAssertEqual(viewModel.ui.transcript.snapshot.panePresentation, .restoring)
            await fixture.gate.open()
            await loadTask.value
            await fixture.completions.wait(tabID: fixture.tabID, generation: activationGeneration)
            XCTAssertEqual(viewModel.ui.transcript.snapshot.panePresentation, .transcript)
            XCTAssertEqual(session.items.map(\.text), ["Persisted history"])
            await viewModel.flushSave(for: fixture.tabID)
            let countAfterRestore = try await persistedItemCount(fixture, workspace: workspace)
            XCTAssertEqual(countAfterRestore, 1)
        }
    }

    /// Observable rename contract with the real prompt manager: the compose-tab name (display and save
    /// authority) survives hydration and a later real save, and the saved history is retained.
    func testRenameSurvivesHydrationAndLaterRealSaveWithPromptManager() async throws {
        try await withRealObserverSavedTab(bound: false) { fixture in
            let viewModel = fixture.viewModel
            let entry = indexEntry(sessionID: fixture.sessionID, tabID: fixture.tabID)
            let open = PrepareGate()
            await open.open()
            let builders = gatedSidebarIndexBuilders(open, entries: { [entry.id: entry] })
            viewModel.test_setSidebarIndexBuilders(prioritized: builders.0, stream: builders.1)
            var saved = AgentSession(id: fixture.sessionID, name: "Saved", savedAt: Date())
            saved.composeTabID = fixture.tabID
            saved.items = [AgentChatItemPersist(
                from: AgentChatItem(id: UUID(), timestamp: Date(), kind: .user, text: "Persisted history")
            )]
            _ = try await AgentSessionDataService.shared.saveAgentSession(saved, for: fixture.workspace)
            viewModel.setAgentModeActive(true)
            await viewModel.handleWorkspaceSwitch(fixture.workspace)
            await viewModel.test_waitForSessionListCacheRefresh()
            XCTAssertEqual(viewModel.boundSessionID(for: fixture.tabID), fixture.sessionID, "precondition: index-preferred")
            await fixture.prompt.switchComposeTab(fixture.tabID)
            let session = viewModel.session(for: fixture.tabID)
            XCTAssertNil(session.activeAgentSessionID, "precondition: unbound live target")
            XCTAssertEqual(viewModel.currentTabID, fixture.tabID, "precondition: current target")

            viewModel.renameSession(tabID: fixture.tabID, to: "Renamed")
            let activationGeneration = viewModel.test_sessionActivationGeneration
            await fixture.gate.waitUntilEntered()
            let loadTask = try XCTUnwrap(session.persistedLoadTask)
            await fixture.gate.open()
            await loadTask.value
            await fixture.completions.wait(tabID: fixture.tabID, generation: activationGeneration)
            XCTAssertEqual(session.items.map(\.text), ["Persisted history"])

            // Display authority after hydration: the renamed compose tab, not the hydrated index name.
            let tabs = fixture.prompt.currentComposeTabs
            XCTAssertEqual(tabs.first { $0.id == fixture.tabID }?.name, "Renamed")
            XCTAssertEqual(viewModel.agentChatsSidebarSessions(for: tabs).first { $0.tabID == fixture.tabID }?.title, "Renamed")

            // A later real save persists the renamed authority with the history retained.
            session.appendItem(AgentChatItem(id: UUID(), timestamp: Date(), kind: .user, text: "After rename"))
            await viewModel.flushSave(for: fixture.tabID)
            let persisted = try await AgentSessionDataService.shared.loadAgentSession(id: fixture.sessionID, for: fixture.workspace)
            XCTAssertEqual(persisted?.name, "Renamed")
            XCTAssertEqual(persisted?.items.count, 2, "history retained plus the new turn")
        }
    }

    func testRenameOfNonCurrentEmptyTabNeverSavesPlaceholderOverHistory() async throws {
        try await withSavedSelectedTab(bound: false) { fixture in
            let viewModel = fixture.viewModel
            let workspace = try await seedPreferredIndexEntry(fixture)
            try await savePersistedHistory(fixture, workspace: workspace)
            viewModel.setAgentModeActive(true)
            let session = try XCTUnwrap(viewModel.sessions[fixture.tabID])
            viewModel.test_setCurrentTabIDOverride(UUID())

            viewModel.renameSession(tabID: fixture.tabID, to: "Renamed")
            XCTAssertEqual(session.activeAgentSessionID, fixture.sessionID)
            XCTAssertNil(session.persistedLoadTask, "not current: restores on selection, no load now")
            XCTAssertFalse(session.hasLoadedPersistedState, "next activation loads the saved history")
            await viewModel.flushSave(for: fixture.tabID)
            let count = try await persistedItemCount(fixture, workspace: workspace)
            XCTAssertEqual(count, 1, "history not overwritten")
            viewModel.test_setCurrentTabIDOverride(fixture.tabID)
        }
    }

    func testRenameWithLocalContentAttachesWithoutLoadingOverLocalItems() async throws {
        try await withSavedSelectedTab(bound: false) { fixture in
            let viewModel = fixture.viewModel
            _ = try await seedPreferredIndexEntry(fixture)
            viewModel.setAgentModeActive(true)
            let session = try XCTUnwrap(viewModel.sessions[fixture.tabID])
            let local = AgentChatItem(id: UUID(), timestamp: Date(), kind: .user, text: "Local draft turn")
            session.appendItem(local)

            viewModel.renameSession(tabID: fixture.tabID, to: "Renamed")
            XCTAssertNil(session.persistedLoadTask, "local content owns the scope; no disk load over it")
            XCTAssertEqual(session.items.map(\.id), [local.id])
            let entries = await fixture.gate.entries
            XCTAssertEqual(entries, 0)
        }
    }

    func testRejectedAttachmentStartsNoLoadForAnUnrelatedSession() async throws {
        try await withSavedSelectedTab(bound: false) { fixture in
            let viewModel = fixture.viewModel
            var workspace = try await seedPreferredIndexEntry(fixture)
            viewModel.setAgentModeActive(true)
            let session = try XCTUnwrap(viewModel.sessions[fixture.tabID])
            // Durable authority moved to an unrelated session after the live target materialized unbound:
            // compare-and-set from the live (nil) binding is rejected.
            let unrelatedSessionID = UUID()
            workspace.composeTabs[0].activeAgentSessionID = unrelatedSessionID
            fixture.manager.workspaces = [workspace]
            fixture.manager.activeWorkspace = workspace

            viewModel.renameSession(tabID: fixture.tabID, to: "Renamed")
            XCTAssertNil(session.activeAgentSessionID, "attachment rejected")
            XCTAssertNil(session.persistedLoadTask, "no load of an unrelated session")
            let entries = await fixture.gate.entries
            XCTAssertEqual(entries, 0)
        }
    }
}

/// Index stream held at the real refresh consumer until the test opens it (no sleeps).
private func gatedSidebarIndexBuilders(
    _ gate: PrepareGate,
    entries: @escaping @Sendable () -> [UUID: AgentSessionIndexEntry] = { [:] }
) -> (AgentModeViewModel.SidebarPrioritizedIndexBuilder, AgentModeViewModel.SidebarIndexStreamBuilder) {
    (
        { _ in AgentSessionSidebarBuildResult(entriesBySessionID: [:], preferredSessionIDByTabID: [:]) },
        { _, _ in
            AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        try await gate.hold()
                        continuation.yield(AgentSessionSidebarBuildBatch(entriesBySessionID: entries(), preferredSessionIDByTabID: [:]))
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    )
}

/// §5.2–5.6 through the real switch → index refresh → selected loader → sidebar consumers.
@MainActor
final class AgentSidebarRestoreStabilityTests: XCTestCase {
    private func installGatedIndex(_ gate: PrepareGate) -> (AgentModeViewModel) -> Void {
        { viewModel in
            let builders = gatedSidebarIndexBuilders(gate)
            viewModel.test_setSidebarIndexBuilders(prioritized: builders.0, stream: builders.1)
        }
    }

    private func displayedRows(_ fixture: Fixture) throws -> [AgentModeViewModel.SidebarSession] {
        let workspace = try XCTUnwrap(fixture.manager.activeWorkspace)
        return fixture.viewModel.filteredSidebarSessions(for: workspace.composeTabs, currentTabID: fixture.tabID, searchText: "")
    }

    func testIndexCompletionFirstStagesMetadataAndReleasesOnceSelectedSettles() async throws {
        let indexGate = PrepareGate()
        try await withSavedSelectedTab(beforeSwitch: installGatedIndex(indexGate)) { fixture in
            let viewModel = fixture.viewModel
            XCTAssertNotNil(viewModel.test_ownerValidatedSidebarRestoreBaseline, "captured at owner install")
            viewModel.setAgentModeActive(true)
            let activationGeneration = viewModel.test_sessionActivationGeneration
            await fixture.gate.waitUntilEntered()
            XCTAssertEqual(viewModel.test_ownerValidatedSidebarRestoreJoin?.selected.isSettled, false)

            await indexGate.open()
            await viewModel.test_waitForSessionListCacheRefresh()
            XCTAssertEqual(viewModel.test_ownerValidatedSidebarRestoreJoin?.index.isTerminal, true, "terminal metadata staged")
            XCTAssertNotNil(viewModel.test_ownerValidatedSidebarRestoreBaseline, "index completion alone does not release")
            XCTAssertFalse(viewModel.test_ownerValidatedSessionListCacheReady, "readiness waits for the join")
            XCTAssertNotNil(try displayedRows(fixture).first?.restorationDateBucket, "baseline positions displayed rows")

            let loadTask = try XCTUnwrap(viewModel.sessions[fixture.tabID]?.persistedLoadTask)
            await fixture.gate.open()
            await loadTask.value
            await fixture.completions.wait(tabID: fixture.tabID, generation: activationGeneration)

            XCTAssertNil(viewModel.test_ownerValidatedSidebarRestoreJoin)
            XCTAssertNil(viewModel.test_ownerValidatedSidebarRestoreBaseline)
            XCTAssertTrue(viewModel.test_ownerValidatedSessionListCacheReady)
            XCTAssertNil(try displayedRows(fixture).first?.restorationDateBucket, "settled rows use ordinary headings")
        }
        await indexGate.open()
    }

    func testSelectedSettlementFirstWaitsForIndexTerminalBeforeRelease() async throws {
        let indexGate = PrepareGate()
        try await withSavedSelectedTab(beforeSwitch: installGatedIndex(indexGate)) { fixture in
            let viewModel = fixture.viewModel
            viewModel.setAgentModeActive(true)
            let activationGeneration = viewModel.test_sessionActivationGeneration
            await fixture.gate.waitUntilEntered()
            let loadTask = try XCTUnwrap(viewModel.sessions[fixture.tabID]?.persistedLoadTask)
            await fixture.gate.open()
            await loadTask.value
            await fixture.completions.wait(tabID: fixture.tabID, generation: activationGeneration)

            XCTAssertEqual(viewModel.test_ownerValidatedSidebarRestoreJoin?.selected, .settled(.restoration(.missing)))
            XCTAssertNotNil(viewModel.test_ownerValidatedSidebarRestoreBaseline, "selected settlement alone does not release")

            await indexGate.open()
            await viewModel.test_waitForSessionListCacheRefresh()
            XCTAssertNil(viewModel.test_ownerValidatedSidebarRestoreBaseline)
            XCTAssertTrue(viewModel.test_ownerValidatedSessionListCacheReady)
        }
        await indexGate.open()
    }

    func testInactiveAtInstallDoesNotSettleSelectedSideUntilActivationRestores() async throws {
        let indexGate = PrepareGate()
        try await withSavedSelectedTab(beforeSwitch: installGatedIndex(indexGate)) { fixture in
            let viewModel = fixture.viewModel
            // The launch switch can install the owner before the Agent view activates.
            await indexGate.open()
            await viewModel.test_waitForSessionListCacheRefresh()
            XCTAssertEqual(viewModel.test_ownerValidatedSidebarRestoreJoin?.index.isTerminal, true)
            XCTAssertEqual(viewModel.test_ownerValidatedSidebarRestoreJoin?.selected.isSettled, false)
            XCTAssertNotNil(viewModel.test_ownerValidatedSidebarRestoreBaseline)

            viewModel.setAgentModeActive(true)
            let activationGeneration = viewModel.test_sessionActivationGeneration
            await fixture.gate.waitUntilEntered()
            await viewModel.test_waitForSessionListCacheRefresh()
            XCTAssertNotNil(viewModel.test_ownerValidatedSidebarRestoreBaseline, "activation refresh transfers, never releases early")
            let loadTask = try XCTUnwrap(viewModel.sessions[fixture.tabID]?.persistedLoadTask)
            await fixture.gate.open()
            await loadTask.value
            await fixture.completions.wait(tabID: fixture.tabID, generation: activationGeneration)
            XCTAssertNil(viewModel.test_ownerValidatedSidebarRestoreBaseline)
        }
        await indexGate.open()
    }

    func testAgentModeOffDuringPendingJoinDefersUntilReactivationWithoutRelease() async throws {
        let indexGate = PrepareGate()
        try await withSavedSelectedTab(beforeSwitch: installGatedIndex(indexGate)) { fixture in
            let viewModel = fixture.viewModel
            viewModel.setAgentModeActive(true)
            await fixture.gate.waitUntilEntered()
            viewModel.setAgentModeActive(false)
            XCTAssertEqual(viewModel.test_ownerValidatedSidebarRestoreJoin?.index, .deferred(.agentModeInactive))
            XCTAssertEqual(viewModel.test_ownerValidatedSidebarRestoreJoin?.selected, .settled(.notPresented))
            XCTAssertNotNil(viewModel.test_ownerValidatedSidebarRestoreBaseline, "deferred-inactive is not terminal")

            viewModel.setAgentModeActive(true)
            XCTAssertEqual(viewModel.test_ownerValidatedSidebarRestoreJoin?.index.isTerminal, false, "reactivation adopts a new token")
            XCTAssertNotNil(viewModel.test_ownerValidatedSidebarRestoreBaseline)
            await indexGate.open()
            await viewModel.test_waitForSessionListCacheRefresh()
            XCTAssertNil(viewModel.test_ownerValidatedSidebarRestoreBaseline)
            await fixture.gate.open()
        }
        await indexGate.open()
    }

    func testDeactivationAfterIndexFirstKeepsBaselineAndReadinessFalse() async throws {
        let indexGate = PrepareGate()
        try await withSavedSelectedTab(beforeSwitch: installGatedIndex(indexGate)) { fixture in
            let viewModel = fixture.viewModel
            viewModel.setAgentModeActive(true)
            await fixture.gate.waitUntilEntered()
            await indexGate.open()
            await viewModel.test_waitForSessionListCacheRefresh()
            XCTAssertEqual(viewModel.test_ownerValidatedSidebarRestoreJoin?.index.isTerminal, true, "precondition: staged")
            viewModel.setAgentModeActive(false)
            XCTAssertEqual(viewModel.test_ownerValidatedSidebarRestoreJoin?.index, .deferred(.agentModeInactive))
            XCTAssertNotNil(viewModel.test_ownerValidatedSidebarRestoreBaseline)
            XCTAssertFalse(viewModel.test_ownerValidatedSessionListCacheReady, "no readiness while disabled")
            viewModel.setAgentModeActive(true)
            await viewModel.test_waitForSessionListCacheRefresh()
            XCTAssertNil(viewModel.test_ownerValidatedSidebarRestoreBaseline, "the same owner's replacement refresh releases")
            XCTAssertTrue(viewModel.test_ownerValidatedSessionListCacheReady)
            await fixture.gate.open()
        }
        await indexGate.open()
    }

    func testExplicitSelectionChangeAfterSwitchSettlesInitialBarrier() async throws {
        let indexGate = PrepareGate()
        try await withSavedSelectedTab(beforeSwitch: installGatedIndex(indexGate)) { fixture in
            let viewModel = fixture.viewModel
            viewModel.setAgentModeActive(true)
            await fixture.gate.waitUntilEntered()
            viewModel.test_setCurrentTabIDOverride(UUID())
            viewModel.syncTranscriptUIState()
            XCTAssertEqual(viewModel.test_ownerValidatedSidebarRestoreJoin?.selected, .settled(.selectionChanged))
            XCTAssertNotNil(viewModel.test_ownerValidatedSidebarRestoreBaseline, "index side still pending")
            await indexGate.open()
            await viewModel.test_waitForSessionListCacheRefresh()
            XCTAssertNil(viewModel.test_ownerValidatedSidebarRestoreBaseline)
            viewModel.test_setCurrentTabIDOverride(fixture.tabID)
            await fixture.gate.open()
        }
        await indexGate.open()
    }

    func testClearAndSourceMutationsPreserveBaselineCoverage() async throws {
        let indexGate = PrepareGate()
        try await withSavedSelectedTab(bound: false, beforeSwitch: installGatedIndex(indexGate)) { fixture in
            let viewModel = fixture.viewModel
            viewModel.setAgentModeActive(true)
            let revision = try XCTUnwrap(viewModel.test_ownerValidatedSidebarRestoreBaseline?.revision)
            viewModel.ensureSession(for: fixture.tabID)
            viewModel.clearChat(tabID: fixture.tabID)
            XCTAssertEqual(viewModel.test_ownerValidatedSidebarRestoreBaseline?.revision, revision, "user mutations never drop coverage")
            await indexGate.open()
        }
        await indexGate.open()
    }

    func testWindowTeardownDropsJoinAndBaseline() async throws {
        let indexGate = PrepareGate()
        try await withSavedSelectedTab(beforeSwitch: installGatedIndex(indexGate)) { fixture in
            XCTAssertNotNil(fixture.viewModel.test_ownerValidatedSidebarRestoreBaseline)
            await indexGate.open()
            await fixture.viewModel.prepareForWindowClose()
            XCTAssertNil(fixture.viewModel.sidebarRestoreBaseline)
            XCTAssertNil(fixture.viewModel.test_ownerValidatedSidebarRestoreJoin)
        }
        await indexGate.open()
    }

    /// §5.6 through the actual delegate → sidebar UI seam: the final index terminal publishes exactly
    /// one sidebar snapshot, and that snapshot already observes final index, readiness and no baseline.
    func testReleasePublishesExactlyOneCoherentSidebarSnapshotThroughVMDelegate() async throws {
        let indexGate = PrepareGate()
        try await withSavedSelectedTab(beforeSwitch: installGatedIndex(indexGate)) { fixture in
            let viewModel = fixture.viewModel
            viewModel.setAgentModeActive(true)
            let activationGeneration = viewModel.test_sessionActivationGeneration
            await fixture.gate.waitUntilEntered()
            let loadTask = try XCTUnwrap(viewModel.sessions[fixture.tabID]?.persistedLoadTask)
            await fixture.gate.open()
            await loadTask.value
            await fixture.completions.wait(tabID: fixture.tabID, generation: activationGeneration)
            XCTAssertEqual(viewModel.test_ownerValidatedSidebarRestoreJoin?.selected.isSettled, true, "precondition")
            XCTAssertNotNil(viewModel.test_ownerValidatedSidebarRestoreBaseline, "precondition: index pending")

            struct Observed: Equatable {
                let rowContentRevision: Int
                let baselineReleased: Bool
                let ready: Bool
                let displayedBuckets: [AgentSidebarDateSectionBucket?]
            }
            var observed: [Observed] = []
            let workspace = try XCTUnwrap(fixture.manager.activeWorkspace)
            let subscription = viewModel.ui.sessionSidebar.$snapshot.dropFirst().sink { snapshot in
                observed.append(Observed(
                    rowContentRevision: snapshot.rowContentRevision,
                    baselineReleased: viewModel.test_ownerValidatedSidebarRestoreBaseline == nil,
                    ready: viewModel.test_ownerValidatedSessionListCacheReady,
                    displayedBuckets: viewModel.filteredSidebarSessions(
                        for: workspace.composeTabs,
                        currentTabID: fixture.tabID,
                        searchText: ""
                    ).map(\.restorationDateBucket)
                ))
            }
            defer { subscription.cancel() }
            let revisionBefore = viewModel.ui.sessionSidebar.snapshot.rowContentRevision

            await indexGate.open()
            await viewModel.test_waitForSessionListCacheRefresh()

            XCTAssertEqual(observed.count, 1, "exactly one sidebar UI publication for the release: \(observed)")
            XCTAssertEqual(observed.first, Observed(
                rowContentRevision: revisionBefore + 1,
                baselineReleased: true,
                ready: true,
                displayedBuckets: [nil]
            ))
        }
        await indexGate.open()
    }

    /// §5.5: index entries never bind a live session (`explicitActiveSessionID` excludes the index and
    /// `session(for:)` returns the existing live session first), so an initially unbound selected tab's
    /// live session only gains a saved binding through an explicit install — a same-tab rebind once
    /// discovery completed. It settles the barrier instead of waiting on an attempt nothing will start.
    func testInitiallyUnboundTabExplicitSavedBindingAfterDiscoverySettlesWithoutStranding() async throws {
        let indexGate = PrepareGate()
        try await withSavedSelectedTab(bound: false, beforeSwitch: installGatedIndex(indexGate)) { fixture in
            let viewModel = fixture.viewModel
            let join = try XCTUnwrap(viewModel.test_ownerValidatedSidebarRestoreJoin)
            XCTAssertNil(join.initialBindingID, "precondition: unbound at install")
            XCTAssertFalse(join.selected.isSettled, "precondition: inactive at install does not settle")
            let session = try XCTUnwrap(viewModel.sessions[fixture.tabID])
            XCTAssertNotNil(viewModel.test_installPersistentSessionBinding(sessionID: fixture.sessionID, on: session))

            viewModel.setAgentModeActive(true)
            viewModel.syncTranscriptUIState()
            XCTAssertNil(session.persistedLoadTask, "precondition: no attempt starts for the installed binding")
            XCTAssertEqual(viewModel.test_ownerValidatedSidebarRestoreJoin?.selected, .settled(.bindingChanged))
            XCTAssertNotNil(viewModel.test_ownerValidatedSidebarRestoreBaseline, "index side still pending")

            await indexGate.open()
            await viewModel.test_waitForSessionListCacheRefresh()
            XCTAssertNil(viewModel.test_ownerValidatedSidebarRestoreBaseline, "released, never stranded")
            XCTAssertTrue(viewModel.test_ownerValidatedSessionListCacheReady)
        }
        await indexGate.open()
    }

    /// §5.5: a System launch deferral declined while a real switch is in flight, followed by the switch
    /// being cancelled and recovered to System without any switch notification (the System owner survives),
    /// must not leave the join waiting on a deferral nothing will ever start. (Cancelling after the
    /// incoming ID publishes instead re-notifies and installs a fresh owner, discarding the old join.)
    func testDeclinedSystemDeferralDuringAbortedSwitchDoesNotStrandJoin() async throws {
        try await withRealObserverSavedTab { fixture in
            let viewModel = fixture.viewModel
            let systemTabID = UUID()
            let system = WorkspaceModel(
                name: "System",
                repoPaths: [],
                isSystemWorkspace: true,
                ephemeralFlag: true,
                composeTabs: [ComposeTabState(id: systemTabID, name: "System tab")],
                activeComposeTabID: systemTabID
            )
            fixture.manager.workspaces.append(system)
            fixture.manager.activeWorkspace = system
            viewModel.deferInitialSystemWorkspaceSessionListRefresh(reason: "sidebarAbortTest")
            viewModel.setAgentModeActive(true)
            await viewModel.handleWorkspaceSwitch(system)
            await viewModel.test_waitForSessionListCacheRefresh()
            XCTAssertEqual(viewModel.test_ownerValidatedSidebarRestoreJoin?.index, .deferred(.initialSystemDeferral), "precondition")

            let incomingTabID = UUID()
            let incoming = WorkspaceModel(
                name: "Incoming",
                repoPaths: [],
                ephemeralFlag: true,
                composeTabs: [ComposeTabState(id: incomingTabID, name: "Incoming")],
                activeComposeTabID: incomingTabID
            )
            fixture.manager.workspaces.append(incoming)
            let switchGate = PrepareGate()
            fixture.manager.setWorkspaceSwitchBeforeActiveWorkspacePublicationHandlerForTesting { workspaceID in
                guard workspaceID == incoming.id else { return }
                try? await switchGate.hold()
            }
            let systemOwner = try XCTUnwrap(viewModel.sessionIndexOwner)
            let switchTask = Task { await fixture.manager.switchWorkspace(to: incoming, saveState: false, reason: "sidebarAbort") }
            await switchGate.waitUntilEntered()
            XCTAssertTrue(fixture.manager.isSwitchingWorkspace, "precondition: switch in flight")
            // The deferral is cleared while the switch is in flight, so it declines to refresh.
            viewModel.finishInitialSystemWorkspaceSessionListRefreshDeferral()

            await fixture.manager.cancelCurrentWorkspaceSwitchAndReturnToSystem()
            await switchGate.open()
            _ = await switchTask.value
            fixture.manager.setWorkspaceSwitchBeforeActiveWorkspacePublicationHandlerForTesting(nil)
            await viewModel.test_waitForSessionListCacheRefresh()

            XCTAssertEqual(fixture.manager.activeWorkspace?.isSystemWorkspace, true, "precondition: returned to System")
            XCTAssertEqual(viewModel.sessionIndexOwner, systemOwner, "precondition: recovery without a switch notification")
            XCTAssertNotEqual(
                viewModel.test_ownerValidatedSidebarRestoreJoin?.index,
                .deferred(.initialSystemDeferral),
                "no join may wait on a cleared deferral"
            )
        }
    }

    func testOwnerPendingSidebarProjectionShowsNoOutgoingRowsOrTargetHeadings() async throws {
        try await withRealObserverSavedTab { fixture in
            fixture.viewModel.setAgentModeActive(true)
            await fixture.viewModel.handleWorkspaceSwitch(fixture.workspace)
            await fixture.gate.waitUntilEntered()
            await fixture.gate.open()
            let incomingTabID = UUID()
            let incoming = WorkspaceModel(
                name: "Incoming",
                repoPaths: [],
                ephemeralFlag: true,
                composeTabs: [ComposeTabState(id: incomingTabID, name: "Incoming", activeAgentSessionID: UUID())],
                activeComposeTabID: incomingTabID
            )
            fixture.manager.workspaces.append(incoming)
            let switchGate = PrepareGate()
            fixture.manager.setWorkspaceRootHydrationWillSpawnHandlerForTesting { workspaceID in
                guard workspaceID == incoming.id else { return }
                try? await switchGate.hold()
            }
            let switchTask = Task { await fixture.manager.switchWorkspace(to: incoming, saveState: false, reason: "sidebarOwnerPending") }
            await switchGate.waitUntilEntered()

            let viewModel = fixture.viewModel
            XCTAssertTrue(viewModel.isSidebarOwnerPending)
            XCTAssertTrue(viewModel.lastPublishedSidebarOwnerPending, "propagated from the pane publication point")
            let archived = StashedTab(id: UUID(), tab: ComposeTabState(name: "Archived", activeAgentSessionID: UUID()), stashedAt: Date())
            let projection = viewModel.sidebarListProjection(
                workspaceID: incoming.id,
                composeTabs: incoming.composeTabs,
                stashedTabs: [archived],
                currentTabID: incomingTabID,
                sidebarSnapshot: viewModel.ui.sessionSidebar.snapshot,
                archivedSessionsExpanded: true,
                showComposeTabsWithoutAgentSessions: true
            )
            XCTAssertTrue(projection.isOwnerPending)
            XCTAssertTrue(projection.pagedSessions.isEmpty, "no outgoing or target rows")
            XCTAssertTrue(projection.pagedArchivedSessionTabsForRows.isEmpty, "no archived rows")
            XCTAssertTrue(projection.renderedSelectionOrder.isEmpty, "no navigation targets")
            XCTAssertTrue(AgentSidebarDateSectionBuilder.activeSections(for: projection.pagedSessions).isEmpty)
            XCTAssertEqual(
                viewModel.sidebarCollapseAllState(for: incoming.composeTabs, currentTabID: incomingTabID, searchText: ""),
                .hidden
            )

            await switchGate.open()
            _ = await switchTask.value
            fixture.manager.setWorkspaceRootHydrationWillSpawnHandlerForTesting(nil)
            XCTAssertFalse(viewModel.isSidebarOwnerPending)
            XCTAssertEqual(viewModel.test_ownerValidatedSidebarRestoreBaseline?.owner.workspaceID, incoming.id)
            XCTAssertNotNil(viewModel.test_ownerValidatedSidebarRestoreBaseline?.entries[incomingTabID])
        }
    }
}

import Foundation
@testable import RepoPrompt
import XCTest

@MainActor
final class AgentComposerSubmissionAttemptTests: XCTestCase {
    func testComposerProductionEqualityRejectsLiveTabChangeBeforePropsCatchUp() {
        let sourceTabID = UUID()
        let destinationTabID = UUID()

        XCTAssertTrue(
            AgentComposerView.hasEquivalentRenderIdentity(
                lhsProps: .empty,
                lhsPlaceholderText: "Send a message...",
                lhsCurrentTabID: sourceTabID,
                rhsProps: .empty,
                rhsPlaceholderText: "Send a message...",
                rhsCurrentTabID: sourceTabID
            )
        )
        XCTAssertFalse(
            AgentComposerView.hasEquivalentRenderIdentity(
                lhsProps: .empty,
                lhsPlaceholderText: "Send a message...",
                lhsCurrentTabID: sourceTabID,
                rhsProps: .empty,
                rhsPlaceholderText: "Send a message...",
                rhsCurrentTabID: destinationTabID
            )
        )
    }

    func testLatchSuppressesRapidSameTabCallbacksButAllowsAnotherTab() throws {
        var latch = AgentComposerSubmissionLatch()
        let firstSession = AgentModeViewModel.TabSession(tabID: UUID())
        let secondSession = AgentModeViewModel.TabSession(tabID: UUID())
        let firstTarget = makeTarget(session: firstSession)
        let secondTarget = makeTarget(session: secondSession)

        let firstAttempt = try XCTUnwrap(latch.begin(target: firstTarget, rawDraftSnapshot: "first"))

        XCTAssertTrue(latch.isLatched(for: firstSession.tabID))
        XCTAssertEqual(latch.activeAttemptID(for: firstSession.tabID), firstAttempt.id)
        XCTAssertNil(latch.begin(target: firstTarget, rawDraftSnapshot: "duplicate"))
        XCTAssertNotNil(latch.begin(target: secondTarget, rawDraftSnapshot: "second"))
    }

    func testMatchingCompletionClearsOnlyUnchangedInput() throws {
        var latch = AgentComposerSubmissionLatch()
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        latch.advanceInputRevision()
        let attempt = try XCTUnwrap(
            latch.begin(target: makeTarget(session: session), rawDraftSnapshot: "submitted draft")
        )

        let effects = latch.complete(
            attempt,
            result: .submitted,
            currentTabID: session.tabID,
            currentRawDraft: "submitted draft"
        )

        XCTAssertTrue(effects.matchedAttempt)
        XCTAssertTrue(effects.shouldClearInput)
        XCTAssertNil(effects.blockedMessage)
        XCTAssertFalse(latch.isLatched(for: session.tabID))
    }

    func testNewerTypingAndDraftRestorationSurviveCompletion() throws {
        var latch = AgentComposerSubmissionLatch()
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        latch.advanceInputRevision()
        let attempt = try XCTUnwrap(
            latch.begin(target: makeTarget(session: session), rawDraftSnapshot: "submitted draft")
        )

        // A programmatic restoration must advance the same revision even when the
        // resulting text happens to match the submitted text.
        latch.advanceInputRevision()
        let effects = latch.complete(
            attempt,
            result: .submitted,
            currentTabID: session.tabID,
            currentRawDraft: "submitted draft"
        )

        XCTAssertTrue(effects.matchedAttempt)
        XCTAssertFalse(effects.shouldClearInput)
    }

    func testTabSwitchPreventsOldCompletionFromClearingCurrentDraft() throws {
        var latch = AgentComposerSubmissionLatch()
        let sourceSession = AgentModeViewModel.TabSession(tabID: UUID())
        let currentSession = AgentModeViewModel.TabSession(tabID: UUID())
        let attempt = try XCTUnwrap(
            latch.begin(target: makeTarget(session: sourceSession), rawDraftSnapshot: "same text")
        )

        let effects = latch.complete(
            attempt,
            result: .submitted,
            currentTabID: currentSession.tabID,
            currentRawDraft: "same text"
        )

        XCTAssertTrue(effects.matchedAttempt)
        XCTAssertFalse(effects.shouldClearInput)
    }

    func testStaleCompletionCannotReleaseNewerAttempt() throws {
        var latch = AgentComposerSubmissionLatch()
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        let target = makeTarget(session: session)
        let oldAttempt = try XCTUnwrap(
            latch.begin(target: target, rawDraftSnapshot: "old", attemptID: UUID())
        )
        XCTAssertTrue(latch.cancel(oldAttempt))
        let newAttempt = try XCTUnwrap(
            latch.begin(target: target, rawDraftSnapshot: "new", attemptID: UUID())
        )

        let staleEffects = latch.complete(
            oldAttempt,
            result: .submitted,
            currentTabID: session.tabID,
            currentRawDraft: "new"
        )

        XCTAssertEqual(staleEffects, .stale)
        XCTAssertEqual(latch.activeAttemptID(for: session.tabID), newAttempt.id)
    }

    func testBlockedCompletionCannotOverwriteNewerNotice() throws {
        var latch = AgentComposerSubmissionLatch()
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        let attempt = try XCTUnwrap(
            latch.begin(target: makeTarget(session: session), rawDraftSnapshot: "draft")
        )
        latch.advanceNoticeRevision()

        let effects = latch.complete(
            attempt,
            result: .blocked(message: "older notice"),
            currentTabID: session.tabID,
            currentRawDraft: "draft"
        )

        XCTAssertTrue(effects.matchedAttempt)
        XCTAssertNil(effects.blockedMessage)
    }

    private func makeTarget(session: AgentModeViewModel.TabSession) -> AgentComposerSubmitTarget {
        AgentComposerSubmitTarget(
            tabID: session.tabID,
            route: .createAgentSessionFromSourceTab,
            expectedSourceTabSessionIdentity: ObjectIdentifier(session),
            expectedSourceAgentSessionID: nil,
            expectedPersistentBindingIdentity: nil,
            expectedBindingTransitionGeneration: session.bindingTransitionGeneration,
            expectedRunState: .idle,
            expectedRunID: nil,
            expectedRunAttemptID: nil,
            expectedSubmissionToken: session.composerSubmissionToken,
            expectedInitialStartLocation: .local
        )
    }
}

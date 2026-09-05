import Combine
import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

/// The explicit oversight wake signal for readiness inputs that publish nothing of their own.
///
/// Every input asserted here gates observed status or send-readiness. If one stops firing, a
/// overseen session can look idle to a cross-window observer while it is still committing a terminal
/// turn, draining a steering queue, mid-submission, rebinding, or not yet hydrated.
@MainActor
final class AgentSessionLinkObservationSignalTests: XCTestCase {
    private func makeSession() -> (AgentModeViewModel.TabSession, () -> Int, AnyCancellable) {
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        let counter = Counter()
        let cancellable = session.monitorObservationSignal.sink { _ in counter.value += 1 }
        return (session, { counter.value }, cancellable)
    }

    private final class Counter {
        var value = 0
    }

    private func makeSubmitAttempt(for session: AgentModeViewModel.TabSession) -> AgentComposerSubmitAttempt {
        AgentComposerSubmitAttempt(
            id: UUID(),
            target: AgentComposerSubmitTarget(
                tabID: session.tabID,
                route: .existingAgentSession,
                expectedSourceTabSessionIdentity: ObjectIdentifier(session),
                expectedSourceAgentSessionID: nil,
                expectedPersistentBindingIdentity: nil,
                expectedBindingTransitionGeneration: session.bindingTransitionGeneration,
                expectedRunState: .idle,
                expectedRunID: nil,
                expectedRunAttemptID: nil,
                expectedSubmissionToken: session.composerSubmissionToken,
                expectedInitialStartLocation: nil
            ),
            inputRevision: 0,
            noticeRevision: 0,
            rawDraftSnapshot: ""
        )
    }

    // MARK: - Non-replaying contract

    func testSignalDoesNotReplayToNewSubscribers() {
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        XCTAssertTrue(session.runLifecycle.beginTerminalCommit())

        // A `PassthroughSubject` was chosen over an `@Published` counter precisely so a late
        // subscriber does not immediately receive a stale value and rebuild a snapshot for nothing.
        var received = 0
        let cancellable = session.monitorObservationSignal.sink { _ in received += 1 }
        defer { cancellable.cancel() }
        XCTAssertEqual(received, 0)

        session.runLifecycle.completeTerminalCommit()
        XCTAssertEqual(received, 1)
    }

    func testAcceptedTurnClearsWaitingOnAndPublishesExactlyOnce() throws {
        let (session, count, cancellable) = makeSession()
        defer { cancellable.cancel() }
        session.agentSessionLinkWaitingOn = try XCTUnwrap(DomainAgentSessionWaitingOn(
            summary: "external review",
            declaredAt: Date(timeIntervalSince1970: 1)
        ))

        session.clearAgentSessionLinkWaitingOnAfterAcceptedTurn()
        XCTAssertNil(session.agentSessionLinkWaitingOn)
        XCTAssertEqual(count(), 1)

        session.clearAgentSessionLinkWaitingOnAfterAcceptedTurn()
        XCTAssertEqual(count(), 1)
    }

    // MARK: - Readiness inputs

    /// The terminal-commit phase is owned by `AgentRunAttemptLifecycle`, so this drives the phase
    /// through that owner rather than writing the (now read-only) `TabSession` projection.
    func testTerminalCommitTransitionsWake() {
        let (session, count, cancellable) = makeSession()
        defer { cancellable.cancel() }
        XCTAssertTrue(session.runLifecycle.beginTerminalCommit())
        XCTAssertTrue(session.terminalCommitInProgress)
        XCTAssertEqual(count(), 1)
        // A rejected re-entrant acquire changes nothing, so it must not wake an observer.
        XCTAssertFalse(session.runLifecycle.beginTerminalCommit())
        XCTAssertEqual(count(), 1)
        session.runLifecycle.completeTerminalCommit()
        XCTAssertFalse(session.terminalCommitInProgress)
        XCTAssertEqual(count(), 2)
    }

    /// An aborted commit is the other way the phase clears, and it must wake observers too:
    /// an overseen session that aborts settlement is no longer committing.
    func testAbortedTerminalCommitWakes() {
        let (session, count, cancellable) = makeSession()
        defer { cancellable.cancel() }
        XCTAssertTrue(session.runLifecycle.beginTerminalCommit())
        XCTAssertEqual(count(), 1)
        session.runLifecycle.abortTerminalCommit()
        XCTAssertFalse(session.terminalCommitInProgress)
        XCTAssertEqual(count(), 2)
    }

    func testFollowUpAndInstructionQueuesWake() {
        let (session, count, cancellable) = makeSession()
        defer { cancellable.cancel() }
        session.mcpFollowUpRunPending = true
        XCTAssertEqual(count(), 1)
        session.pendingInstructions.append("do the thing")
        XCTAssertEqual(count(), 2)
        session.pendingInstructions.removeAll()
        XCTAssertEqual(count(), 3)
    }

    func testClaudeSteeringQueueWakes() {
        let (session, count, cancellable) = makeSession()
        defer { cancellable.cancel() }
        session.pendingClaudeSteeringInstructions.append(
            AgentModeViewModel.TabSession.ClaudeSteeringInstruction(
                id: UUID(),
                targetRunID: nil,
                targetRunAttemptID: nil,
                providerText: "steer",
                attachments: [],
                taggedFileAttachments: [],
                draftText: "steer",
                optimisticUserItemID: nil,
                createdAt: Date(timeIntervalSince1970: 0)
            )
        )
        XCTAssertEqual(count(), 1)
        session.pendingClaudeSteeringInstructions.removeAll()
        XCTAssertEqual(count(), 2)
    }

    func testComposerSubmissionInFlightTransitionsWake() {
        let (session, count, cancellable) = makeSession()
        defer { cancellable.cancel() }
        let attempt = makeSubmitAttempt(for: session)
        session.activeComposerSubmitAttempt = attempt
        XCTAssertTrue(session.isComposerSubmissionInFlight)
        XCTAssertEqual(count(), 1)

        // Replacing one in-flight attempt with another does not change what an observer can see.
        session.activeComposerSubmitAttempt = makeSubmitAttempt(for: session)
        XCTAssertEqual(count(), 1)

        session.activeComposerSubmitAttempt = nil
        XCTAssertFalse(session.isComposerSubmissionInFlight)
        XCTAssertEqual(count(), 2)
    }

    func testBindingTransitionAndHydrationWake() {
        let (session, count, cancellable) = makeSession()
        defer { cancellable.cancel() }
        session.hasLoadedPersistedState = true
        XCTAssertEqual(count(), 1)

        _ = session.beginPersistentBindingTransition()
        XCTAssertTrue(session.bindingTransitionInProgress)
        XCTAssertEqual(count(), 2)

        session.installPersistentSessionBinding(
            AgentPersistentSessionBindingIdentity(tabID: session.tabID, sessionID: UUID())
        )
        XCTAssertFalse(session.bindingTransitionInProgress)
        XCTAssertEqual(count(), 3)
    }
}

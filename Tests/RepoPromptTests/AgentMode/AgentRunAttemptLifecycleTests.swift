import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

/// Deterministic unit coverage for the extracted app-host run-attempt
/// lifecycle facade, plus characterization of the `TabSession` forwarding
/// behavior the facade must preserve (run-ID survival across attempt begin,
/// binding-transition invalidation scope, and drain-generation reset).
@MainActor
final class AgentRunAttemptLifecycleTests: XCTestCase {
    private func makeContext(
        tabID: UUID = UUID(),
        persistentSessionID: UUID? = nil,
        bindingTransitionGeneration: UInt64 = 0
    ) -> AgentRunAttemptLifecycle.AttemptContext {
        AgentRunAttemptLifecycle.AttemptContext(
            tabID: tabID,
            persistentSessionID: persistentSessionID,
            persistentBindingGeneration: nil,
            bindingTransitionGeneration: bindingTransitionGeneration,
            turnEpoch: nil
        )
    }

    private func makeRevision(
        ownership: AgentRunOwnership,
        expectedRunID: UUID? = nil
    ) -> AgentRunTerminalCommitRevision {
        AgentRunTerminalCommitRevision(
            commitID: UUID(),
            ownership: ownership,
            terminalState: .completed,
            failureReason: nil,
            expectedRunID: expectedRunID,
            sourceItemsRevision: 0,
            assistantDeltaFlushGeneration: 0,
            providerDrainGeneration: 0,
            mcpPublicationEnvelope: nil,
            successorKind: nil,
            providerSuccessorID: nil
        )
    }

    // MARK: - Attempt begin/end

    func testBeginAttemptCapturesContextResetsTerminalStateAndPreservesRunID() {
        let lifecycle = AgentRunAttemptLifecycle()
        let tabID = UUID()
        let persistentSessionID = UUID()
        let runID = UUID()

        lifecycle.installRunID(runID)
        lifecycle.bumpProviderTerminalDrainGeneration()
        let staleOwnership = lifecycle.beginAttempt(context: makeContext(tabID: tabID))
        lifecycle.stageTerminalRevision(makeRevision(ownership: staleOwnership))
        lifecycle.recordTerminalPublicationResult(.accepted(successorEpoch: nil))
        XCTAssertTrue(lifecycle.beginTerminalCommit())
        lifecycle.completeTerminalCommit()
        lifecycle.bumpProviderTerminalDrainGeneration()

        let ownership = lifecycle.beginAttempt(
            context: makeContext(
                tabID: tabID,
                persistentSessionID: persistentSessionID,
                bindingTransitionGeneration: 3
            )
        )

        XCTAssertEqual(ownership.binding.tabID, tabID)
        XCTAssertEqual(ownership.binding.persistentSessionID, persistentSessionID)
        XCTAssertEqual(ownership.binding.bindingTransitionGeneration, 3)
        XCTAssertEqual(lifecycle.activeOwnership, ownership)
        XCTAssertEqual(lifecycle.liveness?.stage, .starting)
        // The run ID installed before the attempt begins must survive.
        XCTAssertEqual(lifecycle.currentRunID, runID)
        // The transient terminal-settlement cluster resets.
        XCTAssertEqual(lifecycle.providerTerminalDrainGeneration, 0)
        XCTAssertFalse(lifecycle.terminalCommitInProgress)
        XCTAssertNil(lifecycle.lastTerminalCommitRevision)
        XCTAssertNil(lifecycle.lastTerminalPublicationResult)
        XCTAssertNil(lifecycle.terminalResources)
    }

    func testEndAttemptOnlyEndsMatchingOwnershipAndPreservesSettledState() {
        let lifecycle = AgentRunAttemptLifecycle()
        let runID = UUID()
        lifecycle.installRunID(runID)
        let ownership = lifecycle.beginAttempt(context: makeContext())
        let revision = makeRevision(ownership: ownership)
        lifecycle.stageTerminalRevision(revision)
        lifecycle.recordTerminalPublicationResult(.accepted(successorEpoch: nil))

        let staleOwnership = AgentRunOwnership(
            binding: AgentRunBindingIdentity(tabID: UUID(), persistentSessionID: nil)
        )
        XCTAssertFalse(lifecycle.endAttempt(ifCurrent: staleOwnership))
        XCTAssertEqual(lifecycle.activeOwnership, ownership)

        XCTAssertTrue(lifecycle.endAttempt(ifCurrent: ownership))
        XCTAssertNil(lifecycle.activeOwnership)
        XCTAssertNil(lifecycle.liveness)
        // Ending the attempt never implicitly clears settled/terminal state.
        XCTAssertEqual(lifecycle.currentRunID, runID)
        XCTAssertEqual(lifecycle.lastTerminalCommitRevision, revision)
        XCTAssertEqual(lifecycle.lastTerminalPublicationResult, .accepted(successorEpoch: nil))
    }

    func testIsCurrentAttemptValidatesOwnershipAndExpectedRunID() {
        let lifecycle = AgentRunAttemptLifecycle()
        let runID = UUID()
        lifecycle.installRunID(runID)
        let ownership = lifecycle.beginAttempt(context: makeContext())

        XCTAssertTrue(lifecycle.isCurrentAttempt(ownership))
        XCTAssertTrue(lifecycle.isCurrentAttempt(ownership, expectedRunID: runID))
        XCTAssertFalse(lifecycle.isCurrentAttempt(ownership, expectedRunID: UUID()))

        let foreignOwnership = AgentRunOwnership(
            binding: AgentRunBindingIdentity(tabID: UUID(), persistentSessionID: nil)
        )
        XCTAssertFalse(lifecycle.isCurrentAttempt(foreignOwnership))
        XCTAssertFalse(lifecycle.isCurrentAttempt(foreignOwnership, expectedRunID: runID))
    }

    // MARK: - Progress passthrough

    func testProgressPassthroughAcceptsCurrentAndRejectsStaleOwnership() {
        let lifecycle = AgentRunAttemptLifecycle()
        let ownership = lifecycle.beginAttempt(context: makeContext())
        // The tracker stamps `begin` with the current uptime clock, so progress
        // timestamps must be later than that baseline to stay monotonic.
        let base = DispatchTime.now().uptimeNanoseconds

        let accepted = lifecycle.recordProgress(
            ownership: ownership,
            kind: .stageTransition,
            stage: .running,
            timestampUptimeNanoseconds: base + 10
        )
        guard case let .accepted(snapshot) = accepted else {
            return XCTFail("Expected accepted progress, got \(accepted)")
        }
        XCTAssertEqual(snapshot.stage, .running)
        XCTAssertEqual(snapshot.lastRealProgressUptimeNanoseconds, base + 10)

        let staleOwnership = AgentRunOwnership(
            binding: AgentRunBindingIdentity(tabID: UUID(), persistentSessionID: nil)
        )
        let rejected = lifecycle.recordProgress(
            ownership: staleOwnership,
            kind: .providerEvent,
            stage: .running,
            timestampUptimeNanoseconds: base + 20
        )
        guard case .rejected(.staleOwnership) = rejected else {
            return XCTFail("Expected staleOwnership rejection, got \(rejected)")
        }
        XCTAssertEqual(lifecycle.liveness?.stage, .running)
    }

    func testHeartbeatProgressDoesNotAdvanceRealProgressTimestamp() {
        let lifecycle = AgentRunAttemptLifecycle()
        let ownership = lifecycle.beginAttempt(context: makeContext())
        // The tracker stamps `begin` with the current uptime clock, so progress
        // timestamps must be later than that baseline to stay monotonic.
        let base = DispatchTime.now().uptimeNanoseconds
        _ = lifecycle.recordProgress(
            ownership: ownership,
            kind: .providerEvent,
            stage: .running,
            timestampUptimeNanoseconds: base + 10
        )
        let heartbeat = lifecycle.recordProgress(
            ownership: ownership,
            kind: .heartbeat,
            stage: .running,
            timestampUptimeNanoseconds: base + 30
        )
        guard case let .accepted(snapshot) = heartbeat else {
            return XCTFail("Expected accepted heartbeat, got \(heartbeat)")
        }
        XCTAssertEqual(snapshot.lastRealProgressUptimeNanoseconds, base + 10)
        XCTAssertEqual(snapshot.lastHeartbeatUptimeNanoseconds, base + 30)
        XCTAssertEqual(snapshot.lastSignalUptimeNanoseconds, base + 30)
    }

    // MARK: - Run identity

    func testClearRunIDIfCurrentIsStaleSafe() {
        let lifecycle = AgentRunAttemptLifecycle()
        let firstRunID = UUID()
        lifecycle.installRunID(firstRunID)

        // A successor run replaces the identity before the stale cleanup runs.
        let successorRunID = UUID()
        lifecycle.installRunID(successorRunID)

        XCTAssertFalse(lifecycle.clearRunID(ifCurrent: firstRunID))
        XCTAssertEqual(lifecycle.currentRunID, successorRunID)

        XCTAssertTrue(lifecycle.clearRunID(ifCurrent: successorRunID))
        XCTAssertNil(lifecycle.currentRunID)

        lifecycle.installRunID(firstRunID)
        lifecycle.forceClearRunID()
        XCTAssertNil(lifecycle.currentRunID)
    }

    // MARK: - Terminal resources

    func testTerminalResourcesInstallRequiresCurrentOwnershipAndClaimIsExactlyOnce() {
        let lifecycle = AgentRunAttemptLifecycle()
        let ownership = lifecycle.beginAttempt(context: makeContext())
        let staleOwnership = AgentRunOwnership(
            binding: AgentRunBindingIdentity(tabID: UUID(), persistentSessionID: nil)
        )

        lifecycle.installTerminalResources(ownership: staleOwnership) { _ in nil }
        XCTAssertNil(lifecycle.terminalResources)

        var preparedStates: [AgentSessionRunState] = []
        var teardownRuns = 0
        lifecycle.installTerminalResources(ownership: ownership) { terminalState in
            preparedStates.append(terminalState)
            return { teardownRuns += 1 }
        }
        XCTAssertNotNil(lifecycle.terminalResources)

        // A stale-ownership claim leaves the resources installed for the owner.
        XCTAssertNil(lifecycle.claimTerminalTeardown(ownership: staleOwnership, terminalState: .cancelled))
        XCTAssertNotNil(lifecycle.terminalResources)
        XCTAssertEqual(preparedStates, [])

        let teardown = lifecycle.claimTerminalTeardown(ownership: ownership, terminalState: .failed)
        XCTAssertNotNil(teardown)
        XCTAssertEqual(preparedStates, [.failed])
        XCTAssertNil(lifecycle.terminalResources)
        // Claiming prepares but never executes the teardown.
        XCTAssertEqual(teardownRuns, 0)

        // A second claim finds nothing.
        XCTAssertNil(lifecycle.claimTerminalTeardown(ownership: ownership, terminalState: .failed))
    }

    // MARK: - Phased terminal commit

    func testTerminalCommitPhaseIsExclusiveAndPhasesAreIndependent() {
        let lifecycle = AgentRunAttemptLifecycle()
        let ownership = lifecycle.beginAttempt(context: makeContext())

        XCTAssertTrue(lifecycle.beginTerminalCommit())
        XCTAssertFalse(lifecycle.beginTerminalCommit(), "Only one terminal commit phase may be active")

        let revision = makeRevision(ownership: ownership)
        lifecycle.recordTerminalPublicationResult(.rejected(reason: "prior"))
        lifecycle.stageTerminalRevision(revision)
        XCTAssertEqual(lifecycle.lastTerminalCommitRevision, revision)
        XCTAssertNil(
            lifecycle.lastTerminalPublicationResult,
            "Staging a revision clears the prior publication result"
        )
        XCTAssertTrue(lifecycle.terminalCommitInProgress, "Staging must not end the commit phase")

        lifecycle.recordTerminalPublicationResult(.accepted(successorEpoch: nil))
        XCTAssertTrue(lifecycle.terminalCommitInProgress, "Recording a result must not end the commit phase")

        lifecycle.completeTerminalCommit()
        XCTAssertFalse(lifecycle.terminalCommitInProgress)
        XCTAssertEqual(lifecycle.lastTerminalCommitRevision, revision)
        XCTAssertEqual(lifecycle.lastTerminalPublicationResult, .accepted(successorEpoch: nil))
    }

    func testAbortTerminalCommitClearsOnlyThePhaseFlag() {
        let lifecycle = AgentRunAttemptLifecycle()
        let ownership = lifecycle.beginAttempt(context: makeContext())
        let revision = makeRevision(ownership: ownership)
        lifecycle.stageTerminalRevision(revision)
        lifecycle.recordTerminalPublicationResult(.stale)
        XCTAssertTrue(lifecycle.beginTerminalCommit())

        lifecycle.abortTerminalCommit()

        XCTAssertFalse(lifecycle.terminalCommitInProgress)
        XCTAssertEqual(lifecycle.lastTerminalCommitRevision, revision)
        XCTAssertEqual(lifecycle.lastTerminalPublicationResult, .stale)
    }

    func testBindingTransitionInvalidationClearsOnlyRevisionAndResult() {
        let lifecycle = AgentRunAttemptLifecycle()
        let runID = UUID()
        lifecycle.installRunID(runID)
        let ownership = lifecycle.beginAttempt(context: makeContext())
        lifecycle.bumpProviderTerminalDrainGeneration()
        lifecycle.stageTerminalRevision(makeRevision(ownership: ownership))
        lifecycle.recordTerminalPublicationResult(.accepted(successorEpoch: nil))
        XCTAssertTrue(lifecycle.beginTerminalCommit())

        lifecycle.invalidateTerminalRevisionForBindingTransition()

        XCTAssertNil(lifecycle.lastTerminalCommitRevision)
        XCTAssertNil(lifecycle.lastTerminalPublicationResult)
        XCTAssertEqual(lifecycle.activeOwnership, ownership)
        XCTAssertEqual(lifecycle.currentRunID, runID)
        XCTAssertEqual(lifecycle.providerTerminalDrainGeneration, 1)
        XCTAssertTrue(
            lifecycle.terminalCommitInProgress,
            "Rebind invalidation must not release an in-flight terminal commit phase"
        )

        // Characterize the existing reentrant order: a publication result
        // recorded after invalidation is stored without restoring the revision.
        lifecycle.recordTerminalPublicationResult(.rejected(reason: "activation_replaced"))
        XCTAssertNil(lifecycle.lastTerminalCommitRevision)
        XCTAssertEqual(lifecycle.lastTerminalPublicationResult, .rejected(reason: "activation_replaced"))
    }

    // MARK: - TabSession forwarding characterization

    func testTabSessionBeginRunAttemptPreservesRunIDAndResetsDrainGeneration() {
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        let runID = UUID()
        session.installRunID(runID)

        let first = session.beginRunAttempt(source: "test.forwarding")
        for _ in 0 ..< 3 {
            session.bumpProviderTerminalDrainGeneration()
        }
        XCTAssertEqual(session.providerTerminalDrainGeneration, 3)
        XCTAssertTrue(session.isCurrentRunAttempt(first, expectedRunID: runID))
        XCTAssertTrue(session.endRunAttempt(ifCurrent: first, source: "test.forwarding"))

        let second = session.beginRunAttempt(source: "test.forwarding")
        XCTAssertEqual(session.providerTerminalDrainGeneration, 0)
        XCTAssertEqual(session.runID, runID, "beginRunAttempt must preserve the installed run ID")
        XCTAssertEqual(session.activeRunAttemptID, second.attemptID)
        XCTAssertNotEqual(first.attemptID, second.attemptID)
    }

    func testTabSessionPersistentBindingTransitionInvalidatesSettledRevisionOnly() {
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        let runID = UUID()
        session.installRunID(runID)
        let ownership = session.beginRunAttempt(source: "test.rebind")
        session.runLifecycle.stageTerminalRevision(makeRevision(ownership: ownership, expectedRunID: runID))
        session.runLifecycle.recordTerminalPublicationResult(.accepted(successorEpoch: nil))

        _ = session.beginPersistentBindingTransition()

        XCTAssertNil(session.lastTerminalCommitRevision)
        XCTAssertNil(session.lastTerminalPublicationResult)
        XCTAssertEqual(session.runID, runID)
        XCTAssertEqual(session.activeRunOwnership, ownership)
        XCTAssertFalse(
            session.isCurrentRunAttemptForCurrentBinding(ownership),
            "An in-progress binding transition must reject binding-scoped currency"
        )
    }

    func testTabSessionClearRunIDIfCurrentDoesNotClearSuccessorRun() {
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        let firstRunID = UUID()
        session.installRunID(firstRunID)
        let successorRunID = UUID()
        session.installRunID(successorRunID)

        XCTAssertFalse(session.clearRunID(ifCurrent: firstRunID))
        XCTAssertEqual(session.runID, successorRunID)
        XCTAssertTrue(session.clearRunID(ifCurrent: successorRunID))
        XCTAssertNil(session.runID)
    }
}

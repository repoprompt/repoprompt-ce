@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

@MainActor
final class AgentSelfCompactTerminalSchedulerTests: XCTestCase {
    @MainActor private final class BindGate {
        private var entered = false
        private var enteredWaiter: CheckedContinuation<Void, Never>?
        private var releaseWaiter: CheckedContinuation<Void, Never>?

        func wait() async {
            entered = true
            enteredWaiter?.resume()
            enteredWaiter = nil
            await withCheckedContinuation { releaseWaiter = $0 }
        }

        func waitUntilEntered() async {
            if entered { return }
            await withCheckedContinuation { enteredWaiter = $0 }
        }

        func release() {
            releaseWaiter?.resume()
            releaseWaiter = nil
        }
    }

    @MainActor private final class Fake {
        var state = AgentSelfCompactState()
        var endpointIsCurrent = true
        var teardownIsSettled = true
        var toolsAreDrained = true
        var support: AgentSessionLinkCompactSupport = .claudeCode
        var dispatched = 0
        var polls = 0
        var onPoll: (() -> Void)?
        let runID = UUID()
        let attemptID = UUID()
        let endpoint = AgentSelfCompactOwner(
            windowID: 1,
            workspaceID: UUID(),
            tabID: UUID(),
            sessionID: UUID(),
            persistentBindingGeneration: UUID(),
            bindingTransitionGeneration: 1,
            runID: UUID(),
            runAttemptID: UUID()
        )

        func scheduler() -> AgentSelfCompactTerminalScheduler {
            AgentSelfCompactTerminalScheduler(
                load: { self.state },
                store: { self.state = $0 },
                isCurrentOwner: { _ in self.endpointIsCurrent },
                hasActiveTools: { _ in !self.toolsAreDrained },
                support: { self.support },
                dispatch: { _, _, stillAdmissible in
                    guard stillAdmissible() else { return false }
                    self.dispatched += 1
                    return true
                },
                maximumDrainPolls: 50,
                sleep: { _ in
                    self.polls += 1
                    self.onPoll?()
                }
            )
        }

        func arm() {
            var owner = endpoint
            owner = AgentSelfCompactOwner(
                windowID: owner.windowID,
                workspaceID: owner.workspaceID,
                tabID: owner.tabID,
                sessionID: owner.sessionID,
                persistentBindingGeneration: owner.persistentBindingGeneration,
                bindingTransitionGeneration: owner.bindingTransitionGeneration,
                runID: runID,
                runAttemptID: attemptID
            )
            _ = state.reserve(note: "resume here", idempotencyKey: "key", maximumNoteUTF8Bytes: AgentSessionSelfCompactNotePolicy.fallbackMaximumUTF8Bytes, owner: owner)
            state.active?.admittedSupport = .claudeCode
        }
    }

    private func drain() async {
        for _ in 0 ..< 20 {
            await Task.yield()
        }
    }

    func testAcceptedCommitDispatchesOnlyFromWorkerAndDuplicateDoesNotDispatchTwice() async {
        let fake = Fake()
        fake.arm()
        let scheduler = fake.scheduler()
        scheduler.terminalSettled(
            runID: fake.runID, runAttemptID: fake.attemptID,
            terminalState: .completed, publication: .accepted(successorEpoch: nil),
            successorClaimed: false, teardownSettled: { fake.teardownIsSettled }
        )
        XCTAssertEqual(fake.dispatched, 0, "terminal hook must not call provider inline")
        scheduler.terminalSettled(
            runID: fake.runID, runAttemptID: fake.attemptID,
            terminalState: .completed, publication: .accepted(successorEpoch: nil),
            successorClaimed: false, teardownSettled: { fake.teardownIsSettled }
        )
        await drain()
        XCTAssertEqual(fake.dispatched, 1)
        XCTAssertEqual(fake.state.active?.phase, .awaitingCompactTurn)
    }

    func testRejectedStaleSuccessorAndWrongAttemptNeverDispatch() async {
        for publication in [
            AgentRunTerminalPublicationResult.rejected(reason: "no"),
            .stale,
            .accepted(successorEpoch: nil)
        ] {
            let fake = Fake()
            fake.arm()
            let scheduler = fake.scheduler()
            scheduler.terminalSettled(
                runID: fake.runID,
                runAttemptID: publication == .accepted(successorEpoch: nil) ? UUID() : fake.attemptID,
                terminalState: .completed,
                publication: publication,
                successorClaimed: false,
                teardownSettled: { true }
            )
            await drain()
            XCTAssertEqual(fake.dispatched, 0)
        }
        let fake = Fake()
        fake.arm()
        let scheduler = fake.scheduler()
        scheduler.terminalSettled(
            runID: fake.runID, runAttemptID: fake.attemptID,
            terminalState: .completed, publication: .accepted(successorEpoch: nil),
            successorClaimed: true, teardownSettled: { true }
        )
        await drain()
        XCTAssertEqual(fake.dispatched, 0)
        XCTAssertEqual(fake.state.latest?.outcome, .cancelled)
    }

    func testRejectedPublicationCanRetryButStaleCancels() async {
        let fake = Fake()
        fake.arm()
        let scheduler = fake.scheduler()
        scheduler.terminalSettled(
            runID: fake.runID, runAttemptID: fake.attemptID,
            terminalState: .completed, publication: .rejected(reason: "transient"),
            successorClaimed: false, teardownSettled: { true }
        )
        XCTAssertEqual(fake.state.active?.phase, .scheduled)
        XCTAssertEqual(fake.dispatched, 0)
        scheduler.terminalSettled(
            runID: fake.runID, runAttemptID: fake.attemptID,
            terminalState: .completed, publication: .accepted(successorEpoch: nil),
            successorClaimed: false, teardownSettled: { true }
        )
        await drain()
        XCTAssertEqual(fake.dispatched, 1)

        let stale = Fake()
        stale.arm()
        stale.scheduler().terminalSettled(
            runID: stale.runID, runAttemptID: stale.attemptID,
            terminalState: .completed, publication: .stale,
            successorClaimed: false, teardownSettled: { true }
        )
        XCTAssertEqual(stale.state.latest?.outcome, .cancelled)
        XCTAssertEqual(stale.dispatched, 0)

        let abandoned = Fake()
        abandoned.arm()
        abandoned.scheduler().terminalSettled(
            runID: abandoned.runID, runAttemptID: abandoned.attemptID,
            terminalState: .completed, publication: .rejected(reason: "never retried"),
            successorClaimed: false, teardownSettled: { true }
        )
        for _ in 0 ..< 120 {
            await Task.yield()
        }
        XCTAssertNil(abandoned.state.active)
        XCTAssertEqual(abandoned.state.latest?.outcome, .failed)
        XCTAssertEqual(abandoned.dispatched, 0)
    }

    func testEndpointAndSupportAreRecheckedAfterTeardown() async {
        for invalidateEndpoint in [false, true] {
            let fake = Fake()
            fake.arm()
            fake.teardownIsSettled = false
            fake.onPoll = {
                fake.teardownIsSettled = true
                if invalidateEndpoint {
                    fake.endpointIsCurrent = false
                } else {
                    fake.support = .notSupported
                }
            }
            let scheduler = fake.scheduler()
            scheduler.terminalSettled(
                runID: fake.runID, runAttemptID: fake.attemptID,
                terminalState: .completed, publication: .accepted(successorEpoch: nil),
                successorClaimed: false, teardownSettled: { fake.teardownIsSettled }
            )
            await drain()
            XCTAssertEqual(fake.dispatched, 0)
            XCTAssertNil(fake.state.active)
            XCTAssertEqual(fake.state.latest?.outcome, invalidateEndpoint ? .cancelled : .failed)
        }
    }

    func testAcceptedLocalInputAndSupportChangeCancelBeforeDispatch() async {
        let fake = Fake()
        fake.arm()
        fake.teardownIsSettled = false
        let scheduler = fake.scheduler()
        scheduler.terminalSettled(
            runID: fake.runID, runAttemptID: fake.attemptID,
            terminalState: .completed, publication: .accepted(successorEpoch: nil),
            successorClaimed: false, teardownSettled: { fake.teardownIsSettled }
        )
        scheduler.cancelForAcceptedLocalInput()
        fake.teardownIsSettled = true
        await drain()
        XCTAssertEqual(fake.dispatched, 0)
        XCTAssertEqual(fake.state.latest?.outcome, .cancelled)

        let changed = Fake()
        changed.arm()
        changed.support = .codex
        let other = changed.scheduler()
        other.terminalSettled(
            runID: changed.runID, runAttemptID: changed.attemptID,
            terminalState: .completed, publication: .accepted(successorEpoch: nil),
            successorClaimed: false, teardownSettled: { true }
        )
        await drain()
        XCTAssertEqual(changed.dispatched, 0)
        XCTAssertEqual(changed.state.latest?.outcome, .failed)
    }

    func testACPBindAfterPipelineStartCanFollowAwaitingCompactTurn() async throws {
        let fake = Fake()
        fake.arm()
        fake.state.active?.admittedSupport = .acpAdvertisedCommand
        fake.support = .acpAdvertisedCommand
        let requestID = try XCTUnwrap(fake.state.active?.id)
        let runID = UUID()
        let runAttemptID = UUID()
        let gate = BindGate()
        let completion = AgentSelfCompactNativeCompletionCoordinator(
            load: { fake.state },
            store: { fake.state = $0 },
            isCurrentOwner: { _ in true },
            dispatchNote: { _, _ in false }
        )
        let bindAfterPreparation = Task { @MainActor in
            await gate.wait()
            return completion.bindCompact(
                .init(requestID: requestID, stage: .compact),
                runID: runID, runAttemptID: runAttemptID
            )
        }
        await gate.waitUntilEntered()
        fake.scheduler().terminalSettled(
            runID: fake.runID, runAttemptID: fake.attemptID,
            terminalState: .completed, publication: .accepted(successorEpoch: nil),
            successorClaimed: false, teardownSettled: { true }
        )
        await drain()
        XCTAssertEqual(fake.dispatched, 1)
        XCTAssertEqual(fake.state.active?.phase, .awaitingCompactTurn)
        gate.release()
        let bound = await bindAfterPreparation.value
        XCTAssertTrue(bound, "ACP physical command must still bind after pipeline-start receipt")
        XCTAssertEqual(fake.state.active?.compactRunID, runID)
        XCTAssertEqual(fake.state.active?.compactRunAttemptID, runAttemptID)
        completion.cancelRuntimeWork()
    }

    func testACPAdvertisedCommandDispatchesTheCompactTurn() async {
        let fake = Fake()
        fake.arm()
        fake.state.active?.admittedSupport = .acpAdvertisedCommand
        fake.support = .acpAdvertisedCommand
        fake.scheduler().terminalSettled(
            runID: fake.runID, runAttemptID: fake.attemptID,
            terminalState: .completed, publication: .accepted(successorEpoch: nil),
            successorClaimed: false, teardownSettled: { true }
        )
        await drain()
        XCTAssertEqual(fake.dispatched, 1)
        XCTAssertEqual(fake.state.active?.phase, .awaitingCompactTurn)
        XCTAssertNil(fake.state.latest)
    }

    func testTeardownAndToolDrainAreBoundedWithoutCancellingForeignTools() async {
        let fake = Fake()
        fake.arm()
        fake.toolsAreDrained = false
        let scheduler = fake.scheduler()
        scheduler.terminalSettled(
            runID: fake.runID, runAttemptID: fake.attemptID,
            terminalState: .completed, publication: .accepted(successorEpoch: nil),
            successorClaimed: false, teardownSettled: { true }
        )
        for _ in 0 ..< 100 {
            await Task.yield()
        }
        XCTAssertEqual(fake.dispatched, 0)
        XCTAssertNil(fake.state.active)
        XCTAssertEqual(fake.state.latest?.outcome, .failed)
        XCTAssertLessThanOrEqual(fake.polls, 50)
        XCTAssertFalse(fake.toolsAreDrained, "worker must not cancel another tool")

        let teardown = Fake()
        teardown.arm()
        teardown.teardownIsSettled = false
        teardown.scheduler().terminalSettled(
            runID: teardown.runID, runAttemptID: teardown.attemptID,
            terminalState: .completed, publication: .accepted(successorEpoch: nil),
            successorClaimed: false, teardownSettled: { teardown.teardownIsSettled }
        )
        for _ in 0 ..< 100 {
            await Task.yield()
        }
        XCTAssertNil(teardown.state.active)
        XCTAssertEqual(teardown.dispatched, 0)
        XCTAssertLessThanOrEqual(teardown.polls, 50)
    }
}

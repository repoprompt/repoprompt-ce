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
        var onSupport: (() -> Void)?
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
                support: {
                    self.onSupport?()
                    return self.support
                },
                dispatch: { _, _, stillAdmissible, _ in
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

    func testToolStartingDuringSupportUsesRemainingDrainBudget() async {
        let fake = Fake()
        fake.arm()
        fake.onSupport = { fake.toolsAreDrained = false }
        fake.onPoll = { if fake.polls == 3 { fake.toolsAreDrained = true } }
        let worker = fake.scheduler().terminalSettled(
            runID: fake.runID, runAttemptID: fake.attemptID,
            terminalState: .completed, publication: .accepted(successorEpoch: nil),
            successorClaimed: false, teardownSettled: { fake.teardownIsSettled }
        )
        await worker?.value
        XCTAssertEqual(fake.polls, 3)
        XCTAssertEqual(fake.dispatched, 1)
    }

    func testToolStartingDuringSupportTimesOutWithoutDispatch() async {
        let fake = Fake()
        fake.arm()
        fake.onSupport = { fake.toolsAreDrained = false }
        let worker = fake.scheduler().terminalSettled(
            runID: fake.runID, runAttemptID: fake.attemptID,
            terminalState: .completed, publication: .accepted(successorEpoch: nil),
            successorClaimed: false, teardownSettled: { fake.teardownIsSettled }
        )
        await worker?.value
        XCTAssertEqual(fake.polls, 50)
        XCTAssertEqual(fake.dispatched, 0)
        XCTAssertEqual(fake.state.latest?.outcome, .failed)
    }

    func testToolAfterSupportDoesNotGetASecondDrainBudget() async {
        let fake = Fake()
        fake.arm()
        fake.toolsAreDrained = false
        fake.onPoll = { if fake.polls == 48 { fake.toolsAreDrained = true } }
        fake.onSupport = { fake.toolsAreDrained = false }
        let worker = fake.scheduler().terminalSettled(
            runID: fake.runID, runAttemptID: fake.attemptID,
            terminalState: .completed, publication: .accepted(successorEpoch: nil),
            successorClaimed: false, teardownSettled: { fake.teardownIsSettled }
        )
        await worker?.value
        XCTAssertEqual(fake.polls, 50)
        XCTAssertEqual(fake.dispatched, 0)
        XCTAssertEqual(fake.state.latest?.outcome, .failed)
    }

    func testToolAppearingDuringDispatchPreparationRefusesNativeStart() async {
        let fake = Fake()
        fake.arm()
        let scheduler = AgentSelfCompactTerminalScheduler(
            load: { fake.state }, store: { fake.state = $0 },
            isCurrentOwner: { _ in true }, hasActiveTools: { _ in !fake.toolsAreDrained },
            support: { .claudeCode },
            dispatch: { _, _, stillAdmissible, _ in
                XCTAssertTrue(stillAdmissible())
                fake.toolsAreDrained = false // e.g. while required save is suspended
                XCTAssertFalse(stillAdmissible())
                return false
            }
        )
        let worker = scheduler.terminalSettled(
            runID: fake.runID, runAttemptID: fake.attemptID,
            terminalState: .completed, publication: .accepted(successorEpoch: nil),
            successorClaimed: false, teardownSettled: { true }
        )
        await worker?.value
        XCTAssertEqual(fake.state.latest?.outcome, .failed)
        XCTAssertEqual(fake.dispatched, 0)
    }

    func testSupportReturningAfterOriginalDeadlineCannotStartCompact() async {
        let fake = Fake()
        fake.arm()
        var instant = ContinuousClock.now
        let scheduler = AgentSelfCompactTerminalScheduler(
            load: { fake.state }, store: { fake.state = $0 }, isCurrentOwner: { _ in true },
            hasActiveTools: { _ in false },
            support: { instant = instant.advanced(by: .seconds(6))
                return .claudeCode
            },
            dispatch: { _, _, _, _ in XCTFail("expired drain must not dispatch")
                return true
            },
            maximumDrainPolls: 50, now: { instant }, sleep: { _ in }
        )
        let worker = scheduler.terminalSettled(
            runID: fake.runID, runAttemptID: fake.attemptID,
            terminalState: .completed, publication: .accepted(successorEpoch: nil),
            successorClaimed: false, teardownSettled: { true }
        )
        await worker?.value
        XCTAssertEqual(fake.state.latest?.outcome, .failed)
    }

    func testPhysicalStartFenceRejectsLateToolAndExpiredDeadline() async {
        let fake = Fake()
        fake.arm()
        var instant = ContinuousClock.now
        var captured: (@MainActor () -> Bool)?
        let scheduler = AgentSelfCompactTerminalScheduler(
            load: { fake.state }, store: { fake.state = $0 }, isCurrentOwner: { _ in true },
            hasActiveTools: { _ in !fake.toolsAreDrained }, support: { .claudeCode },
            dispatch: { _, _, _, physicalStartIsSafe in captured = physicalStartIsSafe
                return true
            },
            maximumDrainPolls: 50, now: { instant }, sleep: { _ in }
        )
        let worker = scheduler.terminalSettled(
            runID: fake.runID, runAttemptID: fake.attemptID,
            terminalState: .completed, publication: .accepted(successorEpoch: nil),
            successorClaimed: false, teardownSettled: { true }
        )
        await worker?.value
        XCTAssertTrue(captured?() == true)
        fake.toolsAreDrained = false
        XCTAssertFalse(captured?() ?? true)
        fake.toolsAreDrained = true
        instant = instant.advanced(by: .seconds(6))
        XCTAssertFalse(captured?() ?? true)
    }

    func testAcceptedCommitDispatchesOnlyFromWorkerAndDuplicateDoesNotDispatchTwice() async {
        let fake = Fake()
        fake.arm()
        let scheduler = fake.scheduler()
        let worker = scheduler.terminalSettled(
            runID: fake.runID, runAttemptID: fake.attemptID,
            terminalState: .completed, publication: .accepted(successorEpoch: nil),
            successorClaimed: false, teardownSettled: { fake.teardownIsSettled }
        )
        XCTAssertEqual(fake.dispatched, 0, "terminal hook must not call provider inline")
        let duplicate = scheduler.terminalSettled(
            runID: fake.runID, runAttemptID: fake.attemptID,
            terminalState: .completed, publication: .accepted(successorEpoch: nil),
            successorClaimed: false, teardownSettled: { fake.teardownIsSettled }
        )
        XCTAssertNil(duplicate)
        await worker?.value
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
            let worker = scheduler.terminalSettled(
                runID: fake.runID,
                runAttemptID: publication == .accepted(successorEpoch: nil) ? UUID() : fake.attemptID,
                terminalState: .completed,
                publication: publication,
                successorClaimed: false,
                teardownSettled: { true }
            )
            await worker?.value
            XCTAssertEqual(fake.dispatched, 0)
        }
        let fake = Fake()
        fake.arm()
        let scheduler = fake.scheduler()
        let worker = scheduler.terminalSettled(
            runID: fake.runID, runAttemptID: fake.attemptID,
            terminalState: .completed, publication: .accepted(successorEpoch: nil),
            successorClaimed: true, teardownSettled: { true }
        )
        await worker?.value
        XCTAssertEqual(fake.dispatched, 0)
        XCTAssertEqual(fake.state.latest?.outcome, .cancelled)
    }

    func testRejectedPublicationCanRetryButStaleCancels() async {
        let fake = Fake()
        fake.arm()
        let scheduler = fake.scheduler()
        let rejected = scheduler.terminalSettled(
            runID: fake.runID, runAttemptID: fake.attemptID,
            terminalState: .completed, publication: .rejected(reason: "transient"),
            successorClaimed: false, teardownSettled: { true }
        )
        XCTAssertEqual(fake.state.active?.phase, .scheduled)
        XCTAssertEqual(fake.dispatched, 0)
        let worker = scheduler.terminalSettled(
            runID: fake.runID, runAttemptID: fake.attemptID,
            terminalState: .completed, publication: .accepted(successorEpoch: nil),
            successorClaimed: false, teardownSettled: { true }
        )
        await worker?.value
        await rejected?.value
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
        let abandonedWorker = abandoned.scheduler().terminalSettled(
            runID: abandoned.runID, runAttemptID: abandoned.attemptID,
            terminalState: .completed, publication: .rejected(reason: "never retried"),
            successorClaimed: false, teardownSettled: { true }
        )
        await abandonedWorker?.value
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
            let worker = scheduler.terminalSettled(
                runID: fake.runID, runAttemptID: fake.attemptID,
                terminalState: .completed, publication: .accepted(successorEpoch: nil),
                successorClaimed: false, teardownSettled: { fake.teardownIsSettled }
            )
            await worker?.value
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
        let worker = scheduler.terminalSettled(
            runID: fake.runID, runAttemptID: fake.attemptID,
            terminalState: .completed, publication: .accepted(successorEpoch: nil),
            successorClaimed: false, teardownSettled: { fake.teardownIsSettled }
        )
        scheduler.cancelForAcceptedLocalInput()
        fake.teardownIsSettled = true
        await worker?.value
        XCTAssertEqual(fake.dispatched, 0)
        XCTAssertEqual(fake.state.latest?.outcome, .cancelled)

        let changed = Fake()
        changed.arm()
        changed.support = .codex
        let other = changed.scheduler()
        let changedWorker = other.terminalSettled(
            runID: changed.runID, runAttemptID: changed.attemptID,
            terminalState: .completed, publication: .accepted(successorEpoch: nil),
            successorClaimed: false, teardownSettled: { true }
        )
        await changedWorker?.value
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
        let worker = fake.scheduler().terminalSettled(
            runID: fake.runID, runAttemptID: fake.attemptID,
            terminalState: .completed, publication: .accepted(successorEpoch: nil),
            successorClaimed: false, teardownSettled: { true }
        )
        await worker?.value
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
        let worker = fake.scheduler().terminalSettled(
            runID: fake.runID, runAttemptID: fake.attemptID,
            terminalState: .completed, publication: .accepted(successorEpoch: nil),
            successorClaimed: false, teardownSettled: { true }
        )
        await worker?.value
        XCTAssertEqual(fake.dispatched, 1)
        XCTAssertEqual(fake.state.active?.phase, .awaitingCompactTurn)
        XCTAssertNil(fake.state.latest)
    }

    func testTeardownAndToolDrainAreBoundedWithoutCancellingForeignTools() async {
        let fake = Fake()
        fake.arm()
        fake.toolsAreDrained = false
        let scheduler = fake.scheduler()
        let worker = scheduler.terminalSettled(
            runID: fake.runID, runAttemptID: fake.attemptID,
            terminalState: .completed, publication: .accepted(successorEpoch: nil),
            successorClaimed: false, teardownSettled: { true }
        )
        await worker?.value
        XCTAssertEqual(fake.dispatched, 0)
        XCTAssertNil(fake.state.active)
        XCTAssertEqual(fake.state.latest?.outcome, .failed)
        XCTAssertLessThanOrEqual(fake.polls, 50)
        XCTAssertFalse(fake.toolsAreDrained, "worker must not cancel another tool")

        let teardown = Fake()
        teardown.arm()
        teardown.teardownIsSettled = false
        let teardownWorker = teardown.scheduler().terminalSettled(
            runID: teardown.runID, runAttemptID: teardown.attemptID,
            terminalState: .completed, publication: .accepted(successorEpoch: nil),
            successorClaimed: false, teardownSettled: { teardown.teardownIsSettled }
        )
        await teardownWorker?.value
        XCTAssertNil(teardown.state.active)
        XCTAssertEqual(teardown.dispatched, 0)
        XCTAssertLessThanOrEqual(teardown.polls, 50)
    }
}

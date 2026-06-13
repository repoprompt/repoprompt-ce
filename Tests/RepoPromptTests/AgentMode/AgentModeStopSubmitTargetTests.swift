import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPrompt

@MainActor
final class AgentModeStopSubmitTargetTests: XCTestCase {
    func testComposerCancelTargetUsesExplicitTabSessionIdentity() throws {
        let vm = makeViewModel()
        let runningTabID = UUID()
        let idleTabID = UUID()
        vm.ensureSession(for: runningTabID)
        vm.ensureSession(for: idleTabID)
        let runningSession = try XCTUnwrap(vm.sessions[runningTabID])
        let idleSession = try XCTUnwrap(vm.sessions[idleTabID])
        let runID = UUID()
        let agentSessionID = UUID()
        let attemptID = UUID()
        runningSession.runState = .running
        runningSession.runID = runID
        runningSession.testInstallPersistentSessionBinding(sessionID: agentSessionID)
        runningSession.beginRunAttempt(source: "test", attemptID: attemptID)
        idleSession.runState = .idle

        // Simulate mixed props: global state is running, but the explicit composer tab is idle.
        vm.runState = .running

        XCTAssertNil(vm.makeComposerProps(tabID: idleTabID).cancelTarget)
        let runningTarget = vm.makeComposerProps(tabID: runningTabID).cancelTarget
        XCTAssertEqual(runningTarget?.tabID, runningTabID)
        XCTAssertEqual(runningTarget?.expectedRunID, runID)
        XCTAssertEqual(runningTarget?.expectedActiveAgentSessionID, agentSessionID)
        XCTAssertEqual(runningTarget?.expectedRunAttemptID, attemptID)
    }

    func testGuardedCancelRoutesToRenderTimeTargetTabWhenCurrentTabChanged() async throws {
        var cancelledRunIDs: [UUID] = []
        let vm = makeViewModel { runID, _ in
            cancelledRunIDs.append(runID)
            return 0
        }
        let targetTabID = UUID()
        let otherTabID = UUID()
        vm.ensureSession(for: targetTabID)
        vm.ensureSession(for: otherTabID)
        let targetSession = try XCTUnwrap(vm.sessions[targetTabID])
        let otherSession = try XCTUnwrap(vm.sessions[otherTabID])
        let targetRunID = UUID()
        let otherRunID = UUID()
        targetSession.runState = .running
        targetSession.runID = targetRunID
        targetSession.testInstallPersistentSessionBinding(sessionID: UUID())
        targetSession.beginRunAttempt(source: "test")
        otherSession.runState = .running
        otherSession.runID = otherRunID
        otherSession.testInstallPersistentSessionBinding(sessionID: UUID())
        otherSession.beginRunAttempt(source: "test")
        let cancelTarget = vm.makeRunCancelTarget(tabID: targetTabID, session: targetSession)
        vm.test_setCurrentTabIDOverride(otherTabID)
        defer { vm.test_setCurrentTabIDOverride(nil) }

        let accepted = await vm.cancelAgentRun(target: cancelTarget, completion: .terminalPublished)

        XCTAssertTrue(accepted)
        XCTAssertEqual(cancelledRunIDs, [targetRunID])
        XCTAssertEqual(targetSession.runState, .cancelled)
        XCTAssertEqual(otherSession.runState, .running)
    }

    func testGuardedCancelRejectsStaleTargetAfterNewRunStarts() async throws {
        var cancelledRunIDs: [UUID] = []
        let vm = makeViewModel { runID, _ in
            cancelledRunIDs.append(runID)
            return 0
        }
        let tabID = UUID()
        vm.ensureSession(for: tabID)
        let session = try XCTUnwrap(vm.sessions[tabID])
        session.runState = .running
        session.runID = UUID()
        session.testInstallPersistentSessionBinding(sessionID: UUID())
        session.beginRunAttempt(source: "test")
        let staleTarget = vm.makeRunCancelTarget(tabID: tabID, session: session)
        let newerRunID = UUID()
        session.runID = newerRunID

        let accepted = await vm.cancelAgentRun(target: staleTarget, completion: .terminalPublished)

        XCTAssertFalse(accepted)
        XCTAssertEqual(session.runState, .running)
        XCTAssertTrue(cancelledRunIDs.isEmpty)
    }

    func testGuardedCancelRejectsStaleTargetAfterAgentSessionReplacement() async throws {
        var cancelledRunIDs: [UUID] = []
        let vm = makeViewModel { runID, _ in
            cancelledRunIDs.append(runID)
            return 0
        }
        let tabID = UUID()
        vm.ensureSession(for: tabID)
        let session = try XCTUnwrap(vm.sessions[tabID])
        session.runState = .running
        session.runID = UUID()
        session.testInstallPersistentSessionBinding(sessionID: UUID())
        session.beginRunAttempt(source: "test")
        let staleTarget = vm.makeRunCancelTarget(tabID: tabID, session: session)
        session.testInstallPersistentSessionBinding(sessionID: UUID())

        let accepted = await vm.cancelAgentRun(target: staleTarget, completion: .terminalPublished)

        XCTAssertFalse(accepted)
        XCTAssertEqual(session.runState, .running)
        XCTAssertTrue(cancelledRunIDs.isEmpty)
    }

    func testGuardedCancelRejectsStaleTargetAfterRunAttemptRotation() async throws {
        var cancelledRunIDs: [UUID] = []
        let vm = makeViewModel { runID, _ in
            cancelledRunIDs.append(runID)
            return 0
        }
        let tabID = UUID()
        vm.ensureSession(for: tabID)
        let session = try XCTUnwrap(vm.sessions[tabID])
        session.runState = .running
        session.runID = UUID()
        session.testInstallPersistentSessionBinding(sessionID: UUID())
        session.beginRunAttempt(source: "test")
        let staleTarget = vm.makeRunCancelTarget(tabID: tabID, session: session)
        session.beginRunAttempt(source: "test.rotated")

        let accepted = await vm.cancelAgentRun(target: staleTarget, completion: .terminalPublished)

        XCTAssertFalse(accepted)
        XCTAssertEqual(session.runState, .running)
        XCTAssertTrue(cancelledRunIDs.isEmpty)
    }

    func testGuardedSubmitRoutesToRenderTimeTargetTabWhenCurrentTabChanged() async throws {
        let vm = makeViewModel()
        let targetTabID = UUID()
        let otherTabID = UUID()
        vm.ensureSession(for: targetTabID)
        vm.ensureSession(for: otherTabID)
        let targetSession = try XCTUnwrap(vm.sessions[targetTabID])
        let otherSession = try XCTUnwrap(vm.sessions[otherTabID])
        targetSession.hasLoadedPersistedState = true
        otherSession.hasLoadedPersistedState = true
        targetSession.selectedAgent = .codexExec
        otherSession.selectedAgent = .codexExec
        targetSession.testInstallPersistentSessionBinding(sessionID: UUID())
        otherSession.testInstallPersistentSessionBinding(sessionID: UUID())
        let target = try XCTUnwrap(vm.makeComposerSubmitTarget(tabID: targetTabID, session: targetSession))
        XCTAssertEqual(target.route, .existingAgentSession)
        vm.test_setCurrentTabIDOverride(otherTabID)
        defer { vm.test_setCurrentTabIDOverride(nil) }

        let result = await vm.submitUserTurnCreatingSessionIfNeeded(
            text: "send to rendered tab",
            target: target,
            createAndActivateSessionTab: {
                XCTFail("Existing-session submit should not create a new tab")
                return nil
            }
        )

        XCTAssertEqual(result, .submitted)
        XCTAssertEqual(targetSession.items.filter { $0.kind == .user }.map(\.text), ["send to rendered tab"])
        XCTAssertTrue(otherSession.items.isEmpty)
    }

    func testGuardedExistingSessionSubmitAcceptsLiveRunStartedAfterTargetCaptureExactlyOnce() async throws {
        let recorder = StopSubmitSendRecorder()
        let controller = StopSubmitNoopCodexController(recorder: recorder, hasActiveThread: true)
        let vm = makeViewModel(codexController: controller)
        let tabID = UUID()
        vm.ensureSession(for: tabID)
        let session = try XCTUnwrap(vm.sessions[tabID])
        session.hasLoadedPersistedState = true
        session.hasSentFirstMessage = true
        session.selectedAgent = .codexExec
        session.testInstallPersistentSessionBinding(sessionID: UUID())
        let target = try XCTUnwrap(vm.makeComposerSubmitTarget(tabID: tabID, session: session))
        XCTAssertEqual(target.route, .existingAgentSession)
        XCTAssertEqual(target.expectedRunState, .idle)
        XCTAssertNil(target.expectedRunID)
        XCTAssertNil(target.expectedRunAttemptID)
        XCTAssertNil(target.expectedInitialStartLocation)

        let liveRunID = UUID()
        let liveAttemptID = UUID()
        session.runState = .running
        session.runID = liveRunID
        session.beginRunAttempt(source: "test.liveRunStarted", attemptID: liveAttemptID)
        let result = await vm.submitUserTurnCreatingSessionIfNeeded(text: "send to live run", target: target)

        XCTAssertEqual(result, .submitted)
        XCTAssertEqual(session.items.filter { $0.kind == .user }.map(\.text), ["send to live run"])
        XCTAssertNotNil(session.runID)
        XCTAssertNotNil(session.activeRunAttemptID)
    }

    func testGuardedExistingSessionSubmitAcceptsRotatedCodexAttemptExactlyOnce() async throws {
        let recorder = StopSubmitSendRecorder()
        let controller = StopSubmitNoopCodexController(recorder: recorder, hasActiveThread: true)
        let vm = makeViewModel(codexController: controller)
        let tabID = UUID()
        vm.ensureSession(for: tabID)
        let session = try XCTUnwrap(vm.sessions[tabID])
        session.hasLoadedPersistedState = true
        session.selectedAgent = .codexExec
        session.testInstallPersistentSessionBinding(sessionID: UUID())
        session.runState = .running
        let liveRunID = UUID()
        session.runID = liveRunID
        let firstOwnership = session.beginRunAttempt(source: "test.firstAttempt", attemptID: UUID())
        let target = try XCTUnwrap(vm.makeComposerSubmitTarget(tabID: tabID, session: session))
        XCTAssertEqual(target.route, .existingAgentSession)
        XCTAssertEqual(target.expectedRunAttemptID, firstOwnership.attemptID)

        XCTAssertTrue(session.endRunAttempt(ifCurrent: firstOwnership, source: "test.rotateAttempt"))
        let liveAttemptID = UUID()
        session.beginRunAttempt(source: "test.secondAttempt", attemptID: liveAttemptID)
        let result = await vm.submitUserTurnCreatingSessionIfNeeded(text: "send after attempt rotation", target: target)

        XCTAssertEqual(result, .submitted)
        XCTAssertEqual(session.items.filter { $0.kind == .user }.map(\.text), ["send after attempt rotation"])
        XCTAssertNotNil(session.runID)
        XCTAssertNotNil(session.activeRunAttemptID)
        XCTAssertNotEqual(session.activeRunAttemptID, firstOwnership.attemptID)
    }

    func testGuardedExistingSessionSubmitRejectsReusedRenderTargetAfterFirstTurnIsAccepted() async throws {
        let recorder = StopSubmitSendRecorder()
        let controller = StopSubmitNoopCodexController(recorder: recorder, hasActiveThread: true)
        let vm = makeViewModel(codexController: controller)
        let tabID = UUID()
        vm.ensureSession(for: tabID)
        let session = try XCTUnwrap(vm.sessions[tabID])
        session.hasLoadedPersistedState = true
        session.hasSentFirstMessage = true
        session.selectedAgent = .codexExec
        session.testInstallPersistentSessionBinding(sessionID: UUID())
        session.runState = .running
        session.runID = UUID()
        session.beginRunAttempt(source: "test")
        let target = try XCTUnwrap(vm.makeComposerSubmitTarget(tabID: tabID, session: session))
        let firstResult = await vm.submitUserTurnCreatingSessionIfNeeded(text: "send once", target: target)
        let reusedResult = await vm.submitUserTurnCreatingSessionIfNeeded(text: "send once", target: target)

        XCTAssertEqual(firstResult, .submitted)
        guard case let .blocked(message) = reusedResult else {
            return XCTFail("Expected reused render target to be blocked")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertEqual(session.items.filter { $0.kind == .user }.map(\.text), ["send once"])
    }

    func testGuardedExistingSessionSubmitRejectsReusedControlCommandTargetWithoutUserBubble() async throws {
        let recorder = StopSubmitSendRecorder()
        let controller = StopSubmitNoopCodexController(recorder: recorder, hasActiveThread: true)
        let vm = makeViewModel(codexController: controller)
        let tabID = UUID()
        vm.ensureSession(for: tabID)
        let session = try XCTUnwrap(vm.sessions[tabID])
        session.hasLoadedPersistedState = true
        session.hasSentFirstMessage = true
        session.selectedAgent = .codexExec
        session.codexConversationID = "noop"
        session.testInstallPersistentSessionBinding(sessionID: UUID())
        let target = try XCTUnwrap(vm.makeComposerSubmitTarget(tabID: tabID, session: session))
        let firstResult = await vm.submitUserTurnCreatingSessionIfNeeded(text: "/compact", target: target)
        let reusedResult = await vm.submitUserTurnCreatingSessionIfNeeded(text: "/compact", target: target)
        try await waitUntil { recorder.compactionInvocationCount() == 1 }

        XCTAssertEqual(firstResult, .submitted)
        guard case let .blocked(message) = reusedResult else {
            return XCTFail("Expected reused control-command target to be blocked")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertTrue(session.items.filter { $0.kind == .user }.isEmpty)
        XCTAssertEqual(recorder.compactionInvocationCount(), 1)
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ predicate: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for asynchronous Codex submission")
    }

    func testGuardedFirstSendRejectsReusedSourceTargetBeforeCreatingAnotherDestination() async throws {
        let vm = makeViewModel()
        let sourceTabID = UUID()
        let destinationTabID = UUID()
        let sourceSession = await vm.ensureSessionReady(tabID: sourceTabID)
        sourceSession.selectedAgent = .codexExec
        let target = try XCTUnwrap(vm.makeComposerSubmitTarget(tabID: sourceTabID, session: sourceSession))
        XCTAssertEqual(target.route, .createAgentSessionFromSourceTab)
        var createCount = 0

        let firstResult = await vm.submitUserTurnCreatingSessionIfNeeded(
            text: "create once",
            target: target,
            createAndActivateSessionTab: {
                createCount += 1
                XCTAssertNil(vm.makeComposerSubmitTarget(tabID: sourceTabID, session: sourceSession))
                return destinationTabID
            }
        )
        let reusedResult = await vm.submitUserTurnCreatingSessionIfNeeded(
            text: "create twice",
            target: target,
            createAndActivateSessionTab: {
                createCount += 1
                return UUID()
            }
        )

        XCTAssertEqual(firstResult, .submitted)
        guard case let .blocked(message) = reusedResult else {
            return XCTFail("Expected reused first-send target to be blocked")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertEqual(createCount, 1)
        let destinationSession = try XCTUnwrap(vm.sessions[destinationTabID])
        XCTAssertEqual(destinationSession.items.filter { $0.kind == .user }.map(\.text), ["create once"])
    }

    func testGuardedExistingSessionSubmitRejectsPersistentSessionReplacementAndPreservesDraft() async throws {
        let recorder = StopSubmitSendRecorder()
        let controller = StopSubmitNoopCodexController(recorder: recorder, hasActiveThread: true)
        let vm = makeViewModel(codexController: controller)
        let tabID = UUID()
        vm.ensureSession(for: tabID)
        let session = try XCTUnwrap(vm.sessions[tabID])
        session.hasLoadedPersistedState = true
        session.selectedAgent = .codexExec
        let originalSessionID = UUID()
        session.testInstallPersistentSessionBinding(sessionID: originalSessionID)
        let staleTarget = try XCTUnwrap(vm.makeComposerSubmitTarget(tabID: tabID, session: session))
        XCTAssertEqual(staleTarget.route, .existingAgentSession)
        XCTAssertEqual(staleTarget.expectedSourceAgentSessionID, originalSessionID)
        vm.storeDraftText(for: tabID, "draft survives replacement")

        let replacementSessionID = UUID()
        session.testInstallPersistentSessionBinding(sessionID: replacementSessionID)
        let result = await vm.submitUserTurnCreatingSessionIfNeeded(
            text: "draft survives replacement",
            target: staleTarget
        )

        guard case let .blocked(message) = result else {
            return XCTFail("Expected replaced persistent session target to be blocked")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertEqual(session.activeAgentSessionID, replacementSessionID)
        XCTAssertEqual(vm.retrieveDraftText(for: tabID), "draft survives replacement")
        XCTAssertTrue(session.items.isEmpty)
        XCTAssertTrue(session.pendingInstructions.isEmpty)
        XCTAssertTrue(session.pendingClaudeSteeringInstructions.isEmpty)
        XCTAssertTrue(session.pendingACPSteeringInstructions.isEmpty)
        XCTAssertTrue(recorder.sentTexts().isEmpty)
    }

    func testComposerClaimPublishesNilImmediatelyAndRejectsSecondClaimAsExisting() async throws {
        let vm = makeViewModel()
        let tabID = UUID()
        let session = await vm.ensureSessionReady(tabID: tabID)
        vm.test_setCurrentTabIDOverride(tabID)
        defer { vm.test_setCurrentTabIDOverride(nil) }
        vm.storeDraftText(for: tabID, "claim draft")
        vm.syncComposerUIState(tabID: tabID)
        let target = try XCTUnwrap(vm.ui.composer.props.submitTarget)
        let originalToken = target.expectedSubmissionToken
        let originalRevision = vm.ui.composer.revision
        let attempt = AgentComposerSubmitAttempt(
            id: UUID(),
            target: target,
            inputRevision: 42,
            noticeRevision: 7,
            rawDraftSnapshot: "claim draft"
        )

        let claim: AgentModeViewModel.AgentComposerSubmitClaim
        switch vm.claimComposerSubmitAttempt(attempt) {
        case let .claimed(acceptedClaim):
            claim = acceptedClaim
        case let .rejected(rejection):
            return XCTFail("Expected claim, got rejection: \(rejection)")
        }

        XCTAssertEqual(session.activeComposerSubmitAttempt?.id, attempt.id)
        XCTAssertTrue(session.isComposerSubmissionInFlight)
        XCTAssertNotEqual(session.composerSubmissionToken, originalToken)
        XCTAssertNil(vm.ui.composer.props.submitTarget)
        XCTAssertGreaterThan(vm.ui.composer.revision, originalRevision)
        XCTAssertEqual(claim.attempt.inputRevision, 42)
        XCTAssertEqual(claim.attempt.capturedSubmissionToken, originalToken)

        let duplicateAttempt = AgentComposerSubmitAttempt(
            id: UUID(),
            target: target,
            inputRevision: 42,
            noticeRevision: 7,
            rawDraftSnapshot: "claim draft"
        )
        switch vm.claimComposerSubmitAttempt(duplicateAttempt) {
        case .claimed:
            XCTFail("Expected the active claim to reject a duplicate")
        case let .rejected(rejection):
            XCTAssertEqual(rejection, .activeAttemptExists(activeAttemptID: attempt.id))
        }

        XCTAssertTrue(vm.releaseComposerSubmitClaim(claim))
        XCTAssertFalse(session.isComposerSubmissionInFlight)
        XCTAssertNotNil(vm.ui.composer.props.submitTarget)
    }

    func testStaleComposerClaimReleaseCannotClearNewerClaim() async throws {
        let vm = makeViewModel()
        let tabID = UUID()
        let session = await vm.ensureSessionReady(tabID: tabID)
        vm.test_setCurrentTabIDOverride(tabID)
        defer { vm.test_setCurrentTabIDOverride(nil) }

        let firstTarget = try XCTUnwrap(vm.makeComposerSubmitTarget(tabID: tabID, session: session))
        let firstAttempt = AgentComposerSubmitAttempt(
            id: UUID(),
            target: firstTarget,
            inputRevision: 1,
            noticeRevision: 0,
            rawDraftSnapshot: "first"
        )
        let firstClaim: AgentModeViewModel.AgentComposerSubmitClaim
        switch vm.claimComposerSubmitAttempt(firstAttempt) {
        case let .claimed(claim):
            firstClaim = claim
        case let .rejected(rejection):
            return XCTFail("Expected first claim, got rejection: \(rejection)")
        }
        XCTAssertTrue(vm.releaseComposerSubmitClaim(firstClaim))

        let secondTarget = try XCTUnwrap(vm.makeComposerSubmitTarget(tabID: tabID, session: session))
        let secondAttempt = AgentComposerSubmitAttempt(
            id: UUID(),
            target: secondTarget,
            inputRevision: 2,
            noticeRevision: 0,
            rawDraftSnapshot: "second"
        )
        let secondClaim: AgentModeViewModel.AgentComposerSubmitClaim
        switch vm.claimComposerSubmitAttempt(secondAttempt) {
        case let .claimed(claim):
            secondClaim = claim
        case let .rejected(rejection):
            return XCTFail("Expected second claim, got rejection: \(rejection)")
        }

        XCTAssertFalse(vm.releaseComposerSubmitClaim(firstClaim))
        XCTAssertEqual(session.activeComposerSubmitAttempt?.id, secondAttempt.id)
        XCTAssertTrue(vm.releaseComposerSubmitClaim(secondClaim))
    }

    func testComposerClaimedSubmitPreservesNewerStoredDraft() async throws {
        let controller = StopSubmitNoopCodexController(hasActiveThread: true)
        let vm = makeViewModel(codexController: controller)
        let tabID = UUID()
        vm.ensureSession(for: tabID)
        let session = try XCTUnwrap(vm.sessions[tabID])
        session.hasLoadedPersistedState = true
        session.hasSentFirstMessage = true
        session.selectedAgent = .codexExec
        session.testInstallPersistentSessionBinding(sessionID: UUID())
        session.runState = .running
        session.runID = UUID()
        session.beginRunAttempt(source: "test")
        vm.storeDraftText(for: tabID, "submitted draft")
        let target = try XCTUnwrap(vm.makeComposerSubmitTarget(tabID: tabID, session: session))
        let attempt = AgentComposerSubmitAttempt(
            id: UUID(),
            target: target,
            inputRevision: 1,
            noticeRevision: 0,
            rawDraftSnapshot: "submitted draft"
        )
        let claim: AgentModeViewModel.AgentComposerSubmitClaim
        switch vm.claimComposerSubmitAttempt(attempt) {
        case let .claimed(acceptedClaim):
            claim = acceptedClaim
        case let .rejected(rejection):
            return XCTFail("Expected claim, got rejection: \(rejection)")
        }
        vm.storeDraftText(for: tabID, "newer draft")

        let result = await vm.executeComposerSubmitAttempt(text: "submitted draft", claim: claim)

        XCTAssertEqual(result, .submitted)
        XCTAssertEqual(vm.retrieveDraftText(for: tabID), "newer draft")
    }

    func testGuardedFirstSendRejectsUnprovenCreateToExistingTransitionAndPreservesDraft() async throws {
        let vm = makeViewModel()
        let sourceTabID = UUID()
        let sourceSession = await vm.ensureSessionReady(tabID: sourceTabID)
        sourceSession.selectedAgent = .codexExec
        sourceSession.pendingImageAttachments = [
            AgentImageAttachment(
                source: .localFile(path: "/tmp/create-to-existing.png"),
                title: "create-to-existing.png"
            )
        ]
        vm.storeDraftText(for: sourceTabID, "draft must survive")
        let staleCreateTarget = try XCTUnwrap(
            vm.makeComposerSubmitTarget(tabID: sourceTabID, session: sourceSession)
        )
        XCTAssertEqual(staleCreateTarget.route, .createAgentSessionFromSourceTab)

        let linkedSessionID = UUID()
        sourceSession.testInstallPersistentSessionBinding(sessionID: linkedSessionID)
        sourceSession.runState = .running
        sourceSession.runID = UUID()
        sourceSession.beginRunAttempt(source: "test.linked")
        var createCalled = false

        let result = await vm.submitUserTurnCreatingSessionIfNeeded(
            text: "draft must survive",
            target: staleCreateTarget,
            createAndActivateSessionTab: {
                createCalled = true
                return UUID()
            }
        )

        guard case let .blocked(message) = result else {
            return XCTFail("Expected unproven create-to-existing transition to remain blocked")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertFalse(createCalled)
        XCTAssertEqual(sourceSession.activeAgentSessionID, linkedSessionID)
        XCTAssertEqual(vm.retrieveDraftText(for: sourceTabID), "draft must survive")
        XCTAssertEqual(sourceSession.pendingImageAttachments.count, 1)
        XCTAssertTrue(sourceSession.items.isEmpty)
    }

    func testFreshManualThreadProjectsAndUpdatesInitialStartLocation() async {
        let vm = makeViewModel()
        let tabID = UUID()
        let session = await vm.ensureSessionReady(tabID: tabID)
        vm.test_setCurrentTabIDOverride(tabID)
        defer { vm.test_setCurrentTabIDOverride(nil) }

        XCTAssertEqual(vm.initialStartLocationProps(tabID: tabID)?.selection, .local)
        XCTAssertEqual(vm.makeComposerSubmitTarget(tabID: tabID, session: session)?.expectedInitialStartLocation, .local)

        vm.selectInitialStartLocation(.newWorktree, for: tabID)

        XCTAssertEqual(vm.initialStartLocationProps(tabID: tabID)?.selection, .newWorktree)
        XCTAssertEqual(vm.makeComposerSubmitTarget(tabID: tabID, session: session)?.expectedInitialStartLocation, .newWorktree)
    }

    func testFreshLinkedManualThreadProjectsInitialLocationThenPersistentLocalLocationAfterStart() async {
        let vm = makeViewModel()
        vm.selectedAgent = .codexExec
        vm.selectedModelRaw = "iris-alpha"
        vm.selectedReasoningEffortRaw = "high"
        let tabID = UUID()
        let session = await vm.ensureSessionReady(tabID: tabID)
        vm.ensureSession(for: tabID)
        vm.test_setCurrentTabIDOverride(tabID)
        defer { vm.test_setCurrentTabIDOverride(nil) }

        XCTAssertTrue(vm.hasLinkedAgentSession(for: tabID))
        XCTAssertEqual(session.selectedAgent, .codexExec)
        XCTAssertEqual(session.selectedModelRaw, "iris-alpha")
        XCTAssertEqual(session.selectedReasoningEffortRaw, "high")
        XCTAssertEqual(vm.initialStartLocationProps(tabID: tabID)?.selection, .local)

        vm.selectInitialStartLocation(.newWorktree, for: tabID)

        XCTAssertEqual(vm.initialStartLocationProps(tabID: tabID)?.selection, .newWorktree)
        XCTAssertEqual(vm.makeComposerSubmitTarget(tabID: tabID, session: session)?.route, .existingAgentSession)
        session.isPreparingInitialWorktree = true
        XCTAssertEqual(vm.initialStartLocationProps(tabID: tabID)?.isEnabled, false)
        XCTAssertNil(vm.makeComposerSubmitTarget(tabID: tabID, session: session))

        session.isPreparingInitialWorktree = false
        session.hasSentFirstMessage = true
        XCTAssertNil(vm.initialStartLocationProps(tabID: tabID))
        XCTAssertEqual(vm.executionLocationProps(tabID: tabID)?.selection, .local)
        XCTAssertEqual(vm.executionLocationProps(tabID: tabID)?.isInitialSelection, false)
    }

    func testLinkedStartedThreadDoesNotReuseRetainedInitialWorktreeIntent() async throws {
        let vm = makeViewModel()
        let tabID = UUID()
        let session = await vm.ensureSessionReady(tabID: tabID)
        vm.ensureSession(for: tabID)
        session.selectedAgent = .codexExec
        vm.test_setCurrentTabIDOverride(tabID)
        defer { vm.test_setCurrentTabIDOverride(nil) }
        vm.selectInitialStartLocation(.newWorktree, for: tabID)
        session.hasSentFirstMessage = true
        let target = try XCTUnwrap(vm.makeComposerSubmitTarget(tabID: tabID, session: session))
        XCTAssertNil(target.expectedInitialStartLocation)

        let result = await vm.submitUserTurnCreatingSessionIfNeeded(
            text: "continue locally",
            target: target,
            createAndActivateSessionTab: {
                XCTFail("Existing linked submit should not create another tab")
                return nil
            }
        )

        XCTAssertEqual(result, .submitted)
        XCTAssertTrue(session.worktreeBindings.isEmpty)
    }

    func testLinkedMCPParentedThreadDoesNotExposeOrPrepareInitialWorktree() async throws {
        let vm = makeViewModel()
        let tabID = UUID()
        let session = await vm.ensureSessionReady(tabID: tabID)
        vm.ensureSession(for: tabID)
        session.parentSessionID = UUID()
        session.selectedAgent = .codexExec
        session.pendingInitialStartLocation = .newWorktree
        vm.test_setCurrentTabIDOverride(tabID)
        defer { vm.test_setCurrentTabIDOverride(nil) }

        XCTAssertNil(vm.initialStartLocationProps(tabID: tabID))
        let target = try XCTUnwrap(vm.makeComposerSubmitTarget(tabID: tabID, session: session))
        XCTAssertNil(target.expectedInitialStartLocation)

        let result = await vm.submitUserTurnCreatingSessionIfNeeded(
            text: "child continues without rebinding",
            target: target,
            createAndActivateSessionTab: {
                XCTFail("Existing child submit should not create another tab")
                return nil
            }
        )

        XCTAssertEqual(result, .submitted)
        XCTAssertTrue(session.worktreeBindings.isEmpty)
    }

    func testGuardedFirstSendRejectsStaleInitialStartLocationSelection() async throws {
        let vm = makeViewModel()
        let sourceTabID = UUID()
        let session = await vm.ensureSessionReady(tabID: sourceTabID)
        vm.test_setCurrentTabIDOverride(sourceTabID)
        defer { vm.test_setCurrentTabIDOverride(nil) }
        vm.selectInitialStartLocation(.newWorktree, for: sourceTabID)
        let staleTarget = try XCTUnwrap(vm.makeComposerSubmitTarget(tabID: sourceTabID, session: session))
        vm.selectInitialStartLocation(.local, for: sourceTabID)

        let result = await vm.submitUserTurnCreatingSessionIfNeeded(
            text: "stale location",
            target: staleTarget,
            createAndActivateSessionTab: {
                XCTFail("A stale start location must not create a destination tab")
                return nil
            }
        )

        guard case let .blocked(message) = result else {
            return XCTFail("Expected stale start location to be blocked")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertTrue(session.items.isEmpty)
    }

    func testGuardedFirstSendUsesRenderTimeSourceTab() async throws {
        let vm = makeViewModel()
        vm.selectedAgent = .codexExec
        vm.selectedModelRaw = "iris-alpha"
        vm.selectedReasoningEffortRaw = "high"
        let sourceTabID = UUID()
        let ambientTabID = UUID()
        let destinationTabID = UUID()
        let sourceSession = await vm.ensureSessionReady(tabID: sourceTabID)
        XCTAssertEqual(sourceSession.selectedAgent, .codexExec)
        XCTAssertEqual(sourceSession.selectedModelRaw, "iris-alpha")
        XCTAssertEqual(sourceSession.selectedReasoningEffortRaw, "high")
        let ambientSession = await vm.ensureSessionReady(tabID: ambientTabID)
        let imageAttachment = AgentImageAttachment(
            source: .localFile(path: "/tmp/render-target-image.png"),
            title: "render-target-image.png"
        )
        sourceSession.selectedWorkflow = AgentWorkflow.build.definition
        sourceSession.pendingImageAttachments = [imageAttachment]
        let target = try XCTUnwrap(vm.makeComposerSubmitTarget(tabID: sourceTabID, session: sourceSession))
        XCTAssertEqual(target.route, .createAgentSessionFromSourceTab)
        vm.test_setCurrentTabIDOverride(ambientTabID)
        defer { vm.test_setCurrentTabIDOverride(nil) }

        let result = await vm.submitUserTurnCreatingSessionIfNeeded(
            text: "first send from rendered source",
            target: target,
            createAndActivateSessionTab: {
                vm.selectedAgent = .claudeCode
                return destinationTabID
            }
        )

        XCTAssertEqual(result, .submitted)
        XCTAssertNil(sourceSession.selectedWorkflow)
        XCTAssertTrue(sourceSession.pendingImageAttachments.isEmpty)
        XCTAssertTrue(ambientSession.items.isEmpty)
        XCTAssertTrue(ambientSession.pendingImageAttachments.isEmpty)
        let destinationSession = try XCTUnwrap(vm.sessions[destinationTabID])
        guard let userItem = destinationSession.items.first else {
            return XCTFail("Expected destination to receive optimistic user item")
        }
        XCTAssertEqual(userItem.kind, .user)
        XCTAssertEqual(userItem.text, "first send from rendered source")
        XCTAssertEqual(userItem.workflow?.builtInWorkflow, .build)
        XCTAssertEqual(userItem.attachments, [imageAttachment])
        XCTAssertEqual(destinationSession.selectedAgent, .codexExec)
        XCTAssertEqual(destinationSession.selectedModelRaw, "iris-alpha")
        XCTAssertEqual(destinationSession.selectedReasoningEffortRaw, "high")
        XCTAssertTrue(destinationSession.worktreeBindings.isEmpty)
    }

    func testGuardedFirstSendRejectsIfAttachmentsChangeDuringCreateAndPreservesDraft() async throws {
        let vm = makeViewModel()
        vm.selectedAgent = .codexExec
        let sourceTabID = UUID()
        let destinationTabID = UUID()
        let sourceSession = await vm.ensureSessionReady(tabID: sourceTabID)
        sourceSession.pendingImageAttachments = [
            AgentImageAttachment(
                source: .localFile(path: "/tmp/source-state-changed.png"),
                title: "source-state-changed.png"
            )
        ]
        vm.storeDraftText(for: sourceTabID, "draft survives")
        let target = try XCTUnwrap(vm.makeComposerSubmitTarget(tabID: sourceTabID, session: sourceSession))

        let result = await vm.submitUserTurnCreatingSessionIfNeeded(
            text: "should not consume changed source",
            target: target,
            createAndActivateSessionTab: {
                _ = vm.session(for: destinationTabID)
                sourceSession.pendingImageAttachments.removeAll()
                return destinationTabID
            }
        )

        guard case let .blocked(message) = result else {
            return XCTFail("Expected changed source state to be blocked")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertEqual(vm.retrieveDraftText(for: sourceTabID), "draft survives")
        XCTAssertTrue(sourceSession.items.isEmpty)
        XCTAssertNil(vm.sessions[destinationTabID])
    }

    func testPendingUserInputCancelTargetBindsSnapshotTabAndRequestIdentity() {
        let tabID = UUID()
        let runID = UUID()
        let agentSessionID = UUID()
        let attemptID = UUID()
        let requestID = CodexAppServerRequestID.string("request-1")
        let request = AgentRequestUserInputRequest(
            requestID: requestID,
            method: "request_user_input",
            threadID: "thread",
            turnID: "turn",
            itemID: "item",
            questions: [
                AgentRequestUserInputQuestion(
                    id: "q1",
                    header: "Question",
                    question: "Continue?",
                    isOther: false,
                    isSecret: false,
                    options: []
                )
            ]
        )
        let snapshot = AgentRunInteractionUISnapshot(
            currentTabID: tabID,
            runState: .waitingForUser,
            runningStatusText: nil,
            activeAgentRunStartedAt: nil,
            waitingPrompt: nil,
            pendingAskUser: nil,
            pendingUserInputRequest: request,
            pendingApproval: nil,
            pendingPermissionsRequest: nil,
            pendingMCPElicitationRequest: nil,
            pendingApplyEditsReview: nil,
            pendingWorktreeMergeReview: nil,
            activeRunID: runID,
            activeAgentSessionID: agentSessionID,
            activeRunAttemptID: attemptID,
            latestUserSequenceIndex: nil,
            canForkCurrentSession: false,
            selectedAgent: .codexExec,
            selectedModelRaw: AgentModel.defaultModel.rawValue,
            selectedReasoningEffortRaw: nil
        )

        let cancelTarget = snapshot.pendingUserInputCancelTarget

        XCTAssertEqual(cancelTarget?.tabID, tabID)
        XCTAssertEqual(cancelTarget?.expectedRunID, runID)
        XCTAssertEqual(cancelTarget?.expectedActiveAgentSessionID, agentSessionID)
        XCTAssertEqual(cancelTarget?.expectedRunAttemptID, attemptID)
        XCTAssertEqual(cancelTarget?.expectedPendingUserInputRequestID, requestID)
    }

    private func makeViewModel(
        onCancelTools: @escaping AgentModeViewModel.MCPRunToolCanceller = { _, _ in 0 },
        codexController: StopSubmitNoopCodexController? = nil
    ) -> AgentModeViewModel {
        AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in
                codexController ?? StopSubmitNoopCodexController()
            },
            mcpRunToolCanceller: onCancelTools
        )
    }
}

private final class StopSubmitSendRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String] = []
    private var compactionInvocations = 0

    func record(_ text: String) {
        lock.lock()
        texts.append(text)
        lock.unlock()
    }

    func sentTexts() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return texts
    }

    func recordCompaction() {
        lock.lock()
        compactionInvocations += 1
        lock.unlock()
    }

    func compactionInvocationCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return compactionInvocations
    }
}

private final class StopSubmitNoopCodexController: CodexSessionControlling {
    private let recorder: StopSubmitSendRecorder?
    private let activeThread: Bool
    private let eventStream: AsyncStream<CodexNativeSessionController.Event>
    private let eventContinuation: AsyncStream<CodexNativeSessionController.Event>.Continuation

    init(recorder: StopSubmitSendRecorder? = nil, hasActiveThread: Bool = false) {
        self.recorder = recorder
        activeThread = hasActiveThread
        var continuation: AsyncStream<CodexNativeSessionController.Event>.Continuation?
        eventStream = AsyncStream { continuation = $0 }
        eventContinuation = continuation!
        if !hasActiveThread {
            eventContinuation.finish()
        }
    }

    deinit {
        eventContinuation.finish()
    }

    var hasActiveThread: Bool {
        activeThread
    }

    var events: AsyncStream<CodexNativeSessionController.Event> {
        eventStream
    }

    func ensureEventsStreamReady() {}
    func startOrResume(existing: CodexNativeSessionController.SessionRef?, baseInstructions: String) async throws -> CodexNativeSessionController.SessionRef {
        CodexNativeSessionController.SessionRef(conversationID: "noop", rolloutPath: nil, model: nil, reasoningEffort: nil)
    }

    func startOrResume(existing: CodexNativeSessionController.SessionRef?, baseInstructions: String, model: String?, reasoningEffort: String?) async throws -> CodexNativeSessionController.SessionRef {
        CodexNativeSessionController.SessionRef(conversationID: "noop", rolloutPath: nil, model: model, reasoningEffort: reasoningEffort)
    }

    func startOrResume(existing: CodexNativeSessionController.SessionRef?, baseInstructions: String, model: String?, reasoningEffort: String?, serviceTier: String?) async throws -> CodexNativeSessionController.SessionRef {
        CodexNativeSessionController.SessionRef(conversationID: "noop", rolloutPath: nil, model: model, reasoningEffort: reasoningEffort)
    }

    func readThreadSnapshot(includeTurns: Bool, timeout: TimeInterval?) async throws -> CodexNativeSessionController.ThreadSnapshot {
        CodexNativeSessionController.ThreadSnapshot(
            conversationID: "noop",
            rolloutPath: nil,
            model: nil,
            reasoningEffort: nil,
            runtimeStatus: .idle,
            currentTurnID: nil,
            activeTurnIDs: [],
            latestTurnStatus: nil
        )
    }

    func setThreadName(_ name: String, threadID: String?) async throws {}
    func startUserTurn(text: String, images: [AgentImageAttachment], model: String?, reasoningEffort: String?, serviceTier: String?) async throws -> CodexTurnStartReceipt {
        recorder?.record(text)
        return CodexTurnStartReceipt(provisionalSubmissionID: "stop-submit-submission")
    }

    func steerUserTurn(text: String, images: [AgentImageAttachment], expectedTurnID: String) async throws -> CodexTurnSteerReceipt {
        recorder?.record(text)
        return CodexTurnSteerReceipt(acceptedTurnID: expectedTurnID)
    }

    func interruptUserTurn(expectedTurnID: String) async throws -> CodexTurnInterruptReceipt {
        CodexTurnInterruptReceipt(interruptedTurnID: expectedTurnID)
    }

    func compactThread() async throws {
        recorder?.recordCompaction()
    }

    func getThreadGoal() async throws -> CodexNativeSessionController.ThreadGoal? {
        nil
    }

    func setThreadGoalObjective(_ objective: String) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func setThreadGoalStatus(_ status: CodexNativeSessionController.ThreadGoalStatus) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func clearThreadGoal() async throws -> Bool {
        false
    }

    func cancelCurrentTurn() async {}
    func shutdown() async {}
    func respondToServerRequest(id: CodexAppServerRequestID, result: [String: Any]) async {}
}

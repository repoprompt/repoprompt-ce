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
        runningSession.activeAgentSessionID = agentSessionID
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
        targetSession.activeAgentSessionID = UUID()
        targetSession.beginRunAttempt(source: "test")
        otherSession.runState = .running
        otherSession.runID = otherRunID
        otherSession.activeAgentSessionID = UUID()
        otherSession.beginRunAttempt(source: "test")
        let cancelTarget = vm.makeRunCancelTarget(tabID: targetTabID, session: targetSession)
        vm.test_setCurrentTabIDOverride(otherTabID)
        defer { vm.test_setCurrentTabIDOverride(nil) }

        let accepted = await vm.cancelAgentRun(target: cancelTarget, waitForCleanup: false)

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
        session.activeAgentSessionID = UUID()
        session.beginRunAttempt(source: "test")
        let staleTarget = vm.makeRunCancelTarget(tabID: tabID, session: session)
        let newerRunID = UUID()
        session.runID = newerRunID
        session.beginRunAttempt(source: "test")

        let accepted = await vm.cancelAgentRun(target: staleTarget, waitForCleanup: false)

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
        let target = try XCTUnwrap(vm.makeComposerSubmitTarget(tabID: targetTabID, session: targetSession))
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

    func testGuardedSubmitRejectsMismatchedRunIdentityAndPreservesDraft() async throws {
        let vm = makeViewModel()
        let tabID = UUID()
        vm.ensureSession(for: tabID)
        let session = try XCTUnwrap(vm.sessions[tabID])
        session.runState = .running
        session.runID = UUID()
        session.beginRunAttempt(source: "test")
        vm.storeDraftText(for: tabID, "stale steering")
        let staleTarget = AgentComposerSubmitTarget(
            tabID: tabID,
            route: .existingAgentSession,
            expectedSourceAgentSessionID: session.activeAgentSessionID,
            expectedRunState: .running,
            expectedRunID: UUID(),
            expectedRunAttemptID: session.activeRunAttemptID,
            expectedInitialStartLocation: nil
        )

        let result = await vm.submitUserTurnCreatingSessionIfNeeded(text: "stale steering", target: staleTarget)

        guard case let .blocked(message) = result else {
            return XCTFail("Expected stale target to be blocked")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertEqual(vm.retrieveDraftText(for: tabID), "stale steering")
        XCTAssertTrue(session.items.isEmpty)
        XCTAssertTrue(session.pendingInstructions.isEmpty)
        XCTAssertTrue(session.pendingClaudeSteeringInstructions.isEmpty)
        XCTAssertTrue(session.pendingACPSteeringInstructions.isEmpty)
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
        onCancelTools: @escaping AgentModeViewModel.MCPRunToolCanceller = { _, _ in 0 }
    ) -> AgentModeViewModel {
        AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in StopSubmitNoopCodexController() },
            mcpRunToolCanceller: onCancelTools
        )
    }
}

private final class StopSubmitNoopCodexController: CodexSessionControlling {
    var hasActiveThread: Bool {
        false
    }

    var events: AsyncStream<CodexNativeSessionController.Event> {
        AsyncStream { continuation in continuation.finish() }
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
    func sendUserMessage(_ text: String) async throws {}
    func sendUserTurn(text: String, images: [AgentImageAttachment]) async throws {}
    func sendUserTurn(text: String, images: [AgentImageAttachment], model: String?, reasoningEffort: String?) async throws {}
    func sendUserTurn(text: String, images: [AgentImageAttachment], model: String?, reasoningEffort: String?, serviceTier: String?) async throws {}
    func compactThread() async throws {}
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

import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

@MainActor
final class AgentSessionLinkLaneBoardTests: XCTestCase {
    private func candidate(
        tabID: UUID,
        sessionID: UUID = UUID(),
        workspaceID: UUID = UUID(),
        isClosing: Bool = false
    ) -> AgentSessionLinkEndpointCandidate {
        AgentSessionLinkEndpointCandidate(
            windowID: 1,
            workspaceID: workspaceID,
            tabID: tabID,
            sessionID: sessionID,
            persistentBindingGeneration: UUID(),
            bindingTransitionGeneration: 1,
            isTopLevel: true,
            hasLoadedPersistedState: true,
            bindingTransitionInProgress: false,
            isClosing: isClosing,
            isMCPControlled: false,
            isMCPOriginated: false,
            roleAllowsOutboundMonitoring: true,
            displayName: "Worker",
            providerDisplayName: "Codex CLI",
            locationLabel: nil
        )
    }

    private func snapshot(
        for session: AgentModeViewModel.TabSession,
        candidate: AgentSessionLinkEndpointCandidate,
        subagentCounts: (running: Int, finished: Int) = (0, 0)
    ) -> DomainAgentSessionObservationSnapshot {
        AgentModeViewModel.observationSnapshot(
            for: session,
            candidate: candidate,
            subagentCounts: subagentCounts
        )
    }

    func testRunOutcomeKeepsTerminalStatesDistinctWhileLinkStatusStaysIdle() {
        let tabID = UUID()
        let session = AgentModeViewModel.TabSession(tabID: tabID)
        session.hasLoadedPersistedState = true
        let target = candidate(tabID: tabID)
        let states: [(AgentSessionRunState, DomainAgentSessionLaneBoard.RunOutcome)] = [
            (.idle, .none),
            (.running, .running),
            (.waitingForUser, .awaitingUser),
            (.completed, .completed),
            (.cancelled, .cancelled),
            (.failed, .failed)
        ]
        for (runState, outcome) in states {
            session.runState = runState
            let observed = snapshot(for: session, candidate: target)
            XCTAssertEqual(observed.board.runOutcome, outcome)
            if runState.isActive {
                XCTAssertNotEqual(observed.status, .idle)
            } else {
                XCTAssertEqual(observed.status, .idle)
            }
        }
    }

    func testFailureReasonUsesOnlyStampedTerminalClassification() {
        XCTAssertEqual(
            AgentModeViewModel.laneFailureReason(for: .failed, stamped: .timeout),
            .timeout
        )
        XCTAssertEqual(
            AgentModeViewModel.laneFailureReason(for: .failed, stamped: .processCrash),
            .processCrash
        )
        XCTAssertNil(AgentModeViewModel.laneFailureReason(for: .failed, stamped: nil))
        XCTAssertNil(AgentModeViewModel.laneFailureReason(for: .completed, stamped: .agentError))
        XCTAssertNil(AgentModeViewModel.laneFailureReason(for: .running, stamped: .agentError))
        XCTAssertEqual(AgentModeViewModel.laneFailureReason(for: .cancelled, stamped: nil), .cancelled)

        let tabID = UUID()
        let session = AgentModeViewModel.TabSession(tabID: tabID)
        session.runState = .cancelled
        XCTAssertEqual(snapshot(for: session, candidate: candidate(tabID: tabID)).board.failureReason, .cancelled)
    }

    func testFailedTerminalCommitRetainsStampedReasonAfterProviderClearsRunID() {
        for reason in [DomainAgentRunSnapshot.FailureReason.timeout, .resumeTimedOut] {
            let tabID = UUID()
            let session = AgentModeViewModel.TabSession(tabID: tabID)
            let runID = UUID()
            session.installRunID(runID)
            let ownership = AgentRunOwnership(
                binding: AgentRunBindingIdentity(tabID: tabID, persistentSessionID: nil)
            )
            XCTAssertTrue(session.runLifecycle.beginTerminalCommit())
            session.runLifecycle.stageTerminalRevision(AgentRunTerminalCommitRevision(
                commitID: UUID(),
                ownership: ownership,
                terminalState: .failed,
                failureReason: reason,
                expectedRunID: runID,
                sourceItemsRevision: 0,
                assistantDeltaFlushGeneration: 0,
                providerDrainGeneration: 0,
                mcpPublicationEnvelope: nil,
                successorKind: nil,
                providerSuccessorID: nil
            ))
            session.runState = .failed
            XCTAssertTrue(session.clearRunID(ifCurrent: runID))
            session.runLifecycle.completeTerminalCommit()
            XCTAssertNil(session.runID)
            XCTAssertNotNil(session.lastTerminalCommitRevision)
            let observed = snapshot(for: session, candidate: candidate(tabID: tabID))
            XCTAssertEqual(observed.board.runOutcome, .failed)
            XCTAssertEqual(observed.board.failureReason?.rawValue, reason.rawValue)
            let wire = AgentSessionLinkResponseRenderer.laneBoardValue(observed.board).objectValue
            XCTAssertEqual(wire?["failure_reason"]?.stringValue, reason.rawValue)

            session.runState = .completed
            XCTAssertNil(snapshot(for: session, candidate: candidate(tabID: tabID)).board.failureReason)
        }
    }

    func testEveryNamedReadinessConditionProducesItsOwnBlocker() {
        let tabID = UUID()
        let session = AgentModeViewModel.TabSession(tabID: tabID)
        session.hasLoadedPersistedState = true
        let target = candidate(tabID: tabID)
        let baseline = AgentModeViewModel.sendReadinessInputs(session: session, candidate: target, status: .idle)
        XCTAssertTrue(AgentModeViewModel.sendBlockers(baseline).isEmpty)

        typealias Inputs = AgentModeViewModel.SendReadinessInputs
        let cases: [(String, WritableKeyPath<Inputs, Bool>, Bool)] = [
            ("run_state_active", \.runStateIsActive, true),
            ("persisted_state_not_loaded", \.hasLoadedPersistedState, false),
            ("binding_transition_in_progress", \.bindingTransitionInProgress, true),
            ("terminal_commit_in_progress", \.terminalCommitInProgress, true),
            ("mcp_follow_up_run_pending", \.mcpFollowUpRunPending, true),
            ("composer_submission_in_flight", \.isComposerSubmissionInFlight, true),
            ("preparing_initial_worktree", \.isPreparingInitialWorktree, true),
            ("changing_execution_location", \.isChangingExecutionLocation, true),
            ("pending_instructions", \.hasPendingInstructions, true),
            ("pending_acp_steering_instructions", \.hasPendingACPSteeringInstructions, true),
            ("pending_claude_steering_instructions", \.hasPendingClaudeSteeringInstructions, true),
            ("pending_auto_wake", \.hasPendingAutoWake, true),
            ("pending_self_compact", \.hasPendingSelfCompact, true),
            ("stop_in_progress", \.stopInProgress, true),
            ("candidate_closing", \.isCandidateClosing, true)
        ]
        for (expected, keyPath, blockedValue) in cases {
            var input = baseline
            input[keyPath: keyPath] = blockedValue
            XCTAssertEqual(AgentModeViewModel.sendBlockers(input).map(\.rawValue), [expected])
        }
        var nonIdle = baseline
        nonIdle.status = .awaitingUser
        XCTAssertEqual(AgentModeViewModel.sendBlockers(nonIdle).map(\.rawValue), ["status_not_idle"])
        XCTAssertEqual(AgentModeViewModel.SendBlocker.sessionUnavailable.rawValue, "session_unavailable")
    }

    func testUnavailableSessionUsesTheSharedBlockerVocabulary() {
        let viewModel = AgentModeViewModel(
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in
                preconditionFailure("Lane-board tests must not start a provider")
            }
        )
        let observed = viewModel.agentSessionLinkObservationSnapshot(for: candidate(tabID: UUID()))
        XCTAssertFalse(observed.idleForSend)
        XCTAssertEqual(observed.board.sendBlockers, [AgentModeViewModel.SendBlocker.sessionUnavailable.rawValue])
        XCTAssertNil(observed.board.directRunningHelperCount)
    }

    func testSupplementalNeedsUserRequiresHookOrCompleteInstructionWait() async throws {
        let tabID = UUID()
        let viewModel = AgentModeViewModel(testWorkspacePath: FileManager.default.currentDirectoryPath, codexControllerFactory: { _, _, _, _, _, _ in
            preconditionFailure("Wait evidence tests must not start a provider")
        })
        let workspaceManager = AgentSessionLinkEndpointTestSupport.installWorkspace(on: viewModel, tabID: tabID, name: "Wait evidence")
        defer { withExtendedLifetime(workspaceManager) {} }
        let session = viewModel.session(for: tabID)
        let sessionID = UUID()
        _ = try XCTUnwrap(viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session, updateWorkspaceMetadata: true))
        session.hasLoadedPersistedState = true
        session.recordRestorationAuthoritative(.persistedPayloadApplied)
        session.markCurrentBindingHydrated()
        let target = try XCTUnwrap(viewModel.agentSessionLinkCandidates(isWindowClosing: false).first { $0.sessionID == sessionID })
        _ = try viewModel.agentSessionLinkReadableSession(for: target).get()
        XCTAssertTrue(session.permitsBoundOperationAndSave)
        XCTAssertNotNil(session.quietRunFacts(capturedState: .waitingForUser))
        func evidence() -> Bool? {
            viewModel.agentSessionLinkRunFacts(for: target, capturedStatus: .awaitingUser)?.supplementalNeedsUser
        }
        XCTAssertEqual(evidence(), false)
        var publishedEvidence: [Bool] = []
        let observation = try XCTUnwrap(viewModel.agentSessionLinkInstallObservation(for: target) {
            if let value = evidence() { publishedEvidence.append(value) }
        })
        defer { observation.invalidate() }
        try await AsyncTestWait.waitUntil("initial wait evidence observed") { publishedEvidence.last == false }
        session.runState = .waitingForUser
        session.waitingPrompt = "Stale prompt alone"
        XCTAssertEqual(evidence(), false)
        // ID and continuation are read projections of one owned record now: neither half can
        // independently turn a stale prompt into a complete instruction wait.
        XCTAssertNil(session.instructionWaitID)
        XCTAssertNil(session.instructionContinuation)
        XCTAssertEqual(evidence(), false)
        let runtime = viewModel.linkExecutionRuntime
        let command = try XCTUnwrap(runtime.admit(target))
        let wait = Task<UserInstructionResponse, Error> {
            try await withCheckedThrowingContinuation {
                runtime.test_installInstructionWait(command: command, continuation: $0)
            }
        }
        try await AsyncTestWait.waitUntil("instruction continuation installed") { session.instructionContinuation != nil }
        try await AsyncTestWait.waitUntil("instruction wait mutation observed") { publishedEvidence.last == true }
        XCTAssertEqual(evidence(), true)
        XCTAssertEqual(AgentPendingInteractionDescriptor.make(from: session)?.kind, .instruction)
        let installedWait = try XCTUnwrap(session.instructionWait)
        session.instructionWait = nil
        XCTAssertEqual(evidence(), false)
        installedWait.continuation.resume(throwing: CancellationError())
        _ = await wait.result
        try await AsyncTestWait.waitUntil("instruction teardown observed") { publishedEvidence.last == false }
        let review = AgentCodexHookReviewRequest(tabID: tabID, runAttemptID: nil, runID: nil, executionCWD: "/tmp", hooks: [], phase: .reviewRequired, gateGeneration: 1)
        session.pendingCodexHookReview = review
        try await AsyncTestWait.waitUntil("hook review mutation observed") { publishedEvidence.last == true }
        XCTAssertNil(AgentModeViewModel.pendingInteractionKind(for: session))
        XCTAssertEqual(evidence(), true)
        session.pendingCodexHookReview = nil
        try await AsyncTestWait.waitUntil("hook review teardown observed") { publishedEvidence.last == false }
        session.pendingCodexHookReview = review
        session.beginPersistentBindingTransition()
        XCTAssertNil(evidence(), "unknown proof must never be replaced with zero counters")
    }

    func testCachedCensusDistinguishesUnavailableFromKnownZeroWithoutChangingPollWire() throws {
        let tabID = UUID()
        let viewModel = AgentModeViewModel(testWorkspacePath: FileManager.default.currentDirectoryPath, codexControllerFactory: { _, _, _, _, _, _ in
            preconditionFailure("Census tests must not start a provider")
        })
        let workspaceManager = AgentSessionLinkEndpointTestSupport.installWorkspace(on: viewModel, tabID: tabID, name: "Census availability")
        defer { withExtendedLifetime(workspaceManager) {} }
        let session = viewModel.session(for: tabID)
        let sessionID = try XCTUnwrap(viewModel.test_ensureSessionBoundToTab(session))
        let target = try candidate(tabID: tabID, sessionID: sessionID, workspaceID: XCTUnwrap(workspaceManager.activeWorkspace?.id))
        viewModel.agentSessionLinkCensusWorkspaceID = nil
        let unknown = viewModel.agentSessionLinkObservationSnapshot(for: target)
        XCTAssertNil(unknown.board.directRunningHelperCount)
        var changedParents: Set<UUID> = []
        let subscription = viewModel.agentSessionLinkSubagentCensusChanged.sink { changedParents.formUnion($0) }
        defer { subscription.cancel() }
        viewModel.rebuildAgentSessionLinkSubagentCensus()
        let known = viewModel.agentSessionLinkObservationSnapshot(for: target)
        XCTAssertEqual(known.board.directRunningHelperCount, 0)
        XCTAssertTrue(changedParents.isEmpty, "availability decorates the next existing observation; it creates no new notification")
        XCTAssertEqual(AgentSessionLinkResponseRenderer.laneBoardValue(unknown.board), AgentSessionLinkResponseRenderer.laneBoardValue(known.board))
        let wrongWorkspace = candidate(tabID: tabID, sessionID: sessionID, workspaceID: UUID())
        XCTAssertNil(viewModel.agentSessionLinkObservationSnapshot(for: wrongWorkspace).board.directRunningHelperCount)
    }

    func testPublishedBlockersAndIdleForSendShareTheSameEvaluation() {
        let tabID = UUID()
        let session = AgentModeViewModel.TabSession(tabID: tabID)
        session.hasLoadedPersistedState = true
        let target = candidate(tabID: tabID)

        let ready = snapshot(for: session, candidate: target)
        XCTAssertTrue(ready.idleForSend)
        XCTAssertTrue(ready.board.sendBlockers.isEmpty)
        XCTAssertEqual(ready.board.subagentRunning, 0)
        XCTAssertEqual(ready.board.subagentFinished, 0)

        session.pendingInstructions = ["queued"]
        let queued = snapshot(for: session, candidate: target, subagentCounts: (running: 1, finished: 2))
        XCTAssertFalse(queued.idleForSend)
        XCTAssertEqual(queued.board.sendBlockers, ["pending_instructions"])
        XCTAssertEqual(queued.board.subagentRunning, 1)
        XCTAssertEqual(queued.board.subagentFinished, 2)

        session.runState = .running
        let running = snapshot(for: session, candidate: target)
        XCTAssertFalse(running.idleForSend)
        XCTAssertEqual(
            running.board.sendBlockers,
            ["pending_instructions", "run_state_active", "status_not_idle"]
        )
    }

    func testSelfCompactHoldSharesBoardAndSendReadinessUntilNoteIsParked() {
        let tabID = UUID()
        let session = AgentModeViewModel.TabSession(tabID: tabID)
        session.hasLoadedPersistedState = true
        let target = candidate(tabID: tabID)

        for phase in AgentSelfCompactAttempt.Phase.allCases {
            session.selfCompactState = AgentSelfCompactState(active: AgentSelfCompactAttempt(
                idempotencyKey: "board-hold", note: "Continue the current task.", phase: phase
            ))
            let observed = snapshot(for: session, candidate: target)
            let isParked = phase == .parked
            XCTAssertEqual(observed.idleForSend, isParked, "\(phase)")
            XCTAssertEqual(observed.board.sendBlockers, isParked ? [] : ["pending_self_compact"], "\(phase)")
            XCTAssertTrue(session.selfCompactState.blocksAutomaticWake, "even a parked note belongs to the next ordinary send")
        }
    }

    func testCensusMergesLiveIndexAndPersistedBySessionIDThenDropsCleanedUpChildren() {
        typealias Record = AgentSessionLinkSubagentCensus.Record
        let parentID = UUID()
        let unrelatedID = UUID()
        let liveID = UUID()
        let terminalID = UUID()
        let persistedOnlyID = UUID()
        let indexOnlyID = UUID()
        let movedID = UUID()
        let persisted = [
            Record(sessionID: liveID, parentSessionID: unrelatedID, isLiveInFlight: false),
            Record(sessionID: terminalID, parentSessionID: parentID, isLiveInFlight: false),
            Record(sessionID: persistedOnlyID, parentSessionID: parentID, isLiveInFlight: false),
            Record(sessionID: movedID, parentSessionID: parentID, isLiveInFlight: false)
        ]
        let index = [
            Record(sessionID: terminalID, parentSessionID: unrelatedID, isLiveInFlight: false),
            Record(sessionID: indexOnlyID, parentSessionID: parentID, isLiveInFlight: false),
            Record(sessionID: movedID, parentSessionID: nil, isLiveInFlight: false)
        ]
        let live = [
            Record(sessionID: liveID, parentSessionID: parentID, isLiveInFlight: true),
            Record(sessionID: terminalID, parentSessionID: parentID, isLiveInFlight: false)
        ]
        let census = AgentSessionLinkSubagentCensus(persisted: persisted, index: index, live: live)
        XCTAssertEqual(census.counts(for: parentID), .init(running: 1, finished: 3))
        XCTAssertEqual(census.counts(for: unrelatedID), .init())

        let afterCleanup = AgentSessionLinkSubagentCensus(
            persisted: persisted.filter { $0.sessionID != persistedOnlyID },
            index: index,
            live: live
        )
        XCTAssertEqual(afterCleanup.counts(for: parentID), .init(running: 1, finished: 2))
        XCTAssertEqual(afterCleanup.changedParents(comparedTo: census), [parentID])
    }

    func testLiveAndPersistedChildrenAppearOnParentsActualObservationSnapshot() throws {
        let tabID = UUID()
        let viewModel = AgentModeViewModel(
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in
                preconditionFailure("Lane-board tests must not start a provider")
            }
        )
        let workspaceManager = AgentSessionLinkEndpointTestSupport.installWorkspace(
            on: viewModel, tabID: tabID, name: "Lane board census"
        )
        defer { withExtendedLifetime(workspaceManager) {} }
        let parent = viewModel.session(for: tabID)
        parent.hasLoadedPersistedState = true
        let parentID = try XCTUnwrap(viewModel.test_ensureSessionBoundToTab(parent))
        let target = try candidate(
            tabID: tabID,
            sessionID: parentID,
            workspaceID: XCTUnwrap(workspaceManager.activeWorkspace?.id)
        )

        let runningChild = AgentModeViewModel.TabSession(tabID: UUID())
        runningChild.parentSessionID = parentID
        runningChild.runState = .running
        XCTAssertNotNil(viewModel.test_installPersistentSessionBinding(sessionID: UUID(), on: runningChild))
        viewModel.test_installLiveSession(runningChild)
        let finishedChild = AgentModeViewModel.TabSession(tabID: UUID())
        finishedChild.parentSessionID = parentID
        finishedChild.runState = .completed
        XCTAssertNotNil(viewModel.test_installPersistentSessionBinding(sessionID: UUID(), on: finishedChild))
        viewModel.test_installLiveSession(finishedChild)
        let unrelated = AgentModeViewModel.TabSession(tabID: UUID())
        unrelated.parentSessionID = UUID()
        unrelated.runState = .running
        XCTAssertNotNil(viewModel.test_installPersistentSessionBinding(sessionID: UUID(), on: unrelated))
        viewModel.test_installLiveSession(unrelated)

        let persistedID = UUID()
        viewModel.agentSessionLinkPersistedSubagentWorkspaceID = workspaceManager.activeWorkspace?.id
        viewModel.agentSessionLinkPersistedSubagentMeta = [AgentSessionMeta(
            id: persistedID,
            composeTabID: nil,
            name: "Finished child",
            lastModified: Date(),
            itemCount: 0,
            agentKind: nil,
            agentModel: nil,
            lastRunState: AgentSessionRunState.completed.rawValue,
            acpModelParameterSelections: [],
            parentSessionID: parentID,
            createdByOverseerSessionID: nil,
            isMCPOriginated: true,
            worktreeBindingSummaries: [],
            activeWorktreeMergeSummaries: []
        )]
        viewModel.rebuildAgentSessionLinkSubagentCensus()
        var board = viewModel.agentSessionLinkObservationSnapshot(for: target).board
        XCTAssertEqual(board.subagentRunning, 1)
        XCTAssertEqual(board.subagentFinished, 2)

        runningChild.runState = .waitingForApproval
        viewModel.rebuildAgentSessionLinkSubagentCensus()
        board = viewModel.agentSessionLinkObservationSnapshot(for: target).board
        XCTAssertEqual(board.subagentRunning, 1)
        XCTAssertEqual(board.subagentFinished, 2)

        runningChild.runState = .idle
        viewModel.rebuildAgentSessionLinkSubagentCensus()
        board = viewModel.agentSessionLinkObservationSnapshot(for: target).board
        XCTAssertEqual(board.subagentRunning, 0)
        XCTAssertEqual(board.subagentFinished, 3)

        runningChild.runState = .failed
        viewModel.rebuildAgentSessionLinkSubagentCensus()
        board = viewModel.agentSessionLinkObservationSnapshot(for: target).board
        XCTAssertEqual(board.subagentRunning, 0)
        XCTAssertEqual(board.subagentFinished, 3)

        viewModel.test_removeSession(tabID: finishedChild.tabID)
        viewModel.agentSessionLinkPersistedSubagentMeta = []
        viewModel.rebuildAgentSessionLinkSubagentCensus()
        board = viewModel.agentSessionLinkObservationSnapshot(for: target).board
        XCTAssertEqual(board.subagentRunning, 0)
        XCTAssertEqual(board.subagentFinished, 1)
    }

    func testUnhydratedLiveChildKeepsPersistedParentAndInPlaceUnbindRebuildsCensus() throws {
        let tabID = UUID()
        let viewModel = AgentModeViewModel(
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in
                preconditionFailure("Lane-board tests must not start a provider")
            }
        )
        let workspaceManager = AgentSessionLinkEndpointTestSupport.installWorkspace(
            on: viewModel, tabID: tabID, name: "Lane board unhydrated child"
        )
        defer { withExtendedLifetime(workspaceManager) {} }
        let parent = viewModel.session(for: tabID)
        let parentID = try XCTUnwrap(viewModel.test_ensureSessionBoundToTab(parent))
        let target = try candidate(
            tabID: tabID,
            sessionID: parentID,
            workspaceID: XCTUnwrap(workspaceManager.activeWorkspace?.id)
        )
        let childID = UUID()
        viewModel.agentSessionLinkPersistedSubagentWorkspaceID = workspaceManager.activeWorkspace?.id
        viewModel.agentSessionLinkPersistedSubagentMeta = [AgentSessionMeta(
            id: childID,
            composeTabID: nil,
            name: "Restoring child",
            lastModified: Date(),
            itemCount: 0,
            agentKind: nil,
            agentModel: nil,
            lastRunState: AgentSessionRunState.completed.rawValue,
            acpModelParameterSelections: [],
            parentSessionID: parentID,
            createdByOverseerSessionID: nil,
            isMCPOriginated: true,
            worktreeBindingSummaries: [],
            activeWorktreeMergeSummaries: []
        )]
        let child = AgentModeViewModel.TabSession(tabID: UUID())
        XCTAssertFalse(child.hasLoadedPersistedState)
        XCTAssertNil(child.parentSessionID)
        XCTAssertNotNil(viewModel.test_installPersistentSessionBinding(sessionID: childID, on: child))
        viewModel.test_installLiveSession(child)
        var board = viewModel.agentSessionLinkObservationSnapshot(for: target).board
        XCTAssertEqual(board.subagentRunning, 0, "an idle unhydrated tab is not in flight")
        XCTAssertEqual(board.subagentFinished, 1, "unhydrated live state must retain known persisted parentage")

        _ = viewModel.test_installPersistentSessionBinding(sessionID: nil, on: child)
        board = viewModel.agentSessionLinkObservationSnapshot(for: target).board
        XCTAssertEqual(board.subagentRunning, 0)
        XCTAssertEqual(board.subagentFinished, 1, "old persisted identity remains known after unbind")

        viewModel.agentSessionLinkPersistedSubagentMeta = []
        viewModel.rebuildAgentSessionLinkSubagentCensus()
        board = viewModel.agentSessionLinkObservationSnapshot(for: target).board
        XCTAssertEqual(board.subagentRunning, 0)
        XCTAssertEqual(board.subagentFinished, 0)

        child.parentSessionID = parentID
        child.runState = .running
        XCTAssertNotNil(viewModel.test_installPersistentSessionBinding(sessionID: UUID(), on: child))
        board = viewModel.agentSessionLinkObservationSnapshot(for: target).board
        XCTAssertEqual(board.subagentRunning, 1, "in-place rebind must rebuild without a sessions dictionary mutation")
    }

    func testChildRunAndCleanupRepublishParentBoardWithoutManualRebuild() async throws {
        let tabID = UUID()
        let viewModel = AgentModeViewModel(
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in
                preconditionFailure("Lane-board tests must not start a provider")
            }
        )
        let workspaceManager = AgentSessionLinkEndpointTestSupport.installWorkspace(
            on: viewModel, tabID: tabID, name: "Lane board observation"
        )
        defer { withExtendedLifetime(workspaceManager) {} }
        let parent = viewModel.session(for: tabID)
        let parentID = try XCTUnwrap(viewModel.test_ensureSessionBoundToTab(parent))
        let target = try candidate(
            tabID: tabID,
            sessionID: parentID,
            workspaceID: XCTUnwrap(workspaceManager.activeWorkspace?.id)
        )
        let child = AgentModeViewModel.TabSession(tabID: UUID())
        child.parentSessionID = parentID
        child.runState = .running
        XCTAssertNotNil(viewModel.test_installPersistentSessionBinding(sessionID: UUID(), on: child))
        viewModel.test_installLiveSession(child)
        XCTAssertEqual(viewModel.agentSessionLinkObservationSnapshot(for: target).board.subagentRunning, 1)

        var observedFinished = false
        var observedEmpty = false
        let token = try XCTUnwrap(viewModel.agentSessionLinkInstallObservation(for: target) {
            let board = viewModel.agentSessionLinkObservationSnapshot(for: target).board
            observedFinished = observedFinished || (board.subagentRunning == 0 && board.subagentFinished == 1)
            observedEmpty = observedEmpty || (board.subagentRunning == 0 && board.subagentFinished == 0)
        })
        defer { token.invalidate() }
        child.runState = .completed
        try await AsyncTestWait.waitUntil("parent board observed child completion") { observedFinished }
        viewModel.test_removeSession(tabID: child.tabID)
        try await AsyncTestWait.waitUntil("parent board observed child cleanup") { observedEmpty }
    }

    /// Measures only the in-memory census build plus projection, not metadata I/O or bridge refresh.
    func testThirtyTwoTargetProjectionsFromOneLargeInMemoryCensusStayBounded() {
        typealias Record = AgentSessionLinkSubagentCensus.Record
        let parentIDs = (0 ..< 32).map { _ in UUID() }
        let targetSessions = parentIDs.map { parentID -> (AgentModeViewModel.TabSession, AgentSessionLinkEndpointCandidate) in
            let tabID = UUID()
            let session = AgentModeViewModel.TabSession(tabID: tabID)
            session.hasLoadedPersistedState = true
            return (session, candidate(tabID: tabID, sessionID: parentID))
        }
        let persisted = (0 ..< 16384).map { index in
            Record(
                sessionID: UUID(),
                parentSessionID: parentIDs[index % parentIDs.count],
                isLiveInFlight: false
            )
        }
        let start = ProcessInfo.processInfo.systemUptime
        let census = AgentSessionLinkSubagentCensus(persisted: persisted, index: [], live: [])
        let snapshots = targetSessions.map { session, target in
            let counts = census.counts(for: target.sessionID)
            return snapshot(
                for: session,
                candidate: target,
                subagentCounts: (running: counts.running, finished: counts.finished)
            )
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        XCTAssertEqual(snapshots.count, 32)
        XCTAssertTrue(snapshots.allSatisfy { $0.board.subagentFinished == 512 })
        print("LaneBoardCensusProjectionStress: 32 targets, 16384 children, elapsed=\(String(format: "%.4f", elapsed))s")
        XCTAssertLessThan(elapsed, 1.0, "One in-memory 32-target projection batch should stay below 1 s")
    }

    func testCensusRefreshKeepsLastGoodPersistedListWhenMetadataIsUnavailable() async throws {
        let tabID = UUID()
        let viewModel = AgentModeViewModel(
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in
                preconditionFailure("Lane-board tests must not start a provider")
            }
        )
        let workspaceManager = AgentSessionLinkEndpointTestSupport.installWorkspace(
            on: viewModel, tabID: tabID, name: "Lane board refresh"
        )
        defer { withExtendedLifetime(workspaceManager) {} }
        let workspace = try XCTUnwrap(workspaceManager.activeWorkspace)
        let parent = viewModel.session(for: tabID)
        let parentID = try XCTUnwrap(viewModel.test_ensureSessionBoundToTab(parent))
        let target = candidate(tabID: tabID, sessionID: parentID, workspaceID: workspace.id)

        final class LoaderStub {
            var result: [AgentSessionMeta]?
            var calls = 0
        }
        let stub = LoaderStub()
        stub.result = [AgentSessionMeta(
            id: UUID(),
            composeTabID: nil,
            name: "Persisted child",
            lastModified: Date(),
            itemCount: 0,
            agentKind: nil,
            agentModel: nil,
            lastRunState: AgentSessionRunState.completed.rawValue,
            acpModelParameterSelections: [],
            parentSessionID: parentID,
            createdByOverseerSessionID: nil,
            isMCPOriginated: true,
            worktreeBindingSummaries: [],
            activeWorktreeMergeSummaries: []
        )]
        viewModel.agentSessionLinkPersistedSubagentMetaLoader = { _ in
            stub.calls += 1
            return stub.result
        }

        await viewModel.agentSessionLinkRefreshSubagentCensus(for: workspace)
        XCTAssertEqual(viewModel.agentSessionLinkObservationSnapshot(for: target).board.subagentFinished, 1)

        stub.result = nil
        await viewModel.agentSessionLinkRefreshSubagentCensus(for: workspace)
        XCTAssertEqual(
            viewModel.agentSessionLinkObservationSnapshot(for: target).board.subagentFinished, 1,
            "an unavailable metadata index must keep the last good list rather than flap the count"
        )

        stub.result = []
        await viewModel.agentSessionLinkRefreshSubagentCensus(for: workspace)
        XCTAssertEqual(viewModel.agentSessionLinkObservationSnapshot(for: target).board.subagentFinished, 0)
        XCTAssertEqual(stub.calls, 3, "one metadata load per refresh")
    }

    func testDefaultCensusLoaderReadsCachedIndexWithoutBackfill() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaneBoardCensusLoader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        await AgentSessionDataService.shared.test_setWorkspaceRootOverride(root)
        addTeardownBlock {
            await AgentSessionDataService.shared.test_setWorkspaceRootOverride(nil)
            try? FileManager.default.removeItem(at: root)
        }
        let viewModel = AgentModeViewModel(
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in
                preconditionFailure("Lane-board tests must not start a provider")
            }
        )
        let workspace = WorkspaceModel(name: "Lane board loader", repoPaths: [root.path])
        func indexFileExists() -> Bool {
            let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
            while let url = enumerator?.nextObject() as? URL {
                if url.lastPathComponent == "AgentSessionIndex.json" { return true }
            }
            return false
        }

        let missing = await viewModel.agentSessionLinkPersistedSubagentMetaLoader(workspace)
        XCTAssertNil(missing, "a missing index reads as unavailable")
        XCTAssertFalse(indexFileExists(), "the poll/wait census path must never backfill the index")

        let folder = WorkspaceSessionSidecarMigration.workspaceDirectory(for: workspace, root: root)
            .appendingPathComponent("AgentSessions", isDirectory: true)
        // Neither reader may create an absent history. Backfill applies only to an existing store.
        let absent = try await AgentSessionDataService.shared.listAgentSessionsMeta(for: workspace)
        XCTAssertTrue(absent.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.deletingLastPathComponent().path))
        XCTAssertFalse(indexFileExists())

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let unindexed = await viewModel.agentSessionLinkPersistedSubagentMetaLoader(workspace)
        XCTAssertNil(unindexed)
        XCTAssertFalse(indexFileExists(), "the census must not backfill even an existing store")

        // Only the full listing path backfills the explicitly seeded empty store.
        _ = try await AgentSessionDataService.shared.listAgentSessionsMeta(for: workspace)
        XCTAssertTrue(indexFileExists())
        let cached = await viewModel.agentSessionLinkPersistedSubagentMetaLoader(workspace)
        XCTAssertEqual(cached?.count, 0, "an existing index is served, not reported unavailable")
    }
}

@MainActor
final class AgentSessionLinkManagedMetadataTests: XCTestCase {
    private typealias Notices = AgentSessionLinkPassiveStatusNotices
    private let at = Date(timeIntervalSince1970: 1000)

    private func endpoint(_ number: Int) -> DomainAgentSessionLinkEndpointIdentity {
        AgentSessionLinkIdentityTestSupport.endpoint(sessionID: id(number))
    }

    private func id(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!
    }

    private func reference(_ number: Int = 1) -> DomainAgentSessionLinkReference {
        .init(linkID: id(number + 100), generation: 1)
    }

    private func observation(
        context: DomainAgentSessionContextLoad? = nil,
        outcome: DomainAgentSessionLaneBoard.RunOutcome = .completed,
        pending: Bool = false,
        helpers: Int? = nil
    ) -> DomainAgentSessionObservationSnapshot {
        .init(
            sessionID: id(1), displayName: "Worker", providerDisplayName: nil, status: .idle,
            board: .init(runOutcome: outcome, failureReason: nil, sendBlockers: [], subagentRunning: helpers ?? 0, subagentFinished: 0, subagentCountsKnown: helpers != nil),
            idleForSend: false, pendingInteractionKind: pending ? .question : nil,
            latestVisibleAssistantPreview: nil, visibleRowCount: 0, lastActivityAt: at, context: context
        )
    }

    private func sample(_ status: Notices.Status, metadata: Notices.ManagedMetadata?, number: Int = 1, preview: String? = nil) -> Notices.Sample {
        .init(reference: reference(number), targetEndpoint: endpoint(number), targetSessionID: id(number), displayName: "Worker", status: status, latestVisibleAssistantPreview: preview, managedMetadata: metadata)
    }

    private func notices(metadata: Notices.ManagedMetadata?, count: Int = 1, preview: String? = nil) -> Notices {
        var result = Notices(observerEndpoint: endpoint(0))
        result.enable(samples: (1 ... count).map { sample(.running, metadata: metadata, number: $0, preview: preview) }, linkSetRevision: 1, observedAt: at)
        result.reconcile(samples: (1 ... count).map { sample(.idle, metadata: metadata, number: $0, preview: preview) }, linkSetRevision: 1, deliverable: true, observedAt: at)
        for number in 1 ... count {
            XCTAssertEqual(result.requestAttention(reference: reference(number), targetEndpoint: endpoint(number), targetSessionID: id(number), linkSetRevision: 1, requestedAt: at), .accepted)
        }
        return result
    }

    private func inventory(count: Int = 1, managed: Bool = true) -> AgentSessionLinkPromptInventory {
        .init(observerSessionID: id(0), linkSetRevision: 1, items: (1 ... count).map {
            .init(targetSessionID: id($0), displayName: "Worker", capabilityNames: managed ? ["manage", "poll"] : ["poll"], reference: reference($0))
        })
    }

    func testBothRowKindsRenderCachedFactsAndIndependentUnknowns() {
        let contexts: [(DomainAgentSessionContextLoad?, String, String)] = [
            (nil, "unknown", "unknown"),
            (.init(usedTokens: nil, windowTokens: 100, confidence: .exact), "unknown", "unknown"),
            (.init(usedTokens: 50, windowTokens: nil, confidence: .inferred), "unknown", "inferred"),
            (.init(usedTokens: 125, windowTokens: 100, confidence: .bestEffort), "125.0", "best_effort"),
            (.init(usedTokens: 0, windowTokens: 100, confidence: .exact), "0.0", "exact")
        ]
        for (context, percent, confidence) in contexts {
            for outcome in [DomainAgentSessionLaneBoard.RunOutcome.completed, .cancelled, .failed] {
                for helpers in [nil, 0, 2] as [Int?] {
                    let metadata = Notices.ManagedMetadata(observation(context: context, outcome: outcome, pending: true, helpers: helpers))
                    let snapshot = notices(metadata: metadata).snapshot
                    let rendered = AgentSessionLinkPrompts.rendered(.init(membershipKind: nil, inventory: inventory(), passiveNotices: snapshot, laneGuidanceMode: .reminder))
                    for attribute in [
                        "context_used_percent=\"\(percent)\"", "context_count_confidence=\"\(confidence)\"",
                        "run_outcome=\"\(outcome.rawValue)\"", "has_pending_interaction=\"true\"",
                        "direct_running_helpers=\"\(helpers.map(String.init) ?? "unknown")\""
                    ] {
                        XCTAssertEqual(rendered.fragment.components(separatedBy: attribute).count - 1, 2, attribute)
                    }
                    XCTAssertFalse(rendered.fragment.contains("pending_interaction_kind"))
                    XCTAssertFalse(rendered.fragment.contains("interaction_id"))
                    XCTAssertEqual(rendered.passiveBatch?.entries.count, 1)
                    XCTAssertEqual(rendered.passiveBatch?.attentionRequests.count, 1)
                }
            }
        }
        let unmanaged = AgentSessionLinkPrompts.rendered(.init(membershipKind: nil, inventory: inventory(managed: false), passiveNotices: notices(metadata: nil).snapshot))
        XCTAssertFalse(unmanaged.fragment.contains("context_used_percent="))
        XCTAssertFalse(unmanaged.fragment.contains("run_outcome="))
        XCTAssertFalse(unmanaged.fragment.contains("has_pending_interaction="))
        XCTAssertFalse(unmanaged.fragment.contains("direct_running_helpers="))
        XCTAssertFalse(unmanaged.fragment.contains("Managed metadata"))
    }

    func testSupplementalRefreshPreservesWakeIdentityAndFrozenReceipt() throws {
        let initial = Notices.ManagedMetadata(observation())
        let updated = Notices.ManagedMetadata(observation(context: .init(usedTokens: 90, windowTokens: 100, confidence: .exact), outcome: .failed, pending: true, helpers: 2))
        var reducer = notices(metadata: initial)
        let before = reducer.snapshot
        let receipt = Notices.Receipt(snapshot: before)
        for metadata in [updated, nil] {
            reducer.reconcile(samples: [sample(.idle, metadata: metadata)], linkSetRevision: 1, deliverable: true, observedAt: at.addingTimeInterval(20))
            let after = reducer.snapshot
            XCTAssertEqual(after.entries.first?.managedMetadata, metadata)
            XCTAssertEqual(after.attentionRequests.first?.managedMetadata, metadata)
            XCTAssertEqual(after.entries.first?.changeSequence, before.entries.first?.changeSequence)
            XCTAssertEqual(after.entries.first?.edgeSequence, before.entries.first?.edgeSequence)
            XCTAssertEqual(after.entries.first?.observedAt, at)
            XCTAssertEqual(after.attentionRequests.first?.observedAt, at)
            XCTAssertEqual(after.attentionRequests.first?.occurrence, before.attentionRequests.first?.occurrence)
            XCTAssertEqual(after.attentionRequests.first?.requestedAt, at)
            XCTAssertEqual(after.wakeEligibilityFingerprint, before.wakeEligibilityFingerprint)
            XCTAssertTrue(try XCTUnwrap(after.entries.first).isRoutineWakeEligible)
        }
        reducer.apply(receipt)
        XCTAssertTrue(reducer.snapshot.entries.isEmpty)
        XCTAssertTrue(reducer.snapshot.attentionRequests.isEmpty)
        let revision = reducer.snapshot.queueRevision
        reducer.reconcile(samples: [sample(.idle, metadata: updated)], linkSetRevision: 1, deliverable: true)
        XCTAssertEqual(reducer.snapshot.queueRevision, revision)
        XCTAssertFalse(reducer.snapshot.hasDeliverableContent, "metadata is not independently owed")
        XCTAssertEqual(reducer.snapshot.unacknowledgedOverflowCount, 0)
        XCTAssertEqual(reducer.requestAttention(reference: reference(), targetEndpoint: endpoint(1), targetSessionID: id(1), linkSetRevision: 1, requestedAt: at), .accepted)
        XCTAssertEqual(reducer.snapshot.attentionRequests.first?.managedMetadata, updated, "standalone attention uses the newest cached sample")
    }

    func testAvailabilityOnlyPublicationRefreshesCacheWithoutReleasingParkedChangeWait() async throws {
        let authority = DomainAgentSessionLinkAuthority(identity: .init(runtimeID: id(500), lifecycleGeneration: 1, processID: 1, mode: .app, createdAt: at))
        let observer = endpoint(0)
        let target = endpoint(1)
        guard case let .reserved(reservation, _) = await authority.reserveLink(observer: observer, target: target),
              case .activated = await authority.activateLink(reservation: reservation, initialSnapshot: observation(), sourcePublicationSequence: 1) else { return XCTFail("activation failed") }
        let lease = try await authority.authorize(operation: .monitorWait, observerEndpoint: observer, targetSessionID: target.sessionID).get()
        let initialState = await authority.targetState(for: lease)
        let initial = try XCTUnwrap(initialState)
        let initialRevision = await authority.snapshot().authorityRevision
        let waiter = Task { await authority.wait(requests: [.init(lease: lease, cursor: initial.waitCursor)], until: .change, timeoutSeconds: 30) }
        defer { waiter.cancel() }
        try await AsyncTestWait.waitUntil("availability regression's change waiter is parked") {
            await authority.snapshot().parkedWaiterCount == 1
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(AgentSessionLinkResponseRenderer.laneBoardValue(initial.snapshot.board))
        var previous = observation()
        for (sequence, helpers) in [(UInt64(2), Optional(0)), (UInt64(3), nil)] {
            let incoming = observation(helpers: helpers)
            XCTAssertNotEqual(incoming, previous, "internal equality must retain availability")
            XCTAssertEqual(try encoder.encode(AgentSessionLinkResponseRenderer.laneBoardValue(incoming.board)), encoded)
            let result = await authority.publishTargetSnapshot(endpoint: target, snapshot: incoming, sourcePublicationSequence: sequence, runFacts: .init(settledThrough: sequence, ordinaryThrough: sequence))
            XCTAssertEqual(result, .unchanged(changeSequence: initial.changeSequence))
            let cached = await authority.observationSnapshot(forTargetEndpoint: target)
            XCTAssertEqual(cached?.snapshot.board.directRunningHelperCount, helpers)
            XCTAssertEqual(cached?.sourcePublicationSequence, sequence)
            XCTAssertEqual(cached?.runFacts?.settledThrough, sequence)
            let state = await authority.targetState(for: lease)
            XCTAssertEqual(state?.changeSequence, initial.changeSequence)
            let diagnostics = await authority.snapshot()
            XCTAssertEqual(diagnostics.authorityRevision, initialRevision)
            XCTAssertEqual(diagnostics.parkedWaiterCount, 1, "private availability cannot release a public change waiter")
            previous = incoming
        }
        let stale = await authority.publishTargetSnapshot(endpoint: target, snapshot: observation(helpers: 0), sourcePublicationSequence: 2)
        XCTAssertEqual(stale, .stale(currentSourcePublicationSequence: 3))
        let stillUnknown = await authority.observationSnapshot(forTargetEndpoint: target)
        XCTAssertNil(stillUnknown?.snapshot.board.directRunningHelperCount)
        let changed = await authority.publishTargetSnapshot(endpoint: target, snapshot: observation(helpers: 1), sourcePublicationSequence: 4)
        XCTAssertEqual(changed, .accepted(changeSequence: initial.changeSequence + 1))
        let completed = await waiter.value
        XCTAssertEqual(completed.outcome, .changed(sessionID: target.sessionID))
        XCTAssertEqual(completed.targets.first?.snapshot.board.directRunningHelperCount, 1)
    }

    func testManagedProofSuspensionRevalidatesMixedWatchMembershipBeforeOrdinaryRelease() async throws {
        let observer = endpoint(0)
        let authority = DomainAgentSessionLinkAuthority(identity: .init(runtimeID: id(500), lifecycleGeneration: 1, processID: 1, mode: .app, createdAt: at))
        var grants: [DomainAgentSessionLinkGrant] = []
        for number in 1 ... 2 {
            guard case let .reserved(reservation, _) = await authority.reserveLink(observer: observer, target: endpoint(number), capabilities: number == 1 ? [.poll, .manage] : [.poll]),
                  case let .activated(activation) = await authority.activateLink(reservation: reservation, initialSnapshot: .init(sessionID: id(number), displayName: "Worker", providerDisplayName: nil, status: .idle, board: .empty, idleForSend: false, pendingInteractionKind: nil, latestVisibleAssistantPreview: nil, visibleRowCount: 0, lastActivityAt: at), sourcePublicationSequence: 1) else { return XCTFail("activation failed") }
            grants.append(activation.grant)
        }
        func samples(_ status: Notices.Status, includeWatch: Bool) -> [Notices.Sample] {
            grants.prefix(includeWatch ? 2 : 1).enumerated().map { index, grant in
                .init(reference: .init(linkID: grant.id, generation: grant.generation), targetEndpoint: grant.target, targetSessionID: grant.target.sessionID, displayName: index == 0 ? "MANAGED-A" : "WATCH-B", status: status, managedMetadata: index == 0 ? .init(observation()) : nil)
            }
        }
        func liveInventory(_ revision: UInt64, includeWatch: Bool) -> AgentSessionLinkPromptInventory {
            .init(observerSessionID: observer.sessionID, linkSetRevision: revision, items: grants.prefix(includeWatch ? 2 : 1).enumerated().map { index, grant in
                .init(targetSessionID: grant.target.sessionID, displayName: index == 0 ? "MANAGED-A" : "WATCH-B", capabilityNames: index == 0 ? ["poll", "manage"] : ["poll"], reference: .init(linkID: grant.id, generation: grant.generation))
            })
        }
        var reducer = Notices(observerEndpoint: observer)
        reducer.enable(samples: samples(.running, includeWatch: true), linkSetRevision: 1, observedAt: at)
        reducer.reconcile(samples: samples(.idle, includeWatch: true), linkSetRevision: 1, deliverable: true, observedAt: at)
        let store = AgentSessionLinkOutboundPromptClaimStore()
        let epoch = AgentSessionLinkPromptEpoch(endpoint: observer, allowsSupplement: true, providerContext: .codexExec)
        let dispatch = AgentSessionLinkPromptDispatchID.headlessRun(runID: id(200))
        let original = try XCTUnwrap(store.claim(dispatchID: dispatch, epoch: epoch, inventory: liveInventory(1, includeWatch: true), passiveNotices: reducer.snapshot, render: AgentSessionLinkPrompts.rendered))
        XCTAssertEqual(original.managedMetadataRequirements.count, 1)
        XCTAssertTrue(original.fragment.contains("WATCH-B"))
        let gate = TestReleaseFence(name: "managed proof with mixed watch membership")
        let proving = Task { await AgentSessionLinkProviderInputRelease.prove(original, managedProof: { observer, requirements in
            await gate.enterAndWait()
            return await authority.managedObservationAuthorizations(observer: observer, requirements: requirements)
        }) { _ in XCTFail("no local input")
            return false
        } }
        defer { gate.release()
            proving.cancel()
        }
        guard await gate.waitUntilEntered() else { return XCTFail("proof did not suspend") }
        _ = await authority.revoke(linkID: grants[1].id, generation: grants[1].generation, reason: .userRequested)
        reducer.reconcile(samples: samples(.idle, includeWatch: false), linkSetRevision: 2, deliverable: true, observedAt: at)
        XCTAssertTrue(store.isPending(original), "pending status alone does not revalidate membership")
        gate.release()
        let proof = await proving.value
        var reclaimCalls = 0
        let released = AgentSessionLinkProviderInputRelease.handoff(original: original, proof: proof, current: {
            reclaimCalls += 1
            return store.claimOutcome(dispatchID: dispatch, epoch: epoch, inventory: liveInventory(2, includeWatch: false), passiveNotices: reducer.snapshot, render: AgentSessionLinkPrompts.rendered)
        }, isPending: store.isPending, consume: { _ in false })
        XCTAssertEqual(reclaimCalls, 1)
        XCTAssertFalse(released.mustAbortDispatch)
        XCTAssertFalse(try XCTUnwrap(released.fragment).contains("WATCH-B"))
        XCTAssertTrue(try XCTUnwrap(released.fragment).contains("MANAGED-A"))
        XCTAssertEqual(released.claim?.passive?.receipt.deliveredStatuses.map(\.targetEndpoint), [grants[0].target])
        XCTAssertTrue(try store.isPending(XCTUnwrap(released.claim)), "handoff does not pay the receipt")
    }

    func testMetadataIsExcludedFromSampleIdentityAndNondeliverableRevision() {
        let old = sample(.idle, metadata: .init(observation()))
        let new = sample(.idle, metadata: .init(observation(outcome: .failed, helpers: 0)))
        XCTAssertEqual(old, new)
        XCTAssertEqual(Set([old, new]).count, 1)
        var reducer = Notices(observerEndpoint: endpoint(0))
        reducer.enable(samples: [old], linkSetRevision: 1, deliverable: false, observedAt: at)
        let revision = reducer.snapshot.queueRevision
        reducer.reconcile(samples: [new], linkSetRevision: 1, deliverable: false, observedAt: at.addingTimeInterval(1))
        XCTAssertEqual(reducer.snapshot.queueRevision, revision)
        XCTAssertFalse(reducer.snapshot.hasDeliverableContent)
    }

    private func authorization(_ requirement: DomainAgentSessionManagedObservationRequirement, observer: DomainAgentSessionLinkEndpointIdentity, fence: DomainAgentSessionLinkRevocationFence) -> DomainAgentSessionLinkCommitAuthorization {
        let grant = DomainAgentSessionLinkGrant(id: requirement.reference.linkID, generation: requirement.reference.generation, observer: observer, target: requirement.target, createdAt: at, capabilities: [.manage])
        let lease = DomainAgentSessionLinkLease(leaseID: id(600), runtimeID: id(601), runtimeGeneration: 1, linkID: grant.id, linkGeneration: grant.generation, capability: .manage, observer: observer, target: requirement.target, issuedAt: at)
        return .init(lease: lease, fence: fence, grant: grant, consent: nil, elevation: nil, now: { Date(timeIntervalSince1970: 1000) })
    }

    func testAcceptedReplayKeepsFrozenBytesAfterReceiptAndStillChecksRevocation() async throws {
        var reducer = notices(metadata: .init(observation(helpers: 0)))
        let store = AgentSessionLinkOutboundPromptClaimStore()
        let epoch = AgentSessionLinkPromptEpoch(endpoint: endpoint(0), allowsSupplement: true, providerContext: .codexExec)
        let dispatch = AgentSessionLinkPromptDispatchID.headlessRun(runID: id(200))
        let claim = try XCTUnwrap(store.claim(dispatchID: dispatch, epoch: epoch, inventory: inventory(), passiveNotices: reducer.snapshot, render: AgentSessionLinkPrompts.rendered))
        XCTAssertEqual(claim.managedMetadataRequirements.count, 1, "both rendered row kinds deduplicate the same exact requirement")
        XCTAssertEqual(claim.passive?.receipt.deliveredStatuses.count, 1)
        XCTAssertEqual(claim.passive?.receipt.deliveredAttentionOccurrences.count, 1)
        store.accept(claim)
        try reducer.apply(XCTUnwrap(claim.passive?.receipt))
        XCTAssertFalse(reducer.snapshot.hasDeliverableContent)
        XCTAssertNil(store.claim(dispatchID: dispatch, epoch: epoch, inventory: inventory(), passiveNotices: reducer.snapshot, render: AgentSessionLinkPrompts.rendered))
        let fence = DomainAgentSessionLinkRevocationFence()
        let proof = await AgentSessionLinkProviderInputRelease.prove(claim.baselineOnly, managedProof: { observer, requirements in
            requirements.map { self.authorization($0, observer: observer, fence: fence) }
        }) { _ in false }
        let current = store.canReuseAcceptedClaim(claim, dispatchID: dispatch, epoch: epoch, inventory: inventory())
        XCTAssertTrue(current)
        let replay = AgentSessionLinkProviderInputRelease.handoffAcceptedReplay(claim.baselineOnly, proof: proof, isCurrent: current, requiresLaneBatch: false)
        XCTAssertEqual(replay.fragment, claim.fragment)
        XCTAssertEqual(replay.claim?.passive?.receipt, claim.passive?.receipt)
        fence.revoke()
        let refused = AgentSessionLinkProviderInputRelease.handoffAcceptedReplay(claim.baselineOnly, proof: proof, isCurrent: current, requiresLaneBatch: true)
        XCTAssertTrue(refused.mustAbortDispatch)
        XCTAssertNil(refused.fragment)
    }

    func testReclaimCanReorderOrRemoveProvenRequirementsButCannotAddOne() async throws {
        let store = AgentSessionLinkOutboundPromptClaimStore()
        let claim = try XCTUnwrap(store.claim(dispatchID: .autoWake(wakeID: id(200)), epoch: .init(endpoint: endpoint(0), allowsSupplement: true, providerContext: .codexExec), inventory: inventory(count: 2), passiveNotices: notices(metadata: .init(observation()), count: 2).snapshot, render: AgentSessionLinkPrompts.rendered))
        XCTAssertEqual(claim.managedMetadataRequirements.count, 2)
        let proof = await AgentSessionLinkProviderInputRelease.prove(claim, managedProof: { observer, requirements in
            requirements.map { self.authorization($0, observer: observer, fence: .init()) }
        }) { _ in false }
        var replacement = claim
        replacement.managedMetadataRequirements.reverse()
        for requirements in [replacement.managedMetadataRequirements, Array(replacement.managedMetadataRequirements.prefix(1))] {
            replacement.managedMetadataRequirements = requirements
            let released = AgentSessionLinkProviderInputRelease.handoff(original: claim, proof: proof, current: { .claimed(replacement) }, isPending: { _ in false }, consume: { _ in false })
            XCTAssertEqual(released.claim, replacement)
            XCTAssertFalse(released.mustAbortDispatch)
        }
        replacement.managedMetadataRequirements.append(.init(reference: reference(3), target: endpoint(3)))
        let refused = AgentSessionLinkProviderInputRelease.handoff(original: claim, proof: proof, current: { .claimed(replacement) }, isPending: { _ in false }, consume: { _ in false })
        XCTAssertTrue(refused.mustAbortDispatch)
        XCTAssertNil(refused.claim)
    }

    func testRenderedBudgetAndClaimsFenceOnlyTheRenderedManagedSubset() throws {
        let metadata = Notices.ManagedMetadata(observation(helpers: 0))
        let snapshot = notices(metadata: metadata, count: 16, preview: String(repeating: "<&\"", count: 500)).snapshot
        let store = AgentSessionLinkOutboundPromptClaimStore()
        let live = inventory(count: 16)
        let epoch = AgentSessionLinkPromptEpoch(endpoint: endpoint(0), allowsSupplement: true, providerContext: .codexExec)
        let claim = try XCTUnwrap(store.claim(dispatchID: .autoWake(wakeID: id(200)), epoch: epoch, inventory: live, passiveNotices: snapshot, render: AgentSessionLinkPrompts.rendered))
        XCTAssertLessThanOrEqual(claim.fragment.utf8.count, AgentSessionLinkPrompts.maximumRenderedBytes)
        let receipt = try XCTUnwrap(claim.passive?.receipt)
        let renderedReferences = Set(receipt.deliveredStatuses.map(\.reference) + receipt.deliveredAttentionOccurrences.map(\.reference))
        XCTAssertEqual(Set(claim.managedMetadataRequirements.map(\.reference)), renderedReferences)
        XCTAssertEqual(claim.managedMetadataRequirements.count, renderedReferences.count, "status and attention share one exact requirement")
        XCTAssertLessThan(receipt.deliveredStatuses.count + receipt.deliveredAttentionOccurrences.count, 32, "worst-case rows must defer under the shared cap")
        // A real receipt is queue-qualified; use the source queue to verify subset removal separately.
        var reducer = notices(metadata: metadata, count: 16, preview: String(repeating: "<&\"", count: 500))
        let rendered = AgentSessionLinkPrompts.rendered(.init(membershipKind: nil, inventory: live, passiveNotices: reducer.snapshot))
        let batch = try XCTUnwrap(rendered.passiveBatch)
        reducer.apply(.init(queueEpoch: reducer.snapshot.queueEpoch, queueRevision: reducer.snapshot.queueRevision, deliveredStatuses: batch.entries.map(Notices.DeliveredStatus.init), deliveredAttentionOccurrences: batch.attentionRequests.map(\.occurrence), overflowProducedThrough: batch.overflowProducedThrough))
        XCTAssertEqual(reducer.snapshot.entries.count, 16 - batch.entries.count)
        XCTAssertEqual(reducer.snapshot.attentionRequests.count, 16 - batch.attentionRequests.count)
    }

    func testStaleManagedSnapshotCannotBeClaimedAgainstWatchOnlyInventory() {
        let store = AgentSessionLinkOutboundPromptClaimStore()
        let outcome = store.claimOutcome(dispatchID: .autoWake(wakeID: id(200)), epoch: .init(endpoint: endpoint(0), allowsSupplement: true, providerContext: .codexExec), inventory: inventory(managed: false), passiveNotices: notices(metadata: .init(observation())).snapshot, render: AgentSessionLinkPrompts.rendered)
        XCTAssertTrue(outcome.mustAbortDispatch)
        XCTAssertNil(outcome.claim)
    }

    func testPhysicalHandoffRejectsManageWithdrawalAfterProofWithoutAcknowledging() async {
        let observer = endpoint(0)
        let target = endpoint(1)
        let authority = DomainAgentSessionLinkAuthority(identity: .init(runtimeID: id(500), lifecycleGeneration: 1, processID: 1, mode: .app, createdAt: at))
        let elevation = DomainAgentSessionLinkCapabilityElevation()
        await authority.installCapabilityElevation(elevation)
        guard case let .reserved(reservation, _) = await authority.reserveLink(observer: observer, target: target, capabilities: [.poll]),
              case let .activated(activation) = await authority.activateLink(reservation: reservation, initialSnapshot: observation(), sourcePublicationSequence: 1) else { return XCTFail("fixture activation failed") }
        let requirement = DomainAgentSessionManagedObservationRequirement(reference: .init(linkID: activation.grant.id, generation: activation.grant.generation), target: target)
        let denied = await authority.managedObservationAuthorizations(observer: observer, requirements: [requirement])
        XCTAssertNil(denied)
        for automatic in [false, true] {
            elevation.elevate(observer: observer.sessionID)
            var claim = AgentSessionLinkOutboundPromptClaim(observerSessionID: observer.sessionID, dispatchID: automatic ? .autoWake(wakeID: id(200)) : .headlessRun(runID: id(201)), epochToken: .init(), fragment: "managed cached metadata", observerEndpoint: observer)
            claim.managedMetadataRequirements = [requirement]
            let proof = await AgentSessionLinkProviderInputRelease.prove(claim, managedProof: { observer, requirements in
                await authority.managedObservationAuthorizations(observer: observer, requirements: requirements)
            }) { _ in XCTFail("no local-input read requested")
                return false
            }
            let allowed = AgentSessionLinkProviderInputRelease.handoff(original: claim, proof: proof, current: { .claimed(claim) }, isPending: { _ in true }, consume: { _ in false })
            XCTAssertEqual(allowed.fragment, claim.fragment)
            elevation.revokeAll()
            let revoked = AgentSessionLinkProviderInputRelease.handoff(original: claim, proof: proof, current: { XCTFail("must reject before reclaim")
                return .claimed(claim)
            }, isPending: { _ in true }, consume: { _ in false })
            XCTAssertNil(revoked.fragment)
            XCTAssertNil(revoked.claim, "no receipt can be applied for refused content")
            XCTAssertEqual(revoked.mustAbortDispatch, automatic)
            XCTAssertEqual(revoked.text("user text"), "user text")
        }
    }
}

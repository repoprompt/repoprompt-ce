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
            failureReason: .timeout,
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
        XCTAssertEqual(observed.board.failureReason, .timeout)

        session.runState = .completed
        XCTAssertNil(snapshot(for: session, candidate: candidate(tabID: tabID)).board.failureReason)
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
            externalMCPComposition: FigmaMCPTestGraph.make(),
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in
                preconditionFailure("Lane-board tests must not start a provider")
            }
        )
        let observed = viewModel.agentSessionLinkObservationSnapshot(for: candidate(tabID: UUID()))
        XCTAssertFalse(observed.idleForSend)
        XCTAssertEqual(observed.board.sendBlockers, [AgentModeViewModel.SendBlocker.sessionUnavailable.rawValue])
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
            externalMCPComposition: FigmaMCPTestGraph.make(),
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
            externalMCPComposition: FigmaMCPTestGraph.make(),
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
            externalMCPComposition: FigmaMCPTestGraph.make(),
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
            externalMCPComposition: FigmaMCPTestGraph.make(),
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
            externalMCPComposition: FigmaMCPTestGraph.make(),
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

        // The full listing path does backfill, which is exactly what the hot path avoids.
        _ = try await AgentSessionDataService.shared.listAgentSessionsMeta(for: workspace)
        XCTAssertTrue(indexFileExists())
        let cached = await viewModel.agentSessionLinkPersistedSubagentMetaLoader(workspace)
        XCTAssertEqual(cached?.count, 0, "an existing index is served, not reported unavailable")
    }
}

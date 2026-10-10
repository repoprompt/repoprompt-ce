import Foundation
@testable import RepoPromptApp
@_spi(TestSupport) @testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptSecureStorage
import XCTest

/// Live-view-model coverage for the overseer `compact` transaction.
///
/// Compaction reuses the send contract — the same readiness gate, composer claim, commit fence, and
/// durable-before-dispatch ordering — and differs only in what it records and dispatches: an
/// attributed `.system` request row and a RepoPrompt-constructed native command instead of a user
/// row and an envelope.
@MainActor
final class AgentSessionLinkCompactTransactionTests: XCTestCase {
    private struct Fixture {
        let viewModel: AgentModeViewModel
        let manager: WorkspaceManagerViewModel
        let tabID: UUID
        let session: AgentModeViewModel.TabSession
        let candidate: AgentSessionLinkEndpointCandidate
        let events: LiveSendEventLog
        let claude: CompactRecordingNativeController
        let codexRecorder: LifecycleRecorder
        let driftHook: AgentSessionLinkSendTransactionLiveTests.LiveSendDriftHook
        let managesCodexTooling: Bool
    }

    @MainActor
    private final class FirstSaveGate {
        private var entered = false
        private var enteredWaiter: CheckedContinuation<Void, Never>?
        private var releaseWaiter: CheckedContinuation<Void, Never>?

        func pause() async {
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

    private var retainedViewModels: [AgentModeViewModel] = []

    override func tearDown() {
        retainedViewModels.removeAll()
        super.tearDown()
    }

    private func makeFixture(
        agent: AgentProviderKind = .claudeCode,
        providerConversation: Bool = true,
        shouldManageCodexTooling: Bool = false,
        codexResumeGate: TestReleaseFence? = nil,
        saverBehavior: LiveSendEventLog.SaverBehavior = .succeed,
        firstSaveGate: FirstSaveGate? = nil,
        secondSaveGate: FirstSaveGate? = nil,
        codexStallWatchdogProbeThreshold: TimeInterval? = nil,
        codexStallWatchdogRecoveryThreshold: TimeInterval? = nil,
        codexStallWatchdogPollIntervalNanos: UInt64? = nil,
        codexSnapshotLatestTurnStatus: CodexNativeSessionController.TurnStatus? = nil
    ) throws -> Fixture {
        let events = LiveSendEventLog()
        let driftHook = AgentSessionLinkSendTransactionLiveTests.LiveSendDriftHook()
        let claude = CompactRecordingNativeController()
        let codexRecorder = LifecycleRecorder()
        let tabID = UUID()
        let fileManager = WorkspaceFilesViewModel()
        let keyManager = KeyManager(secureService: SecureKeysService(secureStorage: TestSecureStorageBackend()))
        let apiSettings = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )
        let prompt = PromptViewModel(
            fileManager: fileManager,
            apiSettingsViewModel: apiSettings,
            windowID: -1,
            settingsManager: WindowSettingsManager(windowID: -1)
        )
        let manager = WorkspaceManagerViewModel(
            fileManager: fileManager,
            promptViewModel: prompt,
            performInitialWorkspaceActivation: false
        )
        let workspace = WorkspaceModel(
            name: "Overseer compaction",
            repoPaths: [],
            ephemeralFlag: true,
            composeTabs: [ComposeTabState(id: tabID)],
            activeComposeTabID: tabID
        )
        manager.workspaces = [workspace]
        manager.activeWorkspace = workspace

        let viewModel = AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            shouldManageCodexTooling: shouldManageCodexTooling,
            codexControllerFactory: { _, _, _, _, _, _ in
                events.record(.providerControllerCreated)
                return LifecycleNoopCodexController(
                    recorder: codexRecorder,
                    resumeGate: codexResumeGate,
                    snapshotLatestTurnStatus: codexSnapshotLatestTurnStatus
                )
            },
            claudeControllerFactory: { _, _, _, _ in
                events.record(.providerControllerCreated)
                return claude
            },
            connectionPolicyInstaller: { clientName, windowID, restrictedTools, oneShot, reason, ttl, tabID, runID, additionalTools, purpose, taskLabelKind, allowsExternalControl, requiresExpectedPID in
                guard shouldManageCodexTooling else { return }
                await ServerNetworkManager.shared.installClientConnectionPolicy(
                    for: clientName, windowID: windowID, restrictedTools: restrictedTools,
                    oneShot: oneShot, reason: reason, ttl: ttl, tabID: tabID, runID: runID,
                    additionalTools: additionalTools, purpose: purpose, taskLabelKind: taskLabelKind,
                    allowsAgentExternalControlTools: allowsExternalControl,
                    requiresExpectedAgentPID: requiresExpectedPID
                )
            },
            mcpServerEnabler: { true },
            testCodexStallWatchdogPollIntervalNanos: codexStallWatchdogPollIntervalNanos,
            testCodexStallWatchdogProbeThreshold: codexStallWatchdogProbeThreshold,
            testCodexStallWatchdogRecoveryThreshold: codexStallWatchdogRecoveryThreshold
        )
        retainedViewModels.append(viewModel)
        viewModel.workspaceManager = manager
        viewModel.test_setCurrentTabIDOverride(tabID)
        viewModel.test_setAgentSessionSaver { agentSession, _, _ in
            let saveIndex = events.recordSave(items: agentSession.toLiveItems())
            if saveIndex == 0 {
                driftHook.duringDeliveryFlush?()
                await firstSaveGate?.pause()
            } else if saveIndex == 1 {
                await secondSaveGate?.pause()
            }
            switch saverBehavior {
            case .succeed:
                break
            case .fail:
                throw LiveSendEventLog.SaveFailure()
            case .failFirst:
                if saveIndex == 0 { throw LiveSendEventLog.SaveFailure() }
            }
            return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(UUID().uuidString).json")
        }

        let session = viewModel.session(for: tabID)
        session.selectedAgent = agent
        session.hasLoadedPersistedState = true
        if providerConversation {
            session.providerSessionID = "provider-conversation"
            session.codexConversationID = "codex-thread"
        }
        let sessionID = try XCTUnwrap(viewModel.test_ensureSessionBoundToTab(session))
        let candidate = try XCTUnwrap(viewModel.agentSessionLinkCandidate(
            tabID: tabID,
            sessionID: sessionID,
            tabName: "Build API",
            isWindowClosing: false
        ))
        if shouldManageCodexTooling {
            addTeardownBlock { @MainActor in
                let runID = session.runID
                await viewModel.test_codexCoordinator.shutdownCodexSession(session)
                if let runID, let clientName = AgentProviderKind.codexExec.mcpClientNameHint {
                    await ServerNetworkManager.shared.revokeClientConnectionPolicy(
                        for: clientName, windowID: 1, runID: runID
                    )
                    await MCPRoutingWaiter.shared.cleanup(runID: runID)
                }
                _ = manager
            }
        }
        return Fixture(
            viewModel: viewModel,
            manager: manager,
            tabID: tabID,
            session: session,
            candidate: candidate,
            events: events,
            claude: claude,
            codexRecorder: codexRecorder,
            driftHook: driftHook,
            managesCodexTooling: shouldManageCodexTooling
        )
    }

    private static let observerEndpoint = DomainAgentSessionLinkEndpointIdentity(
        windowID: 2,
        workspaceID: UUID(),
        tabID: UUID(),
        sessionID: UUID(),
        persistentBindingGeneration: UUID(),
        bindingTransitionGeneration: 1
    )

    private static let liveLiveness = AgentSessionLinkSendLiveness(
        observerEndpointIsLive: true,
        targetEndpointIsLive: true,
        targetWindowIsClosing: false
    )

    private let request = AgentSessionLinkCompactRequest(
        linkID: UUID(),
        linkGeneration: 1,
        observerEndpoint: AgentSessionLinkCompactTransactionTests.observerEndpoint,
        observerDisplayName: "Planning"
    )

    private func compact(
        _ fixture: Fixture,
        liveness: @escaping AgentSessionLinkSendLivenessProbe = { liveLiveness },
        commit: @escaping @MainActor () async -> AgentSessionLinkSendCommitOutcome = { .committed }
    ) async -> AgentSessionLinkSendTransactionOutcome {
        let routing = fixture.managesCodexTooling ? Task {
            do {
                try await AsyncTestWait.waitUntil("managed compact resume staged", timeout: 4) {
                    fixture.viewModel.test_codexCoordinator.test_hasPendingCodexStart(for: fixture.session)
                }
                if !Task.isCancelled, let runID = fixture.session.runID {
                    await MCPRoutingWaiter.shared.notifyRouted(runID: runID)
                }
            } catch {
                if !Task.isCancelled { XCTFail("Managed compact routing fixture failed: \(error)") }
            }
        } : nil
        let outcome = await fixture.viewModel.agentSessionLinkPerformCompact(
            to: fixture.candidate,
            request: request,
            liveness: liveness,
            commitAuthorization: commit
        )
        routing?.cancel()
        await routing?.value
        return outcome
    }

    // MARK: - Support

    func testOnlyClaudeCodeAndCodexWithAProviderConversationAreSupported() async throws {
        for agent in AgentProviderKind.allCases {
            let fixture = try makeFixture(agent: agent)
            let expected: AgentSessionLinkCompactSupport = switch agent {
            case .claudeCode: .claudeCode
            case .codexExec: .codex
            case .devin, .grokBuild, .antigravity:
                // A remembered ACP conversation with no live session yet is retryable, not
                // incapable: one ordinary turn brings the provider session and its command
                // advertisement up.
                .noProviderSession
            default: .notSupported
            }
            let support = await fixture.viewModel.agentSessionLinkCompactSupport(for: fixture.session)
            XCTAssertEqual(support, expected, "\(agent)")
        }
        for agent in [AgentProviderKind.claudeCode, .codexExec] {
            let fixture = try makeFixture(agent: agent, providerConversation: false)
            let support = await fixture.viewModel.agentSessionLinkCompactSupport(for: fixture.session)
            XCTAssertEqual(
                support,
                .noProviderSession,
                "\(agent) with nothing to compact"
            )
        }
    }

    // MARK: - Claude Code

    func testClaudeCompactionRecordsAnAttributedSystemRowThenSendsTheBareNativeCommand() async throws {
        let fixture = try makeFixture()
        let before = fixture.session.items.count

        let outcome = await compact(fixture)

        guard case let .delivered(delivery) = outcome else {
            return XCTFail("Expected an accepted compaction, got \(outcome)")
        }
        XCTAssertEqual(delivery.deliveryState, .runStarted)
        XCTAssertFalse(
            delivery.compactionRunsInBackground,
            "Claude compacts inside the turn it was sent on; there is no background work to cancel"
        )
        XCTAssertEqual(fixture.session.items.count, before + 1)
        let row = try XCTUnwrap(fixture.session.items.last)
        XCTAssertEqual(row.id, delivery.targetItemID)
        XCTAssertEqual(row.kind, .system, "RepoPrompt issued the command, not the target's user")
        XCTAssertEqual(row.text, AgentChatItem.overseerCompactionRequestText)
        XCTAssertEqual(row.crossSessionAttribution?.sourceSessionID, request.observerSessionID)
        XCTAssertEqual(row.crossSessionAttribution?.sourceName, "Planning")
        XCTAssertTrue(fixture.session.items.allSatisfy { $0.kind != .user }, "No /compact user row is fabricated")
        XCTAssertTrue(fixture.events.savedItemsContainAttributedRow(id: row.id))
        XCTAssertTrue(fixture.events.saveHappenedBeforeProviderStart())
        // The run is started through the ordinary pipeline; the exact provider bytes are pinned by
        // `AgentSessionLinkCompactClaudeDispatchTests`, which drives the raw lane directly.
        XCTAssertEqual(fixture.session.runState, .running)
        XCTAssertNil(fixture.session.activeComposerSubmitAttempt, "The composer claim is released")
    }

    func testSelfTerminalBoundaryStartsNativeCommandPipelineAfterPersistingFixedRow() async throws {
        let fixture = try makeFixture()
        let runID = UUID()
        fixture.session.installRunID(runID)
        fixture.session.runState = .running
        let ownership = fixture.session.beginRunAttempt(source: "test.selfCompact.origin")
        let reservation = fixture.viewModel.agentSelfCompactSchedule(
            endpoint: fixture.candidate.domainEndpoint,
            runID: runID,
            runAttemptID: ownership.attemptID,
            note: "verbatim private continuation",
            idempotencyKey: "self-compact-integration",
            support: .claudeCode
        )
        guard case .scheduled = reservation else {
            return XCTFail("Expected a correlated self-compaction reservation")
        }
        fixture.session.runState = .completed
        _ = fixture.session.endRunAttempt(ifCurrent: ownership, source: "test.selfCompact.terminal")
        let revision = AgentRunTerminalCommitRevision(
            commitID: UUID(),
            ownership: ownership,
            terminalState: .completed,
            failureReason: nil,
            expectedRunID: runID,
            sourceItemsRevision: fixture.session.sourceItemsRevision,
            assistantDeltaFlushGeneration: fixture.session.assistantDeltaFlushGeneration,
            providerDrainGeneration: fixture.session.providerTerminalDrainGeneration,
            mcpPublicationEnvelope: nil,
            successorKind: nil,
            providerSuccessorID: nil
        )
        fixture.viewModel.agentSelfCompactTerminalSettled(
            session: fixture.session,
            revision: revision,
            publication: .accepted(successorEpoch: nil),
            teardownSettled: { true }
        )
        XCTAssertEqual(fixture.session.selfCompactState.active?.phase, .compactDispatchPending)
        XCTAssertFalse(fixture.events.contains(.providerControllerCreated), "No inline provider start")

        for _ in 0 ..< 500 {
            if fixture.session.selfCompactState.active?.phase == .awaitingCompactTurn { break }
            await Task.yield()
        }
        // The run-start recorder is pipeline admission, not physical transport acceptance. The
        // raw Claude dispatch suite separately pins the provider-bound bytes to exactly `/compact`.
        XCTAssertEqual(fixture.session.selfCompactState.active?.phase, .awaitingCompactTurn)
        XCTAssertTrue(fixture.session.selfCompactState.active?.compactDispatchStarted == true)
        let row = try XCTUnwrap(fixture.session.items.first {
            $0.kind == .system && $0.text == "Context compaction was requested by this session."
        })
        XCTAssertFalse(row.text.contains("verbatim private continuation"))
        XCTAssertTrue(fixture.events.saveHappenedBeforeProviderStart())
    }

    func testWriterBoundAfterReceiptBeforeDeferredNativeDispatchPreventsProviderStart() async throws {
        let gate = FirstSaveGate()
        let fixture = try makeFixture(secondSaveGate: gate)
        let runID = UUID()
        fixture.session.installRunID(runID)
        fixture.session.runState = .running
        let ownership = fixture.session.beginRunAttempt(source: "test.selfCompact.lateWriter")
        let endpoint = fixture.candidate.domainEndpoint
        let origin = AgentSelfMCPCallOrigin(endpoint: endpoint, runID: runID, runAttemptID: ownership.attemptID)
        guard case .scheduled = await fixture.viewModel.agentSelfCompactMCPAdmission(
            endpoint: endpoint, origin: origin, note: "private continuation", idempotencyKey: "late-writer"
        ) else { return XCTFail("Expected a durable scheduled receipt") }

        fixture.session.runState = .completed
        _ = fixture.session.endRunAttempt(ifCurrent: ownership, source: "test.selfCompact.lateWriterTerminal")
        let revision = AgentRunTerminalCommitRevision(
            commitID: UUID(), ownership: ownership, terminalState: .completed,
            failureReason: nil, expectedRunID: runID,
            sourceItemsRevision: fixture.session.sourceItemsRevision,
            assistantDeltaFlushGeneration: fixture.session.assistantDeltaFlushGeneration,
            providerDrainGeneration: fixture.session.providerTerminalDrainGeneration,
            mcpPublicationEnvelope: nil, successorKind: nil, providerSuccessorID: nil
        )
        fixture.viewModel.agentSelfCompactTerminalSettled(
            session: fixture.session, revision: revision,
            publication: .accepted(successorEpoch: nil), teardownSettled: { true }
        )
        await gate.waitUntilEntered()
        let otherTabID = UUID()
        let competing = fixture.viewModel.session(for: otherTabID)
        competing.installPersistentSessionBinding(AgentPersistentSessionBindingIdentity(
            tabID: otherTabID, sessionID: endpoint.sessionID
        ))
        gate.release()
        for _ in 0 ..< 500 {
            if fixture.session.selfCompactState.active == nil { break }
            await Task.yield()
        }
        XCTAssertNil(fixture.session.selfCompactState.active)
        XCTAssertEqual(fixture.session.selfCompactState.latest?.outcome, .cancelled)
        XCTAssertFalse(fixture.events.contains(.providerControllerCreated))
    }

    func testSelfMCPAdmissionPersistsExactOriginBeforeReceiptAndReplaysOnlyIdenticalKey() async throws {
        let fixture = try makeFixture()
        let runID = UUID()
        fixture.session.installRunID(runID)
        fixture.session.runState = .running
        let ownership = fixture.session.beginRunAttempt(source: "test.selfCompact.mcp")
        let endpoint = fixture.candidate.domainEndpoint
        let origin = AgentSelfMCPCallOrigin(
            endpoint: endpoint, runID: runID, runAttemptID: ownership.attemptID
        )
        fixture.session.isDirty = false // The reservation itself must make the required save necessary.

        let first = await fixture.viewModel.agentSelfCompactMCPAdmission(
            endpoint: endpoint, origin: origin,
            note: "continue exactly", idempotencyKey: "self-mcp-key"
        )
        guard case let .scheduled(attempt) = first else {
            return XCTFail("Expected a durable scheduled receipt")
        }
        XCTAssertEqual(attempt.admittedSupport, .claudeCode)
        XCTAssertTrue(fixture.events.contains(.save), "reservation must persist before receipt")
        XCTAssertFalse(fixture.events.contains(.providerControllerCreated), "no inline native dispatch")

        let replay = await fixture.viewModel.agentSelfCompactMCPAdmission(
            endpoint: endpoint, origin: origin,
            note: "continue exactly", idempotencyKey: "self-mcp-key"
        )
        guard case let .duplicate(requestID, status) = replay else {
            return XCTFail("Expected same-key retry to replay")
        }
        XCTAssertEqual(requestID, attempt.id)
        XCTAssertEqual(status?.phase, AgentSelfCompactAttempt.Phase.scheduled.rawValue)

        let conflict = await fixture.viewModel.agentSelfCompactMCPAdmission(
            endpoint: endpoint, origin: origin,
            note: "changed", idempotencyKey: "self-mcp-key"
        )
        guard case let .blocked(reason) = conflict else { return XCTFail("Expected conflict") }
        XCTAssertEqual(reason, "idempotency_conflict")
        let rebound = AgentSelfMCPCallOrigin(
            endpoint: endpoint, runID: runID, runAttemptID: UUID()
        )
        let unavailable = await fixture.viewModel.agentSelfCompactMCPAdmission(
            endpoint: endpoint, origin: rebound,
            note: "continue exactly", idempotencyKey: "other-key"
        )
        guard case .unavailable = unavailable else { return XCTFail("Rebound attempt must be denied") }
        XCTAssertEqual(fixture.session.selfCompactState.active?.id, attempt.id)
    }

    func testSameKeyRetryCannotClaimScheduledWhileFirstReservationSaveIsPending() async throws {
        let gate = FirstSaveGate()
        let fixture = try makeFixture(firstSaveGate: gate)
        let runID = UUID()
        fixture.session.installRunID(runID)
        fixture.session.runState = .running
        let ownership = fixture.session.beginRunAttempt(source: "test.selfCompact.pendingSave")
        fixture.session.isDirty = false
        let endpoint = fixture.candidate.domainEndpoint
        let origin = AgentSelfMCPCallOrigin(
            endpoint: endpoint, runID: runID, runAttemptID: ownership.attemptID
        )
        let first = Task { @MainActor in
            await fixture.viewModel.agentSelfCompactMCPAdmission(
                endpoint: endpoint, origin: origin,
                note: "pending note", idempotencyKey: "same-key-pending"
            )
        }
        await gate.waitUntilEntered()
        let retry = await fixture.viewModel.agentSelfCompactMCPAdmission(
            endpoint: endpoint, origin: origin,
            note: "pending note", idempotencyKey: "same-key-pending"
        )
        guard case let .blocked(reason) = retry else {
            gate.release()
            return XCTFail("A retry must not claim scheduled before the first save commits")
        }
        XCTAssertEqual(reason, "persistence_pending")
        gate.release()
        guard case let .scheduled(attempt) = await first.value else {
            return XCTFail("Expected the first admission after its save")
        }
        let committedRetry = await fixture.viewModel.agentSelfCompactMCPAdmission(
            endpoint: endpoint, origin: origin,
            note: "pending note", idempotencyKey: "same-key-pending"
        )
        guard case let .duplicate(requestID, _) = committedRetry else {
            return XCTFail("Expected idempotent replay after commit")
        }
        XCTAssertEqual(requestID, attempt.id)
    }

    func testSelfMCPAdmissionRejectsCompetingWriterArrivingDuringRequiredSave() async throws {
        let gate = FirstSaveGate()
        let fixture = try makeFixture(firstSaveGate: gate)
        let runID = UUID()
        fixture.session.installRunID(runID)
        fixture.session.runState = .running
        let ownership = fixture.session.beginRunAttempt(source: "test.selfCompact.writerDuringSave")
        fixture.session.isDirty = false
        let endpoint = fixture.candidate.domainEndpoint
        let origin = AgentSelfMCPCallOrigin(
            endpoint: endpoint, runID: runID, runAttemptID: ownership.attemptID
        )
        let admission = Task { @MainActor in
            await fixture.viewModel.agentSelfCompactMCPAdmission(
                endpoint: endpoint, origin: origin,
                note: "retain for recovery", idempotencyKey: "writer-during-save"
            )
        }
        await gate.waitUntilEntered()
        let otherTabID = UUID()
        let competing = fixture.viewModel.session(for: otherTabID)
        competing.installPersistentSessionBinding(AgentPersistentSessionBindingIdentity(
            tabID: otherTabID, sessionID: endpoint.sessionID
        ))
        gate.release()

        let result = await admission.value
        guard case let .blocked(reason) = result else {
            return XCTFail("A new competing writer must prevent a scheduled receipt")
        }
        XCTAssertEqual(reason, "session_not_exclusive")
        XCTAssertNil(fixture.session.selfCompactState.active)
        XCTAssertEqual(fixture.session.selfCompactState.latest?.outcome, .cancelled)
        XCTAssertFalse(fixture.events.contains(.providerControllerCreated))
    }

    func testSelfMCPAdmissionPersistenceFailureNeverLeavesExecutableRequest() async throws {
        let gate = FirstSaveGate()
        let fixture = try makeFixture(saverBehavior: .fail, firstSaveGate: gate)
        let runID = UUID()
        fixture.session.installRunID(runID)
        fixture.session.runState = .running
        let ownership = fixture.session.beginRunAttempt(source: "test.selfCompact.failedSave")
        fixture.session.isDirty = false
        let endpoint = fixture.candidate.domainEndpoint
        let origin = AgentSelfMCPCallOrigin(
            endpoint: endpoint, runID: runID, runAttemptID: ownership.attemptID
        )

        let first = Task { @MainActor in
            await fixture.viewModel.agentSelfCompactMCPAdmission(
                endpoint: endpoint, origin: origin,
                note: "retain after failed save", idempotencyKey: "failed-save-key"
            )
        }
        await gate.waitUntilEntered()
        let retry = await fixture.viewModel.agentSelfCompactMCPAdmission(
            endpoint: endpoint, origin: origin,
            note: "retain after failed save", idempotencyKey: "failed-save-key"
        )
        guard case let .blocked(pendingReason) = retry else {
            gate.release()
            return XCTFail("A retry must not claim scheduled before a failing save")
        }
        XCTAssertEqual(pendingReason, "persistence_pending")
        gate.release()
        let result = await first.value
        guard case let .blocked(reason) = result else {
            return XCTFail("Expected an indeterminate persistence refusal")
        }
        XCTAssertEqual(reason, "persistence_indeterminate")
        XCTAssertNil(fixture.session.selfCompactState.active)
        XCTAssertEqual(fixture.session.selfCompactState.latest?.outcome, .recoveryRequired)
        XCTAssertEqual(fixture.session.selfCompactState.latest?.recoveryNote, "retain after failed save")
        XCTAssertFalse(fixture.events.contains(.providerControllerCreated))
    }

    func testSelfMCPAdmissionRefusesDuplicateWriterEvenWithinOneWindow() async throws {
        let fixture = try makeFixture()
        let runID = UUID()
        fixture.session.installRunID(runID)
        fixture.session.runState = .running
        let ownership = fixture.session.beginRunAttempt(source: "test.selfCompact.duplicateWriter")
        let endpoint = fixture.candidate.domainEndpoint
        let otherTabID = UUID()
        let other = fixture.viewModel.session(for: otherTabID)
        other.installPersistentSessionBinding(AgentPersistentSessionBindingIdentity(
            tabID: otherTabID, sessionID: endpoint.sessionID
        ))
        let origin = AgentSelfMCPCallOrigin(
            endpoint: endpoint, runID: runID, runAttemptID: ownership.attemptID
        )

        let result = await fixture.viewModel.agentSelfCompactMCPAdmission(
            endpoint: endpoint, origin: origin,
            note: "continue", idempotencyKey: "duplicate-writer-key"
        )
        guard case let .blocked(reason) = result else { return XCTFail("Expected nonexclusive refusal") }
        XCTAssertEqual(reason, "session_not_exclusive")
        XCTAssertNil(fixture.session.selfCompactState.active)
        XCTAssertFalse(fixture.events.contains(.save))
    }

    func testProviderControlOptionsSkipEveryUserAugmentationAndOnlyClaudeCodeDispatchesThem() {
        let command = AgentProviderControlCommand.compact(
            expectedBinding: AgentPersistentSessionBindingIdentity(tabID: UUID(), sessionID: UUID()),
            expectedProviderConversation: "conversation"
        )
        let options = AgentDirectRunStartOptions.providerControl(command)
        XCTAssertTrue(options.skipsUserAugmentation)
        XCTAssertTrue(options.ignoresPendingHandoff, "A compaction never spends the target's staged handoff")
        XCTAssertFalse(options.isLaneUpdate)
        XCTAssertEqual(command.providerText, "/compact", "Fixed text: the conversation binding never reaches the provider")
        for agent in AgentProviderKind.allCases {
            let session = AgentModeViewModel.TabSession(tabID: UUID())
            session.selectedAgent = agent
            XCTAssertEqual(
                AgentModeRunService.dispatchesProviderControlCommand(command, for: session),
                agent == .claudeCode,
                "\(agent) without a live advertising ACP session"
            )
        }
    }

    func testAFailedLastRunIsAdmittedBecauseThatIsWhenCompactionIsNeeded() async throws {
        let fixture = try makeFixture()
        fixture.session.runState = .failed

        let outcome = await compact(fixture)

        guard case .delivered = outcome else {
            return XCTFail("A target whose last turn failed is idle and must be admissible: \(outcome)")
        }
    }

    func testBusyWaitingOrInteractionTargetsAreRefusedWithoutMutation() async throws {
        for runState: AgentSessionRunState in [.running, .waitingForUser, .waitingForApproval, .waitingForQuestion] {
            let fixture = try makeFixture()
            fixture.session.runState = runState
            let before = fixture.session.items.count

            let outcome = await compact(fixture)

            XCTAssertEqual(outcome, .blocked(.targetNotIdle), "\(runState)")
            XCTAssertEqual(fixture.session.items.count, before, "\(runState)")
            XCTAssertFalse(fixture.events.contains(.save), "\(runState)")
        }
    }

    func testUnsupportedOrConversationlessTargetsAreRefusedBeforeAnythingIsRecorded() async throws {
        for (agent, conversation, expected) in [
            (AgentProviderKind.claudeCodeGLM, true, AgentSessionLinkSendFailure.notSupported),
            // A stored Devin conversation with no live provider session (e.g. right after a
            // relaunch) is retryable: it is not yet knowable whether the provider compacts.
            (.devin, true, .noProviderSession),
            (.claudeCode, false, .noProviderSession),
            (.codexExec, false, .noProviderSession)
        ] {
            let fixture = try makeFixture(agent: agent, providerConversation: conversation)
            let before = fixture.session.items.count

            let outcome = await compact(fixture)

            XCTAssertEqual(outcome, .blocked(expected), "\(agent)")
            XCTAssertEqual(fixture.session.items.count, before, "\(agent)")
            XCTAssertFalse(fixture.events.contains(.save), "\(agent)")
            XCTAssertFalse(fixture.events.contains(.providerControllerCreated), "\(agent)")
        }
    }

    func testLosingTheCommitFenceRecordsAndDispatchesNothing() async throws {
        let fixture = try makeFixture()
        let before = fixture.session.items.count

        let outcome = await compact(fixture, commit: { .linkRevoked })

        XCTAssertEqual(outcome, .blocked(.linkRevoked))
        XCTAssertEqual(fixture.session.items.count, before)
        XCTAssertNil(fixture.session.activeComposerSubmitAttempt, "The composer claim is released")
        let sent = await fixture.claude.sentMessages
        XCTAssertTrue(sent.isEmpty)
    }

    func testAFailedDurableWriteRollsTheRequestRowBack() async throws {
        let fixture = try makeFixture(saverBehavior: .failFirst)
        let before = fixture.session.items.count

        let outcome = await compact(fixture)

        XCTAssertEqual(outcome, .blocked(.persistenceFailed))
        XCTAssertEqual(fixture.session.items.count, before)
        let sent = await fixture.claude.sentMessages
        XCTAssertTrue(sent.isEmpty)
    }

    func testDriftAfterTheDurableRecordWithholdsDispatch() async throws {
        let fixture = try makeFixture()
        var observerIsLive = true
        fixture.driftHook.duringDeliveryFlush = { observerIsLive = false }

        let outcome = await compact(fixture, liveness: {
            AgentSessionLinkSendLiveness(
                observerEndpointIsLive: observerIsLive,
                targetEndpointIsLive: true,
                targetWindowIsClosing: false
            )
        })

        guard case let .delivered(delivery) = outcome else {
            return XCTFail("The durable request stays recorded: \(outcome)")
        }
        XCTAssertEqual(delivery.deliveryState, .persisted)
        let sent = await fixture.claude.sentMessages
        XCTAssertTrue(sent.isEmpty, "A target that became busy must not receive the command")
    }

    func testCompactionLeavesTheTargetsWaitingOnDeclarationAlone() async throws {
        let fixture = try makeFixture()
        let declaration = try XCTUnwrap(
            DomainAgentSessionWaitingOn(summary: "CI artifact", declaredAt: Date(timeIntervalSince1970: 50))
        )
        fixture.session.oversight.waitingOn = declaration

        guard case .delivered = await compact(fixture) else { return XCTFail("Expected an accepted compaction") }

        XCTAssertEqual(
            fixture.session.oversight.waitingOn,
            declaration,
            "Compaction resolves no dependency, so it must not retire the target's declaration"
        )
    }

    func testTheAttributedRequestRowNeverRevealsItsObserverToTranscriptReaders() {
        let row = AgentChatItem.overseerCompactionRequest(attribution: request.attribution, sequenceIndex: 3)
        for reader in [request.observerSessionID, UUID(), nil] {
            XCTAssertNil(
                AgentSessionLinkTranscriptSanitizer.crossSessionOrigin(for: row, readerSessionID: reader),
                "A system row carries no cross-session origin for any reader"
            )
        }
        XCTAssertEqual(row.text, AgentChatItem.overseerCompactionRequestText, "Replay sees only the fixed text")
    }

    // MARK: - Codex

    /// A failed Codex compaction start unwinds queued fallback follow-ups, which belong to the
    /// target's own user, so an overseer compaction is refused while any exist.
    func testCodexCompactionIsRefusedWhileTheTargetUsersFallbackFollowUpsAreQueued() async throws {
        let fixture = try makeFixture(agent: .codexExec)
        fixture.session.codexFallbackQueue = [AgentTabSession.CodexFallbackQueueEntry(
            id: UUID(),
            providerText: "queued follow-up",
            images: [],
            taggedFileAttachments: [],
            model: nil,
            reasoningEffort: nil,
            serviceTier: nil,
            attachmentReservationID: nil,
            optimisticUserItemID: nil,
            draftText: "queued follow-up",
            origin: .manual,
            fallbackReason: .staleAuthoritativeIdentity,
            originThreadID: "codex-thread",
            originControllerInstanceID: ObjectIdentifier(fixture.viewModel),
            originControllerGeneration: fixture.session.codexControllerGeneration,
            originRunID: UUID(),
            originRunAttemptID: UUID(),
            blockingTurn: nil,
            state: .queued
        )]
        let before = fixture.session.items.count

        let outcome = await compact(fixture)

        XCTAssertEqual(outcome, .blocked(.targetNotIdle))
        XCTAssertEqual(fixture.session.items.count, before)
        XCTAssertEqual(fixture.session.codexFallbackQueue.count, 1, "The user's queued follow-up survives")
        XCTAssertFalse(fixture.codexRecorder.events.contains("codex:compact"))
    }

    /// A resume that lands on any other thread (a fresh-thread fallback included) must not be
    /// compacted: the conversation the overseer meant is no longer the one attached.
    func testCodexCompactionIsWithheldWhenResumeLandsOnADifferentThread() async throws {
        let fixture = try makeFixture(agent: .codexExec)
        // The stub controller always resumes into its own "lifecycle" thread.
        fixture.session.codexConversationID = "a-thread-that-will-not-come-back"

        let outcome = await compact(fixture)

        guard case let .delivered(delivery) = outcome else {
            return XCTFail("The durable request stays recorded: \(outcome)")
        }
        XCTAssertEqual(delivery.deliveryState, .persisted, "Nothing was sent to the provider")
        XCTAssertFalse(fixture.codexRecorder.events.contains("codex:compact"))
    }

    func testIdleManagedCodexCompactionResumesExactThreadWithRoutingWithoutUserTurn() async throws {
        let fixture = try makeFixture(agent: .codexExec, shouldManageCodexTooling: true)
        fixture.session.codexConversationID = "lifecycle"
        XCTAssertNil(fixture.session.codexController, "Exercise idle controller restoration")

        let outcome = await compact(fixture)

        guard case let .delivered(delivery) = outcome else {
            return XCTFail("Expected an accepted Codex compaction, got \(outcome)")
        }
        XCTAssertEqual(delivery.deliveryState, .runStarted)
        XCTAssertEqual(fixture.codexRecorder.events.count(where: { $0 == "codex:compact" }), 1)
        XCTAssertFalse(fixture.codexRecorder.events.contains("codex:send"))
        XCTAssertEqual(fixture.session.codexConversationID, "lifecycle")
    }

    func testCancellationDuringCodexResumeWithholdsCompactionAfterExactThreadReturns() async throws {
        let gate = TestReleaseFence(name: "compact Codex resume")
        let fixture = try makeFixture(agent: .codexExec, shouldManageCodexTooling: true, codexResumeGate: gate)
        fixture.session.codexConversationID = "lifecycle"
        let operation = Task { await compact(fixture) }
        defer {
            operation.cancel()
            gate.release()
        }
        guard await gate.waitUntilEntered() else { return }
        XCTAssertEqual(fixture.session.items.last?.text, AgentChatItem.overseerCompactionRequestText)

        let runID = try XCTUnwrap(fixture.session.runID)
        operation.cancel()
        gate.release()
        let outcome = await operation.value
        let policies = try await ServerNetworkManager.shared.debugPendingPolicySnapshot(
            for: XCTUnwrap(AgentProviderKind.codexExec.mcpClientNameHint)
        )
        XCTAssertFalse(policies.contains { $0.runID == runID })
        let routingOutcome = await MCPRoutingWaiter.currentTerminalOutcome(runID: runID)
        XCTAssertNil(routingOutcome)

        guard case let .delivered(delivery) = outcome else {
            return XCTFail("The durable request survives cancellation: \(outcome)")
        }
        XCTAssertEqual(fixture.session.codexConversationID, "lifecycle")
        XCTAssertNil(fixture.session.codexController, "Cancelled uncommitted resume is retired")
        XCTAssertEqual(delivery.deliveryState, .persisted, "The cancelled caller must not dispatch")
        XCTAssertFalse(fixture.codexRecorder.events.contains("codex:compact"))
        XCTAssertFalse(fixture.codexRecorder.events.contains("codex:send"))
        XCTAssertNil(fixture.session.codexPendingTurnKind)
        XCTAssertFalse(fixture.session.isComposerSubmissionInFlight, "The claim is released")
    }

    func testWorkspaceChangeDuringCodexResumeWithholdsCompactionAfterExactThreadReturns() async throws {
        let gate = TestReleaseFence(name: "compact Codex resume")
        let fixture = try makeFixture(agent: .codexExec, shouldManageCodexTooling: true, codexResumeGate: gate)
        fixture.session.codexConversationID = "lifecycle"
        let operation = Task { await compact(fixture) }
        defer {
            operation.cancel()
            gate.release()
        }
        guard await gate.waitUntilEntered() else { return }

        fixture.manager.activeWorkspace = nil
        gate.release()
        let outcome = await operation.value

        guard case let .delivered(delivery) = outcome else {
            return XCTFail("The durable request survives workspace drift: \(outcome)")
        }
        XCTAssertEqual(fixture.session.codexConversationID, "lifecycle")
        XCTAssertEqual(fixture.session.codexController?.hasActiveThread, true, "Resume still completed")
        XCTAssertEqual(delivery.deliveryState, .persisted)
        XCTAssertFalse(fixture.codexRecorder.events.contains("codex:compact"))
        XCTAssertNil(fixture.session.codexPendingTurnKind)
        XCTAssertFalse(fixture.session.isComposerSubmissionInFlight, "The claim is released")
    }

    func testCodexCompactionStartsNativeThreadCompactionAndNeverSendsAMessage() async throws {
        let fixture = try makeFixture(agent: .codexExec)
        // The thread the stub controller resumes into, so preparation keeps the admitted thread.
        fixture.session.codexConversationID = "lifecycle"

        let outcome = await compact(fixture)

        guard case let .delivered(delivery) = outcome else {
            return XCTFail("Expected an accepted Codex compaction, got \(outcome)")
        }
        XCTAssertEqual(delivery.deliveryState, .runStarted)
        XCTAssertEqual(fixture.codexRecorder.events.count(where: { $0 == "codex:compact" }), 1)
        XCTAssertFalse(fixture.codexRecorder.events.contains("codex:send"))
        XCTAssertEqual(fixture.session.codexPendingTurnKind, .compact)
        XCTAssertEqual(fixture.session.items.last?.text, AgentChatItem.overseerCompactionRequestText)
    }

    /// Regression: a dispatched compaction whose provider lifecycle events never arrive must
    /// still settle — the stall watchdog reconciles through `thread/read` instead of leaving
    /// the lane `running` forever (cold Codex compact hang, 2026-10-01).
    func testSilentCodexCompactionSettlesThroughTheStallWatchdog() async throws {
        let fixture = try makeFixture(
            agent: .codexExec,
            codexStallWatchdogProbeThreshold: 0.05,
            codexStallWatchdogRecoveryThreshold: 0.25,
            codexStallWatchdogPollIntervalNanos: 10_000_000,
            codexSnapshotLatestTurnStatus: .completed
        )
        fixture.session.codexConversationID = "lifecycle"

        let outcome = await compact(fixture)

        guard case let .delivered(delivery) = outcome else {
            return XCTFail("Expected an accepted Codex compaction, got \(outcome)")
        }
        XCTAssertEqual(delivery.deliveryState, .runStarted)
        XCTAssertEqual(fixture.session.runState, .running)

        try await AsyncTestWait.waitUntil("silent Codex compaction settles via the stall watchdog", timeout: 5) {
            fixture.session.runState == .completed
        }
        XCTAssertEqual(fixture.session.codexPendingTurnKind, nil)
        XCTAssertEqual(
            fixture.codexRecorder.events.count(where: { $0 == "codex:compact" }),
            1,
            "Recovery reconciles the miss — it must never re-dispatch compaction"
        )
        XCTAssertFalse(fixture.codexRecorder.events.contains("codex:send"))
    }
}

/// The raw provider-command lane of the Claude coordinator, driven directly.
@MainActor
final class AgentSessionLinkCompactClaudeDispatchTests: XCTestCase {
    private var retained: [AnyObject] = []

    override func tearDown() {
        retained.removeAll()
        super.tearDown()
    }

    private func makeViewModel(
        controller: MonitorFakeNativeController
    ) throws -> (AgentModeViewModel, AgentModeViewModel.TabSession, MonitorInventoryPublisher, UUID) {
        let tabID = UUID()
        let fileManager = WorkspaceFilesViewModel()
        let keyManager = KeyManager(secureService: SecureKeysService(secureStorage: TestSecureStorageBackend()))
        let apiSettings = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )
        let prompt = PromptViewModel(
            fileManager: fileManager,
            apiSettingsViewModel: apiSettings,
            windowID: -1,
            settingsManager: WindowSettingsManager(windowID: -1)
        )
        let manager = WorkspaceManagerViewModel(
            fileManager: fileManager,
            promptViewModel: prompt,
            performInitialWorkspaceActivation: false
        )
        let workspace = WorkspaceModel(
            name: "Raw command lane",
            repoPaths: [],
            ephemeralFlag: true,
            composeTabs: [ComposeTabState(id: tabID)],
            activeComposeTabID: tabID
        )
        manager.workspaces = [workspace]
        manager.activeWorkspace = workspace
        let viewModel = AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in LifecycleNoopCodexController(recorder: LifecycleRecorder()) },
            claudeControllerFactory: { _, _, _, _ in controller },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
            mcpServerEnabler: { true }
        )
        retained.append(viewModel)
        retained.append(manager)
        viewModel.workspaceManager = manager
        viewModel.test_setCurrentTabIDOverride(tabID)
        viewModel.test_setAgentSessionSaver { _, _, _ in
            URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(UUID().uuidString).json")
        }
        let session = viewModel.session(for: tabID)
        session.selectedAgent = .claudeCode
        session.hasLoadedPersistedState = true
        let sessionID = try XCTUnwrap(viewModel.test_ensureSessionBoundToTab(session))
        session.claudeController = controller
        let inventory = MonitorInventoryPublisher(viewModel: viewModel, observerSessionID: sessionID, tabID: tabID)
        return (viewModel, session, inventory, tabID)
    }

    private func intent(for session: AgentModeViewModel.TabSession) throws -> ClaudeAgentModeCoordinator.NativeSessionIntent {
        if session.runID == nil { session.installRunID(UUID()) }
        let runID = try XCTUnwrap(session.runID)
        session.runState = .running
        let ownership = session.beginRunAttempt(source: "test.compact.raw")
        return .runAttempt(ownership: ownership, runID: runID)
    }

    func testRawCommandSendsExactlyTheNativeTextAndLeavesTheOversightSupplementOwed() async throws {
        let controller = MonitorFakeNativeController()
        let (viewModel, session, inventory, _) = try makeViewModel(controller: controller)
        // The fake controller's live conversation, so preparation keeps the same conversation.
        session.providerSessionID = "monitor-native-session"
        inventory.publish(revision: 1, targetCount: 1)
        let runIntent = try intent(for: session)
        let binding = try XCTUnwrap(session.persistentSessionBindingIdentity)

        let outcome = await viewModel.test_claudeCoordinator.sendClaudeNativeMessage(
            session: session,
            text: "/compact",
            attachments: [],
            intent: runIntent,
            allowsCatalogRouteControllerRecovery: false,
            providerControlCommand: .compact(
                expectedBinding: binding,
                expectedProviderConversation: "monitor-native-session"
            )
        )

        XCTAssertEqual(outcome, .sent)
        let sent = await controller.sentMessages
        XCTAssertEqual(sent, ["/compact"])

        // The supplement this turn skipped is still owed to the next ordinary turn.
        _ = await viewModel.test_claudeCoordinator.sendClaudeNativeMessage(
            session: session,
            text: "next turn",
            attachments: [],
            intent: runIntent,
            allowsCatalogRouteControllerRecovery: false
        )
        let after = await controller.sentMessages
        try MonitorSupplementAssertions.assertCarriesExactlyOneSupplement(XCTUnwrap(after.last), userContent: "next turn")
    }

    /// A failed resume falls back to a fresh provider conversation. There is then nothing to compact,
    /// so the command must not run against the empty conversation.
    func testRawCommandFailsClosedWhenTheConversationCannotBeResumed() async throws {
        let controller = MonitorFakeNativeController()
        await controller.setRejectResume(true)
        let (viewModel, session, _, _) = try makeViewModel(controller: controller)
        session.providerSessionID = "conversation-to-compact"
        let runIntent = try intent(for: session)
        let binding = try XCTUnwrap(session.persistentSessionBindingIdentity)

        let outcome = await viewModel.test_claudeCoordinator.sendClaudeNativeMessage(
            session: session,
            text: "/compact",
            attachments: [],
            intent: runIntent,
            allowsCatalogRouteControllerRecovery: false,
            providerControlCommand: .compact(
                expectedBinding: binding,
                expectedProviderConversation: "conversation-to-compact"
            )
        )

        guard case .failed = outcome else { return XCTFail("Expected a fail-closed refusal, got \(outcome)") }
        let sent = await controller.sentMessages
        XCTAssertTrue(sent.isEmpty, "Nothing may run against a conversation the command was not for")
    }

    /// Run preparation can suspend after the admitting transaction's last fence. A rebind in that
    /// window may keep the provider conversation, so the command is bound to the exact binding too.
    func testRawCommandFailsClosedAfterARebindThatKeepsTheProviderConversation() async throws {
        let controller = MonitorFakeNativeController()
        let (viewModel, session, _, _) = try makeViewModel(controller: controller)
        session.providerSessionID = "monitor-native-session"
        let admittedBinding = try XCTUnwrap(session.persistentSessionBindingIdentity)
        let runIntent = try intent(for: session)
        // Rebound to the same session UUID: a new binding identity, same provider conversation.
        session.installPersistentSessionBinding(
            AgentPersistentSessionBindingIdentity(tabID: session.tabID, sessionID: admittedBinding.sessionID)
        )

        let outcome = await viewModel.test_claudeCoordinator.sendClaudeNativeMessage(
            session: session,
            text: "/compact",
            attachments: [],
            intent: runIntent,
            allowsCatalogRouteControllerRecovery: false,
            providerControlCommand: .compact(
                expectedBinding: admittedBinding,
                expectedProviderConversation: "monitor-native-session"
            )
        )

        XCTAssertNotEqual(outcome, .sent, "A rebound session must never receive the command")
        let sent = await controller.sentMessages
        XCTAssertTrue(sent.isEmpty)
    }

    private func armSelfNote(
        session: AgentModeViewModel.TabSession,
        note: String
    ) throws -> AgentSelfCompactionDispatchID {
        let binding = try XCTUnwrap(session.persistentSessionBindingIdentity)
        let owner = try AgentSelfCompactOwner(
            windowID: 1,
            workspaceID: UUID(),
            tabID: session.tabID,
            sessionID: binding.sessionID,
            persistentBindingGeneration: binding.generation,
            bindingTransitionGeneration: session.bindingTransitionGeneration,
            runID: XCTUnwrap(session.runID),
            runAttemptID: XCTUnwrap(session.activeRunAttemptID)
        )
        var state = AgentSelfCompactState()
        _ = state.reserve(note: note, idempotencyKey: "native-note-test", owner: owner)
        state.active?.phase = .dispatchingNote
        state.active?.compactProviderConversation = "monitor-native-session"
        let id = try XCTUnwrap(state.active?.id)
        session.selfCompactState = state
        return .init(requestID: id, stage: .note)
    }

    func testDedicatedClaudeNoteSendsExactFrameAndAcknowledgesAtProviderSeam() async throws {
        let controller = MonitorFakeNativeController()
        let (viewModel, session, _, _) = try makeViewModel(controller: controller)
        session.providerSessionID = "monitor-native-session"
        let declaration = try XCTUnwrap(
            DomainAgentSessionWaitingOn(summary: "CI artifact", declaredAt: Date(timeIntervalSince1970: 50))
        )
        let handoff = AgentModeViewModel.PendingHandoffState(
            payload: "keep staged handoff",
            createdAt: Date(timeIntervalSince1970: 7),
            sourceItemID: UUID()
        )
        let workflow = AgentWorkflowDefinition(
            customID: UUID(), displayName: "Keep workflow", template: "keep"
        )
        let attachment = AgentImageAttachment(
            source: .localFile(path: "/tmp/self-compact-keep.png"),
            title: "self-compact-keep.png"
        )
        session.oversight.waitingOn = declaration
        session.pendingHandoff = handoff
        session.lastUserMessageAt = Date(timeIntervalSince1970: 9)
        session.draftText = "unsent draft"
        session.selectedWorkflow = workflow
        session.pendingImageAttachments = [attachment]
        let commandIntent = try intent(for: session)
        let binding = try XCTUnwrap(session.persistentSessionBindingIdentity)
        let command = AgentProviderControlCommand.compact(
            expectedBinding: binding, expectedProviderConversation: "monitor-native-session"
        )
        let commandOutcome = await viewModel.test_claudeCoordinator.sendClaudeNativeMessage(
            session: session, text: command.providerText, attachments: [], intent: commandIntent,
            allowsCatalogRouteControllerRecovery: false, providerControlCommand: command
        )
        XCTAssertEqual(commandOutcome, .sent)
        let note = "line one\nβeta line two"
        let noteIntent = try intent(for: session)
        let dispatchID = try armSelfNote(session: session, note: note)
        let outcome = await viewModel.test_claudeCoordinator.sendClaudeNativeMessage(
            session: session, text: AgentSelfCompactNoteEnvelope.frame(note), attachments: [],
            intent: noteIntent, allowsCatalogRouteControllerRecovery: false,
            selfCompactDispatchID: dispatchID
        )
        XCTAssertEqual(outcome, .sent)
        let sent = await controller.sentMessages
        XCTAssertEqual(sent, ["/compact", AgentSelfCompactNoteEnvelope.frame(note)])
        XCTAssertEqual(session.selfCompactState.latest?.outcome, .noteAccepted)
        XCTAssertEqual(session.selfCompactState.latest?.noteDelivery, .accepted)
        XCTAssertEqual(session.oversight.waitingOn, declaration)
        XCTAssertEqual(session.pendingHandoff, handoff)
        XCTAssertEqual(session.lastUserMessageAt, Date(timeIntervalSince1970: 9))
        XCTAssertEqual(session.draftText, "unsent draft")
        XCTAssertEqual(session.selectedWorkflow, workflow)
        XCTAssertEqual(session.pendingImageAttachments, [attachment])
    }

    func testDedicatedClaudeNoteRefusesLateLostWriterAndReleasesTheHold() async throws {
        let controller = MonitorFakeNativeController()
        let (viewModel, session, _, _) = try makeViewModel(controller: controller)
        session.providerSessionID = "monitor-native-session"
        let runIntent = try intent(for: session)
        let dispatchID = try armSelfNote(session: session, note: "private continuation")
        session.selfCompactDispatchIsCurrent = { false } // Another tab bound after note pipeline admission.
        session.selfCompactNativeCompletion = AgentSelfCompactNativeCompletionCoordinator(
            load: { session.selfCompactState },
            store: { session.selfCompactState = $0 },
            isCurrentOwner: { _ in false },
            dispatchNote: { _, _ in XCTFail("No second note dispatch")
                return false
            }
        )

        let outcome = await viewModel.test_claudeCoordinator.sendClaudeNativeMessage(
            session: session, text: AgentSelfCompactNoteEnvelope.frame("private continuation"),
            attachments: [], intent: runIntent, allowsCatalogRouteControllerRecovery: false,
            selfCompactDispatchID: dispatchID
        )
        XCTAssertEqual(outcome, .superseded)
        let sent = await controller.sentMessages
        XCTAssertEqual(sent, [])
        XCTAssertNil(session.selfCompactState.active)
        XCTAssertEqual(session.selfCompactState.latest?.outcome, .cancelled)
        XCTAssertFalse(session.selfCompactState.blocksOverseerDelivery)
        XCTAssertFalse(session.selfCompactState.blocksAutomaticWake)
    }

    func testClaudeAmbiguousNoteTransportRetainsRecoveryWithoutRetry() async throws {
        let controller = MonitorFakeNativeController()
        let (viewModel, session, _, _) = try makeViewModel(controller: controller)
        session.providerSessionID = "monitor-native-session"
        let commandIntent = try intent(for: session)
        let binding = try XCTUnwrap(session.persistentSessionBindingIdentity)
        let command = AgentProviderControlCommand.compact(
            expectedBinding: binding, expectedProviderConversation: "monitor-native-session"
        )
        _ = await viewModel.test_claudeCoordinator.sendClaudeNativeMessage(
            session: session, text: command.providerText, attachments: [], intent: commandIntent,
            allowsCatalogRouteControllerRecovery: false, providerControlCommand: command
        )
        let noteIntent = try intent(for: session)
        let dispatchID = try armSelfNote(session: session, note: "recover me")
        await controller.setFailSendAfterRecord(true)
        let outcome = await viewModel.test_claudeCoordinator.sendClaudeNativeMessage(
            session: session, text: AgentSelfCompactNoteEnvelope.frame("recover me"), attachments: [],
            intent: noteIntent, allowsCatalogRouteControllerRecovery: false,
            selfCompactDispatchID: dispatchID
        )
        guard case .failed = outcome else { return XCTFail("Expected transport error") }
        XCTAssertEqual(session.selfCompactState.latest?.outcome, .deliveryUnknown)
        XCTAssertEqual(session.selfCompactState.latest?.recoveryNote, "recover me")
        XCTAssertNil(session.selfCompactState.parkedNote)
        let sent = await controller.sentMessages
        XCTAssertEqual(sent.count, 2)
    }

    func testRawCommandFailsClosedInsteadOfInterruptingAnInFlightTurn() async throws {
        let controller = MonitorFakeNativeController()
        await controller.setTurnInFlight(true)
        let (viewModel, session, _, _) = try makeViewModel(controller: controller)
        session.providerSessionID = "monitor-native-session"
        let runIntent = try intent(for: session)
        let binding = try XCTUnwrap(session.persistentSessionBindingIdentity)

        let outcome = await viewModel.test_claudeCoordinator.sendClaudeNativeMessage(
            session: session,
            text: "/compact",
            attachments: [],
            intent: runIntent,
            allowsCatalogRouteControllerRecovery: false,
            providerControlCommand: .compact(
                expectedBinding: binding,
                expectedProviderConversation: "monitor-native-session"
            )
        )

        guard case let .failed(message) = outcome else {
            return XCTFail("Expected a fail-closed refusal, got \(outcome)")
        }
        XCTAssertTrue(message.contains("still in flight"), message)
        let sent = await controller.sentMessages
        XCTAssertTrue(sent.isEmpty)
    }
}

/// A native runtime stub with an active session that records every provider-bound message.
actor CompactRecordingNativeController: NativeAgentRuntimeControlling {
    private var configuration = SessionLinkNativeConfigurationFixture()
    private(set) var sentMessages: [String] = []
    private let stream: AsyncStream<NativeAgentRuntimeEvent>

    init() {
        stream = AsyncStream { $0.finish() }
    }

    var hasActiveSession: Bool {
        true
    }

    var hasTurnInFlight: Bool {
        false
    }

    var events: AsyncStream<NativeAgentRuntimeEvent> {
        stream
    }

    func ensureEventsStreamReady() {}
    func resetEventsStreamForNewRun() {}

    func startOrResume(
        existingSessionID: String?,
        model _: String?,
        effortLevel _: NativeAgentRuntimeEffortLevel?,
        systemPromptOverride _: String?
    ) async throws -> NativeAgentRuntimeSessionRef {
        configuration.replaceProcess()
        return NativeAgentRuntimeSessionRef(sessionID: existingSessionID ?? "compact-recording")
    }

    func currentSessionRef() -> NativeAgentRuntimeSessionRef {
        NativeAgentRuntimeSessionRef(sessionID: "compact-recording")
    }

    func applyModelAndEffort(model _: String?, effortLevel _: NativeAgentRuntimeEffortLevel?) async throws {
        _ = configuration.apply()
    }

    func applyModelAndEffortWithProof(model _: String?, effortLevel _: NativeAgentRuntimeEffortLevel?) async throws -> NativeAgentRuntimeConfigurationApplication {
        configuration.apply()
    }

    func sendUserMessage(_ text: String, configuration proof: NativeAgentRuntimeConfigurationProof) async throws -> UUID {
        try configuration.validate(proof)
        sentMessages.append(text)
        return UUID()
    }

    func sendUserMessage(_ text: String) async throws -> UUID {
        sentMessages.append(text)
        return UUID()
    }

    func interruptTurn(reason _: String) -> NativeAgentRuntimeInterruptOutcome {
        .noTurnInFlight
    }

    func shutdown() {
        configuration.replaceProcess()
    }

    func respondToPermissionRequest(id _: String, decision _: AgentApprovalDecision) {}
}

/// Actor-owned fake receipt state. Every application intent supersedes earlier receipts, even
/// identical values. Tests that replace a process rotate its lifetime rather than reuse counters.
struct SessionLinkNativeConfigurationFixture {
    private var lifetime = UUID()
    private var generation: UInt64 = 0
    private var current: NativeAgentRuntimeConfigurationProof?

    mutating func apply() -> NativeAgentRuntimeConfigurationApplication {
        generation &+= 1
        let proof = NativeAgentRuntimeConfigurationProof(
            lifetime: lifetime, intentGeneration: generation, requestGeneration: generation
        )
        current = proof
        return .applied(proof)
    }

    mutating func replaceProcess() {
        lifetime = UUID()
        current = nil
    }

    func validate(_ proof: NativeAgentRuntimeConfigurationProof) throws {
        guard current == proof else { throw NativeAgentRuntimeControllerError.configurationNotCurrent }
    }
}

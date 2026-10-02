import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptSecureStorage
import XCTest

@MainActor
final class AgentSessionLinkACPSteerTests: XCTestCase {
    private struct Fixture {
        let viewModel: AgentModeViewModel
        let manager: WorkspaceManagerViewModel
        let session: AgentModeViewModel.TabSession
        let candidate: AgentSessionLinkEndpointCandidate
        let controller: ACPAgentSessionController
        let provider: AgentSessionLinkCapturingACPProvider
        let directory: URL
    }

    private var fixtures: [Fixture] = []

    override func tearDown() async throws {
        for fixture in fixtures {
            await fixture.controller.shutdown()
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        fixtures.removeAll()
        try await super.tearDown()
    }

    private func makeFixture(failPromptsContaining: String? = nil) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManagedACPSteer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = try AgentSessionLinkACPServerScript.write(to: directory)
        var environment: [String: String] = [:]
        if let failPromptsContaining {
            environment["ACP_FAIL_PROMPTS_CONTAINING"] = failPromptsContaining
        }
        let provider = AgentSessionLinkCapturingACPProvider(
            providerID: .openCode, commandPath: script.path, environment: environment
        )
        let request = ACPRunRequest(
            agentKind: .openCode, modelString: nil, workspacePath: directory.path,
            resumeSessionID: nil, attachments: [], taskLabelKind: nil
        )
        let controller = try ACPAgentSessionController(provider: provider, runRequest: request)
        _ = try await controller.bootstrap()

        let tabID = UUID()
        let files = WorkspaceFilesViewModel()
        let keys = KeyManager(secureService: SecureKeysService(secureStorage: TestSecureStorageBackend()))
        let api = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keys),
            keyManager: keys, loadStoredDataOnInit: false
        )
        let prompt = PromptViewModel(
            fileManager: files, apiSettingsViewModel: api, windowID: -1,
            settingsManager: WindowSettingsManager(windowID: -1)
        )
        let manager = WorkspaceManagerViewModel(
            fileManager: files, promptViewModel: prompt,
            performInitialWorkspaceActivation: false
        )
        let workspace = WorkspaceModel(
            name: "ACP steer target", repoPaths: [], ephemeralFlag: true,
            composeTabs: [ComposeTabState(id: tabID)], activeComposeTabID: tabID
        )
        manager.workspaces = [workspace]
        manager.activeWorkspace = workspace
        let viewModel = AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: directory.path,
            codexControllerFactory: { _, _, _, _, _, _ in
                LifecycleNoopCodexController(recorder: LifecycleRecorder())
            },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
            mcpServerEnabler: { true }
        )
        viewModel.workspaceManager = manager
        viewModel.test_setCurrentTabIDOverride(tabID)
        viewModel.test_setAgentSessionSaver { _, _, _ in
            directory.appendingPathComponent("\(UUID().uuidString).json")
        }
        let session = viewModel.session(for: tabID)
        session.selectedAgent = .openCode
        session.hasLoadedPersistedState = true
        let sessionID = try XCTUnwrap(viewModel.test_ensureSessionBoundToTab(session))
        let candidate = try XCTUnwrap(viewModel.agentSessionLinkCandidate(
            tabID: tabID, sessionID: sessionID, tabName: "ACP steer target", isWindowClosing: false
        ))
        session.providerSessionID = "monitor-acp-session"
        session.acpController = controller
        session.runState = .running
        session.installRunID(UUID())
        _ = session.beginRunAttempt(source: "managed-acp-steer-test")
        let fixture = Fixture(
            viewModel: viewModel, manager: manager, session: session, candidate: candidate,
            controller: controller, provider: provider, directory: directory
        )
        fixtures.append(fixture)
        return fixture
    }

    private static let observer = DomainAgentSessionLinkEndpointIdentity(
        windowID: 2, workspaceID: UUID(), tabID: UUID(), sessionID: UUID(),
        persistentBindingGeneration: UUID(), bindingTransitionGeneration: 1
    )

    private static let liveness = AgentSessionLinkSendLiveness(
        observerEndpointIsLive: true, targetEndpointIsLive: true, targetWindowIsClosing: false
    )

    private func request(_ text: String) -> AgentSessionLinkSendRequest {
        AgentSessionLinkSendRequest(
            linkID: UUID(), linkGeneration: 1, observerEndpoint: Self.observer,
            observerDisplayName: "Overseer", message: text, workflow: nil
        )
    }

    private func steer(_ fixture: Fixture, request: AgentSessionLinkSendRequest) async
        -> AgentSessionLinkSendTransactionOutcome
    {
        await fixture.viewModel.agentSessionLinkPerformSteer(
            to: fixture.candidate, request: request,
            liveness: { Self.liveness }, commitAuthorization: { .committed }
        )
    }

    private func mixedSteeringBatch(
        _ fixture: Fixture,
        localDraft: String = "typed local draft"
    ) -> ([AgentModeViewModel.TabSession.ACPSteeringInstruction], AgentSessionLinkManagedSteerSink) {
        let local = AgentModeViewModel.TabSession.ACPSteeringInstruction(
            id: UUID(), targetRunID: fixture.session.runID,
            targetRunAttemptID: fixture.session.activeRunAttemptID,
            providerText: "local provider text", interruptedPromptProviderText: nil,
            attachments: [], taggedFileAttachments: [], draftText: localDraft,
            optimisticUserItemID: nil, createdAt: Date()
        )
        let message = request("managed scheduled direction")
        let envelope = AgentSessionLinkMessageEnvelope.render(
            sourceSessionID: message.observerSessionID, sourceName: message.observerDisplayName,
            linkID: message.linkID, linkGeneration: message.linkGeneration,
            message: message.message, framing: .management
        )
        let row = AgentChatItem.user(
            message.message, sequenceIndex: fixture.session.nextSequenceIndex,
            crossSessionAttribution: message.attribution, dispatchedProviderText: envelope
        )
        fixture.session.appendItem(row)
        let sink = AgentSessionLinkManagedSteerSink()
        let managed = AgentModeViewModel.TabSession.ACPSteeringInstruction(
            id: UUID(), targetRunID: fixture.session.runID,
            targetRunAttemptID: fixture.session.activeRunAttemptID,
            providerText: envelope, interruptedPromptProviderText: nil,
            attachments: [], taggedFileAttachments: [], draftText: "",
            optimisticUserItemID: row.id, createdAt: Date(),
            managed: .init(
                sink: sink, attributedItemID: row.id,
                candidate: fixture.candidate, attribution: message.attribution
            )
        )
        return ([local, managed], sink)
    }

    private func stopBeforeScheduledACPStart(_ fixture: Fixture) async throws {
        let stopRequest = AgentSessionLinkStopRequest(
            requestID: UUID(), linkID: UUID(), linkGeneration: 1,
            observerEndpoint: Self.observer, observerDisplayName: "Overseer"
        )
        let stop = await fixture.viewModel.agentSessionLinkPerformStop(
            to: fixture.candidate, request: stopRequest,
            liveness: { Self.liveness }, queueHasCommittedDrain: { false },
            withdrawInbound: { true }, commitAuthorization: { .committed }
        )
        guard case let .settled(receipt) = stop else { return XCTFail("Expected Stop receipt") }
        XCTAssertEqual(receipt.result, .stopped)
        XCTAssertNil(fixture.session.scheduledACPFollowUp)
    }

    func testRunningACPManagedSteerDeliversFramedPrompt() async throws {
        let fixture = try await makeFixture()
        let message = request("Keep the parser fix & skip the rest.")
        let outcome = await steer(fixture, request: message)
        guard case let .delivered(delivery) = outcome else { return XCTFail("Expected delivery: \(outcome)") }
        XCTAssertEqual(delivery.deliveryState, .steered)
        let envelope = AgentSessionLinkMessageEnvelope.render(
            sourceSessionID: message.observerSessionID, sourceName: message.observerDisplayName,
            linkID: message.linkID, linkGeneration: message.linkGeneration,
            message: message.message, framing: .management
        )
        XCTAssertTrue(fixture.provider.promptedMessages.last?.userMessage.contains(envelope) == true)
        let row = try XCTUnwrap(fixture.session.items.first(where: { $0.id == delivery.targetItemID }))
        XCTAssertEqual(row.text, message.message)
        XCTAssertEqual(row.dispatchedProviderText, envelope)
        XCTAssertEqual(row.crossSessionAttribution, message.attribution)
    }

    func testRefusedACPFlushQueuesExactEnvelopeAndSettles() async throws {
        let fixture = try await makeFixture(failPromptsContaining: "REFUSE_THIS_STEER")
        let message = request("REFUSE_THIS_STEER")
        let outcome = await steer(fixture, request: message)
        guard case let .delivered(delivery) = outcome else { return XCTFail("Expected queued follow-up: \(outcome)") }
        XCTAssertEqual(delivery.deliveryState, .queuedFollowUp)
        let envelope = AgentSessionLinkMessageEnvelope.render(
            sourceSessionID: message.observerSessionID, sourceName: message.observerDisplayName,
            linkID: message.linkID, linkGeneration: message.linkGeneration,
            message: message.message, framing: .management
        )
        XCTAssertEqual(fixture.session.pendingInstructions.first?.providerText, envelope)
    }

    func testMixedLocalAndManagedBatchSettlesManagedOnly() async throws {
        let fixture = try await makeFixture()
        let local = AgentModeViewModel.TabSession.ACPSteeringInstruction(
            id: UUID(), targetRunID: fixture.session.runID,
            targetRunAttemptID: fixture.session.activeRunAttemptID,
            providerText: "local direction", interruptedPromptProviderText: nil,
            attachments: [], taggedFileAttachments: [], draftText: "local direction",
            optimisticUserItemID: nil, createdAt: Date()
        )
        fixture.session.pendingACPSteeringInstructions.append(local)
        let outcome = await steer(fixture, request: request("managed direction"))
        guard case let .delivered(delivery) = outcome else { return XCTFail("Expected delivery: \(outcome)") }
        XCTAssertEqual(delivery.deliveryState, .steered)
        let sent = try XCTUnwrap(fixture.provider.promptedMessages.last?.userMessage)
        XCTAssertTrue(sent.contains("local direction"))
        XCTAssertTrue(sent.contains("managed direction"))
        XCTAssertTrue(fixture.session.pendingACPSteeringInstructions.isEmpty)
    }

    func testStaleRunRequeuesManagedSteerExactlyOnce() async throws {
        let fixture = try await makeFixture()
        let message = request("direction for the original run")
        let envelope = AgentSessionLinkMessageEnvelope.render(
            sourceSessionID: message.observerSessionID, sourceName: message.observerDisplayName,
            linkID: message.linkID, linkGeneration: message.linkGeneration,
            message: message.message, framing: .management
        )
        let sink = AgentSessionLinkManagedSteerSink()
        XCTAssertTrue(fixture.viewModel.submitAgentSessionLinkManagedSteer(
            tabID: fixture.session.tabID,
            session: fixture.session,
            displayText: message.message,
            turn: AgentSessionLinkManagedTurn(
                candidate: fixture.candidate, providerText: envelope,
                attribution: message.attribution, sink: sink
            ),
            route: .acpQueued
        ))
        fixture.session.installRunID(UUID())
        let settled = await sink.awaitOutcome(timeoutSeconds: 2)
        XCTAssertEqual(settled, .delivered(.queuedFollowUp))
        sink.resolve(.notAccepted(message: "late duplicate"))
        XCTAssertEqual(sink.outcome, .delivered(.queuedFollowUp))
        XCTAssertEqual(fixture.session.pendingInstructions.first?.providerText, envelope)
    }

    func testMixedACPFollowUpRestoresOnlyTypedLocalDraftAfterStop() async throws {
        let fixture = try await makeFixture()
        let local = AgentModeViewModel.TabSession.ACPSteeringInstruction(
            id: UUID(), targetRunID: fixture.session.runID,
            targetRunAttemptID: fixture.session.activeRunAttemptID,
            providerText: "local provider text", interruptedPromptProviderText: nil,
            attachments: [], taggedFileAttachments: [], draftText: "local draft",
            optimisticUserItemID: nil, createdAt: Date()
        )
        let message = request("managed direction")
        let envelope = AgentSessionLinkMessageEnvelope.render(
            sourceSessionID: message.observerSessionID, sourceName: message.observerDisplayName,
            linkID: message.linkID, linkGeneration: message.linkGeneration,
            message: message.message, framing: .management
        )
        let row = AgentChatItem.user(
            message.message, sequenceIndex: fixture.session.nextSequenceIndex,
            crossSessionAttribution: message.attribution, dispatchedProviderText: envelope
        )
        fixture.session.appendItem(row)
        let sink = AgentSessionLinkManagedSteerSink()
        let managed = AgentModeViewModel.TabSession.ACPSteeringInstruction(
            id: UUID(), targetRunID: fixture.session.runID,
            targetRunAttemptID: fixture.session.activeRunAttemptID,
            providerText: envelope, interruptedPromptProviderText: nil,
            attachments: [], taggedFileAttachments: [], draftText: "",
            optimisticUserItemID: row.id, createdAt: Date(),
            managed: .init(
                sink: sink, attributedItemID: row.id,
                candidate: fixture.candidate, attribution: message.attribution
            )
        )
        fixture.viewModel.test_requeueDequeuedACPSteeringAfterStop(
            [local, managed], session: fixture.session,
            stopFence: AgentRunStartStopFence(session: fixture.session)
        )
        XCTAssertEqual(sink.outcome, .delivered(.queuedFollowUp))
        let queued = try XCTUnwrap(fixture.session.pendingInstructions.first)
        XCTAssertTrue(queued.providerText.contains("local provider text"))
        XCTAssertTrue(queued.providerText.contains(envelope))
        XCTAssertEqual(queued.localDraftText, "local draft")

        fixture.viewModel.withdrawQueuedWorkForManagedStop(session: fixture.session)
        let restored = fixture.viewModel.retrieveDraftText(for: fixture.session.tabID)
        XCTAssertTrue(restored.contains("local draft"))
        XCTAssertFalse(restored.contains("managed direction"))
        XCTAssertFalse(restored.contains("local provider text"))
        XCTAssertTrue(fixture.session.pendingInstructions.isEmpty)
    }

    func testCompletedACPFallbackStopRestoresOnlyScheduledLocalDraft() async throws {
        let fixture = try await makeFixture()
        await fixture.viewModel.test_publishNaturalCompletion(fixture.session)
        let terminalRevision = try XCTUnwrap(fixture.session.lastTerminalCommitRevision)
        XCTAssertEqual(fixture.session.runState, .completed)
        XCTAssertTrue(fixture.session.acpController === fixture.controller)

        let entered = AgentSessionLinkStopSignal<Void>()
        let release = AgentSessionLinkStopSignal<Void>()
        let finished = AgentSessionLinkStopSignal<Void>()
        addTeardownBlock { release.finish(()) }
        fixture.viewModel.test_didFinishScheduledACPFollowUpStart = { finished.finish(()) }
        fixture.viewModel.test_beforeScheduledACPFollowUpStart = {
            entered.finish(())
            await release.value()
        }
        defer {
            fixture.viewModel.test_beforeScheduledACPFollowUpStart = nil
            fixture.viewModel.test_didFinishScheduledACPFollowUpStart = nil
        }
        let local = AgentModeViewModel.TabSession.ACPSteeringInstruction(
            id: UUID(), targetRunID: fixture.session.runID,
            targetRunAttemptID: fixture.session.activeRunAttemptID,
            providerText: "local provider text", interruptedPromptProviderText: nil,
            attachments: [], taggedFileAttachments: [], draftText: "typed local draft",
            optimisticUserItemID: nil, createdAt: Date()
        )
        let message = request("managed scheduled direction")
        let envelope = AgentSessionLinkMessageEnvelope.render(
            sourceSessionID: message.observerSessionID, sourceName: message.observerDisplayName,
            linkID: message.linkID, linkGeneration: message.linkGeneration,
            message: message.message, framing: .management
        )
        let row = AgentChatItem.user(
            message.message, sequenceIndex: fixture.session.nextSequenceIndex,
            crossSessionAttribution: message.attribution, dispatchedProviderText: envelope
        )
        fixture.session.appendItem(row)
        let sink = AgentSessionLinkManagedSteerSink()
        let managed = AgentModeViewModel.TabSession.ACPSteeringInstruction(
            id: UUID(), targetRunID: fixture.session.runID,
            targetRunAttemptID: fixture.session.activeRunAttemptID,
            providerText: envelope, interruptedPromptProviderText: nil,
            attachments: [], taggedFileAttachments: [], draftText: "",
            optimisticUserItemID: row.id, createdAt: Date(),
            managed: .init(
                sink: sink, attributedItemID: row.id,
                candidate: fixture.candidate, attribution: message.attribution
            )
        )
        fixture.viewModel.test_requeueDequeuedACPSteeringAfterStop(
            [local, managed], session: fixture.session,
            stopFence: AgentRunStartStopFence(session: fixture.session)
        )
        await entered.value()
        XCTAssertEqual(sink.outcome, .delivered(.queuedFollowUp))
        XCTAssertNotNil(fixture.session.scheduledACPFollowUp)
        let stopRequest = AgentSessionLinkStopRequest(
            requestID: UUID(), linkID: UUID(), linkGeneration: 1,
            observerEndpoint: Self.observer, observerDisplayName: "Overseer"
        )
        let stop = await fixture.viewModel.agentSessionLinkPerformStop(
            to: fixture.candidate, request: stopRequest,
            liveness: { Self.liveness }, queueHasCommittedDrain: { false },
            withdrawInbound: { true }, commitAuthorization: { .committed }
        )
        guard case let .settled(receipt) = stop else { return XCTFail("Expected Stop receipt") }
        XCTAssertEqual(receipt.result, .stopped)
        XCTAssertNil(fixture.session.scheduledACPFollowUp)
        release.finish(())
        await finished.value()
        XCTAssertTrue(fixture.provider.promptedMessages.isEmpty)
        XCTAssertEqual(fixture.session.lastTerminalCommitRevision, terminalRevision)
        XCTAssertEqual(fixture.session.runState, .completed)
        let draft = fixture.viewModel.retrieveDraftText(for: fixture.session.tabID)
        XCTAssertTrue(draft.contains("typed local draft"))
        XCTAssertFalse(draft.contains(message.message))
        XCTAssertFalse(draft.contains(envelope))
    }

    func testTerminalBarrierFollowUpStopRestoresTypedLocalDraft() async throws {
        let fixture = try await makeFixture()
        let (batch, sink) = mixedSteeringBatch(fixture)
        fixture.viewModel.test_requeueDequeuedACPSteeringAfterStop(
            batch, session: fixture.session,
            stopFence: AgentRunStartStopFence(session: fixture.session)
        )
        XCTAssertEqual(sink.outcome, .delivered(.queuedFollowUp))
        XCTAssertEqual(fixture.session.pendingInstructions.first?.localDraftText, "typed local draft")

        let entered = AgentSessionLinkStopSignal<Void>()
        let release = AgentSessionLinkStopSignal<Void>()
        let finished = AgentSessionLinkStopSignal<Void>()
        addTeardownBlock { release.finish(()) }
        fixture.viewModel.test_beforeScheduledACPFollowUpStart = {
            entered.finish(())
            await release.value()
        }
        fixture.viewModel.test_didFinishScheduledACPFollowUpStart = { finished.finish(()) }
        defer {
            fixture.viewModel.test_beforeScheduledACPFollowUpStart = nil
            fixture.viewModel.test_didFinishScheduledACPFollowUpStart = nil
        }

        await fixture.viewModel.test_publishNaturalCompletion(fixture.session, supportsFollowUp: true)
        await entered.value()
        let terminalRevision = try XCTUnwrap(fixture.session.lastTerminalCommitRevision)
        XCTAssertTrue(fixture.session.pendingInstructions.isEmpty)
        XCTAssertNotNil(fixture.session.scheduledACPFollowUp)
        try await stopBeforeScheduledACPStart(fixture)
        release.finish(())
        await finished.value()

        XCTAssertTrue(fixture.provider.promptedMessages.isEmpty)
        XCTAssertEqual(fixture.session.lastTerminalCommitRevision, terminalRevision)
        XCTAssertEqual(fixture.session.runState, .completed)
        let draft = fixture.viewModel.retrieveDraftText(for: fixture.session.tabID)
        XCTAssertTrue(draft.contains("typed local draft"))
        XCTAssertFalse(draft.contains("local provider text"))
        XCTAssertFalse(draft.contains("managed scheduled direction"))
    }

    func testViewModelCompletedFallbackStopRestoresTypedLocalDraft() async throws {
        let fixture = try await makeFixture()
        let (batch, sink) = mixedSteeringBatch(fixture)
        await fixture.viewModel.test_publishNaturalCompletion(fixture.session)
        let terminalRevision = try XCTUnwrap(fixture.session.lastTerminalCommitRevision)
        XCTAssertEqual(fixture.session.runState, .completed)
        fixture.session.pendingACPSteeringInstructions.append(contentsOf: batch)

        let entered = AgentSessionLinkStopSignal<Void>()
        let release = AgentSessionLinkStopSignal<Void>()
        let finished = AgentSessionLinkStopSignal<Void>()
        addTeardownBlock { release.finish(()) }
        fixture.viewModel.test_beforeScheduledACPFollowUpStart = {
            entered.finish(())
            await release.value()
        }
        fixture.viewModel.test_didFinishScheduledACPFollowUpStart = { finished.finish(()) }
        defer {
            fixture.viewModel.test_beforeScheduledACPFollowUpStart = nil
            fixture.viewModel.test_didFinishScheduledACPFollowUpStart = nil
        }

        let stopFence = AgentRunStartStopFence(session: fixture.session)
        for instruction in batch {
            fixture.viewModel.test_settleRejectedACPSteeringSubmission(
                id: instruction.id, session: fixture.session, stopFence: stopFence
            )
        }
        await entered.value()
        XCTAssertEqual(sink.outcome, .delivered(.queuedFollowUp))
        XCTAssertEqual(fixture.session.scheduledACPFollowUp?.queuedInstructions.count, 1)
        XCTAssertTrue(fixture.session.pendingInstructions.isEmpty)
        try await stopBeforeScheduledACPStart(fixture)
        release.finish(())
        await finished.value()

        XCTAssertTrue(fixture.provider.promptedMessages.isEmpty)
        XCTAssertEqual(fixture.session.lastTerminalCommitRevision, terminalRevision)
        XCTAssertEqual(fixture.session.runState, .completed)
        XCTAssertTrue(fixture.session.pendingInstructions.isEmpty)
        XCTAssertTrue(fixture.session.pendingACPSteeringInstructions.isEmpty)
        let draft = fixture.viewModel.retrieveDraftText(for: fixture.session.tabID)
        XCTAssertTrue(draft.contains("typed local draft"))
        XCTAssertFalse(draft.contains("local provider text"))
        XCTAssertFalse(draft.contains("managed scheduled direction"))
    }

    func testFailedSuccessorStartLeavesRemainingSiblingWithdrawableByStop() async throws {
        let fixture = try await makeFixture()
        await fixture.viewModel.test_publishNaturalCompletion(fixture.session)
        let originalFence = AgentRunStartStopFence(session: fixture.session)
        let batch = (1 ... 3).map { index in
            AgentModeViewModel.TabSession.ACPSteeringInstruction(
                id: UUID(), targetRunID: fixture.session.runID,
                targetRunAttemptID: fixture.session.activeRunAttemptID,
                providerText: "pre-Stop payload \(index)", interruptedPromptProviderText: nil,
                attachments: [], taggedFileAttachments: [], draftText: "typed draft \(index)",
                optimisticUserItemID: nil, createdAt: Date()
            )
        }
        fixture.session.pendingACPSteeringInstructions.append(contentsOf: batch)
        let firstFinished = AgentSessionLinkStopSignal<Void>()
        let secondFinished = AgentSessionLinkStopSignal<Void>()
        var starts = 0
        var finishes = 0
        fixture.viewModel.test_beforeScheduledACPFollowUpStart = {
            starts += 1
            if starts == 2 {
                // B reaches the real provider-availability check and fails before a prompt.
                fixture.session.selectedAgent = .cursor
            }
        }
        fixture.viewModel.test_didFinishScheduledACPFollowUpStart = {
            finishes += 1
            if finishes == 1 { firstFinished.finish(()) }
            if finishes == 2 { secondFinished.finish(()) }
        }
        defer {
            fixture.viewModel.test_beforeScheduledACPFollowUpStart = nil
            fixture.viewModel.test_didFinishScheduledACPFollowUpStart = nil
        }
        for instruction in batch {
            fixture.viewModel.test_settleRejectedACPSteeringSubmission(
                id: instruction.id, session: fixture.session, stopFence: originalFence
            )
        }
        XCTAssertEqual(fixture.session.scheduledACPFollowUp?.queuedInstructions.count, 2)
        await firstFinished.value()
        XCTAssertTrue(fixture.session.runState.isActive, "A must own a running turn before handoff")
        XCTAssertEqual(fixture.session.pendingInstructions.map(\.providerText), [
            "pre-Stop payload 2", "pre-Stop payload 3"
        ])
        XCTAssertTrue(fixture.session.pendingInstructions.allSatisfy { $0.stopFence == originalFence })

        await fixture.viewModel.test_publishNaturalCompletion(fixture.session, supportsFollowUp: true)
        await secondFinished.value()
        XCTAssertNil(fixture.session.scheduledACPFollowUp)
        XCTAssertFalse(fixture.session.mcpFollowUpRunPending)
        XCTAssertEqual(fixture.session.pendingInstructions.map(\.providerText), ["pre-Stop payload 3"])
        XCTAssertEqual(fixture.viewModel.retrieveDraftText(for: fixture.session.tabID), "typed draft 2")
        let snapshot = AgentModeViewModel.agentSessionLinkDeliveryReadinessSnapshot(
            session: fixture.session, endpointMatchesGrant: true, isClosing: false
        )
        XCTAssertEqual(AgentSessionLinkStopAdmission.classify(snapshot), .pendingStart)

        let stopRequest = AgentSessionLinkStopRequest(
            requestID: UUID(), linkID: UUID(), linkGeneration: 1,
            observerEndpoint: Self.observer, observerDisplayName: "Overseer"
        )
        let stop = await fixture.viewModel.agentSessionLinkPerformStop(
            to: fixture.candidate, request: stopRequest,
            liveness: { Self.liveness }, queueHasCommittedDrain: { false },
            withdrawInbound: { true }, commitAuthorization: { .committed }
        )
        guard case let .settled(receipt) = stop else { return XCTFail("Expected Stop receipt") }
        XCTAssertEqual(receipt.result, .stopped)
        XCTAssertTrue(fixture.session.pendingInstructions.isEmpty)
        let recovered = fixture.viewModel.retrieveDraftText(for: fixture.session.tabID)
        XCTAssertEqual(recovered.components(separatedBy: "\n"), ["typed draft 3", "typed draft 2"])

        fixture.session.selectedAgent = .openCode
        await fixture.viewModel.startAgentRun(tabID: fixture.session.tabID, initialMessage: "fresh run after Stop")
        await fixture.session.agentTask?.value
        let prompted = try XCTUnwrap(fixture.provider.promptedMessages.last?.userMessage)
        XCTAssertTrue(prompted.contains("fresh run after Stop"))
        XCTAssertFalse(prompted.contains("pre-Stop payload 2"))
        XCTAssertFalse(prompted.contains("pre-Stop payload 3"))
        XCTAssertEqual(fixture.viewModel.retrieveDraftText(for: fixture.session.tabID), recovered)
    }

    func testFailedScheduledACPStartWithdrawsAllFallbacksBeforeStop() async throws {
        let fixture = try await makeFixture()
        await fixture.viewModel.test_publishNaturalCompletion(fixture.session)
        let terminalRevision = try XCTUnwrap(fixture.session.lastTerminalCommitRevision)
        let (mixed, sink) = mixedSteeringBatch(fixture, localDraft: "first typed draft")
        let secondLocal = AgentModeViewModel.TabSession.ACPSteeringInstruction(
            id: UUID(), targetRunID: fixture.session.runID,
            targetRunAttemptID: fixture.session.activeRunAttemptID,
            providerText: "second pre-Stop provider payload", interruptedPromptProviderText: nil,
            attachments: [], taggedFileAttachments: [], draftText: "second typed draft",
            optimisticUserItemID: nil, createdAt: Date()
        )
        let batch = mixed + [secondLocal]
        fixture.session.pendingACPSteeringInstructions.append(contentsOf: batch)

        let finished = AgentSessionLinkStopSignal<Void>()
        fixture.viewModel.test_beforeScheduledACPFollowUpStart = {
            // Cursor is deterministically unavailable in this fixture. Reject before any ACP call,
            // after all three typed fallbacks have been handed to the scheduled-start owner.
            fixture.session.selectedAgent = .cursor
        }
        fixture.viewModel.test_didFinishScheduledACPFollowUpStart = { finished.finish(()) }
        defer {
            fixture.viewModel.test_beforeScheduledACPFollowUpStart = nil
            fixture.viewModel.test_didFinishScheduledACPFollowUpStart = nil
        }
        let stopFence = AgentRunStartStopFence(session: fixture.session)
        for instruction in batch {
            fixture.viewModel.test_settleRejectedACPSteeringSubmission(
                id: instruction.id, session: fixture.session, stopFence: stopFence
            )
        }
        XCTAssertEqual(fixture.session.scheduledACPFollowUp?.queuedInstructions.count, 2)
        XCTAssertTrue(fixture.session.mcpFollowUpRunPending)
        XCTAssertTrue(fixture.session.pendingInstructions.isEmpty)
        await finished.value()

        XCTAssertEqual(sink.outcome, .delivered(.queuedFollowUp))
        XCTAssertNil(fixture.session.scheduledACPFollowUp)
        XCTAssertTrue(fixture.session.pendingInstructions.isEmpty)
        XCTAssertTrue(fixture.session.pendingACPSteeringInstructions.isEmpty)
        XCTAssertFalse(fixture.session.mcpFollowUpRunPending)
        XCTAssertEqual(fixture.session.lastTerminalCommitRevision, terminalRevision)
        XCTAssertTrue(fixture.provider.promptedMessages.isEmpty)
        let recovered = fixture.viewModel.retrieveDraftText(for: fixture.session.tabID)
        XCTAssertEqual(recovered, "first typed draft\nsecond typed draft")
        XCTAssertFalse(recovered.contains("managed scheduled direction"))

        // Stop now sees a settled, non-running target. A later fresh run must not rediscover
        // the pre-Stop managed envelope or either local provider payload in a handoff queue.
        let stopRequest = AgentSessionLinkStopRequest(
            requestID: UUID(), linkID: UUID(), linkGeneration: 1,
            observerEndpoint: Self.observer, observerDisplayName: "Overseer"
        )
        let stop = await fixture.viewModel.agentSessionLinkPerformStop(
            to: fixture.candidate, request: stopRequest,
            liveness: { Self.liveness }, queueHasCommittedDrain: { false },
            withdrawInbound: { true }, commitAuthorization: { .committed }
        )
        guard case let .settled(receipt) = stop else { return XCTFail("Expected Stop receipt") }
        XCTAssertEqual(receipt.result, .notRunning)
        XCTAssertEqual(fixture.viewModel.retrieveDraftText(for: fixture.session.tabID), recovered)
        fixture.session.selectedAgent = .openCode
        await fixture.viewModel.startAgentRun(tabID: fixture.session.tabID, initialMessage: "fresh run after Stop")
        await fixture.session.agentTask?.value
        XCTAssertEqual(fixture.provider.promptedMessages.count, 1)
        let prompted = try XCTUnwrap(fixture.provider.promptedMessages.last?.userMessage)
        XCTAssertTrue(prompted.contains("fresh run after Stop"))
        XCTAssertFalse(prompted.contains("local provider text"))
        XCTAssertFalse(prompted.contains("second pre-Stop provider payload"))
        XCTAssertFalse(prompted.contains("managed scheduled direction"))
        XCTAssertTrue(fixture.session.pendingInstructions.isEmpty)
    }

    func testOldFlushResumingAfterStopCannotClearSuccessorSteering() async throws {
        let fixture = try await makeFixture()
        let oldRunID = try XCTUnwrap(fixture.session.runID)
        let oldAttemptID = try XCTUnwrap(fixture.session.activeRunAttemptID)
        let oldFence = AgentRunStartStopFence(session: fixture.session)
        // The old flush is held at MCP-idle wait while Stop invalidates its fence. A newly
        // accepted run queues its own steer before that old waiter resumes.
        fixture.session.stopState.invalidateScheduledStarts()
        let successor = AgentModeViewModel.TabSession.ACPSteeringInstruction(
            id: UUID(), targetRunID: UUID(), targetRunAttemptID: UUID(),
            providerText: "successor direction", interruptedPromptProviderText: nil,
            attachments: [], taggedFileAttachments: [], draftText: "successor direction",
            optimisticUserItemID: nil, createdAt: Date()
        )
        fixture.session.pendingACPSteeringInstructions = [successor]
        fixture.viewModel.test_resumeStaleACPFlush(
            session: fixture.session, runID: oldRunID,
            runAttemptID: oldAttemptID, stopFence: oldFence
        )
        XCTAssertEqual(fixture.session.pendingACPSteeringInstructions.map(\.id), [successor.id])
        XCTAssertTrue(fixture.session.pendingInstructions.isEmpty)
    }

    func testStoppedFlushRestoresOnlyDequeuedLocalACPDraft() async throws {
        let fixture = try await makeFixture()
        let oldFence = AgentRunStartStopFence(session: fixture.session)
        let local = AgentModeViewModel.TabSession.ACPSteeringInstruction(
            id: UUID(), targetRunID: fixture.session.runID,
            targetRunAttemptID: fixture.session.activeRunAttemptID,
            providerText: "local direction", interruptedPromptProviderText: nil,
            attachments: [], taggedFileAttachments: [], draftText: "local direction",
            optimisticUserItemID: nil, createdAt: Date()
        )
        let message = request("managed direction")
        let sink = AgentSessionLinkManagedSteerSink()
        let managed = AgentModeViewModel.TabSession.ACPSteeringInstruction(
            id: UUID(), targetRunID: fixture.session.runID,
            targetRunAttemptID: fixture.session.activeRunAttemptID,
            providerText: "managed direction", interruptedPromptProviderText: nil,
            attachments: [], taggedFileAttachments: [], draftText: "",
            optimisticUserItemID: nil, createdAt: Date(),
            managed: .init(
                sink: sink, attributedItemID: UUID(),
                candidate: fixture.candidate, attribution: message.attribution
            )
        )
        fixture.session.stopState.invalidateScheduledStarts()
        fixture.viewModel.test_requeueDequeuedACPSteeringAfterStop(
            [local, managed], session: fixture.session, stopFence: oldFence
        )
        guard case .notAccepted = sink.outcome else { return XCTFail("managed steer must be refused") }
        let draft = fixture.viewModel.retrieveDraftText(for: fixture.session.tabID)
        XCTAssertTrue(draft.contains("local direction"))
        XCTAssertFalse(draft.contains("managed direction"))
        XCTAssertTrue(fixture.session.pendingInstructions.isEmpty)
    }

    func testAugmentationSuspensionCannotMutateReboundACPQueueOrComposer() async throws {
        let fixture = try await makeFixture()
        let entered = AgentSessionLinkStopSignal<Void>()
        let release = AgentSessionLinkStopSignal<Void>()
        addTeardownBlock { release.finish(()) }
        fixture.viewModel.test_afterProviderInputAugmentation = {
            entered.finish(())
            await release.value()
        }
        fixture.session.pendingNonCodexUserInputTokenQueue = [111]
        let message = request("stale managed direction")
        let steering = Task { await self.steer(fixture, request: message) }
        await entered.value()
        fixture.session.stopState.invalidateScheduledStarts()
        fixture.session.installPersistentSessionBinding(
            AgentPersistentSessionBindingIdentity(tabID: fixture.session.tabID, sessionID: UUID())
        )
        fixture.session.pendingNonCodexUserInputTokenQueue = [222]
        fixture.viewModel.storeDraftText(for: fixture.session.tabID, "replacement draft")
        release.finish(())
        let outcome = await steering.value
        guard case .blocked = outcome else { return XCTFail("stale steer must not be delivered") }
        XCTAssertEqual(fixture.session.pendingNonCodexUserInputTokenQueue, [222])
        XCTAssertEqual(fixture.viewModel.retrieveDraftText(for: fixture.session.tabID), "replacement draft")
        XCTAssertTrue(
            fixture.session.items.contains(where: { $0.text == message.message }),
            "a stale flush must not remove a row from the rebound session"
        )
        XCTAssertTrue(fixture.provider.promptedMessages.isEmpty)
        fixture.viewModel.test_afterProviderInputAugmentation = nil
    }

    func testCancelWipesManagedQueueWithoutRestoringItsDraft() async throws {
        let fixture = try await makeFixture()
        let message = request("managed queue entry")
        let envelope = AgentSessionLinkMessageEnvelope.render(
            sourceSessionID: message.observerSessionID, sourceName: message.observerDisplayName,
            linkID: message.linkID, linkGeneration: message.linkGeneration,
            message: message.message, framing: .management
        )
        let row = AgentChatItem.user(
            message.message, sequenceIndex: fixture.session.nextSequenceIndex,
            crossSessionAttribution: message.attribution, dispatchedProviderText: envelope
        )
        fixture.session.appendItem(row)
        let sink = AgentSessionLinkManagedSteerSink()
        sink.noteAppended(itemID: row.id)
        fixture.session.pendingACPSteeringInstructions.append(.init(
            id: UUID(), targetRunID: fixture.session.runID,
            targetRunAttemptID: fixture.session.activeRunAttemptID,
            providerText: envelope, interruptedPromptProviderText: nil,
            attachments: [], taggedFileAttachments: [], draftText: "",
            optimisticUserItemID: row.id, createdAt: Date(),
            managed: .init(
                sink: sink, attributedItemID: row.id,
                candidate: fixture.candidate, attribution: message.attribution
            )
        ))
        await fixture.viewModel.cancelAgentRun(tabID: fixture.session.tabID)
        guard case .notAccepted = sink.outcome else { return XCTFail("Queue wipe left a managed sink pending") }
        XCTAssertFalse(fixture.session.items.contains(where: { $0.id == row.id }))
        XCTAssertTrue(fixture.session.pendingACPSteeringInstructions.isEmpty)
    }

    func testComposerAcceptanceAdvancesGenerationButManagedInputDoesNot() async throws {
        let fixture = try await makeFixture()
        let endpoint = try XCTUnwrap(fixture.viewModel.agentSessionLinkObserverEndpoint(tabID: fixture.session.tabID))
        let bridge = AgentSessionLinkRuntimeBridge.shared
        // This suite builds a synthetic window. Publish its live endpoint to the shared bridge
        // so ordinary stale-endpoint sweeps cannot retire the generation during provider awaits.
        let host = LiveWindowEndpointHost()
        host.register(fixture.viewModel, windowID: 1)
        bridge.attach(host: host)
        defer { WindowStatesManager.shared.attachAgentSessionLinkBridge() }
        let before = bridge.captureWaitInput(for: endpoint)
        fixture.viewModel.test_beforeACPToolIdleWait = {
            XCTAssertGreaterThan(bridge.captureWaitInput(for: endpoint).generation, before.generation)
        }
        defer { fixture.viewModel.test_beforeACPToolIdleWait = nil }
        // Another MCP dispatch can be awaiting its acknowledgement; this is still local input.
        fixture.session.isMCPInstructionDispatchInProgress = true
        let submitted = fixture.viewModel.submitUserTurn(text: "accepted local input", tabID: fixture.session.tabID)
        fixture.session.isMCPInstructionDispatchInProgress = false
        guard case .submitted = submitted else { return XCTFail("Expected accepted composer input") }
        let after = bridge.captureWaitInput(for: endpoint)
        XCTAssertEqual(after.generation, before.generation + 1)
        let outcome = await steer(fixture, request: request("managed input"))
        guard case .delivered = outcome else { return XCTFail("Expected delivered managed input") }
        XCTAssertEqual(bridge.captureWaitInput(for: endpoint), after)
    }

    func testDeferredMCPInputDoesNotBecomeLocalAfterItsDispatchScopeEnds() async throws {
        let fixture = try await makeFixture()
        let endpoint = try XCTUnwrap(fixture.viewModel.agentSessionLinkObserverEndpoint(tabID: fixture.session.tabID))
        let bridge = AgentSessionLinkRuntimeBridge.shared
        // This suite builds a synthetic window. Publish its live endpoint to the shared bridge
        // so ordinary stale-endpoint sweeps cannot retire the generation during provider awaits.
        let host = LiveWindowEndpointHost()
        host.register(fixture.viewModel, windowID: 1)
        bridge.attach(host: host)
        defer { WindowStatesManager.shared.attachAgentSessionLinkBridge() }
        let before = bridge.captureWaitInput(for: endpoint)
        await fixture.viewModel.submitUserTurnAfterHydration(
            tabID: fixture.session.tabID, originalSession: fixture.session,
            originalBinding: fixture.session.persistentSessionBindingIdentity,
            trimmedText: "deferred MCP input", attachmentsToSend: [], taggedFilesToSend: [],
            activeWorkflow: nil, stopFence: AgentRunStartStopFence(session: fixture.session),
            isLocalComposerInput: false
        )
        XCTAssertTrue(fixture.session.items.contains { $0.text == "deferred MCP input" })
        XCTAssertEqual(bridge.captureWaitInput(for: endpoint), before)
    }

    func testInputAcceptedDuringReleaseBarrierMustAlsoFinishBeforeDrain() async throws {
        let fixture = try await makeFixture()
        let first = AgentSessionLinkStopSignal<Void>()
        let second = AgentSessionLinkStopSignal<Void>()
        addTeardownBlock { first.finish(())
            second.finish(())
        }
        let firstTask = Task { await first.value() }
        fixture.session.observerWaitRelease = (fixture.session.runID, fixture.session.activeRunAttemptID, firstTask)
        var drained = false
        let drain = Task { @MainActor in
            try await fixture.session.awaitObserverWaitRelease(
                runID: fixture.session.runID!,
                runAttemptID: fixture.session.activeRunAttemptID
            )
            drained = true
        }
        for _ in 0 ..< 50 {
            await Task.yield()
        }
        let secondTask = Task { await second.value() }
        fixture.session.observerWaitRelease = (fixture.session.runID, fixture.session.activeRunAttemptID, secondTask)
        first.finish(())
        await firstTask.value
        for _ in 0 ..< 50 {
            await Task.yield()
        }
        XCTAssertFalse(drained, "A newer accepted input still owns a pending barrier")
        second.finish(())
        try await drain.value
        XCTAssertTrue(drained)
    }

    func testAcceptedInputReleaseFinishesBeforeACPToolIdleDrain() async throws {
        let fixture = try await makeFixture()
        let release = AgentSessionLinkStopSignal<Void>()
        addTeardownBlock { release.finish(()) }
        var releaseFinished = false
        let forwarding = Task { @MainActor in
            await release.value()
            releaseFinished = true
        }
        fixture.session.observerWaitRelease = (
            fixture.session.runID, fixture.session.activeRunAttemptID, forwarding
        )
        fixture.viewModel.test_beforeACPToolIdleWait = {
            XCTAssertTrue(releaseFinished, "Host idle drain must follow the accepted-input release barrier")
        }
        defer { fixture.viewModel.test_beforeACPToolIdleWait = nil }
        let steering = Task { await self.steer(fixture, request: self.request("ordered steer")) }
        for _ in 0 ..< 50 {
            await Task.yield()
        }
        XCTAssertFalse(releaseFinished)
        release.finish(())
        let outcome = await steering.value
        guard case .delivered = outcome else { return XCTFail("Expected accepted steering, got \(outcome)") }
    }

    func testACPControllerTeardownWithdrawsManagedSteerBeforeDequeue() async throws {
        let fixture = try await makeFixture()
        let entered = AgentSessionLinkStopSignal<Void>()
        let release = AgentSessionLinkStopSignal<Void>()
        addTeardownBlock { release.finish(()) }
        fixture.viewModel.test_beforeACPToolIdleWait = {
            entered.finish(())
            await release.value()
        }
        defer { fixture.viewModel.test_beforeACPToolIdleWait = nil }

        let message = request("queued before shutdown")
        let steering = Task { await self.steer(fixture, request: message) }
        await entered.value()
        let row = try XCTUnwrap(fixture.session.items.first(where: { $0.text == message.message }))
        XCTAssertNotNil(row.dispatchedProviderText)
        XCTAssertEqual(fixture.session.pendingACPSteeringInstructions.count, 1)
        XCTAssertTrue(fixture.provider.promptedMessages.isEmpty)

        await fixture.session.teardownACPControllerIfPresent()
        release.finish(())
        let outcome = await steering.value
        XCTAssertEqual(outcome, .blocked(.steerNotAccepted))
        XCTAssertFalse(fixture.session.items.contains(where: { $0.id == row.id }))
        XCTAssertTrue(fixture.session.pendingACPSteeringInstructions.isEmpty)
        XCTAssertTrue(fixture.session.pendingInstructions.isEmpty)
        XCTAssertTrue(fixture.provider.promptedMessages.isEmpty)
    }

    func testControllerTeardownWithdrawsDequeuedManagedBatchDuringAugmentation() async throws {
        let fixture = try await makeFixture()
        let entered = AgentSessionLinkStopSignal<Void>()
        let release = AgentSessionLinkStopSignal<Void>()
        addTeardownBlock { release.finish(()) }
        fixture.viewModel.test_afterProviderInputAugmentation = {
            entered.finish(())
            await release.value()
        }
        defer { fixture.viewModel.test_afterProviderInputAugmentation = nil }
        let message = request("managed direction during teardown")
        let steering = Task { await self.steer(fixture, request: message) }
        await entered.value()
        XCTAssertTrue(fixture.session.pendingACPSteeringInstructions.isEmpty)
        let optimisticRow = try XCTUnwrap(fixture.session.items.first(where: { $0.text == message.message }))
        await fixture.session.teardownACPControllerIfPresent()
        release.finish(())
        let outcome = await steering.value
        XCTAssertEqual(outcome, .blocked(.steerNotAccepted))
        XCTAssertFalse(fixture.session.items.contains(where: { $0.id == optimisticRow.id }))
        XCTAssertTrue(fixture.session.pendingACPSteeringInstructions.isEmpty)
        XCTAssertTrue(fixture.session.pendingInstructions.isEmpty)
        XCTAssertTrue(fixture.provider.promptedMessages.isEmpty)
    }

    func testInterruptedAttributedReplayUsesExactStoredProviderBytes() async throws {
        let fixture = try await makeFixture()
        let attribution = request("x").attribution
        let exact = "  <cross_session_message delegation=\"user_delegated_management\">\n\u{00E9}&amp;\n</cross_session_message>  "
        let prior = AgentChatItem.user(
            "raw overseer words", sequenceIndex: fixture.session.nextSequenceIndex,
            crossSessionAttribution: attribution, dispatchedProviderText: exact
        )
        fixture.session.appendItem(prior)
        let next = AgentChatItem.user("new steer", sequenceIndex: fixture.session.nextSequenceIndex)
        XCTAssertEqual(
            fixture.viewModel.interruptedACPProviderText(for: fixture.session, before: next), exact
        )
        let restored = AgentChatItemPersist(from: prior).toItem()
        XCTAssertEqual(restored.dispatchedProviderText, exact)
    }

    func testLegacyAttributedReplayDropsAndLocalReplayRemains() async throws {
        let fixture = try await makeFixture()
        let attribution = request("x").attribution
        fixture.session.appendItem(.user(
            "legacy overseer words", sequenceIndex: fixture.session.nextSequenceIndex,
            crossSessionAttribution: attribution
        ))
        let next = AgentChatItem.user("new steer", sequenceIndex: fixture.session.nextSequenceIndex)
        XCTAssertNil(fixture.viewModel.interruptedACPProviderText(for: fixture.session, before: next))
        fixture.session.appendItem(.user("local message", sequenceIndex: fixture.session.nextSequenceIndex))
        let afterLocal = AgentChatItem.user("another steer", sequenceIndex: fixture.session.nextSequenceIndex)
        XCTAssertNotNil(fixture.viewModel.interruptedACPProviderText(for: fixture.session, before: afterLocal))
    }

    func testExistingRoutesAndUnavailableStateStayUnchanged() async throws {
        let fixture = try await makeFixture()
        XCTAssertEqual(fixture.viewModel.agentSessionLinkManagedSteerRoute(for: fixture.session), .acpQueued)
        fixture.session.acpController = nil
        XCTAssertNil(fixture.viewModel.agentSessionLinkManagedSteerRoute(for: fixture.session))
        XCTAssertEqual(
            fixture.viewModel.agentSessionLinkSteerAdmission(for: fixture.session, liveness: Self.liveness),
            .blocked(.steerUnavailable)
        )
        fixture.session.selectedAgent = .claudeCode
        XCTAssertEqual(fixture.viewModel.agentSessionLinkManagedSteerRoute(for: fixture.session), .claudeInterrupt)
        fixture.session.selectedAgent = .codexExec
        XCTAssertEqual(fixture.viewModel.agentSessionLinkManagedSteerRoute(for: fixture.session), .codex)
    }
}

import Foundation
import MCP
@testable import RepoPromptApp
import XCTest

final class ContextBuilderStrictFinalizationTests: XCTestCase {
    private var previousAdditionalOracleModels: [String] = []

    override func setUp() async throws {
        previousAdditionalOracleModels = await MainActor.run {
            GlobalSettingsStore.shared.additionalOracleModelRaws()
        }
        try await MainActor.run {
            try GlobalSettingsStore.shared.setAdditionalOracleModelRaws([], commit: false)
        }
        try await super.setUp()
    }

    override func tearDown() async throws {
        let previousAdditionalOracleModels = previousAdditionalOracleModels
        try await MainActor.run {
            try GlobalSettingsStore.shared.setAdditionalOracleModelRaws(previousAdditionalOracleModels, commit: false)
        }
        try await super.tearDown()
    }

    @MainActor
    func testActiveContextBuilderIncompleteTerminationFailsAndPreservesOracleChat() async throws {
        #if DEBUG
            let composition = makeComposition(
                windowID: -177,
                terminalOutcome: .incomplete(reason: "max_tokens")
            )
            await composition.workspaceManager.awaitInitialized()

            let root = makeTemporaryRoot(label: "active")
            defer { try? FileManager.default.removeItem(at: root) }

            let workspace = composition.workspaceManager.createWorkspace(
                name: "Context Builder strict active test",
                repoPaths: [root.path],
                ephemeral: true
            )
            await composition.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "ContextBuilderStrictFinalizationTests.active"
            )
            let activeWorkspace = try XCTUnwrap(composition.workspaceManager.activeWorkspace)
            let tabID = try XCTUnwrap(
                activeWorkspace.activeComposeTabID ?? activeWorkspace.composeTabs.first?.id
            )
            let agentModeSessionID = UUID()
            let agentModeRunID = UUID()
            let viewModel = composition.contextBuilderAgentViewModel
            installModelHook(on: viewModel)
            defer { viewModel.installRunTestHooks(nil) }

            do {
                _ = try await viewModel.runMCPPlanOrQuestion(
                    for: tabID,
                    oracleViewModel: composition.oracleViewModel,
                    agentModeSessionID: agentModeSessionID,
                    agentModeRunID: agentModeRunID,
                    mode: .plan,
                    prompt: "Produce a plan.",
                    selection: StoredSelection(),
                    reviewGitContext: .automaticOnly()
                )
                XCTFail("Expected incomplete provider termination to fail")
            } catch {
                XCTAssertEqual(
                    error as? OracleContextBuilderCompletionError,
                    .providerTerminatedIncomplete(reason: "max_tokens")
                )
            }

            let oracleSession = try XCTUnwrap(
                composition.oracleViewModel.sessions.first(where: {
                    $0.agentModeSessionID == agentModeSessionID &&
                        $0.agentModeRunID == agentModeRunID
                })
            )
            XCTAssertEqual(viewModel.currentFollowUpOracleChatID(for: tabID), oracleSession.shortID)
            let retainedResponse = try XCTUnwrap(
                composition.oracleViewModel.messagesSnapshot(for: oracleSession.id)
                    .first(where: { !$0.isUser })
            )
            XCTAssertTrue(retainedResponse.content.hasPrefix("partial response"))
            XCTAssertTrue(retainedResponse.content.contains("reason: max_tokens"))
            guard case .error = viewModel.planStatus(for: tabID) else {
                return XCTFail("Expected Context Builder error state")
            }
        #else
            throw XCTSkip("Strict finalization injection is DEBUG-only.")
        #endif
    }

    @MainActor
    func testInteractiveIncompleteTerminationPreservesPartialResponseAndShowsReason() async throws {
        #if DEBUG
            let composition = makeComposition(
                windowID: -180,
                terminalOutcome: .incomplete(reason: "max_tokens")
            )
            await composition.workspaceManager.awaitInitialized()

            let root = makeTemporaryRoot(label: "interactive-incomplete")
            defer { try? FileManager.default.removeItem(at: root) }

            let workspace = composition.workspaceManager.createWorkspace(
                name: "Interactive incomplete completion test",
                repoPaths: [root.path],
                ephemeral: true
            )
            await composition.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "ContextBuilderStrictFinalizationTests.interactive-incomplete"
            )

            let sentQueryID = await composition.oracleViewModel.sendMessage(
                "Produce a response.",
                overrideModel: .customProvider(
                    name: "Unconfigured test provider",
                    provider: "custom",
                    model: "unconfigured-test-model"
                )
            )
            let queryID = try XCTUnwrap(sentQueryID)
            let sessionID = try XCTUnwrap(composition.oracleViewModel.currentSessionID)
            try await composition.oracleViewModel.waitUntilMessageFinalised(queryID)

            let response = try XCTUnwrap(
                composition.oracleViewModel.messagesSnapshot(for: sessionID)
                    .first(where: { $0.id == queryID })
            )
            XCTAssertTrue(response.content.hasPrefix("partial response"))
            XCTAssertTrue(response.content.contains("reason: max_tokens"))
            XCTAssertTrue(response.isFinalized)
        #else
            throw XCTSkip("Strict finalization injection is DEBUG-only.")
        #endif
    }

    @MainActor
    func testAskOracleIncompleteTerminationFailsAndPreservesTranscript() async throws {
        #if DEBUG
            let composition = makeComposition(
                windowID: -181,
                terminalOutcome: .incomplete(reason: "max_tokens")
            )
            await composition.workspaceManager.awaitInitialized()

            let root = makeTemporaryRoot(label: "ask-oracle-incomplete")
            defer { try? FileManager.default.removeItem(at: root) }

            let workspace = composition.workspaceManager.createWorkspace(
                name: "Ask Oracle incomplete completion test",
                repoPaths: [root.path],
                ephemeral: true
            )
            await composition.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "ContextBuilderStrictFinalizationTests.ask-oracle-incomplete"
            )

            let settings = GlobalSettingsStore.shared
            let previousShowPresets = settings.mcpShowModelPresets()
            let previousDisablePresets = settings.mcpTemporarilyDisablePresets()
            let previousPlanningModel = composition.promptManager.planningModelName
            let previousCustomProviderValidity = composition.apiSettingsViewModel.isCustomProviderValid
            defer {
                settings.setMCPShowModelPresets(previousShowPresets, commit: false)
                settings.setMCPTemporarilyDisablePresets(previousDisablePresets, commit: false)
                composition.promptManager.planningModelName = previousPlanningModel
                composition.apiSettingsViewModel.isCustomProviderValid = previousCustomProviderValidity
            }
            settings.setMCPShowModelPresets(false, commit: false)
            settings.setMCPTemporarilyDisablePresets(false, commit: false)
            composition.apiSettingsViewModel.isCustomProviderValid = true
            composition.promptManager.planningModelName = AIModel.customProviderUser(
                name: "strict-finalization-test"
            ).rawValue
            let oracleSession = try await composition.oracleViewModel.createSession(
                named: "Ask Oracle incomplete response"
            )

            do {
                _ = try await composition.oracleViewModel.tool_chatSend(
                    args: [
                        "message": .string("Review the response."),
                        "mode": .string("review"),
                        "chat_id": .string(oracleSession.id.uuidString)
                    ],
                    promptVM: composition.promptManager
                )
                XCTFail("Expected Ask Oracle incomplete provider termination to fail")
            } catch {
                XCTAssertEqual(
                    error as? OracleContextBuilderCompletionError,
                    .providerTerminatedIncomplete(reason: "max_tokens")
                )
            }

            let response = try XCTUnwrap(
                composition.oracleViewModel.messagesSnapshot(for: oracleSession.id)
                    .first(where: { !$0.isUser })
            )
            XCTAssertTrue(response.content.hasPrefix("partial response"))
            XCTAssertTrue(response.content.contains("reason: max_tokens"))
            XCTAssertTrue(response.isFinalized)
        #else
            throw XCTSkip("Strict finalization injection is DEBUG-only.")
        #endif
    }

    @MainActor
    func testAskOracleProviderCompletionReturnsExactResponse() async throws {
        #if DEBUG
            let composition = makeComposition(windowID: -182, terminalOutcome: .completed)
            await composition.workspaceManager.awaitInitialized()

            let root = makeTemporaryRoot(label: "ask-oracle-completed")
            defer { try? FileManager.default.removeItem(at: root) }

            let workspace = composition.workspaceManager.createWorkspace(
                name: "Ask Oracle completed response test",
                repoPaths: [root.path],
                ephemeral: true
            )
            await composition.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "ContextBuilderStrictFinalizationTests.ask-oracle-completed"
            )

            let settings = GlobalSettingsStore.shared
            let previousShowPresets = settings.mcpShowModelPresets()
            let previousDisablePresets = settings.mcpTemporarilyDisablePresets()
            let previousPlanningModel = composition.promptManager.planningModelName
            let previousCustomProviderValidity = composition.apiSettingsViewModel.isCustomProviderValid
            defer {
                settings.setMCPShowModelPresets(previousShowPresets, commit: false)
                settings.setMCPTemporarilyDisablePresets(previousDisablePresets, commit: false)
                composition.promptManager.planningModelName = previousPlanningModel
                composition.apiSettingsViewModel.isCustomProviderValid = previousCustomProviderValidity
            }
            settings.setMCPShowModelPresets(false, commit: false)
            settings.setMCPTemporarilyDisablePresets(false, commit: false)
            composition.apiSettingsViewModel.isCustomProviderValid = true
            composition.promptManager.planningModelName = AIModel.customProviderUser(
                name: "strict-finalization-test"
            ).rawValue

            let reply = try await composition.oracleViewModel.tool_chatSend(
                args: [
                    "message": .string("Review the response."),
                    "mode": .string("review")
                ],
                promptVM: composition.promptManager
            )

            XCTAssertEqual(reply["response"]?.stringValue, "partial response")
            XCTAssertNil(reply["errors"])
        #else
            throw XCTSkip("Strict finalization injection is DEBUG-only.")
        #endif
    }

    @MainActor
    func testInactiveContextBuilderCleanEOFFailsBeforePersistence() async throws {
        #if DEBUG
            let composition = makeComposition(windowID: -178)
            await composition.workspaceManager.awaitInitialized()

            let activeRoot = makeTemporaryRoot(label: "headless-active")
            let inactiveRoot = makeTemporaryRoot(label: "headless-target")
            defer {
                try? FileManager.default.removeItem(at: activeRoot)
                try? FileManager.default.removeItem(at: inactiveRoot)
            }

            let activeWorkspace = composition.workspaceManager.createWorkspace(
                name: "Context Builder strict headless active workspace",
                repoPaths: [activeRoot.path],
                ephemeral: true
            )
            await composition.workspaceManager.switchWorkspace(
                to: activeWorkspace,
                saveState: false,
                reason: "ContextBuilderStrictFinalizationTests.headless-active"
            )
            let inactiveWorkspace = composition.workspaceManager.createWorkspace(
                name: "Context Builder strict headless target workspace",
                repoPaths: [inactiveRoot.path],
                ephemeral: true
            )
            let tabID = try XCTUnwrap(
                inactiveWorkspace.activeComposeTabID ?? inactiveWorkspace.composeTabs.first?.id
            )
            let identity = WorkspaceSelectionIdentity(
                workspaceID: inactiveWorkspace.id,
                tabID: tabID
            )
            let viewModel = composition.contextBuilderAgentViewModel
            installModelHook(on: viewModel)
            defer { viewModel.installRunTestHooks(nil) }
            let initialPersistedSessionIDs = try await Set(
                composition.oracleViewModel.chatData.recentSessions(
                    for: inactiveWorkspace,
                    limit: 100,
                    composeTabID: tabID
                ).map(\.id)
            )

            do {
                _ = try await viewModel.runMCPPlanOrQuestion(
                    for: identity,
                    oracleViewModel: composition.oracleViewModel,
                    mode: .plan,
                    prompt: "Produce a plan.",
                    selection: StoredSelection(),
                    reviewGitContext: .automaticOnly()
                )
                XCTFail("Expected headless clean EOF without provider completion to fail")
            } catch {
                XCTAssertEqual(
                    error as? OracleContextBuilderCompletionError,
                    .streamEndedWithoutProviderCompletion
                )
            }

            let persistedSessionIDs = try await Set(
                composition.oracleViewModel.chatData.recentSessions(
                    for: inactiveWorkspace,
                    limit: 100,
                    composeTabID: tabID
                ).map(\.id)
            )
            XCTAssertEqual(persistedSessionIDs, initialPersistedSessionIDs)
            XCTAssertNil(viewModel.currentFollowUpOracleChatID(for: tabID))
            guard case .error = viewModel.planStatus(for: tabID) else {
                return XCTFail("Expected Context Builder error state")
            }
        #else
            throw XCTSkip("Strict finalization injection is DEBUG-only.")
        #endif
    }

    @MainActor
    func testInactiveContextBuilderProviderCompletionPersistsReply() async throws {
        #if DEBUG
            let composition = makeComposition(windowID: -179, terminalOutcome: .completed)
            await composition.workspaceManager.awaitInitialized()

            let activeRoot = makeTemporaryRoot(label: "headless-success-active")
            let inactiveRoot = makeTemporaryRoot(label: "headless-success-target")
            defer {
                try? FileManager.default.removeItem(at: activeRoot)
                try? FileManager.default.removeItem(at: inactiveRoot)
            }

            let activeWorkspace = composition.workspaceManager.createWorkspace(
                name: "Context Builder strict headless success active workspace",
                repoPaths: [activeRoot.path],
                ephemeral: true
            )
            await composition.workspaceManager.switchWorkspace(
                to: activeWorkspace,
                saveState: false,
                reason: "ContextBuilderStrictFinalizationTests.headless-success-active"
            )
            let inactiveWorkspace = composition.workspaceManager.createWorkspace(
                name: "Context Builder strict headless success target workspace",
                repoPaths: [inactiveRoot.path],
                ephemeral: true
            )
            let tabID = try XCTUnwrap(
                inactiveWorkspace.activeComposeTabID ?? inactiveWorkspace.composeTabs.first?.id
            )
            let identity = WorkspaceSelectionIdentity(
                workspaceID: inactiveWorkspace.id,
                tabID: tabID
            )
            let viewModel = composition.contextBuilderAgentViewModel
            installModelHook(on: viewModel)
            defer { viewModel.installRunTestHooks(nil) }

            let reply = try await viewModel.runMCPPlanOrQuestion(
                for: identity,
                oracleViewModel: composition.oracleViewModel,
                mode: .plan,
                prompt: "Produce a plan.",
                selection: StoredSelection(),
                reviewGitContext: .automaticOnly()
            )

            XCTAssertEqual(reply.response, "partial response")
            XCTAssertEqual(viewModel.currentFollowUpOracleChatID(for: tabID), reply.shortId)

            let persistedSession = try await composition.oracleViewModel.chatData.findSession(
                for: inactiveWorkspace,
                id: reply.shortId,
                composeTabID: tabID
            )
            XCTAssertEqual(persistedSession?.id, reply.chatId)
            XCTAssertEqual(persistedSession?.shortID, reply.shortId)
            XCTAssertEqual(persistedSession?.messages.last?.rawText, "partial response")
        #else
            throw XCTSkip("Strict finalization injection is DEBUG-only.")
        #endif
    }

    @MainActor
    func testGroupPrimaryFailureReturnsStructuredReplyWithoutAuxiliarySubstitution() async throws {
        #if DEBUG
            let primaryModel = AIModel.customProviderUser(name: "oracle-group-primary-failure-test")
            let auxiliaryModel = AIModel.customProviderUser(name: "oracle-group-auxiliary-success-test")
            try GlobalSettingsStore.shared.setAdditionalOracleModelRaws(
                [auxiliaryModel.rawValue],
                commit: false
            )
            let composition = makeComposition(
                windowID: -184,
                streamOutputProvider: { model in
                    if model.rawValue == primaryModel.rawValue {
                        return (
                            text: "primary partial",
                            terminalOutcome: .incomplete(reason: "max_tokens")
                        )
                    }
                    return (text: "auxiliary answer", terminalOutcome: .completed)
                }
            )
            await composition.workspaceManager.awaitInitialized()
            let previousCustomProviderValidity = composition.apiSettingsViewModel.isCustomProviderValid
            composition.apiSettingsViewModel.isCustomProviderValid = true
            defer { composition.apiSettingsViewModel.isCustomProviderValid = previousCustomProviderValidity }

            let root = makeTemporaryRoot(label: "group-incomplete")
            defer { try? FileManager.default.removeItem(at: root) }

            let workspace = composition.workspaceManager.createWorkspace(
                name: "Context Builder grouped incomplete test",
                repoPaths: [root.path],
                ephemeral: true
            )
            await composition.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "ContextBuilderStrictFinalizationTests.group-incomplete"
            )
            let activeWorkspace = try XCTUnwrap(composition.workspaceManager.activeWorkspace)
            let tabID = try XCTUnwrap(
                activeWorkspace.activeComposeTabID ?? activeWorkspace.composeTabs.first?.id
            )
            let viewModel = composition.contextBuilderAgentViewModel
            viewModel.installRunTestHooks(
                ContextBuilderAgentViewModel.RunTestHooks(
                    beforeProcessingProviderEvent: nil,
                    providerEventDisposition: nil,
                    teardownCompleted: nil,
                    resolveMCPFollowUpModel: { _ in
                        (model: primaryModel, chatPresetID: nil, mcpControlInfo: nil)
                    }
                )
            )
            defer { viewModel.installRunTestHooks(nil) }

            let phaseRecorder = ContextBuilderStrictFinalizationPhaseRecorder()
            let reply = try await viewModel.runMCPPlanOrQuestion(
                for: tabID,
                oracleViewModel: composition.oracleViewModel,
                mode: .plan,
                prompt: "Produce a grouped plan.",
                selection: StoredSelection(),
                reviewGitContext: .automaticOnly(),
                progressReporter: { phase in
                    await phaseRecorder.record(phase)
                }
            )
            XCTAssertEqual(reply.oracleGroup?.result.status, .failed)
            XCTAssertEqual(reply.response, "primary partial")
            XCTAssertEqual(reply.oracleGroup?.orderedResults.map(\.laneIndex), [0, 1])
            XCTAssertEqual(reply.oracleGroup?.orderedResults.map(\.status), [.failed, .completed])
            XCTAssertEqual(
                reply.oracleGroup?.orderedResults.map(\.response),
                [nil, "auxiliary answer"]
            )
            XCTAssertEqual(
                reply.oracleGroup?.orderedResults.map { $0.error?.partialResponse },
                ["primary partial", nil]
            )
            XCTAssertEqual(reply.errors, [
                "Oracle failed: The provider ended the response before successful completion (reason: max_tokens)."
            ])
            let owner = try OracleViewModel.oracleGroupOwner(
                workspaceID: workspace.id,
                tabID: tabID
            )
            let loadedGroup = try await AppDomainRuntimeComposition.shared
                .oracleConversationStore.load(
                    member: OracleMemberLookup(publicChatID: reply.shortId),
                    owner: owner
                )
            let group = try XCTUnwrap(loadedGroup)
            XCTAssertEqual(group.turns.last?.status, .failed)
            XCTAssertEqual(group.turns.last?.results.map(\.status), [.failed, .completed])
            XCTAssertEqual(
                group.turns.last?.results.map { $0.error?.partialResponse },
                ["primary partial", nil]
            )

            XCTAssertEqual(viewModel.generatedPlanResponseText(for: tabID), "primary partial")
            XCTAssertNotNil(viewModel.currentFollowUpOracleChatID(for: tabID))
            guard case let .ready(_, previewText) = viewModel.planStatus(for: tabID) else {
                return XCTFail("Expected Context Builder ready state with retained Primary partial response")
            }
            XCTAssertEqual(previewText, "primary partial")
            let phases = await phaseRecorder.snapshot()
            XCTAssertEqual(phases, [
                .modelResolution,
                .payloadPackaging,
                .sessionCreationAndPersist,
                .streaming,
                .messageFinalization
            ])
        #else
            throw XCTSkip("Strict finalization injection is DEBUG-only.")
        #endif
    }

    @MainActor
    func testReplacementOracleRunOwnsStateWhilePredecessorResumesAfterReservationRelease() async throws {
        #if DEBUG
            let testModel = AIModel.customProviderUser(name: "oracle-group-replacement-test")
            try GlobalSettingsStore.shared.setAdditionalOracleModelRaws(
                [testModel.rawValue],
                commit: false
            )
            let responseCounter = ContextBuilderStrictFinalizationResponseCounter()
            let composition = makeComposition(
                windowID: -183,
                terminalOutcome: .completed,
                responseTextProvider: {
                    let index = await responseCounter.next()
                    return "response-\(index)"
                }
            )
            await composition.workspaceManager.awaitInitialized()
            let previousCustomProviderValidity = composition.apiSettingsViewModel.isCustomProviderValid
            composition.apiSettingsViewModel.isCustomProviderValid = true
            defer { composition.apiSettingsViewModel.isCustomProviderValid = previousCustomProviderValidity }

            let root = makeTemporaryRoot(label: "replacement-after-reservation-release")
            defer { try? FileManager.default.removeItem(at: root) }

            let workspace = composition.workspaceManager.createWorkspace(
                name: "Context Builder replacement ownership test",
                repoPaths: [root.path],
                ephemeral: true
            )
            await composition.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "ContextBuilderStrictFinalizationTests.replacement-after-reservation-release"
            )
            let activeWorkspace = try XCTUnwrap(composition.workspaceManager.activeWorkspace)
            let tabID = try XCTUnwrap(
                activeWorkspace.activeComposeTabID ?? activeWorkspace.composeTabs.first?.id
            )
            let viewModel = composition.contextBuilderAgentViewModel
            let firstReleaseGate = ContextBuilderStrictFinalizationGate()
            let secondReleaseGate = ContextBuilderStrictFinalizationGate()
            var releaseCount = 0
            viewModel.installRunTestHooks(
                ContextBuilderAgentViewModel.RunTestHooks(
                    beforeProcessingProviderEvent: nil,
                    providerEventDisposition: nil,
                    teardownCompleted: nil,
                    resolveMCPFollowUpModel: { _ in
                        (
                            model: testModel,
                            chatPresetID: nil,
                            mcpControlInfo: nil
                        )
                    },
                    afterOracleArtifactReservationReleased: { _ in
                        releaseCount += 1
                        if releaseCount == 1 {
                            await firstReleaseGate.arriveAndWait()
                        } else if releaseCount == 2 {
                            await secondReleaseGate.arriveAndWait()
                        }
                    }
                )
            )
            defer { viewModel.installRunTestHooks(nil) }

            let firstRun = Task { @MainActor in
                try await viewModel.runMCPPlanOrQuestion(
                    for: tabID,
                    oracleViewModel: composition.oracleViewModel,
                    mode: .plan,
                    prompt: "First plan.",
                    selection: StoredSelection(),
                    reviewGitContext: .automaticOnly()
                )
            }
            await firstReleaseGate.waitUntilArrived()

            let secondRun = Task { @MainActor in
                try await viewModel.runMCPPlanOrQuestion(
                    for: tabID,
                    oracleViewModel: composition.oracleViewModel,
                    mode: .plan,
                    prompt: "Second plan.",
                    selection: StoredSelection(),
                    reviewGitContext: .automaticOnly()
                )
            }
            await secondReleaseGate.waitUntilArrived()

            XCTAssertEqual(viewModel.planStatus(for: tabID), .generating)
            XCTAssertTrue(viewModel.hasFollowUpOracleGroupTaskForTesting(tabID: tabID))
            let replacementProgress = try XCTUnwrap(viewModel.generatedPlanResponseText(for: tabID))
            XCTAssertTrue(replacementProgress.hasPrefix("response-"))

            await firstReleaseGate.release()
            do {
                _ = try await firstRun.value
                XCTFail("Expected the replaced Oracle run to cancel")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }

            XCTAssertEqual(viewModel.planStatus(for: tabID), .generating)
            XCTAssertTrue(viewModel.hasFollowUpOracleGroupTaskForTesting(tabID: tabID))
            XCTAssertEqual(viewModel.generatedPlanResponseText(for: tabID), replacementProgress)

            await secondReleaseGate.release()
            let reply = try await secondRun.value
            let response = try XCTUnwrap(reply.response)
            XCTAssertTrue(response.hasPrefix("response-"))
            XCTAssertEqual(viewModel.generatedPlanResponseText(for: tabID), response)
            XCTAssertFalse(viewModel.hasFollowUpOracleGroupTaskForTesting(tabID: tabID))
        #else
            throw XCTSkip("Oracle replacement ownership injection is DEBUG-only.")
        #endif
    }

    #if DEBUG
        @MainActor
        private func makeComposition(
            windowID: Int,
            terminalOutcome: ChatStreamTerminalOutcome? = nil,
            responseTextProvider: (@Sendable () async -> String)? = nil,
            streamOutputProvider: (@Sendable (AIModel) async -> (
                text: String,
                terminalOutcome: ChatStreamTerminalOutcome?
            ))? = nil
        ) -> WindowStateComposition {
            let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            let composition = WindowStateCompositionFactory.make(
                windowID: windowID,
                deferredInitialAgentSystemWorkspaceRefresh: true,
                sharedMCPService: MCPService(),
                aiQueriesServiceFactory: { keyManager in
                    AIQueriesService(
                        keyManager: keyManager,
                        sendPromptOverride: { _, model in
                            let output = await streamOutputProvider?(model)
                            let responseText: String = if let output {
                                output.text
                            } else {
                                await responseTextProvider?() ?? "partial response"
                            }
                            let selectedTerminalOutcome = output?.terminalOutcome ?? terminalOutcome
                            let stream = AsyncThrowingStream<ChatStreamOutput, Error> { continuation in
                                continuation.yield(
                                    ChatStreamOutput(
                                        text: responseText,
                                        reasoning: nil,
                                        tokens: ChatTokenInfo(),
                                        terminalOutcome: selectedTerminalOutcome
                                    )
                                )
                                continuation.finish()
                            }
                            return (UUID(), stream)
                        }
                    )
                }
            )
            GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
            return composition
        }

        @MainActor
        private func installModelHook(on viewModel: ContextBuilderAgentViewModel) {
            viewModel.installRunTestHooks(
                ContextBuilderAgentViewModel.RunTestHooks(
                    beforeProcessingProviderEvent: nil,
                    providerEventDisposition: nil,
                    teardownCompleted: nil,
                    resolveMCPFollowUpModel: { _ in
                        (
                            model: .customProvider(
                                name: "Unconfigured test provider",
                                provider: "custom",
                                model: "unconfigured-test-model"
                            ),
                            chatPresetID: nil,
                            mcpControlInfo: nil
                        )
                    }
                )
            )
        }

        private func makeTemporaryRoot(label: String) -> URL {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("ContextBuilderStrictFinalizationTests-\(label)-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            return root
        }
    #endif
}

private actor ContextBuilderStrictFinalizationResponseCounter {
    private var value = 0

    func next() -> Int {
        value += 1
        return value
    }
}

private actor ContextBuilderStrictFinalizationPhaseRecorder {
    private var phases: [ContextBuilderMCPProgressPhase] = []

    func record(_ phase: ContextBuilderMCPProgressPhase) {
        phases.append(phase)
    }

    func snapshot() -> [ContextBuilderMCPProgressPhase] {
        phases
    }
}

private actor ContextBuilderStrictFinalizationGate {
    private var arrived = false
    private var released = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func arriveAndWait() async {
        arrived = true
        let waiters = arrivalWaiters
        arrivalWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilArrived() async {
        guard !arrived else { return }
        await withCheckedContinuation { continuation in
            arrivalWaiters.append(continuation)
        }
    }

    func release() {
        guard !released else { return }
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

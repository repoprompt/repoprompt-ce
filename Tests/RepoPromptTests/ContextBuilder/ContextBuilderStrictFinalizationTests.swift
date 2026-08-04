import Foundation
@testable import RepoPromptApp
import XCTest

final class ContextBuilderStrictFinalizationTests: XCTestCase {
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
            XCTAssertTrue(
                composition.oracleViewModel.messagesSnapshot(for: oracleSession.id)
                    .contains(where: { !$0.isUser && $0.content == "partial response" })
            )
            guard case .error = viewModel.planStatus(for: tabID) else {
                return XCTFail("Expected Context Builder error state")
            }
        #else
            throw XCTSkip("Strict finalization injection is DEBUG-only.")
        #endif
    }

    @MainActor
    func testInteractiveIncompleteTerminationPreservesPartialResponse() async throws {
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
            XCTAssertEqual(response.content, "partial response")
            XCTAssertTrue(response.isFinalized)
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

    #if DEBUG
        @MainActor
        private func makeComposition(
            windowID: Int,
            terminalOutcome: ChatStreamTerminalOutcome? = nil
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
                        sendPromptOverride: { _, _ in
                            let stream = AsyncThrowingStream<ChatStreamOutput, Error> { continuation in
                                continuation.yield(
                                    ChatStreamOutput(
                                        text: "partial response",
                                        reasoning: nil,
                                        tokens: ChatTokenInfo(),
                                        terminalOutcome: terminalOutcome
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

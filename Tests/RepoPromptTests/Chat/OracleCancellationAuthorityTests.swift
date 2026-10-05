import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptFoundation
import RepoPromptSettingsCore
import XCTest

@MainActor
final class OracleCancellationAuthorityTests: XCTestCase {
    func testForegroundExplicitCancelPreservesResolvedAuthorityForReloadAndContinuation() async throws {
        try await assertCancellationPreservesAuthority(.explicit)
    }

    func testPreTokenTransportCancelPreservesResolvedAuthorityForReloadAndContinuation() async throws {
        try await assertCancellationPreservesAuthority(.transport)
    }

    func testPreTokenTransportCancelPreservesAuthorityAcrossConcurrentSessionReload() async throws {
        try await assertCancellationPreservesAuthority(.transport, pauseReload: true)
    }

    func testSameWorkspaceReloadPreservesHeldStreamOwnership() async throws {
        try await assertCancellationPreservesAuthority(.explicit, pauseReload: true, reloadWhileStreaming: true)
    }

    func testImagePreparationPublicationOwnership() async throws {
        let composition = WindowStateCompositionFactory.make(
            windowID: -9342, deferredInitialAgentSystemWorkspaceRefresh: true, sharedMCPService: MCPService()
        )
        await composition.workspaceManager.awaitInitialized()
        let oracle = composition.oracleViewModel
        defer {
            oracle.oracleImageThumbnailsForTesting = nil
            oracle.setOraclePostPackagingTransportOverrideForTesting(nil)
            composition.workspaceManager.prepareForWindowClose()
            oracle.sessions = []
        }
        composition.apiSettingsViewModel.openAIApiKey = "test-key"
        composition.apiSettingsViewModel.isOpenAIKeyValid = true
        await oracle.startNewChatSession()
        let sessionID = try XCTUnwrap(oracle.currentSessionID)
        let original = AITransientImage(bytes: Data([1, 2, 3]), mediaType: .png, title: "original")
        var gates: [CheckedContinuation<[AIChatImageAttachment], Error>] = []
        var sent: [AIMessage] = []
        oracle.oracleImageThumbnailsForTesting = { _ in
            try await withCheckedThrowingContinuation { gates.append($0) }
        }
        oracle.setOraclePostPackagingTransportOverrideForTesting { message, _ in
            sent.append(message)
            return (UUID(), AsyncThrowingStream { continuation in
                continuation.yield(ChatStreamOutput(text: "done", reasoning: nil, tokens: ChatTokenInfo(), terminalOutcome: .completed))
                continuation.finish()
            })
        }
        func begin(_ text: String, scope: ContextBuilderOracleLaneScope? = nil) -> Task<UUID?, Never> {
            Task { await oracle.sendMessage(
                text,
                sessionID: sessionID,
                overrideModel: .gpt54Mini,
                oracleTransientImages: [original],
                contextBuilderScope: scope
            ) }
        }
        func waitForGate(_ count: Int) async throws {
            try await AsyncTestWait.waitUntil("thumbnail preparation \(count)") { gates.count == count }
        }
        func waitForCompletion(_ id: UUID, in target: UUID) async throws {
            try await AsyncTestWait.waitUntil("prepared image send completion") {
                !oracle.isSessionStreaming(target) && oracle.messagesSnapshot(for: target).contains {
                    $0.id == id && $0.isFinalized && $0.content == "done"
                }
            }
        }

        let cancelled = begin("cancelled")
        try await waitForGate(1)
        cancelled.cancel()
        gates[0].resume(returning: [])
        let cancelledResult = await cancelled.value
        XCTAssertNil(cancelledResult)

        let group = ContextBuilderOracleGroupSupervision()
        let revoked = begin("revoked", scope: group.makeLane(sessionID: sessionID))
        try await waitForGate(2)
        group.cancel()
        gates[1].resume(returning: [])
        let revokedResult = await revoked.value
        XCTAssertNil(revokedResult)
        XCTAssertTrue(oracle.messagesSnapshot(for: sessionID).isEmpty)
        XCTAssertTrue(sent.isEmpty)

        let older = begin("older")
        try await waitForGate(3)
        let newer = begin("newer")
        try await waitForGate(4)
        gates[2].resume(returning: [])
        let olderResult = await older.value
        XCTAssertNil(olderResult)
        // An obsolete preparation must not clear the newer owner's token.
        gates[3].resume(returning: [])
        let newerResult = await newer.value
        XCTAssertNotNil(newerResult)
        if let newerResult { try await waitForCompletion(newerResult, in: sessionID) }

        let beforeText = begin("before text")
        try await waitForGate(5)
        let textResult = await oracle.sendMessage("text successor", sessionID: sessionID, overrideModel: .gpt54Mini)
        if let textResult { try await waitForCompletion(textResult, in: sessionID) }
        gates[4].resume(returning: [])
        let beforeTextResult = await beforeText.value
        XCTAssertNil(beforeTextResult)

        let explicitlyCancelled = begin("explicit cancel")
        try await waitForGate(6)
        await oracle.cancelAIResponse(in: sessionID)
        gates[5].resume(returning: [])
        let explicitResult = await explicitlyCancelled.value
        XCTAssertNil(explicitResult)

        let reset = begin("reset")
        try await waitForGate(7)
        await oracle.cancelAllActiveSessionStreams()
        gates[6].resume(returning: [])
        let resetResult = await reset.value
        XCTAssertNil(resetResult)

        let background = begin("background")
        try await waitForGate(8)
        await oracle.startNewChatSession()
        gates[7].resume(returning: [])
        let backgroundResult = await background.value
        XCTAssertNotNil(backgroundResult)
        if let backgroundResult { try await waitForCompletion(backgroundResult, in: sessionID) }

        let obsolete = begin("obsolete")
        try await waitForGate(9)
        let latest = begin("latest")
        try await waitForGate(10)
        gates[9].resume(returning: [])
        let latestResult = await latest.value
        XCTAssertNotNil(latestResult)
        if let latestResult { try await waitForCompletion(latestResult, in: sessionID) }
        gates[8].resume(returning: [])
        let obsoleteResult = await obsolete.value
        XCTAssertNil(obsoleteResult)

        XCTAssertEqual(
            oracle.messagesSnapshot(for: sessionID).filter(\.isUser).map(\.content),
            ["newer", "text successor", "background", "latest"]
        )
        XCTAssertTrue(oracle.messagesSnapshot(for: sessionID).filter(\.isUser).allSatisfy(\.imageAttachments.isEmpty))

        let deleted = begin("deleted")
        try await waitForGate(11)
        oracle.purgeSessionStorage(sessionID)
        gates[10].resume(returning: [])
        let deletedResult = await deleted.value
        XCTAssertNil(deletedResult)
        XCTAssertTrue(oracle.messagesSnapshot(for: sessionID).isEmpty)
        XCTAssertEqual(
            sent.map { $0.conversationMessages.last?.content ?? "" },
            ["newer", "text successor", "background", "latest"].map { "<user_instructions>\n\($0)\n</user_instructions>" }
        )
        XCTAssertEqual(sent.first?.transientImages.first?.bytes, original.bytes)
        XCTAssertEqual(sent.last?.transientImages.first?.bytes, original.bytes)

        // Exercise real preview failure through sendMessage, not just the ordering override.
        oracle.oracleImageThumbnailsForTesting = nil
        let visibleSessionID = try XCTUnwrap(oracle.currentSessionID)
        let placeholder = await oracle.sendMessage(
            "unavailable preview",
            sessionID: visibleSessionID,
            overrideModel: .gpt54Mini,
            oracleTransientImages: [original]
        )
        let placeholderID = try XCTUnwrap(placeholder)
        try await waitForCompletion(placeholderID, in: visibleSessionID)
        XCTAssertEqual(sent.count, 5)
        XCTAssertEqual(sent.last?.transientImages.first?.bytes, original.bytes)
        let previews = try XCTUnwrap(oracle.messagesSnapshot(for: visibleSessionID).first(where: \.isUser)?.imageAttachments)
        XCTAssertEqual(previews.count, 1)
        XCTAssertTrue(previews[0].thumbnailData.isEmpty)
    }

    private enum CancellationKind: Equatable {
        case explicit
        case transport
    }

    private func assertCancellationPreservesAuthority(
        _ cancellationKind: CancellationKind,
        pauseReload: Bool = false,
        reloadWhileStreaming: Bool = false
    ) async throws {
        let composition = WindowStateCompositionFactory.make(
            windowID: cancellationKind == .explicit ? -9340 : -9341,
            deferredInitialAgentSystemWorkspaceRefresh: true,
            sharedMCPService: MCPService()
        )
        await composition.workspaceManager.awaitInitialized()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OracleCancellationAuthority-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            composition.oracleViewModel.setOraclePostPackagingTransportOverrideForTesting(nil)
            composition.workspaceManager.prepareForWindowClose()
            composition.oracleViewModel.sessions = []
            try? FileManager.default.removeItem(at: root)
        }

        var workspace = try XCTUnwrap(composition.workspaceManager.activeWorkspace)
        let tab = ComposeTabState(id: UUID())
        workspace.customStoragePath = root
        workspace.composeTabs = [tab]
        workspace.activeComposeTabID = tab.id
        if let index = composition.workspaceManager.workspaces.firstIndex(where: { $0.id == workspace.id }) {
            composition.workspaceManager.workspaces[index] = workspace
        }
        composition.workspaceManager.activeWorkspace = workspace
        composition.promptManager.loadComposeTabsFromWorkspace(workspace)
        composition.apiSettingsViewModel.openAIApiKey = "test-key"
        composition.apiSettingsViewModel.isOpenAIKeyValid = true
        composition.promptManager.preferredModel = AIModel.gpt54.rawValue
        composition.promptManager.selectedChatPresetID = ChatPreset.BuiltIn.chat.id

        let promptID = UUID()
        let promptMarker = "CANCELLED ORACLE CUSTOM REVIEW"
        composition.promptManager.storedPrompts.append(
            StoredPromptRecord(id: promptID, title: "[Cancelled Review]", content: promptMarker)
        )
        let chatPreset = ChatPreset(
            name: "Cancelled Review",
            mode: .review,
            fileTreeMode: .auto,
            codeMapUsage: .auto,
            gitInclusion: GitInclusion.none,
            storedPromptIds: [promptID],
            useStoredPromptsAsSystem: true
        )
        let modelPreset = try ModelPreset(
            name: "Cancelled Oracle",
            model: .gpt54Mini,
            chatPresetMappings: ChatPresetMappings(reviewPresetID: chatPreset.id)
        )
        let profile = AgentModelsSettingsProfile(planningModelRaw: AIModel.gpt54.rawValue)
        let startSnapshot = snapshot(
            profile: profile,
            modelPresets: [modelPreset],
            chatPreset: chatPreset,
            exposed: true
        )
        var reloadTask: Task<Void, Never>?
        let reloadFence = TestReleaseFence(name: "identified chat snapshot publication")
        var expectedReloadGeneration: UInt64?
        var pausedReloadGeneration: UInt64?
        var unrelatedReloadGeneration: UInt64?
        var admittedSessionID: UUID?
        var settleRequest: (() async -> Void)?
        try await AsyncScope.withCleanup({}, cleanup: {
            composition.oracleViewModel.workspaceChatSessionLoadBeforePublicationForTesting = nil
            reloadFence.release()
            await reloadTask?.value
            await settleRequest?()
            await composition.oracleViewModel.drainTrackedAutosaves(for: workspace.id)
        }) {
            if pauseReload {
                // Finish initial hydration, then hold a fresh same-workspace snapshot before publication.
                await composition.oracleViewModel.loadSessionsFromWorkspace()
                let reloadPaused = expectation(description: "Empty chat snapshot ready for publication")
                composition.oracleViewModel.workspaceChatSessionLoadBeforePublicationForTesting = { workspaceID, generation in
                    guard workspaceID == workspace.id else { return }
                    guard generation == expectedReloadGeneration else {
                        unrelatedReloadGeneration = generation
                        return
                    }
                    pausedReloadGeneration = generation
                    reloadPaused.fulfill()
                    await reloadFence.enterAndWait()
                }
                // A different reload of the same workspace must finish without entering the hold.
                await composition.oracleViewModel.loadSessionsFromWorkspace()
                let unrelatedGeneration = try XCTUnwrap(unrelatedReloadGeneration)
                XCTAssertNil(pausedReloadGeneration)
                reloadTask = Task { @MainActor in
                    expectedReloadGeneration = composition.oracleViewModel.workspaceChatSessionLoadGenerationForTesting + 1
                    await composition.oracleViewModel.loadSessionsFromWorkspace()
                }
                await fulfillment(of: [reloadPaused], timeout: 5)
                let pausedGeneration = try XCTUnwrap(pausedReloadGeneration)
                XCTAssertEqual(pausedGeneration, expectedReloadGeneration)
                XCTAssertNotEqual(pausedGeneration, unrelatedGeneration)
            }

            var capturedMessages: [AIMessage] = []
            var capturedModels: [AIModel] = []
            var heldContinuation: AsyncThrowingStream<ChatStreamOutput, Error>.Continuation?
            composition.oracleViewModel.setOraclePostPackagingTransportOverrideForTesting { message, model in
                capturedMessages.append(message)
                capturedModels.append(model)
                admittedSessionID = composition.oracleViewModel.sessions.first {
                    $0.selectedChatPresetID == chatPreset.id && $0.workspaceID == workspace.id && $0.composeTabID == tab.id
                }?.id
                let stream = AsyncThrowingStream<ChatStreamOutput, Error> { continuation in
                    switch cancellationKind {
                    case .explicit:
                        heldContinuation = continuation
                    case .transport:
                        continuation.finish(throwing: CancellationError())
                    }
                }
                return (UUID(), stream)
            }

            let request = Task { @MainActor in
                try await composition.oracleViewModel.tool_chatSendWithConfiguredRoster(
                    args: [
                        "message": .string("Cancel before response"),
                        "mode": .string("review"),
                        "model": .string(modelPreset.name),
                        "new_chat": .bool(true)
                    ],
                    promptVM: composition.promptManager,
                    tabContext: makeTabContext(workspaceID: workspace.id, tabID: tab.id),
                    capturedProfile: profile,
                    selectionSnapshotOverride: startSnapshot
                )
            }

            settleRequest = {
                heldContinuation?.finish(throwing: CancellationError())
                request.cancel()
                _ = await request.result
            }

            if cancellationKind == .explicit {
                try await AsyncTestWait.waitUntil("Oracle explicit-cancel stream start") {
                    heldContinuation != nil && composition.oracleViewModel.sessions.contains {
                        $0.selectedChatPresetID == chatPreset.id
                    }
                }
                let session = try XCTUnwrap(
                    composition.oracleViewModel.sessions.first(where: { $0.selectedChatPresetID == chatPreset.id })
                )
                if reloadWhileStreaming {
                    let queryID = try XCTUnwrap(composition.oracleViewModel.activeQueryId(for: session.id))
                    let messageIDs = composition.oracleViewModel.messagesSnapshot(for: session.id).map(\.id)
                    XCTAssertFalse(messageIDs.isEmpty)
                    XCTAssertTrue(composition.oracleViewModel.isSessionPinnedForTesting(session.id))
                    composition.oracleViewModel.workspaceChatSessionLoadBeforePublicationForTesting = nil
                    reloadFence.release()
                    await reloadTask?.value
                    XCTAssertTrue(composition.oracleViewModel.isSessionStreaming(session.id))
                    XCTAssertTrue(composition.oracleViewModel.isSessionPinnedForTesting(session.id))
                    XCTAssertEqual(composition.oracleViewModel.activeQueryId(for: session.id), queryID)
                    XCTAssertEqual(composition.oracleViewModel.messagesSnapshot(for: session.id).map(\.id), messageIDs)
                }
                await composition.oracleViewModel.cancelAIResponse(in: session.id, skipPartialParseAndSave: false)
                heldContinuation?.finish(throwing: CancellationError())
            }

            do {
                _ = try await request.value
                XCTFail("Expected cancellation")
            } catch is CancellationError {
            } catch let error as ChatToolError {
                XCTAssertTrue(error.message.localizedCaseInsensitiveContains("cancel"), error.message)
            }

            await composition.oracleViewModel.drainTrackedAutosaves(for: workspace.id)
            if pauseReload {
                let admittedID = try XCTUnwrap(admittedSessionID)
                let beforeReload = try XCTUnwrap(composition.oracleViewModel.sessions.first { $0.id == admittedID })
                XCTAssertEqual(capturedMessages.count, 1)
                XCTAssertEqual(beforeReload.workspaceID, workspace.id)
                XCTAssertEqual(beforeReload.composeTabID, tab.id)
                XCTAssertEqual(beforeReload.messages.filter(\.isUser).map(\.rawText), ["Cancel before response"])
                XCTAssertEqual(beforeReload.oracleExecutionAuthority, .frozen)
                XCTAssertEqual(beforeReload.preferredAIModel, AIModel.gpt54Mini.rawValue)
                XCTAssertEqual(beforeReload.selectedChatPresetID, chatPreset.id)
                let beforeReloadURL = try XCTUnwrap(beforeReload.fileURL)
                let savedBeforeReload = try await composition.oracleViewModel.chatData.loadChatSession(from: beforeReloadURL)
                XCTAssertEqual(savedBeforeReload.id, admittedID)
                XCTAssertEqual(savedBeforeReload.oracleExecutionAuthority, .frozen)
                XCTAssertEqual(savedBeforeReload.selectedChatPresetID, chatPreset.id)
                composition.oracleViewModel.workspaceChatSessionLoadBeforePublicationForTesting = nil
                reloadFence.release()
                await reloadTask?.value
                let afterReload = composition.oracleViewModel.sessions.first { $0.id == admittedID }
                XCTAssertEqual(afterReload?.oracleExecutionAuthority, .frozen)
                XCTAssertEqual(afterReload?.preferredAIModel, AIModel.gpt54Mini.rawValue)
                XCTAssertEqual(afterReload?.selectedChatPresetID, chatPreset.id)
            }
            let cancelledSession = try XCTUnwrap(
                composition.oracleViewModel.sessions.first(where: { $0.selectedChatPresetID == chatPreset.id })
            )
            let savedURL = try XCTUnwrap(cancelledSession.fileURL)
            let persisted = try await composition.oracleViewModel.chatData.loadChatSession(from: savedURL)
            XCTAssertFalse(persisted.messages.contains { !$0.isUser && $0.rawText.isEmpty })
            XCTAssertEqual(persisted.preferredAIModel, AIModel.gpt54Mini.rawValue)
            XCTAssertEqual(persisted.selectedChatPresetID, chatPreset.id)

            composition.oracleViewModel.setOraclePostPackagingTransportOverrideForTesting { message, model in
                capturedMessages.append(message)
                capturedModels.append(model)
                let stream = AsyncThrowingStream<ChatStreamOutput, Error> { continuation in
                    continuation.yield(
                        ChatStreamOutput(text: "continued", reasoning: nil, tokens: ChatTokenInfo(), terminalOutcome: .completed)
                    )
                    continuation.finish()
                }
                return (UUID(), stream)
            }
            let continuationSnapshot = snapshot(
                profile: AgentModelsSettingsProfile(planningModelRaw: AIModel.gpt54.rawValue),
                modelPresets: [],
                chatPreset: chatPreset,
                exposed: false
            )
            _ = try await composition.oracleViewModel.tool_chatSendWithConfiguredRoster(
                args: [
                    "message": .string("Continue after cancellation"),
                    "mode": .string("review"),
                    "chat_id": .string(cancelledSession.shortID)
                ],
                promptVM: composition.promptManager,
                tabContext: makeTabContext(workspaceID: workspace.id, tabID: tab.id),
                capturedProfile: continuationSnapshot.agentModelsProfile,
                selectionSnapshotOverride: continuationSnapshot
            )

            XCTAssertEqual(capturedModels, [.gpt54Mini, .gpt54Mini])
            XCTAssertEqual(capturedMessages.count, 2)
            XCTAssertTrue(capturedMessages.allSatisfy { $0.systemPrompt.contains(promptMarker) })
        }
    }

    func testCatalogReloadMergesDiskHistoryWithoutReplacingLiveAuthorityAndExplicitReloadRefreshes() async throws {
        try await withCatalogFixture { composition, workspace, tab in
            let oracle = composition.oracleViewModel
            var live = ChatSession(
                workspaceID: workspace.id,
                composeTabID: tab.id,
                name: "Live",
                messages: [StoredMessage(isUser: true, rawText: "Live turn", sequenceIndex: 0)]
            )
            live.oracleExecutionAuthority = .frozen
            live.fileURL = try await oracle.chatData.saveChatSession(live, for: workspace)
            oracle.sessions.append(live)
            var diskVersion = live
            diskVersion.name = "Updated on disk"
            diskVersion.messages = [StoredMessage(isUser: true, rawText: "Disk turn", sequenceIndex: 0)]
            _ = try await oracle.chatData.saveChatSession(diskVersion, for: workspace)
            let history = ChatSession(workspaceID: workspace.id, composeTabID: tab.id, name: "Disk history")
            _ = try await oracle.chatData.saveChatSession(history, for: workspace)
            await oracle.loadSessionsFromWorkspace()
            let retained = try XCTUnwrap(oracle.sessions.first { $0.id == live.id })
            XCTAssertEqual(retained.name, "Live")
            XCTAssertEqual(retained.messages.map(\.rawText), ["Live turn"])
            XCTAssertEqual(retained.oracleExecutionAuthority, .frozen)
            XCTAssertTrue(oracle.sessions.contains { $0.id == history.id && $0.name == "Disk history" })
            try await oracle.loadChatSession(from: XCTUnwrap(live.fileURL))
            let refreshed = try XCTUnwrap(oracle.sessions.first { $0.id == live.id })
            XCTAssertEqual(refreshed.name, "Updated on disk")
            XCTAssertEqual(refreshed.messages.map(\.rawText), ["Disk turn"])
        }
    }

    func testDeletedSessionsCannotBeResurrectedByInFlightCatalogReload() async throws {
        // Equivalent logical deletions include legacy headers without workspace metadata.
        for deletion in ["baseline", "legacy", "added", "all"] {
            try await withCatalogFixture { composition, workspace, tab in
                let oracle = composition.oracleViewModel
                var victim = ChatSession(workspaceID: deletion == "legacy" ? nil : workspace.id, composeTabID: tab.id, name: deletion)
                victim.fileURL = try await oracle.chatData.saveChatSession(victim, for: workspace)
                if deletion == "baseline" || deletion == "legacy" { oracle.sessions.append(victim) }
                try await withPausedCatalogReload(oracle, workspace: workspace) {
                    if deletion == "added" { oracle.sessions.append(victim) }
                    if deletion == "all" {
                        await oracle.clearAllChats()
                    } else {
                        await oracle.deleteSession(victim)
                    }
                }
                XCTAssertFalse(oracle.sessions.contains { $0.id == victim.id }, deletion)
                XCTAssertFalse(try FileManager.default.fileExists(atPath: XCTUnwrap(victim.fileURL).path), deletion)
            }
        }
    }

    func testDeletedOracleGroupCannotBeResurrectedByInFlightCatalogReload() async throws {
        for replaceRootDuringCleanup in [false, true] {
            try await withCatalogFixture { composition, workspace, tab in
                let oracle = composition.oracleViewModel
                let owner = try OracleViewModel.oracleGroupOwner(workspaceID: workspace.id, tabID: tab.id)
                let models = try ["model-a", "model-b"].map { try OracleModelReference(modelID: $0) }
                let descriptor = try OracleGroupDescriptor(size: 2)
                let members = try models.enumerated().map { index, model in
                    let id = UUID()
                    return try OracleGroupMember(
                        laneID: OracleLaneID(index: index),
                        memberID: OracleMemberID(rawValue: id),
                        publicChatID: ChatSession.makeShortID(name: "Group", uuid: id),
                        model: model
                    )
                }
                let timestamp = Date(timeIntervalSince1970: 1000)
                let group = try OracleGroupDocument(
                    group: descriptor,
                    owner: owner,
                    name: "Group",
                    revision: 1,
                    createdAt: timestamp,
                    updatedAt: timestamp,
                    roster: OracleRoster(primary: models[0], additional: [models[1]]),
                    members: members,
                    turns: [OracleTurnRecord(
                        input: OracleInput(mode: .chat, userMessage: "Group history"),
                        state: .prepared,
                        startedAt: timestamp
                    )]
                )
                let store = AppDomainRuntimeComposition.shared.oracleConversationStore
                do {
                    try await store.create(group)
                } catch {
                    XCTFail("Creating the canonical deletion fixture failed: \(error)")
                    throw error
                }
                addTeardownBlock {
                    if let retained = try await store.load(groupID: descriptor.id, owner: owner) {
                        try await store.delete(groupID: descriptor.id, owner: owner, expectedRevision: retained.revision)
                    }
                }
                var projections: [ChatSession] = []
                for member in members {
                    var projection = ChatSession(
                        id: member.memberID.rawValue,
                        workspaceID: workspace.id,
                        composeTabID: tab.id,
                        oracleGroupID: descriptor.id.rawValue,
                        oracleLaneIndex: member.laneID.index,
                        oracleGroupSize: 2,
                        oracleModelRaw: member.model.modelID,
                        name: "Group",
                        shortID: member.publicChatID
                    )
                    projection.fileURL = try await oracle.chatData.saveChatSession(projection, for: workspace)
                    projections.append(projection)
                }
                oracle.sessions.append(contentsOf: projections)
                let victim = try XCTUnwrap(projections.first)
                if replaceRootDuringCleanup {
                    let paused = expectation(description: "Old group committed before projection cleanup")
                    let fence = TestReleaseFence(name: "Group root successor cleanup")
                    var observedID: UUID?
                    oracle.workspaceChatSessionDeletionBeforeCommitForTesting = { sessionID in
                        guard sessionID == victim.id else { return }
                        observedID = sessionID
                        paused.fulfill()
                        await fence.enterAndWait()
                    }
                    let deletionTask = Task { @MainActor in await oracle.deleteSession(victim) }
                    try await AsyncScope.withCleanup({}, cleanup: {
                        oracle.workspaceChatSessionDeletionBeforeCommitForTesting = nil
                        fence.release()
                        await deletionTask.value
                    }) {
                        await fulfillment(of: [paused], timeout: 5)
                        XCTAssertEqual(try XCTUnwrap(observedID), victim.id)
                        let deleted = try await store.load(groupID: descriptor.id, owner: owner)
                        XCTAssertNil(deleted)
                        var successor = workspace
                        successor.customStoragePath = try XCTUnwrap(workspace.customStoragePath).appendingPathComponent("Group successor")
                        var successorURLs: [URL] = []
                        for var projection in projections {
                            projection.name = "Successor group copy"
                            try await successorURLs.append(oracle.chatData.saveChatSession(projection, for: successor))
                        }
                        // Same public/group IDs, but a new committed incarnation must survive old cleanup.
                        try await store.create(group)
                        let index = try XCTUnwrap(composition.workspaceManager.workspaces.firstIndex { $0.id == workspace.id })
                        composition.workspaceManager.workspaces[index] = successor
                        composition.workspaceManager.activeWorkspace = successor
                        composition.promptManager.loadComposeTabsFromWorkspace(successor)
                        await oracle.loadSessionsFromWorkspace()
                        let before = Set(oracle.sessions.filter { $0.oracleGroupID == descriptor.id.rawValue }.map(\.id))
                        XCTAssertEqual(before, Set(members.map(\.memberID.rawValue)))
                        oracle.workspaceChatSessionDeletionBeforeCommitForTesting = nil
                        fence.release()
                        await deletionTask.value
                        XCTAssertTrue(oracle.sessionOperationError?.contains("workspace storage changed") == true)
                        let retained = Set(oracle.sessions.filter { $0.oracleGroupID == descriptor.id.rawValue }.map(\.id))
                        XCTAssertEqual(retained, before)
                        for url in successorURLs {
                            let saved = try await oracle.chatData.loadChatSession(from: url)
                            XCTAssertEqual(saved.name, "Successor group copy")
                        }
                        let recreated = try await store.load(groupID: descriptor.id, owner: owner)
                        XCTAssertEqual(recreated, group)
                    }
                } else {
                    try await withPausedCatalogReload(oracle, workspace: workspace) { await oracle.deleteSession(victim) }
                    XCTAssertNil(oracle.sessionOperationError)
                    let memberIDs = Set(members.map(\.memberID.rawValue))
                    XCTAssertTrue(memberIDs.isDisjoint(with: oracle.sessions.map(\.id)))
                    let retained = try await store.load(groupID: descriptor.id, owner: owner)
                    XCTAssertNil(retained)
                }
            }
        }
    }

    func testDelayedWorkspaceAndStorageCallbacksCannotClearNewCatalog() async throws {
        try await withCatalogFixture { composition, workspace, tab in
            let oracle = composition.oracleViewModel
            let root = try XCTUnwrap(workspace.customStoragePath)
            var nextWorkspace = WorkspaceModel(name: "Next", repoPaths: [], customStoragePath: root.appendingPathComponent("Next"))
            nextWorkspace.composeTabs = [tab]
            nextWorkspace.activeComposeTabID = tab.id
            composition.workspaceManager.workspaces.append(nextWorkspace)
            try await withPausedCatalogReload(oracle, workspace: workspace) {
                composition.workspaceManager.activeWorkspace = nextWorkspace
                composition.promptManager.loadComposeTabsFromWorkspace(nextWorkspace)
                await oracle.loadSessionsFromWorkspace()
                let activeID = try XCTUnwrap(oracle.currentSessionID)
                await oracle.loadSessionsFromWorkspaceForTesting(workspace)
                await oracle.loadSessionsFromWorkspaceForTesting(nil)
                XCTAssertEqual(oracle.currentSessionID, activeID)
                XCTAssertTrue(oracle.sessions.contains { $0.id == activeID && $0.workspaceID == nextWorkspace.id })
            }
            XCTAssertTrue(oracle.sessions.allSatisfy { $0.workspaceID == nextWorkspace.id })
            var newStorage = nextWorkspace
            newStorage.customStoragePath = root.appendingPathComponent("Moved")
            composition.workspaceManager.activeWorkspace = newStorage
            await oracle.loadSessionsFromWorkspace()
            let activeID = try XCTUnwrap(oracle.currentSessionID)
            await oracle.loadSessionsFromWorkspaceForTesting(nextWorkspace)
            XCTAssertEqual(oracle.currentSessionID, activeID)
        }
    }

    func testOldDeletionCannotInvalidateSuccessorWorkspaceOrStorageReload() async throws {
        for sameWorkspaceNewRoot in [false, true] {
            try await withCatalogFixture { composition, workspace, tab in
                let oracle = composition.oracleViewModel
                var victim = ChatSession(workspaceID: workspace.id, composeTabID: tab.id, name: "Old owner")
                victim.fileURL = try await oracle.chatData.saveChatSession(victim, for: workspace)
                oracle.sessions.append(victim)
                let root = try XCTUnwrap(workspace.customStoragePath).appendingPathComponent("Successor")
                var successor = sameWorkspaceNewRoot ? workspace : WorkspaceModel(name: "Successor", repoPaths: [])
                successor.customStoragePath = root
                successor.composeTabs = [tab]
                successor.activeComposeTabID = tab.id
                let history = ChatSession(workspaceID: successor.id, composeTabID: tab.id, name: "Successor history")
                _ = try await oracle.chatData.saveChatSession(history, for: successor)
                let deletionPaused = expectation(description: "Exact old-owner deletion ready")
                let deletionFence = TestReleaseFence(name: "Old owner deletion commit")
                var observedDeletionID: UUID?
                oracle.workspaceChatSessionDeletionBeforeCommitForTesting = { sessionID in
                    guard sessionID == victim.id else { return }
                    observedDeletionID = sessionID
                    deletionPaused.fulfill()
                    await deletionFence.enterAndWait()
                }
                let deletionTask = Task { @MainActor in await oracle.deleteSession(victim) }
                try await AsyncScope.withCleanup({}, cleanup: {
                    oracle.workspaceChatSessionDeletionBeforeCommitForTesting = nil
                    deletionFence.release()
                    await deletionTask.value
                }) {
                    await fulfillment(of: [deletionPaused], timeout: 5)
                    XCTAssertEqual(try XCTUnwrap(observedDeletionID), victim.id)
                    if let index = composition.workspaceManager.workspaces.firstIndex(where: { $0.id == successor.id }) {
                        composition.workspaceManager.workspaces[index] = successor
                    } else {
                        composition.workspaceManager.workspaces.append(successor)
                    }
                    composition.workspaceManager.activeWorkspace = successor
                    composition.promptManager.loadComposeTabsFromWorkspace(successor)
                    // Establish the successor owner before its identified restore begins.
                    oracle.prepareChatSessionCatalog(for: successor)
                    try await withPausedCatalogReload(oracle, workspace: successor) {
                        let generation = oracle.workspaceChatSessionLoadGenerationForTesting
                        oracle.workspaceChatSessionDeletionBeforeCommitForTesting = nil
                        deletionFence.release()
                        await deletionTask.value
                        XCTAssertEqual(oracle.workspaceChatSessionLoadGenerationForTesting, generation)
                    }
                    XCTAssertTrue(oracle.sessions.contains { $0.id == history.id && $0.name == "Successor history" })
                    XCTAssertFalse(oracle.sessions.contains { $0.id == victim.id })
                }
            }
        }
    }

    func testOldDeletionCannotRemovePublishedSuccessorWithSameSessionID() async throws {
        try await withCatalogFixture { composition, workspace, tab in
            let oracle = composition.oracleViewModel
            var victim = ChatSession(workspaceID: workspace.id, composeTabID: tab.id, name: "Old owner")
            victim.fileURL = try await oracle.chatData.saveChatSession(victim, for: workspace)
            oracle.sessions.append(victim)
            var successor = workspace
            successor.customStoragePath = try XCTUnwrap(workspace.customStoragePath).appendingPathComponent("Successor")
            var replacement = victim
            replacement.name = "Successor copy"
            replacement.messages = [StoredMessage(isUser: true, rawText: "Successor turn", sequenceIndex: 0)]
            let replacementURL = try await oracle.chatData.saveChatSession(replacement, for: successor)
            let deletionPaused = expectation(description: "Exact old-owner deletion ready")
            let fence = TestReleaseFence(name: "Old root deletion cleanup")
            var observedDeletionID: UUID?
            oracle.workspaceChatSessionDeletionBeforeCommitForTesting = { sessionID in
                guard sessionID == victim.id else { return }
                observedDeletionID = sessionID
                deletionPaused.fulfill()
                await fence.enterAndWait()
            }
            let deletionTask = Task { @MainActor in await oracle.deleteSession(victim) }
            try await AsyncScope.withCleanup({}, cleanup: {
                oracle.workspaceChatSessionDeletionBeforeCommitForTesting = nil
                fence.release()
                await deletionTask.value
            }) {
                await fulfillment(of: [deletionPaused], timeout: 5)
                XCTAssertEqual(try XCTUnwrap(observedDeletionID), victim.id)
                let index = try XCTUnwrap(composition.workspaceManager.workspaces.firstIndex { $0.id == workspace.id })
                composition.workspaceManager.workspaces[index] = successor
                composition.workspaceManager.activeWorkspace = successor
                composition.promptManager.loadComposeTabsFromWorkspace(successor)
                await oracle.loadSessionsFromWorkspace()
                await oracle.loadChatSession(from: replacementURL)
                let before = try XCTUnwrap(oracle.sessions.first { $0.id == victim.id })
                XCTAssertEqual(before.name, "Successor copy")
                XCTAssertEqual(before.fileURL, replacementURL)
                let messageIDs = oracle.messagesSnapshot(for: victim.id).map(\.id)
                XCTAssertFalse(messageIDs.isEmpty)
                oracle.workspaceChatSessionDeletionBeforeCommitForTesting = nil
                fence.release()
                await deletionTask.value
                let retained = oracle.sessions.first { $0.id == victim.id }
                XCTAssertEqual(retained?.name, "Successor copy")
                XCTAssertEqual(retained?.fileURL, replacementURL)
                XCTAssertEqual(oracle.messagesSnapshot(for: victim.id).map(\.id), messageIDs)
                let saved = try await oracle.chatData.loadChatSession(from: replacementURL)
                XCTAssertEqual(saved.messages.map(\.rawText), ["Successor turn"])
            }
        }
    }

    func testOldGroupCancellationCannotClearHeldSuccessorQueriesWithSameSessionIDs() async throws {
        try await withCatalogFixture { composition, workspace, tab in
            let oracle = composition.oracleViewModel
            composition.apiSettingsViewModel.openAIApiKey = "test-key"
            composition.apiSettingsViewModel.isOpenAIKeyValid = true
            let owner = try OracleViewModel.oracleGroupOwner(workspaceID: workspace.id, tabID: tab.id)
            let model = try OracleModelReference(modelID: AIModel.gpt54.rawValue)
            let descriptor = try OracleGroupDescriptor(size: 2)
            let members = try (0 ..< 2).map { index in
                let id = UUID()
                return try OracleGroupMember(
                    laneID: OracleLaneID(index: index),
                    memberID: OracleMemberID(rawValue: id),
                    publicChatID: ChatSession.makeShortID(name: "Held", uuid: id),
                    model: model
                )
            }
            let timestamp = Date(timeIntervalSince1970: 1000)
            let group = try OracleGroupDocument(
                group: descriptor,
                owner: owner,
                name: "Held",
                revision: 1,
                createdAt: timestamp,
                updatedAt: timestamp,
                roster: OracleRoster(primary: model, additional: [model]),
                members: members,
                turns: [OracleTurnRecord(
                    input: OracleInput(mode: .chat, userMessage: "Held lanes"),
                    state: .prepared,
                    startedAt: timestamp
                )]
            )
            let store = AppDomainRuntimeComposition.shared.oracleConversationStore
            try await store.create(group)
            addTeardownBlock {
                if let retained = try await store.load(groupID: descriptor.id, owner: owner) {
                    try await store.delete(groupID: descriptor.id, owner: owner, expectedRevision: retained.revision)
                }
            }
            var projections: [ChatSession] = []
            for member in members {
                var projection = ChatSession(
                    id: member.memberID.rawValue,
                    workspaceID: workspace.id,
                    composeTabID: tab.id,
                    oracleGroupID: descriptor.id.rawValue,
                    oracleLaneIndex: member.laneID.index,
                    oracleGroupSize: 2,
                    oracleModelRaw: model.modelID,
                    name: "Held",
                    shortID: member.publicChatID
                )
                projection.fileURL = try await oracle.chatData.saveChatSession(projection, for: workspace)
                projections.append(projection)
            }
            oracle.sessions.append(contentsOf: projections)
            var streamStarted = expectation(description: "Two old held streams admitted")
            streamStarted.expectedFulfillmentCount = 2
            var startedCount = 0
            var finishingStreams = false
            var continuations: [AsyncThrowingStream<ChatStreamOutput, Error>.Continuation] = []
            var waiters: [Task<String, Error>] = []
            let fence = TestReleaseFence(name: "Old cancellation runtime cleanup")
            var deletionTask: Task<Void, Never>?
            oracle.setOraclePostPackagingTransportOverrideForTesting { _, _ in
                let stream = AsyncThrowingStream<ChatStreamOutput, Error> { continuation in
                    continuations.append(continuation)
                    if finishingStreams {
                        continuation.yield(ChatStreamOutput(text: "fixture cleanup", reasoning: nil, tokens: ChatTokenInfo(), terminalOutcome: .completed))
                        continuation.finish()
                    }
                }
                startedCount += 1
                streamStarted.fulfill()
                return (UUID(), stream)
            }
            try await AsyncScope.withCleanup({}, cleanup: {
                finishingStreams = true
                for continuation in continuations {
                    continuation.yield(ChatStreamOutput(text: "fixture cleanup", reasoning: nil, tokens: ChatTokenInfo(), terminalOutcome: .completed))
                    continuation.finish()
                }
                for waiter in waiters {
                    if case let .failure(error) = await waiter.result { XCTFail("Owned stream settlement failed: \(error)") }
                }
                oracle.workspaceChatSessionCancellationBeforeCleanupForTesting = nil
                fence.release()
                await deletionTask?.value
                oracle.setOraclePostPackagingTransportOverrideForTesting(nil)
                for projection in projections {
                    oracle.unpinSession(projection.id)
                }
            }) {
                var oldQueries: [UUID] = []
                for projection in projections {
                    let admittedQuery = await oracle.sendMessage("Old lane", sessionID: projection.id, overrideModel: .gpt54)
                    let query = try XCTUnwrap(admittedQuery)
                    oldQueries.append(query)
                    waiters.append(Task { try await oracle.waitForContextBuilderCompletion(query) })
                }
                await fulfillment(of: [streamStarted], timeout: 5)
                _ = try XCTUnwrap(startedCount == 2 ? oldQueries : nil)
                let cancellationPaused = expectation(description: "Exact old query cancellation before runtime cleanup")
                var observedQuery: UUID?
                let firstSessionID = projections[0].id
                let firstQueryID = oldQueries[0]
                oracle.workspaceChatSessionCancellationBeforeCleanupForTesting = { sessionID, queryID in
                    guard sessionID == firstSessionID, queryID == firstQueryID else { return }
                    observedQuery = queryID
                    cancellationPaused.fulfill()
                    await fence.enterAndWait()
                }
                let victim = try XCTUnwrap(projections.first)
                deletionTask = Task { @MainActor in await oracle.deleteSession(victim) }
                await fulfillment(of: [cancellationPaused], timeout: 5)
                XCTAssertEqual(try XCTUnwrap(observedQuery), oldQueries[0])
                // Let the old providers settle while cancellation is still held; join saves before moving roots.
                for continuation in continuations {
                    continuation.yield(ChatStreamOutput(text: "old completed", reasoning: nil, tokens: ChatTokenInfo(), terminalOutcome: .completed))
                    continuation.finish()
                }
                for waiter in waiters {
                    let outcome = try await waiter.value
                    XCTAssertEqual(outcome, "old completed")
                }
                await oracle.drainTrackedAutosaves(for: workspace.id)
                var successor = workspace
                successor.customStoragePath = try XCTUnwrap(workspace.customStoragePath).appendingPathComponent("Held successor")
                for projection in projections {
                    _ = try await oracle.chatData.saveChatSession(projection, for: successor)
                }
                let index = try XCTUnwrap(composition.workspaceManager.workspaces.firstIndex { $0.id == workspace.id })
                composition.workspaceManager.workspaces[index] = successor
                composition.workspaceManager.activeWorkspace = successor
                composition.promptManager.loadComposeTabsFromWorkspace(successor)
                await oracle.loadSessionsFromWorkspace()
                streamStarted = expectation(description: "Two same-ID successor streams admitted")
                streamStarted.expectedFulfillmentCount = 2
                var successorQueries: [UUID] = []
                for projection in projections {
                    oracle.pinSession(projection.id)
                    let admittedQuery = await oracle.sendMessage("Successor lane", sessionID: projection.id, overrideModel: .gpt54)
                    let query = try XCTUnwrap(admittedQuery)
                    successorQueries.append(query)
                    waiters.append(Task { try await oracle.waitForContextBuilderCompletion(query) })
                }
                await fulfillment(of: [streamStarted], timeout: 5)
                _ = try XCTUnwrap(startedCount == 4 ? successorQueries : nil)
                XCTAssertTrue(Set(oldQueries).isDisjoint(with: successorQueries))
                let messageIDs = projections.map { oracle.messagesSnapshot(for: $0.id).map(\.id) }
                XCTAssertTrue(messageIDs.allSatisfy { !$0.isEmpty })
                oracle.workspaceChatSessionCancellationBeforeCleanupForTesting = nil
                fence.release()
                await deletionTask?.value
                XCTAssertTrue(oracle.sessionOperationError?.contains("Workspace storage changed") == true)
                for (index, projection) in projections.enumerated() {
                    XCTAssertEqual(oracle.activeQueryId(for: projection.id), successorQueries[index])
                    XCTAssertTrue(oracle.isSessionStreaming(projection.id))
                    XCTAssertTrue(oracle.isSessionPinnedForTesting(projection.id))
                    XCTAssertEqual(oracle.messagesSnapshot(for: projection.id).map(\.id), messageIDs[index])
                }
                let retained = try await store.load(groupID: descriptor.id, owner: owner)
                XCTAssertEqual(retained, group)
            }
        }
    }

    func testRetainedCurrentCatalogReloadDoesNotSkipNextSwitchAutosave() async throws {
        try await withCatalogFixture { composition, workspace, tab in
            let oracle = composition.oracleViewModel
            var session = ChatSession(
                workspaceID: workspace.id,
                composeTabID: tab.id,
                name: "Unsaved current",
                messages: [StoredMessage(isUser: true, rawText: "Original", sequenceIndex: 0)]
            )
            session.fileURL = try await oracle.chatData.saveChatSession(session, for: workspace)
            try await oracle.loadChatSession(from: XCTUnwrap(session.fileURL))
            composition.workspaceManager.setActiveChatSessionID(session.id, forTabID: tab.id)
            await oracle.loadSessionsFromWorkspace()
            XCTAssertEqual(oracle.currentSessionID, session.id)
            let messageID = try XCTUnwrap(oracle.messagesSnapshot(for: session.id).first?.id)
            oracle.updateMessage(withId: messageID) { $0.updateContent("Unsaved edit") }
            XCTAssertEqual(oracle.messagesSnapshot(for: session.id).map(\.content), ["Unsaved edit"])
            let beforeSwitch = try await oracle.chatData.loadChatSession(from: XCTUnwrap(session.fileURL))
            XCTAssertEqual(beforeSwitch.messages.map(\.rawText), ["Original"])
            let other = ChatSession(workspaceID: workspace.id, composeTabID: tab.id, name: "Other")
            oracle.sessions.append(other)
            await oracle.switchToSession(other.id)
            await oracle.drainTrackedAutosaves(for: workspace.id)
            let persisted = try await oracle.chatData.loadChatSession(from: XCTUnwrap(session.fileURL))
            XCTAssertEqual(persisted.messages.filter(\.isUser).map(\.rawText), ["Unsaved edit"])
        }
    }

    private func withCatalogFixture(
        _ body: (WindowStateComposition, WorkspaceModel, ComposeTabState) async throws -> Void
    ) async throws {
        let composition = WindowStateCompositionFactory.make(
            windowID: -9342,
            deferredInitialAgentSystemWorkspaceRefresh: true,
            sharedMCPService: MCPService()
        )
        await composition.workspaceManager.awaitInitialized()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OracleCatalog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let workspaceToConfigure = try XCTUnwrap(composition.workspaceManager.activeWorkspace)
        try await AsyncScope.withCleanup({}, cleanup: {
            for workspace in composition.workspaceManager.workspaces {
                await composition.oracleViewModel.drainTrackedAutosaves(for: workspace.id)
            }
            composition.workspaceManager.prepareForWindowClose()
            composition.oracleViewModel.sessions = []
            try? FileManager.default.removeItem(at: root)
        }) {
            var workspace = workspaceToConfigure
            let tab = ComposeTabState(id: UUID())
            workspace.customStoragePath = root
            workspace.composeTabs = [tab]
            workspace.activeComposeTabID = tab.id
            if let index = composition.workspaceManager.workspaces.firstIndex(where: { $0.id == workspace.id }) {
                composition.workspaceManager.workspaces[index] = workspace
            }
            composition.workspaceManager.activeWorkspace = workspace
            composition.promptManager.loadComposeTabsFromWorkspace(workspace)
            await composition.oracleViewModel.loadSessionsFromWorkspace()
            try await body(composition, workspace, tab)
        }
    }

    private func withPausedCatalogReload(
        _ oracle: OracleViewModel,
        workspace: WorkspaceModel,
        _ body: () async throws -> Void
    ) async throws {
        let paused = expectation(description: "Identified catalog snapshot ready")
        let fence = TestReleaseFence(name: "Catalog control publication")
        var expectedGeneration: UInt64?
        var observedGeneration: UInt64?
        oracle.workspaceChatSessionLoadBeforePublicationForTesting = { workspaceID, generation in
            guard workspaceID == workspace.id, generation == expectedGeneration else { return }
            observedGeneration = generation
            paused.fulfill()
            await fence.enterAndWait()
        }
        let task = Task { @MainActor in
            expectedGeneration = oracle.workspaceChatSessionLoadGenerationForTesting + 1
            await oracle.loadSessionsFromWorkspace()
        }
        try await AsyncScope.withCleanup({}, cleanup: {
            oracle.workspaceChatSessionLoadBeforePublicationForTesting = nil
            fence.release()
            await task.value
        }) {
            await fulfillment(of: [paused], timeout: 5)
            XCTAssertEqual(try XCTUnwrap(observedGeneration), expectedGeneration)
            try await body()
        }
    }

    private func snapshot(
        profile: AgentModelsSettingsProfile,
        modelPresets: [ModelPreset],
        chatPreset: ChatPreset,
        exposed: Bool
    ) -> OracleSelectionSnapshot {
        OracleSelectionSnapshot(
            origin: .mcp,
            agentModelsProfile: profile,
            modelPresets: modelPresets,
            modelPresetsExposed: exposed,
            modelPresetsTemporarilyDisabled: false,
            chatPresets: ChatPreset.BuiltIn.all() + [chatPreset],
            defaultChatPresets: [
                .chat: ChatPreset.BuiltIn.chat,
                .plan: ChatPreset.BuiltIn.plan,
                .review: ChatPreset.BuiltIn.review
            ]
        )
    }

    private func makeTabContext(workspaceID: UUID, tabID: UUID) -> OracleViewModel.OracleSendTabContext {
        OracleViewModel.OracleSendTabContext(
            tabID: tabID,
            workspaceID: workspaceID,
            activationPolicy: .foregroundWhenActive,
            packaging: OracleViewModel.OracleSendPackagingContext(
                sourceTabID: tabID,
                sourceWorkspaceID: workspaceID,
                sourceSelectionRevision: 0,
                sourceAgentSessionID: nil,
                sourceAgentRunID: nil,
                promptText: "",
                selection: StoredSelection(),
                lookupContext: nil,
                reviewGitContext: .automaticOnly(),
                provenance: .direct
            )
        )
    }
}

import Foundation
import MCP
@testable import RepoPromptApp
import XCTest

@MainActor
final class OracleTransientImageHistoryTests: XCTestCase {
    func testOverrideAttachmentTargetsOnlyTheFinalUserTurn() {
        let override = AIMessage(
            systemPrompt: "system",
            conversationMessages: [
                ConversationEntry(role: .user, content: "first"),
                ConversationEntry(role: .assistant, content: "answer"),
                ConversationEntry(role: .user, content: "final")
            ],
            temperature: nil,
            promptSectionsOrder: [],
            disabledPromptSections: []
        )

        let attached = override.attachingImagesToFinalUserTurn([image()])
        XCTAssertEqual(attached.conversationMessages.map(\.images), [[], [], [image()]])
        XCTAssertEqual(
            attached.conversationMessages.map(\.content),
            override.conversationMessages.map(\.content)
        )
        XCTAssertEqual(override.attachingImagesToFinalUserTurn([]).conversationMessages.map(\.images), [[], [], []])
    }

    func testContinuationAfterSessionUnloadRejectsNonImageModelBeforeUserRowOrDispatch() async throws {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let composition = WindowStateCompositionFactory.make(
            windowID: -3312,
            deferredInitialAgentSystemWorkspaceRefresh: true,
            sharedMCPService: MCPService()
        )
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        await composition.workspaceManager.awaitInitialized()

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OracleTransientImageHistoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Chats", isDirectory: true),
            withIntermediateDirectories: true
        )
        let oracle = composition.oracleViewModel
        defer {
            oracle.sessions = []
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
        await oracle.loadSessionsFromWorkspace()

        let imageChat = ChatSession(
            workspaceID: workspace.id,
            composeTabID: tab.id,
            name: "Image History",
            messages: [
                StoredMessage(isUser: true, rawText: "what colors", sequenceIndex: 0),
                StoredMessage(isUser: false, rawText: "COLORS: red,green,blue", sequenceIndex: 1)
            ]
        )
        oracle.sessions.append(imageChat)
        if oracle.currentSessionID == nil {
            _ = await oracle.startNewChatSession(name: "Foreground", tabID: tab.id)
        }
        let foregroundSessionID = try XCTUnwrap(oracle.currentSessionID)
        XCTAssertNotEqual(foregroundSessionID, imageChat.id)

        let loaded = await oracle.ensureSessionMessagesLoaded(imageChat.id)
        XCTAssertTrue(loaded)
        let imageTurn = try XCTUnwrap(oracle.messagesSnapshot(for: imageChat.id).first)
        oracle.recordTransientImages([image()], for: imageTurn.id, in: imageChat.id)

        oracle.pinSession(imageChat.id)
        oracle.unpinSession(imageChat.id)
        XCTAssertTrue(oracle.messagesSnapshot(for: imageChat.id).isEmpty)
        XCTAssertTrue(oracle.hasHistoricalTransientImages(in: imageChat.id))
        XCTAssertFalse(oracle.hasHistoricalTransientImages(in: foregroundSessionID))

        do {
            _ = try await oracle.tool_chatSend(
                args: [
                    "message": .string("which one is in the middle?"),
                    "chat_id": .string(imageChat.id.uuidString.lowercased())
                ],
                promptVM: composition.promptManager,
                resolvedModel: .codexCustom(name: "codex")
            )
            XCTFail("Expected a ChatToolError for an image-bearing chat on a non-image model")
        } catch let error as ChatToolError {
            XCTAssertEqual(error.code, .invalidParams)
            XCTAssertTrue(error.message.hasPrefix("Image attachments are not supported"))
        }

        XCTAssertEqual(
            oracle.messagesSnapshot(for: imageChat.id).map(\.content),
            ["what colors", "COLORS: red,green,blue"]
        )
        XCTAssertFalse(oracle.isSessionStreaming(imageChat.id))

        let replayed = oracle.buildConversationEntries(for: imageChat.id)
        XCTAssertEqual(replayed.map(\.content), ["what colors", "COLORS: red,green,blue"])
        XCTAssertEqual(replayed.map(\.images), [[image()], []])

        let storedImageChat = try XCTUnwrap(oracle.sessions.first(where: { $0.id == imageChat.id }))
        await oracle.deleteSession(storedImageChat)
        XCTAssertFalse(oracle.hasHistoricalTransientImages(in: imageChat.id))
        await oracle.drainTrackedAutosaves(for: workspace.id)
    }

    func testRemovingAnImageBearingTurnReleasesItsImages() async throws {
        let fixture = makeOracleFixture(windowID: -3313)
        let oracle = fixture.oracle
        let sessionID = try await startImageTurn(in: oracle, message: "what colors")

        let imageTurn = try XCTUnwrap(oracle.messagesSnapshot(for: sessionID).first)
        await oracle.removeMessage(imageTurn.id)

        XCTAssertFalse(oracle.hasHistoricalTransientImages(in: sessionID))
        XCTAssertEqual(oracle.buildConversationEntries(for: sessionID).flatMap(\.images), [])
    }

    func testEditingTheFirstImageBearingTurnReleasesTruncatedImages() async throws {
        let fixture = makeOracleFixture(windowID: -3314)
        let oracle = fixture.oracle
        let sessionID = try await startImageTurn(in: oracle, message: "what colors")

        let imageTurn = try XCTUnwrap(oracle.messagesSnapshot(for: sessionID).first)
        await oracle.editAndResendMessage(messageId: imageTurn.id, newContent: "what colors now")

        XCTAssertFalse(oracle.hasHistoricalTransientImages(in: sessionID))
        XCTAssertEqual(
            oracle.messagesSnapshot(for: sessionID).filter(\.isUser).map(\.content),
            ["what colors now"]
        )
        XCTAssertEqual(oracle.buildConversationEntries(for: sessionID).flatMap(\.images), [])
    }

    func testEditingTheLastImageBearingTurnReleasesItsImages() async throws {
        let fixture = makeOracleFixture(windowID: -3315)
        let oracle = fixture.oracle
        let sessionID = try await startImageTurn(in: oracle, message: "what colors")

        let rows = oracle.messagesSnapshot(for: sessionID)
        let imageTurn = try XCTUnwrap(rows.first)
        let assistantRow = try XCTUnwrap(rows.dropFirst().first)
        XCTAssertFalse(assistantRow.isUser)
        await oracle.removeMessage(assistantRow.id)
        XCTAssertTrue(oracle.hasHistoricalTransientImages(in: sessionID))

        await oracle.editAndResendMessage(messageId: imageTurn.id, newContent: "what colors now")

        XCTAssertFalse(oracle.hasHistoricalTransientImages(in: sessionID))
        XCTAssertEqual(oracle.buildConversationEntries(for: sessionID).flatMap(\.images), [])
    }

    func testForkCarriesRetainedImageTurnsIntoTheNewSession() async throws {
        let fixture = makeOracleFixture(windowID: -3316)
        let oracle = fixture.oracle
        let sessionID = try await startImageTurn(in: oracle, message: "what colors")
        let forkPoint = try XCTUnwrap(oracle.messagesSnapshot(for: sessionID).last)

        await oracle.forkChatSession(from: forkPoint.id)

        let forkedID = try XCTUnwrap(oracle.sessions.first(where: { $0.id != sessionID })?.id)
        XCTAssertEqual(oracle.currentSessionID, forkedID)
        XCTAssertTrue(oracle.hasHistoricalTransientImages(in: forkedID))
        XCTAssertTrue(oracle.hasHistoricalTransientImages(in: sessionID))

        let forkedEntries = oracle.buildConversationEntries(for: forkedID)
        XCTAssertEqual(forkedEntries.first?.content, "what colors")
        XCTAssertEqual(forkedEntries.first?.images, [image()])
        XCTAssertEqual(forkedEntries.dropFirst().flatMap(\.images), [])
    }

    @MainActor
    private func startImageTurn(in oracle: OracleViewModel, message: String) async throws -> UUID {
        let workspace = try WorkspaceModel(
            name: "Image history",
            repoPaths: [],
            customStoragePath: makeTestDirectory()
        )
        oracle.workspaceManager.workspaces = [workspace]
        oracle.workspaceManager.activeWorkspace = workspace
        addTeardownBlock {
            await oracle.drainTrackedAutosaves(for: workspace.id)
        }
        let session = ChatSession(workspaceID: workspace.id, name: "Image chat")
        oracle.sessions = [session]
        oracle.currentSessionID = session.id
        _ = await oracle.sendMessage(message, sessionID: session.id, oracleTransientImages: [image()])

        let rows = oracle.messagesSnapshot(for: session.id)
        XCTAssertEqual(rows.first?.content, message)
        XCTAssertFalse(oracle.isSessionStreaming(session.id))
        XCTAssertTrue(oracle.hasHistoricalTransientImages(in: session.id))
        return session.id
    }

    @MainActor
    private func makeOracleFixture(windowID: Int) -> (oracle: OracleViewModel, apiSettings: APISettingsViewModel) {
        let keyManager = KeyManager(
            secureService: SecureKeysService(secureStorage: TestSecureStorageBackend())
        )
        let aiQueriesService = AIQueriesService(keyManager: keyManager)
        let fileManager = WorkspaceFilesViewModel()
        let apiSettings = APISettingsViewModel(
            aiQueriesService: aiQueriesService,
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )
        let prompt = PromptViewModel(
            fileManager: fileManager,
            apiSettingsViewModel: apiSettings,
            windowID: windowID,
            settingsManager: WindowSettingsManager(windowID: windowID)
        )
        let workspaceManager = WorkspaceManagerViewModel(
            fileManager: fileManager,
            promptViewModel: prompt,
            performInitialWorkspaceActivation: false
        )
        let oracle = OracleViewModel(
            aiQueriesService: aiQueriesService,
            promptViewModel: prompt,
            workspaceManager: workspaceManager,
            chatData: ChatDataService()
        )
        return (oracle, apiSettings)
    }

    private func image(title: String? = "Diagram") -> AITransientImage {
        AITransientImage(bytes: Data([1, 2, 3]), mediaType: .png, title: title)
    }
}

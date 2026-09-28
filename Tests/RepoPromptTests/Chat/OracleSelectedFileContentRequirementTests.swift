import Foundation
import MCP
@testable import RepoPromptApp
import XCTest

/// Oracle sends must fail closed instead of shipping a prompt without explicitly selected files.
@MainActor
final class OracleSelectedFileContentRequirementTests: XCTestCase {
    private struct Fixture {
        let composition: WindowStateComposition
        let workspaceID: UUID
        let tabID: UUID
        let store: WorkspaceFileContextStore
        let rootRecord: WorkspaceRootRecord
        let baseURL: URL

        func path(_ relativePath: String) -> String {
            (rootRecord.standardizedFullPath as NSString).appendingPathComponent(relativePath)
        }
    }

    private actor OneShotIngressProbe {
        private(set) var fireCount = 0

        func claimFirstFire() -> Bool {
            fireCount += 1
            return fireCount == 1
        }
    }

    func testUnresolvedExplicitSelectionFailsOracleSendWithoutDispatch() async throws {
        let fixture = try await makeFixture(windowID: -9811)
        defer { tearDown(fixture) }
        var capturedMessages: [AIMessage] = []
        installTransport(on: fixture) { capturedMessages.append($0) }

        let presentPath = fixture.path("present.md")
        let missingPath = fixture.path("missing.md")
        do {
            _ = try await send(fixture, selection: StoredSelection(selectedPaths: [presentPath, missingPath]))
            XCTFail("Expected the Oracle send to fail for an unresolved selected file")
        } catch {
            let description = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            XCTAssertTrue(description.contains("Oracle send aborted"), description)
            XCTAssertTrue(description.contains(missingPath), description)
            XCTAssertFalse(description.contains(presentPath), description)
        }
        XCTAssertTrue(capturedMessages.isEmpty, "A partial prompt must never reach the provider")

        // Control: the same fixture packages a fully resolvable selection normally.
        _ = try await send(fixture, selection: StoredSelection(selectedPaths: [presentPath]))
        XCTAssertEqual(capturedMessages.count, 1)
        XCTAssertTrue(
            try XCTUnwrap(capturedMessages.first).fileBlocks.joined().contains("PRESENT_MARKER"),
            "Resolved selected file contents must be packaged"
        )
    }

    func testOracleSendAwaitsAppliedIngressBeforeResolvingSelection() async throws {
        let fixture = try await makeFixture(windowID: -9812)
        defer { tearDown(fixture) }
        var capturedMessages: [AIMessage] = []
        installTransport(on: fixture) { capturedMessages.append($0) }

        // `late.md` only exists once the ingress barrier has captured its watermarks, so the
        // selection can resolve only if packaging awaits ingress before entry resolution.
        let lateRelativePath = "late.md"
        let lateURL = fixture.baseURL.appendingPathComponent("repo/\(lateRelativePath)")
        let probe = OneShotIngressProbe()
        let store = fixture.store
        let rootID = fixture.rootRecord.id
        await store.setAppliedIngressDidCaptureWatermarksHandler { _ in
            guard await probe.claimFirstFire() else { return }
            try? Data("LATE_MARKER".utf8).write(to: lateURL)
            await store.replayObservedFileSystemDeltas(rootID: rootID, deltas: [.fileAdded(lateRelativePath)])
        }
        addTeardownBlock { await store.setAppliedIngressDidCaptureWatermarksHandler(nil) }

        _ = try await send(fixture, selection: StoredSelection(selectedPaths: [fixture.path(lateRelativePath)]))

        let ingressFires = await probe.fireCount
        XCTAssertGreaterThan(ingressFires, 0, "Oracle packaging must await applied ingress")
        XCTAssertEqual(capturedMessages.count, 1)
        XCTAssertTrue(
            try XCTUnwrap(capturedMessages.first).fileBlocks.joined().contains("LATE_MARKER"),
            "Selection must resolve against the post-ingress catalog"
        )
    }

    // MARK: - Helpers

    private func makeFixture(windowID: Int) async throws -> Fixture {
        let composition = WindowStateCompositionFactory.make(
            windowID: windowID,
            deferredInitialAgentSystemWorkspaceRefresh: true,
            sharedMCPService: MCPService()
        )
        await composition.workspaceManager.awaitInitialized()
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OracleSelectedFileContent-\(UUID().uuidString)", isDirectory: true)
        let storageURL = baseURL.appendingPathComponent("storage", isDirectory: true)
        let repoURL = baseURL.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        try Data("PRESENT_MARKER".utf8).write(to: repoURL.appendingPathComponent("present.md"))

        var workspace = try XCTUnwrap(composition.workspaceManager.activeWorkspace)
        let tab = ComposeTabState(id: UUID())
        workspace.customStoragePath = storageURL
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

        let store = composition.promptManager.workspaceFileContextStore
        let rootRecord = try await store.loadRoot(path: repoURL.path)
        return Fixture(
            composition: composition,
            workspaceID: workspace.id,
            tabID: tab.id,
            store: store,
            rootRecord: rootRecord,
            baseURL: baseURL
        )
    }

    private func tearDown(_ fixture: Fixture) {
        fixture.composition.oracleViewModel.setOraclePostPackagingTransportOverrideForTesting(nil)
        fixture.composition.workspaceManager.prepareForWindowClose()
        fixture.composition.oracleViewModel.sessions = []
        let store = fixture.store
        let rootID = fixture.rootRecord.id
        let baseURL = fixture.baseURL
        let workspaceManager = fixture.composition.workspaceManager
        addTeardownBlock {
            await workspaceManager.awaitOwnSavesForWindowClose()
            await store.unloadRoot(id: rootID)
            try? FileManager.default.removeItem(at: baseURL)
        }
    }

    private func installTransport(on fixture: Fixture, capture: @escaping @MainActor (AIMessage) -> Void) {
        fixture.composition.oracleViewModel.setOraclePostPackagingTransportOverrideForTesting { message, _ in
            capture(message)
            let stream = AsyncThrowingStream<ChatStreamOutput, Error> { continuation in
                continuation.yield(
                    ChatStreamOutput(text: "ok", reasoning: nil, tokens: ChatTokenInfo(), terminalOutcome: .completed)
                )
                continuation.finish()
            }
            return (UUID(), stream)
        }
    }

    private func send(_ fixture: Fixture, selection: StoredSelection) async throws -> [String: Value] {
        let profile = AgentModelsSettingsProfile(
            planningModelRaw: AIModel.gpt54.rawValue,
            additionalOracleModelRaws: []
        )
        let snapshot = OracleSelectionSnapshot(
            origin: .mcp,
            agentModelsProfile: profile,
            modelPresets: [],
            modelPresetsExposed: false,
            modelPresetsTemporarilyDisabled: false,
            chatPresets: ChatPreset.BuiltIn.all(),
            defaultChatPresets: [
                .chat: ChatPreset.BuiltIn.chat,
                .plan: ChatPreset.BuiltIn.plan,
                .review: ChatPreset.BuiltIn.review
            ]
        )
        let tabContext = OracleViewModel.OracleSendTabContext(
            tabID: fixture.tabID,
            workspaceID: fixture.workspaceID,
            activationPolicy: .background,
            packaging: OracleViewModel.OracleSendPackagingContext(
                sourceTabID: fixture.tabID,
                sourceWorkspaceID: fixture.workspaceID,
                sourceSelectionRevision: 0,
                sourceAgentSessionID: nil,
                sourceAgentRunID: nil,
                promptText: "",
                selection: selection,
                lookupContext: nil,
                reviewGitContext: .automaticOnly(),
                provenance: .direct
            )
        )
        return try await fixture.composition.oracleViewModel.tool_chatSendWithConfiguredRoster(
            args: [
                "message": .string("Summarize the selected files"),
                "mode": .string("chat"),
                "new_chat": .bool(true)
            ],
            promptVM: fixture.composition.promptManager,
            tabContext: tabContext,
            capturedProfile: profile,
            selectionSnapshotOverride: snapshot
        )
    }
}

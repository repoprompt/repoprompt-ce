@testable import RepoPrompt
import XCTest

final class ClassicRepoPromptImportServiceTests: XCTestCase {
    private var tempRoot: URL!
    private lazy var documentEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private lazy var documentDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClassicRepoPromptImportServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
        try super.tearDownWithError()
    }

    func testImportCopiesClassicWorkspaceSessionsAndRewritesWorkspaceForCE() async throws {
        let sourceRoot = tempRoot.appendingPathComponent("RepoPrompt/Workspaces", isDirectory: true)
        let targetRoot = tempRoot.appendingPathComponent("RepoPrompt CE/Workspaces", isDirectory: true)
        let workspaceID = UUID()
        let chatID = UUID()
        let agentID = UUID()
        let workspace = WorkspaceModel(
            id: workspaceID,
            name: "Default",
            repoPaths: ["/tmp/classic-root"],
            isSystemWorkspace: true,
            customStoragePath: nil,
            composeTabs: [
                ComposeTabState(
                    name: "Imported Tab",
                    activeChatSessionID: chatID,
                    activeAgentSessionID: agentID
                )
            ]
        )

        try writeClassicWorkspace(
            workspace,
            sourceRoot: sourceRoot,
            chatID: chatID,
            agentID: agentID,
            includeAgentIndex: true
        )

        let result = try await ClassicRepoPromptImportService().importWorkspaces(sourceRoot: sourceRoot, targetRoot: targetRoot)

        XCTAssertEqual(result.importedCount, 1)
        XCTAssertEqual(result.skippedCount, 0)
        XCTAssertEqual(result.failedCount, 0)

        let targetIndex = try readIndex(from: targetRoot)
        XCTAssertEqual(targetIndex.count, 1)
        XCTAssertEqual(targetIndex[0].id, workspaceID)
        XCTAssertEqual(targetIndex[0].name, "Default (Classic)")
        XCTAssertFalse(targetIndex[0].isSystemWorkspace)
        XCTAssertNil(targetIndex[0].customStoragePath)

        let targetDirectory = targetRoot.appendingPathComponent("Workspace-Default (Classic)-\(workspaceID.uuidString)", isDirectory: true)
        let importedWorkspace = try WorkspaceManagerViewModel.loadWorkspaceFromFile(
            at: targetDirectory.appendingPathComponent("workspace.json")
        )
        XCTAssertEqual(importedWorkspace.id, workspaceID)
        XCTAssertEqual(importedWorkspace.name, "Default (Classic)")
        XCTAssertFalse(importedWorkspace.isSystemWorkspace)
        XCTAssertFalse(importedWorkspace.isEphemeral)
        XCTAssertNil(importedWorkspace.customStoragePath)
        XCTAssertEqual(importedWorkspace.composeTabs.first?.activeChatSessionID, chatID)
        XCTAssertEqual(importedWorkspace.composeTabs.first?.activeAgentSessionID, agentID)

        XCTAssertTrue(FileManager.default.fileExists(atPath: targetDirectory.appendingPathComponent("Chats/ChatSession-\(chatID.uuidString).json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: targetDirectory.appendingPathComponent("AgentSessions/AgentSession-\(agentID.uuidString).json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetDirectory.appendingPathComponent("AgentSessions/AgentSessionIndex.json").path))
    }

    func testFullImportLeavesWorkspacePathNilWhenCETargetUsesGlobalCustomStorage() async throws {
        let sourceAppSupportRoot = tempRoot.appendingPathComponent("RepoPrompt", isDirectory: true)
        let targetAppSupportRoot = tempRoot.appendingPathComponent("RepoPrompt CE", isDirectory: true)
        let sourcePromptRoot = tempRoot.appendingPathComponent("ClassicPromptSupport", isDirectory: true)
        let targetPromptRoot = tempRoot.appendingPathComponent("CEPromptSupport", isDirectory: true)
        let targetWorkspacesRoot = tempRoot.appendingPathComponent("CE Custom Workspaces", isDirectory: true)
        let workspaceID = UUID()
        let chatID = UUID()
        let agentID = UUID()
        let workspace = WorkspaceModel(
            id: workspaceID,
            name: "Custom CE Root",
            repoPaths: ["/tmp/custom-ce-root"],
            composeTabs: [
                ComposeTabState(
                    name: "Imported Tab",
                    activeChatSessionID: chatID,
                    activeAgentSessionID: agentID
                )
            ]
        )

        try writeClassicWorkspace(
            workspace,
            sourceRoot: sourceAppSupportRoot.appendingPathComponent("Workspaces", isDirectory: true),
            chatID: chatID,
            agentID: agentID
        )

        let result = try await ClassicRepoPromptImportService().importClassicRepoPromptData(
            sourceAppSupportRoot: sourceAppSupportRoot,
            targetAppSupportRoot: targetAppSupportRoot,
            sourcePromptSupportRoot: sourcePromptRoot,
            targetPromptSupportRoot: targetPromptRoot,
            targetWorkspacesRoot: targetWorkspacesRoot,
            targetWorkspacesRootIsGlobalCustomStorage: true
        )

        XCTAssertEqual(result.importedCount, 1)
        let targetDirectory = targetWorkspacesRoot.appendingPathComponent("Workspace-Custom CE Root-\(workspaceID.uuidString)", isDirectory: true)
        let targetIndex = try readIndex(from: targetWorkspacesRoot)
        XCTAssertNil(targetIndex.first?.customStoragePath)

        let importedWorkspace = try WorkspaceManagerViewModel.loadWorkspaceFromFile(
            at: targetDirectory.appendingPathComponent("workspace.json")
        )
        XCTAssertNil(importedWorkspace.customStoragePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: targetDirectory.appendingPathComponent("Chats/ChatSession-\(chatID.uuidString).json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: targetDirectory.appendingPathComponent("AgentSessions/AgentSession-\(agentID.uuidString).json").path))
    }

    func testImportPinsWorkspacePathWhenNameCannotRoundTripThroughIndexPath() async throws {
        let sourceRoot = tempRoot.appendingPathComponent("RepoPrompt/Workspaces", isDirectory: true)
        let targetRoot = tempRoot.appendingPathComponent("RepoPrompt CE/Workspaces", isDirectory: true)
        let workspace = WorkspaceModel(id: UUID(), name: "Client/API", repoPaths: ["/tmp/client-api"])
        try writeClassicWorkspace(workspace, sourceRoot: sourceRoot)

        let result = try await ClassicRepoPromptImportService().importWorkspaces(sourceRoot: sourceRoot, targetRoot: targetRoot)

        XCTAssertEqual(result.importedCount, 1)
        let targetDirectory = targetRoot.appendingPathComponent("Workspace-Client_API-\(workspace.id.uuidString)", isDirectory: true)
        let targetIndex = try readIndex(from: targetRoot)
        XCTAssertEqual(targetIndex.first?.name, "Client/API")
        XCTAssertEqual(targetIndex.first?.customStoragePath, targetDirectory)

        let importedWorkspace = try WorkspaceManagerViewModel.loadWorkspaceFromFile(
            at: targetDirectory.appendingPathComponent("workspace.json")
        )
        XCTAssertEqual(importedWorkspace.name, "Client/API")
        XCTAssertEqual(importedWorkspace.customStoragePath, targetDirectory)
    }

    func testImportIsIdempotentByWorkspaceID() async throws {
        let sourceRoot = tempRoot.appendingPathComponent("RepoPrompt/Workspaces", isDirectory: true)
        let targetRoot = tempRoot.appendingPathComponent("RepoPrompt CE/Workspaces", isDirectory: true)
        let workspace = WorkspaceModel(id: UUID(), name: "duoarts", repoPaths: ["/Users/example/dev/duoarts"])
        try writeClassicWorkspace(workspace, sourceRoot: sourceRoot)

        let first = try await ClassicRepoPromptImportService().importWorkspaces(sourceRoot: sourceRoot, targetRoot: targetRoot)
        let second = try await ClassicRepoPromptImportService().importWorkspaces(sourceRoot: sourceRoot, targetRoot: targetRoot)

        XCTAssertEqual(first.importedCount, 1)
        XCTAssertEqual(second.importedCount, 0)
        XCTAssertEqual(second.skippedCount, 1)
        XCTAssertEqual(try readIndex(from: targetRoot).count, 1)
    }

    func testImportRepairsWorkspaceWhenSourceAndTargetRootsMatch() async throws {
        let sharedRoot = tempRoot.appendingPathComponent("Shared Classic Workspaces", isDirectory: true)
        let chatID = UUID()
        let agentID = UUID()
        let workspace = WorkspaceModel(
            id: UUID(),
            name: "Default",
            repoPaths: ["/tmp/shared-classic"],
            isSystemWorkspace: true,
            ephemeralFlag: true,
            composeTabs: [
                ComposeTabState(
                    name: "Imported Tab",
                    activeChatSessionID: chatID,
                    activeAgentSessionID: agentID
                )
            ]
        )
        try writeClassicWorkspace(
            workspace,
            sourceRoot: sharedRoot,
            chatID: chatID,
            agentID: agentID,
            includeAgentIndex: true
        )

        let result = try await ClassicRepoPromptImportService().importWorkspaces(sourceRoot: sharedRoot, targetRoot: sharedRoot)

        XCTAssertEqual(result.importedCount, 1)
        let repairedIndex = try readIndex(from: sharedRoot)
        XCTAssertEqual(repairedIndex.first?.name, "Default (Classic)")
        XCTAssertEqual(repairedIndex.first?.isSystemWorkspace, false)
        let repairedDirectory = sharedRoot.appendingPathComponent("Workspace-Default (Classic)-\(workspace.id.uuidString)", isDirectory: true)
        let repairedWorkspace = try WorkspaceManagerViewModel.loadWorkspaceFromFile(
            at: repairedDirectory.appendingPathComponent("workspace.json")
        )
        XCTAssertEqual(repairedWorkspace.name, "Default (Classic)")
        XCTAssertFalse(repairedWorkspace.isSystemWorkspace)
        XCTAssertFalse(repairedWorkspace.isEphemeral)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repairedDirectory.appendingPathComponent("AgentSessions/AgentSessionIndex.json").path))
    }

    func testImportRepairsExistingTargetFolderMissingIndexEntry() async throws {
        let sourceRoot = tempRoot.appendingPathComponent("RepoPrompt/Workspaces", isDirectory: true)
        let targetRoot = tempRoot.appendingPathComponent("RepoPrompt CE/Workspaces", isDirectory: true)
        let workspace = WorkspaceModel(id: UUID(), name: "Recovered", repoPaths: ["/tmp/recovered"])
        let chatID = UUID()
        let agentID = UUID()
        try writeClassicWorkspace(
            workspace,
            sourceRoot: sourceRoot,
            chatID: chatID,
            agentID: agentID,
            includeAgentIndex: true
        )

        let targetDirectory = targetRoot.appendingPathComponent("Workspace-Recovered-\(workspace.id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(workspace).write(to: targetDirectory.appendingPathComponent("workspace.json"))

        let result = try await ClassicRepoPromptImportService().importWorkspaces(sourceRoot: sourceRoot, targetRoot: targetRoot)

        XCTAssertEqual(result.importedCount, 1)
        XCTAssertEqual(result.failedCount, 0)
        XCTAssertEqual(try readIndex(from: targetRoot).map(\.id), [workspace.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: targetDirectory.appendingPathComponent("Chats/ChatSession-\(chatID.uuidString).json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: targetDirectory.appendingPathComponent("AgentSessions/AgentSession-\(agentID.uuidString).json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetDirectory.appendingPathComponent("AgentSessions/AgentSessionIndex.json").path))
    }

    func testImportRepairsExistingTargetFolderWithNormalizedIndexName() async throws {
        let sourceRoot = tempRoot.appendingPathComponent("RepoPrompt/Workspaces", isDirectory: true)
        let targetRoot = tempRoot.appendingPathComponent("RepoPrompt CE/Workspaces", isDirectory: true)
        let workspace = WorkspaceModel(
            id: UUID(),
            name: "Default",
            repoPaths: ["/tmp/recovered"],
            isSystemWorkspace: true,
            ephemeralFlag: true
        )
        try writeClassicWorkspace(workspace, sourceRoot: sourceRoot)

        let targetDirectory = targetRoot.appendingPathComponent("Workspace-Default (Classic)-\(workspace.id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(workspace).write(to: targetDirectory.appendingPathComponent("workspace.json"))

        let result = try await ClassicRepoPromptImportService().importWorkspaces(sourceRoot: sourceRoot, targetRoot: targetRoot)

        XCTAssertEqual(result.importedCount, 1)
        XCTAssertEqual(try readIndex(from: targetRoot).first?.name, "Default (Classic)")

        let recoveredWorkspace = try WorkspaceManagerViewModel.loadWorkspaceFromFile(
            at: targetDirectory.appendingPathComponent("workspace.json")
        )
        XCTAssertEqual(recoveredWorkspace.name, "Default (Classic)")
        XCTAssertFalse(recoveredWorkspace.isSystemWorkspace)
        XCTAssertFalse(recoveredWorkspace.isEphemeral)
    }

    func testImportFailsCorruptClassicWorkspaceIndex() async throws {
        let sourceRoot = tempRoot.appendingPathComponent("RepoPrompt/Workspaces", isDirectory: true)
        let targetRoot = tempRoot.appendingPathComponent("RepoPrompt CE/Workspaces", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: sourceRoot.appendingPathComponent("workspacesIndex.json"))

        do {
            _ = try await ClassicRepoPromptImportService().importWorkspaces(sourceRoot: sourceRoot, targetRoot: targetRoot)
            XCTFail("Expected corrupt Classic workspace index to fail import")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    func testFullImportContinuesAfterCorruptWorkspaceIndex() async throws {
        let sourceAppSupportRoot = tempRoot.appendingPathComponent("RepoPrompt", isDirectory: true)
        let targetAppSupportRoot = tempRoot.appendingPathComponent("RepoPrompt CE", isDirectory: true)
        let sourcePromptRoot = tempRoot.appendingPathComponent("ClassicPromptSupport", isDirectory: true)
        let targetPromptRoot = tempRoot.appendingPathComponent("CEPromptSupport", isDirectory: true)
        let targetWorkspacesRoot = targetAppSupportRoot.appendingPathComponent("Workspaces", isDirectory: true)
        let sourceWorkspacesRoot = sourceAppSupportRoot.appendingPathComponent("Workspaces", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceWorkspacesRoot, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: sourceWorkspacesRoot.appendingPathComponent("workspacesIndex.json"))
        try writeDocument(
            GlobalSettingsDocument(globalDefaults: GlobalDefaults(discoverAgentRaw: "codexExec")),
            to: sourceAppSupportRoot.appendingPathComponent("Settings/globalSettings.json")
        )

        let result = try await ClassicRepoPromptImportService().importClassicRepoPromptData(
            sourceAppSupportRoot: sourceAppSupportRoot,
            targetAppSupportRoot: targetAppSupportRoot,
            sourcePromptSupportRoot: sourcePromptRoot,
            targetPromptSupportRoot: targetPromptRoot,
            targetWorkspacesRoot: targetWorkspacesRoot
        )

        XCTAssertEqual(result.failedCount, 1)
        XCTAssertEqual(result.settings.importedCount, 1)
        XCTAssertGreaterThan(result.totalFailedCount, 0)
    }

    func testFullImportUsesClassicGlobalCustomWorkspaceStorage() async throws {
        let sourceAppSupportRoot = tempRoot.appendingPathComponent("RepoPrompt", isDirectory: true)
        let targetAppSupportRoot = tempRoot.appendingPathComponent("RepoPrompt CE", isDirectory: true)
        let sourcePromptRoot = tempRoot.appendingPathComponent("ClassicPromptSupport", isDirectory: true)
        let targetPromptRoot = tempRoot.appendingPathComponent("CEPromptSupport", isDirectory: true)
        let targetWorkspacesRoot = targetAppSupportRoot.appendingPathComponent("Workspaces", isDirectory: true)
        let classicCustomWorkspacesRoot = tempRoot.appendingPathComponent("Classic Custom Workspaces", isDirectory: true)
        let workspace = WorkspaceModel(id: UUID(), name: "Custom Root Project", repoPaths: ["/tmp/custom-root"])
        let sourcePreferences = InMemoryPreferences(values: [
            "GlobalCustomStorageURL": classicCustomWorkspacesRoot.path
        ])

        try writeClassicWorkspace(workspace, sourceRoot: classicCustomWorkspacesRoot)

        let service = ClassicRepoPromptImportService()
        XCTAssertTrue(service.sourceExists(at: sourceAppSupportRoot, preferences: sourcePreferences))
        XCTAssertFalse(service.sourceExists(at: sourceAppSupportRoot))

        let result = try await service.importClassicRepoPromptData(
            sourceAppSupportRoot: sourceAppSupportRoot,
            targetAppSupportRoot: targetAppSupportRoot,
            sourcePromptSupportRoot: sourcePromptRoot,
            targetPromptSupportRoot: targetPromptRoot,
            targetWorkspacesRoot: targetWorkspacesRoot,
            sourcePreferences: sourcePreferences
        )

        XCTAssertEqual(result.sourceRoot, classicCustomWorkspacesRoot)
        XCTAssertEqual(result.importedCount, 1)
        XCTAssertEqual(try readIndex(from: targetWorkspacesRoot).map(\.id), [workspace.id])
    }

    func testImportAppendsToExistingCEIndexWithoutOverwritingWorkspaces() async throws {
        let sourceRoot = tempRoot.appendingPathComponent("RepoPrompt/Workspaces", isDirectory: true)
        let targetRoot = tempRoot.appendingPathComponent("RepoPrompt CE/Workspaces", isDirectory: true)
        let existingWorkspace = WorkspaceModel(id: UUID(), name: "CE Existing", repoPaths: ["/tmp/ce-existing"])
        let classicWorkspace = WorkspaceModel(id: UUID(), name: "Classic Project", repoPaths: ["/tmp/classic-project"])
        try writeClassicWorkspace(classicWorkspace, sourceRoot: sourceRoot)
        try writeCEWorkspace(existingWorkspace, targetRoot: targetRoot)

        let result = try await ClassicRepoPromptImportService().importWorkspaces(sourceRoot: sourceRoot, targetRoot: targetRoot)

        XCTAssertEqual(result.importedCount, 1)
        let targetIndex = try readIndex(from: targetRoot)
        XCTAssertEqual(targetIndex.map(\.id), [existingWorkspace.id, classicWorkspace.id])
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: targetRoot
                    .appendingPathComponent("Workspace-CE Existing-\(existingWorkspace.id.uuidString)", isDirectory: true)
                    .appendingPathComponent("workspace.json")
                    .path
            )
        )
    }

    func testImportDecodesClassicWorkspaceWithClassicOnlyFields() async throws {
        let sourceRoot = tempRoot.appendingPathComponent("RepoPrompt/Workspaces", isDirectory: true)
        let targetRoot = tempRoot.appendingPathComponent("RepoPrompt CE/Workspaces", isDirectory: true)
        let workspace = WorkspaceModel(id: UUID(), name: "Classic With Extras", repoPaths: ["/tmp/classic-extra"])
        try writeClassicWorkspace(workspace, sourceRoot: sourceRoot, includeClassicOnlyFields: true)

        let result = try await ClassicRepoPromptImportService().importWorkspaces(sourceRoot: sourceRoot, targetRoot: targetRoot)

        XCTAssertEqual(result.importedCount, 1)
        let importedWorkspaceURL = targetRoot
            .appendingPathComponent("Workspace-Classic With Extras-\(workspace.id.uuidString)", isDirectory: true)
            .appendingPathComponent("workspace.json")
        let importedWorkspace = try WorkspaceManagerViewModel.loadWorkspaceFromFile(at: importedWorkspaceURL)
        XCTAssertEqual(importedWorkspace.id, workspace.id)
        XCTAssertEqual(importedWorkspace.repoPaths, ["/tmp/classic-extra"])
    }

    func testImportDecodesOlderClassicWorkspaceIndexMissingHiddenFlag() async throws {
        let sourceRoot = tempRoot.appendingPathComponent("RepoPrompt/Workspaces", isDirectory: true)
        let targetRoot = tempRoot.appendingPathComponent("RepoPrompt CE/Workspaces", isDirectory: true)
        let workspace = WorkspaceModel(id: UUID(), name: "Legacy Index", repoPaths: ["/tmp/legacy-index"])
        try writeClassicWorkspace(workspace, sourceRoot: sourceRoot)
        let legacyIndex = """
        [
          {
            "id": "\(workspace.id.uuidString)",
            "name": "Legacy Index",
            "customStoragePath": null,
            "isSystemWorkspace": false
          }
        ]
        """
        try Data(legacyIndex.utf8).write(to: sourceRoot.appendingPathComponent("workspacesIndex.json"))

        let result = try await ClassicRepoPromptImportService().importWorkspaces(sourceRoot: sourceRoot, targetRoot: targetRoot)

        XCTAssertEqual(result.importedCount, 1)
        let targetIndex = try readIndex(from: targetRoot)
        XCTAssertEqual(targetIndex.first?.id, workspace.id)
        XCTAssertEqual(targetIndex.first?.isHiddenInMenus, false)
    }

    func testImportSkipsMissingWorkspaceFile() async throws {
        let sourceRoot = tempRoot.appendingPathComponent("RepoPrompt/Workspaces", isDirectory: true)
        let targetRoot = tempRoot.appendingPathComponent("RepoPrompt CE/Workspaces", isDirectory: true)
        let missingID = UUID()
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try writeIndex(
            [
                WorkspaceIndexEntry(
                    id: missingID,
                    name: "Missing",
                    customStoragePath: nil,
                    isSystemWorkspace: false,
                    isHiddenInMenus: false
                )
            ],
            to: sourceRoot
        )

        let result = try await ClassicRepoPromptImportService().importWorkspaces(sourceRoot: sourceRoot, targetRoot: targetRoot)

        XCTAssertEqual(result.importedCount, 0)
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertEqual(result.skipped.first?.id, missingID)
        XCTAssertEqual(try readIndex(from: targetRoot).count, 0)
    }

    func testFullImportBringsClassicSettingsPresetsPromptsAndSecureAccounts() async throws {
        let sourceAppSupportRoot = tempRoot.appendingPathComponent("RepoPrompt", isDirectory: true)
        let targetAppSupportRoot = tempRoot.appendingPathComponent("RepoPrompt CE", isDirectory: true)
        let sourcePromptRoot = tempRoot.appendingPathComponent("ClassicPromptSupport", isDirectory: true)
        let targetPromptRoot = tempRoot.appendingPathComponent("CEPromptSupport", isDirectory: true)
        let targetWorkspacesRoot = targetAppSupportRoot.appendingPathComponent("Workspaces", isDirectory: true)
        let workspaceID = UUID()
        let workflowID = UUID()

        try writeClassicWorkspace(
            WorkspaceModel(id: workspaceID, name: "Classic Project", repoPaths: ["/tmp/classic-project"]),
            sourceRoot: sourceAppSupportRoot.appendingPathComponent("Workspaces", isDirectory: true)
        )

        let settings = GlobalSettingsDocument(
            copySettings: [
                workspaceID: CopyGlobalSettings(workspaceID: workspaceID, fileTreeOption: .files)
            ],
            chatSettings: [
                workspaceID: ChatGlobalSettings(workspaceID: workspaceID, planActMode: .plan)
            ],
            globalDefaults: GlobalDefaults(discoverAgentRaw: "codexExec", discoverModelsByAgent: ["codexExec": "gpt-5"]),
            scalarPreferences: GlobalScalarPreferences(
                modelSelection: .init(preferredComposeModel: "gpt-5")
            )
        )
        try writeDocument(settings, to: sourceAppSupportRoot.appendingPathComponent("Settings/globalSettings.json"))

        let copyPresetID = UUID()
        let chatPresetID = UUID()
        let workflowPresets = PresetFileStore.WorkflowPresetDocument(
            copyUserPresets: [CopyPreset(id: copyPresetID, name: "Classic Copy")],
            copyVisibility: [copyPresetID: true],
            copyOverrides: [CopyPresetOverrides(presetID: copyPresetID, includeFiles: true)],
            chatUserPresets: [ChatPreset(id: chatPresetID, name: "Classic Chat", mode: .chat)],
            chatVisibility: [chatPresetID: true],
            chatOverrides: [ChatPresetOverrides.empty(for: chatPresetID)]
        )
        try writeDocument(workflowPresets, to: sourceAppSupportRoot.appendingPathComponent("Presets/workflowPresets.json"))

        let modelPresets = PresetFileStore.ModelPresetDocument(
            modelPresets: [ModelPreset(name: "classic_model", model: .claude4Sonnet)]
        )
        try writeDocument(modelPresets, to: sourceAppSupportRoot.appendingPathComponent("Presets/modelPresets.json"))

        let savedPrompt = PromptViewModel.StoredPrompt(id: UUID(), title: "Classic Prompt", content: "Use the old way.")
        try writeDocument([savedPrompt], to: sourcePromptRoot.appendingPathComponent("SavedPrompts.json"))

        let contextBuilderPrompt = ContextBuilderPrompt(title: "Classic Context", content: "Gather context.")
        try writeDocument([contextBuilderPrompt], to: sourcePromptRoot.appendingPathComponent("ContextBuilderPrompts.json"))

        try writeWorkflow(
            id: workflowID,
            name: "Classic Workflow",
            to: sourceAppSupportRoot
                .appendingPathComponent("Workflows", isDirectory: true)
                .appendingPathComponent("classic-workflow.md")
        )

        let sourcePreferences = InMemoryPreferences(values: [
            "CodexCLIConnected": true,
            "ClaudeCodeConnected": true,
            "ClaudeCodeCompatibleBackendConfigs": Data(#"{"kimi":{"displayName":"Classic Kimi"}}"#.utf8),
            "ClaudeCodeCompatibleBackendConfigured.kimi": true,
            "CustomProviderConfig": Data(#"{"url":"https://classic.example","defaultModel":"classic-model"}"#.utf8),
            "openrouter_configuration": Data(#"{"useCustomSettings":false}"#.utf8),
            "provider_config_openAI": Data(#"{"temperature":0.7}"#.utf8),
            "CustomOpenRouterModels": ["classic-router", "existing-router"],
            "OllamaLocalModels": ["classic-ollama"],
            "agentMode.lastUsedAgent": "codexExec",
            "agentMode.lastUsedModelsByAgent": ["codexExec": "gpt-5"],
            "AgentWorkflowStore.featuredWorkflowIDs": ["custom-\(workflowID.uuidString)"],
            "codexAgentTools.mcpServerToggles": ["classic": true],
            "codexAgentTools.bash.sandboxMode": "danger-full-access",
            "codexAgent.reasoning.lastUsedEffortByModelSlug": ["gpt-5": "medium"],
            "claudeCodePermissionMode": "acceptEdits",
            "cursorACPToolPermissionLevel": "fullAccess"
        ])
        let targetPreferences = InMemoryPreferences(values: [
            "ClaudeCodeConnected": false,
            "ClaudeCodeCompatibleBackendConfigs": Data(#"{"custom":{"displayName":"Existing Custom"}}"#.utf8),
            "openrouter_configuration": Data(#"{"baseConfig":{},"customHeaders":{},"useCustomSettings":true}"#.utf8),
            "provider_config_openAI": Data(#"{"maxTokens":1000}"#.utf8),
            "CustomOpenRouterModels": ["existing-router"],
            "agentMode.lastUsedModelsByAgent": ["engineer": "claude-sonnet"],
            "AgentWorkflowStore.featuredWorkflowIDs": ["ce-default-1", "ce-default-2", "ce-default-3", "ce-default-4"],
            "codexAgentTools.mcpServerToggles": ["existing": false],
            "codexAgent.reasoning.lastUsedEffortByModelSlug": ["o3": "high"]
        ])

        let sourceSecureStore = InMemorySecureStore(values: [
            SecureStorageAccount.openAIAPI.identifier: "classic-openai-key",
            SecureStorageAccount.codexCLIAPI.identifier: "classic-codex-key",
            SecureStorageAccount.agentPermissionCodexDocument.identifier: #"{"schemaVersion":1}"#
        ])
        let targetSecureStore = InMemorySecureStore(values: [
            SecureStorageAccount.anthropicAPI.identifier: "existing-ce-key"
        ])

        let result = try await ClassicRepoPromptImportService().importClassicRepoPromptData(
            sourceAppSupportRoot: sourceAppSupportRoot,
            targetAppSupportRoot: targetAppSupportRoot,
            sourcePromptSupportRoot: sourcePromptRoot,
            targetPromptSupportRoot: targetPromptRoot,
            targetWorkspacesRoot: targetWorkspacesRoot,
            sourceSecureValueReader: sourceSecureStore,
            targetSecureStore: targetSecureStore,
            sourcePreferences: sourcePreferences,
            targetPreferences: targetPreferences
        )

        XCTAssertEqual(result.importedCount, 1)
        XCTAssertGreaterThanOrEqual(result.settings.importedCount, 4)
        XCTAssertEqual(result.workflowPresets.importedCount, 6)
        XCTAssertEqual(result.modelPresets.importedCount, 1)
        XCTAssertEqual(result.savedPrompts.importedCount, 1)
        XCTAssertEqual(result.contextBuilderPrompts.importedCount, 1)
        XCTAssertEqual(result.workflows.importedCount, 1)
        XCTAssertGreaterThanOrEqual(result.preferences.importedCount, 7)
        XCTAssertEqual(result.secureAccounts.importedCount, 3)

        let importedSettings = try documentDecoder.decode(
            GlobalSettingsDocument.self,
            from: Data(contentsOf: targetAppSupportRoot.appendingPathComponent("Settings/globalSettings.json"))
        )
        XCTAssertEqual(importedSettings.copySettings[workspaceID]?.fileTreeOption, .files)
        XCTAssertEqual(importedSettings.chatSettings[workspaceID]?.planActMode, .plan)
        XCTAssertEqual(importedSettings.globalDefaults.discoverAgentRaw, "codexExec")
        XCTAssertEqual(importedSettings.scalarPreferences?.modelSelection?.preferredComposeModel, "gpt-5")

        let importedWorkflowPresets = try documentDecoder.decode(
            PresetFileStore.WorkflowPresetDocument.self,
            from: Data(contentsOf: targetAppSupportRoot.appendingPathComponent("Presets/workflowPresets.json"))
        )
        XCTAssertEqual(importedWorkflowPresets.copyUserPresets.first?.name, "Classic Copy")
        XCTAssertEqual(importedWorkflowPresets.chatUserPresets.first?.name, "Classic Chat")

        let importedModelPresets = try documentDecoder.decode(
            PresetFileStore.ModelPresetDocument.self,
            from: Data(contentsOf: targetAppSupportRoot.appendingPathComponent("Presets/modelPresets.json"))
        )
        XCTAssertEqual(importedModelPresets.modelPresets.first?.name, "classic_model")

        let importedSavedPrompts = try JSONDecoder().decode(
            [PromptViewModel.StoredPrompt].self,
            from: Data(contentsOf: targetPromptRoot.appendingPathComponent("SavedPrompts.json"))
        )
        XCTAssertEqual(importedSavedPrompts, [savedPrompt])

        let importedContextBuilderPrompts = try JSONDecoder().decode(
            [ContextBuilderPrompt].self,
            from: Data(contentsOf: targetPromptRoot.appendingPathComponent("ContextBuilderPrompts.json"))
        )
        XCTAssertEqual(importedContextBuilderPrompts, [contextBuilderPrompt])
        let importedWorkflowURL = targetAppSupportRoot
            .appendingPathComponent("Workflows", isDirectory: true)
            .appendingPathComponent("classic-workflow.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: importedWorkflowURL.path))
        let importedWorkflowText = try String(contentsOf: importedWorkflowURL)
        XCTAssertTrue(importedWorkflowText.contains("Classic Workflow"))

        XCTAssertEqual(targetPreferences.object(forKey: "CodexCLIConnected") as? Bool, true)
        XCTAssertEqual(targetPreferences.object(forKey: "ClaudeCodeConnected") as? Bool, false)
        let mergedBackendConfigsData = try XCTUnwrap(
            targetPreferences.object(forKey: "ClaudeCodeCompatibleBackendConfigs") as? Data
        )
        let mergedBackendConfigs = try JSONDecoder().decode([String: ClaudeCodeCompatibleBackendConfig].self, from: mergedBackendConfigsData)
        XCTAssertNotNil(mergedBackendConfigs["custom"])
        XCTAssertEqual(mergedBackendConfigs["kimi"]?.displayName, "Classic Kimi")
        XCTAssertEqual(mergedBackendConfigs["kimi"]?.baseURL, "https://api.kimi.com/coding/")
        XCTAssertEqual(targetPreferences.object(forKey: "ClaudeCodeCompatibleBackendConfigured.kimi") as? Bool, true)
        let customProviderConfigData = try XCTUnwrap(targetPreferences.object(forKey: "CustomProviderConfig") as? Data)
        let customProviderConfig = try JSONDecoder().decode(CustomProviderConfiguration.self, from: customProviderConfigData)
        XCTAssertEqual(customProviderConfig.url, "https://classic.example")
        XCTAssertEqual(customProviderConfig.defaultModel, "classic-model")
        XCTAssertEqual(customProviderConfig.name, "Classic Custom Provider")
        XCTAssertTrue(customProviderConfig.enabledModels.contains("classic-model"))
        let openRouterConfigData = try XCTUnwrap(targetPreferences.object(forKey: "openrouter_configuration") as? Data)
        let openRouterConfig = try JSONDecoder().decode(OpenRouterConfiguration.self, from: openRouterConfigData)
        XCTAssertEqual(openRouterConfig.useCustomSettings, false)
        XCTAssertEqual(openRouterConfig.customHeaders, [:])
        XCTAssertEqual(openRouterConfig.baseConfig.maxTokens, nil)
        XCTAssertEqual(openRouterConfig.baseConfig.temperature, nil)
        let mergedOpenAIConfigData = try XCTUnwrap(targetPreferences.object(forKey: "provider_config_openAI") as? Data)
        let mergedOpenAIConfig = try XCTUnwrap(
            JSONSerialization.jsonObject(with: mergedOpenAIConfigData) as? [String: Any]
        )
        XCTAssertEqual(mergedOpenAIConfig["temperature"] as? Double, 0.7)
        XCTAssertEqual(mergedOpenAIConfig["maxTokens"] as? Int, 1000)
        XCTAssertEqual(
            targetPreferences.object(forKey: "CustomOpenRouterModels") as? [String],
            ["existing-router", "classic-router"]
        )
        XCTAssertEqual(
            targetPreferences.object(forKey: "OllamaLocalModels") as? [String],
            ["classic-ollama"]
        )
        XCTAssertEqual(targetPreferences.object(forKey: "agentMode.lastUsedAgent") as? String, "codexExec")
        XCTAssertEqual(
            targetPreferences.object(forKey: "agentMode.lastUsedModelsByAgent") as? [String: String],
            ["engineer": "claude-sonnet", "codexExec": "gpt-5"]
        )
        XCTAssertEqual(
            targetPreferences.object(forKey: "AgentWorkflowStore.featuredWorkflowIDs") as? [String],
            ["custom-\(workflowID.uuidString)", "ce-default-1", "ce-default-2", "ce-default-3", "ce-default-4"]
        )
        XCTAssertEqual(
            targetPreferences.object(forKey: "codexAgentTools.mcpServerToggles") as? [String: Bool],
            ["existing": false, "classic": true]
        )
        XCTAssertEqual(
            targetPreferences.object(forKey: "codexAgent.reasoning.lastUsedEffortByModelSlug") as? [String: String],
            ["o3": "high", "gpt-5": "medium"]
        )
        XCTAssertEqual(targetPreferences.object(forKey: "codexAgentTools.bash.sandboxMode") as? String, "danger-full-access")
        XCTAssertEqual(targetPreferences.object(forKey: "claudeCodePermissionMode") as? String, "acceptEdits")
        XCTAssertEqual(targetPreferences.object(forKey: "cursorACPToolPermissionLevel") as? String, "fullAccess")

        XCTAssertEqual(try targetSecureStore.get(for: SecureStorageAccount.openAIAPI.identifier, accessMode: .interactive), "classic-openai-key")
        XCTAssertEqual(try targetSecureStore.get(for: SecureStorageAccount.codexCLIAPI.identifier, accessMode: .interactive), "classic-codex-key")
        XCTAssertEqual(
            try targetSecureStore.get(for: SecureStorageAccount.agentPermissionCodexDocument.identifier, accessMode: .interactive),
            #"{"schemaVersion":1}"#
        )
        XCTAssertEqual(try targetSecureStore.get(for: SecureStorageAccount.anthropicAPI.identifier, accessMode: .interactive), "existing-ce-key")
    }

    func testWorkflowPresetMetadataSkipsPresetsRejectedByName() async throws {
        let sourceAppSupportRoot = tempRoot.appendingPathComponent("RepoPrompt", isDirectory: true)
        let targetAppSupportRoot = tempRoot.appendingPathComponent("RepoPrompt CE", isDirectory: true)
        let sourcePromptRoot = tempRoot.appendingPathComponent("ClassicPromptSupport", isDirectory: true)
        let targetPromptRoot = tempRoot.appendingPathComponent("CEPromptSupport", isDirectory: true)
        let targetWorkspacesRoot = targetAppSupportRoot.appendingPathComponent("Workspaces", isDirectory: true)
        let sourceCopyID = UUID()
        let targetCopyID = UUID()
        let sourceChatID = UUID()
        let targetChatID = UUID()

        let sourcePresets = PresetFileStore.WorkflowPresetDocument(
            copyUserPresets: [CopyPreset(id: sourceCopyID, name: "Shared Copy")],
            copyVisibility: [sourceCopyID: true],
            copyOverrides: [CopyPresetOverrides(presetID: sourceCopyID, includeFiles: true)],
            chatUserPresets: [ChatPreset(id: sourceChatID, name: "Shared Chat", mode: .chat)],
            chatVisibility: [sourceChatID: true],
            chatOverrides: [ChatPresetOverrides.empty(for: sourceChatID)]
        )
        let targetPresets = PresetFileStore.WorkflowPresetDocument(
            copyUserPresets: [CopyPreset(id: targetCopyID, name: "Shared Copy")],
            chatUserPresets: [ChatPreset(id: targetChatID, name: "Shared Chat", mode: .chat)]
        )
        try writeDocument(sourcePresets, to: sourceAppSupportRoot.appendingPathComponent("Presets/workflowPresets.json"))
        try writeDocument(targetPresets, to: targetAppSupportRoot.appendingPathComponent("Presets/workflowPresets.json"))

        let result = try await ClassicRepoPromptImportService().importClassicRepoPromptData(
            sourceAppSupportRoot: sourceAppSupportRoot,
            targetAppSupportRoot: targetAppSupportRoot,
            sourcePromptSupportRoot: sourcePromptRoot,
            targetPromptSupportRoot: targetPromptRoot,
            targetWorkspacesRoot: targetWorkspacesRoot,
            sourceSecureValueReader: nil,
            targetSecureStore: nil,
            sourcePreferences: nil,
            targetPreferences: nil
        )

        XCTAssertEqual(result.workflowPresets.importedCount, 0)
        let mergedPresets = try documentDecoder.decode(
            PresetFileStore.WorkflowPresetDocument.self,
            from: Data(contentsOf: targetAppSupportRoot.appendingPathComponent("Presets/workflowPresets.json"))
        )
        XCTAssertEqual(mergedPresets.copyUserPresets.map(\.id), [targetCopyID])
        XCTAssertEqual(mergedPresets.chatUserPresets.map(\.id), [targetChatID])
        XCTAssertTrue(mergedPresets.copyOverrides.isEmpty)
        XCTAssertTrue(mergedPresets.chatOverrides.isEmpty)
        XCTAssertTrue(mergedPresets.copyVisibilityByPresetID.isEmpty)
        XCTAssertTrue(mergedPresets.chatVisibilityByPresetID.isEmpty)
    }

    func testImportWithoutSecureStoresMigratesConfigWithoutKeychainAccess() async throws {
        let sourceAppSupportRoot = tempRoot.appendingPathComponent("RepoPrompt", isDirectory: true)
        let targetAppSupportRoot = tempRoot.appendingPathComponent("RepoPrompt CE", isDirectory: true)
        let sourcePromptRoot = tempRoot.appendingPathComponent("ClassicPromptSupport", isDirectory: true)
        let targetPromptRoot = tempRoot.appendingPathComponent("CEPromptSupport", isDirectory: true)
        let targetWorkspacesRoot = targetAppSupportRoot.appendingPathComponent("Workspaces", isDirectory: true)
        let workspaceID = UUID()

        try writeClassicWorkspace(
            WorkspaceModel(id: workspaceID, name: "Classic Project", repoPaths: ["/tmp/classic-project"]),
            sourceRoot: sourceAppSupportRoot.appendingPathComponent("Workspaces", isDirectory: true)
        )
        try writeDocument(
            GlobalSettingsDocument(
                globalDefaults: GlobalDefaults(discoverAgentRaw: "codexExec", discoverModelsByAgent: ["codexExec": "gpt-5"])
            ),
            to: sourceAppSupportRoot.appendingPathComponent("Settings/globalSettings.json")
        )

        let sourcePreferences = InMemoryPreferences(values: [
            "CodexCLIConnected": true,
            "agentMode.lastUsedAgent": "codexExec",
            "agentMode.lastUsedModelsByAgent": ["codexExec": "gpt-5"]
        ])
        let targetPreferences = InMemoryPreferences()

        let result = try await ClassicRepoPromptImportService().importClassicRepoPromptData(
            sourceAppSupportRoot: sourceAppSupportRoot,
            targetAppSupportRoot: targetAppSupportRoot,
            sourcePromptSupportRoot: sourcePromptRoot,
            targetPromptSupportRoot: targetPromptRoot,
            targetWorkspacesRoot: targetWorkspacesRoot,
            sourceSecureValueReader: nil,
            targetSecureStore: nil,
            sourcePreferences: sourcePreferences,
            targetPreferences: targetPreferences
        )

        XCTAssertEqual(result.importedCount, 1)
        XCTAssertEqual(result.settings.importedCount, 1)
        XCTAssertEqual(result.preferences.importedCount, 3)
        XCTAssertEqual(result.secureAccounts.importedCount, 0)
        XCTAssertEqual(result.secureAccounts.skippedCount, 1)
        XCTAssertEqual(result.secureAccounts.messages, ["Classic secure account import is unavailable in this runtime."])
        XCTAssertEqual(targetPreferences.object(forKey: "CodexCLIConnected") as? Bool, true)
        XCTAssertEqual(targetPreferences.object(forKey: "agentMode.lastUsedAgent") as? String, "codexExec")
        XCTAssertEqual(
            targetPreferences.object(forKey: "agentMode.lastUsedModelsByAgent") as? [String: String],
            ["codexExec": "gpt-5"]
        )
    }

    func testImportCanRunForPreferenceOnlyClassicSource() async throws {
        let sourceAppSupportRoot = tempRoot.appendingPathComponent("RepoPrompt", isDirectory: true)
        let targetAppSupportRoot = tempRoot.appendingPathComponent("RepoPrompt CE", isDirectory: true)
        let sourcePromptRoot = tempRoot.appendingPathComponent("ClassicPromptSupport", isDirectory: true)
        let targetPromptRoot = tempRoot.appendingPathComponent("CEPromptSupport", isDirectory: true)
        let targetWorkspacesRoot = targetAppSupportRoot.appendingPathComponent("Workspaces", isDirectory: true)
        let sourcePreferences = InMemoryPreferences(values: [
            "CodexCLIConnected": true,
            "ClaudeCodeConnected": true,
            "OpenCodeCLIConnected": true,
            "agentMode.lastUsedAgent": "codexExec",
            "agentMode.lastUsedModelsByAgent": ["engineer": "gpt-5"]
        ])
        let targetPreferences = InMemoryPreferences()
        let service = ClassicRepoPromptImportService()

        XCTAssertFalse(service.sourceExists(at: sourceAppSupportRoot))
        XCTAssertTrue(service.sourceExists(at: sourceAppSupportRoot, preferences: sourcePreferences))

        let result = try await service.importClassicRepoPromptData(
            sourceAppSupportRoot: sourceAppSupportRoot,
            targetAppSupportRoot: targetAppSupportRoot,
            sourcePromptSupportRoot: sourcePromptRoot,
            targetPromptSupportRoot: targetPromptRoot,
            targetWorkspacesRoot: targetWorkspacesRoot,
            sourceSecureValueReader: nil,
            targetSecureStore: nil,
            sourcePreferences: sourcePreferences,
            targetPreferences: targetPreferences
        )

        XCTAssertEqual(result.importedCount, 0)
        XCTAssertEqual(result.preferences.importedCount, 5)
        XCTAssertEqual(result.secureAccounts.importedCount, 0)
        XCTAssertEqual(targetPreferences.object(forKey: "CodexCLIConnected") as? Bool, true)
        XCTAssertEqual(targetPreferences.object(forKey: "ClaudeCodeConnected") as? Bool, true)
        XCTAssertEqual(targetPreferences.object(forKey: "OpenCodeCLIConnected") as? Bool, true)
        XCTAssertEqual(targetPreferences.object(forKey: "agentMode.lastUsedAgent") as? String, "codexExec")
        XCTAssertEqual(
            targetPreferences.object(forKey: "agentMode.lastUsedModelsByAgent") as? [String: String],
            ["engineer": "gpt-5"]
        )
    }

    func testSourceExistsRequiresClassicAppSupportDataNotOnlySharedPrompts() throws {
        let sourceAppSupportRoot = tempRoot.appendingPathComponent("RepoPrompt", isDirectory: true)
        XCTAssertFalse(ClassicRepoPromptImportService().sourceExists(at: sourceAppSupportRoot))

        try writeDocument(
            [PromptViewModel.StoredPrompt(id: UUID(), title: "Shared", content: "Prompt")],
            to: tempRoot
                .appendingPathComponent("com.pvncher.repoprompt", isDirectory: true)
                .appendingPathComponent("SavedPrompts.json")
        )
        XCTAssertFalse(ClassicRepoPromptImportService().sourceExists(at: sourceAppSupportRoot))

        try FileManager.default.createDirectory(
            at: sourceAppSupportRoot.appendingPathComponent("Workflows", isDirectory: true),
            withIntermediateDirectories: true
        )
        XCTAssertFalse(ClassicRepoPromptImportService().sourceExists(at: sourceAppSupportRoot))

        try writeWorkflow(
            id: UUID(),
            name: "Only Workflow",
            to: sourceAppSupportRoot
                .appendingPathComponent("Workflows", isDirectory: true)
                .appendingPathComponent("only-workflow.md")
        )
        XCTAssertTrue(ClassicRepoPromptImportService().sourceExists(at: sourceAppSupportRoot))
        try FileManager.default.removeItem(at: sourceAppSupportRoot.appendingPathComponent("Workflows", isDirectory: true))

        try writeDocument(
            GlobalSettingsDocument(),
            to: sourceAppSupportRoot.appendingPathComponent("Settings/globalSettings.json")
        )
        XCTAssertTrue(ClassicRepoPromptImportService().sourceExists(at: sourceAppSupportRoot))
    }

    func testSummaryUsesFailureMessagesInsteadOfSkippedNotes() {
        let result = ClassicRepoPromptImportResult(
            sourceRoot: tempRoot.appendingPathComponent("source"),
            targetRoot: tempRoot.appendingPathComponent("target"),
            workflowPresets: .init(skippedCount: 1, messages: ["Classic workflow presets were already present."]),
            secureAccounts: .init(failedCount: 1, messages: ["OpenAI API key: Keychain access requires user interaction."], failureMessages: ["OpenAI API key: Keychain access requires user interaction."])
        )

        let summary = result.userFacingSummary()

        XCTAssertTrue(summary.contains("Failed 1 item: OpenAI API key: Keychain access requires user interaction."))
        XCTAssertFalse(summary.contains("Failed 1 item: Classic workflow presets were already present."))
    }

    func testSectionFailureSummaryIncludesImportError() async throws {
        let sourceAppSupportRoot = tempRoot.appendingPathComponent("RepoPrompt", isDirectory: true)
        let targetAppSupportRoot = tempRoot.appendingPathComponent("RepoPrompt CE", isDirectory: true)
        let sourcePromptRoot = tempRoot.appendingPathComponent("ClassicPromptSupport", isDirectory: true)
        let targetPromptRoot = tempRoot.appendingPathComponent("CEPromptSupport", isDirectory: true)
        let targetWorkspacesRoot = targetAppSupportRoot.appendingPathComponent("Workspaces", isDirectory: true)
        let settingsURL = sourceAppSupportRoot.appendingPathComponent("Settings/globalSettings.json")
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{".utf8).write(to: settingsURL)

        let result = try await ClassicRepoPromptImportService().importClassicRepoPromptData(
            sourceAppSupportRoot: sourceAppSupportRoot,
            targetAppSupportRoot: targetAppSupportRoot,
            sourcePromptSupportRoot: sourcePromptRoot,
            targetPromptSupportRoot: targetPromptRoot,
            targetWorkspacesRoot: targetWorkspacesRoot
        )

        XCTAssertEqual(result.settings.failedCount, 1)
        XCTAssertTrue(result.userFacingSummary().contains("Failed 1 item: Settings import failed:"))
    }

    private func writeClassicWorkspace(
        _ workspace: WorkspaceModel,
        sourceRoot: URL,
        chatID: UUID? = nil,
        agentID: UUID? = nil,
        includeAgentIndex: Bool = false,
        includeClassicOnlyFields: Bool = false
    ) throws {
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let workspaceDirectory = sourceRoot.appendingPathComponent(workspaceDirectoryName(for: workspace), isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDirectory, withIntermediateDirectories: true)
        var workspaceData = try JSONEncoder().encode(workspace)
        if includeClassicOnlyFields {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: workspaceData) as? [String: Any])
            object["workingFilePaths"] = ["/tmp/classic-extra/Sources/App.swift"]
            object["workingExpandedFolders"] = ["/tmp/classic-extra/Sources"]
            object["workingStoredSelection"] = [
                "selectedPaths": ["/tmp/classic-extra/Sources/App.swift"],
                "slices": [:],
                "codemapAutoEnabled": true,
                "autoCodemapPaths": []
            ]
            object["discoveryInstructions"] = "Classic-only discovery instructions"
            workspaceData = try JSONSerialization.data(withJSONObject: object)
        }
        try workspaceData.write(to: workspaceDirectory.appendingPathComponent("workspace.json"))

        if let chatID {
            let chats = workspaceDirectory.appendingPathComponent("Chats", isDirectory: true)
            try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
            let chat = ChatSession(
                id: chatID,
                workspaceID: workspace.id,
                composeTabID: workspace.composeTabs.first?.id,
                name: "Classic Chat",
                messages: []
            )
            try JSONEncoder().encode(chat).write(to: chats.appendingPathComponent("ChatSession-\(chatID.uuidString).json"))
        }

        if let agentID {
            let sessions = workspaceDirectory.appendingPathComponent("AgentSessions", isDirectory: true)
            try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
            let payload = #"{"id":"\#(agentID.uuidString)","name":"Classic Agent"}"#
            try Data(payload.utf8).write(to: sessions.appendingPathComponent("AgentSession-\(agentID.uuidString).json"))
            if includeAgentIndex {
                try Data(#"{"schemaVersion":1,"entries":[]}"#.utf8).write(to: sessions.appendingPathComponent("AgentSessionIndex.json"))
            }
        }

        try writeIndex(
            [
                WorkspaceIndexEntry(
                    id: workspace.id,
                    name: workspace.name,
                    customStoragePath: workspace.customStoragePath,
                    isSystemWorkspace: workspace.isSystemWorkspace,
                    isHiddenInMenus: workspace.isHiddenInMenus
                )
            ],
            to: sourceRoot
        )
    }

    private func writeCEWorkspace(_ workspace: WorkspaceModel, targetRoot: URL) throws {
        try FileManager.default.createDirectory(at: targetRoot, withIntermediateDirectories: true)
        let workspaceDirectory = targetRoot.appendingPathComponent(workspaceDirectoryName(for: workspace), isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(workspace).write(to: workspaceDirectory.appendingPathComponent("workspace.json"))
        try writeIndex(
            [
                WorkspaceIndexEntry(
                    id: workspace.id,
                    name: workspace.name,
                    customStoragePath: workspace.customStoragePath,
                    isSystemWorkspace: workspace.isSystemWorkspace,
                    isHiddenInMenus: workspace.isHiddenInMenus
                )
            ],
            to: targetRoot
        )
    }

    private func writeIndex(_ entries: [WorkspaceIndexEntry], to root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: root.appendingPathComponent("workspacesIndex.json"))
    }

    private func readIndex(from root: URL) throws -> [WorkspaceIndexEntry] {
        let url = root.appendingPathComponent("workspacesIndex.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }
        return try JSONDecoder().decode([WorkspaceIndexEntry].self, from: Data(contentsOf: url))
    }

    private func workspaceDirectoryName(for workspace: WorkspaceModel) -> String {
        let safeName = workspace.name
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "Workspace-\(safeName)-\(workspace.id.uuidString)"
    }

    private func writeDocument(_ document: some Encodable, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try documentEncoder.encode(document).write(to: url)
    }

    private func writeWorkflow(id: UUID, name: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = """
        ---
        id: \(id.uuidString)
        name: "\(name)"
        icon: "hammer.fill"
        ---

        # \(name)

        $ARGUMENTS
        """
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}

private final class InMemoryPreferences: ClassicRepoPromptPreferences, @unchecked Sendable {
    private var values: [String: Any]
    private let lock = NSLock()

    init(values: [String: Any] = [:]) {
        self.values = values
    }

    func object(forKey key: String) -> Any? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func setObject(_ value: Any, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
    }
}

private final class InMemorySecureStore: ClassicRepoPromptSecureValueReading, ClassicRepoPromptSecureValueWriting, @unchecked Sendable {
    private var values: [String: String]
    private let lock = NSLock()

    init(values: [String: String] = [:]) {
        self.values = values
    }

    func save(_ value: String, for key: String, accessMode: KeychainAccessMode) throws {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
    }

    func get(for key: String, accessMode: KeychainAccessMode) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let value = values[key] else {
            throw KeychainService.KeychainError.itemNotFound
        }
        return value
    }

    func savePlainValue(_ value: String, for account: SecureStorageAccount, accessMode: KeychainAccessMode) throws {
        try save(value, for: account.identifier, accessMode: accessMode)
    }

    func getPlainValue(for account: SecureStorageAccount, accessMode: KeychainAccessMode) throws -> String? {
        do {
            return try get(for: account.identifier, accessMode: accessMode)
        } catch KeychainService.KeychainError.itemNotFound {
            return nil
        }
    }

    func delete(for key: String, accessMode: KeychainAccessMode) throws {
        lock.lock()
        defer { lock.unlock() }
        values.removeValue(forKey: key)
    }
}

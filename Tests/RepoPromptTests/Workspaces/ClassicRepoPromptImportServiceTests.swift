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
            "agentMode.lastUsedAgent": "codexExec",
            "agentMode.lastUsedModelsByAgent": ["codexExec": "gpt-5"],
            "AgentWorkflowStore.featuredWorkflowIDs": ["custom-\(workflowID.uuidString)"],
            "codexAgentTools.bash.sandboxMode": "danger-full-access",
            "claudeCodePermissionMode": "acceptEdits",
            "cursorACPToolPermissionLevel": "fullAccess"
        ])
        let targetPreferences = InMemoryPreferences(values: [
            "ClaudeCodeConnected": false
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
        XCTAssertEqual(targetPreferences.object(forKey: "agentMode.lastUsedAgent") as? String, "codexExec")
        XCTAssertEqual(
            targetPreferences.object(forKey: "agentMode.lastUsedModelsByAgent") as? [String: String],
            ["codexExec": "gpt-5"]
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

    private func writeClassicWorkspace(
        _ workspace: WorkspaceModel,
        sourceRoot: URL,
        chatID: UUID? = nil,
        agentID: UUID? = nil,
        includeAgentIndex: Bool = false,
        includeClassicOnlyFields: Bool = false
    ) throws {
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let workspaceDirectory = sourceRoot.appendingPathComponent("Workspace-\(workspace.name)-\(workspace.id.uuidString)", isDirectory: true)
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
        let workspaceDirectory = targetRoot.appendingPathComponent("Workspace-\(workspace.name)-\(workspace.id.uuidString)", isDirectory: true)
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

private final class InMemorySecureStore: SecureKeyValueStorageBackend, ClassicRepoPromptSecureValueReading, @unchecked Sendable {
    let persistsValuesAcrossLaunches = true
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

    func delete(for key: String, accessMode: KeychainAccessMode) throws {
        lock.lock()
        defer { lock.unlock() }
        values.removeValue(forKey: key)
    }
}

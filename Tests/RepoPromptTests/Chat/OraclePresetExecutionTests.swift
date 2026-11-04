import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptSettingsCore
import RepoPromptShared
import XCTest

@MainActor
final class OraclePresetExecutionTests: XCTestCase {
    func testBackgroundFlatSchemaSurvivesCanonicalCallerProjection() async throws {
        let canonical = try XCTUnwrap(MCPDomainCanonicalToolDefinitions.definition(named: MCPWindowToolName.askOracle))
        var schema = try XCTUnwrap(canonical.inputSchema.objectValue)
        var properties = try XCTUnwrap(schema["properties"]?.objectValue)
        XCTAssertEqual(properties[OracleAdditionalOraclesContract.argumentName], OracleAdditionalOraclesContract.schemaProperty())
        XCTAssertNil(schema["required"])
        XCTAssertTrue(canonical.description.hasSuffix(OracleBackgroundContract.startDescription + "\n\n" + OracleBackgroundContract.cancelDescription))

        properties["background"] = .object(["type": .string("boolean"), "default": .bool(false)])
        properties["op"] = .object([
            "type": .string("string"), "enum": .array([.string("send"), .string("cancel")]), "default": .string("send")
        ])
        for key in ["oracle_group_id", "oracle_turn_id"] {
            properties[key] = .object(["type": .string("string"), "format": .string("uuid")])
        }
        schema["properties"] = .object(properties)
        schema.removeValue(forKey: "required")
        XCTAssertEqual(schema["type"], .string("object"))
        for key in ["anyOf", "oneOf", "allOf", "if", "then", "not"] {
            XCTAssertNil(schema[key], "Oracle schema root must omit \(key)")
        }
        // Independently spell the approved recipe, including the fork roster property.
        let projected = MCPDomainToolDefinition(
            name: canonical.name,
            description: canonical.description,
            inputSchema: .object(schema),
            annotations: canonical.annotations,
            isEnabledByDefault: canonical.isEnabledByDefault
        )
        XCTAssertEqual(projected.inputSchema, canonical.inputSchema)
        let collect = try XCTUnwrap(MCPDomainCanonicalToolDefinitions.definition(named: MCPWindowToolName.oracleChatLog))
        let collectProperties = try XCTUnwrap(collect.inputSchema.objectValue?["properties"]?.objectValue)
        XCTAssertEqual(collectProperties["op"], .object(["type": .string("string"), "enum": .array([.string("read"), .string("collect")]), "default": .string("read")]))
        XCTAssertEqual(collectProperties["include_finished"], .object(["type": .string("boolean"), "default": .bool(true)]))
        for key in ["oracle_group_id", "oracle_turn_id"] {
            XCTAssertEqual(collectProperties[key], properties[key])
        }
        XCTAssertTrue(collect.description.hasSuffix(OracleBackgroundContract.collectDescription))
        let binding = MCPDomainToolBinding(definition: canonical) { _ in .null }
        let tool = try RepoPromptApp.Tool(domainBinding: binding)
        // The typed schema is not the advertised authority for a canonical name.
        // Registration reloads the exact raw canonical schema.
        XCTAssertEqual(try tool.domainBinding().definition, canonical)
        let rebound = try RepoPromptApp.Tool(canonicalizing: tool).domainBinding()
        XCTAssertEqual(rebound.definition, canonical)

        #if DEBUG
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("oracle-schema-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let runtime = MCPDomainRuntime(configuration: .init(
                mode: .app, profileIdentifier: "oracle-schema-test", storageDirectory: directory,
                eventDirectory: directory, temporaryDirectory: directory, externalReloadInterval: nil
            ))
            // Exercise canonical registration, host policy, production cache and final codec.
            _ = try await runtime.toolRegistry.register(
                registrationID: MCPDomainToolRegistrationID(), scope: .window(id: 1), bindings: [binding]
            )
            let manager = ServerNetworkManager(domainHost: runtime.domainHost)
            let callers: [(MCPClientToolPolicyProfile, MCPRunPurpose, String)] = [
                (.direct, .unknown, "manual"), (.discovery, .discoverRun, "discovery"),
                (.agentModeGenericExplore, .agentModeRun, "generic"),
                (.agentModeGenericEngineer, .agentModeRun, "generic"),
                (.agentModeClaudeEngineer, .agentModeRun, "claude-code"),
                (.agentModeCodexEngineer, .agentModeRun, "codex-mcp-client"),
                (.agentModeOpenCodeEngineer, .agentModeRun, "opencode"),
                (.agentModeCursorEngineer, .agentModeRun, "cursor")
            ]
            for (profile, purpose, client) in callers {
                let classification = MCPClientToolPolicyCatalog.classification(for: profile)
                let policy = MCPDomainClientPolicySnapshot(
                    restrictedToolNames: MCPDomainToolCatalog.toolNames(for: classification.restrictedCapabilities),
                    additionalToolNames: MCPDomainToolCatalog.toolNames(for: classification.grantedCapabilities),
                    role: classification.role, allowsAgentExternalControlTools: classification.allowsAgentExternalControlTools
                )
                for surface: AgentSessionLinkToolSurface in [.full, .overseenOnly] {
                    let advertised = await runtime.domainHost.advertisedCatalog(.init(
                        isGloballyEnabled: true, disabledToolNames: [],
                        policy: policy, agentSessionLinkSurface: surface
                    ))
                    if profile == .discovery || profile == .agentModeGenericExplore {
                        XCTAssertTrue(advertised.definitions.isEmpty, "\(profile) must not gain Oracle access")
                        XCTAssertEqual(advertised.hiddenReasonsByToolName[canonical.name], profile == .discovery ? .restricted : .roleAdvertisementPolicy)
                        continue
                    }
                    let definition = try XCTUnwrap(advertised.definitions.first { $0.name == canonical.name }, "\(profile)")
                    XCTAssertEqual(definition.inputSchema, projected.inputSchema)
                    let outboundSchema = try await manager.debugCachedToolSchema(
                        definition: definition, purpose: purpose, surface: surface
                    )
                    let outbound = ListTools.Result(tools: [MCP.Tool(
                        name: definition.name, description: definition.description, inputSchema: outboundSchema,
                        annotations: CodexMCPToolAnnotationProjection.project(
                            definition.annotations.mcpAnnotations, clientIdentifier: client
                        )
                    )])
                    let decoded = try JSONDecoder().decode(ListTools.Result.self, from: JSONEncoder().encode(outbound))
                    XCTAssertEqual(decoded.tools.first?.inputSchema, projected.inputSchema, "\(profile)/\(purpose)/\(surface)")
                }
            }
        #else
            throw XCTSkip("Production schema cache testing seam is DEBUG-only")
        #endif
        XCTAssertEqual(MCPDomainCanonicalToolDefinitions.definition(named: MCPWindowToolName.askOracle)?.inputSchema, canonical.inputSchema)
    }

    func testPublishedAppToolSchemasHaveNoRootCombinators() async throws {
        func assertFlatRoot(_ input: Value, name: String) throws {
            let schema = try XCTUnwrap(input.objectValue, name)
            XCTAssertEqual(schema["type"], .string("object"), name)
            for key in ["anyOf", "oneOf", "allOf", "if", "then", "not"] {
                XCTAssertNil(schema[key], "\(name) schema root must omit \(key)")
            }
        }
        let definitions = MCPDomainCanonicalToolDefinitions.definitions
        XCTAssertFalse(definitions.isEmpty)
        for definition in definitions {
            try assertFlatRoot(definition.inputSchema, name: definition.name)
        }
        let canonical = try XCTUnwrap(MCPDomainCanonicalToolDefinitions.definition(named: MCPWindowToolName.askOracle))
        let collect = try XCTUnwrap(MCPDomainCanonicalToolDefinitions.definition(named: MCPWindowToolName.oracleChatLog))
        #if DEBUG
            try await MCPSharedServerTestLease.shared.withLease { lease in
                let fixture = try await PersistentMCPTestFixture.make(lease: lease)
                var agentEndpoint: PersistentMCPTestEndpoint?
                @MainActor func closeAgentEndpoint() async {
                    guard let endpoint = agentEndpoint else { return }
                    endpoint.client.close()
                    await endpoint.connectionManager.stop()
                    await fixture.networkManager.debugRemoveConnection(endpoint.connectionID)
                    await fixture.networkManager.clearClientConnectionPolicy(for: endpoint.clientName)
                    await fixture.networkManager.debugClearPersistedRoutingState(for: endpoint.clientName)
                    fixture.contextA.window.mcpServer.removeTabContext(forConnectionID: endpoint.connectionID, clientName: endpoint.clientName, windowID: nil, runID: nil)
                }
                do {
                    let window = fixture.contextA.window
                    var workspace = try XCTUnwrap(window.workspaceManager.workspaces.first { $0.id == fixture.contextA.workspaceID })
                    let sessionID = UUID(), runID = UUID()
                    workspace.composeTabs[0].activeAgentSessionID = sessionID
                    _ = try await AgentSessionDataService.shared.saveAgentSession(AgentSession(id: sessionID, workspaceID: workspace.id, composeTabID: fixture.contextA.tabID, name: "Oracle schema fixture", agentKind: AgentProviderKind.claudeCode.rawValue), for: workspace)
                    if let index = window.workspaceManager.workspaces.firstIndex(where: { $0.id == workspace.id }) { window.workspaceManager.workspaces[index] = workspace }
                    await window.workspaceManager.switchWorkspace(to: workspace, saveState: false, reason: "offline Oracle schema fixture")
                    let session = await window.agentModeViewModel.ensureSessionReady(tabID: fixture.contextA.tabID, reconnectActiveProviders: false)
                    session.installRunID(runID)
                    _ = session.beginRunAttempt(source: "schema fixture")
                    session.runState = .running
                    try await window.agentModeViewModel.mcpActivateControlContext(forTabID: fixture.contextA.tabID, sessionID: sessionID, originatingConnectionID: nil, startPending: true)
                    let clientName = "oracle-schema-agent-\(UUID().uuidString)"
                    let agentPolicy = MCPClientToolPolicyCatalog.classification(for: .agentModeGenericEngineer)
                    await fixture.networkManager.installClientConnectionPolicy(
                        for: clientName, windowID: fixture.contextA.window.windowID,
                        restrictedTools: MCPDomainToolCatalog.toolNames(for: agentPolicy.restrictedCapabilities),
                        tabID: fixture.contextA.tabID, runID: runID,
                        additionalTools: MCPDomainToolCatalog.toolNames(for: agentPolicy.grantedCapabilities),
                        purpose: .agentModeRun, taskLabelKind: .engineer
                    )
                    let endpoint = try await PersistentMCPTestEndpoint.make(label: "oracle-schema-agent", networkManager: fixture.networkManager, clientName: clientName, requiredToolNames: [MCPWindowToolName.askOracle, MCPWindowToolName.oracleChatLog])
                    agentEndpoint = endpoint
                    let policy = await fixture.networkManager.debugConnectionPolicyState(for: endpoint.connectionID)
                    XCTAssertEqual(policy.purpose, .agentModeRun)
                    for refresh in [false, true] {
                        if refresh {
                            await AppDomainRuntimeComposition.shared.unregister(fixture.contextA.catalogService)
                            try await AppDomainRuntimeComposition.shared.register(fixture.contextA.catalogService)
                        }
                        let catalog = await AppDomainRuntimeComposition.shared.runtime.domainHost.advertisedCatalog(.init(
                            isGloballyEnabled: true, disabledToolNames: [],
                            policy: .init(
                                restrictedToolNames: MCPDomainToolCatalog.toolNames(for: agentPolicy.restrictedCapabilities),
                                additionalToolNames: MCPDomainToolCatalog.toolNames(for: agentPolicy.grantedCapabilities),
                                role: agentPolicy.role, allowsAgentExternalControlTools: agentPolicy.allowsAgentExternalControlTools
                            )
                        ))
                        XCTAssertFalse(catalog.definitions.isEmpty)
                        XCTAssertTrue(catalog.definitions.contains { $0.name == canonical.name })
                        for definition in catalog.definitions {
                            try assertFlatRoot(definition.inputSchema, name: "app catalog/\(definition.name)")
                        }
                        let response = try await endpoint.client.request(method: "tools/list", params: [:])
                        let object = try MCPExportWatchdogIntegrationTests.responseObject(from: response)
                        let result = try JSONDecoder().decode(ListTools.Result.self, from: JSONSerialization.data(withJSONObject: XCTUnwrap(object["result"])))
                        XCTAssertFalse(result.tools.isEmpty)
                        for tool in result.tools {
                            try assertFlatRoot(tool.inputSchema, name: "socket/\(tool.name)")
                        }
                        for expected in [canonical, collect] {
                            let tool = try XCTUnwrap(result.tools.first { $0.name == expected.name }, "Missing \(expected.name); actual \(result.tools.map(\.name))")
                            XCTAssertEqual(tool.inputSchema, expected.inputSchema, "actual socket/catalog refresh=\(refresh)")
                        }
                    }
                } catch {
                    await closeAgentEndpoint()
                    await fixture.cleanup()
                    throw error
                }
                await closeAgentEndpoint()
                await fixture.cleanup()
            }
        #endif
    }

    func testSchema1ReviewPresetOverridesConflictingAgentRosterAndUsesMappedPrompt() async throws {
        let composition = WindowStateCompositionFactory.make(
            windowID: -9321,
            deferredInitialAgentSystemWorkspaceRefresh: true,
            sharedMCPService: MCPService()
        )
        await composition.workspaceManager.awaitInitialized()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OraclePresetExecutionTests-\(UUID().uuidString)", isDirectory: true)
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
        let promptMarker = "CUSTOM REVIEW PRESET MARKER"
        composition.promptManager.storedPrompts.append(
            StoredPromptRecord(id: promptID, title: "[Custom Review]", content: promptMarker)
        )
        let chatPreset = ChatPreset(
            name: "Custom Review",
            mode: .review,
            fileTreeMode: .auto,
            codeMapUsage: .auto,
            gitInclusion: GitInclusion.none,
            storedPromptIds: [promptID],
            useStoredPromptsAsSystem: true
        )
        let migratedPreset = try loadSchema1ReviewPreset(
            directory: root,
            model: AIModel.gpt54Mini,
            chatPresetID: chatPreset.id
        )
        let profile = AgentModelsSettingsProfile(
            planningModelRaw: AIModel.gpt54.rawValue,
            additionalOracleModelRaws: [AIModel.gpt54.rawValue]
        )
        let snapshot = OracleSelectionSnapshot(
            origin: .mcp,
            agentModelsProfile: profile,
            modelPresets: [migratedPreset],
            modelPresetsExposed: true,
            modelPresetsTemporarilyDisabled: false,
            chatPresets: ChatPreset.BuiltIn.all() + [chatPreset],
            defaultChatPresets: [
                .chat: ChatPreset.BuiltIn.chat,
                .plan: ChatPreset.BuiltIn.plan,
                .review: ChatPreset.BuiltIn.review
            ]
        )
        var capturedMessages: [AIMessage] = []
        var capturedModels: [AIModel] = []
        composition.oracleViewModel.setOraclePostPackagingTransportOverrideForTesting { message, model in
            capturedMessages.append(message)
            capturedModels.append(model)
            let stream = AsyncThrowingStream<ChatStreamOutput, Error> { continuation in
                continuation.yield(
                    ChatStreamOutput(text: "36", reasoning: nil, tokens: ChatTokenInfo(), terminalOutcome: .completed)
                )
                continuation.finish()
            }
            return (UUID(), stream)
        }

        let invalidPreset = try ModelPreset(
            name: "Unavailable",
            modelStrings: [AIModel.gpt54Mini.rawValue, "missing-model"]
        )
        let invalidSnapshot = OracleSelectionSnapshot(
            origin: .mcp,
            agentModelsProfile: profile,
            modelPresets: [invalidPreset],
            modelPresetsExposed: true,
            modelPresetsTemporarilyDisabled: false,
            chatPresets: ChatPreset.BuiltIn.all(),
            defaultChatPresets: [
                .chat: ChatPreset.BuiltIn.chat,
                .plan: ChatPreset.BuiltIn.plan,
                .review: ChatPreset.BuiltIn.review
            ]
        )
        let sessionsBeforePreflight = composition.oracleViewModel.sessions.map(\.id)
        do {
            _ = try await composition.oracleViewModel.tool_chatSendWithConfiguredRoster(
                args: [
                    "message": .string("Must not dispatch"),
                    "mode": .string("review"),
                    "model": .string(invalidPreset.name),
                    "new_chat": .bool(true)
                ],
                promptVM: composition.promptManager,
                tabContext: makeTabContext(workspaceID: workspace.id, tabID: tab.id),
                capturedProfile: profile,
                selectionSnapshotOverride: invalidSnapshot
            )
            XCTFail("Expected whole-roster preflight failure")
        } catch let error as ChatToolError {
            XCTAssertEqual(error.code, .invalidParams)
            XCTAssertTrue(error.message.contains("lane 2"))
        }
        XCTAssertTrue(capturedMessages.isEmpty)
        XCTAssertEqual(composition.oracleViewModel.sessions.map(\.id), sessionsBeforePreflight)

        let result = try await composition.oracleViewModel.tool_chatSendWithConfiguredRoster(
            args: [
                "message": .string("Test: reply '36'"),
                "mode": .string("review"),
                "model": .string("Review-2"),
                "new_chat": .bool(true)
            ],
            promptVM: composition.promptManager,
            tabContext: makeTabContext(workspaceID: workspace.id, tabID: tab.id),
            capturedProfile: profile,
            selectionSnapshotOverride: snapshot
        )

        XCTAssertEqual(result["response"]?.stringValue, "36")
        XCTAssertEqual(capturedModels, [.gpt54Mini])
        XCTAssertEqual(capturedMessages.count, 1)
        XCTAssertTrue(try XCTUnwrap(capturedMessages.first).systemPrompt.contains(promptMarker))
        XCTAssertTrue(composition.oracleViewModel.sessions.allSatisfy { $0.oracleGroupID == nil })
        let session = try XCTUnwrap(
            composition.oracleViewModel.sessions.first(where: { $0.selectedChatPresetID == chatPreset.id })
        )
        XCTAssertEqual(session.preferredAIModel, AIModel.gpt54Mini.rawValue)
        await composition.oracleViewModel.drainTrackedAutosaves(for: workspace.id)
        let savedSession = try XCTUnwrap(
            composition.oracleViewModel.sessions.first(where: { $0.id == session.id })
        )
        let savedURL = try XCTUnwrap(savedSession.fileURL)
        let persistedSession = try await composition.oracleViewModel.chatData.loadChatSession(from: savedURL)
        XCTAssertEqual(persistedSession.preferredAIModel, AIModel.gpt54Mini.rawValue)
        XCTAssertEqual(persistedSession.selectedChatPresetID, chatPreset.id)

        let chatID = try XCTUnwrap(result["chat_id"]?.stringValue)
        let changedProfile = AgentModelsSettingsProfile(
            planningModelRaw: AIModel.gpt54.rawValue,
            additionalOracleModelRaws: [AIModel.gpt54.rawValue]
        )
        let continuationSnapshot = OracleSelectionSnapshot(
            origin: .mcp,
            agentModelsProfile: changedProfile,
            modelPresets: [],
            modelPresetsExposed: false,
            modelPresetsTemporarilyDisabled: false,
            chatPresets: ChatPreset.BuiltIn.all() + [chatPreset],
            defaultChatPresets: [
                .chat: ChatPreset.BuiltIn.chat,
                .plan: ChatPreset.BuiltIn.plan,
                .review: ChatPreset.BuiltIn.review
            ]
        )
        composition.oracleViewModel.purgeSessionStorage(session.id)
        composition.oracleViewModel.sessions = []
        composition.oracleViewModel.currentSessionID = nil
        let continuedByShortID = try await composition.oracleViewModel.tool_chatSendWithConfiguredRoster(
            args: [
                "message": .string("Continue by short ID"),
                "mode": .string("review"),
                "chat_id": .string(chatID)
            ],
            promptVM: composition.promptManager,
            tabContext: makeTabContext(workspaceID: workspace.id, tabID: tab.id),
            capturedProfile: changedProfile,
            selectionSnapshotOverride: continuationSnapshot
        )
        XCTAssertNil(continuedByShortID["oracle_group_id"])
        await composition.oracleViewModel.drainTrackedAutosaves(for: workspace.id)

        composition.oracleViewModel.purgeSessionStorage(session.id)
        composition.oracleViewModel.sessions = []
        composition.oracleViewModel.currentSessionID = nil
        let continuedByUUID = try await composition.oracleViewModel.tool_chatSendWithConfiguredRoster(
            args: [
                "message": .string("Continue by UUID"),
                "mode": .string("review"),
                "chat_id": .string(session.id.uuidString)
            ],
            promptVM: composition.promptManager,
            tabContext: makeTabContext(workspaceID: workspace.id, tabID: tab.id),
            capturedProfile: changedProfile,
            selectionSnapshotOverride: continuationSnapshot
        )
        XCTAssertNil(continuedByUUID["oracle_group_id"])
        XCTAssertEqual(capturedModels, [.gpt54Mini, .gpt54Mini, .gpt54Mini])
        XCTAssertEqual(capturedMessages.count, 3)
        XCTAssertTrue(capturedMessages.allSatisfy { $0.systemPrompt.contains(promptMarker) })
    }

    func testUnmarkedLegacySingleSessionUpgradesAndFreezesResolvedExecutionAuthority() async throws {
        let composition = WindowStateCompositionFactory.make(
            windowID: -9324,
            deferredInitialAgentSystemWorkspaceRefresh: true,
            sharedMCPService: MCPService()
        )
        await composition.workspaceManager.awaitInitialized()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OracleLegacyPresetExecutionTests-\(UUID().uuidString)", isDirectory: true)
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

        let promptID = UUID()
        let promptMarker = "LEGACY SINGLE REVIEW MARKER"
        composition.promptManager.storedPrompts.append(
            StoredPromptRecord(id: promptID, title: "[Legacy Review]", content: promptMarker)
        )
        let reviewPreset = ChatPreset(
            name: "Legacy Review",
            mode: .review,
            fileTreeMode: .auto,
            codeMapUsage: .auto,
            gitInclusion: GitInclusion.none,
            storedPromptIds: [promptID],
            useStoredPromptsAsSystem: true
        )
        let modelPreset = try ModelPreset(
            name: "Legacy Automatic Review",
            modelStrings: [AIModel.gpt54Mini.rawValue],
            chatPresetMappings: ChatPresetMappings(reviewPresetID: reviewPreset.id)
        )
        let profile = AgentModelsSettingsProfile(planningModelRaw: AIModel.gpt54.rawValue)
        let legacySnapshot = OracleSelectionSnapshot(
            origin: .mcp,
            agentModelsProfile: profile,
            modelPresets: [modelPreset],
            modelPresetsExposed: true,
            modelPresetsTemporarilyDisabled: false,
            chatPresets: ChatPreset.BuiltIn.all() + [reviewPreset],
            defaultChatPresets: [
                .chat: ChatPreset.BuiltIn.chat,
                .plan: ChatPreset.BuiltIn.plan,
                .review: ChatPreset.BuiltIn.review
            ]
        )
        let legacySession = ChatSession(
            workspaceID: workspace.id,
            composeTabID: tab.id,
            name: "Legacy single",
            messages: [
                StoredMessage(isUser: true, rawText: "Earlier question", timestamp: Date(timeIntervalSince1970: 1)),
                StoredMessage(isUser: false, rawText: "Earlier answer", timestamp: Date(timeIntervalSince1970: 2))
            ],
            preferredAIModel: AIModel.gpt54.rawValue,
            selectedChatPresetID: ChatPreset.BuiltIn.chat.id
        )
        let savedURL = try await composition.oracleViewModel.chatData.saveChatSession(legacySession, for: workspace)

        var capturedMessages: [AIMessage] = []
        var capturedModels: [AIModel] = []
        var persistedAtFirstDispatch: ChatSession?
        composition.oracleViewModel.setOraclePostPackagingTransportOverrideForTesting { message, model in
            if capturedMessages.isEmpty {
                persistedAtFirstDispatch = try? await composition.oracleViewModel.chatData.loadChatSession(from: savedURL)
            }
            capturedMessages.append(message)
            capturedModels.append(model)
            let stream = AsyncThrowingStream<ChatStreamOutput, Error> { continuation in
                continuation.yield(
                    ChatStreamOutput(text: "done", reasoning: nil, tokens: ChatTokenInfo(), terminalOutcome: .completed)
                )
                continuation.finish()
            }
            return (UUID(), stream)
        }

        _ = try await composition.oracleViewModel.tool_chatSendWithConfiguredRoster(
            args: [
                "message": .string("First upgraded turn"),
                "mode": .string("review"),
                "chat_id": .string(legacySession.shortID)
            ],
            promptVM: composition.promptManager,
            tabContext: makeTabContext(workspaceID: workspace.id, tabID: tab.id),
            capturedProfile: profile,
            selectionSnapshotOverride: legacySnapshot
        )
        XCTAssertEqual(persistedAtFirstDispatch?.preferredAIModel, AIModel.gpt54Mini.rawValue)
        XCTAssertEqual(persistedAtFirstDispatch?.selectedChatPresetID, reviewPreset.id)
        XCTAssertEqual(persistedAtFirstDispatch?.oracleExecutionAuthority, .frozen)
        XCTAssertEqual(capturedModels, [.gpt54Mini])
        XCTAssertTrue(try XCTUnwrap(capturedMessages.first).systemPrompt.contains(promptMarker))
        await composition.oracleViewModel.drainTrackedAutosaves(for: workspace.id)
        let upgraded = try await composition.oracleViewModel.chatData.loadChatSession(from: savedURL)
        XCTAssertEqual(upgraded.preferredAIModel, AIModel.gpt54Mini.rawValue)
        XCTAssertEqual(upgraded.selectedChatPresetID, reviewPreset.id)
        XCTAssertEqual(upgraded.oracleExecutionAuthority, .frozen)

        let changedProfile = AgentModelsSettingsProfile(planningModelRaw: AIModel.gpt54.rawValue)
        let changedSnapshot = OracleSelectionSnapshot(
            origin: .mcp,
            agentModelsProfile: changedProfile,
            modelPresets: [],
            modelPresetsExposed: false,
            modelPresetsTemporarilyDisabled: false,
            chatPresets: ChatPreset.BuiltIn.all() + [reviewPreset],
            defaultChatPresets: [
                .chat: ChatPreset.BuiltIn.chat,
                .plan: ChatPreset.BuiltIn.plan,
                .review: ChatPreset.BuiltIn.review
            ]
        )
        composition.oracleViewModel.purgeSessionStorage(legacySession.id)
        composition.oracleViewModel.sessions = []
        composition.oracleViewModel.currentSessionID = nil
        _ = try await composition.oracleViewModel.tool_chatSendWithConfiguredRoster(
            args: [
                "message": .string("Frozen later turn"),
                "mode": .string("review"),
                "chat_id": .string(legacySession.id.uuidString)
            ],
            promptVM: composition.promptManager,
            tabContext: makeTabContext(workspaceID: workspace.id, tabID: tab.id),
            capturedProfile: changedProfile,
            selectionSnapshotOverride: changedSnapshot
        )
        XCTAssertEqual(capturedModels, [.gpt54Mini, .gpt54Mini])
        XCTAssertEqual(capturedMessages.count, 2)
        XCTAssertTrue(capturedMessages.allSatisfy { $0.systemPrompt.contains(promptMarker) })
        await composition.oracleViewModel.drainTrackedAutosaves(for: workspace.id)
    }

    func testTwoLanePresetPreservesRosterPromptAndContinuationAuthority() async throws {
        let composition = WindowStateCompositionFactory.make(
            windowID: -9322,
            deferredInitialAgentSystemWorkspaceRefresh: true,
            sharedMCPService: MCPService()
        )
        await composition.workspaceManager.awaitInitialized()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OraclePresetExecutionGroupTests-\(UUID().uuidString)", isDirectory: true)
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

        let promptID = UUID()
        composition.promptManager.preferredModel = AIModel.gpt54.rawValue
        composition.promptManager.selectedChatPresetID = ChatPreset.BuiltIn.chat.id
        let promptMarker = "GROUP CUSTOM REVIEW MARKER"
        composition.promptManager.storedPrompts.append(
            StoredPromptRecord(id: promptID, title: "[Group Review]", content: promptMarker)
        )
        let chatPreset = ChatPreset(
            name: "Group Review",
            mode: .review,
            fileTreeMode: .auto,
            codeMapUsage: .auto,
            gitInclusion: GitInclusion.none,
            storedPromptIds: [promptID],
            useStoredPromptsAsSystem: true
        )
        let dispatchGuidance = "  Compare evidence before proposing changes.\nKeep disagreements explicit.  "
        let continuationGuidance = "Review the new evidence independently."
        let preset = try ModelPreset(
            name: "Review-Group",
            modelStrings: [AIModel.gpt54Mini.rawValue, AIModel.gpt54.rawValue],
            chatPresetMappings: ChatPresetMappings(reviewPresetID: chatPreset.id)
        )
        let profile = AgentModelsSettingsProfile(
            planningModelRaw: AIModel.gpt54.rawValue,
            additionalOracleModelRaws: [AIModel.gpt54.rawValue],
            oracleReconciliationGuidance: dispatchGuidance
        )
        let snapshot = OracleSelectionSnapshot(
            origin: .mcp,
            agentModelsProfile: profile,
            modelPresets: [preset],
            modelPresetsExposed: true,
            modelPresetsTemporarilyDisabled: false,
            chatPresets: ChatPreset.BuiltIn.all() + [chatPreset],
            defaultChatPresets: [
                .chat: ChatPreset.BuiltIn.chat,
                .plan: ChatPreset.BuiltIn.plan,
                .review: ChatPreset.BuiltIn.review
            ]
        )
        var capturedMessages: [AIMessage] = []
        var capturedModels: [AIModel] = []
        composition.oracleViewModel.setOraclePostPackagingTransportOverrideForTesting { message, model in
            capturedMessages.append(message)
            capturedModels.append(model)
            let stream = AsyncThrowingStream<ChatStreamOutput, Error> { continuation in
                continuation.yield(
                    ChatStreamOutput(
                        text: "response-\(model.rawValue)",
                        reasoning: nil,
                        tokens: ChatTokenInfo(),
                        terminalOutcome: .completed
                    )
                )
                continuation.finish()
            }
            return (UUID(), stream)
        }
        let context = makeTabContext(workspaceID: workspace.id, tabID: tab.id)
        let owner = try OracleViewModel.oracleGroupOwner(workspaceID: workspace.id, tabID: tab.id)
        let store = AppDomainRuntimeComposition.shared.oracleConversationStore
        var groupIDForCleanup: OracleGroupID?
        defer {
            if let groupIDForCleanup {
                addTeardownBlock {
                    if let retained = try await store.load(groupID: groupIDForCleanup, owner: owner) {
                        try await store.delete(
                            groupID: retained.group.id,
                            owner: owner,
                            expectedRevision: retained.revision
                        )
                    }
                }
            }
        }

        let started = try await composition.oracleViewModel.tool_chatSendWithConfiguredRoster(
            args: [
                "message": .string("First"),
                "mode": .string("review"),
                "model": .string(preset.name),
                "new_chat": .bool(true)
            ],
            promptVM: composition.promptManager,
            tabContext: context,
            capturedProfile: profile,
            selectionSnapshotOverride: snapshot
        )
        let groupID = try XCTUnwrap(started["oracle_group_id"]?.stringValue)
        let groupUUID = try XCTUnwrap(UUID(uuidString: groupID))
        groupIDForCleanup = OracleGroupID(rawValue: groupUUID)
        let chatID = try XCTUnwrap(started["chat_id"]?.stringValue)
        let startedLanes = try XCTUnwrap(started["oracle_results"]?.arrayValue)
        XCTAssertEqual(startedLanes.compactMap { $0.objectValue?["model_id"]?.stringValue }, preset.modelStrings)
        XCTAssertEqual(started["oracle_count"]?.intValue, 2)
        XCTAssertEqual(started["oracle_reconciliation_guidance"]?.stringValue, dispatchGuidance)
        XCTAssertEqual(capturedMessages.count, 2)
        XCTAssertTrue(capturedMessages.allSatisfy { $0.systemPrompt.contains(promptMarker) })
        await composition.oracleViewModel.drainTrackedAutosaves(for: workspace.id)
        let primarySession = try XCTUnwrap(
            composition.oracleViewModel.sessions.first(where: {
                $0.oracleGroupID == groupUUID && $0.oracleLaneIndex == 0
            })
        )
        let primaryURL = try XCTUnwrap(primarySession.fileURL)
        let persistedPrimary = try await composition.oracleViewModel.chatData.loadChatSession(from: primaryURL)
        XCTAssertEqual(persistedPrimary.preferredAIModel, AIModel.gpt54Mini.rawValue)
        XCTAssertEqual(persistedPrimary.selectedChatPresetID, chatPreset.id)
        XCTAssertEqual(persistedPrimary.oracleExecutionAuthority, .frozen)

        let changedProfile = AgentModelsSettingsProfile(
            planningModelRaw: AIModel.gpt54.rawValue,
            additionalOracleModelRaws: [],
            oracleReconciliationGuidance: continuationGuidance
        )
        let continued = try await composition.oracleViewModel.tool_chatSendWithConfiguredRoster(
            args: [
                "message": .string("Second"),
                "mode": .string("review"),
                "chat_id": .string(chatID)
            ],
            promptVM: composition.promptManager,
            tabContext: context,
            capturedProfile: changedProfile,
            selectionSnapshotOverride: snapshot
        )
        XCTAssertEqual(continued["oracle_group_id"]?.stringValue, groupID)
        XCTAssertEqual(continued["oracle_count"]?.intValue, 2)
        XCTAssertEqual(continued["oracle_reconciliation_guidance"]?.stringValue, continuationGuidance)
        XCTAssertTrue(capturedMessages.allSatisfy {
            !$0.systemPrompt.contains(dispatchGuidance) && !$0.systemPrompt.contains(continuationGuidance)
        })
        XCTAssertEqual(capturedMessages.count, 4)
        XCTAssertTrue(capturedMessages.allSatisfy { $0.systemPrompt.contains(promptMarker) })

        let groupSessionIDs = composition.oracleViewModel.sessions
            .filter { $0.oracleGroupID == groupUUID }
            .map(\.id)
        for sessionID in groupSessionIDs {
            let index = try XCTUnwrap(composition.oracleViewModel.sessions.firstIndex(where: { $0.id == sessionID }))
            var legacyProjection = composition.oracleViewModel.sessions[index]
            legacyProjection.preferredAIModel = AIModel.gpt54.rawValue
            legacyProjection.selectedChatPresetID = ChatPreset.BuiltIn.chat.id
            legacyProjection.oracleExecutionAuthority = nil
            _ = try await composition.oracleViewModel.chatData.saveChatSession(legacyProjection, for: workspace)
            composition.oracleViewModel.purgeSessionStorage(sessionID)
        }
        composition.oracleViewModel.sessions = []
        composition.oracleViewModel.currentSessionID = nil
        await composition.oracleViewModel.loadSessionsFromWorkspace()

        let legacySnapshot = OracleSelectionSnapshot(
            origin: .mcp,
            agentModelsProfile: changedProfile,
            modelPresets: [],
            modelPresetsExposed: false,
            modelPresetsTemporarilyDisabled: false,
            chatPresets: ChatPreset.BuiltIn.all() + [chatPreset],
            defaultChatPresets: [
                .chat: ChatPreset.BuiltIn.chat,
                .plan: ChatPreset.BuiltIn.plan,
                .review: chatPreset
            ]
        )
        let upgradedLegacyGroup = try await composition.oracleViewModel.tool_chatSendWithConfiguredRoster(
            args: [
                "message": .string("Legacy group upgrade"),
                "mode": .string("review"),
                "chat_id": .string(chatID)
            ],
            promptVM: composition.promptManager,
            tabContext: context,
            capturedProfile: changedProfile,
            selectionSnapshotOverride: legacySnapshot
        )
        XCTAssertEqual(upgradedLegacyGroup["oracle_group_id"]?.stringValue, groupID)
        let upgradedLanes = try XCTUnwrap(upgradedLegacyGroup["oracle_results"]?.arrayValue)
        XCTAssertEqual(upgradedLanes.compactMap { $0.objectValue?["model_id"]?.stringValue }, preset.modelStrings)
        XCTAssertEqual(Set(capturedModels.suffix(2).map(\.rawValue)), Set(preset.modelStrings))
        XCTAssertTrue(capturedMessages.suffix(2).allSatisfy { $0.systemPrompt.contains(promptMarker) })
        await composition.oracleViewModel.drainTrackedAutosaves(for: workspace.id)
        for sessionID in groupSessionIDs {
            let session = try XCTUnwrap(composition.oracleViewModel.sessions.first(where: { $0.id == sessionID }))
            let persisted = try await composition.oracleViewModel.chatData.loadChatSession(from: XCTUnwrap(session.fileURL))
            let laneIndex = try XCTUnwrap(persisted.oracleLaneIndex)
            XCTAssertEqual(persisted.preferredAIModel, preset.modelStrings[laneIndex])
            XCTAssertEqual(persisted.selectedChatPresetID, chatPreset.id)
            XCTAssertEqual(persisted.oracleExecutionAuthority, .frozen)
            composition.oracleViewModel.purgeSessionStorage(sessionID)
        }

        composition.oracleViewModel.sessions = []
        composition.oracleViewModel.currentSessionID = nil
        await composition.oracleViewModel.loadSessionsFromWorkspace()
        let frozenSnapshot = OracleSelectionSnapshot(
            origin: .mcp,
            agentModelsProfile: changedProfile,
            modelPresets: [],
            modelPresetsExposed: false,
            modelPresetsTemporarilyDisabled: false,
            chatPresets: ChatPreset.BuiltIn.all() + [chatPreset],
            defaultChatPresets: [
                .chat: ChatPreset.BuiltIn.chat,
                .plan: ChatPreset.BuiltIn.plan,
                .review: ChatPreset.BuiltIn.review
            ]
        )
        _ = try await composition.oracleViewModel.tool_chatSendWithConfiguredRoster(
            args: [
                "message": .string("Frozen group continuation"),
                "mode": .string("review"),
                "chat_id": .string(chatID)
            ],
            promptVM: composition.promptManager,
            tabContext: context,
            capturedProfile: changedProfile,
            selectionSnapshotOverride: frozenSnapshot
        )
        XCTAssertEqual(Set(capturedModels.suffix(2).map(\.rawValue)), Set(preset.modelStrings))
        XCTAssertTrue(capturedMessages.suffix(2).allSatisfy { $0.systemPrompt.contains(promptMarker) })
        await composition.oracleViewModel.drainTrackedAutosaves(for: workspace.id)
    }

    func testFiveLanePresetExecutesMaximumOrderedRosterWithMappedPrompt() async throws {
        let composition = WindowStateCompositionFactory.make(
            windowID: -9323,
            deferredInitialAgentSystemWorkspaceRefresh: true,
            sharedMCPService: MCPService()
        )
        await composition.workspaceManager.awaitInitialized()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OraclePresetExecutionFiveLaneTests-\(UUID().uuidString)", isDirectory: true)
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

        let promptID = UUID()
        composition.promptManager.preferredModel = AIModel.gpt54.rawValue
        composition.promptManager.selectedChatPresetID = ChatPreset.BuiltIn.chat.id
        let promptMarker = "FIVE LANE CUSTOM REVIEW MARKER"
        composition.promptManager.storedPrompts.append(
            StoredPromptRecord(id: promptID, title: "[Five Lane Review]", content: promptMarker)
        )
        let chatPreset = ChatPreset(
            name: "Five Lane Review",
            mode: .review,
            fileTreeMode: .auto,
            codeMapUsage: .auto,
            gitInclusion: GitInclusion.none,
            storedPromptIds: [promptID],
            useStoredPromptsAsSystem: true
        )
        let preset = try ModelPreset(
            name: "Review-Five",
            modelStrings: Array(repeating: AIModel.gpt54Mini.rawValue, count: 5),
            chatPresetMappings: ChatPresetMappings(reviewPresetID: chatPreset.id)
        )
        let profile = AgentModelsSettingsProfile(planningModelRaw: AIModel.gpt54.rawValue)
        let snapshot = OracleSelectionSnapshot(
            origin: .mcp,
            agentModelsProfile: profile,
            modelPresets: [preset],
            modelPresetsExposed: true,
            modelPresetsTemporarilyDisabled: false,
            chatPresets: ChatPreset.BuiltIn.all() + [chatPreset],
            defaultChatPresets: [
                .chat: ChatPreset.BuiltIn.chat,
                .plan: ChatPreset.BuiltIn.plan,
                .review: ChatPreset.BuiltIn.review
            ]
        )
        var capturedMessages: [AIMessage] = []
        composition.oracleViewModel.setOraclePostPackagingTransportOverrideForTesting { message, model in
            capturedMessages.append(message)
            let stream = AsyncThrowingStream<ChatStreamOutput, Error> { continuation in
                continuation.yield(
                    ChatStreamOutput(
                        text: "response-\(model.rawValue)",
                        reasoning: nil,
                        tokens: ChatTokenInfo(),
                        terminalOutcome: .completed
                    )
                )
                continuation.finish()
            }
            return (UUID(), stream)
        }
        let context = makeTabContext(workspaceID: workspace.id, tabID: tab.id)
        let owner = try OracleViewModel.oracleGroupOwner(workspaceID: workspace.id, tabID: tab.id)
        let store = AppDomainRuntimeComposition.shared.oracleConversationStore
        var groupIDForCleanup: OracleGroupID?
        defer {
            if let groupIDForCleanup {
                addTeardownBlock {
                    if let retained = try await store.load(groupID: groupIDForCleanup, owner: owner) {
                        try await store.delete(
                            groupID: retained.group.id,
                            owner: owner,
                            expectedRevision: retained.revision
                        )
                    }
                }
            }
        }

        let started = try await composition.oracleViewModel.tool_chatSendWithConfiguredRoster(
            args: [
                "message": .string("Five lanes"),
                "mode": .string("review"),
                "model": .string(preset.name),
                "new_chat": .bool(true)
            ],
            promptVM: composition.promptManager,
            tabContext: context,
            capturedProfile: profile,
            selectionSnapshotOverride: snapshot
        )
        let groupID = try XCTUnwrap(started["oracle_group_id"]?.stringValue)
        let groupUUID = try XCTUnwrap(UUID(uuidString: groupID))
        groupIDForCleanup = OracleGroupID(rawValue: groupUUID)
        let results = try XCTUnwrap(started["oracle_results"]?.arrayValue)
        XCTAssertEqual(started["oracle_count"]?.intValue, 5)
        XCTAssertEqual(results.compactMap { $0.objectValue?["model_id"]?.stringValue }, preset.modelStrings)
        XCTAssertEqual(capturedMessages.count, 5)
        XCTAssertTrue(capturedMessages.allSatisfy { $0.systemPrompt.contains(promptMarker) })
    }

    func testTerminalOnlyUsageSurvivesPreviouslySavedLiveProjection() async throws {
        let composition = WindowStateCompositionFactory.make(
            windowID: -9324,
            deferredInitialAgentSystemWorkspaceRefresh: true,
            sharedMCPService: MCPService()
        )
        await composition.workspaceManager.awaitInitialized()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
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
        composition.promptManager.preferredModel = AIModel.gpt54Mini.rawValue
        var output: AsyncThrowingStream<ChatStreamOutput, Error>.Continuation?
        composition.oracleViewModel.setOraclePostPackagingTransportOverrideForTesting { _, _ in
            let stream = AsyncThrowingStream<ChatStreamOutput, Error> { output = $0 }
            output?.yield(ChatStreamOutput(text: "saved text", reasoning: nil, tokens: ChatTokenInfo()))
            return (UUID(), stream)
        }
        let sending = Task {
            try await composition.oracleViewModel.tool_chatSendWithConfiguredRoster(
                args: ["message": .string("usage"), "new_chat": .bool(true)],
                promptVM: composition.promptManager,
                tabContext: makeTabContext(workspaceID: workspace.id, tabID: tab.id),
                capturedProfile: AgentModelsSettingsProfile(planningModelRaw: AIModel.gpt54Mini.rawValue)
            )
        }
        defer {
            sending.cancel()
            output?.finish()
        }
        var liveResponse: AIChatMessage?
        var sessionID: UUID?
        for _ in 0 ..< 10000 {
            sessionID = composition.oracleViewModel.sessions.first?.id
            liveResponse = composition.oracleViewModel.messagesSnapshot(for: sessionID).first { !$0.isUser && $0.content == "saved text" }
            if liveResponse != nil { break }
            await Task.yield()
        }
        let responseID = try XCTUnwrap(liveResponse?.id)
        let id = try XCTUnwrap(sessionID)
        XCTAssertEqual(composition.oracleViewModel.currentSessionID, id)
        composition.oracleViewModel.renameSession(id: id, newName: "Saved before usage")
        await composition.oracleViewModel.drainTrackedAutosaves(for: workspace.id)
        let url = try XCTUnwrap(composition.oracleViewModel.sessions.first { $0.id == id }?.fileURL)
        let before = try await composition.oracleViewModel.chatData.loadChatSession(from: url)
        let savedLiveResponse = try XCTUnwrap(before.messages.first { $0.id == responseID })
        XCTAssertEqual(savedLiveResponse.rawText, "saved text")
        XCTAssertNil(savedLiveResponse.promptTokens)
        XCTAssertNil(savedLiveResponse.completionTokens)
        output?.yield(ChatStreamOutput(text: "", reasoning: nil, tokens: ChatTokenInfo(promptTokens: 0, completionTokens: 7), terminalOutcome: .completed))
        output?.finish()
        _ = try await sending.value
        await composition.oracleViewModel.drainTrackedAutosaves(for: workspace.id)
        composition.oracleViewModel.purgeSessionStorage(id)
        let reloaded = try await composition.oracleViewModel.chatData.loadChatSession(from: url)
        let response = try XCTUnwrap(reloaded.messages.first { $0.id == responseID })
        XCTAssertEqual(response.promptTokens, 0)
        XCTAssertEqual(response.completionTokens, 7)
    }

    private func loadSchema1ReviewPreset(
        directory: URL,
        model: AIModel,
        chatPresetID: UUID
    ) throws -> ModelPreset {
        let modelURL = directory.appendingPathComponent("modelPresets.json")
        let presetID = UUID()
        let json = """
        {
          "schemaVersion": 1,
          "updatedAt": "2026-09-10T00:00:00Z",
          "modelPresets": [{
            "id": "\(presetID.uuidString)",
            "name": "Review-2",
            "modelString": "\(model.rawValue)",
            "supportedModes": {"chat": false, "plan": false, "review": true},
            "chatPresetMappings": {"reviewPresetID": "\(chatPresetID.uuidString)"}
          }]
        }
        """
        try Data(json.utf8).write(to: modelURL)
        let store = PresetFileStore(
            workflowFileURL: directory.appendingPathComponent("workflowPresets.json"),
            modelFileURL: modelURL
        )
        return try XCTUnwrap(store.loadModelPresets().modelPresets.first)
    }

    private func makeTabContext(workspaceID: UUID, tabID: UUID) -> OracleViewModel.OracleSendTabContext {
        OracleViewModel.OracleSendTabContext(
            tabID: tabID,
            workspaceID: workspaceID,
            activationPolicy: .background,
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

    func testExcludedFilesSkipIngressInDirectAndHeadlessOraclePackaging() async throws {
        let fixture = try await makeFixture(windowID: -9813)
        defer { tearDown(fixture) }
        let probe = OneShotIngressProbe()
        await fixture.store.setAppliedIngressDidCaptureWatermarksHandler { _ in
            _ = await probe.claimFirstFire()
        }
        let store = fixture.store
        addTeardownBlock { await store.setAppliedIngressDidCaptureWatermarksHandler(nil) }
        let config = OraclePromptConfiguration(
            chatPreset: ChatPreset.BuiltIn.chat, mode: .chat,
            promptContext: PromptContextResolved(
                includeFiles: false, includeUserPrompt: true, includeMetaPrompts: false,
                includeFileTree: false, fileTreeMode: .none, codeMapUsage: .none,
                gitInclusion: .none, storedPromptIds: []
            ),
            systemPrompt: "EXCLUDED_FILES_SYSTEM", metaInstructions: []
        )
        let selection = StoredSelection(selectedPaths: [fixture.path("missing.md")])
        let prompt = fixture.composition.promptManager
        let direct = try await prompt.packagePrompt(
            conversation: [ConversationEntry(role: .user, content: "EXCLUDED_FILES_USER")],
            oraclePromptConfiguration: config, selectionOverride: selection,
            reviewGitContextOverride: .automaticOnly()
        )
        let headless = try await prompt.buildHeadlessAIMessage(
            from: HeadlessContextSnapshot(
                workspaceID: fixture.workspaceID, tabID: fixture.tabID,
                promptText: "EXCLUDED_FILES_USER", selection: selection, reviewGitContext: .automaticOnly()
            ), model: .gpt54, mode: .chat, oraclePromptConfiguration: config
        )
        XCTAssertTrue(direct.conversationMessages.contains { $0.content.contains("EXCLUDED_FILES_USER") })
        XCTAssertTrue(headless.conversationMessages.contains { $0.content.contains("EXCLUDED_FILES_USER") })
        XCTAssertTrue(direct.fileBlocks.isEmpty)
        XCTAssertTrue(headless.fileBlocks.isEmpty)
        let ingressFires = await probe.fireCount
        XCTAssertEqual(ingressFires, 0, "Intentionally excluded file content must not wait on watcher ingress")
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

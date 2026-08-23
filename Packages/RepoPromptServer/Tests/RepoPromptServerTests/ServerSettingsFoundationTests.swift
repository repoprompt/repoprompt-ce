import Foundation
import RepoPromptHeadlessRuntime
import RepoPromptMCPAdapter
@testable import RepoPromptServiceHTTP
@testable import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import RepoPromptWorkspaceRuntimeCore
import XCTest

@testable import RepoPromptServerHost
@testable import RepoPromptServerExecutable
@testable import RepoPromptHeadlessRuntime
final class ServerSettingsFoundationTests: XCTestCase {
    func testTypedSettingsRoundTripThroughServiceCoders() throws {
        let target = AgentModelTarget(providerID: .codex, modelID: "gpt-5.6-sol", reasoningEffort: "high", pinned: true)
        try assertRoundTrip(AgentModelsProfile(
            oracle: target,
            engineer: target,
            restrictDiscoveryToRoleModels: true,
            contextBuilderModelsByAgent: [ProviderSettingsID.codex.rawValue: "gpt-5.6-sol"]
        ))
        try assertRoundTrip(SubagentPermissionSettings(policy: .custom, codex: .readOnly, claude: .autoApproveEdits, openCode: .fullAccess, cursor: .managedDefault, grokBuild: .fullAccess))
        try assertRoundTrip(DirectAgentPermissionsSettings(
            codex: .init(sandboxMode: .readOnly, approvalPolicy: .unlessTrusted, approvalReviewer: .user, bashEnabled: false),
            claude: .init(permissionMode: .autoApproveEdits, bashEnabled: false, mcpStrictModeEnabled: true, promptDelivery: .userMessageXML),
            grokBuild: .init(permissionLevel: .fullAccess)
        ))
        try assertRoundTrip(ContextBuilderSettingsProfile(
            budget: 100_000,
            enhancementMode: .augment,
            questionTimeoutSeconds: 120,
            portalClarifyingQuestions: false,
            mcpClarifyingQuestions: true,
            followUpAnalysis: .plan,
            followUpBudget: 80_000
        ))
        try assertRoundTrip(MCPModelPreset(
            presetID: UUID(),
            name: "Review",
            target: target,
            availability: [.review],
            order: 0
        ))
        try assertRoundTrip(AdvancedServerSettings(historyIdleThresholdMinutes: 10))
        try assertRoundTrip(WorkspaceApprovalSettings(autoApproveAll: true, autoApproveOperations: [.addFolder]))
        try assertRoundTrip(MCPDisabledToolsSettings(disabledTools: ["manage_workspaces"]))
        try assertRoundTrip(MCPShowModelPresetsSettings(showModelPresets: true))
        try assertRoundTrip(ProjectSelectionPreset(
            presetID: UUID(),
            projectID: UUID(),
            name: "Core",
            entries: [.init(rootID: UUID(), logicalPath: "Sources", mode: .full)],
            order: 0,
            rowRevision: 1
        ))
    }

    func testGrokBuildACPIsFirstClassCLIIdentityNotDirectAPI() throws {
        XCTAssertEqual(ProviderSettingsID.defaultSettingsID(for: .grokBuildACP), .grokBuildACP)
        XCTAssertEqual(ProviderSettingsID.grokBuildACP.runtimeKind, .grokBuildACP)
        XCTAssertTrue(ProviderSettingsID.grokBuildACP.ownsRuntimeAdmission)
        XCTAssertTrue(ProviderSettingsID.grokBuildACP.hasTypedDirectAgentProfile)
        XCTAssertFalse(ProviderSettingsID.grokBuildACP.isDirectAPI)
        XCTAssertNotEqual(ProviderSettingsID.grokBuildACP, .xAI)

        let subagent = try JSONDecoder().decode(
            SubagentPermissionSettings.self,
            from: Data(#"{"policy":"custom","codex":"readOnly","claude":"auto","openCode":"fullAccess","cursor":"managedDefault"}"#.utf8)
        )
        XCTAssertEqual(subagent.grokBuild, .managedDefault)

        let direct = try JSONDecoder().decode(
            DirectAgentPermissionsSettings.self,
            from: Data(#"{"codex":{},"claude":{},"openCode":{},"cursor":{}}"#.utf8)
        )
        XCTAssertEqual(direct.grokBuild.permissionLevel, .managedDefault)
    }

    func testDirectAgentsPersistTypedSandboxApprovalReviewerBashAndMCPStrictAndRootLaunchLiveReadsThem() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let catalog = StaticProviderCatalog(response: Self.providerCatalog())
        let service = ServerSettingsService(store: store, providerCatalog: catalog, projectCatalog: store)
        let portal = PortalDesktopSettingsService(store: store)
        let empty = await service.directAgentPermissions()
        XCTAssertEqual(empty.revision, 0)
        XCTAssertEqual(empty.settings.codex.sandboxMode, .workspaceWrite)
        XCTAssertEqual(empty.settings.codex.approvalPolicy, .onRequest)
        XCTAssertEqual(empty.settings.codex.approvalReviewer, .autoReview)
        XCTAssertTrue(empty.settings.codex.bashEnabled)
        XCTAssertEqual(empty.settings.claude.permissionMode, .requireApproval)
        XCTAssertTrue(empty.settings.claude.mcpStrictModeEnabled)
        XCTAssertEqual(empty.settings.claude.promptDelivery, .nativeSystemPrompt)
        let defaultClaude = try await portal.runtimeDefaults(for: .claudeCompatible)
        XCTAssertEqual(defaultClaude.providerSettings["claude.strictMCPEnabled"], "true")
        XCTAssertEqual(defaultClaude.providerSettings["claude.promptDelivery"], "nativeSystemPrompt")

        let projected = try await portal.runtimeDefaults(for: .codex)
        XCTAssertEqual(projected.mode, "workspaceWrite")
        XCTAssertEqual(projected.providerSettings["codex.sandbox"], "workspace-write")
        XCTAssertEqual(projected.providerSettings["codex.approvalPolicy"], "on-request")
        XCTAssertEqual(projected.providerSettings["codex.approvalsReviewer"], "auto_review")
        XCTAssertEqual(projected.providerSettings["codex.bashEnabled"], "true")

        var leftover = PortalDesktopSettingKey.defaultValues
        leftover[PortalDesktopSettingKey.codexPermissionLevel.rawValue] = "fullAccess"
        leftover[PortalDesktopSettingKey.claudeStrictMCPEnabled.rawValue] = "true"
        _ = try await store.upsertPortalDesktopSettings(
            .init(revision: 1, values: leftover, updatedAt: Date()),
            expectedRevision: 0
        )
        let bagProjected = try await portal.runtimeDefaults(for: .codex)
        XCTAssertEqual(bagProjected.mode, "fullAccess")
        XCTAssertEqual(bagProjected.providerSettings["codex.sandbox"], "danger-full-access")
        XCTAssertEqual(bagProjected.providerSettings["codex.approvalPolicy"], "never")
        XCTAssertEqual(bagProjected.providerSettings["codex.approvalsReviewer"], "user")
        let bagClaude = try await portal.runtimeDefaults(for: .claudeCompatible)
        XCTAssertEqual(bagClaude.providerSettings["claude.strictMCPEnabled"], "true")

        let written = try await service.replaceDirectAgentPermissions(
            .init(
                expectedRevision: 0,
                settings: .init(
                    codex: .init(
                        sandboxMode: .readOnly,
                        approvalPolicy: .unlessTrusted,
                        approvalReviewer: .user,
                        bashEnabled: false
                    ),
                    claude: .init(
                        permissionMode: .autoApproveEdits,
                        bashEnabled: false,
                        mcpStrictModeEnabled: true
                    )
                )
            ),
            attribution: Self.attribution
        )
        XCTAssertEqual(written.revision, 1)
        XCTAssertEqual(written.settings.codex.permissionLevel, "readOnly")

        let typedWins = try await portal.runtimeDefaults(for: .codex)
        XCTAssertEqual(typedWins.mode, "readOnly")
        XCTAssertEqual(typedWins.providerSettings["codex.sandbox"], "read-only")
        XCTAssertEqual(typedWins.providerSettings["codex.approvalPolicy"], "untrusted")
        XCTAssertEqual(typedWins.providerSettings["codex.approvalsReviewer"], "user")
        XCTAssertEqual(typedWins.providerSettings["codex.bashEnabled"], "false")
        let claude = try await portal.runtimeDefaults(for: .claudeCompatible)
        XCTAssertEqual(claude.mode, "workspaceWrite")
        XCTAssertEqual(claude.providerSettings["claude.permissionMode"], "acceptEdits")
        XCTAssertEqual(claude.providerSettings["claude.bashEnabled"], "false")
        XCTAssertEqual(claude.providerSettings["claude.strictMCPEnabled"], "true")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("direct-agents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = RepoPromptHeadlessAuthority(
            store: store,
            serverSettings: service,
            directProviderDefaults: portal
        )
        let actor = ExternalActor(userID: "direct", username: "direct", displayName: "Direct")
        let project = try await authority.createProject(
            input: .init(name: "Direct", roots: [.init(logicalName: "root", path: root.path, writable: true)]),
            externalActor: actor,
            idempotencyKey: "direct-project",
            requestDigest: "direct-project"
        )
        let session = try await authority.createSession(
            input: .init(projectID: project.projectID, provider: .codex, visibility: .privateSession),
            externalActor: actor,
            idempotencyKey: "direct-session",
            requestDigest: "direct-session"
        )
        let permissions = try await authority.authoritySessionSnapshot(sessionID: session.sessionID).permissions
        XCTAssertEqual(permissions.mode, "readOnly")
        XCTAssertEqual(permissions.providerSettings["codex.sandbox"], "read-only")
        XCTAssertEqual(permissions.providerSettings["codex.approvalPolicy"], "untrusted")
        XCTAssertEqual(permissions.providerSettings["codex.approvalsReviewer"], "user")
        XCTAssertEqual(permissions.providerSettings["codex.bashEnabled"], "false")
        XCTAssertEqual(permissions.providerSettings["provider.permissionId"], "codex.readOnly")
    }

    func testWorkspaceAutoApproveAllDefaultsOffAndMCPMutationsLiveReadIt() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let catalog = StaticProviderCatalog(response: Self.providerCatalog())
        let service = ServerSettingsService(store: store, providerCatalog: catalog, projectCatalog: store)
        let empty = await service.workspaceApprovals()
        XCTAssertEqual(empty.revision, 0)
        XCTAssertFalse(empty.settings.autoApproveAll)
        XCTAssertTrue(empty.settings.autoApproveOperations.isEmpty)

        let missingJSON = try JSONDecoder.serviceDecoder.decode(
            WorkspaceApprovalSettings.self,
            from: Data("{}".utf8)
        )
        XCTAssertFalse(missingJSON.autoApproveAll)

        let authority = RepoPromptHeadlessAuthority(store: store, serverSettings: service)
        let actor = ExternalActor(userID: "mcp-client", username: "mcp", displayName: "MCP")
        do {
            try await authority.authorizeWorkspaceOperation(.createWorkspace, clientID: actor.userID)
            XCTFail("default-off must not auto-approve workspace create")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .invalidRequest)
            XCTAssertEqual(error.message, WorkspaceApprovalOperation.createWorkspace.deniedByUserMessage)
        }

        let adapter = RepoPromptMCPAdapter(serving: await RepoPromptAuthorityMCPService.admitted(authority: authority, portalSettings: PortalDesktopSettingsService(store: store), admissionGate: AuthorityMutationGate()))
        let projectRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ws-approval-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let project = try await authority.createProject(
            input: .init(name: "Approvals", roots: [.init(logicalName: "root", path: projectRoot.path, writable: true)]),
            externalActor: actor,
            idempotencyKey: "ws-approval-project",
            requestDigest: "ws-approval-project"
        )
        let session = try await authority.createSession(
            input: .init(projectID: project.projectID, provider: .codex, visibility: .privateSession),
            externalActor: actor,
            idempotencyKey: "ws-approval-session",
            requestDigest: "ws-approval-session"
        )
        let binding = RepoPromptMCPBinding(sessionID: session.sessionID, actor: actor)
        do {
            _ = try await adapter.invoke(
                toolName: "manage_workspaces",
                argumentsJSON: JSONSerialization.data(withJSONObject: ["action": "create", "name": "Denied"], options: [.sortedKeys]),
                binding: binding
            )
            XCTFail("MCP create must live-read default-off auto-approve-all")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .invalidRequest)
            XCTAssertEqual(error.message, WorkspaceApprovalOperation.createWorkspace.deniedByUserMessage)
        }

        let written = try await service.replaceWorkspaceApprovals(
            .init(expectedRevision: 0, settings: .init(autoApproveAll: true)),
            attribution: Self.attribution
        )
        XCTAssertEqual(written.revision, 1)
        XCTAssertTrue(written.settings.autoApproveAll)
        try await authority.authorizeWorkspaceOperation(.createWorkspace, clientID: actor.userID)
        try await authority.authorizeWorkspaceOperation(.deleteWorkspace, clientID: actor.userID)
        try await authority.authorizeWorkspaceOperation(.addFolder, clientID: actor.userID)
        try await authority.authorizeWorkspaceOperation(.removeFolder, clientID: actor.userID)
        _ = try await adapter.invoke(
            toolName: "manage_workspaces",
            argumentsJSON: JSONSerialization.data(withJSONObject: ["action": "create", "name": "Allowed"], options: [.sortedKeys]),
            binding: binding
        )
    }

    func testWorkspacePerOperationApprovalsPersistAndLiveReadIndependentlyOfMasterFlag() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let service = ServerSettingsService(
            store: store,
            providerCatalog: StaticProviderCatalog(response: Self.providerCatalog()),
            projectCatalog: store
        )
        let missingJSON = try JSONDecoder.serviceDecoder.decode(
            WorkspaceApprovalSettings.self,
            from: Data("{}".utf8)
        )
        XCTAssertTrue(missingJSON.autoApproveOperations.isEmpty)
        XCTAssertFalse(missingJSON.shouldAutoApprove(operation: .addFolder, clientID: "any"))

        let authority = RepoPromptHeadlessAuthority(store: store, serverSettings: service)
        let actor = ExternalActor(userID: "mcp-client", username: "mcp", displayName: "MCP")
        let enabled = try await authority.setAutoApproveOperation(
            .addFolder,
            enabled: true,
            expectedRevision: 0,
            attribution: Self.attribution
        )
        XCTAssertEqual(enabled.revision, 1)
        XCTAssertFalse(enabled.settings.autoApproveAll)
        XCTAssertEqual(enabled.settings.autoApproveOperations, [.addFolder])

        try await authority.authorizeWorkspaceOperation(.addFolder, clientID: actor.userID)
        do {
            try await authority.authorizeWorkspaceOperation(.createWorkspace, clientID: actor.userID)
            XCTFail("unlisted ops must still deny when master auto-approve is off")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .invalidRequest)
            XCTAssertEqual(error.message, WorkspaceApprovalOperation.createWorkspace.deniedByUserMessage)
        }

        let projectRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ws-per-op-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let project = try await authority.createProject(
            input: .init(name: "PerOp", roots: [.init(logicalName: "root", path: projectRoot.path, writable: true)]),
            externalActor: actor,
            idempotencyKey: "ws-per-op-project",
            requestDigest: "ws-per-op-project"
        )
        let session = try await authority.createSession(
            input: .init(projectID: project.projectID, provider: .codex, visibility: .privateSession),
            externalActor: actor,
            idempotencyKey: "ws-per-op-session",
            requestDigest: "ws-per-op-session"
        )
        let adapter = RepoPromptMCPAdapter(serving: await RepoPromptAuthorityMCPService.admitted(authority: authority, portalSettings: PortalDesktopSettingsService(store: store), admissionGate: AuthorityMutationGate()))
        let binding = RepoPromptMCPBinding(sessionID: session.sessionID, actor: actor)
        _ = try await adapter.invoke(
            toolName: "manage_workspaces",
            argumentsJSON: JSONSerialization.data(withJSONObject: [
                "action": "add_folder",
                "folder_path": projectRoot.path
            ], options: [.sortedKeys]),
            binding: binding
        )
        do {
            _ = try await adapter.invoke(
                toolName: "manage_workspaces",
                argumentsJSON: JSONSerialization.data(withJSONObject: ["action": "delete"], options: [.sortedKeys]),
                binding: binding
            )
            XCTFail("delete must stay denied when only add_folder is listed")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .invalidRequest)
            XCTAssertEqual(error.message, WorkspaceApprovalOperation.deleteWorkspace.deniedByUserMessage)
        }

        let disabled = try await authority.setAutoApproveOperation(
            .addFolder,
            enabled: false,
            expectedRevision: 1,
            attribution: Self.attribution
        )
        XCTAssertTrue(disabled.settings.autoApproveOperations.isEmpty)
        do {
            try await authority.authorizeWorkspaceOperation(.addFolder, clientID: actor.userID)
            XCTFail("clearing the per-op toggle must restore deny")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .invalidRequest)
            XCTAssertEqual(error.message, WorkspaceApprovalOperation.addFolder.deniedByUserMessage)
        }
    }

    func testWorkspaceTrustedClientAlwaysAllowPersistsAndFamilyMatchesIndependentlyOfMasterFlag() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let service = ServerSettingsService(
            store: store,
            providerCatalog: StaticProviderCatalog(response: Self.providerCatalog()),
            projectCatalog: store
        )
        let missingJSON = try JSONDecoder.serviceDecoder.decode(
            WorkspaceApprovalSettings.self,
            from: Data("{}".utf8)
        )
        XCTAssertTrue(missingJSON.clientPolicies.isEmpty)
        XCTAssertFalse(missingJSON.shouldAutoApprove(operation: .createWorkspace, clientID: "claude-code"))

        let authority = RepoPromptHeadlessAuthority(store: store, serverSettings: service)
        let actor = ExternalActor(userID: "mcp-client", username: "mcp", displayName: "MCP")
        let trusted = try await authority.addAutoApproval(
            clientID: "claude-code",
            operation: .createWorkspace,
            expectedRevision: 0,
            attribution: Self.attribution
        )
        XCTAssertEqual(trusted.revision, 1)
        XCTAssertFalse(trusted.settings.autoApproveAll)
        XCTAssertTrue(trusted.settings.autoApproveOperations.isEmpty)
        XCTAssertEqual(Set(trusted.settings.clientPolicies.keys), ["claude-code"])
        XCTAssertEqual(trusted.settings.clientPolicies["claude-code"]?.allowedOperations, [.createWorkspace])

        XCTAssertTrue(trusted.settings.shouldAutoApprove(operation: .createWorkspace, clientID: "Claude Code v2.1"))
        XCTAssertFalse(trusted.settings.shouldAutoApprove(operation: .deleteWorkspace, clientID: "Claude Code v2.1"))
        XCTAssertFalse(trusted.settings.shouldAutoApprove(operation: .createWorkspace, clientID: "my-custom-client"))
        XCTAssertFalse(trusted.settings.shouldAutoApprove(operation: .createWorkspace, clientID: actor.userID))

        try await authority.authorizeWorkspaceOperation(.createWorkspace, clientID: "Claude Code v2.1")
        do {
            try await authority.authorizeWorkspaceOperation(.deleteWorkspace, clientID: "Claude Code v2.1")
            XCTFail("unlisted ops must still deny for a trusted client")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .invalidRequest)
            XCTAssertEqual(error.message, WorkspaceApprovalOperation.deleteWorkspace.deniedByUserMessage)
        }
        do {
            try await authority.authorizeWorkspaceOperation(.createWorkspace, clientID: actor.userID)
            XCTFail("HTTP actor identity must not substitute for MCP client identity")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .invalidRequest)
            XCTAssertEqual(error.message, WorkspaceApprovalOperation.createWorkspace.deniedByUserMessage)
        }

        let projectRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ws-trusted-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let project = try await authority.createProject(
            input: .init(name: "Trusted", roots: [.init(logicalName: "root", path: projectRoot.path, writable: true)]),
            externalActor: actor,
            idempotencyKey: "ws-trusted-project",
            requestDigest: "ws-trusted-project"
        )
        let session = try await authority.createSession(
            input: .init(projectID: project.projectID, provider: .codex, visibility: .privateSession),
            externalActor: actor,
            idempotencyKey: "ws-trusted-session",
            requestDigest: "ws-trusted-session"
        )
        let adapter = RepoPromptMCPAdapter(serving: await RepoPromptAuthorityMCPService.admitted(authority: authority, portalSettings: PortalDesktopSettingsService(store: store), admissionGate: AuthorityMutationGate()))
        let familyBinding = RepoPromptMCPBinding(
            sessionID: session.sessionID,
            actor: actor,
            mcpClientID: "Claude Code v2.1"
        )
        _ = try await adapter.invoke(
            toolName: "manage_workspaces",
            argumentsJSON: JSONSerialization.data(withJSONObject: ["action": "create", "name": "Allowed"], options: [.sortedKeys]),
            binding: familyBinding
        )
        do {
            _ = try await adapter.invoke(
                toolName: "manage_workspaces",
                argumentsJSON: JSONSerialization.data(withJSONObject: ["action": "delete"], options: [.sortedKeys]),
                binding: familyBinding
            )
            XCTFail("delete must stay denied when only create_workspace is trusted for this client")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .invalidRequest)
            XCTAssertEqual(error.message, WorkspaceApprovalOperation.deleteWorkspace.deniedByUserMessage)
        }

        let unknownBinding = RepoPromptMCPBinding(sessionID: session.sessionID, actor: actor)
        do {
            _ = try await adapter.invoke(
                toolName: "manage_workspaces",
                argumentsJSON: JSONSerialization.data(withJSONObject: ["action": "create", "name": "Unknown"], options: [.sortedKeys]),
                binding: unknownBinding
            )
            XCTFail("unknown MCP client must not inherit another client's Always Allow policy")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .invalidRequest)
            XCTAssertEqual(error.message, WorkspaceApprovalOperation.createWorkspace.deniedByUserMessage)
        }
    }

    func testUntrustedIntegrationActorDoesNotInheritTrustedClientAlwaysAllowAndUserCreateStaysUngated() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let service = ServerSettingsService(
            store: store,
            providerCatalog: StaticProviderCatalog(response: Self.providerCatalog()),
            projectCatalog: store
        )
        let authority = RepoPromptHeadlessAuthority(store: store, serverSettings: service)
        let untrusted = ExternalActor(
            userID: "untrusted-chat-host",
            username: "claude-code",
            displayName: "Claude Code v2.1"
        )
        _ = try await authority.addAutoApproval(
            clientID: "claude-code",
            operation: .createWorkspace,
            expectedRevision: 0,
            attribution: Self.attribution
        )
        let trusted = try await authority.workspaceApprovals()
        XCTAssertTrue(
            trusted.settings.shouldAutoApprove(
                operation: .createWorkspace,
                clientID: untrusted.displayName
            )
        )

        let projectRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ws-untrusted-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let project = try await authority.createProject(
            input: .init(name: "Integration", roots: [.init(logicalName: "root", path: projectRoot.path, writable: true)]),
            externalActor: untrusted,
            idempotencyKey: "ws-untrusted-project",
            requestDigest: "ws-untrusted-project"
        )
        XCTAssertEqual(project.name, "Integration")

        let session = try await authority.createSession(
            input: .init(projectID: project.projectID, provider: .codex, visibility: .privateSession),
            externalActor: untrusted,
            idempotencyKey: "ws-untrusted-session",
            requestDigest: "ws-untrusted-session"
        )
        let adapter = RepoPromptMCPAdapter(serving: await RepoPromptAuthorityMCPService.admitted(authority: authority, portalSettings: PortalDesktopSettingsService(store: store), admissionGate: AuthorityMutationGate()))
        let baseline = HeadlessCodexMCPToolPolicy.advertisedToolNames(isRootSession: true)
        let victim = try XCTUnwrap(baseline.sorted().first)
        let kept = try XCTUnwrap(baseline.sorted().first { $0 != victim })
        let untrustedBinding = RepoPromptMCPBinding(
            sessionID: session.sessionID,
            actor: untrusted,
            mcpClientID: RepoPromptMCPBinding.untrustedClientID
        )
        XCTAssertEqual(untrustedBinding.mcpClientID, "unknown-client")
        XCTAssertEqual(RepoPromptMCPBinding(sessionID: session.sessionID, actor: untrusted).mcpClientID, untrustedBinding.mcpClientID)
        do {
            _ = try await adapter.invoke(
                toolName: "manage_workspaces",
                argumentsJSON: JSONSerialization.data(withJSONObject: ["action": "create", "name": "Denied"], options: [.sortedKeys]),
                binding: untrustedBinding
            )
            XCTFail("untrusted chat-host identity must not inherit Desktop Always Allow")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .invalidRequest)
            XCTAssertEqual(error.message, WorkspaceApprovalOperation.createWorkspace.deniedByUserMessage)
        }

        _ = try await authority.setMCPToolEnabled(
            victim,
            enabled: false,
            expectedRevision: 0,
            attribution: Self.attribution
        )
        let advertised = try await adapter.advertisedToolNames(isRootSession: true)
        XCTAssertFalse(advertised.contains(victim))
        XCTAssertTrue(advertised.contains(kept))
        do {
            _ = try await adapter.invoke(
                toolName: victim,
                argumentsJSON: JSONSerialization.data(withJSONObject: ["op": "list"], options: [.sortedKeys]),
                binding: untrustedBinding
            )
            XCTFail("disabled tools must stay omitted for the untrusted MCP binding")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .invalidRequest)
            XCTAssertEqual(error.message, "Tool '\(victim)' is disabled.")
        }
    }

    func testMCPDisabledToolsPersistAndLiveReadOmitsAdvertisedCatalogAndInvoke() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let service = ServerSettingsService(
            store: store,
            providerCatalog: StaticProviderCatalog(response: Self.providerCatalog()),
            projectCatalog: store
        )
        let missingJSON = try JSONDecoder.serviceDecoder.decode(
            MCPDisabledToolsSettings.self,
            from: Data("{}".utf8)
        )
        XCTAssertTrue(missingJSON.disabledTools.isEmpty)
        XCTAssertTrue(missingJSON.isEnabled("manage_workspaces"))

        let authority = RepoPromptHeadlessAuthority(store: store, serverSettings: service)
        let empty = await authority.disabledMCPToolNames()
        XCTAssertTrue(empty.isEmpty)

        let discovered = try await authority.applyMCPToolDefaultOffDiscoveries(
            ["experimental_tool"],
            expectedRevision: 0,
            attribution: Self.attribution
        )
        XCTAssertEqual(discovered.revision, 1)
        XCTAssertEqual(discovered.settings.disabledTools, ["experimental_tool"])
        XCTAssertFalse(discovered.settings.isEnabled("experimental_tool"))
        XCTAssertTrue(discovered.settings.isEnabled("manage_workspaces"))

        let disabled = try await authority.setMCPToolEnabled(
            "manage_workspaces",
            enabled: false,
            expectedRevision: 1,
            attribution: Self.attribution
        )
        XCTAssertEqual(disabled.settings.disabledTools, ["experimental_tool", "manage_workspaces"])

        let actor = ExternalActor(userID: "mcp-tools", username: "mcp", displayName: "MCP")
        let projectRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ws-disabled-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let project = try await authority.createProject(
            input: .init(name: "DisabledTools", roots: [.init(logicalName: "root", path: projectRoot.path, writable: true)]),
            externalActor: actor,
            idempotencyKey: "ws-disabled-project",
            requestDigest: "ws-disabled-project"
        )
        let session = try await authority.createSession(
            input: .init(projectID: project.projectID, provider: .codex, visibility: .privateSession),
            externalActor: actor,
            idempotencyKey: "ws-disabled-session",
            requestDigest: "ws-disabled-session"
        )
        let adapter = RepoPromptMCPAdapter(serving: await RepoPromptAuthorityMCPService.admitted(authority: authority, portalSettings: PortalDesktopSettingsService(store: store), admissionGate: AuthorityMutationGate()))
        let baseline = HeadlessCodexMCPToolPolicy.advertisedToolNames(isRootSession: true)
        XCTAssertFalse(baseline.isEmpty)
        let victim = try XCTUnwrap(baseline.sorted().first)
        let kept = try XCTUnwrap(baseline.sorted().first { $0 != victim })
        let disabledAdvertised = try await authority.setMCPToolEnabled(
            victim,
            enabled: false,
            expectedRevision: 2,
            attribution: Self.attribution
        )
        XCTAssertTrue(disabledAdvertised.settings.disabledTools.contains(victim))
        let advertised = try await adapter.advertisedToolNames(isRootSession: true)
        XCTAssertFalse(advertised.contains(victim))
        XCTAssertTrue(advertised.contains(kept))

        let binding = RepoPromptMCPBinding(sessionID: session.sessionID, actor: actor)
        do {
            _ = try await adapter.invoke(
                toolName: "manage_workspaces",
                argumentsJSON: JSONSerialization.data(withJSONObject: ["action": "list"], options: [.sortedKeys]),
                binding: binding
            )
            XCTFail("disabled tools must not invoke")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .invalidRequest)
            XCTAssertEqual(error.message, "Tool 'manage_workspaces' is disabled.")
        }

        let enabled = try await authority.setMCPToolEnabled(
            "manage_workspaces",
            enabled: true,
            expectedRevision: 3,
            attribution: Self.attribution
        )
        XCTAssertFalse(enabled.settings.disabledTools.contains("manage_workspaces"))
        XCTAssertTrue(enabled.settings.disabledTools.contains(victim))
        _ = try await adapter.invoke(
            toolName: "manage_workspaces",
            argumentsJSON: JSONSerialization.data(withJSONObject: ["action": "list"], options: [.sortedKeys]),
            binding: binding
        )
        let restoredVictim = try await authority.setMCPToolEnabled(
            victim,
            enabled: true,
            expectedRevision: 4,
            attribution: Self.attribution
        )
        XCTAssertFalse(restoredVictim.settings.disabledTools.contains(victim))
        let restored = try await adapter.advertisedToolNames(isRootSession: true)
        XCTAssertTrue(restored.contains(victim))
        XCTAssertEqual(restored, baseline)
    }

    func testMCPShowModelPresetsDefaultsOffAndListModelsLiveReadsTheGate() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let service = ServerSettingsService(
            store: store,
            providerCatalog: StaticProviderCatalog(response: Self.providerCatalog()),
            projectCatalog: store
        )
        let missingJSON = try JSONDecoder.serviceDecoder.decode(
            MCPShowModelPresetsSettings.self,
            from: Data("{}".utf8)
        )
        XCTAssertFalse(missingJSON.showModelPresets)

        let authority = RepoPromptHeadlessAuthority(store: store, serverSettings: service)
        let actor = ExternalActor(userID: "mcp-presets", username: "mcp", displayName: "MCP")
        let projectRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ws-presets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let project = try await authority.createProject(
            input: .init(name: "Presets", roots: [.init(logicalName: "root", path: projectRoot.path, writable: true)]),
            externalActor: actor,
            idempotencyKey: "ws-presets-project",
            requestDigest: "ws-presets-project"
        )
        let session = try await authority.createSession(
            input: .init(projectID: project.projectID, provider: .codex, visibility: .privateSession),
            externalActor: actor,
            idempotencyKey: "ws-presets-session",
            requestDigest: "ws-presets-session"
        )
        let presetID = UUID()
        _ = try await service.replaceModelPresets(
            .init(expectedRevision: 0, presets: [.init(
                presetID: presetID,
                name: "Review",
                target: .init(providerID: .codex, modelID: "gpt-5.6-sol"),
                availability: [.review],
                order: 0
            )]),
            attribution: Self.attribution
        )
        let hiddenDiscovery = try await service.modelDiscovery(projectID: project.projectID)
        XCTAssertTrue(hiddenDiscovery.presets.isEmpty)

        let adapter = RepoPromptMCPAdapter(serving: await RepoPromptAuthorityMCPService.admitted(authority: authority, portalSettings: PortalDesktopSettingsService(store: store), admissionGate: AuthorityMutationGate()))
        let binding = RepoPromptMCPBinding(sessionID: session.sessionID, actor: actor)
        func invoke(tool: String, _ object: [String: Any]) async throws -> [String: Any] {
            let data = try await adapter.invoke(
                toolName: tool,
                argumentsJSON: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                binding: binding
            )
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        let unread = try await invoke(tool: "app_settings", ["op": "get", "key": "mcp.show_model_presets"])
        XCTAssertEqual(unread["key"] as? String, "mcp.show_model_presets")
        XCTAssertEqual(unread["value"] as? Bool, false)
        let listedOff = try await invoke(tool: "oracle_utils", ["op": "models"])
        XCTAssertEqual((listedOff["presets"] as? [[String: Any]])?.count, 0)

        let written = try await invoke(tool: "app_settings", [
            "op": "set",
            "key": "mcp.show_model_presets",
            "value": true
        ])
        XCTAssertEqual(written["value"] as? Bool, true)
        let enabled = try await authority.showModelPresets()
        XCTAssertTrue(enabled.settings.showModelPresets)
        let listedOn = try await invoke(tool: "oracle_utils", ["op": "models"])
        let advertised = try XCTUnwrap(listedOn["presets"] as? [[String: Any]])
        XCTAssertEqual(advertised.count, 1)
        XCTAssertEqual(advertised.first?["presetID"] as? String, presetID.uuidString)
    }

    func testSubagentCustomEmptyCodexDefaultsToDefaultPermissionAndInheritUsesLiveDirectAgents() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let service = ServerSettingsService(
            store: store,
            providerCatalog: StaticProviderCatalog(response: Self.providerCatalog()),
            projectCatalog: store
        )
        XCTAssertEqual(SubagentPermissionSettings.safeManaged.codex, .defaultPermission)
        let inheritedDefaults = StaticDirectProviderDefaults(values: [
            .codex: .init(mode: "fullAccess", providerSettings: [
                "codex.sandbox": "danger-full-access",
                "codex.approvalPolicy": "never",
                "codex.bashEnabled": "false"
            ])
        ])
        let resolver = SubagentPermissionResolver(settings: service, directDefaults: inheritedDefaults)
        _ = try await service.replaceSubagentPermissions(
            .init(expectedRevision: 0, settings: .init(policy: .inheritProviderSettings)),
            attribution: Self.attribution
        )
        let inherited = await resolver.resolve(providerID: .codex)
        XCTAssertEqual(inherited.mode, "fullAccess")
        XCTAssertEqual(inherited.providerSettings["codex.sandbox"], "danger-full-access")
        XCTAssertEqual(inherited.providerSettings["codex.bashEnabled"], "false")

        _ = try await service.replaceSubagentPermissions(
            .init(expectedRevision: 1, settings: .init(policy: .custom)),
            attribution: Self.attribution
        )
        let customEmpty = await resolver.resolve(providerID: .codex)
        XCTAssertEqual(customEmpty.mode, "workspaceWrite")
        XCTAssertEqual(customEmpty.providerSettings["codex.sandbox"], "workspace-write")
        XCTAssertEqual(customEmpty.providerSettings["codex.approvalPolicy"], "on-request")
        XCTAssertEqual(customEmpty.providerSettings["codex.approvalsReviewer"], "user")
        XCTAssertEqual(customEmpty.providerSettings["codex.bashEnabled"], "false")
        XCTAssertEqual(customEmpty.providerSettings["provider.permissionId"], "codex.defaultPermission")
    }

    func testLegacyContextBuilderPromptsDecodeSafelyAndAreIgnored() async throws {
        let legacy = Data("""
        {
          "mode": "projectOverride",
          "profile": {
            "budget": 100000,
            "enhancementMode": "augment",
            "questionTimeoutSeconds": 120,
            "portalClarifyingQuestions": false,
            "mcpClarifyingQuestions": true,
            "followUpAnalysis": "review",
            "followUpBudget": 80000,
            "prompts": [{
              "promptID": "00000000-0000-4000-8000-000000000001",
              "name": "Legacy",
              "instructions": "LEGACY_SAVED_PROMPT_MUST_NOT_RUN",
              "enabled": true,
              "order": 0
            }]
          }
        }
        """.utf8)
        let scope = try JSONDecoder.serviceDecoder.decode(ContextBuilderScopeDocument.self, from: legacy)
        XCTAssertEqual(scope.mode, .projectOverride)
        let profile = try XCTUnwrap(scope.profile)
        XCTAssertEqual(profile.budget, 100_000)
        XCTAssertEqual(profile.enhancementMode, .augment)
        XCTAssertEqual(profile.questionTimeoutSeconds, 120)
        XCTAssertFalse(profile.portalClarifyingQuestions)
        XCTAssertTrue(profile.mcpClarifyingQuestions)
        XCTAssertEqual(profile.followUpAnalysis, .review)
        XCTAssertEqual(profile.followUpBudget, 80_000)

        let encoded = try JSONEncoder.serviceEncoder.encode(scope)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let encodedProfile = try XCTUnwrap(object["profile"] as? [String: Any])
        XCTAssertNil(encodedProfile["prompts"], "removed saved prompts must not survive a decode/encode cycle")

        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let service = ServerSettingsService(
            store: store,
            providerCatalog: StaticProviderCatalog(response: Self.providerCatalog()),
            projectCatalog: StaticProjectCatalog(roots: [:])
        )
        let effective = EffectiveContextBuilderSettings(
            budget: profile.budget,
            enhancementMode: profile.enhancementMode,
            allowClarifyingQuestions: profile.mcpClarifyingQuestions,
            questionTimeoutSeconds: profile.questionTimeoutSeconds,
            followUpAnalysis: profile.followUpAnalysis,
            followUpBudget: profile.followUpBudget
        )
        let rendered = try await service.renderContextBuilderInstructions("Caller", effective: effective)
        XCTAssertEqual(rendered, "Caller")
        XCTAssertFalse(rendered.contains("LEGACY_SAVED_PROMPT_MUST_NOT_RUN"))
    }

    func testContextBuilderInvocationPayloadRetainsProtectedFields() throws {
        let input = ContextBuilderInput(
            expectedSelectionRevision: 7,
            instructions: "Inspect",
            budget: 125_000,
            responseType: "question",
            allowClarifyingQuestions: true,
            enhancementMode: .preserve,
            questionTimeoutSeconds: 300,
            followUpAnalysis: .question,
            followUpBudget: 85_000
        )
        let encoded = try JSONEncoder.serviceEncoder.encode(input)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set([
            "expectedSelectionRevision", "instructions", "budget", "responseType",
            "allowClarifyingQuestions", "enhancementMode", "questionTimeoutSeconds",
            "followUpAnalysis", "followUpBudget"
        ]))
        XCTAssertNil(object["selectedPromptIDs"])

        let decoded = try JSONDecoder.serviceDecoder.decode(ContextBuilderInput.self, from: encoded)
        XCTAssertEqual(decoded.expectedSelectionRevision, 7)
        XCTAssertEqual(decoded.instructions, "Inspect")
        XCTAssertEqual(decoded.budget, 125_000)
        XCTAssertEqual(decoded.responseType, "question")
        XCTAssertEqual(decoded.allowClarifyingQuestions, true)
        XCTAssertEqual(decoded.enhancementMode, .preserve)
        XCTAssertEqual(decoded.questionTimeoutSeconds, 300)
        XCTAssertEqual(decoded.followUpAnalysis, .question)
        XCTAssertEqual(decoded.followUpBudget, 85_000)
    }

    func testSettingsPersistAcrossRestartAndProjectInheritanceIsDeterministic() async throws {
        let database = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
        defer { removeSQLiteFiles(database) }
        let projectID = UUID()
        let rootID = UUID()
        let catalogs = StaticProviderCatalog(response: Self.providerCatalog())
        let projects = StaticProjectCatalog(roots: [projectID: [rootID]])
        let attribution = Self.attribution
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)

        var store = try await SQLiteServiceStore.open(storage: .file(database.path))
        try await persistProject(projectID: projectID, rootID: rootID, store: store)
        var service = ServerSettingsService(store: store, providerCatalog: catalogs, projectCatalog: projects, now: { timestamp })

        let globalTarget = AgentModelTarget(providerID: .codex, modelID: "gpt-5.6-sol", reasoningEffort: "high", pinned: true)
        let global = try await service.replaceGlobalAgentModels(
            .init(expectedRevision: 0, profile: .init(oracle: globalTarget, restrictDiscoveryToRoleModels: true)),
            attribution: attribution
        )
        XCTAssertEqual(global.globalRevision, 1)
        let inherited = try await service.agentModels(projectID: projectID)
        XCTAssertEqual(inherited.projectMode, .inheritGlobal)
        XCTAssertEqual(inherited.effectiveProfile, global.globalProfile)

        let projectTarget = AgentModelTarget(providerID: .claudeCompatible, modelID: "claude-opus-5", pinned: false)
        let overridden = try await service.replaceProjectAgentModels(
            projectID: projectID,
            request: .init(expectedRevision: 0, mode: .projectOverride, profile: .init(oracle: projectTarget)),
            attribution: attribution
        )
        XCTAssertEqual(overridden.effectiveProfile.oracle, projectTarget)

        do {
            _ = try await service.copyGlobalAgentModelsToProject(
                projectID: projectID,
                request: .init(expectedGlobalRevision: 0, expectedProjectRevision: 1),
                attribution: attribution
            )
            XCTFail("expected stale source revision")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .staleRevision)
        }
        let copied = try await service.copyGlobalAgentModelsToProject(
            projectID: projectID,
            request: .init(expectedGlobalRevision: 1, expectedProjectRevision: 1),
            attribution: attribution
        )
        XCTAssertEqual(copied.projectRevision, 2)
        XCTAssertEqual(copied.effectiveProfile, global.globalProfile)
        do {
            _ = try await service.copyGlobalAgentModelsToProject(
                projectID: projectID,
                request: .init(expectedGlobalRevision: 1, expectedProjectRevision: 1),
                attribution: attribution
            )
            XCTFail("expected stale destination revision")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .staleRevision)
            XCTAssertEqual(error.currentRevision, 2)
        }

        let inheritedAgain = try await service.replaceProjectAgentModels(
            projectID: projectID,
            request: .init(expectedRevision: 2, mode: .inheritGlobal, profile: nil),
            attribution: attribution
        )
        XCTAssertEqual(inheritedAgain.projectMode, .inheritGlobal)
        XCTAssertEqual(inheritedAgain.projectProfile, global.globalProfile)
        XCTAssertEqual(inheritedAgain.effectiveProfile, global.globalProfile)

        let restoredOverride = try await service.replaceProjectAgentModels(
            projectID: projectID,
            request: .init(expectedRevision: 3, mode: .projectOverride, profile: nil),
            attribution: attribution
        )
        XCTAssertEqual(restoredOverride.projectMode, .projectOverride)
        XCTAssertEqual(restoredOverride.projectProfile, global.globalProfile)
        XCTAssertEqual(restoredOverride.effectiveProfile, global.globalProfile)

        let projectOwned = try await service.replaceProjectAgentModels(
            projectID: projectID,
            request: .init(expectedRevision: 4, mode: .projectOverride, profile: .init(oracle: projectTarget)),
            attribution: attribution
        )
        XCTAssertEqual(projectOwned.effectiveProfile.oracle, projectTarget)
        do {
            _ = try await service.copyProjectAgentModelsToGlobal(
                projectID: projectID,
                request: .init(expectedGlobalRevision: 0, expectedProjectRevision: 5),
                attribution: attribution
            )
            XCTFail("expected stale global revision")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .staleRevision)
        }
        let published = try await service.copyProjectAgentModelsToGlobal(
            projectID: projectID,
            request: .init(expectedGlobalRevision: 1, expectedProjectRevision: 5),
            attribution: attribution
        )
        XCTAssertEqual(published.globalRevision, 2)
        XCTAssertEqual(published.globalProfile.oracle, projectTarget)
        XCTAssertEqual(published.effectiveProfile.oracle, projectTarget)
        XCTAssertEqual(published.projectMode, .projectOverride)

        _ = try await service.replaceGlobalContextBuilder(
            .init(expectedRevision: 0, profile: .init(budget: 100_000)),
            attribution: attribution
        )
        let context = try await service.copyGlobalContextBuilderToProject(
            projectID: projectID,
            request: .init(expectedGlobalRevision: 1, expectedProjectRevision: 0),
            attribution: attribution
        )
        XCTAssertEqual(context.effectiveProfile.budget, 100_000)
        XCTAssertEqual(context.projectMode, .projectOverride)
        XCTAssertEqual(context.projectProfile, context.globalProfile)

        _ = try await service.replaceSubagentPermissions(
            .init(expectedRevision: 0, settings: .init(policy: .custom, codex: .readOnly)),
            attribution: attribution
        )
        _ = try await service.replaceDirectAgentPermissions(
            .init(
                expectedRevision: 0,
                settings: .init(
                    codex: .init(sandboxMode: .readOnly, approvalPolicy: .onRequest, approvalReviewer: .user, bashEnabled: false),
                    claude: .init(permissionMode: .auto, bashEnabled: true, mcpStrictModeEnabled: true)
                )
            ),
            attribution: attribution
        )
        _ = try await service.replaceModelPresets(
            .init(expectedRevision: 0, presets: [
                .init(
                    presetID: UUID(),
                    name: "Primary Review",
                    target: globalTarget,
                    availability: [.review, .plan],
                    order: 9
                )
            ]),
            attribution: attribution
        )
        _ = try await service.replaceAdvanced(
            .init(expectedRevision: 0, settings: .init(codeMapsEnabled: false, historyIdleThresholdMinutes: 12)),
            attribution: attribution
        )
        _ = try await service.replaceSelectionPresets(
            projectID: projectID,
            request: .init(expectedRevision: 0, presets: [
                .init(
                    presetID: UUID(),
                    projectID: projectID,
                    name: "Sources",
                    entries: [.init(rootID: rootID, logicalPath: "Sources", mode: .full)],
                    order: 7,
                    rowRevision: 1
                )
            ]),
            attribution: attribution
        )

        try await store.close()
        store = try await SQLiteServiceStore.open(storage: .file(database.path))
        service = ServerSettingsService(store: store, providerCatalog: catalogs, projectCatalog: projects, now: { timestamp })

        let recoveredAgentModels = try await service.agentModels(projectID: projectID)
        XCTAssertEqual(recoveredAgentModels.globalRevision, 2)
        XCTAssertEqual(recoveredAgentModels.projectRevision, 5)
        XCTAssertEqual(recoveredAgentModels.projectMode, .projectOverride)
        XCTAssertEqual(recoveredAgentModels.effectiveProfile.oracle, projectTarget)
        XCTAssertEqual(recoveredAgentModels.globalProfile.oracle, projectTarget)
        let recoveredContextBuilder = try await service.contextBuilder(projectID: projectID)
        let recoveredSubagents = await service.subagentPermissions()
        let recoveredDirectAgents = await service.directAgentPermissions()
        let recoveredModelPresets = try await service.modelPresets()
        let recoveredAdvanced = try await service.advanced()
        let recoveredSelectionPresets = try await service.selectionPresets(projectID: projectID)
        let recoveredMetadata = try await store.metadata()
        let operational = try await store.operationalSnapshot()
        XCTAssertEqual(recoveredContextBuilder.projectRevision, 1)
        XCTAssertEqual(recoveredSubagents.settings.policy, .custom)
        XCTAssertEqual(recoveredDirectAgents.settings.codex.sandboxMode, .readOnly)
        XCTAssertEqual(recoveredDirectAgents.settings.codex.approvalReviewer, .user)
        XCTAssertFalse(recoveredDirectAgents.settings.codex.bashEnabled)
        XCTAssertEqual(recoveredDirectAgents.settings.claude.permissionMode, .auto)
        XCTAssertTrue(recoveredDirectAgents.settings.claude.mcpStrictModeEnabled)
        XCTAssertEqual(recoveredModelPresets.presets.first?.order, 0)
        XCTAssertFalse(recoveredAdvanced.settings.codeMapsEnabled)
        XCTAssertEqual(recoveredSelectionPresets.presets.first?.name, "Sources")
        XCTAssertEqual(recoveredMetadata.schemaVersion, SchemaV7.version)
        XCTAssertTrue(operational.migrationsValid)
        try await store.close()
    }

    func testStaleMutationHasNoWriteAndAuditContainsOnlyDigestAndAttribution() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let service = ServerSettingsService(
            store: store,
            providerCatalog: StaticProviderCatalog(response: Self.providerCatalog()),
            projectCatalog: StaticProjectCatalog(roots: [:]),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        _ = try await service.replaceAdvanced(
            .init(expectedRevision: 0, settings: .init(codeMapsEnabled: false, historyIdleThresholdMinutes: 17)),
            attribution: Self.attribution
        )
        do {
            _ = try await service.replaceAdvanced(
                .init(expectedRevision: 0, settings: .init(codeMapsEnabled: true, historyIdleThresholdMinutes: 3)),
                attribution: Self.attribution
            )
            XCTFail("expected stale revision")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .staleRevision)
            XCTAssertEqual(error.currentRevision, 1)
        }

        let snapshot = try await service.advanced()
        XCTAssertEqual(snapshot.revision, 1)
        XCTAssertFalse(snapshot.settings.codeMapsEnabled)
        XCTAssertEqual(snapshot.settings.historyIdleThresholdMinutes, 17)
        let audits = try await store.settingsAuditRecords(domain: .advanced, scopeID: "global")
        XCTAssertEqual(audits.count, 1)
        XCTAssertEqual(audits[0].actorID, Self.attribution.actorID)
        XCTAssertEqual(audits[0].payloadDigest.count, 64)
        let auditJSON = String(decoding: try JSONEncoder.serviceEncoder.encode(audits), as: UTF8.self)
        XCTAssertFalse(auditJSON.contains("historyIdleThresholdMinutes"))
        XCTAssertFalse(auditJSON.contains("codeMapsEnabled"))
    }

    func testValidationRejectsBoundsUnknownModelsAndUnauthorizedRoots() async throws {
        let projectID = UUID()
        let rootID = UUID()
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        try await persistProject(projectID: projectID, rootID: rootID, store: store)
        let service = ServerSettingsService(
            store: store,
            providerCatalog: StaticProviderCatalog(response: Self.providerCatalog()),
            projectCatalog: StaticProjectCatalog(roots: [projectID: [rootID]])
        )

        do {
            _ = try await service.replaceGlobalContextBuilder(
                .init(expectedRevision: 0, profile: .init(budget: 12_000)),
                attribution: Self.attribution
            )
            XCTFail("budget increment must be enforced")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .invalidRequest)
        }
        do {
            _ = try await service.replaceModelPresets(
                .init(expectedRevision: 0, presets: [
                    .init(
                        presetID: UUID(),
                        name: "Unknown",
                        target: .init(providerID: .codex, modelID: "not-advertised"),
                        availability: [.chat],
                        order: 0
                    )
                ]),
                attribution: Self.attribution
            )
            XCTFail("unknown model must be rejected")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .invalidRequest)
        }
        do {
            let target = AgentModelTarget(providerID: .codex, modelID: "gpt-5.6-sol", reasoningEffort: "low")
            _ = try await service.replaceModelPresets(
                .init(expectedRevision: 0, presets: [
                    .init(presetID: UUID(), name: "Duplicate", target: target, availability: [.chat], order: 0),
                    .init(presetID: UUID(), name: "duplicate", target: target, availability: [.plan], order: 1)
                ]),
                attribution: Self.attribution
            )
            XCTFail("case-folded duplicate names must be rejected")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .invalidRequest)
        }
        do {
            _ = try await service.replaceSelectionPresets(
                projectID: projectID,
                request: .init(expectedRevision: 0, presets: [
                    .init(
                        presetID: UUID(),
                        projectID: projectID,
                        name: "Escaped",
                        entries: [.init(rootID: UUID(), logicalPath: "Sources", mode: .full)],
                        order: 0,
                        rowRevision: 1
                    )
                ]),
                attribution: Self.attribution
            )
            XCTFail("foreign root must be rejected")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .rootUnauthorized)
        }
    }

    func testLegacyTypedKeysRemainReadableButCannotBeMutated() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        var values = PortalDesktopSettingKey.defaultValues
        values[PortalDesktopSettingKey.contextBuilderBudget.rawValue] = "120000"
        _ = try await store.upsertPortalDesktopSettings(
            .init(revision: 1, values: values, updatedAt: Date()),
            expectedRevision: 0
        )
        let service = PortalDesktopSettingsService(store: store)
        let legacySnapshot = try await service.snapshot()
        XCTAssertEqual(legacySnapshot.values[PortalDesktopSettingKey.contextBuilderBudget.rawValue], "120000")
        XCTAssertEqual(PortalDesktopSettingKey.contextBuilderBudget.mutability, .supersededByTypedSettings)
        XCTAssertEqual(PortalDesktopSettingKey.codexPermissionLevel.mutability, .supersededByTypedSettings)
        XCTAssertEqual(PortalDesktopSettingKey.mcpUseModelPresets.mutability, .supersededByTypedSettings)
        XCTAssertEqual(PortalDesktopSettingKey.mcpDisabledTools.mutability, .supersededByTypedSettings)
        XCTAssertEqual(PortalDesktopSettingKey.workspaceApprovalsGlobal.mutability, .supersededByTypedSettings)
        XCTAssertEqual(PortalDesktopSettingKey.workspaceApprovalOperations.mutability, .supersededByTypedSettings)
        XCTAssertEqual(PortalDesktopSettingKey.mcpUseModelPresets.defaultValue, "false")
        XCTAssertFalse(PortalDesktopSettingKey.codexPermissionLevel.isMutable)

        do {
            _ = try await service.update(.init(expectedRevision: 1, changes: [
                PortalDesktopSettingKey.contextBuilderBudget.rawValue: "125000"
            ]))
            XCTFail("legacy typed key must be read-only")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .capabilityMissing)
        }
        let unchanged = try await service.snapshot()
        XCTAssertEqual(unchanged.revision, 1)
    }

    func testRuntimeRouteResolutionContextDefaultsPresetsAndDiscovery() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let projectID = UUID()
        let rootID = UUID()
        try await persistProject(projectID: projectID, rootID: rootID, store: store)
        let service = ServerSettingsService(
            store: store,
            providerCatalog: StaticProviderCatalog(response: Self.providerCatalog()),
            projectCatalog: StaticProjectCatalog(roots: [projectID: [rootID]])
        )
        do {
            _ = try await service.resolveAgentTarget(projectID: projectID, target: .oracle)
            XCTFail("unconfigured Oracle must fail-closed")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .invalidRequest)
            XCTAssertTrue(error.message.contains("not configured"))
        }
        do {
            _ = try await service.resolveAgentTarget(projectID: projectID, target: .contextBuilder)
            XCTFail("unconfigured Context Builder must fail-closed")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .invalidRequest)
            XCTAssertTrue(error.message.contains("not configured"))
        }
        let applied = try await service.applyGlobalAgentModelRecommendations(
            .init(expectedRevision: 0),
            attribution: Self.attribution
        )
        XCTAssertNotNil(applied.effectiveProfile.oracle)
        XCTAssertNotNil(applied.effectiveProfile.contextBuilder)
        XCTAssertNil(applied.effectiveProfile.explore)
        XCTAssertNil(applied.effectiveProfile.engineer)
        XCTAssertNil(applied.effectiveProfile.pair)
        XCTAssertNil(applied.effectiveProfile.design)

        for target in AgentRoutingTarget.allCases {
            let resolved = try await service.resolveAgentTarget(projectID: projectID, target: target)
            let route = try XCTUnwrap(resolved)
            XCTAssertEqual(route.routingTarget, target)
            XCTAssertNotEqual(route.providerID, .openCodeACP)
            XCTAssertEqual(route.usedRecommendationFallback, target.isSubagentRole)
        }

        _ = try await service.replaceGlobalContextBuilder(
            .init(expectedRevision: 0, profile: .init(
                budget: 120_000,
                enhancementMode: .augment,
                questionTimeoutSeconds: 120,
                portalClarifyingQuestions: false,
                mcpClarifyingQuestions: true,
                followUpAnalysis: .review,
                followUpBudget: 60_000
            )),
            attribution: Self.attribution
        )
        let portal = try await service.resolveContextBuilder(projectID: projectID, origin: .portal)
        let mcp = try await service.resolveContextBuilder(
            projectID: projectID,
            origin: .mcp,
            overrides: .init(budget: 80_000, allowClarifyingQuestions: false)
        )
        XCTAssertFalse(portal.allowClarifyingQuestions)
        let defaultMCP = try await service.resolveContextBuilder(projectID: projectID, origin: .mcp)
        XCTAssertTrue(defaultMCP.allowClarifyingQuestions, "MCP Context Builder must consume mcpClarifyingQuestions")
        XCTAssertFalse(mcp.allowClarifyingQuestions, "an explicit invocation override retains precedence")
        XCTAssertEqual(mcp.budget, 80_000)
        XCTAssertEqual(mcp.enhancementMode, .augment)
        XCTAssertEqual(mcp.questionTimeoutSeconds, 120)
        XCTAssertEqual(mcp.followUpAnalysis, .review)
        XCTAssertEqual(mcp.followUpBudget, 60_000)
        let rendered = try await service.renderContextBuilderInstructions("Caller", effective: mcp)
        XCTAssertEqual(rendered, "Caller")

        let presetID = UUID()
        _ = try await service.replaceModelPresets(
            .init(expectedRevision: 0, presets: [.init(
                presetID: presetID,
                name: "Oracle Review",
                target: .init(providerID: .codex, modelID: "gpt-5.6-sol", reasoningEffort: "high"),
                availability: [.review],
                order: 0
            )]),
            attribution: Self.attribution
        )
        let hidden = try await service.modelDiscovery(projectID: projectID)
        XCTAssertTrue(hidden.presets.isEmpty, "mcp.show_model_presets defaults off")
        do {
            _ = try await service.resolveModelPreset(presetID: presetID, availability: .review)
            XCTFail("named presets must not resolve while the advertisement gate is off")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .invalidRequest)
        }
        _ = try await service.setShowModelPresets(true, expectedRevision: 0, attribution: Self.attribution)
        let presetRoute = try await service.resolveModelPreset(presetID: presetID, availability: .review)
        XCTAssertEqual(presetRoute.providerID, .codex)
        XCTAssertEqual(presetRoute.reasoningEffort, "high")
        let discovery = try await service.modelDiscovery(projectID: projectID)
        XCTAssertEqual(discovery.presets.map(\.presetID), [presetID])
    }

    func testContextBuilderRemembersPerAgentModelAndFailClosesWhenUnconfigured() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let projectID = UUID()
        let rootID = UUID()
        try await persistProject(projectID: projectID, rootID: rootID, store: store)
        let service = ServerSettingsService(
            store: store,
            providerCatalog: StaticProviderCatalog(response: Self.providerCatalog()),
            projectCatalog: StaticProjectCatalog(roots: [projectID: [rootID]])
        )

        let codex = AgentModelTarget(providerID: .codex, modelID: "gpt-5.6-sol", reasoningEffort: "high")
        let first = try await service.replaceGlobalAgentModels(
            .init(expectedRevision: 0, profile: .init(contextBuilder: codex)),
            attribution: Self.attribution
        )
        XCTAssertEqual(first.effectiveProfile.contextBuilderModelsByAgent?[ProviderSettingsID.codex.rawValue], "gpt-5.6-sol")

        let claude = AgentModelTarget(providerID: .claudeCompatible, modelID: "claude-opus-5")
        let switched = try await service.replaceGlobalAgentModels(
            .init(
                expectedRevision: first.globalRevision,
                profile: first.effectiveProfile.replacing(.contextBuilder, with: claude)
            ),
            attribution: Self.attribution
        )
        XCTAssertEqual(switched.effectiveProfile.contextBuilder?.providerID, .claudeCompatible)
        XCTAssertEqual(switched.effectiveProfile.contextBuilderModelsByAgent?[ProviderSettingsID.codex.rawValue], "gpt-5.6-sol")
        XCTAssertEqual(switched.effectiveProfile.contextBuilderModelsByAgent?[ProviderSettingsID.claudeCompatible.rawValue], "claude-opus-5")

        let restored = try await service.replaceGlobalAgentModels(
            .init(
                expectedRevision: switched.globalRevision,
                profile: switched.effectiveProfile.replacing(
                    .contextBuilder,
                    with: AgentModelTarget(providerID: .codex)
                )
            ),
            attribution: Self.attribution
        )
        XCTAssertEqual(restored.effectiveProfile.contextBuilder?.providerID, .codex)
        XCTAssertEqual(restored.effectiveProfile.contextBuilder?.modelID, "gpt-5.6-sol")
        let route = try await service.resolveAgentTarget(projectID: projectID, target: .contextBuilder)
        XCTAssertEqual(try XCTUnwrap(route).modelID, "gpt-5.6-sol")
        XCTAssertFalse(try XCTUnwrap(route).usedRecommendationFallback)

        let cleared = try await service.replaceGlobalAgentModels(
            .init(
                expectedRevision: restored.globalRevision,
                profile: restored.effectiveProfile.replacing(.contextBuilder, with: nil)
            ),
            attribution: Self.attribution
        )
        do {
            _ = try await service.resolveAgentTarget(projectID: projectID, target: .contextBuilder)
            XCTFail("cleared Context Builder must fail-closed")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .invalidRequest)
        }
        XCTAssertEqual(cleared.effectiveProfile.contextBuilderModelsByAgent?[ProviderSettingsID.codex.rawValue], "gpt-5.6-sol")
    }

    func testRoleDefaultsTrackRecommendationsStickWhenAssignedAndFailClosedWhenEmpty() async throws {
        let omitted = try MCPAgentStartTarget.resolve(modelID: nil, defaultRole: "pair")
        XCTAssertEqual(omitted.role, "pair")
        XCTAssertNil(omitted.provider)
        XCTAssertNil(omitted.model)

        let explore = try MCPAgentStartTarget.resolve(modelID: "explore", defaultRole: "pair")
        XCTAssertEqual(explore.role, "explore")

        let compound = try MCPAgentStartTarget.resolve(modelID: "claudeCode:sonnet", defaultRole: "pair")
        XCTAssertEqual(compound.role, "child")
        XCTAssertEqual(compound.providerSettingsID, .claudeCompatible)
        XCTAssertEqual(compound.model, "sonnet")

        let native = try MCPAgentStartTarget.resolve(modelID: "codex:gpt-5.6-sol", defaultRole: "pair")
        XCTAssertEqual(native.role, "child")
        XCTAssertEqual(native.providerSettingsID, .codex)
        XCTAssertEqual(native.model, "gpt-5.6-sol")

        do {
            _ = try MCPAgentStartTarget.resolve(modelID: "not-a-role", defaultRole: "pair")
            XCTFail("unknown model_id without a colon must fail-closed")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .invalidRequest)
        }

        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let catalog = StaticProviderCatalog(response: Self.providerCatalog())
        let service = ServerSettingsService(
            store: store,
            providerCatalog: catalog,
            projectCatalog: store
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("role-defaults-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = RepoPromptHeadlessAuthority(store: store, serverSettings: service)
        let actor = ExternalActor(userID: "roles", username: "roles", displayName: "Roles")
        let project = try await authority.createProject(
            input: .init(name: "Roles", roots: [.init(logicalName: "root", path: root.path, writable: true)]),
            externalActor: actor,
            idempotencyKey: "roles-project",
            requestDigest: "roles-project"
        )
        let projectID = project.projectID

        let unassignedPairRoute = try await service.resolveAgentTarget(projectID: projectID, target: .pair)
        let unassignedPair = try XCTUnwrap(unassignedPairRoute)
        XCTAssertEqual(unassignedPair.providerID, .codex)
        XCTAssertEqual(unassignedPair.modelID, "gpt-5.6-sol")
        XCTAssertEqual(unassignedPair.reasoningEffort, "high")
        XCTAssertTrue(unassignedPair.usedRecommendationFallback)

        let unassignedExploreRoute = try await service.resolveAgentTarget(projectID: projectID, target: .explore)
        let unassignedExplore = try XCTUnwrap(unassignedExploreRoute)
        XCTAssertEqual(unassignedExplore.providerID, .codex)
        XCTAssertEqual(unassignedExplore.reasoningEffort, "low")
        XCTAssertTrue(unassignedExplore.usedRecommendationFallback)
        let parent = try await authority.createSession(
            input: .init(
                projectID: project.projectID,
                provider: .claudeCompatible,
                model: "claude-opus-5",
                visibility: .privateSession
            ),
            externalActor: actor,
            idempotencyKey: "roles-parent",
            requestDigest: "roles-parent"
        )

        let pairChild = try await authority.spawnChildSession(
            parentSessionID: parent.sessionID,
            initialPrompt: "pair",
            role: "pair"
        )
        XCTAssertEqual(pairChild.provider, .codex)
        XCTAssertEqual(pairChild.providerSettingsID, .codex)
        XCTAssertEqual(pairChild.model, "gpt-5.6-sol")
        XCTAssertNotEqual(pairChild.model, parent.model)

        let explicit = try await authority.spawnChildSession(
            parentSessionID: parent.sessionID,
            providerSettingsID: .claudeGLM,
            initialPrompt: "explicit"
        )
        XCTAssertEqual(explicit.providerSettingsID, .claudeGLM)
        XCTAssertEqual(explicit.provider, .claudeCompatible)

        let matchingRecommendation = AgentModelTarget(providerID: .codex, modelID: "gpt-5.6-sol", reasoningEffort: "high")
        let assigned = try await service.replaceGlobalAgentModels(
            .init(expectedRevision: 0, profile: .init(pair: matchingRecommendation)),
            attribution: Self.attribution
        )
        XCTAssertEqual(assigned.effectiveProfile.pair, matchingRecommendation)
        let stickyPairRoute = try await service.resolveAgentTarget(projectID: projectID, target: .pair)
        let stickyPair = try XCTUnwrap(stickyPairRoute)
        XCTAssertEqual(stickyPair.providerID, .codex)
        XCTAssertEqual(stickyPair.modelID, "gpt-5.6-sol")
        XCTAssertFalse(stickyPair.usedRecommendationFallback)

        let cursorPin = AgentModelTarget(providerID: .cursorACP, modelID: "auto")
        let pinned = try await service.replaceGlobalAgentModels(
            .init(
                expectedRevision: assigned.globalRevision,
                profile: assigned.effectiveProfile.replacing(.pair, with: cursorPin)
            ),
            attribution: Self.attribution
        )
        XCTAssertEqual(pinned.effectiveProfile.pair, cursorPin)

        let degraded = ServerSettingsService(
            store: store,
            providerCatalog: StaticProviderCatalog(response: .init(providers: Self.providerCatalog().providers.filter { $0.providerID != .cursorACP })),
            projectCatalog: store
        )
        let fallbackRoute = try await degraded.resolveAgentTarget(projectID: projectID, target: .pair)
        let fallback = try XCTUnwrap(fallbackRoute)
        XCTAssertEqual(fallback.providerID, .codex)
        XCTAssertEqual(fallback.modelID, "gpt-5.6-sol")
        XCTAssertTrue(fallback.usedRecommendationFallback)
        let persistedPin = try await degraded.agentModels(projectID: projectID)
        XCTAssertEqual(persistedPin.effectiveProfile.pair, cursorPin)

        let empty = ServerSettingsService(
            store: store,
            providerCatalog: StaticProviderCatalog(response: .init(providers: [])),
            projectCatalog: store
        )
        do {
            _ = try await empty.resolveAgentTarget(projectID: projectID, target: .pair)
            XCTFail("empty catalog must fail-closed for role defaults")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .invalidRequest)
            XCTAssertTrue(error.message.contains("No available agent/model for task label 'pair'"))
        }
    }

    func testSessionStartWithoutProviderResolvesPairRoute() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let projectID = UUID()
        let rootID = UUID()
        try await persistProject(projectID: projectID, rootID: rootID, store: store)
        let service = ServerSettingsService(
            store: store,
            providerCatalog: StaticProviderCatalog(response: Self.providerCatalog()),
            projectCatalog: StaticProjectCatalog(roots: [projectID: [rootID]])
        )
        let omitted = try JSONDecoder.serviceDecoder.decode(
            CreateSessionRequest.self,
            from: Data("""
            {"projectId":"\(projectID.uuidString)","visibility":"private","initialPrompt":"Inspect"}
            """.utf8)
        )
        XCTAssertFalse(omitted.hasExplicitProviderRoute)
        let resolved = try await service.createSessionInput(from: omitted)
        XCTAssertEqual(resolved.provider, .codex)
        XCTAssertEqual(resolved.providerSettingsID, .codex)
        XCTAssertEqual(resolved.model, "gpt-5.6-sol")
        XCTAssertEqual(resolved.initialProviderSettings?["provider.reasoningEffort"], "high")

        let explore = try await service.createSessionInput(
            from: .init(projectID: projectID, routingTarget: .explore, visibility: .privateSession, initialPrompt: "Explore")
        )
        XCTAssertEqual(explore.provider, .codex)
        XCTAssertEqual(explore.initialProviderSettings?["provider.reasoningEffort"], "low")

        do {
            _ = try await service.createSessionInput(
                from: .init(projectID: projectID, routingTarget: .oracle, visibility: .privateSession)
            )
            XCTFail("oracle is not a session start role")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .invalidRequest)
        }

        let explicit = try JSONDecoder.serviceDecoder.decode(
            CreateSessionRequest.self,
            from: Data("""
            {"projectId":"\(projectID.uuidString)","provider":"codex","visibility":"private"}
            """.utf8)
        )
        XCTAssertTrue(explicit.hasExplicitProviderRoute)
        let explicitInput = try explicit.explicitCreateSessionInput()
        XCTAssertEqual(explicitInput.provider, .codex)
        XCTAssertNil(explicitInput.model)
    }

    func testLeftoverInitialPermissionModeDoesNotReplaceTypedDirectAgentLaunch() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("leftover-mode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = StaticProviderCatalog(response: Self.providerCatalog())
        let service = ServerSettingsService(store: store, providerCatalog: catalog, projectCatalog: store)
        let portal = PortalDesktopSettingsService(store: store)
        let authority = RepoPromptHeadlessAuthority(
            store: store,
            serverSettings: service,
            directProviderDefaults: portal
        )
        let actor = ExternalActor(userID: "leftover", username: "leftover", displayName: "Leftover")
        let project = try await authority.createProject(
            input: .init(name: "Leftover", roots: [.init(logicalName: "root", path: root.path, writable: true)]),
            externalActor: actor,
            idempotencyKey: "leftover-project",
            requestDigest: "leftover-project"
        )
        let leftover = try await authority.createSession(
            input: .init(
                projectID: project.projectID,
                provider: .codex,
                visibility: .privateSession,
                initialPermissionMode: "readOnly"
            ),
            externalActor: actor,
            idempotencyKey: "leftover-session",
            requestDigest: "leftover-session"
        )
        let leftoverPermissions = try await authority.authoritySessionSnapshot(sessionID: leftover.sessionID).permissions
        XCTAssertEqual(leftoverPermissions.mode, "workspaceWrite")
        XCTAssertEqual(leftoverPermissions.providerSettings["codex.sandbox"], "workspace-write")
        XCTAssertEqual(leftoverPermissions.providerSettings["provider.permissionId"], "codex.autoReview")

        let override = try await authority.createSession(
            input: .init(
                projectID: project.projectID,
                provider: .codex,
                visibility: .privateSession,
                initialProviderSettings: ["provider.permissionId": "codex.readOnly"]
            ),
            externalActor: actor,
            idempotencyKey: "permission-id-session",
            requestDigest: "permission-id-session"
        )
        let overridePermissions = try await authority.authoritySessionSnapshot(sessionID: override.sessionID).permissions
        XCTAssertEqual(overridePermissions.mode, "readOnly")
        XCTAssertEqual(overridePermissions.providerSettings["provider.permissionId"], "codex.readOnly")

        let routed = try await service.createSessionInput(
            from: .init(
                projectID: project.projectID,
                routingTarget: .pair,
                visibility: .privateSession,
                initialPermissionMode: "fullAccess"
            )
        )
        XCTAssertNil(routed.initialPermissionMode)
    }

    func testApplyRecommendationsWritesStickyOracleAndContextBuilderAndClearsRoleOverrides() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let projectID = UUID()
        let rootID = UUID()
        try await persistProject(projectID: projectID, rootID: rootID, store: store)
        let service = ServerSettingsService(
            store: store,
            providerCatalog: StaticProviderCatalog(response: Self.providerCatalog()),
            projectCatalog: StaticProjectCatalog(roots: [projectID: [rootID]])
        )

        let seeded = try await service.replaceGlobalAgentModels(
            .init(
                expectedRevision: 0,
                profile: .init(
                    oracle: .init(providerID: .claudeCompatible, modelID: "claude-opus-5", pinned: true),
                    pair: .init(providerID: .cursorACP, modelID: "auto"),
                    restrictDiscoveryToRoleModels: true
                )
            ),
            attribution: Self.attribution
        )
        XCTAssertEqual(seeded.effectiveProfile.oracle?.providerID, .claudeCompatible)
        XCTAssertEqual(seeded.effectiveProfile.pair?.providerID, .cursorACP)

        let applied = try await service.applyGlobalAgentModelRecommendations(
            .init(expectedRevision: seeded.globalRevision),
            attribution: Self.attribution
        )
        XCTAssertEqual(applied.effectiveProfile.oracle?.providerID, .codex)
        XCTAssertEqual(applied.effectiveProfile.oracle?.modelID, "gpt-5.6-sol")
        XCTAssertEqual(applied.effectiveProfile.contextBuilder?.providerID, .codex)
        XCTAssertNil(applied.effectiveProfile.explore)
        XCTAssertNil(applied.effectiveProfile.engineer)
        XCTAssertNil(applied.effectiveProfile.pair)
        XCTAssertNil(applied.effectiveProfile.design)
        XCTAssertTrue(applied.effectiveProfile.restrictDiscoveryToRoleModels)

        let oracleRoute = try await service.resolveAgentTarget(projectID: projectID, target: .oracle)
        let oracle = try XCTUnwrap(oracleRoute)
        XCTAssertEqual(oracle.providerID, .codex)
        XCTAssertFalse(oracle.usedRecommendationFallback)

        let contextBuilderRoute = try await service.resolveAgentTarget(projectID: projectID, target: .contextBuilder)
        let contextBuilder = try XCTUnwrap(contextBuilderRoute)
        XCTAssertEqual(contextBuilder.providerID, .codex)
        XCTAssertFalse(contextBuilder.usedRecommendationFallback)

        let pairRoute = try await service.resolveAgentTarget(projectID: projectID, target: .pair)
        let pair = try XCTUnwrap(pairRoute)
        XCTAssertEqual(pair.providerID, .codex)
        XCTAssertTrue(pair.usedRecommendationFallback)
    }

    func testRestrictDiscoveryHidesListAgentsCatalogAndLeavesListModelsUnfiltered() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let projectID = UUID()
        let rootID = UUID()
        try await persistProject(projectID: projectID, rootID: rootID, store: store)
        let service = ServerSettingsService(
            store: store,
            providerCatalog: StaticProviderCatalog(response: Self.providerCatalog()),
            projectCatalog: StaticProjectCatalog(roots: [projectID: [rootID]])
        )

        let open = try await service.agentDiscovery(projectID: projectID)
        XCTAssertFalse(open.roleModelRestrictionApplied)
        XCTAssertEqual(Set(open.taskLabels.map(\.label)), ["explore", "engineer", "pair", "design"])
        XCTAssertFalse(try XCTUnwrap(open.agents).isEmpty)
        XCTAssertTrue(try XCTUnwrap(open.agents).contains { agent in
            agent.models.contains { $0.modelID.hasPrefix("codex:") }
        })

        let rolesOnly = try await service.agentDiscovery(projectID: projectID, rolesOnly: true)
        XCTAssertNil(rolesOnly.agents)
        XCTAssertFalse(rolesOnly.taskLabels.isEmpty)

        let restricted = try await service.replaceGlobalAgentModels(
            .init(
                expectedRevision: 0,
                profile: .init(
                    pair: .init(providerID: .cursorACP, modelID: "auto"),
                    restrictDiscoveryToRoleModels: true
                )
            ),
            attribution: Self.attribution
        )
        XCTAssertTrue(restricted.effectiveProfile.restrictDiscoveryToRoleModels)

        let hidden = try await service.agentDiscovery(projectID: projectID)
        XCTAssertTrue(hidden.roleModelRestrictionApplied)
        XCTAssertNil(hidden.agents)
        XCTAssertEqual(Set(hidden.taskLabels.map(\.label)), ["explore", "engineer", "pair", "design"])
        let pairLabel = try XCTUnwrap(hidden.taskLabels.first(where: { $0.label == "pair" }))
        XCTAssertEqual(pairLabel.modelID, "cursorACP:auto")
        XCTAssertTrue(pairLabel.hasCustomOverride)
        XCTAssertFalse(pairLabel.overrideUnavailable)

        let models = try await service.modelDiscovery(projectID: projectID)
        XCTAssertFalse(models.roleModelRestrictionApplied)
        XCTAssertEqual(Set(models.providers.map(\.providerID)), Set(Self.providerCatalog().providers.map(\.providerID)))
        XCTAssertGreaterThan(models.providers.reduce(0) { $0 + $1.models.count }, 1)
    }

    func testAppSettingsRoutingKeysWriteTheTypedAgentModelsStore() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("app-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ServerSettingsService(
            store: store,
            providerCatalog: StaticProviderCatalog(response: Self.providerCatalog()),
            projectCatalog: store
        )
        let authority = RepoPromptHeadlessAuthority(store: store, serverSettings: service)
        let actor = ExternalActor(userID: "mcp-settings", username: "mcp-settings", displayName: "MCP Settings")
        let project = try await authority.createProject(
            input: .init(name: "Settings", roots: [.init(logicalName: "root", path: root.path, writable: true)]),
            externalActor: actor,
            idempotencyKey: "settings-project",
            requestDigest: "settings-project"
        )
        let session = try await authority.createSession(
            input: .init(projectID: project.projectID, provider: .codex, visibility: .privateSession),
            externalActor: actor,
            idempotencyKey: "settings-session",
            requestDigest: "settings-session"
        )
        let adapter = RepoPromptMCPAdapter(serving: await RepoPromptAuthorityMCPService.admitted(authority: authority, portalSettings: PortalDesktopSettingsService(store: store), admissionGate: AuthorityMutationGate()))
        let binding = RepoPromptMCPBinding(sessionID: session.sessionID, actor: actor)

        func invoke(_ object: [String: Any]) async throws -> [String: Any] {
            let data = try await adapter.invoke(
                toolName: "app_settings",
                argumentsJSON: try JSONSerialization.data(withJSONObject: object),
                binding: binding
            )
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        let empty = try await invoke(["op": "get", "key": "models.planning_model"])
        XCTAssertEqual(empty["key"] as? String, "models.planning_model")
        XCTAssertTrue(empty["value"] is NSNull)

        let written = try await invoke([
            "op": "set",
            "key": "models.planning_model",
            "value": "codex:gpt-5.6-sol"
        ])
        XCTAssertEqual(written["value"] as? String, "codex:gpt-5.6-sol")
        let stored = try await authority.globalAgentModels()
        XCTAssertEqual(stored.effectiveProfile.oracle?.providerID, .codex)
        XCTAssertEqual(stored.effectiveProfile.oracle?.modelID, "gpt-5.6-sol")

        _ = try await invoke(["op": "set", "key": "context_builder.agent", "value": "claudeCode"])
        _ = try await invoke(["op": "set", "key": "context_builder.model", "value": "claude-opus-5"])
        let builder = try await authority.globalAgentModels().effectiveProfile.contextBuilder
        XCTAssertEqual(builder?.providerID, .claudeCompatible)
        XCTAssertEqual(builder?.modelID, "claude-opus-5")
        let readBuilder = try await invoke(["op": "get", "key": "context_builder.model"])
        XCTAssertEqual(readBuilder["value"] as? String, "claude-opus-5")
    }

    func testAppSettingsPackagingKeysWriteTheSameAdvancedAndComposeStores() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("app-settings-packaging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ServerSettingsService(
            store: store,
            providerCatalog: StaticProviderCatalog(response: Self.providerCatalog()),
            projectCatalog: store
        )
        let authority = RepoPromptHeadlessAuthority(store: store, serverSettings: service)
        let actor = ExternalActor(userID: "mcp-packaging", username: "mcp-packaging", displayName: "MCP Packaging")
        let project = try await authority.createProject(
            input: .init(name: "Packaging", roots: [.init(logicalName: "root", path: root.path, writable: true)]),
            externalActor: actor,
            idempotencyKey: "packaging-project",
            requestDigest: "packaging-project"
        )
        let session = try await authority.createSession(
            input: .init(projectID: project.projectID, provider: .codex, visibility: .privateSession),
            externalActor: actor,
            idempotencyKey: "packaging-session",
            requestDigest: "packaging-session"
        )
        let adapter = RepoPromptMCPAdapter(serving: await RepoPromptAuthorityMCPService.admitted(authority: authority, portalSettings: PortalDesktopSettingsService(store: store), admissionGate: AuthorityMutationGate()))
        let binding = RepoPromptMCPBinding(sessionID: session.sessionID, actor: actor)

        func invoke(_ object: [String: Any]) async throws -> [String: Any] {
            let data = try await adapter.invoke(
                toolName: "app_settings",
                argumentsJSON: try JSONSerialization.data(withJSONObject: object),
                binding: binding
            )
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        _ = try await invoke(["op": "set", "key": "models.file_edit_format", "value": "Whole"])
        _ = try await invoke(["op": "set", "key": "models.temperature", "value": 0.7])
        _ = try await invoke(["op": "set", "key": "models.temperature_enabled", "value": true])
        _ = try await invoke(["op": "set", "key": "models.custom_planning_prompt", "value": "Custom plan"])
        _ = try await invoke(["op": "set", "key": "prompt_packaging.duplicate_user_instructions_at_top", "value": true])
        _ = try await invoke(["op": "set", "key": "prompt_packaging.file_path_display_option", "value": "Relative"])
        _ = try await invoke(["op": "set", "key": "prompt_packaging.include_datetime_in_user_instructions", "value": true])
        _ = try await invoke([
            "op": "set",
            "key": "prompt_packaging.prompt_sections_order",
            "value": PromptSection.defaultOrderJSON
        ])
        _ = try await invoke(["op": "set", "key": "models.preferred_compose_model", "value": "gpt-5.6-sol"])
        _ = try await invoke(["op": "set", "key": "models.sync_chat_model_with_oracle", "value": false])

        let advanced = try await authority.advancedSettings().settings
        XCTAssertEqual(advanced.resolvedFileEditFormat(), .whole)
        XCTAssertEqual(advanced.modelTemperature, 0.7)
        XCTAssertTrue(advanced.setModelTemperature)
        XCTAssertEqual(advanced.customPlanningPrompt, "Custom plan")
        XCTAssertTrue(advanced.duplicateUserInstructionsAtTop)
        XCTAssertEqual(advanced.resolvedFilePathDisplay(), .relative)
        XCTAssertTrue(advanced.includeDatetimeInUserInstructions)
        XCTAssertEqual(advanced.resolvedPromptSectionOrder(), PromptSection.defaultOrder)

        let compose = try await authority.globalAgentModels().effectiveProfile
        XCTAssertEqual(compose.preferredComposeModelRaw, "gpt-5.6-sol")
        XCTAssertEqual(compose.syncChatModelWithOracle, false)

        let pathDisplay = try await invoke(["op": "get", "key": "prompt_packaging.file_path_display_option"])
        XCTAssertEqual(pathDisplay["value"] as? String, "Relative")
        let composeRead = try await invoke(["op": "get", "key": "models.preferred_compose_model"])
        XCTAssertEqual(composeRead["value"] as? String, "gpt-5.6-sol")
    }

    func testAppSettingsPermissionKeysWriteTheTypedPermissionStore() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("app-settings-permissions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ServerSettingsService(
            store: store,
            providerCatalog: StaticProviderCatalog(response: Self.providerCatalog()),
            projectCatalog: store
        )
        let authority = RepoPromptHeadlessAuthority(store: store, serverSettings: service)
        let actor = ExternalActor(userID: "mcp-permissions", username: "mcp-permissions", displayName: "MCP Permissions")
        let project = try await authority.createProject(
            input: .init(name: "Permissions", roots: [.init(logicalName: "root", path: root.path, writable: true)]),
            externalActor: actor,
            idempotencyKey: "permissions-project",
            requestDigest: "permissions-project"
        )
        let session = try await authority.createSession(
            input: .init(projectID: project.projectID, provider: .codex, visibility: .privateSession),
            externalActor: actor,
            idempotencyKey: "permissions-session",
            requestDigest: "permissions-session"
        )
        let adapter = RepoPromptMCPAdapter(serving: await RepoPromptAuthorityMCPService.admitted(authority: authority, portalSettings: PortalDesktopSettingsService(store: store), admissionGate: AuthorityMutationGate()))
        let binding = RepoPromptMCPBinding(sessionID: session.sessionID, actor: actor)

        func invoke(_ object: [String: Any]) async throws -> [String: Any] {
            let data = try await adapter.invoke(
                toolName: "app_settings",
                argumentsJSON: try JSONSerialization.data(withJSONObject: object),
                binding: binding
            )
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        let defaults = try await invoke(["op": "get", "key": "direct_agents.codex.sandbox"])
        XCTAssertEqual(defaults["value"] as? String, "workspace-write")
        let claudeStrict = try await invoke(["op": "get", "key": "direct_agents.claude.mcp_strict"])
        XCTAssertEqual(claudeStrict["value"] as? Bool, true)

        let written = try await invoke([
            "op": "set",
            "key": "direct_agents.codex.sandbox",
            "value": "read-only"
        ])
        XCTAssertEqual(written["value"] as? String, "read-only")
        _ = try await invoke([
            "op": "set",
            "key": "direct_agents.codex.approval_reviewer",
            "value": "user"
        ])
        _ = try await invoke([
            "op": "set",
            "key": "direct_agents.claude.permission_mode",
            "value": "acceptEdits"
        ])
        _ = try await invoke([
            "op": "set",
            "key": "subagents.policy",
            "value": "inheritProviderSettings"
        ])

        let stored = try await authority.directAgentPermissions()
        XCTAssertEqual(stored.settings.codex.sandboxMode, .readOnly)
        XCTAssertEqual(stored.settings.codex.approvalReviewer, .user)
        XCTAssertEqual(stored.settings.claude.permissionMode, .autoApproveEdits)
        let subagents = try await authority.subagentPermissions()
        XCTAssertEqual(subagents.settings.policy, .inheritProviderSettings)
        let readPolicy = try await invoke(["op": "get", "key": "subagents.policy"])
        XCTAssertEqual(readPolicy["value"] as? String, "inheritProviderSettings")
    }

    func testAppSettingsCLIProviderKeysWriteTheSameStoresWithoutATokenBag() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("app-settings-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ServerSettingsService(
            store: store,
            providerCatalog: StaticProviderCatalog(response: Self.providerCatalog()),
            projectCatalog: store
        )
        let authority = RepoPromptHeadlessAuthority(store: store, serverSettings: service)
        let portal = PortalDesktopSettingsService(store: store)
        let actor = ExternalActor(userID: "mcp-cli", username: "mcp-cli", displayName: "MCP CLI")
        let project = try await authority.createProject(
            input: .init(name: "CLI", roots: [.init(logicalName: "root", path: root.path, writable: true)]),
            externalActor: actor,
            idempotencyKey: "cli-settings-project",
            requestDigest: "cli-settings-project"
        )
        let session = try await authority.createSession(
            input: .init(projectID: project.projectID, provider: .codex, visibility: .privateSession),
            externalActor: actor,
            idempotencyKey: "cli-settings-session",
            requestDigest: "cli-settings-session"
        )
        let adapter = RepoPromptMCPAdapter(serving: await RepoPromptAuthorityMCPService.admitted(authority: authority, portalSettings: PortalDesktopSettingsService(store: store), admissionGate: AuthorityMutationGate()))
        let binding = RepoPromptMCPBinding(sessionID: session.sessionID, actor: actor)

        func invoke(_ object: [String: Any]) async throws -> [String: Any] {
            let data = try await adapter.invoke(
                toolName: "app_settings",
                argumentsJSON: try JSONSerialization.data(withJSONObject: object),
                binding: binding
            )
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        let defaultDelivery = try await invoke(["op": "get", "key": "direct_agents.claude.prompt_delivery"])
        XCTAssertEqual(defaultDelivery["value"] as? String, "nativeSystemPrompt")
        let writtenDelivery = try await invoke([
            "op": "set",
            "key": "direct_agents.claude.prompt_delivery",
            "value": "userMessageXML"
        ])
        XCTAssertEqual(writtenDelivery["value"] as? String, "userMessageXML")
        let stored = try await authority.directAgentPermissions()
        XCTAssertEqual(stored.settings.claude.promptDelivery, .userMessageXML)

        let defaultEnabled = try await invoke(["op": "get", "key": "claude.custom.enabled"])
        XCTAssertEqual(defaultEnabled["value"] as? Bool, false)
        _ = try await invoke(["op": "set", "key": "claude.custom.enabled", "value": true])
        _ = try await invoke([
            "op": "set",
            "key": "claude.kimi.model_behavior",
            "value": "claudeSlotMapping"
        ])
        _ = try await invoke([
            "op": "set",
            "key": "claude.kimi.haiku_model",
            "value": "kimi-haiku"
        ])

        let portalSnapshot = try await portal.snapshot()
        XCTAssertEqual(portalSnapshot.values[PortalDesktopSettingKey.claudeCustomEnabled.rawValue], "true")
        XCTAssertEqual(portalSnapshot.values[PortalDesktopSettingKey.claudeKimiModelBehavior.rawValue], "claudeSlotMapping")
        XCTAssertEqual(portalSnapshot.values[PortalDesktopSettingKey.claudeKimiHaikuModel.rawValue], "kimi-haiku")
        let kimiSettings = try await portal.backendSettings(for: .claudeKimi)
        let kimi = try XCTUnwrap(kimiSettings)
        XCTAssertEqual(kimi.modelBehavior, .claudeSlotMapping)
        XCTAssertEqual(kimi.haikuModel, "kimi-haiku")
        let customSettings = try await portal.backendSettings(for: .claudeCustom)
        let custom = try XCTUnwrap(customSettings)
        XCTAssertTrue(custom.isEnabled)

        do {
            _ = try await invoke(["op": "set", "key": "cli.token", "value": "sk-secret"])
            XCTFail("MCP must not accept a parallel CLI token store")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .invalidRequest)
            XCTAssertTrue(error.message.contains("connection APIs"), error.message)
        }
        do {
            _ = try await invoke(["op": "set", "key": "claude.credential", "value": "sk-secret"])
            XCTFail("MCP must not accept credential-shaped keys")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .invalidRequest)
            XCTAssertTrue(error.message.contains("connection APIs"), error.message)
        }
    }

    func testAppSettingsWorkspaceApprovalKeysWriteTheTypedStoreAndAreNotAlwaysOn() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("app-settings-workspace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ServerSettingsService(
            store: store,
            providerCatalog: StaticProviderCatalog(response: Self.providerCatalog()),
            projectCatalog: store
        )
        let authority = RepoPromptHeadlessAuthority(store: store, serverSettings: service)
        let actor = ExternalActor(userID: "mcp-workspace", username: "mcp-workspace", displayName: "MCP Workspace")
        let project = try await authority.createProject(
            input: .init(name: "Workspace", roots: [.init(logicalName: "root", path: root.path, writable: true)]),
            externalActor: actor,
            idempotencyKey: "workspace-settings-project",
            requestDigest: "workspace-settings-project"
        )
        let session = try await authority.createSession(
            input: .init(projectID: project.projectID, provider: .codex, visibility: .privateSession),
            externalActor: actor,
            idempotencyKey: "workspace-settings-session",
            requestDigest: "workspace-settings-session"
        )
        let adapter = RepoPromptMCPAdapter(serving: await RepoPromptAuthorityMCPService.admitted(authority: authority, portalSettings: PortalDesktopSettingsService(store: store), admissionGate: AuthorityMutationGate()))
        let binding = RepoPromptMCPBinding(sessionID: session.sessionID, actor: actor)

        func invoke(_ object: [String: Any]) async throws -> [String: Any] {
            let data = try await adapter.invoke(
                toolName: "app_settings",
                argumentsJSON: try JSONSerialization.data(withJSONObject: object),
                binding: binding
            )
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        let unread = try await invoke(["op": "get", "key": "workspace.auto_approve_all"])
        XCTAssertEqual(unread["value"] as? Bool, false)
        let unreadCreate = try await invoke(["op": "get", "key": "workspace.auto_approve.create_workspace"])
        XCTAssertEqual(unreadCreate["value"] as? Bool, false)
        do {
            _ = try await adapter.invoke(
                toolName: "manage_workspaces",
                argumentsJSON: JSONSerialization.data(withJSONObject: ["action": "create", "name": "Denied"], options: [.sortedKeys]),
                binding: binding
            )
            XCTFail("workspace mutations must stay fail-closed until the typed store approves them")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .invalidRequest)
            XCTAssertEqual(error.message, WorkspaceApprovalOperation.createWorkspace.deniedByUserMessage)
        }

        let master = try await invoke([
            "op": "set",
            "key": "workspace.auto_approve_all",
            "value": true
        ])
        XCTAssertEqual(master["value"] as? Bool, true)
        let enabled = try await authority.workspaceApprovals()
        XCTAssertTrue(enabled.settings.autoApproveAll)
        _ = try await adapter.invoke(
            toolName: "manage_workspaces",
            argumentsJSON: JSONSerialization.data(withJSONObject: ["action": "create", "name": "Allowed"], options: [.sortedKeys]),
            binding: binding
        )

        _ = try await invoke([
            "op": "set",
            "key": "workspace.auto_approve_all",
            "value": false
        ])
        _ = try await invoke([
            "op": "set",
            "key": "workspace.auto_approve.create_workspace",
            "value": true
        ])
        let stored = try await authority.workspaceApprovals()
        XCTAssertFalse(stored.settings.autoApproveAll)
        XCTAssertEqual(stored.settings.autoApproveOperations, [.createWorkspace])
        _ = try await adapter.invoke(
            toolName: "manage_workspaces",
            argumentsJSON: JSONSerialization.data(withJSONObject: ["action": "create", "name": "PerOp"], options: [.sortedKeys]),
            binding: binding
        )
        do {
            _ = try await adapter.invoke(
                toolName: "manage_workspaces",
                argumentsJSON: JSONSerialization.data(withJSONObject: ["action": "delete"], options: [.sortedKeys]),
                binding: binding
            )
            XCTFail("unlisted workspace ops must stay fail-closed")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .invalidRequest)
            XCTAssertEqual(error.message, WorkspaceApprovalOperation.deleteWorkspace.deniedByUserMessage)
        }
    }

    func testChildCreationEnforcesSafeInheritAndCustomWithExactProviderIdentity() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("settings-runtime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = StaticProviderCatalog(response: Self.providerCatalog())
        let service = ServerSettingsService(store: store, providerCatalog: catalog, projectCatalog: store)
        let inheritedDefaults = StaticDirectProviderDefaults(values: [
            .codex: .init(mode: "fullAccess", providerSettings: ["test.marker": "codex", "codex.approvalPolicy": "never"]),
            .claudeGLM: .init(mode: "workspaceWrite", providerSettings: ["test.marker": "claude", "claude.backendID": ProviderSettingsID.claudeGLM.rawValue, "claude.permissionMode": "acceptEdits"]),
            .openCodeACP: .init(mode: "fullAccess", providerSettings: ["test.marker": "opencode"]),
            .cursorACP: .init(mode: "fullAccess", providerSettings: ["test.marker": "cursor"]),
            .grokBuildACP: .init(mode: "fullAccess", providerSettings: ["test.marker": "grok"])
        ])
        let authority = RepoPromptHeadlessAuthority(
            store: store,
            serverSettings: service,
            directProviderDefaults: inheritedDefaults
        )
        let actor = ExternalActor(userID: "runtime", username: "runtime", displayName: "Runtime")
        let project = try await authority.createProject(
            input: .init(name: "Runtime", roots: [.init(logicalName: "root", path: root.path, writable: true)]),
            externalActor: actor,
            idempotencyKey: "runtime-project",
            requestDigest: "runtime-project"
        )
        let parent = try await authority.createSession(
            input: .init(projectID: project.projectID, provider: .codex, visibility: .privateSession),
            externalActor: actor,
            idempotencyKey: "runtime-parent",
            requestDigest: "runtime-parent"
        )

        let safe = try await authority.spawnChildSession(
            parentSessionID: parent.sessionID,
            providerSettingsID: .claudeGLM,
            initialPrompt: "safe"
        )
        let safePermissions = try await authority.authoritySessionSnapshot(sessionID: safe.sessionID).permissions
        XCTAssertEqual(safe.providerSettingsID, .claudeGLM)
        XCTAssertEqual(safe.provider, .claudeCompatible)
        XCTAssertEqual(safePermissions.providerSettings["claude.backendID"], ProviderSettingsID.claudeGLM.rawValue)
        XCTAssertEqual(safePermissions.providerSettings["claude.permissionMode"], "default")
        XCTAssertEqual(safePermissions.providerSettings["claude.bashEnabled"], "false")
        XCTAssertEqual(safePermissions.providerSettings["claude.strictMCPEnabled"], "true")
        XCTAssertNil(safePermissions.providerSettings["test.marker"])
        for providerID in [ProviderSettingsID.codex, .openCodeACP, .cursorACP, .grokBuildACP] {
            let child = try await authority.spawnChildSession(parentSessionID: parent.sessionID, providerSettingsID: providerID, initialPrompt: "safe-\(providerID.rawValue)")
            let permissions = try await authority.authoritySessionSnapshot(sessionID: child.sessionID).permissions
            XCTAssertNotEqual(permissions.mode, "fullAccess")
            XCTAssertNil(permissions.providerSettings["test.marker"])
            if providerID == .codex {
                XCTAssertEqual(permissions.providerSettings["codex.sandbox"], "workspace-write")
                XCTAssertEqual(permissions.providerSettings["codex.approvalsReviewer"], "auto_review")
                XCTAssertEqual(permissions.providerSettings["codex.approvalPolicy"], "on-request")
            }
        }

        _ = try await service.replaceSubagentPermissions(
            .init(expectedRevision: 0, settings: .init(policy: .inheritProviderSettings)),
            attribution: Self.attribution
        )
        let inherited = try await authority.spawnChildSession(parentSessionID: parent.sessionID, providerSettingsID: .claudeGLM, initialPrompt: "inherit")
        let inheritedPermissions = try await authority.authoritySessionSnapshot(sessionID: inherited.sessionID).permissions
        XCTAssertEqual(inheritedPermissions.providerSettings["claude.permissionMode"], "acceptEdits")
        for providerID in [ProviderSettingsID.codex, .openCodeACP, .cursorACP, .grokBuildACP] {
            let child = try await authority.spawnChildSession(parentSessionID: parent.sessionID, providerSettingsID: providerID, initialPrompt: "inherit-\(providerID.rawValue)")
            let permissions = try await authority.authoritySessionSnapshot(sessionID: child.sessionID).permissions
            XCTAssertEqual(permissions.mode, "fullAccess")
        }

        _ = try await service.replaceSubagentPermissions(
            .init(expectedRevision: 1, settings: .init(policy: .custom, codex: .readOnly, claude: .fullAccess, openCode: .fullAccess, cursor: .fullAccess, grokBuild: .fullAccess)),
            attribution: Self.attribution
        )
        let custom = try await authority.spawnChildSession(parentSessionID: parent.sessionID, providerSettingsID: .claudeGLM, initialPrompt: "custom")
        let customPermissions = try await authority.authoritySessionSnapshot(sessionID: custom.sessionID).permissions
        XCTAssertEqual(customPermissions.mode, "fullAccess")
        XCTAssertEqual(customPermissions.providerSettings["claude.permissionMode"], "bypassPermissions")
        XCTAssertEqual(customPermissions.providerSettings["provider.settingsID"], ProviderSettingsID.claudeGLM.rawValue)
        for (providerID, expectedMode) in [
            (ProviderSettingsID.codex, "readOnly"),
            (.openCodeACP, "fullAccess"),
            (.cursorACP, "fullAccess"),
            (.grokBuildACP, "fullAccess")
        ] {
            let child = try await authority.spawnChildSession(parentSessionID: parent.sessionID, providerSettingsID: providerID, initialPrompt: "custom-\(providerID.rawValue)")
            let permissions = try await authority.authoritySessionSnapshot(sessionID: child.sessionID).permissions
            XCTAssertEqual(permissions.mode, expectedMode)
        }
    }

    func testContextBuilderAndOracleConsumeFrozenRoutesDefaultsAndPreset() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".build/test-workspaces/context-runtime-\(UUID().uuidString)")
        let artifacts = FileManager.default.temporaryDirectory.appendingPathComponent("context-artifacts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: artifacts)
        }
        try "struct Runtime {}".write(to: root.appendingPathComponent("Runtime.swift"), atomically: true, encoding: .utf8)
        let catalog = StaticProviderCatalog(response: Self.providerCatalog())
        let service = ServerSettingsService(store: store, providerCatalog: catalog, projectCatalog: store)
        let contextRuntime = RecordingContextBuilderRuntime()
        let oracleRuntime = RecordingOracleRuntime()
        let runtimeDefaults = StaticDirectProviderDefaults(values: [
            .claudeGLM: .init(mode: "workspaceWrite", providerSettings: ["claude.backendID": ProviderSettingsID.claudeGLM.rawValue])
        ])
        let authority = try RepoPromptHeadlessAuthority(
            store: store,
            artifactService: ArtifactRuntimeService(baseDirectory: artifacts.path),
            contextBuilderRuntime: contextRuntime,
            oracleRuntime: oracleRuntime,
            serverSettings: service,
            directProviderDefaults: runtimeDefaults
        )
        let actor = ExternalActor(userID: "context", username: "context", displayName: "Context")
        let project = try await authority.createProject(
            input: .init(name: "Context", roots: [.init(logicalName: "root", path: root.resolvingSymlinksInPath().path, writable: true)]),
            externalActor: actor,
            idempotencyKey: "context-project",
            requestDigest: "context-project"
        )
        let session = try await authority.createSession(
            input: .init(projectID: project.projectID, provider: .claudeCompatible, visibility: .privateSession),
            externalActor: actor,
            idempotencyKey: "context-session",
            requestDigest: "context-session"
        )
        _ = try await service.applyGlobalAgentModelRecommendations(
            .init(expectedRevision: 0),
            attribution: Self.attribution
        )
        _ = try await service.replaceGlobalAgentModels(
            .init(expectedRevision: 1, profile: .init(
                oracle: .init(providerID: .claudeGLM, modelID: "claude-sonnet-5"),
                contextBuilder: .init(providerID: .claudeGLM, modelID: "claude-sonnet-5")
            )),
            attribution: Self.attribution
        )
        _ = try await service.replaceGlobalContextBuilder(
            .init(expectedRevision: 0, profile: .init(
                budget: 100_000,
                enhancementMode: .augment,
                questionTimeoutSeconds: 60,
                portalClarifyingQuestions: true,
                mcpClarifyingQuestions: false,
                followUpAnalysis: .plan,
                followUpBudget: 50_000
            )),
            attribution: Self.attribution
        )
        let presetID = UUID()
        _ = try await service.replaceModelPresets(
            .init(expectedRevision: 0, presets: [.init(
                presetID: presetID,
                name: "Review preset",
                target: .init(providerID: .codex, modelID: "gpt-5.6-sol", reasoningEffort: "high"),
                availability: [.review],
                order: 0
            )]),
            attribution: Self.attribution
        )
        _ = try await service.setShowModelPresets(true, expectedRevision: 0, attribution: Self.attribution)

        let result = try await authority.runContextBuilder(
            sessionID: session.sessionID,
            input: .init(expectedSelectionRevision: 1, instructions: "Caller", responseType: "question"),
            actor: actor,
            origin: .mcp
        )
        XCTAssertNotNil(result.followUpArtifactID)
        let recordedContextRequest = await contextRuntime.lastRequest()
        let contextRequest = try XCTUnwrap(recordedContextRequest)
        XCTAssertEqual(contextRequest.tokenBudget, 100_000)
        XCTAssertFalse(contextRequest.allowClarifyingQuestions)
        XCTAssertEqual(contextRequest.instructions, "Caller")
        XCTAssertEqual(contextRequest.responseType, "question")
        XCTAssertEqual(contextRequest.providerSettingsID, .claudeGLM)
        XCTAssertEqual(contextRequest.providerSettings["claude.backendID"], ProviderSettingsID.claudeGLM.rawValue)
        let followUpRequests = await oracleRuntime.requests()
        let followUpRequest = try XCTUnwrap(followUpRequests.first)
        XCTAssertEqual(followUpRequest.tokenBudget, 50_000)
        XCTAssertEqual(followUpRequest.mode, "plan")

        let oracle = try await authority.askOracle(
            sessionID: session.sessionID,
            input: .init(chatID: nil, prompt: "Review", contextMode: "review", modelPresetID: presetID),
            actor: actor
        )
        let presetRequests = await oracleRuntime.requests()
        let presetRequest = try XCTUnwrap(presetRequests.last)
        XCTAssertEqual(presetRequest.providerSettingsID, .codex)
        XCTAssertEqual(presetRequest.model, "gpt-5.6-sol")
        XCTAssertEqual(presetRequest.reasoningEffort, "high")
        let chat = try await authority.oracleChatState(sessionID: session.sessionID, chatID: oracle.chatID)
        XCTAssertEqual(chat.providerSettingsID, .codex)
        XCTAssertNotNil(chat.providerSettings)
    }

    func testAdvancedSettingsChangeNextScanAndGateCodeMapsAndHistoryDefault() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("advanced-runtime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "git-ignored.swift\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try "repo-ignored.swift\n".write(to: root.appendingPathComponent(".repo_ignore"), atomically: true, encoding: .utf8)
        try "needle".write(to: root.appendingPathComponent("git-ignored.swift"), atomically: true, encoding: .utf8)
        try "needle".write(to: root.appendingPathComponent("repo-ignored.swift"), atomically: true, encoding: .utf8)
        try "needle".write(to: root.appendingPathComponent("visible.swift"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("empty"), withIntermediateDirectories: true)

        let service = ServerSettingsService(
            store: store,
            providerCatalog: StaticProviderCatalog(response: Self.providerCatalog()),
            projectCatalog: store
        )
        let authority = RepoPromptHeadlessAuthority(store: store, serverSettings: service)
        let actor = ExternalActor(userID: "advanced", username: "advanced", displayName: "Advanced")
        let project = try await authority.createProject(
            input: .init(name: "Advanced", roots: [.init(logicalName: "root", path: root.path, writable: true)]),
            externalActor: actor,
            idempotencyKey: "advanced-project",
            requestDigest: "advanced-project"
        )
        let rootID = try XCTUnwrap(project.roots.first?.rootID)
        let initialHits = try await authority.projectSearch(projectID: project.projectID, request: .init(rootID: rootID, query: "needle"))
        XCTAssertEqual(initialHits.map(\.logicalPath), ["visible.swift"])

        _ = try await service.replaceAdvanced(
            .init(expectedRevision: 0, settings: .init(
                respectRepoIgnore: false,
                showEmptyFolders: false,
                codeMapsEnabled: false,
                historyIdleThresholdMinutes: 14
            )),
            attribution: Self.attribution
        )
        let nextHits = try await authority.projectSearch(projectID: project.projectID, request: .init(rootID: rootID, query: "needle"))
        XCTAssertEqual(Set(nextHits.map(\.logicalPath)), Set(["repo-ignored.swift", "visible.swift"]))
        let tree = try await authority.projectTree(projectID: project.projectID, request: .init(rootID: rootID))
        XCTAssertFalse(tree.contains(where: { $0.logicalPath == "empty" }))
        let storedThreshold = try await authority.historyIdleThresholdMinutes(explicit: nil)
        let explicitThreshold = try await authority.historyIdleThresholdMinutes(explicit: 2)
        XCTAssertEqual(storedThreshold, 14)
        XCTAssertEqual(explicitThreshold, 2)
        do {
            _ = try await authority.projectCodeMap(projectID: project.projectID, request: .init(rootID: rootID, logicalPath: "visible.swift"))
            XCTFail("code maps should be rejected while disabled")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .capabilityMissing)
        }
    }

    func testAgentModelsProjectScopeInheritsAndOverridesLikeDesktop() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let projectID = UUID()
        let rootID = UUID()
        let catalogs = StaticProviderCatalog(response: Self.providerCatalog())
        let projects = StaticProjectCatalog(roots: [projectID: [rootID]])
        try await persistProject(projectID: projectID, rootID: rootID, store: store)
        let service = ServerSettingsService(store: store, providerCatalog: catalogs, projectCatalog: projects)
        let globalTarget = AgentModelTarget(providerID: .codex, modelID: "gpt-5.6-sol", reasoningEffort: "high", pinned: true)
        let projectTarget = AgentModelTarget(providerID: .claudeCompatible, modelID: "claude-opus-5", pinned: false)

        let global = try await service.replaceGlobalAgentModels(
            .init(expectedRevision: 0, profile: .init(oracle: globalTarget)),
            attribution: Self.attribution
        )
        let storedGlobal = try await store.agentModelsDocument(scopeID: "global")
        XCTAssertEqual(storedGlobal?.value.mode, .inheritGlobal)
        XCTAssertEqual(global.effectiveProfile.oracle, globalTarget)

        let overridden = try await service.replaceProjectAgentModels(
            projectID: projectID,
            request: .init(expectedRevision: 0, mode: .projectOverride, profile: .init(oracle: projectTarget)),
            attribution: Self.attribution
        )
        XCTAssertEqual(overridden.projectMode, .projectOverride)
        XCTAssertEqual(overridden.effectiveProfile.oracle, projectTarget)

        let inherited = try await service.replaceProjectAgentModels(
            projectID: projectID,
            request: .init(expectedRevision: 1, mode: .inheritGlobal, profile: nil),
            attribution: Self.attribution
        )
        XCTAssertEqual(inherited.projectMode, .inheritGlobal)
        XCTAssertEqual(inherited.projectProfile?.oracle, projectTarget)
        XCTAssertEqual(inherited.effectiveProfile.oracle, globalTarget)

        let rematerialized = try await service.replaceProjectAgentModels(
            projectID: projectID,
            request: .init(expectedRevision: 2, mode: .projectOverride, profile: nil),
            attribution: Self.attribution
        )
        XCTAssertEqual(rematerialized.projectMode, .projectOverride)
        XCTAssertEqual(rematerialized.effectiveProfile.oracle, projectTarget)

        let copiedToGlobal = try await service.copyProjectAgentModelsToGlobal(
            projectID: projectID,
            request: .init(expectedGlobalRevision: 1, expectedProjectRevision: 3),
            attribution: Self.attribution
        )
        XCTAssertEqual(copiedToGlobal.globalProfile.oracle, projectTarget)
        XCTAssertEqual(copiedToGlobal.effectiveProfile.oracle, projectTarget)
        let storedAfterCopy = try await store.agentModelsDocument(scopeID: "global")
        XCTAssertEqual(storedAfterCopy?.value.mode, .inheritGlobal)

        let copiedToProject = try await service.copyGlobalAgentModelsToProject(
            projectID: projectID,
            request: .init(expectedGlobalRevision: 2, expectedProjectRevision: 3),
            attribution: Self.attribution
        )
        XCTAssertEqual(copiedToProject.projectMode, .projectOverride)
        XCTAssertEqual(copiedToProject.effectiveProfile.oracle, projectTarget)
        try await store.close()
    }

    private func assertRoundTrip<T: Codable & Equatable>(_ value: T, file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try JSONEncoder.serviceEncoder.encode(value)
        let decoded = try JSONDecoder.serviceDecoder.decode(T.self, from: data)
        XCTAssertEqual(decoded, value, file: file, line: line)
    }

    private func persistProject(projectID: UUID, rootID: UUID, store: SQLiteServiceStore) async throws {
        let actor = ExternalActor(userID: "settings-test", username: "settings-test", displayName: "Settings Test")
        let project = ProjectSnapshot(
            projectID: projectID,
            name: "Settings",
            creator: actor,
            state: .active,
            roots: [.init(rootID: rootID, logicalName: "root", canonicalPath: "/tmp/settings-root", writable: true)],
            revision: 1,
            cursor: try await store.nextCursor()
        )
        _ = try await store.persistProject(project, eventType: .projectCreated, actor: actor, correlationID: UUID(), idempotency: nil)
    }

    private func removeSQLiteFiles(_ database: URL) {
        try? FileManager.default.removeItem(at: database)
        try? FileManager.default.removeItem(atPath: database.path + "-wal")
        try? FileManager.default.removeItem(atPath: database.path + "-shm")
    }

    private static let attribution = SettingsMutationAttribution(
        actorID: "portal-test",
        actorLabel: "Portal Test",
        channel: "portal-test"
    )

    private static func providerCatalog() -> ProviderSettingsCatalogResponse {
        .init(providers: [
            provider(
                .codex,
                models: [.init(id: "gpt-5.6-sol", displayName: "GPT-5.6 Sol", reasoningEfforts: ["low", "medium", "high"])]
            ),
            provider(
                .claudeCompatible,
                models: [
                    .init(id: "claude-opus-5", displayName: "Claude Opus 5"),
                    .init(id: "claude-sonnet-5", displayName: "Claude Sonnet 5", reasoningEfforts: ["high"]),
                    .init(id: "claude-haiku-5", displayName: "Claude Haiku 5")
                ]
            ),
            provider(
                .claudeGLM,
                models: [.init(id: "claude-sonnet-5", displayName: "Claude Sonnet 5")]
            ),
            provider(
                .cursorACP,
                models: [
                    .init(id: "auto", displayName: "Auto"),
                    .init(id: "composer-2", displayName: "Composer 2")
                ]
            ),
            provider(
                .grokBuildACP,
                models: [.init(id: "grok-code", displayName: "Grok Code")]
            )
        ])
    }

    private static func provider(_ id: ProviderSettingsID, models: [ProviderModelCatalogEntry]) -> ProviderSettingsSnapshot {
        .init(
            providerID: id,
            displayName: id.rawValue,
            category: .cliProvider,
            summary: "test",
            deploymentAllowed: true,
            runtimePreflightVerified: true,
            effectiveEnabled: true,
            preference: .init(providerID: id, enabled: true),
            cli: nil,
            authentication: .init(state: .authenticated, authenticated: true),
            capabilities: .init(
                supportsModelSelection: true,
                supportsReasoningEffort: true,
                supportsSpeedMode: false,
                supportsServiceTier: false,
                authenticationMethods: [],
                authFlows: []
            ),
            models: models
        )
    }
}

private struct StaticProviderCatalog: ServerSettingsProviderCatalogProviding {
    let response: ProviderSettingsCatalogResponse

    func serverSettingsProviderCatalog() async throws -> ProviderSettingsCatalogResponse { response }
}

private actor RecordingContextBuilderRuntime: ContextBuilderRuntimeService {
    private var request: ContextBuilderRuntimeRequest?

    func propose(_ request: ContextBuilderRuntimeRequest) async throws -> ContextBuilderRuntimeProposal {
        self.request = request
        return .init(
            selection: request.workspace.selection.entries,
            response: "context response",
            providerSessionID: "context-provider-session",
            rawProviderOutput: "context response"
        )
    }

    func lastRequest() -> ContextBuilderRuntimeRequest? { request }
}

private actor RecordingOracleRuntime: OracleRuntimeService {
    private var captured: [OracleRuntimeRequest] = []

    func ask(_ request: OracleRuntimeRequest) async throws -> OracleRuntimeResult {
        captured.append(request)
        return .init(
            response: "oracle response",
            providerSessionID: "oracle-provider-session",
            transcriptEntries: []
        )
    }

    func requests() -> [OracleRuntimeRequest] { captured }
}

private struct StaticDirectProviderDefaults: DirectProviderRuntimeDefaultsProviding {
    let values: [ProviderSettingsID: DirectProviderRuntimeDefaults]

    func directProviderRuntimeDefaults(for providerID: ProviderSettingsID) async throws -> DirectProviderRuntimeDefaults {
        values[providerID] ?? .init(mode: "workspaceWrite", providerSettings: [:])
    }
}

private struct StaticProjectCatalog: ServerSettingsProjectCatalogProviding {
    let roots: [UUID: Set<UUID>]

    func serverSettingsRootIDs(projectID: UUID) async throws -> Set<UUID> {
        guard let roots = roots[projectID] else {
            throw ServiceAPIError(code: .notFound, message: "Project not found")
        }
        return roots
    }
}

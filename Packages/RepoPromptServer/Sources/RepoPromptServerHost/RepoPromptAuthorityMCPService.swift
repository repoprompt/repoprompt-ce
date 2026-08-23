import Foundation
import MCP
import RepoPromptAgentRuntimeCore
import RepoPromptAuthorityAPI
import RepoPromptDomainRuntime
import RepoPromptHeadlessRuntime
import RepoPromptServiceProtocol

private typealias RepoPromptMCPBinding = AuthorityMCPBinding
/*
    public let sessionID: UUID
    public let actor: ExternalActor
    /// Desktop `currentClientIdentifier()` — MCP initialize name, not the HTTP actor.
    public let mcpClientID: String

    /// Chat-server Agent Mode sockets are not a Desktop MCP client.
    /// Always Allow matches initialize `clientInfo.name`, never the HTTP actor.
    public static let untrustedClientID = "unknown-client"

    public init(
        sessionID: UUID,
        actor: ExternalActor,
        mcpClientID: String = RepoPromptMCPBinding.untrustedClientID
    ) {
        self.sessionID = sessionID
        self.actor = actor
        self.mcpClientID = mcpClientID
    }
}*/

/// Canonical MCP compatibility transport over the durable headless authority.
///
/// The adapter deliberately owns no project, selection, conversation, run, interaction, or
/// worktree state. Every tool invocation resolves through `RepoPromptHeadlessAuthority`; the
/// canonical domain catalog supplies the exact 27 tool names shared with the macOS product.
public enum RepoPromptAuthorityMCPToolPolicy: Sendable {
    case headlessCodex
    case direct
}

public actor RepoPromptAuthorityMCPService: RepoPromptMCPServing {
    private let authority: RepoPromptHeadlessAuthority
    private let portalSettings: PortalDesktopSettingsService
    private let mutationCapability: AuthorityMutationCapability
    private let toolPolicy: RepoPromptAuthorityMCPToolPolicy
    private let readCapability: AuthorityReadCapability
    private let subscriptionCapability: AuthorityReadCapability

    init(
        authority: RepoPromptHeadlessAuthority,
        portalSettings: PortalDesktopSettingsService,
        mutationCapability: AuthorityMutationCapability,
        toolPolicy: RepoPromptAuthorityMCPToolPolicy = .headlessCodex,
        readCapability: AuthorityReadCapability,
        subscriptionCapability: AuthorityReadCapability
    ) {
        self.authority = authority
        self.portalSettings = portalSettings
        self.mutationCapability = mutationCapability
        self.toolPolicy = toolPolicy
        self.readCapability = readCapability
        self.subscriptionCapability = subscriptionCapability
    }

    public nonisolated static var canonicalToolNames: [String] {
        MCPDomainToolCatalog.orderedToolNames
    }

    static func admitted(
        authority: RepoPromptHeadlessAuthority,
        portalSettings: PortalDesktopSettingsService,
        admissionGate: AuthorityMutationGate,
        toolPolicy: RepoPromptAuthorityMCPToolPolicy = .headlessCodex
    ) async -> RepoPromptAuthorityMCPService {
        RepoPromptAuthorityMCPService(
            authority: authority,
            portalSettings: portalSettings,
            mutationCapability: await admissionGate.capability(),
            toolPolicy: toolPolicy,
            readCapability: await admissionGate.readCapability(),
            subscriptionCapability: await admissionGate.readCapability(subscription: true)
        )
    }

    public func projectSnapshot(id: UUID) async throws -> ProjectSnapshot {
        try await readCapability.perform { [authority] in
            try await authority.projectSnapshot(projectID: id)
        }
    }

    public func sessionSnapshot(id: UUID) async throws -> SessionSnapshot {
        try await readCapability.perform { [authority] in
            try await authority.sessionSnapshot(sessionID: id)
        }
    }

    public func events(after cursor: ServiceCursor?, limit: Int) async throws -> EventPage {
        try await subscriptionCapability.perform { [authority] in
            try await authority.events(after: cursor, limit: limit)
        }
    }

    public func advertisedToolNames(isRootSession: Bool) async throws -> Set<String> {
        var names: Set<String>
        switch toolPolicy {
        case .headlessCodex:
            names = HeadlessCodexMCPToolPolicy.advertisedToolNames(isRootSession: isRootSession)
        case .direct:
            let classification = MCPClientToolPolicyCatalog.classification(for: .direct)
            let restricted = MCPDomainToolCatalog.toolNames(for: classification.restrictedCapabilities)
            let granted = MCPDomainToolCatalog.toolNames(for: classification.grantedCapabilities)
            names = Set(MCPDomainToolCatalog.orderedToolNames.filter { toolName in
                !restricted.contains(toolName)
                    && (
                        !MCPClientToolPolicyCatalog.policyGatedToolNames.contains(toolName)
                            || granted.contains(toolName)
                    )
                    && MCPClientToolPolicyCatalog.shouldAdvertise(
                        toolName: toolName,
                        role: classification.role,
                        allowsAgentExternalControlTools: classification.allowsAgentExternalControlTools
                    )
            })
        }
        let disabledNames = try await readCapability.perform { [authority] in
            await authority.disabledMCPToolNames()
        }
        names.subtract(disabledNames)
        return names
    }

    public func invoke(
        toolName: String,
        argumentsJSON: Data,
        binding: AuthorityMCPBinding
    ) async throws -> Data {
        try await mutationCapability.perform { [self] in
            try await invokeAdmitted(
                toolName: toolName,
                argumentsJSON: argumentsJSON,
                binding: binding
            )
        }
    }

    private func invokeAdmitted(
        toolName: String,
        argumentsJSON: Data,
        binding: AuthorityMCPBinding
    ) async throws -> Data {
        guard Self.canonicalToolNames.contains(toolName) else {
            throw ServiceAPIError(code: .capabilityMissing, message: "Unknown canonical MCP tool")
        }
        if await authority.disabledMCPToolNames().contains(toolName) {
            throw ServiceAPIError(code: .invalidRequest, message: "Tool '\(toolName)' is disabled.")
        }
        let arguments = try JSONDecoder().decode([String: Value].self, from: argumentsJSON)
        try enforceInvocationPolicy(toolName: toolName, arguments: arguments)
        let invocation = try await authority.beginToolInvocation(sessionID: binding.sessionID, toolName: toolName, argumentDigest: CanonicalSigning.bodyDigest(argumentsJSON), actor: binding.actor)
        do {
            let backend = AuthorityToolBackend(
                authority: authority,
                portalSettings: portalSettings,
                binding: binding
            )
            let value = try await backend.invoke(toolName: toolName, arguments: arguments)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(value)
            try await authority.finishToolInvocation(sessionID: binding.sessionID, invocation: invocation, resultDigest: CanonicalSigning.bodyDigest(data), errorCode: nil, actor: binding.actor)
            return data
        } catch {
            let code = (error as? ServiceAPIError)?.code ?? .dependencyUnavailable
            try? await authority.finishToolInvocation(sessionID: binding.sessionID, invocation: invocation, resultDigest: nil, errorCode: code, actor: binding.actor)
            throw error
        }
    }

    private func enforceInvocationPolicy(
        toolName: String,
        arguments: [String: Value]
    ) throws {
        guard case .direct = toolPolicy else { return }
        let denied = toolName == "file_actions"
            || toolName == "apply_edits"
            || (toolName == "prompt" && arguments["op"]?.stringValue == "export")
        guard !denied else {
            throw ServiceAPIError(
                code: .capabilityMissing,
                message: "Direct headless invocation requires an explicit mutation grant"
            )
        }
    }

    package func install(
        runtime: MCPDomainRuntime,
        scopeID: DomainStandaloneScopeID,
        binding: AuthorityMCPBinding
    ) async throws -> MCPDomainStandaloneToolInstallation {
        let backend = AuthorityDomainBackend(adapter: self, binding: binding)
        return try await MCPDomainStandaloneToolInstaller.install(
            runtime: runtime,
            scopeID: scopeID,
            backends: MCPDomainStandaloneCapabilityBackends(
                global: backend,
                workspace: backend,
                filesystem: backend,
                conversation: backend,
                versionControl: backend,
                agent: backend,
                history: backend
            )
        )
    }
}

public extension RepoPromptAuthorityHost {
    func makeMCPService(
        portalSettings: PortalDesktopSettingsService,
        toolPolicy: RepoPromptAuthorityMCPToolPolicy = .headlessCodex
    ) async throws -> RepoPromptAuthorityMCPService {
        let capabilities = try capabilities()
        return await RepoPromptAuthorityMCPService.admitted(
            authority: capabilities.authority,
            portalSettings: portalSettings,
            admissionGate: capabilities.mutationGate,
            toolPolicy: toolPolicy
        )
    }
}

private struct AuthorityDomainBackend: DomainGlobalControlBackend, DomainWorkspaceCapabilityBackend, DomainFilesystemMutationBackend, DomainConversationCapabilityBackend, DomainVersionControlCapabilityBackend, DomainAgentCapabilityBackend, DomainHistoryCapabilityBackend {
    let adapter: RepoPromptAuthorityMCPService
    let binding: AuthorityMCPBinding

    private func call(_ toolName: String, _ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        try await DomainPhysicalToolResult(json: adapter.invoke(toolName: toolName, argumentsJSON: request.argumentsJSON, binding: binding))
    }

    private func call(_ toolName: String, _ request: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult {
        try await call(toolName, request.request)
    }

    func accessSettings(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        try await call(MCPGlobalToolName.appSettings, request)
    }

    func routeContext(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        try await call(MCPGlobalToolName.bindContext, request)
    }

    func manageWorkspaceLifecycle(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        try await call(MCPGlobalToolName.manageWorkspaces, request)
    }

    func mutateSelection(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        try await call(MCPWindowToolName.manageSelection, request)
    }

    func inspectCodeStructure(_ request: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult {
        try await call(MCPWindowToolName.getCodeStructure, request)
    }

    func renderFileTree(_ request: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult {
        try await call(MCPWindowToolName.getFileTree, request)
    }

    func readFile(_ request: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult {
        try await call(MCPWindowToolName.readFile, request)
    }

    func searchFiles(_ request: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult {
        try await call(MCPWindowToolName.search, request)
    }

    func renderWorkspaceContext(_ request: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult {
        try await call(MCPWindowToolName.workspaceContext, request)
    }

    func accessPrompt(_ request: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult {
        try await call(MCPWindowToolName.prompt, request)
    }

    func manageFiles(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        try await call(MCPWindowToolName.fileActions, request)
    }

    func applyFileEdits(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        try await call(MCPWindowToolName.applyEdits, request)
    }

    func accessOracleUtilities(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        try await call(MCPWindowToolName.oracleUtils, request)
    }

    func startOracleConversation(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        try await call(MCPWindowToolName.askOracle, request)
    }

    func continueOracleConversation(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        try await call(MCPWindowToolName.oracleSend, request)
    }

    func readOracleLog(_ request: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult {
        try await call(MCPWindowToolName.oracleChatLog, request)
    }

    func buildContext(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        try await call(MCPWindowToolName.contextBuilder, request)
    }

    func requestUserInput(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        try await call(MCPWindowToolName.askUser, request)
    }

    func inspectGit(_ request: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult {
        try await call(MCPWindowToolName.git, request)
    }

    func manageWorktree(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        try await call(MCPWindowToolName.manageWorktree, request)
    }

    func explore(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        try await call(MCPWindowToolName.agentExplore, request)
    }

    func run(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        try await call(MCPWindowToolName.agentRun, request)
    }

    func manage(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        try await call(MCPWindowToolName.agentManage, request)
    }

    func shareThoughts(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        try await call(MCPWindowToolName.shareThoughts, request)
    }

    func publishStatus(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        try await call(MCPWindowToolName.setStatus, request)
    }

    func waitForInstruction(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        try await call(MCPWindowToolName.waitForNextInstruction, request)
    }

    func inspectHistory(_ request: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult {
        try await call(MCPWindowToolName.history, request)
    }
}

private actor AuthorityToolBackend {
    private struct BoundPath {
        let root: ProjectRootSnapshot
        let physicalRoot: URL
        let logicalPath: String
        let physicalPath: URL
    }

    private let authority: RepoPromptHeadlessAuthority
    private let portalSettings: PortalDesktopSettingsService
    private let binding: AuthorityMCPBinding

    init(
        authority: RepoPromptHeadlessAuthority,
        portalSettings: PortalDesktopSettingsService,
        binding: AuthorityMCPBinding
    ) {
        self.authority = authority
        self.portalSettings = portalSettings
        self.binding = binding
    }

    func invoke(toolName: String, arguments: [String: Value]) async throws -> Value {
        switch toolName {
        case MCPGlobalToolName.appSettings:
            try await appSettings(arguments)
        case MCPGlobalToolName.bindContext:
            try await bindContext()
        case MCPGlobalToolName.manageWorkspaces:
            try await manageWorkspaces(arguments)
        case MCPWindowToolName.manageSelection:
            try await manageSelection(arguments)
        case MCPWindowToolName.fileActions:
            try await manageFiles(arguments)
        case MCPWindowToolName.getCodeStructure:
            try await codeStructure(arguments)
        case MCPWindowToolName.getFileTree:
            try await fileTree(arguments)
        case MCPWindowToolName.readFile:
            try await readFile(arguments)
        case MCPWindowToolName.search:
            try await search(arguments)
        case MCPWindowToolName.workspaceContext:
            try await workspaceContext(arguments)
        case MCPWindowToolName.prompt:
            try await prompt(arguments)
        case MCPWindowToolName.applyEdits:
            try await applyEdits(arguments)
        case MCPWindowToolName.oracleUtils:
            try await oracleUtilities(arguments)
        case MCPWindowToolName.askOracle:
            try await askOracle(arguments, continuing: false)
        case MCPWindowToolName.oracleSend:
            try await askOracle(arguments, continuing: true)
        case MCPWindowToolName.oracleChatLog:
            try await oracleChatLog(arguments)
        case MCPWindowToolName.git:
            try await git(arguments)
        case MCPWindowToolName.manageWorktree:
            try await manageWorktree(arguments)
        case MCPWindowToolName.contextBuilder:
            try await contextBuilder(arguments)
        case MCPWindowToolName.askUser:
            try await askUser(arguments)
        case MCPWindowToolName.agentExplore:
            try await agentLifecycle(arguments, defaultRole: "explore")
        case MCPWindowToolName.agentRun:
            try await agentLifecycle(arguments, defaultRole: "pair")
        case MCPWindowToolName.agentManage:
            try await agentManage(arguments)
        case MCPWindowToolName.history:
            try await history(arguments)
        case MCPWindowToolName.shareThoughts:
            try await shareThoughts(arguments)
        case MCPWindowToolName.setStatus:
            try await setStatus(arguments)
        case MCPWindowToolName.waitForNextInstruction:
            try await waitForInstruction(arguments)
        default:
            throw ServiceAPIError(code: .capabilityMissing, message: "Unknown canonical MCP tool")
        }
    }

    private func appSettings(_ arguments: [String: Value]) async throws -> Value {
        let operation = arguments["op"]?.stringValue ?? "list"
        switch operation {
        case "get":
            if let key = arguments["key"]?.stringValue {
                return try await typedAppSetting(key: key)
            }
        case "set":
            if let key = arguments["key"]?.stringValue {
                return try await replaceTypedAppSetting(key: key, value: arguments["value"])
            }
            throw ServiceAPIError(code: .invalidRequest, message: "app_settings set requires key")
        default:
            break
        }
        let capabilities = try await authority.capabilities()
        let providers = await authority.providerCapabilities(preflight: operation == "list")
        return try value(SettingsResult(
            operation: operation,
            capabilities: capabilities,
            providers: providers
        ))
    }

    private func typedAppSetting(key: String) async throws -> Value {
        switch key {
        case "models.planning_model", "models.preferred_compose_model", "models.sync_chat_model_with_oracle", "models.custom_planning_prompt", "models.file_edit_format", "models.temperature", "models.temperature_enabled", "prompt_packaging.prompt_sections_order", "prompt_packaging.duplicate_user_instructions_at_top", "prompt_packaging.file_path_display_option", "prompt_packaging.include_datetime_in_user_instructions", "context_builder.agent", "context_builder.model":
            return try await routingAppSetting(key: key)
        case "ui.appearance_mode",
             "ui.show_tooltips",
             "ui.enable_keyboard_shortcuts",
             "ui.font_scale",
             "code_maps.globally_disabled",
             "file_system.respect_repo_ignore",
             "file_system.respect_cursorignore",
             "file_system.global_ignore_defaults",
             "file_system.enable_hierarchical_ignores",
             "file_system.skip_symlinks",
             "file_system.show_empty_folders":
            return try await advancedAppSetting(key: key)
        case "direct_agents.codex.sandbox",
             "direct_agents.codex.approval_policy",
             "direct_agents.codex.approval_reviewer",
             "direct_agents.codex.bash_enabled",
             "direct_agents.claude.permission_mode",
             "direct_agents.claude.bash_enabled",
             "direct_agents.claude.mcp_strict",
             "direct_agents.claude.prompt_delivery",
             "direct_agents.opencode.permission_level",
             "direct_agents.cursor.permission_level",
             "subagents.policy",
             "mcp.show_model_presets":
            return try await permissionAppSetting(key: key)
        case "workspace.auto_approve_all",
             "workspace.auto_approve.create_workspace",
             "workspace.auto_approve.delete_workspace",
             "workspace.auto_approve.add_folder",
             "workspace.auto_approve.remove_folder":
            return try await workspaceAppSetting(key: key)
        case "claude.custom.enabled",
             "claude.kimi.model_behavior",
             "claude.kimi.haiku_model",
             "claude.kimi.sonnet_model",
             "claude.kimi.opus_model":
            return try await backendAppSetting(key: key)
        default:
            if Self.directProviderAppSettingKey(key) != nil {
                return try await directProviderAppSetting(key: key)
            }
            if Self.looksLikeCredentialKey(key) {
                throw ServiceAPIError(
                    code: .invalidRequest,
                    message: "CLI credentials are stored by the server connection APIs, not app_settings"
                )
            }
            throw ServiceAPIError(code: .invalidRequest, message: "Unsupported app_settings key '\(key)'")
        }
    }

    private func replaceTypedAppSetting(key: String, value: Value?) async throws -> Value {
        switch key {
        case "models.planning_model", "models.preferred_compose_model", "models.sync_chat_model_with_oracle", "models.custom_planning_prompt", "models.file_edit_format", "models.temperature", "models.temperature_enabled", "prompt_packaging.prompt_sections_order", "prompt_packaging.duplicate_user_instructions_at_top", "prompt_packaging.file_path_display_option", "prompt_packaging.include_datetime_in_user_instructions", "context_builder.agent", "context_builder.model":
            return try await replaceRoutingAppSetting(key: key, value: value)
        case "ui.appearance_mode",
             "ui.show_tooltips",
             "ui.enable_keyboard_shortcuts",
             "ui.font_scale",
             "code_maps.globally_disabled",
             "file_system.respect_repo_ignore",
             "file_system.respect_cursorignore",
             "file_system.global_ignore_defaults",
             "file_system.enable_hierarchical_ignores",
             "file_system.skip_symlinks",
             "file_system.show_empty_folders":
            return try await replaceAdvancedAppSetting(key: key, value: value)
        case "direct_agents.codex.sandbox",
             "direct_agents.codex.approval_policy",
             "direct_agents.codex.approval_reviewer",
             "direct_agents.codex.bash_enabled",
             "direct_agents.claude.permission_mode",
             "direct_agents.claude.bash_enabled",
             "direct_agents.claude.mcp_strict",
             "direct_agents.claude.prompt_delivery",
             "direct_agents.opencode.permission_level",
             "direct_agents.cursor.permission_level":
            return try await replacePermissionAppSetting(key: key, value: value)
        case "subagents.policy":
            return try await replaceSubagentPolicyAppSetting(value: value)
        case "mcp.show_model_presets":
            return try await replaceShowModelPresetsAppSetting(value: value)
        case "workspace.auto_approve_all",
             "workspace.auto_approve.create_workspace",
             "workspace.auto_approve.delete_workspace",
             "workspace.auto_approve.add_folder",
             "workspace.auto_approve.remove_folder":
            return try await replaceWorkspaceAppSetting(key: key, value: value)
        case "claude.custom.enabled",
             "claude.kimi.model_behavior",
             "claude.kimi.haiku_model",
             "claude.kimi.sonnet_model",
             "claude.kimi.opus_model":
            return try await replaceBackendAppSetting(key: key, value: value)
        default:
            if Self.directProviderAppSettingKey(key) != nil {
                return try await replaceDirectProviderAppSetting(key: key, value: value)
            }
            if Self.looksLikeCredentialKey(key) {
                throw ServiceAPIError(
                    code: .invalidRequest,
                    message: "CLI credentials are stored by the server connection APIs, not app_settings"
                )
            }
            throw ServiceAPIError(code: .invalidRequest, message: "Unsupported app_settings key '\(key)'")
        }
    }

    private func permissionAppSetting(key: String) async throws -> Value {
        let settings = try await authority.directAgentPermissions().settings
        let value: Value
        switch key {
        case "direct_agents.codex.sandbox":
            value = .string(settings.codex.sandboxMode.rawValue)
        case "direct_agents.codex.approval_policy":
            value = .string(settings.codex.approvalPolicy.rawValue)
        case "direct_agents.codex.approval_reviewer":
            value = .string(settings.codex.approvalReviewer.rawValue)
        case "direct_agents.codex.bash_enabled":
            value = .bool(settings.codex.bashEnabled)
        case "direct_agents.claude.permission_mode":
            value = .string(settings.claude.permissionMode.rawValue)
        case "direct_agents.claude.bash_enabled":
            value = .bool(settings.claude.bashEnabled)
        case "direct_agents.claude.mcp_strict":
            value = .bool(settings.claude.mcpStrictModeEnabled)
        case "direct_agents.claude.prompt_delivery":
            value = .string(settings.claude.promptDelivery.rawValue)
        case "direct_agents.opencode.permission_level":
            value = .string(settings.openCode.permissionLevel.rawValue)
        case "direct_agents.cursor.permission_level":
            value = .string(settings.cursor.permissionLevel.rawValue)
        case "subagents.policy":
            value = .string(try await authority.subagentPermissions().settings.policy.rawValue)
        case "mcp.show_model_presets":
            value = .bool(try await authority.showModelPresets().settings.showModelPresets)
        default:
            throw ServiceAPIError(code: .invalidRequest, message: "Unsupported app_settings key '\(key)'")
        }
        return .object(["key": .string(key), "value": value])
    }

    private func replacePermissionAppSetting(key: String, value: Value?) async throws -> Value {
        let current = try await authority.directAgentPermissions()
        var settings = current.settings
        switch key {
        case "direct_agents.codex.sandbox":
            settings.codex.sandboxMode = try Self.enumValue(value, as: CodexSandboxMode.self, key: key)
        case "direct_agents.codex.approval_policy":
            settings.codex.approvalPolicy = try Self.enumValue(value, as: CodexApprovalPolicy.self, key: key)
        case "direct_agents.codex.approval_reviewer":
            settings.codex.approvalReviewer = try Self.enumValue(value, as: CodexApprovalReviewer.self, key: key)
        case "direct_agents.codex.bash_enabled":
            settings.codex.bashEnabled = try Self.boolValue(value, key: key)
        case "direct_agents.claude.permission_mode":
            settings.claude.permissionMode = try Self.enumValue(value, as: ClaudeDirectPermissionMode.self, key: key)
        case "direct_agents.claude.bash_enabled":
            settings.claude.bashEnabled = try Self.boolValue(value, key: key)
        case "direct_agents.claude.mcp_strict":
            settings.claude.mcpStrictModeEnabled = try Self.boolValue(value, key: key)
        case "direct_agents.claude.prompt_delivery":
            settings.claude.promptDelivery = try Self.enumValue(value, as: ClaudeAgentModePromptDelivery.self, key: key)
        case "direct_agents.opencode.permission_level":
            settings.openCode.permissionLevel = try Self.enumValue(value, as: ManagedDirectPermissionLevel.self, key: key)
        case "direct_agents.cursor.permission_level":
            settings.cursor.permissionLevel = try Self.enumValue(value, as: ManagedDirectPermissionLevel.self, key: key)
        default:
            throw ServiceAPIError(code: .invalidRequest, message: "Unsupported app_settings key '\(key)'")
        }
        _ = try await authority.replaceDirectAgentPermissions(
            .init(expectedRevision: current.revision, settings: settings),
            attribution: settingsAttribution
        )
        return try await permissionAppSetting(key: key)
    }

    private func replaceSubagentPolicyAppSetting(value: Value?) async throws -> Value {
        let current = try await authority.subagentPermissions()
        let policy = try Self.enumValue(value, as: SubagentPermissionPolicy.self, key: "subagents.policy")
        _ = try await authority.replaceSubagentPermissions(
            .init(
                expectedRevision: current.revision,
                settings: .init(
                    policy: policy,
                    codex: current.settings.codex,
                    claude: current.settings.claude,
                    openCode: current.settings.openCode,
                    cursor: current.settings.cursor
                )
            ),
            attribution: settingsAttribution
        )
        return try await permissionAppSetting(key: "subagents.policy")
    }

    private func replaceShowModelPresetsAppSetting(value: Value?) async throws -> Value {
        let current = try await authority.showModelPresets()
        let enabled = try Self.boolValue(value, key: "mcp.show_model_presets")
        _ = try await authority.setShowModelPresets(
            enabled,
            expectedRevision: current.revision,
            attribution: settingsAttribution
        )
        return try await permissionAppSetting(key: "mcp.show_model_presets")
    }

    private static let workspaceAutoApproveOperationKeys: [String: WorkspaceApprovalOperation] = [
        "workspace.auto_approve.create_workspace": .createWorkspace,
        "workspace.auto_approve.delete_workspace": .deleteWorkspace,
        "workspace.auto_approve.add_folder": .addFolder,
        "workspace.auto_approve.remove_folder": .removeFolder
    ]

    private func workspaceAppSetting(key: String) async throws -> Value {
        let settings = try await authority.workspaceApprovals().settings
        let value: Value
        if key == "workspace.auto_approve_all" {
            value = .bool(settings.autoApproveAll)
        } else if let operation = Self.workspaceAutoApproveOperationKeys[key] {
            value = .bool(settings.autoApproveOperations.contains(operation))
        } else {
            throw ServiceAPIError(code: .invalidRequest, message: "Unsupported app_settings key '\(key)'")
        }
        return .object(["key": .string(key), "value": value])
    }

    private func replaceWorkspaceAppSetting(key: String, value: Value?) async throws -> Value {
        let current = try await authority.workspaceApprovals()
        var settings = current.settings
        if key == "workspace.auto_approve_all" {
            settings.autoApproveAll = try Self.boolValue(value, key: key)
        } else if let operation = Self.workspaceAutoApproveOperationKeys[key] {
            settings.setAutoApproveOperation(operation, enabled: try Self.boolValue(value, key: key))
        } else {
            throw ServiceAPIError(code: .invalidRequest, message: "Unsupported app_settings key '\(key)'")
        }
        _ = try await authority.replaceWorkspaceApprovals(
            .init(expectedRevision: current.revision, settings: settings),
            attribution: settingsAttribution
        )
        return try await workspaceAppSetting(key: key)
    }

    private static let backendAppSettingKeys: [String: PortalDesktopSettingKey] = [
        "claude.custom.enabled": .claudeCustomEnabled,
        "claude.kimi.model_behavior": .claudeKimiModelBehavior,
        "claude.kimi.haiku_model": .claudeKimiHaikuModel,
        "claude.kimi.sonnet_model": .claudeKimiSonnetModel,
        "claude.kimi.opus_model": .claudeKimiOpusModel
    ]

    private func backendAppSetting(key: String) async throws -> Value {
        guard let settingKey = Self.backendAppSettingKeys[key] else {
            throw ServiceAPIError(code: .invalidRequest, message: "Unsupported app_settings key '\(key)'")
        }
        let snapshot = try await portalSettings.snapshot()
        let raw = snapshot.values[settingKey.rawValue] ?? settingKey.defaultValue
        let value: Value
        if settingKey == .claudeCustomEnabled {
            value = .bool(raw == "true")
        } else {
            value = .string(raw)
        }
        return .object(["key": .string(key), "value": value])
    }

    private func replaceBackendAppSetting(key: String, value: Value?) async throws -> Value {
        guard let settingKey = Self.backendAppSettingKeys[key] else {
            throw ServiceAPIError(code: .invalidRequest, message: "Unsupported app_settings key '\(key)'")
        }
        let encoded: String
        if settingKey == .claudeCustomEnabled {
            encoded = try Self.boolValue(value, key: key) ? "true" : "false"
        } else if let raw = value?.stringValue {
            encoded = raw
        } else {
            throw ServiceAPIError(code: .invalidRequest, message: "\(key) must be a string")
        }
        let current = try await portalSettings.snapshot()
        _ = try await portalSettings.update(
            .init(expectedRevision: current.revision, changes: [settingKey.rawValue: encoded])
        )
        return try await backendAppSetting(key: key)
    }

    private struct DirectProviderAppSettingKey {
        let providerID: ProviderSettingsID
        let field: Field

        enum Field: String {
            case preferredModel = "preferred_model"
            case baseURL = "base_url"
            case maximumOutputTokens = "maximum_output_tokens"
            case apiVersion = "api_version"
            case enabledModels = "enabled_models"
            case includeDefaultModels = "include_default_models"
            case useCustomSettings = "use_custom_settings"
            case includeContentTypeHeader = "include_content_type_header"
            case showServiceTierVariants = "show_service_tier_variants"
            case customHeaders = "custom_headers"
        }
    }

    private static func directProviderAppSettingKey(_ key: String) -> DirectProviderAppSettingKey? {
        let parts = key.split(separator: ".").map(String.init)
        guard parts.count == 3,
              parts[0] == "direct_providers",
              let providerID = ProviderSettingsID(rawValue: parts[1]),
              providerID.isDirectAPI,
              let field = DirectProviderAppSettingKey.Field(rawValue: parts[2])
        else { return nil }
        return DirectProviderAppSettingKey(providerID: providerID, field: field)
    }

    private func directProviderAppSetting(key: String) async throws -> Value {
        guard let parsed = Self.directProviderAppSettingKey(key) else {
            throw ServiceAPIError(code: .invalidRequest, message: "Unsupported app_settings key '\(key)'")
        }
        let configuration = try await authority.directConfiguration(providerID: parsed.providerID)
        let value: Value
        switch parsed.field {
        case .preferredModel:
            value = configuration.preferredModel.map(Value.string) ?? .null
        case .baseURL:
            value = configuration.baseURL.map(Value.string) ?? .null
        case .maximumOutputTokens:
            value = .int(configuration.maximumOutputTokens)
        case .apiVersion:
            value = configuration.apiVersion.map(Value.string) ?? .null
        case .enabledModels:
            value = .array(configuration.enabledModels.map(Value.string))
        case .includeDefaultModels:
            value = .bool(configuration.includeDefaultModels)
        case .useCustomSettings:
            value = .bool(configuration.useCustomSettings)
        case .includeContentTypeHeader:
            value = .bool(configuration.includeContentTypeHeader)
        case .showServiceTierVariants:
            value = .bool(configuration.showServiceTierVariants)
        case .customHeaders:
            value = .object(configuration.customHeaders.mapValues(Value.string))
        }
        return .object(["key": .string(key), "value": value])
    }

    private func replaceDirectProviderAppSetting(key: String, value: Value?) async throws -> Value {
        guard let parsed = Self.directProviderAppSettingKey(key) else {
            throw ServiceAPIError(code: .invalidRequest, message: "Unsupported app_settings key '\(key)'")
        }
        switch parsed.field {
        case .baseURL:
            guard parsed.providerID.acceptsPersistedBaseURL else {
                throw ServiceAPIError(code: .invalidRequest, message: "\(key) is not persisted for this provider")
            }
        case .apiVersion:
            guard parsed.providerID.acceptsPersistedAPIVersion else {
                throw ServiceAPIError(code: .invalidRequest, message: "\(key) is not persisted for this provider")
            }
        case .customHeaders:
            guard parsed.providerID.acceptsCustomHeaders else {
                throw ServiceAPIError(code: .invalidRequest, message: "\(key) is not persisted for this provider")
            }
        default:
            break
        }
        let current = try await authority.directConfiguration(providerID: parsed.providerID)
        let request = UpdateDirectProviderConfigurationRequest(
            expectedRevision: current.revision,
            baseURL: parsed.field == .baseURL ? Self.optionalString(value, key: key) : current.baseURL,
            preferredModel: parsed.field == .preferredModel ? Self.optionalString(value, key: key) : current.preferredModel,
            maximumOutputTokens: parsed.field == .maximumOutputTokens
                ? try Self.maximumOutputTokensValue(value, key: key)
                : current.maximumOutputTokens,
            customHeaders: parsed.field == .customHeaders
                ? try Self.stringMapValue(value, key: key)
                : current.customHeaders,
            contentTypePolicy: current.contentTypePolicy,
            apiVersion: parsed.field == .apiVersion ? Self.optionalString(value, key: key) : current.apiVersion,
            enabledModels: parsed.field == .enabledModels
                ? try Self.stringArrayValue(value, key: key)
                : current.enabledModels,
            includeDefaultModels: parsed.field == .includeDefaultModels
                ? try Self.boolValue(value, key: key)
                : current.includeDefaultModels,
            useCustomSettings: parsed.field == .useCustomSettings
                ? try Self.boolValue(value, key: key)
                : current.useCustomSettings,
            includeContentTypeHeader: parsed.field == .includeContentTypeHeader
                ? try Self.boolValue(value, key: key)
                : current.includeContentTypeHeader,
            showServiceTierVariants: parsed.field == .showServiceTierVariants
                ? try Self.boolValue(value, key: key)
                : current.showServiceTierVariants
        )
        _ = try await authority.updateDirectConfiguration(
            providerID: parsed.providerID,
            request: request,
            attribution: settingsAttribution
        )
        return try await directProviderAppSetting(key: key)
    }

    private static func optionalString(_ value: Value?, key: String) -> String? {
        let raw = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? nil : raw
    }

    private static func maximumOutputTokensValue(_ value: Value?, key: String) throws -> Int {
        let parsed: Int?
        if let integer = value?.intValue {
            parsed = integer
        } else if let raw = value?.stringValue {
            parsed = Int(raw)
        } else {
            parsed = nil
        }
        guard let tokens = parsed, (0 ... 65_536).contains(tokens) else {
            throw ServiceAPIError(code: .invalidRequest, message: "\(key) must be an integer from 0 through 65536")
        }
        return tokens
    }

    private static func stringArrayValue(_ value: Value?, key: String) throws -> [String] {
        if let items = value?.arrayValue {
            let strings = items.compactMap(\.stringValue).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard strings.count == items.count else {
                throw ServiceAPIError(code: .invalidRequest, message: "\(key) must be an array of strings")
            }
            return strings
        }
        if let raw = value?.stringValue {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return [] }
            if let data = trimmed.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([String].self, from: data)
            {
                return decoded.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            }
        }
        throw ServiceAPIError(code: .invalidRequest, message: "\(key) must be an array of strings")
    }

    private static func stringMapValue(_ value: Value?, key: String) throws -> [String: String] {
        if let object = value?.objectValue {
            var mapped: [String: String] = [:]
            for (header, raw) in object {
                guard let string = raw.stringValue else {
                    throw ServiceAPIError(code: .invalidRequest, message: "\(key) values must be strings")
                }
                mapped[header] = string
            }
            return mapped
        }
        if let raw = value?.stringValue {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return [:] }
            if let data = trimmed.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([String: String].self, from: data)
            {
                return decoded
            }
        }
        throw ServiceAPIError(code: .invalidRequest, message: "\(key) must be a JSON object of strings")
    }

    private static func looksLikeCredentialKey(_ key: String) -> Bool {
        let lowered = key.lowercased()
        let parts = lowered.split { $0 == "." || $0 == "_" || $0 == "-" }.map(String.init)
        let forbidden = Set(["credential", "apikey", "token", "authtoken", "secret", "password"])
        if parts.contains(where: { forbidden.contains($0) }) { return true }
        return ["credential", "api_key", "apikey", "auth_token", "cli_token", "clitoken"]
            .contains { lowered.contains($0) }
    }

    private var settingsAttribution: SettingsMutationAttribution {
        SettingsMutationAttribution(
            actorID: binding.actor.userID,
            actorLabel: binding.actor.displayName,
            channel: "mcp"
        )
    }

    private static func boolValue(_ value: Value?, key: String) throws -> Bool {
        if let bool = value?.boolValue { return bool }
        if let raw = value?.stringValue {
            if raw == "true" { return true }
            if raw == "false" { return false }
        }
        throw ServiceAPIError(code: .invalidRequest, message: "\(key) must be a Boolean")
    }

    private static func temperatureValue(_ value: Value?, key: String) throws -> Double {
        let parsed: Double?
        if let number = value?.doubleValue {
            parsed = number
        } else if let integer = value?.intValue {
            parsed = Double(integer)
        } else if let raw = value?.stringValue {
            parsed = Double(raw)
        } else {
            parsed = nil
        }
        guard let temperature = parsed, (0 ... 2).contains(temperature) else {
            throw ServiceAPIError(code: .invalidRequest, message: "\(key) must be a number between 0 and 2")
        }
        return temperature
    }

    private static func promptSectionsOrderValue(_ value: Value?, key: String) throws -> String {
        guard let raw = value?.stringValue,
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([PromptSection].self, from: data),
              decoded.count == PromptSection.allCases.count,
              Set(decoded) == Set(PromptSection.allCases)
        else {
            throw ServiceAPIError(
                code: .invalidRequest,
                message: "\(key) must be a JSON array of each PromptSection once"
            )
        }
        return PromptSection.encode(decoded)
    }

    private static func enumValue<ValueType: RawRepresentable>(
        _ value: Value?,
        as type: ValueType.Type,
        key: String
    ) throws -> ValueType where ValueType.RawValue == String {
        guard let raw = value?.stringValue, let parsed = type.init(rawValue: raw) else {
            throw ServiceAPIError(code: .invalidRequest, message: "\(key) is not a supported value")
        }
        return parsed
    }

    private func advancedAppSetting(key: String) async throws -> Value {
        let settings = try await authority.advancedSettings().settings
        let value: Value
        switch key {
        case "ui.appearance_mode":
            value = .string(settings.resolvedAppearanceMode().rawValue)
        case "ui.show_tooltips":
            value = .bool(settings.showTooltips)
        case "ui.enable_keyboard_shortcuts":
            value = .bool(settings.enableKeyboardShortcuts)
        case "ui.font_scale":
            value = .double(settings.resolvedFontScale().rawValue)
        case "code_maps.globally_disabled":
            value = .bool(settings.codeMapsGloballyDisabled)
        case "file_system.respect_repo_ignore":
            value = .bool(settings.respectRepoIgnore)
        case "file_system.respect_cursorignore":
            value = .bool(settings.respectCursorIgnore)
        case "file_system.global_ignore_defaults":
            value = .string(settings.globalIgnoreDefaults)
        case "file_system.enable_hierarchical_ignores":
            value = .bool(settings.respectNestedIgnoreFiles)
        case "file_system.skip_symlinks":
            value = .bool(settings.skipSymlinks)
        case "file_system.show_empty_folders":
            value = .bool(settings.showEmptyFolders)
        default:
            throw ServiceAPIError(code: .invalidRequest, message: "Unsupported app_settings key '\(key)'")
        }
        return .object(["key": .string(key), "value": value])
    }

    private func replaceAdvancedAppSetting(key: String, value: Value?) async throws -> Value {
        let current = try await authority.advancedSettings()
        let next: AdvancedServerSettings
        switch key {
        case "ui.appearance_mode":
            next = current.settings.replacing(
                appearanceMode: try Self.enumValue(value, as: AdvancedServerSettings.AppearanceMode.self, key: key).rawValue
            )
        case "ui.show_tooltips":
            next = current.settings.replacing(showTooltips: try Self.boolValue(value, key: key))
        case "ui.enable_keyboard_shortcuts":
            next = current.settings.replacing(enableKeyboardShortcuts: try Self.boolValue(value, key: key))
        case "ui.font_scale":
            next = current.settings.replacing(fontScaleBodySize: try Self.fontScaleValue(value, key: key))
        case "code_maps.globally_disabled":
            next = current.settings.replacing(codeMapsGloballyDisabled: try Self.boolValue(value, key: key))
        case "file_system.respect_repo_ignore":
            next = current.settings.replacing(respectRepoIgnore: try Self.boolValue(value, key: key))
        case "file_system.respect_cursorignore":
            next = current.settings.replacing(respectCursorIgnore: try Self.boolValue(value, key: key))
        case "file_system.global_ignore_defaults":
            next = current.settings.replacing(globalIgnoreDefaults: try Self.globalIgnoreDefaultsValue(value, key: key))
        case "file_system.enable_hierarchical_ignores":
            next = current.settings.replacing(respectNestedIgnoreFiles: try Self.boolValue(value, key: key))
        case "file_system.skip_symlinks":
            next = current.settings.replacing(followSymbolicLinks: !(try Self.boolValue(value, key: key)))
        case "file_system.show_empty_folders":
            next = current.settings.replacing(showEmptyFolders: try Self.boolValue(value, key: key))
        default:
            throw ServiceAPIError(code: .invalidRequest, message: "Unsupported app_settings key '\(key)'")
        }
        _ = try await authority.replaceAdvancedSettings(
            .init(expectedRevision: current.revision, settings: next),
            attribution: settingsAttribution
        )
        return try await advancedAppSetting(key: key)
    }

    private static func fontScaleValue(_ value: Value?, key: String) throws -> Double {
        let parsed: Double?
        if let number = value?.doubleValue {
            parsed = number
        } else if let integer = value?.intValue {
            parsed = Double(integer)
        } else if let raw = value?.stringValue {
            parsed = Double(raw)
        } else {
            parsed = nil
        }
        guard let raw = parsed, let preset = AdvancedServerSettings.FontScale(rawValue: raw) else {
            throw ServiceAPIError(
                code: .invalidRequest,
                message: "\(key) must be one of \(AdvancedServerSettings.FontScale.allCases.map { String(format: "%.0f", $0.rawValue) }.joined(separator: ", "))"
            )
        }
        return preset.rawValue
    }

    private static func globalIgnoreDefaultsValue(_ value: Value?, key: String) throws -> String {
        guard let raw = value?.stringValue else {
            throw ServiceAPIError(code: .invalidRequest, message: "\(key) must be a string")
        }
        guard raw.utf8.count <= 20_000 else {
            throw ServiceAPIError(code: .invalidRequest, message: "\(key) exceeds its supported size")
        }
        return raw
    }

    private func routingAppSetting(key: String) async throws -> Value {
        let snapshot = try await authority.globalAgentModels()
        let profile = snapshot.effectiveProfile
        switch key {
        case "models.planning_model":
            return .object([
                "key": .string(key),
                "value": profile.oracle.flatMap(Self.compoundID).map(Value.string) ?? .null
            ])
        case "models.preferred_compose_model":
            return .object([
                "key": .string(key),
                "value": profile.resolvedComposeModelRaw().map(Value.string) ?? .null
            ])
        case "models.sync_chat_model_with_oracle":
            return .object([
                "key": .string(key),
                "value": .bool(profile.resolvedSyncChatModelWithOracle())
            ])
        case "models.custom_planning_prompt":
            let settings = try await authority.advancedSettings().settings
            return .object([
                "key": .string(key),
                "value": .string(settings.customPlanningPrompt)
            ])
        case "models.file_edit_format":
            let settings = try await authority.advancedSettings().settings
            return .object([
                "key": .string(key),
                "value": .string(settings.resolvedFileEditFormat().rawValue)
            ])
        case "models.temperature":
            let settings = try await authority.advancedSettings().settings
            return .object([
                "key": .string(key),
                "value": .double(settings.modelTemperature)
            ])
        case "models.temperature_enabled":
            let settings = try await authority.advancedSettings().settings
            return .object([
                "key": .string(key),
                "value": .bool(settings.setModelTemperature)
            ])
        case "prompt_packaging.prompt_sections_order":
            let settings = try await authority.advancedSettings().settings
            return .object([
                "key": .string(key),
                "value": .string(PromptSection.encode(settings.resolvedPromptSectionOrder()))
            ])
        case "prompt_packaging.duplicate_user_instructions_at_top":
            let settings = try await authority.advancedSettings().settings
            return .object([
                "key": .string(key),
                "value": .bool(settings.duplicateUserInstructionsAtTop)
            ])
        case "prompt_packaging.file_path_display_option":
            let settings = try await authority.advancedSettings().settings
            return .object([
                "key": .string(key),
                "value": .string(settings.resolvedFilePathDisplay().rawValue)
            ])
        case "prompt_packaging.include_datetime_in_user_instructions":
            let settings = try await authority.advancedSettings().settings
            return .object([
                "key": .string(key),
                "value": .bool(settings.includeDatetimeInUserInstructions)
            ])
        case "context_builder.agent":
            return .object([
                "key": .string(key),
                "value": profile.contextBuilder.map { .string($0.providerID.rawValue) } ?? .null
            ])
        case "context_builder.model":
            return .object([
                "key": .string(key),
                "value": profile.contextBuilder?.modelID.map(Value.string) ?? .null
            ])
        default:
            throw ServiceAPIError(code: .invalidRequest, message: "Unsupported app_settings key '\(key)'")
        }
    }

    private func replaceRoutingAppSetting(key: String, value: Value?) async throws -> Value {
        let current = try await authority.globalAgentModels()
        var profile = current.globalProfile
        switch key {
        case "models.planning_model":
            profile = profile.replacing(.oracle, with: try Self.agentTarget(fromCompoundOrModel: value?.stringValue))
        case "models.preferred_compose_model":
            profile = profile.replacingComposeModel(value?.stringValue)
        case "models.sync_chat_model_with_oracle":
            profile = profile.replacingSyncChatModelWithOracle(try Self.boolValue(value, key: key))
        case "models.custom_planning_prompt":
            let currentAdvanced = try await authority.advancedSettings()
            let next = currentAdvanced.settings.replacing(customPlanningPrompt: value?.stringValue ?? "")
            _ = try await authority.replaceAdvancedSettings(
                .init(expectedRevision: currentAdvanced.revision, settings: next),
                attribution: SettingsMutationAttribution(
                    actorID: binding.actor.userID,
                    actorLabel: binding.actor.displayName,
                    channel: "mcp"
                )
            )
            return try await routingAppSetting(key: key)
        case "models.file_edit_format":
            let currentAdvanced = try await authority.advancedSettings()
            let next = currentAdvanced.settings.replacing(fileEditFormat: value?.stringValue ?? AdvancedServerSettings.FileEditFormat.defaultRaw)
            _ = try await authority.replaceAdvancedSettings(
                .init(expectedRevision: currentAdvanced.revision, settings: next),
                attribution: SettingsMutationAttribution(
                    actorID: binding.actor.userID,
                    actorLabel: binding.actor.displayName,
                    channel: "mcp"
                )
            )
            return try await routingAppSetting(key: key)
        case "models.temperature":
            let currentAdvanced = try await authority.advancedSettings()
            let next = currentAdvanced.settings.replacing(modelTemperature: try Self.temperatureValue(value, key: key))
            _ = try await authority.replaceAdvancedSettings(
                .init(expectedRevision: currentAdvanced.revision, settings: next),
                attribution: SettingsMutationAttribution(
                    actorID: binding.actor.userID,
                    actorLabel: binding.actor.displayName,
                    channel: "mcp"
                )
            )
            return try await routingAppSetting(key: key)
        case "models.temperature_enabled":
            let currentAdvanced = try await authority.advancedSettings()
            let next = currentAdvanced.settings.replacing(setModelTemperature: try Self.boolValue(value, key: key))
            _ = try await authority.replaceAdvancedSettings(
                .init(expectedRevision: currentAdvanced.revision, settings: next),
                attribution: SettingsMutationAttribution(
                    actorID: binding.actor.userID,
                    actorLabel: binding.actor.displayName,
                    channel: "mcp"
                )
            )
            return try await routingAppSetting(key: key)
        case "prompt_packaging.prompt_sections_order":
            let currentAdvanced = try await authority.advancedSettings()
            let next = currentAdvanced.settings.replacing(promptSectionsOrder: try Self.promptSectionsOrderValue(value, key: key))
            _ = try await authority.replaceAdvancedSettings(
                .init(expectedRevision: currentAdvanced.revision, settings: next),
                attribution: SettingsMutationAttribution(
                    actorID: binding.actor.userID,
                    actorLabel: binding.actor.displayName,
                    channel: "mcp"
                )
            )
            return try await routingAppSetting(key: key)
        case "prompt_packaging.duplicate_user_instructions_at_top":
            let currentAdvanced = try await authority.advancedSettings()
            let next = currentAdvanced.settings.replacing(duplicateUserInstructionsAtTop: try Self.boolValue(value, key: key))
            _ = try await authority.replaceAdvancedSettings(
                .init(expectedRevision: currentAdvanced.revision, settings: next),
                attribution: SettingsMutationAttribution(
                    actorID: binding.actor.userID,
                    actorLabel: binding.actor.displayName,
                    channel: "mcp"
                )
            )
            return try await routingAppSetting(key: key)
        case "prompt_packaging.file_path_display_option":
            let currentAdvanced = try await authority.advancedSettings()
            let next = currentAdvanced.settings.replacing(
                filePathDisplayOption: try Self.enumValue(value, as: AdvancedServerSettings.FilePathDisplay.self, key: key).rawValue
            )
            _ = try await authority.replaceAdvancedSettings(
                .init(expectedRevision: currentAdvanced.revision, settings: next),
                attribution: SettingsMutationAttribution(
                    actorID: binding.actor.userID,
                    actorLabel: binding.actor.displayName,
                    channel: "mcp"
                )
            )
            return try await routingAppSetting(key: key)
        case "prompt_packaging.include_datetime_in_user_instructions":
            let currentAdvanced = try await authority.advancedSettings()
            let next = currentAdvanced.settings.replacing(includeDatetimeInUserInstructions: try Self.boolValue(value, key: key))
            _ = try await authority.replaceAdvancedSettings(
                .init(expectedRevision: currentAdvanced.revision, settings: next),
                attribution: SettingsMutationAttribution(
                    actorID: binding.actor.userID,
                    actorLabel: binding.actor.displayName,
                    channel: "mcp"
                )
            )
            return try await routingAppSetting(key: key)
        case "context_builder.agent":
            guard let raw = value?.stringValue, let providerID = Self.providerSettingsID(fromAppSettings: raw) else {
                throw ServiceAPIError(code: .invalidRequest, message: "context_builder.agent must be a known CLI agent")
            }
            profile = profile.replacing(.contextBuilder, with: AgentModelTarget(providerID: providerID, modelID: profile.contextBuilder?.modelID))
        case "context_builder.model":
            guard let currentBuilder = profile.contextBuilder else {
                throw ServiceAPIError(code: .invalidRequest, message: "context_builder.agent must be configured before setting context_builder.model")
            }
            profile = profile.replacing(
                .contextBuilder,
                with: AgentModelTarget(providerID: currentBuilder.providerID, modelID: value?.stringValue)
            )
        default:
            throw ServiceAPIError(code: .invalidRequest, message: "Unsupported app_settings key '\(key)'")
        }
        _ = try await authority.replaceGlobalAgentModels(
            .init(expectedRevision: current.globalRevision, profile: profile),
            attribution: SettingsMutationAttribution(
                actorID: binding.actor.userID,
                actorLabel: binding.actor.displayName,
                channel: "mcp"
            )
        )
        return try await routingAppSetting(key: key)
    }

    private static func compoundID(_ target: AgentModelTarget) -> String? {
        guard let modelID = target.modelID, !modelID.isEmpty else { return nil }
        return "\(target.providerID.rawValue):\(modelID)"
    }

    private static func agentTarget(fromCompoundOrModel raw: String?) throws -> AgentModelTarget? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains(":") {
            let start = try MCPAgentStartTarget.resolve(modelID: trimmed, defaultRole: "pair")
            guard let providerID = start.providerSettingsID, let model = start.model else {
                throw ServiceAPIError(code: .invalidRequest, message: "Invalid models.planning_model '\(trimmed)'")
            }
            return AgentModelTarget(providerID: providerID, modelID: model)
        }
        throw ServiceAPIError(
            code: .invalidRequest,
            message: "models.planning_model must be a compound agent:model ID"
        )
    }

    private static func providerSettingsID(fromAppSettings raw: String) -> ProviderSettingsID? {
        ProviderSettingsID(rawValue: raw) ?? {
            switch raw {
            case "codexExec": .codex
            case "claudeCode": .claudeCompatible
            case "openCode": .openCodeACP
            case "cursor": .cursorACP
            case "grokBuild": .grokBuildACP
            default: nil
            }
        }()
    }

    private func bindContext() async throws -> Value {
        let session = try await session()
        return .object([
            "session_id": .string(session.sessionID.uuidString),
            "project_id": .string(session.projectID.uuidString),
            "root_session_id": .string(session.rootSessionID.uuidString),
            "authority": .string("RepoPromptHeadlessAuthority")
        ])
    }

    private func manageWorkspaces(_ arguments: [String: Value]) async throws -> Value {
        let action = arguments["action"]?.stringValue ?? arguments["op"]?.stringValue ?? "list"
        if let operation = WorkspaceApprovalOperation(mcpAction: action) {
            try await authority.authorizeWorkspaceOperation(operation, clientID: binding.mcpClientID)
        }
        let operation = arguments["op"]?.stringValue ?? "list"
        let projects = await authority.projectSnapshots()
        let sessions = try await authority.sessionSnapshots()
        return try value(WorkspaceResult(operation: operation, projects: projects, sessions: sessions))
    }

    private func manageSelection(_ arguments: [String: Value]) async throws -> Value {
        let current = try await authority.selectionSnapshot(sessionID: binding.sessionID)
        let operation = arguments["op"]?.stringValue ?? "get"
        guard !["get", "preview"].contains(operation) else { return try value(current) }

        let requested = arguments["paths"]?.arrayValue?.compactMap(\.stringValue) ?? []
        var entries = current.entries
        switch operation {
        case "clear":
            entries = []
        case "set":
            entries = try await selectionEntries(paths: requested, mode: .full)
        case "add":
            let additions = try await selectionEntries(paths: requested, mode: .full)
            for entry in additions where !entries.contains(entry) {
                entries.append(entry)
            }
        case "remove":
            let removals = try await Set(selectionEntries(paths: requested, mode: .full).map {
                "\($0.rootID.uuidString):\($0.logicalPath)"
            })
            entries.removeAll { removals.contains("\($0.rootID.uuidString):\($0.logicalPath)") }
        case "promote":
            let promoted = try await Set(selectionEntries(paths: requested, mode: .full).map {
                "\($0.rootID.uuidString):\($0.logicalPath)"
            })
            entries = entries.map {
                promoted.contains("\($0.rootID.uuidString):\($0.logicalPath)")
                    ? LogicalSelectionEntry(rootID: $0.rootID, logicalPath: $0.logicalPath, mode: .full)
                    : $0
            }
        case "demote":
            if try await authority.advancedSettings().settings.codeMapsGloballyDisabled {
                throw ServiceAPIError(code: .invalidRequest, message: AdvancedServerSettings.codeMapsGloballyDisabledMCPMessage)
            }
            let demoted = try await Set(selectionEntries(paths: requested, mode: .codeMap).map {
                "\($0.rootID.uuidString):\($0.logicalPath)"
            })
            entries = entries.map {
                demoted.contains("\($0.rootID.uuidString):\($0.logicalPath)")
                    ? LogicalSelectionEntry(rootID: $0.rootID, logicalPath: $0.logicalPath, mode: .codeMap)
                    : $0
            }
        default:
            throw ServiceAPIError(code: .invalidRequest, message: "Unsupported selection operation")
        }
        return try await value(authority.replaceSelection(
            sessionID: binding.sessionID,
            entries: entries,
            expectedRevision: current.revision,
            actor: binding.actor
        ))
    }

    private func fileTree(_ arguments: [String: Value]) async throws -> Value {
        let project = try await project()
        if arguments["type"]?.stringValue == "roots" { return try value(project.roots) }
        let maximumDepth = min(max(arguments["max_depth"]?.intValue ?? 6, 0), 32)
        let maximumEntries = min(max(arguments["maximum_entries"]?.intValue ?? 5000, 1), 10000)
        if let rawPath = arguments["path"]?.stringValue {
            let path = try await resolve(rawPath, allowMissingLeaf: false)
            return try await value(authority.sessionProjectTree(
                sessionID: binding.sessionID,
                request: ProjectTreeRequest(
                    rootID: path.root.rootID,
                    logicalPath: path.logicalPath,
                    maximumDepth: maximumDepth,
                    maximumEntries: maximumEntries
                )
            ))
        }
        var entries: [ProjectTreeEntry] = []
        for root in project.roots {
            entries += try await authority.sessionProjectTree(
                sessionID: binding.sessionID,
                request: ProjectTreeRequest(
                    rootID: root.rootID,
                    maximumDepth: maximumDepth,
                    maximumEntries: max(1, maximumEntries - entries.count)
                )
            )
            if entries.count >= maximumEntries { break }
        }
        return try value(Array(entries.prefix(maximumEntries)))
    }

    private func readFile(_ arguments: [String: Value]) async throws -> Value {
        guard let rawPath = arguments["path"]?.stringValue else {
            throw ServiceAPIError(code: .invalidRequest, message: "read_file requires path")
        }
        let path = try await resolve(rawPath, allowMissingLeaf: false)
        let snapshot = try await authority.sessionProjectFile(
            sessionID: binding.sessionID,
            request: ProjectFileRequest(
                rootID: path.root.rootID,
                logicalPath: path.logicalPath,
                startLine: arguments["start_line"]?.intValue,
                lineCount: arguments["limit"]?.intValue
            )
        )
        return try value(snapshot)
    }

    private func search(_ arguments: [String: Value]) async throws -> Value {
        guard let query = arguments["pattern"]?.stringValue ?? arguments["query"]?.stringValue,
              !query.isEmpty
        else { throw ServiceAPIError(code: .invalidRequest, message: "file_search requires pattern") }
        let project = try await project()
        let requestedPath = arguments["path"]?.stringValue
        let roots: [(ProjectRootSnapshot, String)]
        if let requestedPath {
            let path = try await resolve(requestedPath, allowMissingLeaf: false)
            roots = [(path.root, path.logicalPath)]
        } else {
            roots = project.roots.map { ($0, "") }
        }
        var hits: [ProjectSearchHit] = []
        let limit = min(max(arguments["max_results"]?.intValue ?? 200, 1), 1000)
        for (root, logicalPath) in roots {
            hits += try await authority.sessionProjectSearch(
                sessionID: binding.sessionID,
                request: ProjectSearchRequest(
                    rootID: root.rootID,
                    query: query,
                    logicalPath: logicalPath,
                    useRegex: arguments["regex"]?.boolValue ?? false,
                    maximumResults: max(1, limit - hits.count)
                )
            )
            if hits.count >= limit { break }
        }
        return try value(Array(hits.prefix(limit)))
    }

    private func codeStructure(_ arguments: [String: Value]) async throws -> Value {
        if try await authority.advancedSettings().settings.codeMapsGloballyDisabled {
            return try value(CodeStructureResult(
                files: [],
                updatesPending: false,
                issues: [
                    .init(
                        code: "codemaps_disabled",
                        message: "Codemap generation is disabled."
                    )
                ]
            ))
        }
        let selection = try await authority.selectionSnapshot(sessionID: binding.sessionID)
        let requested = arguments["paths"]?.arrayValue?.compactMap(\.stringValue) ?? []
        var paths = requested
        if paths.isEmpty {
            for entry in selection.entries {
                try await paths.append(physicalPath(for: entry))
            }
        }
        var maps: [ProjectCodeMapSnapshot] = []
        for rawPath in paths.prefix(256) {
            let path = try await resolve(rawPath, allowMissingLeaf: false)
            try await maps.append(authority.sessionProjectCodeMap(
                sessionID: binding.sessionID,
                request: ProjectCodeMapRequest(rootID: path.root.rootID, logicalPath: path.logicalPath)
            ))
        }
        return try value(CodeStructureResult(files: maps, updatesPending: false, issues: nil))
    }

    private func workspaceContext(_ arguments: [String: Value]) async throws -> Value {
        let selection = try await authority.selectionSnapshot(sessionID: binding.sessionID)
        let include = arguments["include"]?.arrayValue?.compactMap(\.stringValue)
            ?? ["prompt", "selection", "files", "code"]
        let artifact = try await authority.buildContext(
            sessionID: binding.sessionID,
            expectedSelectionRevision: selection.revision,
            include: include,
            actor: binding.actor
        )
        let content = try await authority.artifactContent(artifactID: artifact.artifactID, maximumBytes: 8_388_608)
        return try .object([
            "artifact": value(artifact),
            "content": .string(String(decoding: content, as: UTF8.self))
        ])
    }

    private func prompt(_ arguments: [String: Value]) async throws -> Value {
        let operation = arguments["op"]?.stringValue ?? "get"
        var context = try await authority.sessionContext(sessionID: binding.sessionID)
        switch operation {
        case "get": break
        case "set":
            try await MCPDomainMutationCommitContext.willCommit()
            context = try await authority.updateSessionPrompt(
                sessionID: binding.sessionID,
                prompt: arguments["text"]?.stringValue ?? "",
                expectedContextRevision: context.contextRevision,
                actor: binding.actor
            )
        case "append":
            try await MCPDomainMutationCommitContext.willCommit()
            context = try await authority.updateSessionPrompt(
                sessionID: binding.sessionID,
                prompt: context.prompt + (arguments["text"]?.stringValue ?? ""),
                expectedContextRevision: context.contextRevision,
                actor: binding.actor
            )
        case "clear":
            try await MCPDomainMutationCommitContext.willCommit()
            context = try await authority.updateSessionPrompt(
                sessionID: binding.sessionID,
                prompt: "",
                expectedContextRevision: context.contextRevision,
                actor: binding.actor
            )
        default:
            throw ServiceAPIError(code: .invalidRequest, message: "Unsupported prompt operation")
        }
        return try value(context)
    }

    private func manageFiles(_ arguments: [String: Value]) async throws -> Value {
        guard let operation = arguments["action"]?.stringValue else {
            throw ServiceAPIError(code: .invalidRequest, message: "file_actions requires action")
        }
        guard let rawPath = arguments["path"]?.stringValue else {
            throw ServiceAPIError(code: .invalidRequest, message: "file_actions requires path")
        }
        let source = try await resolve(rawPath, allowMissingLeaf: operation == "create")
        guard source.root.writable else {
            throw ServiceAPIError(code: .rootUnauthorized, message: "Project root is read-only")
        }
        switch operation {
        case "create":
            let overwrite = arguments["if_exists"]?.stringValue == "overwrite"
            if FileManager.default.fileExists(atPath: source.physicalPath.path), !overwrite {
                throw ServiceAPIError(code: .staleRevision, message: "Destination already exists")
            }
            try FileManager.default.createDirectory(
                at: source.physicalPath.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data((arguments["content"]?.stringValue ?? "").utf8).write(
                to: source.physicalPath,
                options: .atomic
            )
        case "delete":
            try FileManager.default.removeItem(at: source.physicalPath)
        case "move":
            guard let destinationRaw = arguments["new_path"]?.stringValue else {
                throw ServiceAPIError(code: .invalidRequest, message: "move requires new_path")
            }
            let destination = try await resolve(destinationRaw, allowMissingLeaf: true)
            guard destination.root.rootID == source.root.rootID else {
                throw ServiceAPIError(code: .rootUnauthorized, message: "Cross-root moves are unavailable")
            }
            try FileManager.default.moveItem(at: source.physicalPath, to: destination.physicalPath)
        default:
            throw ServiceAPIError(code: .invalidRequest, message: "Unsupported file action")
        }
        return .object(["action": .string(operation), "path": .string(source.logicalPath), "ok": .bool(true)])
    }

    private func applyEdits(_ arguments: [String: Value]) async throws -> Value {
        guard let rawPath = arguments["path"]?.stringValue else {
            throw ServiceAPIError(code: .invalidRequest, message: "apply_edits requires path")
        }
        let path = try await resolve(rawPath, allowMissingLeaf: arguments["rewrite"] != nil)
        guard path.root.writable else {
            throw ServiceAPIError(code: .rootUnauthorized, message: "Project root is read-only")
        }
        let existing = (try? String(contentsOf: path.physicalPath, encoding: .utf8)) ?? ""
        let updated: String
        if let rewrite = arguments["rewrite"]?.stringValue {
            updated = rewrite
        } else if let edits = arguments["edits"]?.arrayValue {
            updated = try edits.reduce(existing) { partial, raw in
                guard let object = raw.objectValue,
                      let search = object["search"]?.stringValue,
                      let replacement = object["replace"]?.stringValue
                else { throw ServiceAPIError(code: .invalidRequest, message: "Invalid edit entry") }
                return try replace(
                    in: partial,
                    search: search,
                    replacement: replacement,
                    all: object["all"]?.boolValue ?? false
                )
            }
        } else if let search = arguments["search"]?.stringValue,
                  let replacement = arguments["replace"]?.stringValue
        {
            updated = try replace(
                in: existing,
                search: search,
                replacement: replacement,
                all: arguments["all"]?.boolValue ?? false
            )
        } else {
            throw ServiceAPIError(code: .invalidRequest, message: "apply_edits requires one edit mode")
        }
        try FileManager.default.createDirectory(
            at: path.physicalPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(updated.utf8).write(to: path.physicalPath, options: .atomic)
        return .object([
            "path": .string(path.logicalPath),
            "changed": .bool(existing != updated),
            "bytes": .int(updated.utf8.count)
        ])
    }

    private func oracleUtilities(_ arguments: [String: Value]) async throws -> Value {
        let providers = await authority.providerCapabilities(preflight: true)
        let discovery = try await authority.modelDiscovery(sessionID: binding.sessionID)
        return try value(ProviderCatalogResult(
            operation: arguments["op"]?.stringValue ?? "models",
            providers: providers,
            rawModels: discovery.providers,
            presets: discovery.presets,
            roleModelRestrictionApplied: discovery.roleModelRestrictionApplied,
            settingsRevision: discovery.settingsRevision
        ))
    }

    private func askOracle(_ arguments: [String: Value], continuing: Bool) async throws -> Value {
        guard let message = arguments["message"]?.stringValue, !message.isEmpty else {
            throw ServiceAPIError(code: .invalidRequest, message: "Oracle requires message")
        }
        let chatID = arguments["chat_id"]?.stringValue.flatMap(UUID.init(uuidString:))
        if continuing, chatID == nil {
            throw ServiceAPIError(code: .invalidRequest, message: "oracle_send requires chat_id")
        }
        return try await value(authority.askOracle(
            sessionID: binding.sessionID,
            input: OracleInput(
                chatID: chatID,
                prompt: message,
                contextMode: arguments["mode"]?.stringValue ?? "chat",
                modelPresetID: arguments["model_preset_id"]?.stringValue.flatMap(UUID.init(uuidString:))
            ),
            actor: binding.actor
        ))
    }

    private func oracleChatLog(_ arguments: [String: Value]) async throws -> Value {
        guard let chatID = arguments["chat_id"]?.stringValue.flatMap(UUID.init(uuidString:)) else {
            throw ServiceAPIError(code: .invalidRequest, message: "oracle_chat_log requires chat_id")
        }
        let state = try await authority.oracleChatState(sessionID: binding.sessionID, chatID: chatID)
        let limit = min(max(arguments["limit"]?.intValue ?? 8, 1), 50)
        return try value(OracleLogResult(
            chatID: state.chatID,
            providerSessionID: state.providerSessionID,
            turns: Array(state.turns.suffix(limit)),
            revision: state.revision
        ))
    }

    private func contextBuilder(_ arguments: [String: Value]) async throws -> Value {
        guard let instructions = arguments["instructions"]?.stringValue, !instructions.isEmpty else {
            throw ServiceAPIError(code: .invalidRequest, message: "context_builder requires instructions")
        }
        let selection = try await authority.selectionSnapshot(sessionID: binding.sessionID)
        return try await value(authority.runContextBuilder(
            sessionID: binding.sessionID,
            input: ContextBuilderInput(
                expectedSelectionRevision: selection.revision,
                instructions: instructions,
                budget: arguments["budget"]?.intValue,
                responseType: arguments["response_type"]?.stringValue,
                allowClarifyingQuestions: arguments["allow_clarifying_questions"]?.boolValue,
                enhancementMode: arguments["enhancement_mode"]?.stringValue.flatMap(ContextBuilderEnhancementMode.init(rawValue:)),
                questionTimeoutSeconds: arguments["question_timeout_seconds"]?.intValue,
                followUpAnalysis: arguments["follow_up_analysis"]?.stringValue.flatMap(ContextBuilderFollowUpAnalysis.init(rawValue:)),
                followUpBudget: arguments["follow_up_budget"]?.intValue
            ),
            actor: binding.actor,
            origin: .mcp
        ))
    }

    private func askUser(_ arguments: [String: Value]) async throws -> Value {
        let payload = try JSONEncoder().encode(arguments)
        let timeout = arguments["timeout_seconds"]?.intValue ?? arguments["timeout"]?.intValue
        let answer = try await authority.askUserAndWait(
            sessionID: binding.sessionID,
            arguments: payload,
            timeoutSeconds: timeout
        )
        return try JSONDecoder().decode(Value.self, from: answer)
    }

    private func git(_ arguments: [String: Value]) async throws -> Value {
        let operation = arguments["op"]?.stringValue ?? "status"
        let root = try await root(arguments["root_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
        let command: [String]
        switch operation {
        case "status": command = ["status", "--short", "--branch"]
        case "log": command = ["log", "--oneline", "-n", String(min(max(arguments["count"]?.intValue ?? 20, 1), 200))]
        case "show": command = ["show", "--stat", arguments["ref"]?.stringValue ?? "HEAD"]
        case "diff":
            let diff = try await authority.sessionProjectDiff(
                sessionID: binding.sessionID,
                request: ProjectDiffRequest(
                    rootID: root.rootID,
                    comparison: arguments["compare"]?.stringValue ?? "HEAD",
                    logicalPaths: arguments["paths"]?.arrayValue?.compactMap(\.stringValue) ?? []
                )
            )
            return try value(diff)
        default:
            throw ServiceAPIError(code: .invalidRequest, message: "Unsupported Git operation")
        }
        return try await .object([
            "op": .string(operation),
            "output": .string(authority.sessionProjectGit(
                sessionID: binding.sessionID,
                rootID: root.rootID,
                arguments: command
            ))
        ])
    }

    private func manageWorktree(_ arguments: [String: Value]) async throws -> Value {
        let operation = arguments["op"]?.stringValue ?? "list"
        let session = try await session()
        switch operation {
        case "list", "status":
            return try await value(authority.worktreeSnapshots(projectID: session.projectID))
        case "create":
            let root = try await root(arguments["root_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
            return try await value(authority.createWorktree(
                sessionID: binding.sessionID,
                rootID: root.rootID,
                baseRef: arguments["base_ref"]?.stringValue ?? "HEAD",
                branch: arguments["branch"]?.stringValue ?? "repoprompt/session-\(binding.sessionID.uuidString.lowercased().prefix(12))",
                actor: binding.actor
            ))
        case "bind":
            guard let bindingID = arguments["binding_id"]?.stringValue.flatMap(UUID.init(uuidString:)) else {
                throw ServiceAPIError(code: .invalidRequest, message: "bind requires binding_id")
            }
            let worktree = try await authority.worktreeSnapshot(projectID: session.projectID, bindingID: bindingID)
            let selection = try await authority.selectionSnapshot(sessionID: binding.sessionID)
            return try await value(authority.bindWorktree(
                sessionID: binding.sessionID,
                bindingID: bindingID,
                expectedRevision: arguments["expected_revision"]?.intValue.map(Int64.init) ?? worktree.revision,
                expectedSelectionBindingRevision: selection.bindingRevision,
                actor: binding.actor
            ))
        case "merge":
            guard let bindingID = arguments["binding_id"]?.stringValue.flatMap(UUID.init(uuidString:)) else {
                throw ServiceAPIError(code: .invalidRequest, message: "merge requires binding_id")
            }
            let worktree = try await authority.worktreeSnapshot(projectID: session.projectID, bindingID: bindingID)
            return try await value(authority.mergeWorktree(
                sessionID: binding.sessionID,
                bindingID: bindingID,
                strategy: arguments["strategy"]?.stringValue ?? "merge",
                expectedRevision: arguments["expected_revision"]?.intValue.map(Int64.init) ?? worktree.revision,
                actor: binding.actor
            ))
        case "abort":
            guard let bindingID = arguments["binding_id"]?.stringValue.flatMap(UUID.init(uuidString:)),
                  let leaseID = arguments["lease_id"]?.stringValue.flatMap(UUID.init(uuidString:))
            else {
                throw ServiceAPIError(code: .invalidRequest, message: "abort requires binding_id and lease_id")
            }
            let worktree = try await authority.worktreeSnapshot(projectID: session.projectID, bindingID: bindingID)
            return try await value(authority.abortConflictedMerge(
                sessionID: binding.sessionID,
                bindingID: bindingID,
                leaseID: leaseID,
                expectedRevision: arguments["expected_revision"]?.intValue.map(Int64.init) ?? worktree.revision,
                actor: binding.actor
            ))
        default:
            throw ServiceAPIError(code: .invalidRequest, message: "Unsupported worktree operation")
        }
    }

    private func agentLifecycle(_ arguments: [String: Value], defaultRole: String) async throws -> Value {
        let operation = arguments["op"]?.stringValue ?? "start"
        switch operation {
        case "start":
            guard let message = arguments["message"]?.stringValue, !message.isEmpty else {
                throw ServiceAPIError(code: .invalidRequest, message: "Agent start requires message")
            }
            let start = try MCPAgentStartTarget.resolve(
                modelID: arguments["model_id"]?.stringValue,
                defaultRole: defaultRole,
                provider: arguments["provider"]?.stringValue.flatMap(ProviderKind.init(rawValue:)),
                providerSettingsID: arguments["provider_settings_id"]?.stringValue.flatMap(ProviderSettingsID.init(rawValue:)),
                model: arguments["model"]?.stringValue
            )
            let child = try await authority.spawnChildSession(
                parentSessionID: binding.sessionID,
                provider: start.provider,
                providerSettingsID: start.providerSettingsID,
                model: start.model,
                initialPrompt: message,
                role: start.role,
                label: arguments["session_name"]?.stringValue
            )
            // Desktop copies the parent's worktree bindings onto the child
            // session before provider start. Linux keeps a single root-owned
            // binding and exposes it through `effectiveWorktreeBindings` /
            // `authoritySessionSnapshot.worktrees`, so MCP path resolution and
            // session-scoped file tools inherit the same workspace.
            _ = try await authority.startChildAgentRun(sessionID: child.sessionID)
            return try await value(authority.sessionSnapshot(sessionID: child.sessionID))
        case "poll":
            return try await agentSnapshotOrExpired(sessionID: agentSessionID(arguments))
        case "wait":
            let sessionID = try agentSessionID(arguments)
            do {
                return try await value(waitForTerminal(
                    sessionID: sessionID,
                    timeout: arguments["timeout"]?.doubleValue ?? 120
                ))
            } catch let error as ServiceAPIError where error.code == .notFound {
                return DomainAgentRunSnapshot.expired(sessionID: sessionID).toValue()
            }
        case "cancel":
            let sessionID = try agentSessionID(arguments)
            _ = try await authority.cancelChildAgentRun(sessionID: sessionID)
            return try await value(authority.sessionSnapshot(sessionID: sessionID))
        default:
            throw ServiceAPIError(code: .invalidRequest, message: "Unsupported agent operation")
        }
    }

    private func agentManage(_ arguments: [String: Value]) async throws -> Value {
        let operation = arguments["op"]?.stringValue ?? "list_agents"
        switch operation {
        case "list_agents":
            return try await value(authority.agentDiscovery(
                sessionID: binding.sessionID,
                rolesOnly: arguments["roles_only"]?.boolValue ?? false
            ))
        case "list", "list_sessions":
            let root = try await session().rootSessionID
            return try await value(authority.agentSnapshots(rootSessionID: root))
        case "list_workflows":
            let repository = try await authority.workflowRepositorySnapshot()
            return try value(MCPWorkflowListResult(
                workflows: try await authority.workflowSnapshots(),
                revision: repository.revision
            ))
        case "cancel":
            let sessionID = try agentSessionID(arguments)
            _ = try await authority.cancelChildAgentRun(sessionID: sessionID)
            return try await value(authority.sessionSnapshot(sessionID: sessionID))
        default:
            throw ServiceAPIError(code: .invalidRequest, message: "Unsupported agent_manage operation")
        }
    }

    private func history(_ arguments: [String: Value]) async throws -> Value {
        let operation = arguments["op"]?.stringValue ?? "list_sessions"
        let all = try await authority.sessionSnapshots()
        let limit = min(max(arguments["limit"]?.intValue ?? 30, 1), 100)
        switch operation {
        case "list_sessions":
            let threshold = try await historyIdleThresholdMinutes(from: arguments)
            return try value(Array(all.suffix(limit)).map { session in
                HistoryListedSession(
                    snapshot: session,
                    activeDurationSeconds: AdvancedServerSettings.HistoryIdleThreshold.activeDurationSeconds(
                        timestamps: session.transcript.map(\.timestamp),
                        thresholdMinutes: threshold
                    )
                )
            })
        case "get_session": return try await value(authority.sessionSnapshot(sessionID: agentSessionID(arguments)))
        case "search":
            let query = arguments["query"]?.stringValue?.lowercased() ?? ""
            return try value(Array(all.filter {
                $0.sessionID.uuidString.lowercased().contains(query)
                    || $0.transcript.contains { $0.content.lowercased().contains(query) }
            }.prefix(limit)))
        case "time":
            let threshold = try await historyIdleThresholdMinutes(from: arguments)
            let activeSeconds = all.reduce(0) { total, session in
                total + AdvancedServerSettings.HistoryIdleThreshold.activeDurationSeconds(
                    timestamps: session.transcript.map(\.timestamp),
                    thresholdMinutes: threshold
                )
            }
            return .object([
                "session_count": .int(all.count),
                "group_by": arguments["group_by"] ?? .string("session"),
                "idle_threshold_minutes": .int(threshold),
                "active_seconds": .int(activeSeconds)
            ])
        default:
            throw ServiceAPIError(code: .invalidRequest, message: "Unsupported history operation")
        }
    }

    private func shareThoughts(_ arguments: [String: Value]) async throws -> Value {
        guard let text = arguments["text"]?.stringValue ?? arguments["thoughts"]?.stringValue else {
            throw ServiceAPIError(code: .invalidRequest, message: "share_thoughts requires text")
        }
        let target = arguments["session_id"]?.stringValue.flatMap(UUID.init(uuidString:)) ?? binding.sessionID
        let current = try await authority.sessionSnapshot(sessionID: target)
        let snapshot = try await authority.publishProgress(sessionID: target, text: text, actor: binding.actor, expectedRevision: current.revision)
        return .object([
            "session_id": .string(snapshot.sessionID.uuidString),
            "accepted": .bool(true),
            "content_digest": .string(CanonicalSigning.bodyDigest(Data(text.utf8)))
        ])
    }

    private func setStatus(_ arguments: [String: Value]) async throws -> Value {
        let snapshot = try await authority.sessionSnapshot(sessionID: binding.sessionID)
        guard let current = try await authority.agentSnapshots(rootSessionID: snapshot.rootSessionID).first(where: { $0.sessionID == binding.sessionID }) else {
            throw ServiceAPIError(code: .notFound, message: "Agent not found")
        }
        let updated = try await authority.updateAgentLabel(sessionID: binding.sessionID, label: arguments["session_name"]?.stringValue, actor: binding.actor, expectedRevision: current.revision)
        return .object([
            "session_id": .string(snapshot.sessionID.uuidString),
            "session_name": updated.label.map(Value.string) ?? .null,
            "state": .string(snapshot.state.rawValue)
        ])
    }

    private func waitForInstruction(_ arguments: [String: Value]) async throws -> Value {
        let timeoutValue = arguments["timeout_seconds"] ?? arguments["timeout"]
        let timeout = min(max(timeoutValue?.doubleValue ?? timeoutValue?.intValue.map(Double.init) ?? 120, 0), 3600)
        let current = try await authority.sessionSnapshot(sessionID: binding.sessionID)
        let baseline = arguments["after_sequence"]?.intValue.map(Int64.init) ?? current.transcript.last?.sessionSequence ?? 0
        let deadline = ContinuousClock().now.advanced(by: .seconds(timeout))
        while ContinuousClock().now < deadline {
            let snapshot = try await authority.sessionSnapshot(sessionID: binding.sessionID)
            if let instruction = snapshot.transcript.first(where: { $0.kind == .human && $0.sessionSequence > baseline }) {
                return try value(instruction)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        return .object(["timed_out": .bool(true)])
    }

    private func session() async throws -> SessionSnapshot {
        try await authority.sessionSnapshot(sessionID: binding.sessionID)
    }

    private func project() async throws -> ProjectSnapshot {
        let session = try await session()
        return try await authority.projectSnapshot(projectID: session.projectID)
    }

    private func root(_ requested: UUID?) async throws -> ProjectRootSnapshot {
        let project = try await project()
        if let requested, let root = project.roots.first(where: { $0.rootID == requested }) { return root }
        guard project.roots.count == 1, let root = project.roots.first else {
            throw ServiceAPIError(code: .invalidRequest, message: "root_id is required for a multi-root project")
        }
        return root
    }

    private func resolve(_ rawPath: String, allowMissingLeaf: Bool) async throws -> BoundPath {
        let project = try await project()
        // Desktop copies parent worktree bindings onto the child session.
        // Linux stores one active binding on the root and exposes it to
        // children through `authoritySessionSnapshot.worktrees`.
        let worktrees = try await authority.authoritySessionSnapshot(sessionID: binding.sessionID).worktrees
        let bindings = Dictionary(uniqueKeysWithValues: worktrees.map {
            ($0.rootID, URL(fileURLWithPath: $0.physicalPath).standardizedFileURL.resolvingSymlinksInPath())
        })
        var candidates: [BoundPath] = []
        for root in project.roots {
            let logicalRoot = URL(fileURLWithPath: root.canonicalPath)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            let physicalRoot = bindings[root.rootID] ?? logicalRoot
            let candidate: URL
            let logicalPath: String
            if rawPath.hasPrefix("/") {
                let absolute = URL(fileURLWithPath: rawPath).standardizedFileURL
                let checkedAbsolute = allowMissingLeaf
                    ? absolute.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(absolute.lastPathComponent)
                    : absolute.resolvingSymlinksInPath()
                if checkedAbsolute.path == logicalRoot.path || checkedAbsolute.path.hasPrefix(logicalRoot.path + "/") {
                    logicalPath = String(checkedAbsolute.path.dropFirst(logicalRoot.path.count))
                        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    candidate = physicalRoot.appendingPathComponent(logicalPath).standardizedFileURL
                } else if checkedAbsolute.path == physicalRoot.path || checkedAbsolute.path.hasPrefix(physicalRoot.path + "/") {
                    logicalPath = String(checkedAbsolute.path.dropFirst(physicalRoot.path.count))
                        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    candidate = checkedAbsolute
                } else {
                    continue
                }
            } else {
                logicalPath = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                candidate = physicalRoot.appendingPathComponent(logicalPath).standardizedFileURL
            }
            let checked = allowMissingLeaf
                ? candidate.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(candidate.lastPathComponent)
                : candidate.resolvingSymlinksInPath()
            guard checked.path == physicalRoot.path || checked.path.hasPrefix(physicalRoot.path + "/") else { continue }
            if rawPath.hasPrefix("/") || FileManager.default.fileExists(atPath: checked.path) || allowMissingLeaf {
                candidates.append(BoundPath(root: root, physicalRoot: physicalRoot, logicalPath: logicalPath, physicalPath: checked))
            }
        }
        guard candidates.count == 1, let result = candidates.first else {
            throw ServiceAPIError(code: .rootUnauthorized, message: "Path is missing, ambiguous, or outside the bound roots")
        }
        return result
    }

    private func selectionEntries(paths: [String], mode: LogicalSelectionEntry.Mode) async throws -> [LogicalSelectionEntry] {
        var entries: [LogicalSelectionEntry] = []
        for rawPath in paths {
            let path = try await resolve(rawPath, allowMissingLeaf: false)
            entries.append(LogicalSelectionEntry(
                rootID: path.root.rootID,
                logicalPath: path.logicalPath,
                mode: mode
            ))
        }
        return entries
    }

    private func physicalPath(for entry: LogicalSelectionEntry) async throws -> String {
        let project = try await project()
        guard let root = project.roots.first(where: { $0.rootID == entry.rootID }) else {
            throw ServiceAPIError(code: .rootUnauthorized, message: "Selected root is unavailable")
        }
        let worktrees = try await authority.authoritySessionSnapshot(sessionID: binding.sessionID).worktrees
        let base = worktrees.first(where: { $0.rootID == entry.rootID })?.physicalPath ?? root.canonicalPath
        return URL(fileURLWithPath: base).appendingPathComponent(entry.logicalPath).path
    }

    private func agentSessionID(_ arguments: [String: Value]) throws -> UUID {
        guard let raw = arguments["session_id"]?.stringValue,
              let sessionID = UUID(uuidString: raw)
        else { throw ServiceAPIError(code: .invalidRequest, message: "session_id must be a UUID") }
        return sessionID
    }

    private func agentSnapshotOrExpired(sessionID: UUID) async throws -> Value {
        do {
            return try await value(authority.sessionSnapshot(sessionID: sessionID))
        } catch let error as ServiceAPIError where error.code == .notFound {
            return DomainAgentRunSnapshot.expired(sessionID: sessionID).toValue()
        }
    }

    private func waitForTerminal(sessionID: UUID, timeout: Double) async throws -> SessionSnapshot {
        let deadline = ContinuousClock().now.advanced(by: .seconds(min(max(timeout, 0), 3600)))
        while true {
            let snapshot = try await authority.sessionSnapshot(sessionID: sessionID)
            if [.completed, .failed, .canceled, .interrupted, .archived].contains(snapshot.state) { return snapshot }
            if ContinuousClock().now >= deadline { return snapshot }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func replace(in text: String, search: String, replacement: String, all: Bool) throws -> String {
        guard !search.isEmpty else { throw ServiceAPIError(code: .invalidRequest, message: "Edit search must not be empty") }
        guard let range = text.range(of: search) else {
            throw ServiceAPIError(code: .staleRevision, message: "Edit search text was not found")
        }
        if all { return text.replacingOccurrences(of: search, with: replacement) }
        return text.replacingCharacters(in: range, with: replacement)
    }

    private func historyIdleThresholdMinutes(from arguments: [String: Value]) async throws -> Int {
        guard let raw = arguments["idle_threshold_minutes"] else {
            return try await authority.historyIdleThresholdMinutes(explicit: nil)
        }
        if case .null = raw {
            return try await authority.historyIdleThresholdMinutes(explicit: nil)
        }
        guard let minutes = raw.intValue else {
            throw ServiceAPIError(
                code: .invalidRequest,
                message: AdvancedServerSettings.HistoryIdleThreshold.integerRequiredMessage
            )
        }
        return try await authority.historyIdleThresholdMinutes(explicit: minutes)
    }

    private func value(_ encodable: some Encodable) throws -> Value {
        let data = try JSONEncoder.serviceEncoder.encode(encodable)
        return try JSONDecoder().decode(Value.self, from: data)
    }
}

private struct MCPWorkflowListResult: Encodable, Sendable {
    let workflows: [WorkflowSnapshot]
    let revision: Int64
}

private struct HistoryListedSession: Encodable {
    let snapshot: SessionSnapshot
    let activeDurationSeconds: Int

    func encode(to encoder: Encoder) throws {
        try snapshot.encode(to: encoder)
        var container = encoder.container(keyedBy: ExtraKeys.self)
        try container.encode(activeDurationSeconds, forKey: .activeDurationSeconds)
    }

    private enum ExtraKeys: String, CodingKey {
        case activeDurationSeconds = "active_duration_seconds"
    }
}

public struct MCPAgentStartTarget: Sendable {
    public let role: String
    public let provider: ProviderKind?
    public let providerSettingsID: ProviderSettingsID?
    public let model: String?

    public static func resolve(
        modelID: String?,
        defaultRole: String,
        provider: ProviderKind? = nil,
        providerSettingsID: ProviderSettingsID? = nil,
        model: String? = nil
    ) throws -> MCPAgentStartTarget {
        let trimmed = modelID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            return .init(role: defaultRole, provider: provider, providerSettingsID: providerSettingsID, model: model)
        }
        if let role = AgentRoutingTarget(rawValue: trimmed.lowercased()), role.isSubagentRole {
            return .init(role: role.rawValue, provider: provider, providerSettingsID: providerSettingsID, model: model)
        }
        if trimmed.contains(":") {
            let parts = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let agentRaw = String(parts[0])
            let modelRaw = parts.count == 2 ? String(parts[1]) : ""
            guard !modelRaw.isEmpty else {
                throw ServiceAPIError(code: .invalidRequest, message: "Invalid model_id '\(trimmed)'. Use a task label (explore, engineer, pair, design) or a compound ID from agent_manage op=list_agents.")
            }
            let mappedID = ProviderSettingsID(rawValue: agentRaw) ?? desktopProviderSettingsID(agentRaw)
            guard let mappedID else {
                throw ServiceAPIError(code: .invalidRequest, message: "Unknown model_id '\(trimmed)'. Use a task label (explore, engineer, pair, design) or a compound ID from agent_manage op=list_agents.")
            }
            return .init(
                role: "child",
                provider: provider,
                providerSettingsID: providerSettingsID ?? mappedID,
                model: model ?? modelRaw
            )
        }
        throw ServiceAPIError(
            code: .invalidRequest,
            message: "Unknown model_id '\(trimmed)'. Use a task label (explore, engineer, pair, design) or a compound ID from agent_manage op=list_agents."
        )
    }

    private static func desktopProviderSettingsID(_ raw: String) -> ProviderSettingsID? {
        switch raw {
        case "codexExec": .codex
        case "claudeCode": .claudeCompatible
        case "openCode": .openCodeACP
        case "cursor": .cursorACP
        case "grokBuild": .grokBuildACP
        default: nil
        }
    }
}

private struct SettingsResult: Encodable {
    let operation: String
    let capabilities: ServiceCapabilities
    let providers: [ProviderCapability]
}

private struct WorkspaceResult: Encodable {
    let operation: String
    let projects: [ProjectSnapshot]
    let sessions: [SessionSnapshot]
}

private struct CodeStructureResult: Encodable {
    struct Issue: Encodable {
        let code: String
        let message: String
    }

    let files: [ProjectCodeMapSnapshot]
    let updatesPending: Bool
    let issues: [Issue]?

    enum CodingKeys: String, CodingKey {
        case files
        case updatesPending = "updates_pending"
        case issues
    }
}

private struct ProviderCatalogResult: Encodable {
    let operation: String
    let providers: [ProviderCapability]
    let rawModels: [ProviderSettingsSnapshot]
    let presets: [MCPModelPreset]
    let roleModelRestrictionApplied: Bool
    let settingsRevision: Int64

    enum CodingKeys: String, CodingKey {
        case operation, providers, presets
        case rawModels = "raw_models"
        case roleModelRestrictionApplied = "role_model_restriction_applied"
        case settingsRevision = "settings_revision"
    }
}

private struct OracleLogResult: Encodable {
    let chatID: UUID
    let providerSessionID: String?
    let turns: [OracleChatTurn]
    let revision: Int64
}

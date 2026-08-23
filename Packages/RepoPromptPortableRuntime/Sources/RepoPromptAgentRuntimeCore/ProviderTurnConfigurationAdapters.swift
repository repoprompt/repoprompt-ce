import Foundation
import RepoPromptRuntimeModel

public struct ProviderTurnConfigurationInput: Sendable {
    public let providerID: ProviderSettingsID
    public let model: ProviderModelDescriptor
    public let effortID: String?
    public let permissionID: String?
    public let settings: ProviderTurnSettings
    public let toolValues: [String: AgentControlValue]
    public let scopedResources: Set<OwnedResourceReference>
    public let workflowID: String?

    public init(
        providerID: ProviderSettingsID,
        model: ProviderModelDescriptor,
        effortID: String? = nil,
        permissionID: String? = nil,
        settings: ProviderTurnSettings,
        toolValues: [String: AgentControlValue] = [:],
        scopedResources: Set<OwnedResourceReference> = [],
        workflowID: String? = nil
    ) {
        self.providerID = providerID
        self.model = model
        self.effortID = effortID
        self.permissionID = permissionID
        self.settings = settings
        self.toolValues = toolValues
        self.scopedResources = scopedResources
        self.workflowID = workflowID
    }
}

public struct CompiledProviderTurnConfiguration: Sendable {
    public let runtimeKind: ProviderKind
    public let providerRawModelValue: String
    public let effortID: String?
    public let permissions: ResolvedProviderPermissions
    public let executionPolicy: ProviderExecutionPolicy
    public let supportsNativeImages: Bool
    public let normalizedToolValues: [String: AgentControlValue]

    public var providerSettings: [String: String] {
        executionPolicy.providerSettings
    }

    public init(
        runtimeKind: ProviderKind,
        providerRawModelValue: String,
        effortID: String?,
        permissions: ResolvedProviderPermissions,
        executionPolicy: ProviderExecutionPolicy,
        supportsNativeImages: Bool,
        normalizedToolValues: [String: AgentControlValue]
    ) {
        self.runtimeKind = runtimeKind
        self.providerRawModelValue = providerRawModelValue
        self.effortID = effortID
        self.permissions = permissions
        self.executionPolicy = executionPolicy
        self.supportsNativeImages = supportsNativeImages
        self.normalizedToolValues = normalizedToolValues
    }
}

public protocol ProviderTurnConfigurationAdapter: Sendable {
    var providerID: ProviderSettingsID { get }
    var supportedControlIDs: Set<String> { get }
    var supportedPermissionIDs: Set<String> { get }
    func compile(_ input: ProviderTurnConfigurationInput) throws -> CompiledProviderTurnConfiguration
}

public enum ProviderComposerStableControls {
    public static let codex: Set<String> = [
        "codex.bash", "codex.search", "codex.goals", "codex.reasoningSummaries", "codex.memories", "codex.mcpServers"
    ]
    public static let claude: Set<String> = [
        "claude.bash", "claude.mcpStrictMode", "claude.toolSearch", "claude.promptDelivery"
    ]

    public static func descriptors(providerID: ProviderSettingsID, values: [String: AgentControlValue], mutable: Bool, lockReasonCode: String?) -> [ProviderComposerControlDescriptor] {
        switch providerID {
        case .codex:
            [
                toggle("codex.bash", "Bash", defaultValue: true, values: values, mutable: mutable, lockReasonCode: lockReasonCode),
                toggle("codex.search", "Search", defaultValue: true, values: values, mutable: mutable, lockReasonCode: lockReasonCode),
                toggle("codex.goals", "Goals", defaultValue: true, values: values, mutable: mutable, lockReasonCode: lockReasonCode),
                toggle("codex.reasoningSummaries", "Reasoning summaries", defaultValue: false, values: values, mutable: mutable, lockReasonCode: lockReasonCode),
                toggle("codex.memories", "Memories", defaultValue: false, values: values, mutable: mutable, lockReasonCode: lockReasonCode),
                .multiChoice(
                    id: "codex.mcpServers",
                    displayName: "MCP servers",
                    detailText: "RepoPrompt MCP remains required.",
                    selectedIDs: stringArray(values["codex.mcpServers"], fallback: ["repoprompt"]),
                    choices: [.init(id: "repoprompt", displayName: "RepoPrompt", detailText: "Required", enabled: false)],
                    required: true,
                    mutable: mutable,
                    warning: false,
                    lockReasonCode: lockReasonCode
                )
            ]
        case .claudeCompatible, .claudeGLM, .claudeKimi, .claudeCustom:
            [
                toggle("claude.bash", "Bash", defaultValue: true, values: values, mutable: mutable, lockReasonCode: lockReasonCode),
                toggle("claude.mcpStrictMode", "RepoPrompt-only MCP", defaultValue: true, values: values, mutable: mutable, lockReasonCode: lockReasonCode),
                toggle("claude.toolSearch", "Tool search", defaultValue: false, values: values, mutable: mutable, lockReasonCode: lockReasonCode),
                .singleChoice(
                    id: "claude.promptDelivery",
                    displayName: "Prompt delivery",
                    detailText: nil,
                    selectedID: string(values["claude.promptDelivery"], fallback: "nativeSystemPrompt"),
                    choices: [
                        .init(id: "nativeSystemPrompt", displayName: "Replace System Prompt", detailText: "RepoPrompt instructions replace Claude Code's native system prompt."),
                        .init(id: "userMessageXMLWithEmptySystemPrompt", displayName: "User Message (No Native)", detailText: "RepoPrompt instructions are added to the user message, and Claude Code's native system prompt is removed."),
                        .init(id: "userMessageXML", displayName: "User Message (Keep Native)", detailText: "RepoPrompt instructions are added to the user message, and Claude Code keeps its native prompt.")
                    ],
                    required: true,
                    mutable: mutable,
                    warning: false,
                    lockReasonCode: lockReasonCode
                )
            ]
        case .openCodeACP, .cursorACP, .grokBuildACP,
             .openAIAPI, .anthropicAPI, .openRouter, .customOpenAICompatible,
             .gemini, .azure, .deepseek, .fireworks, .xAI, .groq, .zAI, .ollama:
            []
        }
    }

    public static func permissionDescriptor(providerID: ProviderSettingsID, selectedID: String?, mutable: Bool, lockReasonCode: String?) -> ProviderPermissionDescriptor? {
        switch providerID {
        case .codex:
            let choices = [
                ProviderComposerChoiceDescriptor(id: "codex.readOnly", displayName: "Read Only"),
                .init(id: "codex.defaultPermission", displayName: "Require Approval"),
                .init(id: "codex.autoReview", displayName: "Auto Review"),
                .init(id: "codex.fullAccess", displayName: "Full Access", warning: true)
            ]
            return .init(id: "codex.permission", selectedID: selectedID ?? "codex.defaultPermission", choices: choices, mutable: mutable, lockReasonCode: lockReasonCode)
        case .claudeCompatible, .claudeGLM, .claudeKimi, .claudeCustom:
            let choices = [
                ProviderComposerChoiceDescriptor(id: "claude.requireApproval", displayName: "Require Approval"),
                .init(id: "claude.autoApproveEdits", displayName: "Auto-approve Edits"),
                .init(id: "claude.auto", displayName: "Auto (Preview)"),
                .init(id: "claude.fullAccess", displayName: "Full Access", warning: true)
            ]
            return .init(id: "claude.permission", selectedID: selectedID ?? "claude.requireApproval", choices: choices, mutable: mutable, lockReasonCode: lockReasonCode)
        case .openCodeACP:
            return .init(id: "opencode.permission", selectedID: selectedID ?? "opencode.managedDefault", choices: [
                .init(id: "opencode.managedDefault", displayName: "Require Approval", detailText: "OpenCode asks before running tools that need approval."),
                .init(id: "opencode.fullAccess", displayName: "Full Access", warning: true)
            ], mutable: mutable, lockReasonCode: lockReasonCode)
        case .cursorACP:
            return .init(id: "cursor.permission", selectedID: selectedID ?? "cursor.managedDefault", choices: [
                .init(id: "cursor.managedDefault", displayName: "Require Approval", detailText: "Cursor asks before running tools that need approval. RepoPrompt MCP is injected through the ACP session."),
                .init(id: "cursor.fullAccess", displayName: "Full Access", warning: true)
            ], mutable: mutable, lockReasonCode: lockReasonCode)
        case .grokBuildACP:
            return .init(id: "grok.permission", selectedID: selectedID ?? "grok.managedDefault", choices: [
                .init(id: "grok.managedDefault", displayName: "Require Approval", detailText: "Grok Build asks before running tools that need approval."),
                .init(id: "grok.fullAccess", displayName: "Full Access", warning: true)
            ], mutable: mutable, lockReasonCode: lockReasonCode)
        case .openAIAPI, .anthropicAPI, .openRouter, .customOpenAICompatible,
             .gemini, .azure, .deepseek, .fireworks, .xAI, .groq, .zAI, .ollama:
            return nil
        }
    }

    private static func toggle(_ id: String, _ name: String, defaultValue: Bool, values: [String: AgentControlValue], mutable: Bool, lockReasonCode: String?, required: Bool = false) -> ProviderComposerControlDescriptor {
        .toggle(id: id, displayName: name, detailText: nil, value: boolean(values[id], fallback: defaultValue), required: required, mutable: mutable, warning: false, lockReasonCode: lockReasonCode)
    }

    static func boolean(_ value: AgentControlValue?, fallback: Bool) -> Bool {
        if case let .boolean(result) = value { return result }
        return fallback
    }

    static func string(_ value: AgentControlValue?, fallback: String) -> String {
        if case let .choice(result) = value { return result }
        return fallback
    }

    static func stringArray(_ value: AgentControlValue?, fallback: [String]) -> [String] {
        if case let .choices(result) = value { return result }
        return fallback
    }
}

public struct CodexTurnConfigurationAdapter: ProviderTurnConfigurationAdapter {
    public let providerID = ProviderSettingsID.codex
    public let supportedControlIDs = ProviderComposerStableControls.codex
    public let supportedPermissionIDs: Set<String> = ["codex.readOnly", "codex.defaultPermission", "codex.autoReview", "codex.fullAccess"]

    public init() {}

    public func compile(_ input: ProviderTurnConfigurationInput) throws -> CompiledProviderTurnConfiguration {
        try validate(input)
        guard case .codex = input.settings else {
            throw ServiceAPIError(code: .invalidRequest, message: "Codex settings are invalid")
        }
        let effort = input.effortID ?? input.model.defaultEffortID
        if let effort, !input.model.supportedEffortIDs.contains(effort) {
            throw ServiceAPIError(code: .invalidRequest, message: "Codex effort is not supported by the selected model")
        }
        let permission = input.permissionID ?? "codex.defaultPermission"
        let permissions = try ProviderTurnConfigurationAdapters.permissions(
            permission,
            readOnly: ["codex.readOnly"],
            workspaceWrite: ["codex.defaultPermission", "codex.autoReview"],
            fullAccess: ["codex.fullAccess"],
            scopedResources: input.scopedResources
        )
        var settings = try normalizedValues(input.toolValues)
        settings["codex.mcpServers"] = .choices(requiredRepoPromptMCP(from: settings["codex.mcpServers"]))
        var native: [String: String] = [
            "codex.bashEnabled": String(ProviderComposerStableControls.boolean(settings["codex.bash"], fallback: true)),
            "codex.searchEnabled": String(ProviderComposerStableControls.boolean(settings["codex.search"], fallback: true)),
            "codex.goalsEnabled": String(ProviderComposerStableControls.boolean(settings["codex.goals"], fallback: true)),
            "codex.reasoningSummariesEnabled": String(ProviderComposerStableControls.boolean(settings["codex.reasoningSummaries"], fallback: false)),
            "codex.memoriesEnabled": String(ProviderComposerStableControls.boolean(settings["codex.memories"], fallback: false)),
            "codex.mcpServers": ProviderComposerStableControls.stringArray(settings["codex.mcpServers"], fallback: ["repoprompt"]).sorted().joined(separator: ","),
            "provider.permissionId": permission,
            "codex.approvalsReviewer": permission == "codex.autoReview" ? "auto_review" : "user"
        ]
        if let effort { native["provider.reasoningEffort"] = effort }
        if let serviceTier = input.model.serviceTier { native["provider.serviceTier"] = serviceTier }
        return .init(
            runtimeKind: .codex,
            providerRawModelValue: input.model.providerRawValue,
            effortID: effort,
            permissions: permissions,
            executionPolicy: .init(mode: permissions.executionMode, providerSettings: native),
            supportsNativeImages: input.model.capabilities.nativeImages,
            normalizedToolValues: settings
        )
    }

    private func validate(_ input: ProviderTurnConfigurationInput) throws {
        guard input.providerID == providerID, input.model.providerID == providerID else {
            throw ServiceAPIError(code: .invalidRequest, message: "Codex model/provider binding is invalid")
        }
        let unknown = Set(input.toolValues.keys).subtracting(supportedControlIDs)
        guard unknown.isEmpty else { throw ServiceAPIError(code: .invalidRequest, message: "Unknown Codex tool control") }
    }

    private func normalizedValues(_ values: [String: AgentControlValue]) throws -> [String: AgentControlValue] {
        for (key, value) in values {
            if key == "codex.mcpServers" {
                guard case let .choices(selected) = value, Set(selected).isSubset(of: ["repoprompt"]) else { throw ServiceAPIError(code: .invalidRequest, message: "Codex MCP control has an invalid value") }
            } else if case .boolean = value {
                continue
            } else {
                throw ServiceAPIError(code: .invalidRequest, message: "Codex tool control has the wrong value type")
            }
        }
        var normalized: [String: AgentControlValue] = ["codex.bash": .boolean(true), "codex.search": .boolean(true), "codex.goals": .boolean(true), "codex.reasoningSummaries": .boolean(false), "codex.memories": .boolean(false), "codex.mcpServers": .choices(["repoprompt"])]
        normalized.merge(values) { _, supplied in supplied }
        return normalized
    }

    private func requiredRepoPromptMCP(from value: AgentControlValue?) -> [String] {
        var selected = ProviderComposerStableControls.stringArray(value, fallback: ["repoprompt"])
        if !selected.contains("repoprompt") { selected.append("repoprompt") }
        return Array(Set(selected)).sorted()
    }
}

public struct ClaudeCompatibleTurnConfigurationAdapter: ProviderTurnConfigurationAdapter {
    public let providerID: ProviderSettingsID
    public let supportedControlIDs = ProviderComposerStableControls.claude
    public let supportedPermissionIDs: Set<String> = ["claude.requireApproval", "claude.autoApproveEdits", "claude.auto", "claude.fullAccess"]

    public init(providerID: ProviderSettingsID) {
        precondition([.claudeCompatible, .claudeGLM, .claudeKimi, .claudeCustom].contains(providerID))
        self.providerID = providerID
    }

    public func compile(_ input: ProviderTurnConfigurationInput) throws -> CompiledProviderTurnConfiguration {
        guard input.providerID == providerID, input.model.providerID == providerID else {
            throw ServiceAPIError(code: .invalidRequest, message: "Claude-compatible model/provider binding is invalid")
        }
        guard case .claudeCompatible = input.settings else {
            throw ServiceAPIError(code: .invalidRequest, message: "Claude-compatible settings are invalid")
        }
        let unknown = Set(input.toolValues.keys).subtracting(supportedControlIDs)
        guard unknown.isEmpty else { throw ServiceAPIError(code: .invalidRequest, message: "Unknown Claude-compatible tool control") }
        let effort = input.effortID ?? input.model.defaultEffortID
        if let effort, !input.model.supportedEffortIDs.contains(effort) {
            throw ServiceAPIError(code: .invalidRequest, message: "Claude-compatible effort is not supported by the selected model")
        }
        let permission = input.permissionID ?? "claude.requireApproval"
        let permissions = try ProviderTurnConfigurationAdapters.permissions(
            permission,
            readOnly: [],
            workspaceWrite: ["claude.requireApproval", "claude.autoApproveEdits", "claude.auto"],
            fullAccess: ["claude.fullAccess"],
            scopedResources: input.scopedResources
        )
        for (key, value) in input.toolValues {
            if key == "claude.promptDelivery" {
                guard case .choice = value else { throw ServiceAPIError(code: .invalidRequest, message: "Claude-compatible prompt delivery has the wrong value type") }
            } else if case .boolean = value {
                continue
            } else {
                throw ServiceAPIError(code: .invalidRequest, message: "Claude-compatible tool control has the wrong value type")
            }
        }
        var settings: [String: AgentControlValue] = ["claude.bash": .boolean(true), "claude.mcpStrictMode": .boolean(true), "claude.toolSearch": .boolean(false), "claude.promptDelivery": .choice("nativeSystemPrompt")]
        settings.merge(input.toolValues) { _, supplied in supplied }
        let strict = ProviderComposerStableControls.boolean(settings["claude.mcpStrictMode"], fallback: true)
        let delivery = ProviderComposerStableControls.string(settings["claude.promptDelivery"], fallback: "nativeSystemPrompt")
        guard ["nativeSystemPrompt", "userMessageXMLWithEmptySystemPrompt", "userMessageXML"].contains(delivery) else {
            throw ServiceAPIError(code: .invalidRequest, message: "Claude-compatible prompt delivery is invalid")
        }
        let permissionMode = switch permission {
        case "claude.requireApproval": "default"
        case "claude.autoApproveEdits": "acceptEdits"
        case "claude.auto": "auto"
        case "claude.fullAccess": "bypassPermissions"
        default: "default"
        }
        var native: [String: String] = [
            "claude.bashEnabled": String(ProviderComposerStableControls.boolean(settings["claude.bash"], fallback: true)),
            "claude.strictMCPEnabled": String(strict),
            "claude.toolSearchEnabled": String(ProviderComposerStableControls.boolean(settings["claude.toolSearch"], fallback: false)),
            "claude.promptDelivery": delivery,
            "claude.permissionMode": permissionMode,
            "provider.settingsId": providerID.rawValue,
            "provider.permissionId": permission
        ]
        if let effort { native["provider.reasoningEffort"] = effort }
        return .init(
            runtimeKind: .claudeCompatible,
            providerRawModelValue: input.model.providerRawValue,
            effortID: effort,
            permissions: permissions,
            executionPolicy: .init(mode: permissions.executionMode, providerSettings: native),
            supportsNativeImages: input.model.capabilities.nativeImages,
            normalizedToolValues: settings
        )
    }
}

public struct TextOnlyACPTurnConfigurationAdapter: ProviderTurnConfigurationAdapter {
    public let providerID: ProviderSettingsID
    public let supportedControlIDs: Set<String> = []
    public let supportedPermissionIDs: Set<String>

    public init(providerID: ProviderSettingsID) {
        precondition([.openCodeACP, .cursorACP, .grokBuildACP].contains(providerID))
        self.providerID = providerID
        supportedPermissionIDs = switch providerID {
        case .openCodeACP: ["opencode.managedDefault", "opencode.fullAccess"]
        case .cursorACP: ["cursor.managedDefault", "cursor.fullAccess"]
        case .grokBuildACP: ["grok.managedDefault", "grok.fullAccess"]
        default: []
        }
    }

    public func compile(_ input: ProviderTurnConfigurationInput) throws -> CompiledProviderTurnConfiguration {
        guard input.providerID == providerID, input.model.providerID == providerID,
              input.toolValues.isEmpty, case .acp = input.settings
        else {
            throw ServiceAPIError(code: .invalidRequest, message: "ACP turn configuration is invalid")
        }
        let defaultPermission = switch providerID {
        case .openCodeACP: "opencode.managedDefault"
        case .cursorACP: "cursor.managedDefault"
        case .grokBuildACP: "grok.managedDefault"
        default: ""
        }
        let permission = input.permissionID ?? defaultPermission
        let permissionPrefix = switch providerID {
        case .openCodeACP: "opencode"
        case .cursorACP: "cursor"
        case .grokBuildACP: "grok"
        default: ""
        }
        let permissions = try ProviderTurnConfigurationAdapters.permissions(
            permission,
            readOnly: [],
            workspaceWrite: ["\(permissionPrefix).managedDefault"],
            fullAccess: ["\(permissionPrefix).fullAccess"],
            scopedResources: input.scopedResources
        )
        guard let runtimeKind = providerID.runtimeKind else {
            throw ServiceAPIError(code: .invalidRequest, message: "ACP runtime kind is invalid")
        }
        let effort = input.effortID ?? input.model.defaultEffortID
        if let effort, !input.model.supportedEffortIDs.isEmpty,
           !input.model.supportedEffortIDs.contains(effort)
        {
            throw ServiceAPIError(code: .invalidRequest, message: "ACP effort is not supported by the selected model")
        }
        var settings = ["provider.permissionId": permission]
        if providerID == .grokBuildACP, let effort {
            settings["provider.reasoningEffort"] = effort
        }
        return .init(
            runtimeKind: runtimeKind,
            providerRawModelValue: input.model.providerRawValue,
            effortID: effort,
            permissions: permissions,
            executionPolicy: .init(
                mode: permissions.executionMode,
                providerSettings: settings
            ),
            supportsNativeImages: false,
            normalizedToolValues: [:]
        )
    }
}

public struct DirectAPITurnConfigurationAdapter: ProviderTurnConfigurationAdapter {
    public let providerID: ProviderSettingsID
    public let supportedControlIDs: Set<String> = []
    public let supportedPermissionIDs: Set<String> = []

    public init(providerID: ProviderSettingsID) {
        precondition(providerID.isDirectAPI)
        self.providerID = providerID
    }

    public func compile(_ input: ProviderTurnConfigurationInput) throws -> CompiledProviderTurnConfiguration {
        guard input.providerID == providerID, input.model.providerID == providerID else {
            throw ServiceAPIError(code: .invalidRequest, message: "Direct API model/provider binding is invalid")
        }
        guard input.toolValues.isEmpty, case .directAPI = input.settings else {
            throw ServiceAPIError(code: .invalidRequest, message: "Direct API providers do not expose composer tool controls")
        }
        guard input.permissionID == nil else {
            throw ServiceAPIError(code: .invalidRequest, message: "Direct API permissions are managed by the server")
        }
        let effort = input.effortID ?? input.model.defaultEffortID
        if let effort, !input.model.supportedEffortIDs.contains(effort) {
            throw ServiceAPIError(code: .invalidRequest, message: "Direct API effort is not supported by the selected model")
        }
        let permissions = ResolvedProviderPermissions.workspaceWrite(scopedResources: input.scopedResources)
        var settings = ["provider.settingsID": providerID.rawValue]
        if let effort { settings["provider.reasoningEffort"] = effort }
        return .init(
            runtimeKind: .headlessAdapter,
            providerRawModelValue: input.model.providerRawValue,
            effortID: effort,
            permissions: permissions,
            executionPolicy: .init(mode: .workspaceWrite, providerSettings: settings),
            supportsNativeImages: input.model.capabilities.nativeImages,
            normalizedToolValues: [:]
        )
    }
}

public enum ProviderTurnConfigurationAdapters {
    static func permissions(
        _ permissionID: String,
        readOnly: Set<String>,
        workspaceWrite: Set<String>,
        fullAccess: Set<String>,
        scopedResources: Set<OwnedResourceReference>
    ) throws -> ResolvedProviderPermissions {
        if readOnly.contains(permissionID) {
            return .readOnly(scopedResources: scopedResources)
        }
        if workspaceWrite.contains(permissionID) {
            return .workspaceWrite(scopedResources: scopedResources)
        }
        if fullAccess.contains(permissionID) {
            return .fullAccess(scopedResources: scopedResources)
        }
        throw ServiceAPIError(code: .invalidRequest, message: "Provider permission is invalid")
    }

    /// Bump whenever a stable control/permission mapping changes interpretation.
    public static let interpretationRevision = "provider-turn-configuration-v3-desktop-profile"

    public static func defaultSettings(for providerID: ProviderSettingsID) -> ProviderTurnSettings {
        switch providerID {
        case .codex: .codex(.init())
        case .claudeCompatible, .claudeGLM, .claudeKimi, .claudeCustom: .claudeCompatible(.init())
        case .openCodeACP, .cursorACP, .grokBuildACP: .acp
        case .openAIAPI, .anthropicAPI, .openRouter, .customOpenAICompatible,
             .gemini, .azure, .deepseek, .fireworks, .xAI, .groq, .zAI, .ollama: .directAPI
        }
    }

    public static func compile(
        _ input: ProviderTurnConfigurationInput
    ) throws -> CompiledProviderTurnConfiguration {
        guard let adapter = builtIn()[input.providerID] else {
            throw ServiceAPIError(code: .invalidRequest, message: "Provider turn configuration is unsupported")
        }
        return try adapter.compile(input)
    }

    public static func builtIn() -> [ProviderSettingsID: any ProviderTurnConfigurationAdapter] {
        [
            .codex: CodexTurnConfigurationAdapter(),
            .claudeCompatible: ClaudeCompatibleTurnConfigurationAdapter(providerID: .claudeCompatible),
            .claudeGLM: ClaudeCompatibleTurnConfigurationAdapter(providerID: .claudeGLM),
            .claudeKimi: ClaudeCompatibleTurnConfigurationAdapter(providerID: .claudeKimi),
            .claudeCustom: ClaudeCompatibleTurnConfigurationAdapter(providerID: .claudeCustom),
            .openCodeACP: TextOnlyACPTurnConfigurationAdapter(providerID: .openCodeACP),
            .cursorACP: TextOnlyACPTurnConfigurationAdapter(providerID: .cursorACP),
            .grokBuildACP: TextOnlyACPTurnConfigurationAdapter(providerID: .grokBuildACP),
            .openAIAPI: DirectAPITurnConfigurationAdapter(providerID: .openAIAPI),
            .anthropicAPI: DirectAPITurnConfigurationAdapter(providerID: .anthropicAPI),
            .openRouter: DirectAPITurnConfigurationAdapter(providerID: .openRouter),
            .customOpenAICompatible: DirectAPITurnConfigurationAdapter(providerID: .customOpenAICompatible),
            .gemini: DirectAPITurnConfigurationAdapter(providerID: .gemini),
            .azure: DirectAPITurnConfigurationAdapter(providerID: .azure),
            .deepseek: DirectAPITurnConfigurationAdapter(providerID: .deepseek),
            .fireworks: DirectAPITurnConfigurationAdapter(providerID: .fireworks),
            .xAI: DirectAPITurnConfigurationAdapter(providerID: .xAI),
            .groq: DirectAPITurnConfigurationAdapter(providerID: .groq),
            .zAI: DirectAPITurnConfigurationAdapter(providerID: .zAI),
            .ollama: DirectAPITurnConfigurationAdapter(providerID: .ollama)
        ]
    }
}

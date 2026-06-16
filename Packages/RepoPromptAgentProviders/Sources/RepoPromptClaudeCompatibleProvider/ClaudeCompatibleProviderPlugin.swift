import Foundation

/// Stable provider IDs owned by the Claude-compatible provider package.
/// RepoPrompt core maps its persisted `AgentProviderKind` values to these IDs in
/// the bridge layer so plugin-facing code does not depend on app enums.
public enum ClaudeCompatibleProviderPluginID: String, CaseIterable, Codable, Hashable, Sendable {
    case claudeCode = "claude-code"
    case zaiClaudeCode = "zai-claude-code"
    case kimiClaudeCode = "kimi-claude-code"
    case customClaudeCompatible = "custom-claude-compatible"
}

/// Provider package backend IDs. These intentionally mirror core persisted IDs
/// without owning their UserDefaults/keychain storage.
public enum ClaudeCompatibleBackendID: String, CaseIterable, Codable, Hashable, Sendable {
    case glmZAI
    case kimi
    case custom
}

public enum ClaudeCompatibleRuntimeMode: String, Codable, Hashable, Sendable {
    case agentMode
    case discovery
}

public enum ClaudeCompatibleToolContext: String, Codable, Hashable, Sendable {
    case agentRun
    case discoverRun
    case terminal
    case promptOnly
}

public enum ClaudeCompatibleBackendAuth: String, Codable, Hashable, Sendable {
    case anthropicAPIKey
    case anthropicAuthToken
}

public struct ClaudeCompatibleSlotMapping: Codable, Hashable, Sendable {
    public let haiku: String
    public let sonnet: String
    public let opus: String

    public init(haiku: String, sonnet: String, opus: String) {
        self.haiku = haiku
        self.sonnet = sonnet
        self.opus = opus
    }
}

public enum ClaudeCompatibleBackendModelBehavior: Codable, Hashable, Sendable {
    case noModel
    case claudeSlotMapping(ClaudeCompatibleSlotMapping)
}

/// Sanitized persisted backend configuration supplied by the host at launch/catalog time.
/// Secrets are deliberately absent; the host owns secure storage and may pass a
/// resolved launch environment separately after keychain access succeeds.
public struct ClaudeCompatibleBackendConfig: Codable, Hashable, Sendable {
    public let id: ClaudeCompatibleBackendID
    public let isEnabled: Bool
    public let displayName: String
    public let baseURL: String
    public let auth: ClaudeCompatibleBackendAuth
    public let modelBehavior: ClaudeCompatibleBackendModelBehavior

    public init(
        id: ClaudeCompatibleBackendID,
        isEnabled: Bool,
        displayName: String,
        baseURL: String,
        auth: ClaudeCompatibleBackendAuth,
        modelBehavior: ClaudeCompatibleBackendModelBehavior
    ) {
        self.id = id
        self.isEnabled = isEnabled
        self.displayName = displayName
        self.baseURL = baseURL
        self.auth = auth
        self.modelBehavior = modelBehavior
    }
}

/// Runtime launch environment resolved by the host from persisted backend config
/// and host-owned secrets. This mirrors the eventual plugin input without moving
/// keychain/settings ownership into the package.
public struct ClaudeCompatibleLaunchEnvironment: Codable, Hashable, Sendable {
    public let effectiveModel: String?
    public let environmentOverrides: [String: String]
    public let removedEnvironmentKeys: Set<String>
    public let backendID: ClaudeCompatibleBackendID?
    public let suppressesEffortSettings: Bool

    public init(
        effectiveModel: String?,
        environmentOverrides: [String: String],
        removedEnvironmentKeys: Set<String> = [],
        backendID: ClaudeCompatibleBackendID?,
        suppressesEffortSettings: Bool = false
    ) {
        self.effectiveModel = effectiveModel
        self.environmentOverrides = environmentOverrides
        self.removedEnvironmentKeys = removedEnvironmentKeys
        self.backendID = backendID
        self.suppressesEffortSettings = suppressesEffortSettings
    }
}

/// Host settings/runtime configuration normalized for the package. Core remains
/// responsible for reading UserDefaults, secure stores, and MCP policy; the
/// bridge translates those app types into this DTO.
public struct ClaudeCompatibleRuntimeConfig: Codable, Hashable, Sendable {
    public let pluginID: ClaudeCompatibleProviderPluginID
    public let mode: ClaudeCompatibleRuntimeMode
    public let commandName: String
    public let additionalPathHints: [String]
    public let modelString: String?
    public let enableDebugLogging: Bool
    public let sdkConnectTimeoutSeconds: Double
    public let sdkRelaunchMaxAttempts: Int
    public let permissionMode: String
    public let allowNativeBashTool: Bool
    public let toolContext: ClaudeCompatibleToolContext
    public let disallowedBuiltInTools: [String]
    public let mcpStrictMode: Bool
    public let toolSearchEnabled: Bool
    public let effortLevel: String?
    public let processEnvironmentOverrides: [String: String]
    public let effortEnvironmentOverrides: [String: String]
    public let backendConfig: ClaudeCompatibleBackendConfig?

    public init(
        pluginID: ClaudeCompatibleProviderPluginID,
        mode: ClaudeCompatibleRuntimeMode,
        commandName: String,
        additionalPathHints: [String],
        modelString: String?,
        enableDebugLogging: Bool,
        sdkConnectTimeoutSeconds: Double,
        sdkRelaunchMaxAttempts: Int,
        permissionMode: String,
        allowNativeBashTool: Bool,
        toolContext: ClaudeCompatibleToolContext,
        disallowedBuiltInTools: [String],
        mcpStrictMode: Bool,
        toolSearchEnabled: Bool,
        effortLevel: String?,
        processEnvironmentOverrides: [String: String],
        effortEnvironmentOverrides: [String: String],
        backendConfig: ClaudeCompatibleBackendConfig?
    ) {
        self.pluginID = pluginID
        self.mode = mode
        self.commandName = commandName
        self.additionalPathHints = additionalPathHints
        self.modelString = modelString
        self.enableDebugLogging = enableDebugLogging
        self.sdkConnectTimeoutSeconds = sdkConnectTimeoutSeconds
        self.sdkRelaunchMaxAttempts = sdkRelaunchMaxAttempts
        self.permissionMode = permissionMode
        self.allowNativeBashTool = allowNativeBashTool
        self.toolContext = toolContext
        self.disallowedBuiltInTools = disallowedBuiltInTools
        self.mcpStrictMode = mcpStrictMode
        self.toolSearchEnabled = toolSearchEnabled
        self.effortLevel = effortLevel
        self.processEnvironmentOverrides = processEnvironmentOverrides
        self.effortEnvironmentOverrides = effortEnvironmentOverrides
        self.backendConfig = backendConfig
    }
}

public struct ClaudeCompatibleProviderAvailability: Codable, Hashable, Sendable {
    public let pluginID: ClaudeCompatibleProviderPluginID
    public let isAvailable: Bool
    public let reason: String?

    public init(pluginID: ClaudeCompatibleProviderPluginID, isAvailable: Bool, reason: String? = nil) {
        self.pluginID = pluginID
        self.isAvailable = isAvailable
        self.reason = reason
    }
}

public struct ClaudeCompatibleModelOption: Codable, Hashable, Sendable {
    public let rawValue: String
    public let displayName: String
    public let description: String?
    public let isPlaceholderDefault: Bool
    public let isProviderDefault: Bool
    public let supportedEffortLevels: [String]

    public init(
        rawValue: String,
        displayName: String,
        description: String?,
        isPlaceholderDefault: Bool,
        isProviderDefault: Bool,
        supportedEffortLevels: [String] = []
    ) {
        self.rawValue = rawValue
        self.displayName = displayName
        self.description = description
        self.isPlaceholderDefault = isPlaceholderDefault
        self.isProviderDefault = isProviderDefault
        self.supportedEffortLevels = supportedEffortLevels
    }
}

public struct ClaudeCompatibleModelCatalogSnapshot: Codable, Hashable, Sendable {
    public let pluginID: ClaudeCompatibleProviderPluginID
    public let defaultModelRaw: String
    public let options: [ClaudeCompatibleModelOption]

    public init(
        pluginID: ClaudeCompatibleProviderPluginID,
        defaultModelRaw: String,
        options: [ClaudeCompatibleModelOption]
    ) {
        self.pluginID = pluginID
        self.defaultModelRaw = defaultModelRaw
        self.options = options
    }
}

public enum ClaudeCompatibleModelCatalog {
    private struct StaticModel {
        let rawValue: String
        let displayName: String
        let description: String
        let supportsXHigh: Bool
    }

    private static let defaultRaw = "default"
    private static let haikuRaw = "haiku"
    private static let sonnetRaw = "sonnet"
    private static let opusRaw = "opus"
    private static let fable5Raw = "claude-fable-5"
    private static let opus1mRaw = "opus[1m]"
    private static let opus47Raw = "claude-opus-4-7"
    private static let opus46Raw = "claude-opus-4-6"
    private static let opus45Raw = "claude-opus-4-5"
    private static let sonnet46Raw = "claude-sonnet-4-6"
    private static let sonnet45Raw = "claude-sonnet-4-5"
    private static let haiku45Raw = "claude-haiku-4-5"

    private static let claudeModels: [StaticModel] = [
        StaticModel(
            rawValue: fable5Raw,
            displayName: "Fable 5",
            description: "Claude Fable 5. Anthropic's most capable widely released model for demanding reasoning and long-horizon agentic work.",
            supportsXHigh: true
        ),
        StaticModel(
            rawValue: opus1mRaw,
            displayName: "Opus Latest (1M)",
            description: "Claude Opus with 1M token context. Best for large codebases and tasks requiring extensive context.",
            supportsXHigh: true
        ),
        StaticModel(
            rawValue: opusRaw,
            displayName: "Opus Latest",
            description: "Most capable Opus-tier model. Best for open-ended tasks, architecture, and complex reasoning.",
            supportsXHigh: true
        ),
        StaticModel(
            rawValue: opus47Raw,
            displayName: "Opus 4.7",
            description: "Pinned Claude Opus 4.7. Opus-tier capability for complex reasoning and architecture.",
            supportsXHigh: true
        ),
        StaticModel(
            rawValue: opus46Raw,
            displayName: "Opus 4.6",
            description: "Pinned Claude Opus 4.6. Opus-tier capability for complex reasoning and architecture.",
            supportsXHigh: true
        ),
        StaticModel(
            rawValue: opus45Raw,
            displayName: "Opus 4.5",
            description: "Pinned Claude Opus 4.5. Opus-tier capability for complex reasoning and architecture.",
            supportsXHigh: true
        ),
        StaticModel(
            rawValue: sonnetRaw,
            displayName: "Sonnet Latest",
            description: "Balanced speed and capability. Good for general coding, analysis, and everyday work.",
            supportsXHigh: false
        ),
        StaticModel(
            rawValue: sonnet46Raw,
            displayName: "Sonnet 4.6",
            description: "Pinned Claude Sonnet 4.6. Balanced speed and capability for everyday engineering.",
            supportsXHigh: false
        ),
        StaticModel(
            rawValue: sonnet45Raw,
            displayName: "Sonnet 4.5",
            description: "Pinned Claude Sonnet 4.5. Balanced speed and capability for everyday engineering.",
            supportsXHigh: false
        ),
        StaticModel(
            rawValue: haikuRaw,
            displayName: "Haiku Latest",
            description: "Fast and lightweight. Good for exploration, quick edits, and mapping codebases.",
            supportsXHigh: false
        ),
        StaticModel(
            rawValue: haiku45Raw,
            displayName: "Haiku 4.5",
            description: "Pinned Claude Haiku 4.5. Fast and lightweight for quick edits and exploration.",
            supportsXHigh: false
        )
    ]

    private static let effortOrder: [(raw: String, displayName: String)] = [
        ("low", "Low"),
        ("medium", "Medium"),
        ("high", "High"),
        ("max", "Max"),
        ("xhigh", "XHigh")
    ]

    public static func snapshot(
        pluginID: ClaudeCompatibleProviderPluginID,
        backendConfig: ClaudeCompatibleBackendConfig? = nil,
        includeEffortVariants: Bool = true
    ) -> ClaudeCompatibleModelCatalogSnapshot {
        switch pluginID {
        case .claudeCode:
            let baseOptions = [defaultOption()] + claudeModels.map { model in
                ClaudeCompatibleModelOption(
                    rawValue: model.rawValue,
                    displayName: model.displayName,
                    description: model.description,
                    isPlaceholderDefault: false,
                    isProviderDefault: false,
                    supportedEffortLevels: supportedEfforts(supportsXHigh: model.supportsXHigh).map(\.raw)
                )
            }
            return ClaudeCompatibleModelCatalogSnapshot(
                pluginID: pluginID,
                defaultModelRaw: opusRaw,
                options: includeEffortVariants ? expandedOptions(from: baseOptions) : baseOptions
            )
        case .zaiClaudeCode, .kimiClaudeCode, .customClaudeCompatible:
            let backendID = backendID(for: pluginID)
            let config = (backendConfig ?? backendID.defaultPreset).normalized
            let baseOptions = compatibleBackendOptions(backendID: backendID, config: config)
            return ClaudeCompatibleModelCatalogSnapshot(
                pluginID: pluginID,
                defaultModelRaw: compatibleBackendDefaultRaw(backendID: backendID, config: config),
                options: includeEffortVariants ? expandedOptions(from: baseOptions) : baseOptions
            )
        }
    }

    private static func defaultOption() -> ClaudeCompatibleModelOption {
        ClaudeCompatibleModelOption(
            rawValue: defaultRaw,
            displayName: "Default",
            description: "Use the agent's default model. Good starting point when unsure.",
            isPlaceholderDefault: true,
            isProviderDefault: false
        )
    }

    private static func backendID(for pluginID: ClaudeCompatibleProviderPluginID) -> ClaudeCompatibleBackendID {
        switch pluginID {
        case .zaiClaudeCode:
            .glmZAI
        case .kimiClaudeCode:
            .kimi
        case .customClaudeCompatible:
            .custom
        case .claudeCode:
            .glmZAI
        }
    }

    private static func compatibleBackendDefaultRaw(
        backendID: ClaudeCompatibleBackendID,
        config: ClaudeCompatibleBackendConfig
    ) -> String {
        switch config.modelBehavior {
        case .noModel:
            ClaudeCompatibleModelNormalizer.noModelRawValue(for: backendID)
        case .claudeSlotMapping:
            sonnetRaw
        }
    }

    private static func compatibleBackendOptions(
        backendID: ClaudeCompatibleBackendID,
        config: ClaudeCompatibleBackendConfig
    ) -> [ClaudeCompatibleModelOption] {
        switch config.modelBehavior {
        case .noModel:
            let rawValue = ClaudeCompatibleModelNormalizer.noModelRawValue(for: backendID)
            return [ClaudeCompatibleModelOption(
                rawValue: rawValue,
                displayName: noModelDisplayName(backendID: backendID, config: config),
                description: "No model flag. RepoPrompt does not pass --model or Claude effort settings for this backend.",
                isPlaceholderDefault: false,
                isProviderDefault: true
            )]
        case let .claudeSlotMapping(mapping):
            let normalized = mapping.normalized
            return [
                compatibleSlotOption(slotRaw: haikuRaw, backendModelID: normalized.haiku, slotName: "Haiku"),
                compatibleSlotOption(slotRaw: sonnetRaw, backendModelID: normalized.sonnet, slotName: "Sonnet", isProviderDefault: true),
                compatibleSlotOption(slotRaw: opusRaw, backendModelID: normalized.opus, slotName: "Opus")
            ]
        }
    }

    private static func noModelDisplayName(
        backendID: ClaudeCompatibleBackendID,
        config: ClaudeCompatibleBackendConfig
    ) -> String {
        switch backendID {
        case .kimi:
            "Kimi Code"
        case .glmZAI, .custom:
            config.normalizedDisplayName
        }
    }

    private static func compatibleSlotOption(
        slotRaw: String,
        backendModelID: String,
        slotName: String,
        isProviderDefault: Bool = false
    ) -> ClaudeCompatibleModelOption {
        ClaudeCompatibleModelOption(
            rawValue: slotRaw,
            displayName: displayName(forBackendModelID: backendModelID),
            description: "Routes Claude Code's \(slotName) model slot to \(backendModelID).",
            isPlaceholderDefault: false,
            isProviderDefault: isProviderDefault,
            supportedEffortLevels: supportedEfforts(supportsXHigh: false).map(\.raw)
        )
    }

    private static func displayName(forBackendModelID modelID: String) -> String {
        switch modelID {
        case "glm-4.7":
            "GLM 4.7"
        case "glm-5-turbo":
            "GLM 5 Turbo"
        case "glm-5.1":
            "GLM 5.1"
        default:
            modelID
        }
    }

    private static func expandedOptions(
        from baseOptions: [ClaudeCompatibleModelOption]
    ) -> [ClaudeCompatibleModelOption] {
        baseOptions.flatMap { option -> [ClaudeCompatibleModelOption] in
            if option.isPlaceholderDefault {
                return [option]
            }
            let efforts = option.supportedEffortLevels.isEmpty
                ? []
                : option.supportedEffortLevels.compactMap { effort in
                    effortOrder.first { $0.raw == effort }
                }
            guard !efforts.isEmpty else { return [option] }
            return efforts.map { effort in
                ClaudeCompatibleModelOption(
                    rawValue: "\(option.rawValue):\(effort.raw)",
                    displayName: "\(option.displayName) \(effort.displayName)",
                    description: option.description,
                    isPlaceholderDefault: false,
                    isProviderDefault: false
                )
            }
        }
    }

    private static func supportedEfforts(supportsXHigh: Bool) -> [(raw: String, displayName: String)] {
        supportsXHigh ? effortOrder : effortOrder.filter { $0.raw != "xhigh" }
    }
}

public struct ClaudeCompatibleNativeSessionRef: Codable, Hashable, Sendable {
    public let sessionID: String?
    public let turnID: UUID?

    public init(sessionID: String?, turnID: UUID? = nil) {
        self.sessionID = sessionID
        self.turnID = turnID
    }
}

public struct ClaudeCompatibleNativeStartRequest: Codable, Hashable, Sendable {
    public let existingSessionID: String?
    public let model: String?
    public let effortLevel: String?
    public let systemPromptOverride: String?
    public let runtimeConfig: ClaudeCompatibleRuntimeConfig

    public init(
        existingSessionID: String?,
        model: String?,
        effortLevel: String?,
        systemPromptOverride: String?,
        runtimeConfig: ClaudeCompatibleRuntimeConfig
    ) {
        self.existingSessionID = existingSessionID
        self.model = model
        self.effortLevel = effortLevel
        self.systemPromptOverride = systemPromptOverride
        self.runtimeConfig = runtimeConfig
    }
}

public enum ClaudeCompatibleTurnStatus: String, Codable, Hashable, Sendable {
    case completed
    case cancelled
    case failed
}

public enum ClaudeCompatibleInterruptOutcome: String, Codable, Hashable, Sendable {
    case acknowledged
    case noTurnInFlight
    case timedOut
    case failed
}

public struct ClaudeCompatibleInitializeResponseSnapshot: Codable, Hashable, Sendable {
    public struct Command: Codable, Hashable, Sendable {
        public let name: String
        public let description: String
        public let argumentHint: String

        public init(name: String, description: String, argumentHint: String) {
            self.name = name
            self.description = description
            self.argumentHint = argumentHint
        }
    }

    public struct Agent: Codable, Hashable, Sendable {
        public let name: String
        public let description: String
        public let model: String?

        public init(name: String, description: String, model: String?) {
            self.name = name
            self.description = description
            self.model = model
        }
    }

    public struct Account: Codable, Hashable, Sendable {
        public let email: String?
        public let organization: String?
        public let subscriptionType: String?
        public let tokenSource: String?
        public let apiKeySource: String?
        public let apiProvider: String?

        public init(
            email: String?,
            organization: String?,
            subscriptionType: String?,
            tokenSource: String?,
            apiKeySource: String?,
            apiProvider: String?
        ) {
            self.email = email
            self.organization = organization
            self.subscriptionType = subscriptionType
            self.tokenSource = tokenSource
            self.apiKeySource = apiKeySource
            self.apiProvider = apiProvider
        }
    }

    public let commands: [Command]
    public let agents: [Agent]
    public let outputStyle: String?
    public let availableOutputStyles: [String]
    public let account: Account?
    public let pid: Int?
    public let modelsJSON: String?
    public let fastModeStateJSON: String?

    public init(
        commands: [Command] = [],
        agents: [Agent] = [],
        outputStyle: String? = nil,
        availableOutputStyles: [String] = [],
        account: Account? = nil,
        pid: Int? = nil,
        modelsJSON: String? = nil,
        fastModeStateJSON: String? = nil
    ) {
        self.commands = commands
        self.agents = agents
        self.outputStyle = outputStyle
        self.availableOutputStyles = availableOutputStyles
        self.account = account
        self.pid = pid
        self.modelsJSON = modelsJSON
        self.fastModeStateJSON = fastModeStateJSON
    }
}

public struct ClaudeCompatibleRuntimeInitStatus: Codable, Hashable, Sendable {
    public let sessionID: String?
    public let tools: [String]
    public let mcpServerStatuses: [String: String]
    public let initializeResponse: ClaudeCompatibleInitializeResponseSnapshot?

    public init(
        sessionID: String?,
        tools: [String],
        mcpServerStatuses: [String: String],
        initializeResponse: ClaudeCompatibleInitializeResponseSnapshot? = nil
    ) {
        self.sessionID = sessionID
        self.tools = tools
        self.mcpServerStatuses = mcpServerStatuses
        self.initializeResponse = initializeResponse
    }

    public func repoPromptServerStatus(serverName: String) -> String? {
        mcpServerStatuses.first {
            $0.key.compare(serverName, options: .caseInsensitive) == .orderedSame
        }?.value
    }

    public func isRepoPromptServerFailed(serverName: String) -> Bool {
        guard let status = repoPromptServerStatus(serverName: serverName)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        else {
            return false
        }
        return status == "failed"
    }
}

public enum ClaudeCompatibleApprovalDecision: Codable, Hashable, Sendable {
    case allow
    case deny(reason: String?)
}

public struct ClaudeCompatibleApprovalRequest: Codable, Equatable, Sendable {
    public let id: String
    public let toolName: String
    public let arguments: [String: ClaudeProviderJSONValue]
    public let message: String?

    public init(
        id: String,
        toolName: String,
        arguments: [String: ClaudeProviderJSONValue] = [:],
        message: String? = nil
    ) {
        self.id = id
        self.toolName = toolName
        self.arguments = arguments
        self.message = message
    }
}

public enum ClaudeCompatibleRuntimeEvent: Sendable, Equatable {
    case streamResult(ClaudeProviderStreamResult)
    case runtimeInit(ClaudeCompatibleRuntimeInitStatus)
    case approvalRequest(ClaudeCompatibleApprovalRequest)
    case approvalCancelled(requestID: String)
    case turnCompleted(turnID: UUID, status: ClaudeCompatibleTurnStatus)
    case lifecycle(String)
    case completed(providerSessionID: String?)
    case failed(message: String)
}

import Foundation

/// Stable identifiers for the portable provider settings surface. Exact
/// identities survive even when several implementations share the portable
/// `headlessAdapter` runtime kind.
public enum ProviderSettingsID: String, Codable, CaseIterable, Sendable {
    case codex
    case claudeCompatible
    case claudeGLM
    case claudeKimi
    case claudeCustom
    case openCodeACP
    case cursorACP
    case grokBuildACP
    case openAIAPI
    case anthropicAPI
    case openRouter
    case customOpenAICompatible
    case gemini
    case azure
    case deepseek
    case fireworks
    case xAI
    case groq
    case zAI
    case ollama

    public static var directAPIProviders: [ProviderSettingsID] {
        allCases.filter(\.isDirectAPI)
    }

    public static func defaultSettingsID(for runtimeKind: ProviderKind) -> ProviderSettingsID? {
        switch runtimeKind {
        case .codex: .codex
        case .claudeCompatible: .claudeCompatible
        case .openCodeACP: .openCodeACP
        case .cursorACP: .cursorACP
        case .grokBuildACP: .grokBuildACP
        case .headlessAdapter, .mcp: nil
        }
    }

    public var runtimeKind: ProviderKind? {
        switch self {
        case .codex: .codex
        case .claudeCompatible, .claudeGLM, .claudeKimi, .claudeCustom: .claudeCompatible
        case .openCodeACP: .openCodeACP
        case .cursorACP: .cursorACP
        case .grokBuildACP: .grokBuildACP
        case .openAIAPI, .anthropicAPI, .openRouter, .customOpenAICompatible,
             .gemini, .azure, .deepseek, .fireworks, .xAI, .groq, .zAI, .ollama:
            .headlessAdapter
        }
    }

    /// One native Claude process controller serves the standard account and
    /// compatible backends. Only the standard row owns dispatcher admission;
    /// backend rows select launch configuration and credentials per session.
    public var ownsRuntimeAdmission: Bool {
        switch self {
        case .codex, .claudeCompatible, .openCodeACP, .cursorACP, .grokBuildACP: true
        case .claudeGLM, .claudeKimi, .claudeCustom,
             .openAIAPI, .anthropicAPI, .openRouter, .customOpenAICompatible,
             .gemini, .azure, .deepseek, .fireworks, .xAI, .groq, .zAI, .ollama:
            false
        }
    }

    public var runtimeSettingsOwner: ProviderSettingsID {
        switch self {
        case .claudeGLM, .claudeKimi, .claudeCustom: .claudeCompatible
        default: self
        }
    }

    public var isDirectAPI: Bool {
        switch self {
        case .openAIAPI, .anthropicAPI, .openRouter, .customOpenAICompatible,
             .gemini, .azure, .deepseek, .fireworks, .xAI, .groq, .zAI, .ollama:
            true
        default: false
        }
    }

    /// Desktop OpenAI, Azure, Ollama, and custom OpenAI-compatible persist an
    /// operator URL. Other vendors keep `baseURL == nil`.
    public var acceptsPersistedBaseURL: Bool {
        switch self {
        case .openAIAPI, .customOpenAICompatible, .azure, .ollama: true
        default: false
        }
    }

    /// Desktop OpenAI and Azure persist an API-version override. Custom
    /// OpenAI-compatible persists `apiVersion` as a path segment.
    public var acceptsPersistedAPIVersion: Bool {
        switch self {
        case .openAIAPI, .customOpenAICompatible, .azure: true
        default: false
        }
    }

    /// Desktop bootstrap token contract. `0` means omit / use the model default.
    public var desktopBootstrapMaxTokens: Int {
        switch self {
        case .groq: 16384
        case .anthropicAPI, .openRouter: 8192
        case .openAIAPI, .customOpenAICompatible: 0
        default: 4096
        }
    }

    public var acceptsCustomHeaders: Bool {
        switch self {
        case .openRouter, .customOpenAICompatible, .azure: true
        default: false
        }
    }

    /// Ollama's Desktop store is a URL, not a Keychain API key.
    public var requiresVaultCredential: Bool {
        isDirectAPI && self != .ollama
    }

    public static let desktopOllamaDefaultURL = "http://localhost:11434"

    /// Desktop Direct Agents persist a typed profile for these CLI families.
    /// `serverDefaultExecutionMode` must not replace that profile.
    public var hasTypedDirectAgentProfile: Bool {
        switch self {
        case .codex, .claudeCompatible, .claudeGLM, .claudeKimi, .claudeCustom, .openCodeACP, .cursorACP, .grokBuildACP:
            true
        case .openAIAPI, .anthropicAPI, .openRouter, .customOpenAICompatible,
             .gemini, .azure, .deepseek, .fireworks, .xAI, .groq, .zAI, .ollama:
            false
        }
    }
}

public enum ProviderSettingsCategory: String, Codable, Sendable {
    case cliProvider
    case apiProvider
}

public enum ClaudeCompatibleBackendAuthHeader: String, Codable, Hashable, Sendable {
    case anthropicAPIKey
    case anthropicAuthToken

    public var authenticationMethod: ProviderAuthenticationMethod {
        switch self {
        case .anthropicAPIKey: .apiKey
        case .anthropicAuthToken: .authToken
        }
    }

    public var environmentVariableName: String {
        switch self {
        case .anthropicAPIKey: "ANTHROPIC_API_KEY"
        case .anthropicAuthToken: "ANTHROPIC_AUTH_TOKEN"
        }
    }
}

public enum ClaudeCompatibleBackendModelBehavior: String, Codable, Hashable, Sendable {
    case noModel
    case claudeSlotMapping
}

/// Sanitized launch configuration shared by settings authority and the Linux
/// Claude runtime. Credential material is deliberately absent.
public struct ClaudeCompatibleBackendSettings: Codable, Hashable, Sendable {
    public let providerID: ProviderSettingsID
    public let isEnabled: Bool
    public let displayName: String
    public let baseURL: String
    public let authHeader: ClaudeCompatibleBackendAuthHeader
    public let modelBehavior: ClaudeCompatibleBackendModelBehavior
    public let haikuModel: String
    public let sonnetModel: String
    public let opusModel: String

    public init(
        providerID: ProviderSettingsID,
        isEnabled: Bool = true,
        displayName: String,
        baseURL: String,
        authHeader: ClaudeCompatibleBackendAuthHeader,
        modelBehavior: ClaudeCompatibleBackendModelBehavior,
        haikuModel: String = "",
        sonnetModel: String = "",
        opusModel: String = ""
    ) {
        self.providerID = providerID
        self.isEnabled = isEnabled
        self.displayName = displayName
        self.baseURL = baseURL
        self.authHeader = authHeader
        self.modelBehavior = modelBehavior
        self.haikuModel = haikuModel
        self.sonnetModel = sonnetModel
        self.opusModel = opusModel
    }
}

public enum ProviderAuthenticationMethod: String, Codable, CaseIterable, Sendable {
    case browserOAuth
    case deviceCodeBeta
    case apiKey
    case enterpriseAccessToken
    case authToken
    case keyHelper
    case workloadIdentityFederation
    case browserLogin
    case providerSpecific
}

public struct ProviderCLIHealth: Codable, Hashable, Sendable {
    public let installed: Bool
    public let healthy: Bool
    public let version: String?
    public let expectedVersion: String?
    public let detail: String?

    public init(installed: Bool, healthy: Bool, version: String? = nil, expectedVersion: String? = nil, detail: String? = nil) {
        self.installed = installed
        self.healthy = healthy
        self.version = version
        self.expectedVersion = expectedVersion
        self.detail = detail
    }
}

public struct ProviderModelCatalogEntry: Codable, Hashable, Sendable {
    public let id: String
    public let providerRawValue: String?
    public let displayName: String
    public let description: String?
    public let isProviderDefault: Bool
    public let reasoningEfforts: [String]
    public let defaultReasoningEffort: String?
    public let serviceTier: String?
    public let speedModes: [String]
    public let serviceTiers: [String]
    public let supportsNativeImages: Bool
    public let supportsSteering: Bool

    public init(
        id: String,
        providerRawValue: String? = nil,
        displayName: String,
        description: String? = nil,
        isProviderDefault: Bool = false,
        reasoningEfforts: [String] = [],
        defaultReasoningEffort: String? = nil,
        serviceTier: String? = nil,
        speedModes: [String] = [],
        serviceTiers: [String] = [],
        supportsNativeImages: Bool = false,
        supportsSteering: Bool = false
    ) {
        self.id = id
        self.providerRawValue = providerRawValue
        self.displayName = displayName
        self.description = description
        self.isProviderDefault = isProviderDefault
        self.reasoningEfforts = reasoningEfforts
        self.defaultReasoningEffort = defaultReasoningEffort
        self.serviceTier = serviceTier
        self.speedModes = speedModes
        self.serviceTiers = serviceTiers
        self.supportsNativeImages = supportsNativeImages
        self.supportsSteering = supportsSteering
    }

    private enum CodingKeys: String, CodingKey {
        case id, providerRawValue, displayName, description, isProviderDefault, reasoningEfforts, defaultReasoningEffort, serviceTier
        case speedModes, serviceTiers, supportsNativeImages, supportsSteering
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        providerRawValue = try container.decodeIfPresent(String.self, forKey: .providerRawValue)
        displayName = try container.decode(String.self, forKey: .displayName)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        isProviderDefault = try container.decodeIfPresent(Bool.self, forKey: .isProviderDefault) ?? false
        reasoningEfforts = try container.decodeIfPresent([String].self, forKey: .reasoningEfforts) ?? []
        defaultReasoningEffort = try container.decodeIfPresent(String.self, forKey: .defaultReasoningEffort)
        serviceTier = try container.decodeIfPresent(String.self, forKey: .serviceTier)
        speedModes = try container.decodeIfPresent([String].self, forKey: .speedModes) ?? []
        serviceTiers = try container.decodeIfPresent([String].self, forKey: .serviceTiers) ?? []
        supportsNativeImages = try container.decodeIfPresent(Bool.self, forKey: .supportsNativeImages) ?? false
        supportsSteering = try container.decodeIfPresent(Bool.self, forKey: .supportsSteering) ?? false
    }
}

public struct ProviderSettingsCapabilities: Codable, Hashable, Sendable {
    public let supportsModelSelection: Bool
    public let supportsReasoningEffort: Bool
    public let supportsSpeedMode: Bool
    public let supportsServiceTier: Bool
    public let authenticationMethods: [ProviderAuthenticationMethod]

    public init(
        supportsModelSelection: Bool,
        supportsReasoningEffort: Bool,
        supportsSpeedMode: Bool,
        supportsServiceTier: Bool,
        authenticationMethods: [ProviderAuthenticationMethod] = []
    ) {
        self.supportsModelSelection = supportsModelSelection
        self.supportsReasoningEffort = supportsReasoningEffort
        self.supportsSpeedMode = supportsSpeedMode
        self.supportsServiceTier = supportsServiceTier
        self.authenticationMethods = authenticationMethods
    }
}

/// Non-secret, revisioned defaults applied by the Swift provider dispatcher.
public struct ProviderSettingsPreference: Codable, Hashable, Sendable {
    public let providerID: ProviderSettingsID
    public let enabled: Bool
    public let defaultModel: String?
    public let reasoningEffort: String?
    public let speedMode: String?
    public let serviceTier: String?
    public let revision: Int64

    public init(providerID: ProviderSettingsID, enabled: Bool, defaultModel: String? = nil, reasoningEffort: String? = nil, speedMode: String? = nil, serviceTier: String? = nil, revision: Int64 = 1) {
        self.providerID = providerID
        self.enabled = enabled
        self.defaultModel = defaultModel
        self.reasoningEffort = reasoningEffort
        self.speedMode = speedMode
        self.serviceTier = serviceTier
        self.revision = revision
    }
}

public struct ProviderSettingsSnapshot: Codable, Hashable, Sendable {
    public let providerID: ProviderSettingsID
    public let displayName: String
    public let category: ProviderSettingsCategory
    public let summary: String
    public let deploymentAllowed: Bool
    public let runtimePreflightVerified: Bool
    public let effectiveEnabled: Bool
    public let preference: ProviderSettingsPreference
    public let cli: ProviderCLIHealth?
    /// Whether a durable connection or external credential source is present.
    /// Readiness remains authoritative in `preflight`.
    public let configurationPresent: Bool
    public let connection: ProviderConnectionRecord?
    public let preflight: ProviderPreflightStatus
    public let capabilities: ProviderSettingsCapabilities
    public let models: [ProviderModelCatalogEntry]

    public init(providerID: ProviderSettingsID, displayName: String, category: ProviderSettingsCategory, summary: String, deploymentAllowed: Bool, runtimePreflightVerified: Bool, effectiveEnabled: Bool, preference: ProviderSettingsPreference, cli: ProviderCLIHealth?, configurationPresent: Bool, connection: ProviderConnectionRecord? = nil, preflight: ProviderPreflightStatus = .init(ready: false, reason: .runtimeUnavailable, detail: "Provider preflight has not run"), capabilities: ProviderSettingsCapabilities, models: [ProviderModelCatalogEntry]) {
        self.providerID = providerID
        self.displayName = displayName
        self.category = category
        self.summary = summary
        self.deploymentAllowed = deploymentAllowed
        self.runtimePreflightVerified = runtimePreflightVerified
        self.effectiveEnabled = effectiveEnabled
        self.preference = preference
        self.cli = cli
        self.configurationPresent = configurationPresent
        self.connection = connection
        self.preflight = preflight
        self.capabilities = capabilities
        self.models = models
    }
}

public struct ProviderSettingsCatalogResponse: Codable, Sendable {
    public let providers: [ProviderSettingsSnapshot]
    public let generatedAt: Date

    public init(providers: [ProviderSettingsSnapshot], generatedAt: Date = Date()) {
        self.providers = providers
        self.generatedAt = generatedAt
    }
}

/// Full replacement avoids ambiguous omitted-vs-null PATCH semantics.
public struct UpdateProviderSettingsRequest: Codable, Hashable, Sendable {
    public let expectedRevision: Int64
    public let enabled: Bool
    public let defaultModel: String?
    public let reasoningEffort: String?
    public let speedMode: String?
    public let serviceTier: String?

    public init(expectedRevision: Int64, enabled: Bool, defaultModel: String?, reasoningEffort: String?, speedMode: String?, serviceTier: String?) {
        self.expectedRevision = expectedRevision
        self.enabled = enabled
        self.defaultModel = defaultModel
        self.reasoningEffort = reasoningEffort
        self.speedMode = speedMode
        self.serviceTier = serviceTier
    }
}

import Foundation
import RepoPromptRuntimeModel

public enum ComposerContextKind: String, Codable, Hashable, Sendable {
    case project
    case session
}

public struct ComposerCatalogContext: Codable, Hashable, Sendable {
    public let kind: ComposerContextKind
    public let projectID: UUID
    public let sessionID: UUID?
    public let actorID: String
    public let activeRun: Bool
    public let mcpControlled: Bool

    public init(kind: ComposerContextKind, projectID: UUID, sessionID: UUID? = nil, actorID: String, activeRun: Bool = false, mcpControlled: Bool = false) {
        self.kind = kind
        self.projectID = projectID
        self.sessionID = sessionID
        self.actorID = actorID
        self.activeRun = activeRun
        self.mcpControlled = mcpControlled
    }
}

public struct ProviderDiscoveryPolicy: Codable, Hashable, Sendable {
    public let liveFreshnessSeconds: Int
    public let persistedFallbackMaximumAgeSeconds: Int
    public let allowsPersistedFallback: Bool
    public let allowsStaticFallbackAfterSuccessfulPreflight: Bool
    public let discoveryReplacesStaticChoices: Bool

    public init(
        liveFreshnessSeconds: Int = 15 * 60,
        persistedFallbackMaximumAgeSeconds: Int = 24 * 60 * 60,
        allowsPersistedFallback: Bool,
        allowsStaticFallbackAfterSuccessfulPreflight: Bool,
        discoveryReplacesStaticChoices: Bool
    ) {
        self.liveFreshnessSeconds = liveFreshnessSeconds
        self.persistedFallbackMaximumAgeSeconds = persistedFallbackMaximumAgeSeconds
        self.allowsPersistedFallback = allowsPersistedFallback
        self.allowsStaticFallbackAfterSuccessfulPreflight = allowsStaticFallbackAfterSuccessfulPreflight
        self.discoveryReplacesStaticChoices = discoveryReplacesStaticChoices
    }
}

public struct ProviderAvailabilityMatrixEntry: Codable, Hashable, Sendable {
    public let providerID: ProviderSettingsID
    public let displayName: String
    public let runtimeKind: ProviderKind?
    public let modelSource: String
    public let failurePolicy: String
    public let discoveryPolicy: ProviderDiscoveryPolicy
    public let nativeImageSupportRequiresAdapter: Bool

    public init(
        providerID: ProviderSettingsID,
        displayName: String,
        runtimeKind: ProviderKind?,
        modelSource: String,
        failurePolicy: String,
        discoveryPolicy: ProviderDiscoveryPolicy,
        nativeImageSupportRequiresAdapter: Bool = true
    ) {
        self.providerID = providerID
        self.displayName = displayName
        self.runtimeKind = runtimeKind
        self.modelSource = modelSource
        self.failurePolicy = failurePolicy
        self.discoveryPolicy = discoveryPolicy
        self.nativeImageSupportRequiresAdapter = nativeImageSupportRequiresAdapter
    }
}

public enum AgentComposerProviderMatrix {
    public static let liveFreshnessSeconds = 15 * 60
    public static let persistedFallbackMaximumAgeSeconds = 24 * 60 * 60

    public static let entries: [ProviderAvailabilityMatrixEntry] = [
        .init(
            providerID: .codex,
            displayName: "Codex",
            runtimeKind: .codex,
            modelSource: "live-registry,persisted-dynamic-cache,recommended-static-after-preflight",
            failurePolicy: "omit-stale;preserve-selected-unavailable;refresh-on-model-rejection",
            discoveryPolicy: .init(allowsPersistedFallback: true, allowsStaticFallbackAfterSuccessfulPreflight: true, discoveryReplacesStaticChoices: false)
        ),
        .init(
            providerID: .claudeCompatible,
            displayName: "Claude Code",
            runtimeKind: .claudeCompatible,
            modelSource: "provider-supported-static-catalog-after-preflight",
            failurePolicy: "omit-on-preflight-failure;preserve-selected-unavailable",
            discoveryPolicy: .init(allowsPersistedFallback: false, allowsStaticFallbackAfterSuccessfulPreflight: true, discoveryReplacesStaticChoices: false)
        ),
        .init(
            providerID: .claudeGLM,
            displayName: "GLM",
            runtimeKind: .claudeCompatible,
            modelSource: "normalized-backend-configuration",
            failurePolicy: "omit-on-invalid-backend-or-preflight-failure",
            discoveryPolicy: .init(allowsPersistedFallback: false, allowsStaticFallbackAfterSuccessfulPreflight: false, discoveryReplacesStaticChoices: false)
        ),
        .init(
            providerID: .claudeKimi,
            displayName: "Kimi",
            runtimeKind: .claudeCompatible,
            modelSource: "normalized-backend-configuration",
            failurePolicy: "omit-on-invalid-backend-or-preflight-failure",
            discoveryPolicy: .init(allowsPersistedFallback: false, allowsStaticFallbackAfterSuccessfulPreflight: false, discoveryReplacesStaticChoices: false)
        ),
        .init(
            providerID: .claudeCustom,
            displayName: "Claude Compatible",
            runtimeKind: .claudeCompatible,
            modelSource: "normalized-backend-configuration",
            failurePolicy: "omit-on-invalid-backend-or-preflight-failure",
            discoveryPolicy: .init(allowsPersistedFallback: false, allowsStaticFallbackAfterSuccessfulPreflight: false, discoveryReplacesStaticChoices: false)
        ),
        .init(
            providerID: .openCodeACP,
            displayName: "OpenCode",
            runtimeKind: .openCodeACP,
            modelSource: "provider-base-model-variant-discovery,bounded-approved-fallback",
            failurePolicy: "omit-without-fresh-permitted-source;preserve-selected-unavailable",
            discoveryPolicy: .init(allowsPersistedFallback: true, allowsStaticFallbackAfterSuccessfulPreflight: true, discoveryReplacesStaticChoices: true)
        ),
        .init(
            providerID: .cursorACP,
            displayName: "Cursor",
            runtimeKind: .cursorACP,
            modelSource: "authoritative-auto-composer-plus-discovered-nonduplicates",
            failurePolicy: "retain-authoritative-static-only-after-preflight;age-out-discovery",
            discoveryPolicy: .init(allowsPersistedFallback: true, allowsStaticFallbackAfterSuccessfulPreflight: true, discoveryReplacesStaticChoices: false)
        ),
        .init(
            providerID: .grokBuildACP,
            displayName: "Grok Build",
            runtimeKind: .grokBuildACP,
            modelSource: "provider-base-model-variant-discovery,bounded-approved-fallback",
            failurePolicy: "omit-without-fresh-permitted-source;preserve-selected-unavailable",
            discoveryPolicy: .init(allowsPersistedFallback: true, allowsStaticFallbackAfterSuccessfulPreflight: true, discoveryReplacesStaticChoices: true)
        ),
        .init(
            providerID: .openAIAPI,
            displayName: "OpenAI API",
            runtimeKind: .headlessAdapter,
            modelSource: "bounded-authenticated-discovery,persisted-dynamic-cache",
            failurePolicy: "omit-without-fresh-authoritative-catalog;preserve-selected-unavailable",
            discoveryPolicy: .init(allowsPersistedFallback: true, allowsStaticFallbackAfterSuccessfulPreflight: false, discoveryReplacesStaticChoices: true),
            nativeImageSupportRequiresAdapter: false
        ),
        .init(
            providerID: .anthropicAPI,
            displayName: "Anthropic API",
            runtimeKind: .headlessAdapter,
            modelSource: "bounded-authenticated-discovery,persisted-dynamic-cache",
            failurePolicy: "omit-without-fresh-authoritative-catalog;preserve-selected-unavailable",
            discoveryPolicy: .init(allowsPersistedFallback: true, allowsStaticFallbackAfterSuccessfulPreflight: false, discoveryReplacesStaticChoices: true),
            nativeImageSupportRequiresAdapter: false
        ),
        .init(
            providerID: .openRouter,
            displayName: "OpenRouter",
            runtimeKind: .headlessAdapter,
            modelSource: "bounded-authenticated-discovery,persisted-dynamic-cache",
            failurePolicy: "omit-without-fresh-authoritative-catalog;preserve-selected-unavailable",
            discoveryPolicy: .init(allowsPersistedFallback: true, allowsStaticFallbackAfterSuccessfulPreflight: false, discoveryReplacesStaticChoices: true),
            nativeImageSupportRequiresAdapter: false
        ),
        .init(
            providerID: .customOpenAICompatible,
            displayName: "Custom OpenAI-Compatible",
            runtimeKind: .headlessAdapter,
            modelSource: "bounded-authenticated-discovery,persisted-dynamic-cache",
            failurePolicy: "omit-without-fresh-authoritative-catalog;preserve-selected-unavailable",
            discoveryPolicy: .init(allowsPersistedFallback: true, allowsStaticFallbackAfterSuccessfulPreflight: false, discoveryReplacesStaticChoices: true),
            nativeImageSupportRequiresAdapter: false
        ),
        .init(
            providerID: .gemini,
            displayName: "Gemini",
            runtimeKind: .headlessAdapter,
            modelSource: "bounded-authenticated-discovery,persisted-dynamic-cache",
            failurePolicy: "omit-without-fresh-authoritative-catalog;preserve-selected-unavailable",
            discoveryPolicy: .init(allowsPersistedFallback: true, allowsStaticFallbackAfterSuccessfulPreflight: false, discoveryReplacesStaticChoices: true),
            nativeImageSupportRequiresAdapter: false
        ),
        .init(
            providerID: .azure,
            displayName: "Azure",
            runtimeKind: .headlessAdapter,
            modelSource: "bounded-authenticated-discovery,persisted-dynamic-cache",
            failurePolicy: "omit-without-fresh-authoritative-catalog;preserve-selected-unavailable",
            discoveryPolicy: .init(allowsPersistedFallback: true, allowsStaticFallbackAfterSuccessfulPreflight: false, discoveryReplacesStaticChoices: true),
            nativeImageSupportRequiresAdapter: false
        ),
        .init(
            providerID: .deepseek,
            displayName: "DeepSeek",
            runtimeKind: .headlessAdapter,
            modelSource: "bounded-authenticated-discovery,persisted-dynamic-cache",
            failurePolicy: "omit-without-fresh-authoritative-catalog;preserve-selected-unavailable",
            discoveryPolicy: .init(allowsPersistedFallback: true, allowsStaticFallbackAfterSuccessfulPreflight: false, discoveryReplacesStaticChoices: true),
            nativeImageSupportRequiresAdapter: false
        ),
        .init(
            providerID: .fireworks,
            displayName: "Fireworks",
            runtimeKind: .headlessAdapter,
            modelSource: "bounded-authenticated-discovery,persisted-dynamic-cache",
            failurePolicy: "omit-without-fresh-authoritative-catalog;preserve-selected-unavailable",
            discoveryPolicy: .init(allowsPersistedFallback: true, allowsStaticFallbackAfterSuccessfulPreflight: false, discoveryReplacesStaticChoices: true),
            nativeImageSupportRequiresAdapter: false
        ),
        .init(
            providerID: .xAI,
            displayName: "xAI",
            runtimeKind: .headlessAdapter,
            modelSource: "bounded-authenticated-discovery,persisted-dynamic-cache",
            failurePolicy: "omit-without-fresh-authoritative-catalog;preserve-selected-unavailable",
            discoveryPolicy: .init(allowsPersistedFallback: true, allowsStaticFallbackAfterSuccessfulPreflight: false, discoveryReplacesStaticChoices: true),
            nativeImageSupportRequiresAdapter: false
        ),
        .init(
            providerID: .groq,
            displayName: "Groq",
            runtimeKind: .headlessAdapter,
            modelSource: "bounded-authenticated-discovery,persisted-dynamic-cache",
            failurePolicy: "omit-without-fresh-authoritative-catalog;preserve-selected-unavailable",
            discoveryPolicy: .init(allowsPersistedFallback: true, allowsStaticFallbackAfterSuccessfulPreflight: false, discoveryReplacesStaticChoices: true),
            nativeImageSupportRequiresAdapter: false
        ),
        .init(
            providerID: .zAI,
            displayName: "Z.AI",
            runtimeKind: .headlessAdapter,
            modelSource: "bounded-authenticated-discovery,persisted-dynamic-cache",
            failurePolicy: "omit-without-fresh-authoritative-catalog;preserve-selected-unavailable",
            discoveryPolicy: .init(allowsPersistedFallback: true, allowsStaticFallbackAfterSuccessfulPreflight: false, discoveryReplacesStaticChoices: true),
            nativeImageSupportRequiresAdapter: false
        ),
        .init(
            providerID: .ollama,
            displayName: "Ollama",
            runtimeKind: .headlessAdapter,
            modelSource: "bounded-authenticated-discovery,persisted-dynamic-cache",
            failurePolicy: "omit-without-fresh-authoritative-catalog;preserve-selected-unavailable",
            discoveryPolicy: .init(allowsPersistedFallback: true, allowsStaticFallbackAfterSuccessfulPreflight: false, discoveryReplacesStaticChoices: true),
            nativeImageSupportRequiresAdapter: false
        )
    ]

    public static func entry(for providerID: ProviderSettingsID) -> ProviderAvailabilityMatrixEntry? {
        entries.first { $0.providerID == providerID }
    }
}

public struct ProviderModelCapabilities: Codable, Hashable, Sendable {
    public let nativeImages: Bool
    public let steering: Bool

    public init(nativeImages: Bool = false, steering: Bool = false) {
        self.nativeImages = nativeImages
        self.steering = steering
    }
}

public struct ProviderModelDescriptor: Codable, Hashable, Sendable {
    public let providerID: ProviderSettingsID
    public let modelID: String
    public let providerRawValue: String
    public let displayName: String
    public let description: String?
    public let supportedEffortIDs: [String]
    public let defaultEffortID: String?
    public let serviceTier: String?
    public let capabilities: ProviderModelCapabilities

    public init(
        providerID: ProviderSettingsID,
        modelID: String,
        providerRawValue: String,
        displayName: String,
        description: String? = nil,
        supportedEffortIDs: [String] = [],
        defaultEffortID: String? = nil,
        serviceTier: String? = nil,
        capabilities: ProviderModelCapabilities = .init()
    ) {
        self.providerID = providerID
        self.modelID = modelID
        self.providerRawValue = providerRawValue
        self.displayName = displayName
        self.description = description
        self.supportedEffortIDs = supportedEffortIDs
        self.defaultEffortID = defaultEffortID
        self.serviceTier = serviceTier
        self.capabilities = capabilities
    }
}

public enum ProviderComposerControlDescriptor: Hashable, Sendable {
    case toggle(id: String, displayName: String, detailText: String?, value: Bool, required: Bool, mutable: Bool, warning: Bool, lockReasonCode: String?)
    case singleChoice(id: String, displayName: String, detailText: String?, selectedID: String, choices: [ProviderComposerChoiceDescriptor], required: Bool, mutable: Bool, warning: Bool, lockReasonCode: String?)
    case multiChoice(id: String, displayName: String, detailText: String?, selectedIDs: [String], choices: [ProviderComposerChoiceDescriptor], required: Bool, mutable: Bool, warning: Bool, lockReasonCode: String?)

    public var id: String {
        switch self {
        case let .toggle(id, _, _, _, _, _, _, _), let .singleChoice(id, _, _, _, _, _, _, _, _), let .multiChoice(id, _, _, _, _, _, _, _, _): id
        }
    }
}

public struct ProviderComposerChoiceDescriptor: Codable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let detailText: String?
    public let enabled: Bool
    public let warning: Bool

    public init(id: String, displayName: String, detailText: String? = nil, enabled: Bool = true, warning: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.detailText = detailText
        self.enabled = enabled
        self.warning = warning
    }
}

public struct ProviderPermissionDescriptor: Codable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let selectedID: String
    public let choices: [ProviderComposerChoiceDescriptor]
    public let externallyManaged: Bool
    public let mutable: Bool
    public let lockReasonCode: String?

    public init(id: String, displayName: String = "Permissions", selectedID: String, choices: [ProviderComposerChoiceDescriptor], externallyManaged: Bool = false, mutable: Bool = true, lockReasonCode: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.selectedID = selectedID
        self.choices = choices
        self.externallyManaged = externallyManaged
        self.mutable = mutable
        self.lockReasonCode = lockReasonCode
    }
}

public struct ProviderComposerAdvertisement: Sendable {
    public let providerID: ProviderSettingsID
    public let displayName: String
    public let available: Bool
    public let unavailableReasonCode: String?
    public let models: [ProviderModelDescriptor]
    public let toolControls: [ProviderComposerControlDescriptor]
    public let permissionControl: ProviderPermissionDescriptor?
    public let nativeCommandIDs: [String]

    public init(providerID: ProviderSettingsID, displayName: String, available: Bool, unavailableReasonCode: String? = nil, models: [ProviderModelDescriptor], toolControls: [ProviderComposerControlDescriptor] = [], permissionControl: ProviderPermissionDescriptor? = nil, nativeCommandIDs: [String] = []) {
        self.providerID = providerID
        self.displayName = displayName
        self.available = available
        self.unavailableReasonCode = unavailableReasonCode
        self.models = models
        self.toolControls = toolControls
        self.permissionControl = permissionControl
        self.nativeCommandIDs = nativeCommandIDs
    }
}

public protocol ProviderComposerAdapter: Sendable {
    var providerID: ProviderSettingsID { get }
    func advertisement(context: ComposerCatalogContext) async throws -> ProviderComposerAdvertisement
}

public struct ComposerSuggestionDescriptor: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable { case nativeCommand, skill, file }
    public let kind: Kind
    public let id: String
    public let insertionText: String
    public let displayName: String
    public let detailText: String?
    public let providerIDs: [ProviderSettingsID]
    public let available: Bool
    /// Service-only expansion or native invocation; never projected in suggestion wire metadata.
    public let expansion: String?

    public init(kind: Kind, id: String, insertionText: String, displayName: String, detailText: String? = nil, providerIDs: [ProviderSettingsID] = [], available: Bool = true, expansion: String? = nil) {
        self.kind = kind
        self.id = id
        self.insertionText = insertionText
        self.displayName = displayName
        self.detailText = detailText
        self.providerIDs = providerIDs
        self.available = available
        self.expansion = expansion
    }
}

public struct AgentEmptyStateDescriptor: Codable, Hashable, Sendable {
    public let heading: String
    public let featuredWorkflowIDs: [String]
    public let tips: [String]

    public init(heading: String = "What are we building?", featuredWorkflowIDs: [String], tips: [String]) {
        self.heading = heading
        self.featuredWorkflowIDs = featuredWorkflowIDs
        self.tips = tips
    }
}

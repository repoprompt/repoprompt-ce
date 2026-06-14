import Foundation

/// Core facade for GLM/Z.ai Claude-compatible helpers.
///
/// UserDefaults configuration flags and notification names stay in core; model
/// normalization/catalog rules are delegated to the provider package via
/// `ClaudeCompatibleProviderRuntimeBridge`.
enum ClaudeCodeGLMIntegration {
    static let configuredDefaultsKey = "ClaudeCodeGLMZAIConfigured"
    static let defaultModelRawValue = ClaudeCompatibleProviderRuntimeBridge.glmDefaultModelRawValue
    static let haikuEquivalentModelRawValue = ClaudeCompatibleProviderRuntimeBridge.glmHaikuEquivalentModelRawValue
    static let opusEquivalentModelRawValue = ClaudeCompatibleProviderRuntimeBridge.glmOpusEquivalentModelRawValue
    static let defaultRequestedModelRawValue = ClaudeCompatibleProviderRuntimeBridge.glmDefaultRequestedModelRawValue
    static let haikuRequestedModelRawValue = ClaudeCompatibleProviderRuntimeBridge.glmHaikuRequestedModelRawValue
    static let opusRequestedModelRawValue = ClaudeCompatibleProviderRuntimeBridge.glmOpusRequestedModelRawValue
    static let supportedModelRawValues = ClaudeCompatibleProviderRuntimeBridge.glmSupportedModelRawValues

    static func isGLMModel(_ rawModel: String?) -> Bool {
        isGLMModel(rawModel, config: ClaudeCodeCompatibleBackendStore.shared.config(for: .glmZAI))
    }

    static func isGLMModel(
        _ rawModel: String?,
        config: ClaudeCodeCompatibleBackendConfig
    ) -> Bool {
        ClaudeCompatibleProviderRuntimeBridge.isGLMModel(rawModel, config: config)
    }

    static func isConfigured(defaults: UserDefaults = .standard) -> Bool {
        ClaudeCodeCompatibleBackendIntegration.isConfigured(.glmZAI, defaults: defaults)
    }

    @discardableResult
    static func setConfigured(_ isConfigured: Bool, defaults: UserDefaults = .standard) -> Bool {
        ClaudeCodeCompatibleBackendIntegration.setConfigured(isConfigured, for: .glmZAI, defaults: defaults)
    }

    static func environment(apiKey: String) -> [String: String] {
        ClaudeCodeCompatibleBackendIntegration.environment(
            config: ClaudeCodeCompatibleBackendStore.shared.config(for: .glmZAI),
            apiKey: apiKey
        )
    }

    static func normalizedRequestedModel(_ rawModel: String?) -> String? {
        ClaudeCompatibleProviderRuntimeBridge.normalizedRequestedModel(rawModel)
    }

    static func normalizedGLMModel(_ rawModel: String?) -> String? {
        normalizedGLMModel(rawModel, config: ClaudeCodeCompatibleBackendStore.shared.config(for: .glmZAI))
    }

    static func displayName(forRequestedModelRaw rawModel: String?) -> String? {
        option(forRequestedModelRaw: rawModel)?.displayName
    }

    static func description(forRequestedModelRaw rawModel: String?) -> String? {
        option(forRequestedModelRaw: rawModel)?.description
    }

    static func normalizedGLMModel(
        _ rawModel: String?,
        config: ClaudeCodeCompatibleBackendConfig
    ) -> String? {
        ClaudeCompatibleProviderRuntimeBridge.normalizedGLMModel(rawModel, config: config)
    }

    static func normalizedSlotModel(
        _ rawModel: String?,
        config: ClaudeCodeCompatibleBackendConfig
    ) -> String? {
        ClaudeCompatibleProviderRuntimeBridge.normalizedSlotModel(
            rawModel,
            config: config
        )
    }

    private static func option(forRequestedModelRaw rawModel: String?) -> ClaudeCompatiblePluginModelOption? {
        guard let canonical = normalizedGLMModel(rawModel) else { return nil }
        let snapshot = ClaudeCompatibleProviderRuntimeBridge.modelCatalogSnapshot(
            pluginID: .zaiClaudeCode,
            backendConfig: ClaudeCodeCompatibleBackendStore.shared.config(for: .glmZAI),
            includeEffortVariants: false
        )
        return snapshot.options.first {
            $0.rawValue.caseInsensitiveCompare(canonical) == .orderedSame
        }
    }
}

struct ClaudeCodeLaunchEnvironment {
    enum Backend: Equatable {
        case defaultClaude
        case compatible(ClaudeCodeCompatibleBackendID)
    }

    let effectiveModel: String?
    let environmentOverrides: [String: String]
    let removedEnvironmentKeys: Set<String>
    let backend: Backend
    let suppressesEffortSettings: Bool

    init(
        effectiveModel: String?,
        environmentOverrides: [String: String],
        removedEnvironmentKeys: Set<String> = [],
        backend: Backend,
        suppressesEffortSettings: Bool = false
    ) {
        self.effectiveModel = effectiveModel
        self.environmentOverrides = environmentOverrides
        self.removedEnvironmentKeys = removedEnvironmentKeys
        self.backend = backend
        self.suppressesEffortSettings = suppressesEffortSettings
    }
}

protocol ClaudeCodeLaunchEnvironmentResolving: Sendable {
    func resolve(
        variant: ClaudeCodeRuntimeVariant,
        requestedModel: String?
    ) async throws -> ClaudeCodeLaunchEnvironment
}

struct ClaudeCodeLaunchEnvironmentResolver: ClaudeCodeLaunchEnvironmentResolving {
    typealias ZAIKeyProvider = @Sendable () async throws -> String?
    typealias BackendSecretProvider = @Sendable (_ backendID: ClaudeCodeCompatibleBackendID) async throws -> String?

    private let zaiKeyProvider: ZAIKeyProvider
    private let backendSecretProvider: BackendSecretProvider
    private let backendStore: ClaudeCodeCompatibleBackendStore

    init(
        keyManager: KeyManager = KeyManager(),
        backendStore: ClaudeCodeCompatibleBackendStore = .shared
    ) {
        let store = backendStore
        zaiKeyProvider = {
            try await keyManager.getAPIKey(for: .zAI)
        }
        backendSecretProvider = { id in
            try await store.secret(for: id)
        }
        self.backendStore = store
    }

    init(
        zaiKeyProvider: @escaping ZAIKeyProvider,
        backendSecretProvider: BackendSecretProvider? = nil,
        backendStore: ClaudeCodeCompatibleBackendStore = .shared
    ) {
        let store = backendStore
        self.zaiKeyProvider = zaiKeyProvider
        self.backendSecretProvider = backendSecretProvider ?? { id in
            try await store.secret(for: id)
        }
        self.backendStore = store
    }

    func resolve(
        variant: ClaudeCodeRuntimeVariant,
        requestedModel: String?
    ) async throws -> ClaudeCodeLaunchEnvironment {
        try await ClaudeCompatibleProviderRuntimeBridge.resolveLaunchEnvironment(
            variant: variant,
            requestedModel: requestedModel,
            backendConfigProvider: { backendStore.config(for: $0) },
            zaiKeyProvider: zaiKeyProvider,
            backendSecretProvider: backendSecretProvider
        )
    }
}

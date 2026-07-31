import Foundation

public enum ClaudeCompatibleProviderError: Error, Equatable, Sendable {
    case invalidConfiguration(detail: String)
}

extension ClaudeCompatibleProviderError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(detail):
            detail
        }
    }
}

public enum ClaudeCompatibleRuntimeVariant: String, CaseIterable, Codable, Hashable, Sendable {
    case standard
    case glm
    case kimi
    case customCompatible

    public var pluginID: ClaudeCompatibleProviderPluginID {
        switch self {
        case .standard:
            .claudeCode
        case .glm:
            .zaiClaudeCode
        case .kimi:
            .kimiClaudeCode
        case .customCompatible:
            .customClaudeCompatible
        }
    }

    public var compatibleBackendID: ClaudeCompatibleBackendID? {
        switch self {
        case .standard:
            nil
        case .glm:
            .glmZAI
        case .kimi:
            .kimi
        case .customCompatible:
            .custom
        }
    }

    public init(pluginID: ClaudeCompatibleProviderPluginID) {
        switch pluginID {
        case .claudeCode:
            self = .standard
        case .zaiClaudeCode:
            self = .glm
        case .kimiClaudeCode:
            self = .kimi
        case .customClaudeCompatible:
            self = .customCompatible
        }
    }
}

public enum ClaudeCompatiblePromptDeliveryMode: String, CaseIterable, Codable, Hashable, Sendable {
    case userMessageXML
    case userMessageXMLWithEmptySystemPrompt
    case nativeSystemPrompt

    public var sendsRepoPromptAsUserMessage: Bool {
        switch self {
        case .userMessageXML, .userMessageXMLWithEmptySystemPrompt:
            true
        case .nativeSystemPrompt:
            false
        }
    }

    public func nativeSystemPromptOverride(instructions: String) -> String? {
        switch self {
        case .userMessageXML:
            nil
        case .userMessageXMLWithEmptySystemPrompt:
            ""
        case .nativeSystemPrompt:
            instructions
        }
    }
}

public enum ClaudeCompatiblePromptDelivery {
    public static let instructionsTag = "claude_code_instructions"

    public static func decoratedUserMessage(_ userMessage: String, instructions: String) -> String {
        let trimmedInstructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInstructions.isEmpty else {
            return userMessage
        }

        let instructionsBlock = """
        <\(instructionsTag)>
        \(trimmedInstructions)
        </\(instructionsTag)>
        """

        let trimmedUserMessage = userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUserMessage.isEmpty else {
            return instructionsBlock
        }

        return """
        \(instructionsBlock)

        \(userMessage)
        """
    }

    public static func userMessage(
        _ userMessage: String,
        instructions: String,
        mode: ClaudeCompatiblePromptDeliveryMode
    ) -> String {
        mode.sendsRepoPromptAsUserMessage
            ? decoratedUserMessage(userMessage, instructions: instructions)
            : userMessage
    }
}

public extension ClaudeCompatibleBackendAuth {
    var environmentVariableName: String {
        switch self {
        case .anthropicAPIKey:
            "ANTHROPIC_API_KEY"
        case .anthropicAuthToken:
            "ANTHROPIC_AUTH_TOKEN"
        }
    }
}

public extension ClaudeCompatibleBackendID {
    var defaultDisplayName: String {
        switch self {
        case .glmZAI:
            "CC Zai"
        case .kimi:
            "CC Moonshot"
        case .custom:
            "CC Custom"
        }
    }

    var defaultPreset: ClaudeCompatibleBackendConfig {
        switch self {
        case .glmZAI:
            ClaudeCompatibleBackendConfig(
                id: self,
                isEnabled: true,
                displayName: defaultDisplayName,
                baseURL: "https://api.z.ai/api/anthropic",
                auth: .anthropicAuthToken,
                modelBehavior: .claudeSlotMapping(ClaudeCompatibleSlotMapping(
                    haiku: "glm-4.5-air",
                    sonnet: "glm-5.2[1m]",
                    opus: "glm-5.2[1m]"
                ))
            )
        case .kimi:
            ClaudeCompatibleBackendConfig(
                id: self,
                isEnabled: true,
                displayName: defaultDisplayName,
                baseURL: "https://api.kimi.com/coding/",
                auth: .anthropicAPIKey,
                modelBehavior: .noModel
            )
        case .custom:
            ClaudeCompatibleBackendConfig(
                id: self,
                isEnabled: false,
                displayName: defaultDisplayName,
                baseURL: "",
                auth: .anthropicAPIKey,
                modelBehavior: .noModel
            )
        }
    }
}

public extension ClaudeCompatibleSlotMapping {
    var normalized: ClaudeCompatibleSlotMapping {
        ClaudeCompatibleSlotMapping(
            haiku: haiku.trimmingCharacters(in: .whitespacesAndNewlines),
            sonnet: sonnet.trimmingCharacters(in: .whitespacesAndNewlines),
            opus: opus.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    var isValid: Bool {
        let mapping = normalized
        return !mapping.haiku.isEmpty && !mapping.sonnet.isEmpty && !mapping.opus.isEmpty
    }
}

public extension ClaudeCompatibleBackendConfig {
    var normalizedDisplayName: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return id.defaultDisplayName }
        return trimmed
    }

    var normalizedBaseURL: String? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host?.isEmpty == false
        else {
            return nil
        }
        return trimmed
    }

    var normalized: ClaudeCompatibleBackendConfig {
        let normalizedBehavior: ClaudeCompatibleBackendModelBehavior = switch modelBehavior {
        case .noModel:
            .noModel
        case let .claudeSlotMapping(mapping):
            .claudeSlotMapping(mapping.normalized)
        }
        return ClaudeCompatibleBackendConfig(
            id: id,
            isEnabled: isEnabled,
            displayName: normalizedDisplayName,
            baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            auth: auth,
            modelBehavior: normalizedBehavior
        )
    }

    var isValid: Bool {
        guard normalizedBaseURL != nil else { return false }
        switch modelBehavior {
        case .noModel:
            return true
        case let .claudeSlotMapping(mapping):
            return mapping.isValid
        }
    }

    func withSlotOverride(slot: String, backendModelID: String) -> ClaudeCompatibleBackendConfig {
        guard case let .claudeSlotMapping(mapping) = modelBehavior else { return self }
        let normalizedMapping = mapping.normalized
        let overrideBehavior: ClaudeCompatibleBackendModelBehavior
        switch slot.lowercased() {
        case ClaudeCompatibleModelNormalizer.haikuRequestedModelRawValue:
            overrideBehavior = .claudeSlotMapping(ClaudeCompatibleSlotMapping(
                haiku: backendModelID,
                sonnet: normalizedMapping.sonnet,
                opus: normalizedMapping.opus
            ))
        case ClaudeCompatibleModelNormalizer.defaultRequestedModelRawValue:
            overrideBehavior = .claudeSlotMapping(ClaudeCompatibleSlotMapping(
                haiku: normalizedMapping.haiku,
                sonnet: backendModelID,
                opus: normalizedMapping.opus
            ))
        case ClaudeCompatibleModelNormalizer.opusRequestedModelRawValue:
            overrideBehavior = .claudeSlotMapping(ClaudeCompatibleSlotMapping(
                haiku: normalizedMapping.haiku,
                sonnet: normalizedMapping.sonnet,
                opus: backendModelID
            ))
        default:
            return self
        }
        return ClaudeCompatibleBackendConfig(
            id: id,
            isEnabled: isEnabled,
            displayName: displayName,
            baseURL: baseURL,
            auth: auth,
            modelBehavior: overrideBehavior
        )
    }
}

struct ClaudeCompatibleEffortEncodedModel: Equatable {
    private static let knownEffortSuffixes: Set<String> = ["low", "medium", "high", "max", "xhigh", "x-high"]

    let baseModel: String?
    let effortRaw: String?

    init(raw: String?) {
        guard let raw else {
            baseModel = nil
            effortRaw = nil
            return
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            baseModel = nil
            effortRaw = nil
            return
        }

        let lowercased = trimmed.lowercased()
        if let separator = lowercased.lastIndex(of: ":") {
            let suffixStart = lowercased.index(after: separator)
            let suffix = String(lowercased[suffixStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.knownEffortSuffixes.contains(suffix) {
                let base = String(trimmed[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
                baseModel = base.isEmpty || base.lowercased() == ClaudeCompatibleModelNormalizer.defaultSentinelRawValue ? nil : base
                effortRaw = suffix == "x-high" ? "xhigh" : suffix
                return
            }
        }

        baseModel = lowercased == ClaudeCompatibleModelNormalizer.defaultSentinelRawValue ? nil : trimmed
        effortRaw = nil
    }

    var hasEffort: Bool {
        effortRaw != nil
    }
}

public enum ClaudeCompatibleBackendEnvironmentBuilder {
    private static let glmTimeoutMilliseconds = "3000000"
    private static let glmAutoCompactWindow = "1000000"

    public static func removedEnvironmentKeys(config: ClaudeCompatibleBackendConfig) -> Set<String> {
        let normalizedConfig = config.normalized
        let configuredAuthKey = normalizedConfig.auth.environmentVariableName
        var removed = Set(["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"].filter { $0 != configuredAuthKey })
        if case .noModel = normalizedConfig.modelBehavior {
            removed.formUnion([
                "ANTHROPIC_MODEL",
                "ANTHROPIC_DEFAULT_HAIKU_MODEL",
                "ANTHROPIC_DEFAULT_SONNET_MODEL",
                "ANTHROPIC_DEFAULT_OPUS_MODEL",
                "ANTHROPIC_SMALL_FAST_MODEL",
                "CLAUDE_CODE_SUBAGENT_MODEL"
            ])
        }
        return removed
    }

    public static func environment(
        config: ClaudeCompatibleBackendConfig,
        apiKey: String,
        selectedBackendModelID: String? = nil
    ) -> [String: String] {
        let normalizedConfig = config.normalized
        var environment: [String: String] = [
            "ANTHROPIC_BASE_URL": normalizedConfig.normalizedBaseURL ?? normalizedConfig.baseURL,
            normalizedConfig.auth.environmentVariableName: apiKey
        ]
        let normalizedSelectedBackendModelID = selectedBackendModelID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveSlotBackendModelID: String? = if case let .claudeSlotMapping(mapping) = normalizedConfig.modelBehavior {
            if let normalizedSelectedBackendModelID, !normalizedSelectedBackendModelID.isEmpty {
                normalizedSelectedBackendModelID
            } else {
                mapping.normalized.sonnet
            }
        } else {
            nil
        }

        if normalizedConfig.id == .glmZAI {
            environment["API_TIMEOUT_MS"] = glmTimeoutMilliseconds
            if ClaudeCompatibleModelNormalizer.contextWindowTokens(forBackendModelID: effectiveSlotBackendModelID) == 1_000_000 {
                environment["CLAUDE_CODE_AUTO_COMPACT_WINDOW"] = glmAutoCompactWindow
            }
        }

        if case let .claudeSlotMapping(mapping) = normalizedConfig.modelBehavior {
            let normalizedMapping = mapping.normalized
            let defaultBackendModelID = effectiveSlotBackendModelID ?? normalizedMapping.sonnet
            environment["ANTHROPIC_MODEL"] = defaultBackendModelID
            environment["ANTHROPIC_DEFAULT_HAIKU_MODEL"] = normalizedMapping.haiku
            environment["ANTHROPIC_DEFAULT_SONNET_MODEL"] = normalizedMapping.sonnet
            environment["ANTHROPIC_DEFAULT_OPUS_MODEL"] = normalizedMapping.opus
            environment["ANTHROPIC_SMALL_FAST_MODEL"] = normalizedMapping.haiku
            environment["CLAUDE_CODE_SUBAGENT_MODEL"] = normalizedMapping.haiku
        }

        return environment
    }
}

public enum ClaudeCompatibleModelNormalizer {
    public static let defaultModelRawValue = "glm-5.2[1m]"
    public static let haikuEquivalentModelRawValue = "glm-4.5-air"
    public static let opusEquivalentModelRawValue = "glm-5.2[1m]"
    public static let defaultRequestedModelRawValue = "sonnet"
    public static let haikuRequestedModelRawValue = "haiku"
    public static let opusRequestedModelRawValue = "opus"
    public static let defaultSentinelRawValue = "default"
    public static let kimiNoModelRawValue = "kimi-code"
    public static let customNoModelRawValue = "custom-claude-compatible"
    public static let directSelectableGLMModelRawValues: [String] = [
        "glm-4.7",
        "glm-5-turbo",
        "glm-5.1"
    ]

    public static let supportedModelRawValues: [String] = [
        haikuEquivalentModelRawValue,
        "glm-4.7",
        "glm-5.2",
        defaultModelRawValue,
        "glm-5-turbo",
        "glm-5.1"
    ]

    public static func normalizedRequestedModel(_ rawModel: String?) -> String? {
        ClaudeCompatibleEffortEncodedModel(raw: rawModel).baseModel
    }

    public static func isDirectSelectableGLMModel(_ rawModel: String?) -> Bool {
        guard let normalized = normalizedRequestedModel(rawModel)?.lowercased() else { return false }
        return directSelectableGLMModelRawValues.contains(normalized)
    }

    public static func directSelectableGLMSlotRawValue(for rawModel: String?) -> String? {
        guard let normalized = normalizedRequestedModel(rawModel)?.lowercased() else { return nil }
        switch normalized {
        case "glm-4.7":
            return haikuRequestedModelRawValue
        case "glm-5-turbo":
            return defaultRequestedModelRawValue
        case "glm-5.1":
            return opusRequestedModelRawValue
        default:
            return nil
        }
    }

    public static func isGLMModel(
        _ rawModel: String?,
        config: ClaudeCompatibleBackendConfig
    ) -> Bool {
        guard let normalized = normalizedRequestedModel(rawModel)?.lowercased() else { return false }
        if slot(forBackendModelID: normalized, in: slotMapping(from: config)) != nil {
            return true
        }
        return supportedModelRawValues.contains(normalized)
    }

    public static func normalizedGLMModel(
        _ rawModel: String?,
        config: ClaudeCompatibleBackendConfig
    ) -> String? {
        guard let normalized = normalizedRequestedModel(rawModel)?.lowercased() else {
            return defaultRequestedModelRawValue
        }

        let mapping = slotMapping(from: config)
        switch normalized {
        case haikuRequestedModelRawValue:
            return haikuRequestedModelRawValue
        case defaultRequestedModelRawValue:
            return defaultRequestedModelRawValue
        case opusRequestedModelRawValue:
            return opusRequestedModelRawValue
        default:
            break
        }

        if let configuredSlot = slot(forBackendModelID: normalized, in: mapping) {
            return configuredSlot
        }

        switch normalized {
        case haikuEquivalentModelRawValue, "glm-4.7":
            return haikuRequestedModelRawValue
        case "glm-5.2", defaultModelRawValue, "glm-5-turbo":
            return defaultRequestedModelRawValue
        case "glm-5.1":
            return opusRequestedModelRawValue
        default:
            return nil
        }
    }

    public static func normalizedSlotModel(
        _ rawModel: String?,
        config: ClaudeCompatibleBackendConfig
    ) -> String? {
        guard let normalized = normalizedRequestedModel(rawModel)?.lowercased() else {
            return defaultRequestedModelRawValue
        }

        let mapping = slotMapping(from: config)
        switch normalized {
        case haikuRequestedModelRawValue:
            return haikuRequestedModelRawValue
        case defaultRequestedModelRawValue:
            return defaultRequestedModelRawValue
        case opusRequestedModelRawValue:
            return opusRequestedModelRawValue
        default:
            break
        }

        if let configuredSlot = slot(forBackendModelID: normalized, in: mapping) {
            return configuredSlot
        }

        guard config.id == .glmZAI else { return nil }
        switch normalized {
        case haikuEquivalentModelRawValue, "glm-4.7":
            return haikuRequestedModelRawValue
        case "glm-5.2", defaultModelRawValue, "glm-5-turbo":
            return defaultRequestedModelRawValue
        case "glm-5.1":
            return opusRequestedModelRawValue
        default:
            return nil
        }
    }

    public static func supportsXHighEffort(_ rawModel: String?) -> Bool {
        guard let normalized = normalizedRequestedModel(rawModel)?.lowercased() else { return false }
        return normalized == "glm-5.2" || normalized == "glm-5.2[1m]"
    }

    public static func contextWindowTokens(forBackendModelID rawModel: String?) -> Int? {
        guard let normalized = normalizedRequestedModel(rawModel)?.lowercased() else { return nil }
        return normalized == "glm-5.2[1m]" ? 1_000_000 : nil
    }

    public static func noModelRawValue(for backendID: ClaudeCompatibleBackendID) -> String {
        switch backendID {
        case .glmZAI:
            defaultRequestedModelRawValue
        case .kimi:
            kimiNoModelRawValue
        case .custom:
            customNoModelRawValue
        }
    }

    private static func slotMapping(
        from config: ClaudeCompatibleBackendConfig
    ) -> ClaudeCompatibleSlotMapping {
        if case let .claudeSlotMapping(mapping) = config.modelBehavior {
            return mapping.normalized
        }
        if case let .claudeSlotMapping(mapping) = ClaudeCompatibleBackendID.glmZAI.defaultPreset.modelBehavior {
            return mapping.normalized
        }
        return ClaudeCompatibleSlotMapping(
            haiku: haikuEquivalentModelRawValue,
            sonnet: defaultModelRawValue,
            opus: opusEquivalentModelRawValue
        )
    }

    private static func slot(
        forBackendModelID modelID: String,
        in mapping: ClaudeCompatibleSlotMapping
    ) -> String? {
        let normalizedMapping = mapping.normalized
        if modelID == normalizedMapping.haiku.lowercased() {
            return haikuRequestedModelRawValue
        }
        if modelID == normalizedMapping.sonnet.lowercased() {
            return defaultRequestedModelRawValue
        }
        if modelID == normalizedMapping.opus.lowercased() {
            return opusRequestedModelRawValue
        }
        return nil
    }
}

public struct ClaudeCompatibleLaunchEnvironmentResolver: Sendable {
    public typealias BackendConfigProvider = @Sendable (_ backendID: ClaudeCompatibleBackendID) -> ClaudeCompatibleBackendConfig
    public typealias ZAISecretProvider = @Sendable () async throws -> String?
    public typealias BackendSecretProvider = @Sendable (_ backendID: ClaudeCompatibleBackendID) async throws -> String?

    private let backendConfigProvider: BackendConfigProvider
    private let zaiSecretProvider: ZAISecretProvider
    private let backendSecretProvider: BackendSecretProvider

    public init(
        backendConfigProvider: @escaping BackendConfigProvider,
        zaiSecretProvider: @escaping ZAISecretProvider,
        backendSecretProvider: @escaping BackendSecretProvider
    ) {
        self.backendConfigProvider = backendConfigProvider
        self.zaiSecretProvider = zaiSecretProvider
        self.backendSecretProvider = backendSecretProvider
    }

    public func resolve(
        variant: ClaudeCompatibleRuntimeVariant,
        requestedModel: String?,
        requestedEffort: String? = nil
    ) async throws -> ClaudeCompatibleLaunchEnvironment {
        switch variant {
        case .standard:
            let normalizedModel = ClaudeCompatibleModelNormalizer.normalizedRequestedModel(requestedModel)
            let glmConfig = backendConfigProvider(.glmZAI)
            if ClaudeCompatibleModelNormalizer.isGLMModel(normalizedModel, config: glmConfig) {
                throw ClaudeCompatibleProviderError.invalidConfiguration(detail: "GLM models require the Claude Code GLM agent.")
            }
            if isKnownNoModelCompatibleRaw(normalizedModel) {
                throw ClaudeCompatibleProviderError.invalidConfiguration(detail: "Compatible backend models require their matching Claude-compatible agent.")
            }
            return ClaudeCompatibleLaunchEnvironment(
                effectiveModel: normalizedModel,
                environmentOverrides: [:],
                backendID: nil
            )
        case .glm, .kimi, .customCompatible:
            guard let backendID = variant.compatibleBackendID else {
                throw ClaudeCompatibleProviderError.invalidConfiguration(detail: "Unsupported Claude Code runtime variant.")
            }
            return try await resolveCompatibleBackend(
                backendID,
                variant: variant,
                requestedModel: requestedModel,
                requestedEffort: requestedEffort
            )
        }
    }

    private func resolveCompatibleBackend(
        _ backendID: ClaudeCompatibleBackendID,
        variant: ClaudeCompatibleRuntimeVariant,
        requestedModel: String?,
        requestedEffort: String?
    ) async throws -> ClaudeCompatibleLaunchEnvironment {
        let config = backendConfigProvider(backendID).normalized
        guard config.isEnabled, config.isValid else {
            throw ClaudeCompatibleProviderError.invalidConfiguration(detail: "\(config.normalizedDisplayName) has an invalid backend configuration.")
        }

        let requestedSpecifier = ClaudeCompatibleEffortEncodedModel(raw: requestedModel)
        let normalizedRequestedEffort = Self.normalizedEffortRaw(requestedEffort)
        let effectiveEffortRaw = requestedSpecifier.effortRaw ?? normalizedRequestedEffort
        let effectiveModel: String?
        let selectedBackendModelID: String?
        let environmentConfig: ClaudeCompatibleBackendConfig
        switch config.modelBehavior {
        case .noModel:
            guard effectiveEffortRaw == nil,
                  isAllowedNoModelSelection(requestedModel, backendID: backendID)
            else {
                throw ClaudeCompatibleProviderError.invalidConfiguration(detail: "Unsupported \(config.normalizedDisplayName) model selection.")
            }
            effectiveModel = nil
            selectedBackendModelID = nil
            environmentConfig = config
        case .claudeSlotMapping:
            if config.id == .glmZAI,
               let directBackendModelID = requestedSpecifier.baseModel?.lowercased(),
               let directSlot = ClaudeCompatibleModelNormalizer.directSelectableGLMSlotRawValue(for: directBackendModelID)
            {
                if effectiveEffortRaw == "xhigh",
                   !ClaudeCompatibleModelNormalizer.supportsXHighEffort(directBackendModelID)
                {
                    throw ClaudeCompatibleProviderError.invalidConfiguration(detail: "Unsupported \(config.normalizedDisplayName) model selection.")
                }
                effectiveModel = directSlot
                selectedBackendModelID = directBackendModelID
                environmentConfig = config.withSlotOverride(slot: directSlot, backendModelID: directBackendModelID)
                break
            }
            guard let slot = ClaudeCompatibleModelNormalizer.normalizedSlotModel(
                requestedModel,
                config: config
            ),
                let backendModelID = backendModelID(forSlot: slot, config: config)
            else {
                throw ClaudeCompatibleProviderError.invalidConfiguration(detail: "Unsupported \(config.normalizedDisplayName) model selection.")
            }
            if effectiveEffortRaw == "xhigh",
               !ClaudeCompatibleModelNormalizer.supportsXHighEffort(backendModelID)
            {
                throw ClaudeCompatibleProviderError.invalidConfiguration(detail: "Unsupported \(config.normalizedDisplayName) model selection.")
            }
            effectiveModel = slot
            selectedBackendModelID = backendModelID
            environmentConfig = config
        }

        let rawSecret: String? = if backendID == .glmZAI {
            try await zaiSecretProvider()
        } else {
            try await backendSecretProvider(backendID)
        }
        guard let apiKey = rawSecret?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty else {
            throw ClaudeCompatibleProviderError.invalidConfiguration(detail: "\(config.normalizedDisplayName) requires a configured API key.")
        }

        return ClaudeCompatibleLaunchEnvironment(
            effectiveModel: effectiveModel,
            environmentOverrides: ClaudeCompatibleBackendEnvironmentBuilder.environment(
                config: environmentConfig,
                apiKey: apiKey,
                selectedBackendModelID: selectedBackendModelID
            ),
            removedEnvironmentKeys: ClaudeCompatibleBackendEnvironmentBuilder.removedEnvironmentKeys(config: config),
            backendID: backendID,
            suppressesEffortSettings: config.modelBehavior == .noModel
        )
    }

    private static func normalizedEffortRaw(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard !trimmed.isEmpty else { return nil }
        return trimmed == "x-high" ? "xhigh" : trimmed
    }

    private func backendModelID(forSlot slot: String, config: ClaudeCompatibleBackendConfig) -> String? {
        guard case let .claudeSlotMapping(mapping) = config.modelBehavior else { return nil }
        let normalizedMapping = mapping.normalized
        switch slot.lowercased() {
        case ClaudeCompatibleModelNormalizer.haikuRequestedModelRawValue:
            return normalizedMapping.haiku
        case ClaudeCompatibleModelNormalizer.defaultRequestedModelRawValue:
            return normalizedMapping.sonnet
        case ClaudeCompatibleModelNormalizer.opusRequestedModelRawValue:
            return normalizedMapping.opus
        default:
            return nil
        }
    }

    private func isAllowedNoModelSelection(
        _ rawModel: String?,
        backendID: ClaudeCompatibleBackendID
    ) -> Bool {
        guard let normalized = ClaudeCompatibleModelNormalizer.normalizedRequestedModel(rawModel)?.lowercased() else {
            return true
        }
        return normalized == ClaudeCompatibleModelNormalizer.noModelRawValue(for: backendID)
    }

    private func isKnownNoModelCompatibleRaw(_ rawModel: String?) -> Bool {
        guard let normalized = ClaudeCompatibleModelNormalizer.normalizedRequestedModel(rawModel)?.lowercased() else {
            return false
        }
        return normalized == ClaudeCompatibleModelNormalizer.noModelRawValue(for: .kimi)
            || normalized == ClaudeCompatibleModelNormalizer.noModelRawValue(for: .custom)
    }
}

public struct ClaudeCompatibleHeadlessArgumentsRequest: Codable, Hashable, Sendable {
    public let runtimeConfig: ClaudeCompatibleRuntimeConfig
    public let mcpConfigPath: String?
    public let launchEnvironment: ClaudeCompatibleLaunchEnvironment?
    public let resumeSessionID: String?
    public let systemPromptOverride: String?

    public init(
        runtimeConfig: ClaudeCompatibleRuntimeConfig,
        mcpConfigPath: String?,
        launchEnvironment: ClaudeCompatibleLaunchEnvironment?,
        resumeSessionID: String? = nil,
        systemPromptOverride: String? = nil
    ) {
        self.runtimeConfig = runtimeConfig
        self.mcpConfigPath = mcpConfigPath
        self.launchEnvironment = launchEnvironment
        self.resumeSessionID = resumeSessionID
        self.systemPromptOverride = systemPromptOverride
    }
}

public enum ClaudeCompatibleHeadlessRuntime {
    public static func buildArguments(_ request: ClaudeCompatibleHeadlessArgumentsRequest) -> [String] {
        var args: [String] = [
            "-p",
            "--verbose",
            "--output-format", "stream-json"
        ]

        if let sessionID = request.resumeSessionID {
            args.append(contentsOf: ["--resume", sessionID])
        }
        if request.runtimeConfig.pluginID != .claudeCode {
            args.append("--bare")
            args.append(contentsOf: ["--setting-sources", "project,local"])
        }
        if let model = runtimeModelParam(request.launchEnvironment?.effectiveModel) {
            args.append(contentsOf: ["--model", model])
        }
        if let systemPromptOverride = request.systemPromptOverride {
            args.append(contentsOf: ["--system-prompt", systemPromptOverride])
        }

        args.append("--dangerously-skip-permissions")

        if let mcpConfigPath = request.mcpConfigPath {
            args.append(contentsOf: ["--mcp-config", mcpConfigPath])
            if request.runtimeConfig.mcpStrictMode {
                args.append("--strict-mcp-config")
            }
        }

        if !request.runtimeConfig.disallowedBuiltInTools.isEmpty {
            args.append(contentsOf: ["--disallowedTools", request.runtimeConfig.disallowedBuiltInTools.joined(separator: ",")])
        }

        return args
    }

    public static func runtimeModelParam(_ raw: String?) -> String? {
        ClaudeCompatibleModelNormalizer.normalizedRequestedModel(raw)
    }
}

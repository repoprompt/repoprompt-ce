import Foundation
import RepoPromptServiceProtocol

/// Desktop-shaped Claude-compatible launch consume.
///
/// Mirrors Desktop `ClaudeCompatibleLaunchEnvironmentResolver` /
/// `ClaudeCompatibleBackendEnvironmentBuilder`: live-read typed backend config +
/// secret, build `ANTHROPIC_BASE_URL` / key-or-token / slot env, map the
/// requested model through the slot table (or drop `--model` for `noModel`),
/// suppress effort when Desktop does, and strip the unused auth key.
/// Custom `isEnabled == false` and a missing secret fail-close.
///
/// Desktop's connected latch is UserDefaults
/// `ClaudeCodeCompatibleBackendConfigured.<id>` (set when a Keychain secret is
/// saved). Linux does **not** invent that latch. Launch still requires the
/// server readiness predicate `connection.state == connected && testState ==
/// valid` (see `VaultProviderProcessEnvironment`). Server-owned / dedicated
/// accounts, isolated HOME, and vault injection stay additive.
public struct ClaudeCompatibleLaunchResolution: Equatable, Sendable {
    public let effectiveModel: String?
    public let environmentOverrides: [String: String]
    public let removedEnvironmentKeys: Set<String>
    public let suppressesEffortSettings: Bool

    public init(
        effectiveModel: String?,
        environmentOverrides: [String: String],
        removedEnvironmentKeys: Set<String>,
        suppressesEffortSettings: Bool
    ) {
        self.effectiveModel = effectiveModel
        self.environmentOverrides = environmentOverrides
        self.removedEnvironmentKeys = removedEnvironmentKeys
        self.suppressesEffortSettings = suppressesEffortSettings
    }

    public func applying(to environment: [String: String]) -> [String: String] {
        var merged = environment
        merged.merge(environmentOverrides) { _, override in override }
        for key in removedEnvironmentKeys {
            merged.removeValue(forKey: key)
        }
        return merged
    }
}

public enum ClaudeCompatibleLaunchResolver {
    private static let glmTimeoutMilliseconds = "3000000"
    private static let glmAutoCompactWindow = "1000000"
    private static let knownEffortSuffixes: Set<String> = ["low", "medium", "high", "max", "xhigh", "x-high"]
    private static let defaultRequestedModel = "sonnet"
    private static let haikuRequestedModel = "haiku"
    private static let opusRequestedModel = "opus"
    private static let directSelectableGLMModels = ["glm-4.7", "glm-5-turbo", "glm-5.1"]

    public static func resolve(
        settings: ClaudeCompatibleBackendSettings,
        secret: String,
        requestedModel: String?
    ) throws -> ClaudeCompatibleLaunchResolution {
        let normalized = normalize(settings)
        guard normalized.isEnabled, isValid(normalized) else {
            throw ServiceAPIError(
                code: .providerUnavailable,
                message: "\(normalized.displayName) has an invalid backend configuration."
            )
        }
        let model = try resolvedModel(settings: normalized, requestedModel: requestedModel)
        let apiKey = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw ServiceAPIError(
                code: .providerUnavailable,
                message: "\(normalized.displayName) requires a configured API key."
            )
        }
        return ClaudeCompatibleLaunchResolution(
            effectiveModel: model.effectiveModel,
            environmentOverrides: environment(
                settings: model.environmentSettings,
                apiKey: apiKey,
                selectedBackendModelID: model.selectedBackendModelID
            ),
            removedEnvironmentKeys: removedEnvironmentKeys(for: normalized),
            suppressesEffortSettings: normalized.modelBehavior == .noModel
        )
    }

    public static func resolveModel(
        settings: ClaudeCompatibleBackendSettings,
        requestedModel: String?
    ) throws -> String? {
        let normalized = normalize(settings)
        guard normalized.isEnabled, isValid(normalized) else {
            throw ServiceAPIError(
                code: .providerUnavailable,
                message: "\(normalized.displayName) has an invalid backend configuration."
            )
        }
        return try resolvedModel(settings: normalized, requestedModel: requestedModel).effectiveModel
    }

    public static func backendSettings(from providerSettings: [String: String]) -> ClaudeCompatibleBackendSettings? {
        guard let rawID = providerSettings["claude.backendID"],
              let providerID = ProviderSettingsID(rawValue: rawID),
              [.claudeGLM, .claudeKimi, .claudeCustom].contains(providerID)
        else { return nil }
        let auth = ClaudeCompatibleBackendAuthHeader(rawValue: providerSettings["claude.backendAuthHeader"] ?? "")
            ?? .anthropicAPIKey
        let behavior = ClaudeCompatibleBackendModelBehavior(rawValue: providerSettings["claude.backendModelBehavior"] ?? "")
            ?? (providerID == .claudeGLM ? .claudeSlotMapping : .noModel)
        return ClaudeCompatibleBackendSettings(
            providerID: providerID,
            isEnabled: true,
            displayName: providerSettings["claude.backendDisplayName"] ?? providerID.rawValue,
            baseURL: providerSettings["claude.backendBaseURL"] ?? "",
            authHeader: auth,
            modelBehavior: behavior,
            haikuModel: providerSettings["claude.backendHaikuModel"] ?? "",
            sonnetModel: providerSettings["claude.backendSonnetModel"] ?? "",
            opusModel: providerSettings["claude.backendOpusModel"] ?? ""
        )
    }

    public static func shouldApplyEffort(providerSettings: [String: String]) -> Bool {
        providerSettings["claude.backendModelBehavior"] != ClaudeCompatibleBackendModelBehavior.noModel.rawValue
    }

    public static func removedEnvironmentKeys(for settings: ClaudeCompatibleBackendSettings) -> Set<String> {
        let configured = settings.authHeader.environmentVariableName
        return Set(["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"].filter { $0 != configured })
    }

    private struct ResolvedModel {
        let effectiveModel: String?
        let selectedBackendModelID: String?
        let environmentSettings: ClaudeCompatibleBackendSettings
    }

    private static func resolvedModel(
        settings: ClaudeCompatibleBackendSettings,
        requestedModel: String?
    ) throws -> ResolvedModel {
        let specifier = EffortEncodedModel(raw: requestedModel)
        switch settings.modelBehavior {
        case .noModel:
            guard !specifier.hasEffort, isAllowedNoModelSelection(requestedModel, providerID: settings.providerID) else {
                throw ServiceAPIError(
                    code: .providerUnavailable,
                    message: "Unsupported \(settings.displayName) model selection."
                )
            }
            return ResolvedModel(effectiveModel: nil, selectedBackendModelID: nil, environmentSettings: settings)
        case .claudeSlotMapping:
            if settings.providerID == .claudeGLM,
               let directBackendModelID = specifier.baseModel?.lowercased(),
               let directSlot = directSelectableGLMSlot(for: directBackendModelID)
            {
                if specifier.effortRaw == "xhigh", !supportsXHighEffort(directBackendModelID) {
                    throw ServiceAPIError(
                        code: .providerUnavailable,
                        message: "Unsupported \(settings.displayName) model selection."
                    )
                }
                return ResolvedModel(
                    effectiveModel: directSlot,
                    selectedBackendModelID: directBackendModelID,
                    environmentSettings: withSlotOverride(settings, slot: directSlot, backendModelID: directBackendModelID)
                )
            }
            guard let slot = normalizedSlotModel(requestedModel, settings: settings),
                  let backendModelID = backendModelID(forSlot: slot, settings: settings)
            else {
                throw ServiceAPIError(
                    code: .providerUnavailable,
                    message: "Unsupported \(settings.displayName) model selection."
                )
            }
            if specifier.effortRaw == "xhigh", !supportsXHighEffort(backendModelID) {
                throw ServiceAPIError(
                    code: .providerUnavailable,
                    message: "Unsupported \(settings.displayName) model selection."
                )
            }
            return ResolvedModel(effectiveModel: slot, selectedBackendModelID: backendModelID, environmentSettings: settings)
        }
    }

    private static func environment(
        settings: ClaudeCompatibleBackendSettings,
        apiKey: String,
        selectedBackendModelID: String?
    ) -> [String: String] {
        var environment: [String: String] = [
            "ANTHROPIC_BASE_URL": normalizedBaseURL(settings.baseURL) ?? settings.baseURL,
            settings.authHeader.environmentVariableName: apiKey
        ]
        if settings.providerID == .claudeGLM {
            environment["API_TIMEOUT_MS"] = glmTimeoutMilliseconds
            if contextWindowTokens(forBackendModelID: selectedBackendModelID) == 1_000_000 {
                environment["CLAUDE_CODE_AUTO_COMPACT_WINDOW"] = glmAutoCompactWindow
            }
        }
        if settings.modelBehavior == .claudeSlotMapping {
            environment["ANTHROPIC_DEFAULT_HAIKU_MODEL"] = settings.haikuModel.trimmingCharacters(in: .whitespacesAndNewlines)
            environment["ANTHROPIC_DEFAULT_SONNET_MODEL"] = settings.sonnetModel.trimmingCharacters(in: .whitespacesAndNewlines)
            environment["ANTHROPIC_DEFAULT_OPUS_MODEL"] = settings.opusModel.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return environment
    }

    private static func normalize(_ settings: ClaudeCompatibleBackendSettings) -> ClaudeCompatibleBackendSettings {
        ClaudeCompatibleBackendSettings(
            providerID: settings.providerID,
            isEnabled: settings.isEnabled,
            displayName: {
                let trimmed = settings.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? settings.providerID.rawValue : trimmed
            }(),
            baseURL: settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            authHeader: settings.authHeader,
            modelBehavior: settings.modelBehavior,
            haikuModel: settings.haikuModel.trimmingCharacters(in: .whitespacesAndNewlines),
            sonnetModel: settings.sonnetModel.trimmingCharacters(in: .whitespacesAndNewlines),
            opusModel: settings.opusModel.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func isValid(_ settings: ClaudeCompatibleBackendSettings) -> Bool {
        guard normalizedBaseURL(settings.baseURL) != nil else { return false }
        switch settings.modelBehavior {
        case .noModel:
            return true
        case .claudeSlotMapping:
            return !settings.haikuModel.isEmpty && !settings.sonnetModel.isEmpty && !settings.opusModel.isEmpty
        }
    }

    private static func normalizedBaseURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host?.isEmpty == false
        else { return nil }
        return trimmed
    }

    private static func normalizedRequestedModel(_ rawModel: String?) -> String? {
        EffortEncodedModel(raw: rawModel).baseModel
    }

    private static func normalizedSlotModel(
        _ rawModel: String?,
        settings: ClaudeCompatibleBackendSettings
    ) -> String? {
        guard let normalized = normalizedRequestedModel(rawModel)?.lowercased() else {
            return defaultRequestedModel
        }
        switch normalized {
        case haikuRequestedModel, defaultRequestedModel, opusRequestedModel:
            return normalized
        default:
            break
        }
        if let configured = slot(forBackendModelID: normalized, settings: settings) {
            return configured
        }
        switch normalized {
        case "glm-4.5-air", "glm-4.7":
            return haikuRequestedModel
        case "glm-5.2", "glm-5.2[1m]", "glm-5-turbo":
            return defaultRequestedModel
        case "glm-5.1":
            return opusRequestedModel
        default:
            return nil
        }
    }

    private static func slot(
        forBackendModelID modelID: String,
        settings: ClaudeCompatibleBackendSettings
    ) -> String? {
        if modelID == settings.haikuModel.lowercased() { return haikuRequestedModel }
        if modelID == settings.sonnetModel.lowercased() { return defaultRequestedModel }
        if modelID == settings.opusModel.lowercased() { return opusRequestedModel }
        return nil
    }

    private static func backendModelID(forSlot slot: String, settings: ClaudeCompatibleBackendSettings) -> String? {
        switch slot.lowercased() {
        case haikuRequestedModel: settings.haikuModel
        case defaultRequestedModel: settings.sonnetModel
        case opusRequestedModel: settings.opusModel
        default: nil
        }
    }

    private static func directSelectableGLMSlot(for rawModel: String) -> String? {
        switch rawModel.lowercased() {
        case "glm-4.7": haikuRequestedModel
        case "glm-5-turbo": defaultRequestedModel
        case "glm-5.1": opusRequestedModel
        default: nil
        }
    }

    private static func withSlotOverride(
        _ settings: ClaudeCompatibleBackendSettings,
        slot: String,
        backendModelID: String
    ) -> ClaudeCompatibleBackendSettings {
        switch slot.lowercased() {
        case haikuRequestedModel:
            return ClaudeCompatibleBackendSettings(
                providerID: settings.providerID,
                isEnabled: settings.isEnabled,
                displayName: settings.displayName,
                baseURL: settings.baseURL,
                authHeader: settings.authHeader,
                modelBehavior: settings.modelBehavior,
                haikuModel: backendModelID,
                sonnetModel: settings.sonnetModel,
                opusModel: settings.opusModel
            )
        case defaultRequestedModel:
            return ClaudeCompatibleBackendSettings(
                providerID: settings.providerID,
                isEnabled: settings.isEnabled,
                displayName: settings.displayName,
                baseURL: settings.baseURL,
                authHeader: settings.authHeader,
                modelBehavior: settings.modelBehavior,
                haikuModel: settings.haikuModel,
                sonnetModel: backendModelID,
                opusModel: settings.opusModel
            )
        case opusRequestedModel:
            return ClaudeCompatibleBackendSettings(
                providerID: settings.providerID,
                isEnabled: settings.isEnabled,
                displayName: settings.displayName,
                baseURL: settings.baseURL,
                authHeader: settings.authHeader,
                modelBehavior: settings.modelBehavior,
                haikuModel: settings.haikuModel,
                sonnetModel: settings.sonnetModel,
                opusModel: backendModelID
            )
        default:
            return settings
        }
    }

    private static func supportsXHighEffort(_ rawModel: String?) -> Bool {
        guard let normalized = normalizedRequestedModel(rawModel)?.lowercased() else { return false }
        return normalized == "glm-5.2" || normalized == "glm-5.2[1m]"
    }

    private static func contextWindowTokens(forBackendModelID rawModel: String?) -> Int? {
        guard let normalized = normalizedRequestedModel(rawModel)?.lowercased() else { return nil }
        return normalized == "glm-5.2[1m]" ? 1_000_000 : nil
    }

    private static func isAllowedNoModelSelection(_ rawModel: String?, providerID: ProviderSettingsID) -> Bool {
        guard let normalized = normalizedRequestedModel(rawModel)?.lowercased() else { return true }
        return normalized == noModelRawValue(for: providerID)
    }

    private static func noModelRawValue(for providerID: ProviderSettingsID) -> String {
        switch providerID {
        case .claudeKimi: "kimi-code"
        case .claudeCustom: "custom-claude-compatible"
        default: defaultRequestedModel
        }
    }

    private struct EffortEncodedModel {
        let baseModel: String?
        let effortRaw: String?

        var hasEffort: Bool { effortRaw != nil }

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
                if ClaudeCompatibleLaunchResolver.knownEffortSuffixes.contains(suffix) {
                    let base = String(trimmed[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
                    baseModel = base.isEmpty || base.lowercased() == "default" ? nil : base
                    effortRaw = suffix == "x-high" ? "xhigh" : suffix
                    return
                }
            }
            baseModel = lowercased == "default" ? nil : trimmed
            effortRaw = nil
        }
    }
}

import Foundation

enum ClaudeCodeCompatibleBackendID: String, CaseIterable, Codable, Hashable {
    case glmZAI
    case kimi
    case custom

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

    var secureStorageAccount: SecureStorageAccount {
        switch self {
        case .glmZAI:
            .zAIAPI
        case .kimi:
            .claudeCompatibleKimiAPIKey
        case .custom:
            .claudeCompatibleCustomAPIKey
        }
    }

    var defaultPreset: ClaudeCodeCompatibleBackendConfig {
        switch self {
        case .glmZAI:
            ClaudeCodeCompatibleBackendConfig(
                id: self,
                isEnabled: true,
                displayName: defaultDisplayName,
                baseURL: "https://api.z.ai/api/anthropic",
                auth: .anthropicAuthToken,
                modelBehavior: .claudeSlotMapping(
                    ClaudeCodeCompatibleBackendConfig.ClaudeSlotMapping(
                        haiku: "glm-4.7",
                        sonnet: "glm-5-turbo",
                        opus: "glm-5.1"
                    )
                )
            )
        case .kimi:
            ClaudeCodeCompatibleBackendConfig(
                id: self,
                isEnabled: true,
                displayName: defaultDisplayName,
                baseURL: "https://api.kimi.com/coding/",
                auth: .anthropicAPIKey,
                modelBehavior: .noModel
            )
        case .custom:
            ClaudeCodeCompatibleBackendConfig(
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

struct ClaudeCodeCompatibleBackendConfig: Codable, Equatable {
    enum Auth: Codable, Equatable {
        case anthropicAPIKey
        case anthropicAuthToken

        var environmentVariableName: String {
            switch self {
            case .anthropicAPIKey:
                "ANTHROPIC_API_KEY"
            case .anthropicAuthToken:
                "ANTHROPIC_AUTH_TOKEN"
            }
        }
    }

    enum ModelBehavior: Codable, Equatable {
        case noModel
        case claudeSlotMapping(ClaudeSlotMapping)
    }

    struct ClaudeSlotMapping: Codable, Equatable {
        var haiku: String
        var sonnet: String
        var opus: String

        var normalized: ClaudeSlotMapping {
            ClaudeSlotMapping(
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

    var id: ClaudeCodeCompatibleBackendID
    var isEnabled: Bool
    var displayName: String
    var baseURL: String
    var auth: Auth
    var modelBehavior: ModelBehavior
    var updatedAt: Date?

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

    var normalized: ClaudeCodeCompatibleBackendConfig {
        var copy = self
        copy.displayName = normalizedDisplayName
        copy.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if case let .claudeSlotMapping(mapping) = modelBehavior {
            copy.modelBehavior = .claudeSlotMapping(mapping.normalized)
        }
        return copy
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
}

import Foundation
import RepoPromptAuthorityAPI
import RepoPromptRuntimeModel

public struct DirectProviderRuntimeDefaults: Sendable, Equatable {
    public let mode: String
    public let providerSettings: [String: String]

    public init(mode: String, providerSettings: [String: String]) {
        self.mode = mode
        self.providerSettings = providerSettings
    }
}

public protocol DirectProviderRuntimeDefaultsProviding: Sendable {
    func directProviderRuntimeDefaults(for providerID: ProviderSettingsID) async throws -> DirectProviderRuntimeDefaults
}

public struct ResolvedSubagentPermission: Sendable, Equatable {
    public let mode: String
    public let providerSettings: [String: String]
    public let policy: SubagentPermissionPolicy
    public let settingsRevision: Int64

    public init(
        mode: String,
        providerSettings: [String: String],
        policy: SubagentPermissionPolicy,
        settingsRevision: Int64
    ) {
        self.mode = mode
        self.providerSettings = providerSettings
        self.policy = policy
        self.settingsRevision = settingsRevision
    }
}

public struct SubagentPermissionResolver: Sendable {
    private static let identityKeys: Set<String> = [
        "provider.settingsID",
        "provider.reasoningEffort",
        "provider.serviceTier",
        "claude.backendID",
        "claude.backendBaseURL",
        "claude.backendAuthHeader",
        "claude.backendModelBehavior",
        "claude.backendHaikuModel",
        "claude.backendSonnetModel",
        "claude.backendOpusModel"
    ]

    private let settings: ServerSettingsService?
    private let directDefaults: (any DirectProviderRuntimeDefaultsProviding)?

    public init(
        settings: ServerSettingsService?,
        directDefaults: (any DirectProviderRuntimeDefaultsProviding)?
    ) {
        self.settings = settings
        self.directDefaults = directDefaults
    }

    public func resolve(providerID: ProviderSettingsID) async -> ResolvedSubagentPermission {
        let snapshot = await settings?.subagentPermissions()
            ?? SubagentPermissionSettingsSnapshot(
                settings: .safeManaged,
                revision: 0,
                updatedAt: Date(timeIntervalSince1970: 0)
            )
        let inherited = await liveDirectAgents(for: providerID)
        let resolved: DirectProviderRuntimeDefaults = switch snapshot.settings.policy {
        case .safeManaged:
            safeManaged(providerID: providerID, identity: inherited)
        case .inheritProviderSettings:
            inherited ?? Self.directAgentDefaults(for: providerID)
        case .custom:
            customDefaults(providerID: providerID, settings: snapshot.settings, inherited: inherited)
        }
        var providerSettings = resolved.providerSettings
        providerSettings["provider.settingsID"] = providerID.rawValue
        providerSettings["subagent.permissionPolicy"] = snapshot.settings.policy.rawValue
        providerSettings["subagent.permissionSettingsRevision"] = String(snapshot.revision)
        return .init(
            mode: resolved.mode,
            providerSettings: providerSettings,
            policy: snapshot.settings.policy,
            settingsRevision: snapshot.revision
        )
    }

    private func liveDirectAgents(for providerID: ProviderSettingsID) async -> DirectProviderRuntimeDefaults? {
        guard let directDefaults else { return nil }
        return try? await directDefaults.directProviderRuntimeDefaults(for: providerID)
    }

    private func safeManaged(
        providerID: ProviderSettingsID,
        identity: DirectProviderRuntimeDefaults?
    ) -> DirectProviderRuntimeDefaults {
        let sealed = Self.sealedSafeManaged(for: providerID)
        return .init(
            mode: sealed.mode,
            providerSettings: Self.merge(keys: Self.identityKeys, from: identity?.providerSettings, into: sealed.providerSettings)
        )
    }

    private func customDefaults(
        providerID: ProviderSettingsID,
        settings: SubagentPermissionSettings,
        inherited: DirectProviderRuntimeDefaults?
    ) -> DirectProviderRuntimeDefaults {
        let base = inherited ?? Self.directAgentDefaults(for: providerID)
        let overlay = Self.customLevelProjection(providerID: providerID, settings: settings)
        var values = base.providerSettings
        for (key, value) in overlay.providerSettings {
            values[key] = value
        }
        return .init(mode: overlay.mode, providerSettings: values)
    }

    private static func sealedSafeManaged(for providerID: ProviderSettingsID) -> DirectProviderRuntimeDefaults {
        switch providerID {
        case .codex:
            var settings = DirectAgentPermissionsSettings(
                codex: .from(permissionLevel: "autoReview", bashEnabled: true)
            ).projection(for: .codex).providerSettings
            settings["codex.enabledMCPServers"] = "[]"
            return .init(mode: "workspaceWrite", providerSettings: settings)
        case .claudeCompatible, .claudeGLM, .claudeKimi, .claudeCustom:
            return DirectAgentPermissionsSettings(
                claude: .init(permissionMode: .requireApproval, bashEnabled: false, mcpStrictModeEnabled: true)
            ).projection(for: providerID).asRuntimeDefaults
        case .openCodeACP, .cursorACP, .grokBuildACP, .openAIAPI, .anthropicAPI, .openRouter, .customOpenAICompatible,
             .gemini, .azure, .deepseek, .fireworks, .xAI, .groq, .zAI, .ollama:
            return DirectAgentPermissionsSettings.default.projection(for: providerID).asRuntimeDefaults
        }
    }

    private static func customLevelProjection(
        providerID: ProviderSettingsID,
        settings: SubagentPermissionSettings
    ) -> DirectProviderRuntimeDefaults {
        switch providerID {
        case .codex:
            let projected = DirectAgentPermissionsSettings(
                codex: .from(permissionLevel: settings.codex.rawValue)
            ).projection(for: .codex)
            var values = projected.providerSettings
            values.removeValue(forKey: "codex.bashEnabled")
            return .init(mode: projected.mode, providerSettings: values)
        case .claudeCompatible, .claudeGLM, .claudeKimi, .claudeCustom:
            let projected = DirectAgentPermissionsSettings(
                claude: .from(permissionLevel: settings.claude.rawValue)
            ).projection(for: providerID)
            var values = projected.providerSettings
            values.removeValue(forKey: "claude.bashEnabled")
            values.removeValue(forKey: "claude.strictMCPEnabled")
            return .init(mode: projected.mode, providerSettings: values)
        case .openCodeACP:
            return DirectAgentPermissionsSettings(
                openCode: .init(permissionLevel: settings.openCode == .fullAccess ? .fullAccess : .managedDefault)
            ).projection(for: .openCodeACP).asRuntimeDefaults
        case .cursorACP:
            return DirectAgentPermissionsSettings(
                cursor: .init(permissionLevel: settings.cursor == .fullAccess ? .fullAccess : .managedDefault)
            ).projection(for: .cursorACP).asRuntimeDefaults
        case .grokBuildACP:
            return DirectAgentPermissionsSettings(
                grokBuild: .init(permissionLevel: settings.grokBuild == .fullAccess ? .fullAccess : .managedDefault)
            ).projection(for: .grokBuildACP).asRuntimeDefaults
        case .openAIAPI, .anthropicAPI, .openRouter, .customOpenAICompatible,
             .gemini, .azure, .deepseek, .fireworks, .xAI, .groq, .zAI, .ollama:
            return DirectAgentPermissionsSettings.default.projection(for: providerID).asRuntimeDefaults
        }
    }

    private static func directAgentDefaults(for providerID: ProviderSettingsID) -> DirectProviderRuntimeDefaults {
        DirectAgentPermissionsSettings.default.projection(for: providerID).asRuntimeDefaults
    }

    private static func merge(
        keys: Set<String>,
        from source: [String: String]?,
        into destination: [String: String]
    ) -> [String: String] {
        var values = destination
        guard let source else { return values }
        for key in keys {
            if let value = source[key] {
                values[key] = value
            }
        }
        return values
    }
}

private extension DirectAgentRuntimeProjection {
    var asRuntimeDefaults: DirectProviderRuntimeDefaults {
        .init(mode: mode, providerSettings: providerSettings)
    }
}

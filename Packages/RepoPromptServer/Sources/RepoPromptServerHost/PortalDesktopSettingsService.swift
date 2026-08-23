import Foundation
import RepoPromptAgentRuntimeCore
import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import RepoPromptServerOperations
import RepoPromptHeadlessRuntime

public actor PortalDesktopSettingsService: ClaudeCompatibleBackendSettingsProviding, DirectProviderRuntimeDefaultsProviding {
    public struct RuntimeDefaults: Sendable, Equatable {
        public let mode: String
        public let providerSettings: [String: String]
    }

    private let store: SQLiteServiceStore

    public init(store: SQLiteServiceStore) {
        self.store = store
    }

    public func snapshot() async throws -> PortalDesktopSettingsSnapshot {
        let stored = try await store.portalDesktopSettings().map(Self.wireSnapshot)
        return try PortalDesktopSettingsSnapshot.liveRead(stored: stored)
    }

    public func update(_ request: UpdatePortalDesktopSettingsRequest) async throws -> PortalDesktopSettingsSnapshot {
        let current = try await snapshot()
        let updated = try current.applying(request)
        let record = OperatorDesktopSettingsRecord(
            schemaVersion: updated.schemaVersion,
            revision: updated.revision,
            values: updated.values,
            updatedAt: updated.updatedAt
        )
        return Self.wireSnapshot(try await store.upsertPortalDesktopSettings(record, expectedRevision: current.revision))
    }

    private nonisolated static func wireSnapshot(_ record: OperatorDesktopSettingsRecord) -> PortalDesktopSettingsSnapshot {
        .init(
            schemaVersion: record.schemaVersion,
            revision: record.revision,
            values: record.values,
            updatedAt: record.updatedAt
        )
    }

    /// Projects persisted portal defaults into concrete composer controls. The
    /// browser receives the effective choice instead of inventing a separate
    /// "Default" permission with no execution meaning of its own.
    public func composerCatalogProfile(for providerID: ProviderSettingsID) async throws -> AgentCatalogProviderProfile {
        let values = try await snapshot().values
        var toolValues: [String: AgentControlValue] = [:]
        let permissionID: String?

        let typed = await liveDirectAgentPermissions(values: values)
        switch providerID {
        case .codex:
            toolValues = [
                "codex.bash": .boolean(typed.codex.bashEnabled),
                "codex.search": .boolean(Self.boolean(.codexSearchEnabled, values: values)),
                "codex.goals": .boolean(Self.boolean(.codexGoalsEnabled, values: values)),
                "codex.reasoningSummaries": .boolean(Self.boolean(.codexReasoningSummariesEnabled, values: values)),
                "codex.memories": .boolean(Self.boolean(.codexMemoriesEnabled, values: values)),
                "codex.mcpServers": .choices(["repoprompt"])
            ]
            permissionID = "codex.\(typed.codex.permissionLevel)"
        case .claudeCompatible, .claudeGLM, .claudeKimi, .claudeCustom:
            toolValues = [
                "claude.bash": .boolean(typed.claude.bashEnabled),
                "claude.mcpStrictMode": .boolean(typed.claude.mcpStrictModeEnabled),
                "claude.toolSearch": .boolean(Self.boolean(.claudeToolSearchEnabled, values: values)),
                "claude.promptDelivery": .choice(typed.claude.promptDelivery.rawValue)
            ]
            permissionID = "claude.\(typed.claude.permissionLevel)"
        case .openCodeACP:
            permissionID = typed.openCode.permissionLevel == .fullAccess
                ? "opencode.fullAccess"
                : "opencode.managedDefault"
        case .cursorACP:
            permissionID = typed.cursor.permissionLevel == .fullAccess
                ? "cursor.fullAccess"
                : "cursor.managedDefault"
        case .grokBuildACP:
            permissionID = typed.grokBuild.permissionLevel == .fullAccess
                ? "grok.fullAccess"
                : "grok.managedDefault"
        case .openAIAPI, .anthropicAPI, .openRouter, .customOpenAICompatible,
             .gemini, .azure, .deepseek, .fireworks, .xAI, .groq, .zAI, .ollama:
            permissionID = nil
        }

        return .init(
            toolControls: ProviderComposerStableControls.descriptors(
                providerID: providerID,
                values: toolValues,
                mutable: true,
                lockReasonCode: nil
            ),
            permissionControl: ProviderComposerStableControls.permissionDescriptor(
                providerID: providerID,
                selectedID: permissionID,
                mutable: true,
                lockReasonCode: nil
            )
        )
    }

    public func directProviderRuntimeDefaults(for providerID: ProviderSettingsID) async throws -> DirectProviderRuntimeDefaults {
        let defaults = try await runtimeDefaults(for: providerID)
        return .init(mode: defaults.mode, providerSettings: defaults.providerSettings)
    }

    public func runtimeDefaults(for providerID: ProviderSettingsID) async throws -> RuntimeDefaults {
        let values = try await snapshot().values
        let typed = await liveDirectAgentPermissions(values: values)
        let projection = typed.projection(for: providerID)
        let fallbackMode = values[PortalDesktopSettingKey.serverDefaultExecutionMode.rawValue] ?? "workspaceWrite"
        guard providerID.hasTypedDirectAgentProfile else {
            return .init(mode: fallbackMode, providerSettings: [:])
        }
        switch providerID {
        case .codex:
            var providerSettings = projection.providerSettings
            providerSettings["codex.searchEnabled"] = values[PortalDesktopSettingKey.codexSearchEnabled.rawValue] ?? "true"
            providerSettings["codex.goalsEnabled"] = values[PortalDesktopSettingKey.codexGoalsEnabled.rawValue] ?? "true"
            providerSettings["codex.reasoningSummariesEnabled"] = values[PortalDesktopSettingKey.codexReasoningSummariesEnabled.rawValue] ?? "false"
            providerSettings["codex.memoriesEnabled"] = values[PortalDesktopSettingKey.codexMemoriesEnabled.rawValue] ?? "false"
            providerSettings["codex.enabledMCPServers"] = values[PortalDesktopSettingKey.codexEnabledMCPServers.rawValue] ?? "[\"RepoPromptCE\"]"
            return .init(mode: projection.mode, providerSettings: providerSettings)
        case .claudeCompatible, .claudeGLM, .claudeKimi, .claudeCustom:
            var providerSettings = projection.providerSettings
            providerSettings["claude.toolSearchEnabled"] = values[PortalDesktopSettingKey.claudeToolSearchEnabled.rawValue] ?? "true"
            if providerID != .claudeCompatible {
                let backend = try Self.backendSettings(providerID: providerID, values: values)
                if backend.isEnabled {
                    providerSettings["claude.backendID"] = providerID.rawValue
                    providerSettings["claude.backendBaseURL"] = backend.baseURL
                    providerSettings["claude.backendAuthHeader"] = backend.authHeader.rawValue
                    providerSettings["claude.backendModelBehavior"] = backend.modelBehavior.rawValue
                    providerSettings["claude.backendHaikuModel"] = backend.haikuModel
                    providerSettings["claude.backendSonnetModel"] = backend.sonnetModel
                    providerSettings["claude.backendOpusModel"] = backend.opusModel
                }
            }
            return .init(mode: projection.mode, providerSettings: providerSettings)
        case .openCodeACP, .cursorACP, .grokBuildACP:
            return .init(mode: projection.mode, providerSettings: projection.providerSettings)
        case .openAIAPI, .anthropicAPI, .openRouter, .customOpenAICompatible,
             .gemini, .azure, .deepseek, .fireworks, .xAI, .groq, .zAI, .ollama:
            return .init(mode: fallbackMode, providerSettings: [:])
        }
    }

    public func backendSettings(for providerID: ProviderSettingsID) async throws -> ClaudeCompatibleBackendSettings? {
        guard [.claudeGLM, .claudeKimi, .claudeCustom].contains(providerID) else { return nil }
        let values = try await snapshot().values
        return try Self.backendSettings(providerID: providerID, values: values)
    }

    private nonisolated static func backendSettings(providerID: ProviderSettingsID, values: [String: String]) throws -> ClaudeCompatibleBackendSettings {
        let displayName: PortalDesktopSettingKey
        let baseURL: PortalDesktopSettingKey
        let authHeader: PortalDesktopSettingKey
        let haiku: PortalDesktopSettingKey
        let sonnet: PortalDesktopSettingKey
        let opus: PortalDesktopSettingKey
        let behavior: PortalDesktopSettingKey?
        let fallbackBehavior: ClaudeCompatibleBackendModelBehavior
        let isEnabled: Bool
        switch providerID {
        case .claudeGLM:
            displayName = .claudeGLMDisplayName
            baseURL = .claudeGLMBaseURL
            authHeader = .claudeGLMAuthHeader
            haiku = .claudeGLMHaikuModel
            sonnet = .claudeGLMSonnetModel
            opus = .claudeGLMOpusModel
            behavior = nil
            fallbackBehavior = .claudeSlotMapping
            isEnabled = true
        case .claudeKimi:
            displayName = .claudeKimiDisplayName
            baseURL = .claudeKimiBaseURL
            authHeader = .claudeKimiAuthHeader
            haiku = .claudeKimiHaikuModel
            sonnet = .claudeKimiSonnetModel
            opus = .claudeKimiOpusModel
            behavior = .claudeKimiModelBehavior
            fallbackBehavior = .noModel
            isEnabled = true
        case .claudeCustom:
            displayName = .claudeCustomDisplayName
            baseURL = .claudeCustomBaseURL
            authHeader = .claudeCustomAuthHeader
            haiku = .claudeCustomHaikuModel
            sonnet = .claudeCustomSonnetModel
            opus = .claudeCustomOpusModel
            behavior = .claudeCustomModelBehavior
            fallbackBehavior = .noModel
            isEnabled = values[PortalDesktopSettingKey.claudeCustomEnabled.rawValue] == "true"
        default:
            throw ServiceAPIError(code: .invalidRequest, message: "Claude-compatible backend settings were requested for an unrelated provider")
        }
        let auth = ClaudeCompatibleBackendAuthHeader(rawValue: values[authHeader.rawValue] ?? "") ?? .anthropicAPIKey
        let modelBehavior = behavior.flatMap {
            ClaudeCompatibleBackendModelBehavior(rawValue: values[$0.rawValue] ?? $0.defaultValue)
        } ?? fallbackBehavior
        return .init(
            providerID: providerID,
            isEnabled: isEnabled,
            displayName: values[displayName.rawValue] ?? displayName.defaultValue,
            baseURL: values[baseURL.rawValue] ?? baseURL.defaultValue,
            authHeader: auth,
            modelBehavior: modelBehavior,
            haikuModel: values[haiku.rawValue] ?? haiku.defaultValue,
            sonnetModel: values[sonnet.rawValue] ?? sonnet.defaultValue,
            opusModel: values[opus.rawValue] ?? opus.defaultValue
        )
    }

    private func liveDirectAgentPermissions(values: [String: String]) async -> DirectAgentPermissionsSettings {
        if let stored = try? await store.directAgentPermissionDocument() {
            return stored.value
        }
        return Self.projectedDirectAgentPermissions(fromPortalValues: values)
    }

    private nonisolated static func projectedDirectAgentPermissions(
        fromPortalValues values: [String: String]
    ) -> DirectAgentPermissionsSettings {
        .init(
            codex: .from(
                permissionLevel: values[PortalDesktopSettingKey.codexPermissionLevel.rawValue] ?? "autoReview",
                bashEnabled: values[PortalDesktopSettingKey.codexBashEnabled.rawValue] != "false"
            ),
            claude: .from(
                permissionLevel: values[PortalDesktopSettingKey.claudePermissionLevel.rawValue] ?? "requireApproval",
                bashEnabled: values[PortalDesktopSettingKey.claudeBashEnabled.rawValue] != "false",
                mcpStrictModeEnabled: values[PortalDesktopSettingKey.claudeStrictMCPEnabled.rawValue] != "false"
            ),
            openCode: .init(
                permissionLevel: values[PortalDesktopSettingKey.openCodePermissionLevel.rawValue] == "fullAccess"
                    ? .fullAccess
                    : .managedDefault
            ),
            cursor: .init(
                permissionLevel: values[PortalDesktopSettingKey.cursorPermissionLevel.rawValue] == "fullAccess"
                    ? .fullAccess
                    : .managedDefault
            ),
            grokBuild: .init(
                permissionLevel: values[PortalDesktopSettingKey.grokBuildPermissionLevel.rawValue] == "fullAccess"
                    ? .fullAccess
                    : .managedDefault
            )
        )
    }

    private nonisolated static func boolean(_ key: PortalDesktopSettingKey, values: [String: String]) -> Bool {
        values[key.rawValue] == "true"
    }
}

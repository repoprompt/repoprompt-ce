import Foundation

/// Eager, provisional Claude-family configured context-window lookup for sidebar-only
/// denominator state before a provider session has spawned or emitted usage.
///
/// This wrapper intentionally reuses `ClaudeEffectiveContextWindowResolver` for the
/// actual raw-value resolution and keeps eager-only behavior here: Claude-family
/// gating, predicted backend env overrides, and key-based caching.
final class ClaudeProvisionalContextWindowResolver {
    struct Key: Hashable {
        let agentKindRaw: String
        let modelRaw: String
        let workspacePath: String?

        init(agentKind: AgentProviderKind, modelRaw: String, workspacePath: String?) {
            agentKindRaw = agentKind.rawValue
            self.modelRaw = modelRaw
            self.workspacePath = workspacePath
        }

        var agentKind: AgentProviderKind? {
            AgentProviderKind(rawValue: agentKindRaw)
        }
    }

    struct CachedValue: Equatable {
        let configuredContextWindow: Int?
    }

    private var cachedValues: [Key: CachedValue] = [:]

    func cachedConfiguredContextWindow(for key: Key) -> Int? {
        cachedValues[key]?.configuredContextWindow
    }

    func hasCachedValue(for key: Key) -> Bool {
        cachedValues[key] != nil
    }

    func store(_ value: Int?, for key: Key) {
        cachedValues[key] = CachedValue(configuredContextWindow: value)
    }

    func resolveConfiguredContextWindow(
        for key: Key,
        environmentSnapshot: [String: String],
        fileManager: FileManager = .default
    ) -> Int? {
        if let cached = cachedValues[key] {
            return cached.configuredContextWindow
        }
        let value = Self.resolveUncachedConfiguredContextWindow(
            for: key,
            environmentSnapshot: environmentSnapshot,
            fileManager: fileManager
        )
        cachedValues[key] = CachedValue(configuredContextWindow: value)
        return value
    }

    static func resolveUncachedConfiguredContextWindow(
        for key: Key,
        environmentSnapshot: [String: String],
        fileManager: FileManager = .default
    ) -> Int? {
        guard let agentKind = key.agentKind, agentKind.usesClaudeNativeRuntime else {
            return nil
        }

        let predictedEnvironment = predictedLaunchEnvironment(
            agentKind: agentKind,
            modelRaw: key.modelRaw,
            environmentSnapshot: environmentSnapshot
        )
        return ClaudeEffectiveContextWindowResolver.resolveConfiguredContextWindow(
            launchEnvironment: predictedEnvironment,
            workingDirectory: key.workspacePath,
            fileManager: fileManager
        )
    }

    private static func predictedLaunchEnvironment(
        agentKind: AgentProviderKind,
        modelRaw: String,
        environmentSnapshot: [String: String]
    ) -> [String: String] {
        var environment = environmentSnapshot
        if environment["HOME"].map({ !$0.isEmpty }) != true {
            environment["HOME"] = NSHomeDirectory()
        }

        // Mirrors ClaudeCompatibleBackendEnvironmentBuilder.environment(config:apiKey:selectedBackendModelID:),
        // which sets Claude Code's auto-compact window to 1M for GLM backend models whose
        // normalized backend context window is 1M.
        if predictedBackendContextWindow(agentKind: agentKind, modelRaw: modelRaw) == 1_000_000 {
            environment[ClaudeEffectiveContextWindowResolver.environmentKey] = "1000000"
        }
        return environment
    }

    private static func predictedBackendContextWindow(agentKind: AgentProviderKind, modelRaw: String) -> Int? {
        switch agentKind {
        case .claudeCodeGLM:
            ClaudeCompatibleModelCatalogAdapter.contextWindowTokens(
                forRequestedModelRaw: modelRaw,
                agentKind: agentKind
            )
        case .claudeCode, .kimiCode, .customClaudeCompatible, .codexExec, .openCode, .cursor:
            nil
        }
    }
}

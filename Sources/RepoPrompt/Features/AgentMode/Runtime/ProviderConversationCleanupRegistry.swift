import Foundation

struct ProviderConversationCleanupRegistry {
    typealias Cleaner = @Sendable (
        _ handle: ProviderConversationCleanupHandle,
        _ action: ProviderConversationCleanupAction
    ) async -> ProviderConversationCleanupOutcome

    private let codexCleaner: Cleaner

    init(codexCleaner: @escaping Cleaner = Self.defaultCodexCleaner) {
        self.codexCleaner = codexCleaner
    }

    func cleanup(
        _ handle: ProviderConversationCleanupHandle,
        action: ProviderConversationCleanupAction
    ) async -> ProviderConversationCleanupOutcome {
        guard handle.hasProviderIdentifier else {
            return .unsupported(message: "Provider \(handle.provider) has no cleanup identifier.")
        }

        switch Self.normalizedProvider(handle.provider) {
        case Self.normalizedProvider(AgentProviderKind.codexExec.rawValue),
             "codex":
            return await codexCleaner(handle, action)

        case Self.normalizedProvider(AgentProviderKind.claudeCode.rawValue),
             Self.normalizedProvider(AgentProviderKind.claudeCodeGLM.rawValue),
             Self.normalizedProvider(AgentProviderKind.kimiCode.rawValue),
             Self.normalizedProvider(AgentProviderKind.customClaudeCompatible.rawValue):
            return .unsupported(message: "Provider \(handle.provider) has resumable session metadata but no verified conversation cleanup API.")

        case Self.normalizedProvider(AgentProviderKind.openCode.rawValue),
             Self.normalizedProvider(AgentProviderKind.cursor.rawValue):
            return .unsupported(message: "ACP provider \(handle.provider) has session metadata but no verified conversation cleanup API.")

        default:
            return .unsupported(message: "Provider \(handle.provider) has no registered conversation cleanup implementation.")
        }
    }

    private static func defaultCodexCleaner(
        handle: ProviderConversationCleanupHandle,
        action: ProviderConversationCleanupAction
    ) async -> ProviderConversationCleanupOutcome {
        let client = CodexAppServerClient()
        do {
            try await client.startIfNeeded()
            let cleanup = CodexConversationCleanupService(
                requestExecutor: { method, params, timeout in
                    try await client.request(method: method, params: params, timeout: timeout)
                },
                timeout: CodexNativeSessionController.Options.agentModeDefault(forceExperimentalSteering: true).requestTimeout
            )
            let outcome = await cleanup.cleanup(handle, action: action)
            await client.stop()
            return outcome
        } catch {
            await client.stop()
            return .failed(message: error.localizedDescription)
        }
    }

    private static func normalizedProvider(_ provider: String) -> String {
        provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

import RepoPromptAIContracts
import RepoPromptClaudeProvider

package protocol ClaudeCodeLaunchEnvironmentResolving: Sendable {
    func resolve(
        variant: ClaudeCodeRuntimeVariant,
        requestedModel: String?
    ) async throws -> ClaudeCompatiblePluginLaunchEnvironment
}

import Foundation
import RepoPromptACPProviders
import RepoPromptAIContracts
import RepoPromptProcess

/// Name-only policy injection; settings remain owned by App composition.
package typealias ProviderRemovedEnvironmentNames = @Sendable (String) async -> Set<String>

package protocol GrokBuildCLIHost: Sendable {
    func makeHeadlessConfig(modelName: String?) -> GrokBuildAgentConfig
    func modelName(for model: AIModel) -> String?
    func makeOneShotProvider(config: GrokBuildAgentConfig) -> GrokBuildOneShotHeadlessAgentProvider
}

package protocol GrokBuildACPHeadlessHost: Sendable {
    func selectedModel(config: GrokBuildAgentConfig) throws -> String?
}

package protocol GrokBuildOneShotHost: Sendable {
    func resolveModelSelection(modelString: String?) async throws -> (model: String?, effort: String?)
    func filterEnvironment(
        _ environment: [String: String],
        explicitOverrides: [String: String],
        removedNamesProvider: ProviderRemovedEnvironmentNames?
    ) async -> [String: String]
}

package protocol DevinCLIHost: Sendable {
    func modelName(for model: AIModel) -> String?
    func isDefaultModel(_ modelName: String) -> Bool
    func prepareIsolatedIntegration(
        workingDirectory: String,
        sourceEnvironment: [String: String]
    ) throws -> (environment: [String: String], cleanupArtifact: ACPLaunchCleanupArtifact)
    func cleanupIntegration(artifact: ACPLaunchCleanupArtifact)
    func environmentFilter(explicitOverrides: [String: String]) -> CLIProcessConfiguration.EnvironmentFilter
}

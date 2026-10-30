import Foundation
import RepoPromptProcess

/// Physical runtime/configuration composition remains in App. Transport owns the
/// captured launch context and invokes these operations at its existing fences.
package protocol CodexAppServerLaunchHost {
    var applicationVersion: String { get }
    func resolveRuntime(commandName: String, additionalPathHints: [String], enableDebugLogging: Bool) async -> CodexAppServerRuntimeResolution
    func prepareState(for runtime: CodexProviderRuntime.Runtime) throws
    func filterEnvironment(_ environment: [String: String], explicitOverrides: [String: String]) async -> [String: String]
    func baseProcessArguments(runtime: CodexProviderRuntime.Runtime, provisionsRepoPromptMCP: Bool, featurePolicy: CodexProcessConfiguration.FeaturePolicy, reasoningSummary: CodexProcessConfiguration.ReasoningSummary?) throws -> [String]
    /// Called after spawn preparation and cancellation/startup fences. Must remain
    /// synchronous: no suspension from the fresh physical config read to spawn.
    func computerUseProcessArguments(runtime: CodexProviderRuntime.Runtime) throws -> [String]
}

package struct CodexAppServerRuntimeResolution {
    package let environment: [String: String]
    package let resolution: CodexProviderExecutableResolution

    package init(environment: [String: String], resolution: CodexProviderExecutableResolution) {
        self.environment = environment
        self.resolution = resolution
    }
}

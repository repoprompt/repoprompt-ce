import Foundation

/// Physical runtime/configuration composition remains in App. Transport owns the
/// captured launch context and invokes these operations at its existing fences.
package protocol CodexAppServerLaunchHost {
    var applicationVersion: String { get }
    func buildEnvironment(enableDebugLogging: Bool) async -> [String: String]
    /// Resolve synchronously after both environment awaits, using the client's current config.
    func resolveRuntime(commandName: String, environment: [String: String], additionalPathHints: [String], enableDebugLogging: Bool) -> CodexProviderExecutableResolution
    func prepareState(for runtime: CodexProviderRuntime.Runtime) throws
    /// Merge the ambient carrier at the actual launch point, never during cached runtime resolution.
    func processEnvironmentForCurrentLaunch(_ baseEnvironment: [String: String]) -> [String: String]
    func filterEnvironment(_ environment: [String: String], explicitOverrides: [String: String]) async -> [String: String]
    func baseProcessArguments(runtime: CodexProviderRuntime.Runtime, provisionsRepoPromptMCP: Bool, featurePolicy: CodexProcessConfiguration.FeaturePolicy, reasoningSummary: CodexProcessConfiguration.ReasoningSummary?) throws -> [String]
    /// Called after spawn preparation and cancellation/startup fences. Must remain
    /// synchronous: no suspension from the fresh physical config read to spawn.
    func computerUseProcessArguments(runtime: CodexProviderRuntime.Runtime) throws -> [String]
}

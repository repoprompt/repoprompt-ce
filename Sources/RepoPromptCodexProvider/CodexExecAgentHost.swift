import Foundation
import RepoPromptAgentProviderContracts
import RepoPromptAIContracts
import RepoPromptDomainRuntime
import RepoPromptProcess

/// Codex Exec never carries a provider-specific launch payload or a config lease.
package typealias CodexExecLaunchContext = HeadlessLaunchContext<Never>

/// Required App policy at the existing Codex Exec read/effect sites.
package protocol CodexExecAgentHost {
    var toolTracking: any CodexExecToolTracking { get }
    func preflight(commandName: String, additionalPathHints: [String], enableDebugLogging: Bool) async -> CodexProviderExecutableResolution
    func prepareState(_ runtime: CodexProviderRuntime.Runtime) throws
    func environmentFilter(explicitOverrides: [String: String]) -> CLIProcessConfiguration.EnvironmentFilter
    func isMCPServerRunning() async -> Bool
    func ensureServer(runtime: CodexProviderRuntime.Runtime) -> (success: Bool, wasAlreadyPresent: Bool, errorMessage: String?)
    func modelSpecifier(raw: String?) -> CodexModelSpecifier
    func serverEntries() -> [CodexExecServerEntry]
    func brokenServers() async -> Set<String>
    func addBrokenServer(_ name: String) async
    func contextWindowOverrideArguments() -> [String]
    func toolOverrideArguments() -> [String]
    func serverOverrideArguments(entries: [CodexExecServerEntry], brokenServers: Set<String>) -> [String]
    func fallbackModel(attemptedModel: String?, errorDetail: String) -> String?
    func brokenServerName(stderr: String) -> String?
    func isRepoPromptToolName(_ name: String) -> Bool
    func isRepoPromptServerIdentifier(_ name: String) -> Bool
    var manualLoginGuidanceMessage: String { get }
    func registerExpectedPID(_ pid: Int32, runID: UUID) async
    func clearExpectedPID(_ pid: Int32, runID: UUID) async
}

/// Uses the original continuation and the existing App tracking controller.
package protocol CodexExecToolTracking {
    func startTracking(runID: UUID, clientNameHint: String, continuation: AsyncThrowingStream<RepoPromptDomainRuntime.AIStreamResult, Error>.Continuation)
    func stopTracking() async
}

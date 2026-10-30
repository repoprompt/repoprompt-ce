import Darwin
import Foundation
import RepoPromptAgentProviderContracts
import RepoPromptAIContracts

package protocol ClaudeNativeConfigLease: Sendable {
    var url: URL { get }
    func release()
}

package struct ClaudeNativePermissionMatch {
    package let source: String
    package let normalizedToolName: String?
    package let serverIdentifier: String?

    package init(source: String, normalizedToolName: String?, serverIdentifier: String?) {
        self.source = source
        self.normalizedToolName = normalizedToolName
        self.serverIdentifier = serverIdentifier
    }
}

package protocol ClaudeNativeSessionHosting: Sendable {
    func repoPromptPermissionMatch(toolName: String, requestPayload: [String: Any]) -> ClaudeNativePermissionMatch?
    func filterEnvironment(_ environment: [String: String], variant: ClaudeCodeRuntimeVariant) async -> [String: String]
    func mergeCurrentCarrier(into environment: [String: String]) -> [String: String]
    func processEnvironmentOverrides(for context: AgentCLIToolContext) -> [String: String]
    func hasModelSpecifier(_ model: String?) -> Bool
    func explicitEffortLevel(for model: String?) -> ClaudeCodeEffortLevel?
    func isDefaultModel(_ model: String) -> Bool
    func shouldSuppressAbortArtifact(_ message: String) -> Bool
    func supplementedPathHints(_ hints: [String]) -> [String]
    func expectedAgentClientName(for variant: ClaudeCodeRuntimeVariant) -> String?
    func isRawEventFileLoggingEnabled() -> Bool
    func makeRawEventLogFileURL(workspacePath: String?, sessionID: String) -> URL?
    func recordLastRawEventLogFileURL(_ url: URL)
    func isReasoningExtractionEnabled() -> Bool
    func appendReasoningDebug(_ line: String)
    func isRepoPromptToolName(_ name: String) -> Bool
    #if DEBUG
        func debugStatusLineArguments(launchArguments: [String], isFirstParty: Bool, providerArguments: [String]) -> [String]
    #endif
    func isMCPServerRunning() async -> Bool
    func prepareMCPLaunchConfig() async throws -> any ClaudeNativeConfigLease
    func registerExpectedAgentPID(_ pid: pid_t, clientName: String, runID: UUID) async
    func clearExpectedAgentPID(_ pid: pid_t, clientName: String, runID: UUID) async
}

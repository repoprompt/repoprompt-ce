import Darwin
import Foundation
import RepoPromptAIContracts

protocol ClaudeNativeConfigLease: Sendable {
    var url: URL { get }
    func release()
}

struct ClaudeNativePermissionMatch {
    let source: String
    let normalizedToolName: String?
    let serverIdentifier: String?
}

protocol ClaudeNativeSessionHosting: Sendable {
    func repoPromptPermissionMatch(toolName: String, requestPayload: [String: Any]) -> ClaudeNativePermissionMatch?
    func filterEnvironment(_ environment: [String: String], variant: ClaudeCodeRuntimeVariant) async -> [String: String]
    func mergeCurrentCarrier(into environment: [String: String]) -> [String: String]
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

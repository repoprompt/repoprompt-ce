import Darwin
import Foundation
import RepoPromptAIContracts

extension MCPConfigLease: ClaudeNativeConfigLease {}

struct ClaudeNativeSessionAppHost: ClaudeNativeSessionHosting {
    func repoPromptPermissionMatch(toolName: String, requestPayload: [String: Any]) -> ClaudeNativePermissionMatch? {
        guard let match = MCPIntegrationHelper.repoPromptPermissionAutoApprovalMatch(
            requestToolName: toolName,
            requestPayload: requestPayload
        ) else { return nil }
        return ClaudeNativePermissionMatch(
            source: match.source.rawValue,
            normalizedToolName: match.normalizedToolName,
            serverIdentifier: match.serverIdentifier
        )
    }

    func filterEnvironment(_ environment: [String: String], variant: ClaudeCodeRuntimeVariant) async -> [String: String] {
        await ProviderEnvironmentFiltering.filter(environment, for: variant.agentKind)
    }

    func mergeCurrentCarrier(into environment: [String: String]) -> [String: String] {
        DomainChildLaunchEnvironmentBridge.mergingCurrentCarrier(into: environment)
    }

    func supplementedPathHints(_ hints: [String]) -> [String] {
        CLIPathHints.nativeDefaultsSupplemented(with: hints)
    }

    func expectedAgentClientName(for variant: ClaudeCodeRuntimeVariant) -> String? {
        variant.agentKind.mcpClientNameHint
    }

    #if DEBUG
        func debugStatusLineArguments(launchArguments: [String], isFirstParty: Bool, providerArguments: [String]) -> [String] {
            ClaudeStatusLineCompatibilityProbe.claimSettingsArguments(
                launchArguments: launchArguments,
                isFirstParty: isFirstParty,
                providerArguments: providerArguments
            )
        }
    #endif

    func isMCPServerRunning() async -> Bool {
        await ServerNetworkManager.shared.isRunning()
    }

    func prepareMCPLaunchConfig() async throws -> any ClaudeNativeConfigLease {
        try await MCPConfigExportService.shared.prepareLaunchConfig()
    }

    func registerExpectedAgentPID(_ pid: pid_t, clientName: String, runID: UUID) async {
        await ServerNetworkManager.shared.registerExpectedAgentPID(pid, for: clientName, runID: runID)
    }

    func clearExpectedAgentPID(_ pid: pid_t, clientName: String, runID: UUID) async {
        await ServerNetworkManager.shared.clearExpectedAgentPID(pid, for: clientName, runID: runID)
    }
}

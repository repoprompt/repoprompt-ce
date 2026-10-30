import Darwin
import Foundation

extension MCPConfigLease: ClaudeNativeConfigLease {}

struct ClaudeNativeSessionAppHost: ClaudeNativeSessionHosting {
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

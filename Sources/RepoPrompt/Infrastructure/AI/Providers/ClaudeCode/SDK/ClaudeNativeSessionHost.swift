import Darwin
import Foundation

protocol ClaudeNativeConfigLease: Sendable {
    var url: URL { get }
    func release()
}

protocol ClaudeNativeSessionHosting: Sendable {
    func isMCPServerRunning() async -> Bool
    func prepareMCPLaunchConfig() async throws -> any ClaudeNativeConfigLease
    func registerExpectedAgentPID(_ pid: pid_t, clientName: String, runID: UUID) async
    func clearExpectedAgentPID(_ pid: pid_t, clientName: String, runID: UUID) async
}

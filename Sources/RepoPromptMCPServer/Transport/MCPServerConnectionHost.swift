// Exported Swift 5 package values need explicit cross-module Sendable contracts.
// swiftformat:disable redundantSendable
import Foundation
import MCP
import RepoPromptShared

/// App composition and lifecycle authority consumed by a physical connection.
/// The transport cannot inspect windows, settings, consent, or run state.
package struct MCPServerConnectionConfiguration: Sendable {
    package let name: String
    package let version: String
    package let healthPolicy: @Sendable () -> (idleSeconds: Int, keepaliveSeconds: Int)

    package init(name: String, version: String, healthPolicy: @escaping @Sendable () -> (idleSeconds: Int, keepaliveSeconds: Int)) {
        self.name = name
        self.version = version
        self.healthPolicy = healthPolicy
    }
}

package protocol MCPServerConnectionHost: Sendable {
    var connectionConfiguration: MCPServerConnectionConfiguration { get }
    func registerHandlers(for server: MCP.Server, connectionID: UUID) async
    func recordTransportIngressTerminal(
        connectionID: UUID,
        clientName: String?,
        sessionToken: String?,
        snapshot: MCPTransportIngressSnapshot,
        closeSnapshot: MCPTransportCloseSnapshot
    ) async
    func removeConnection(_ id: UUID, context: MCPConnectionCloseContext) async
    func terminateConnection(_ id: UUID, reason: TerminationReason, message: String?) async
    func isRunning() async -> Bool
    func hasInFlightCalls(for connectionID: UUID) async -> Bool
}

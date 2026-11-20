import Foundation
import MCP
import RepoPromptDomainRuntime
import RepoPromptShared

package enum ConnectionStateSnapshot: Equatable {
    case connecting
    case ready
    case failed(Swift.Error?)
    case cancelled

    package static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.connecting, .connecting),
             (.ready, .ready),
             (.cancelled, .cancelled):
            true
        case (.failed, .failed):
            // Treat all failures as equivalent for pruning/retention decisions
            true
        default:
            false
        }
    }
}

package typealias MCPResponseDeliverySnapshot = RepoPromptDomainRuntime.MCPDomainResponseDeliverySnapshot

package typealias MCPProgressDeliveryResult = RepoPromptDomainRuntime.MCPProgressDeliveryResult

/// The server-error payload delivered to each outstanding JSON-RPC request before an
/// accepted connection is closed for an unresponsive tool execution.
///
/// This is deliberately transport-level context. The handler which exceeded its
/// deadline cannot be trusted to return a result, while other accepted requests on
/// the same connection may not yet have reached a handler at all.
package struct MCPExecutionWatchdogTerminalContext {
    package let reason: String
    package let toolName: String
    package let handlerPhase: String
    package let invocationID: UUID

    package static let jsonRPCServerErrorCode = -32000
    package static let message = "MCP connection closed after unresponsive tool execution"

    package init(
        reason: String,
        toolName: String,
        handlerPhase: String,
        invocationID: UUID
    ) {
        self.reason = reason
        self.toolName = toolName
        self.handlerPhase = handlerPhase
        self.invocationID = invocationID
    }
}

package protocol MCPServerConnection: MCPDomainProgressTransport {
    func start(approvalHandler: @escaping (MCP.Client.Info) async -> Bool) async throws
    func stop() async
    /// Sends terminal JSON-RPC errors for outstanding requests, then severs delivery for
    /// a tool execution that ignored cancellation. This must not await handler/server shutdown.
    func abortForExecutionWatchdog(context: MCPExecutionWatchdogTerminalContext) async
    func notifyToolListChanged() async
    func connectionState() -> ConnectionStateSnapshot
    func isViableForRetention() -> Bool
    func secondsSinceLastActivity() async -> TimeInterval
    func transportIngressSnapshot() async -> MCPTransportIngressSnapshot?
    func responseDeliverySnapshot() async -> MCPResponseDeliverySnapshot?
    func waitUntilResponseDeliveryDrained() async -> Bool
    /// Whether this is a legacy filesystem-backed connection (deprecated)
    nonisolated var isFilesystemBacked: Bool { get }
    /// Legacy: connection folder URL for filesystem connections
    nonisolated var connectionFolderURL: URL? { get }
    /// Optional capability token / session key for routing persistence.
    /// Used to correlate CLI sessions across reconnections.
    nonisolated var capabilityToken: String? { get }
    /// Terminates this connection with a reason.
    /// Writes a kill signal file (filesystem side-channel) so CLI exits without retry, then stops.
    /// - Parameter reason: Why the connection is being terminated
    /// - Parameter message: Optional human-readable message
    func terminate(reason: TerminationReason, message: String?) async

    /// Sends a progress notification to the CLI during long-running operations.
    /// - Parameters:
    ///   - tool: Tool name (e.g., "context_builder", "oracle_send")
    ///   - kind: Progress kind (.stage for transitions, .heartbeat for keep-alive)
    ///   - stage: Current stage name
    ///   - message: Human-readable message
    func sendProgress(tool: String, kind: RepoPromptProgressKind, stage: String, message: String) async

    /// Sends a standard MCP `notifications/progress` message associated with the
    /// caller-provided request token.
    func sendMCPProgress(
        token: ProgressToken,
        progress: Double,
        message: String?
    ) async

    /// Reports whether advisory delivery reached a terminal connection state.
    /// Request progress uses this to discard its bounded pending update instead
    /// of attempting more writes after the connection has closed.
    func deliverMCPProgress(
        token: ProgressToken,
        progress: Double,
        message: String?
    ) async -> MCPProgressDeliveryResult
}

package extension MCPServerConnection {
    func responseDeliverySnapshot() async -> MCPResponseDeliverySnapshot? {
        nil
    }

    func waitUntilResponseDeliveryDrained() async -> Bool {
        true
    }

    func sendMCPProgress(
        token _: ProgressToken,
        progress _: Double,
        message _: String?
    ) async {}

    func deliverMCPProgress(
        token: ProgressToken,
        progress: Double,
        message: String?
    ) async -> MCPProgressDeliveryResult {
        await sendMCPProgress(token: token, progress: progress, message: message)
        return isViableForRetention() ? .delivered : .connectionTerminal
    }
}

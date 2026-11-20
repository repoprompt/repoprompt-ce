// Exported Swift 5 package values need explicit cross-module Sendable contracts.
// swiftformat:disable redundantSendable
import Foundation
import RepoPromptDomainRuntime
import RepoPromptShared

public enum MCPTransportTerminalCause: String, Codable, Equatable, Sendable {
    case peerEOF = "peer_eof"
    case incompleteEOF = "incomplete_eof"
    case readError = "read_error"
    case writeFailure = "write_failure"
    case writeStall = "write_stall"
    case writeHangup = "write_hangup"
    case receiveBufferOverflow = "receive_buffer_overflow"
    case clientCancellationOwnershipFailure = "client_cancellation_ownership_failure"
    case localDisconnect = "local_disconnect"
    case connectFailure = "connect_failure"
    case connectCancelled = "connect_cancelled"
}

public struct MCPTransportCloseSnapshot: Equatable, Sendable {
    public let cause: MCPTransportTerminalCause
    public let initiator: MCPTerminalInitiator
    public let errno: Int32?
    public let errorDescription: String?

    package init(
        cause: MCPTransportTerminalCause,
        initiator: MCPTerminalInitiator,
        errno: Int32?,
        errorDescription: String?
    ) {
        self.cause = cause
        self.initiator = initiator
        self.errno = errno
        self.errorDescription = errorDescription
    }
}

package typealias MCPFirstTerminalRecordClaim = MCPDomainFirstTerminalClaim<MCPTerminalRecord>

package struct MCPTerminalToolExecutionContext: Equatable {
    package let toolName: String
    package let invocationID: UUID
    package let elapsedMilliseconds: Double
    package let handlerPhase: String?
    package let handlerPhaseAgeMilliseconds: Double?
    package let executionDeadlineMilliseconds: Double?
    package let cleanupGraceMilliseconds: Double?

    package init(
        toolName: String,
        invocationID: UUID,
        elapsedMilliseconds: Double,
        handlerPhase: String?,
        handlerPhaseAgeMilliseconds: Double?,
        executionDeadlineMilliseconds: Double?,
        cleanupGraceMilliseconds: Double?
    ) {
        self.toolName = toolName
        self.invocationID = invocationID
        self.elapsedMilliseconds = elapsedMilliseconds
        self.handlerPhase = handlerPhase
        self.handlerPhaseAgeMilliseconds = handlerPhaseAgeMilliseconds
        self.executionDeadlineMilliseconds = executionDeadlineMilliseconds
        self.cleanupGraceMilliseconds = cleanupGraceMilliseconds
    }
}

package struct MCPConnectionCloseContext: Equatable {
    package let reason: String
    package let initiator: MCPTerminalInitiator
    package let errno: Int32?
    package let errorDescription: String?
    package let toolExecution: MCPTerminalToolExecutionContext?

    package init(
        reason: String,
        initiator: MCPTerminalInitiator,
        errno: Int32? = nil,
        errorDescription: String? = nil,
        toolExecution: MCPTerminalToolExecutionContext? = nil
    ) {
        self.reason = reason
        self.initiator = initiator
        self.errno = errno
        self.errorDescription = errorDescription
        self.toolExecution = toolExecution
    }

    package init(transport snapshot: MCPTransportCloseSnapshot) {
        self.init(
            reason: snapshot.cause.rawValue,
            initiator: snapshot.initiator,
            errno: snapshot.errno,
            errorDescription: snapshot.errorDescription
        )
    }

    package static func startupFailure(
        error: Swift.Error,
        transportSnapshot: MCPTransportCloseSnapshot?
    ) -> MCPConnectionCloseContext {
        if let transportSnapshot {
            return MCPConnectionCloseContext(transport: transportSnapshot)
        }
        return MCPConnectionCloseContext(
            reason: error is CancellationError
                ? "connection_start_cancelled"
                : "connection_start_failure",
            initiator: .app,
            errorDescription: String(describing: error)
        )
    }

    package static let cleanupUnspecified = MCPConnectionCloseContext(
        reason: "connection_cleanup_unspecified",
        initiator: .unknown
    )
}

package struct MCPTransportIngressSnapshot: Equatable {
    package let receiveBufferCapacity: Int
    package let acceptedFrameCount: Int
    package let droppedFrameCount: Int
    package let receiveBufferHighWaterMark: Int
    package let isTerminal: Bool
    package let terminalCause: MCPTransportTerminalCause?

    package init(
        receiveBufferCapacity: Int,
        acceptedFrameCount: Int,
        droppedFrameCount: Int,
        receiveBufferHighWaterMark: Int,
        isTerminal: Bool,
        terminalCause: MCPTransportTerminalCause?
    ) {
        self.receiveBufferCapacity = receiveBufferCapacity
        self.acceptedFrameCount = acceptedFrameCount
        self.droppedFrameCount = droppedFrameCount
        self.receiveBufferHighWaterMark = receiveBufferHighWaterMark
        self.isTerminal = isTerminal
        self.terminalCause = terminalCause
    }
}

package struct MCPReceiveBufferOverflowError: Error, Equatable, CustomStringConvertible, LocalizedError {
    package let capacity: Int
    package let highWaterMark: Int

    package var description: String {
        "MCP receive buffer overflow (cause=\(MCPTransportTerminalCause.receiveBufferOverflow.rawValue), capacity=\(capacity), highWaterMark=\(highWaterMark))"
    }

    package var errorDescription: String? {
        description
    }

    package init(
        capacity: Int,
        highWaterMark: Int
    ) {
        self.capacity = capacity
        self.highWaterMark = highWaterMark
    }
}

package enum MCPServerIssue: Equatable {
    case none
    case localNetworkPermissionDenied
    case bonjourRegistrationFailed(message: String)
    case listenerRestarting
    case portInUse
    case discoveryDegraded(message: String)
    case lastClientApprovalDenied(clientID: String)
    /// Client approval was auto-denied after timeout (UI didn't respond in time)
    case lastClientApprovalTimedOut(clientID: String)
    case lastClientDisconnectedUnexpectedly(clientID: String?)
    /// Identity/capability token recovery repeatedly failed; server forced filesystem fallback.
    case identityRecoveryDegraded(message: String)
}

package struct MCPDiagnostics: Equatable {
    package var issue: MCPServerIssue
    package var lastEventAt: Date?
    package var listenerStateDescription: String

    package init(
        issue: MCPServerIssue = .none,
        lastEventAt: Date? = nil,
        listenerStateDescription: String = "Idle"
    ) {
        self.issue = issue
        self.lastEventAt = lastEventAt
        self.listenerStateDescription = listenerStateDescription
    }
}

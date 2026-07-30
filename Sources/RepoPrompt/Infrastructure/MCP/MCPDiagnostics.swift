import Foundation
import RepoPromptShared

public enum MCPTransportTerminalCause: String, Codable, Equatable, Sendable {
    case peerEOF = "peer_eof"
    case incompleteEOF = "incomplete_eof"
    case readError = "read_error"
    case writeFailure = "write_failure"
    case writeStall = "write_stall"
    case writeHangup = "write_hangup"
    case receiveBufferOverflow = "receive_buffer_overflow"
    case localDisconnect = "local_disconnect"
    case connectFailure = "connect_failure"
    case connectCancelled = "connect_cancelled"
}

public struct MCPTransportCloseSnapshot: Equatable, Sendable {
    public let cause: MCPTransportTerminalCause
    public let initiator: MCPTerminalInitiator
    public let errno: Int32?
    public let errorDescription: String?
}

struct MCPFirstTerminalRecordClaim: Equatable {
    private(set) var record: MCPTerminalRecord?
    private(set) var didPersist = false

    mutating func claim(_ candidate: MCPTerminalRecord) -> MCPTerminalRecord? {
        guard !didPersist else { return nil }
        if record == nil {
            record = candidate
        }
        return record
    }

    mutating func markPersisted() {
        guard record != nil else { return }
        didPersist = true
    }
}

struct MCPTerminalToolExecutionContext: Equatable {
    let toolName: String
    let invocationID: UUID
    let elapsedMilliseconds: Double
    let handlerPhase: String?
    let handlerPhaseAgeMilliseconds: Double?
    let executionDeadlineMilliseconds: Double?
    let cleanupGraceMilliseconds: Double?
}

struct MCPConnectionCloseContext: Equatable {
    let reason: String
    let initiator: MCPTerminalInitiator
    let errno: Int32?
    let errorDescription: String?
    let toolExecution: MCPTerminalToolExecutionContext?

    init(
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

    init(transport snapshot: MCPTransportCloseSnapshot) {
        self.init(
            reason: snapshot.cause.rawValue,
            initiator: snapshot.initiator,
            errno: snapshot.errno,
            errorDescription: snapshot.errorDescription
        )
    }

    static func startupFailure(
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

    static let cleanupUnspecified = MCPConnectionCloseContext(
        reason: "connection_cleanup_unspecified",
        initiator: .unknown
    )
}

struct MCPTransportIngressSnapshot: Equatable {
    let receiveBufferCapacity: Int
    let acceptedFrameCount: Int
    let droppedFrameCount: Int
    let receiveBufferHighWaterMark: Int
    let isTerminal: Bool
    let terminalCause: MCPTransportTerminalCause?
}

struct MCPReceiveBufferOverflowError: Error, Equatable, CustomStringConvertible, LocalizedError {
    let capacity: Int
    let highWaterMark: Int

    var description: String {
        "MCP receive buffer overflow (cause=\(MCPTransportTerminalCause.receiveBufferOverflow.rawValue), capacity=\(capacity), highWaterMark=\(highWaterMark))"
    }

    var errorDescription: String? {
        description
    }
}

enum MCPServerIssue: Equatable {
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

struct MCPDiagnostics: Equatable {
    var issue: MCPServerIssue
    var lastEventAt: Date?
    var listenerStateDescription: String

    init(
        issue: MCPServerIssue = .none,
        lastEventAt: Date? = nil,
        listenerStateDescription: String = "Idle"
    ) {
        self.issue = issue
        self.lastEventAt = lastEventAt
        self.listenerStateDescription = listenerStateDescription
    }
}

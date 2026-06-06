import Foundation

enum MCPTransportTerminalCause: String, Equatable {
    case receiveBufferOverflow = "receive_buffer_overflow"
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

//
//  MCPBootstrapMessages.swift
//  RepoPrompt
//
//  Shared bootstrap socket handshake message types.
//  Used by both the app (BootstrapSocketServer) and CLI (repoprompt-mcp).
//
//  IMPORTANT: This file must be included in both targets:
//  - RepoPrompt (app)
//  - repoprompt-mcp (CLI)
//

import Foundation

// MARK: - Protocol Version

/// Bootstrap socket protocol versioning.
public enum MCPBootstrapProtocol {
    /// Current protocol version.
    /// - v1: Initial bootstrap socket implementation
    /// - v2: Added client identity caching for reconnects, improved retry logic
    public static let currentVersion = 2
}

// MARK: - Timing

/// Shared timing budgets for bootstrap socket startup.
/// Keep proxy startup under common outer host timeouts so retries can engage.
public enum MCPBootstrapTiming {
    public static let initialResponseTimeout: TimeInterval = 5
    public static let initialRequestWriteTimeout: TimeInterval = 5
}

// MARK: - Handshake Request

/// Request sent by CLI when connecting to bootstrap socket.
public struct MCPBootstrapRequest: Codable, Sendable {
    /// Message type identifier (always "connect")
    public let type: String

    /// Unique session token for this CLI instance.
    /// Used by the app to identify this CLI across reconnections.
    public let sessionToken: String

    /// CLI process ID for debugging and diagnostics.
    public let clientPid: Int

    /// Client executable name (e.g., "cursor", "claude", "repoprompt-mcp").
    /// May be nil if detection fails.
    public let clientName: String?

    /// Protocol version for compatibility checking.
    public let protocolVersion: Int

    public init(
        sessionToken: String,
        clientPid: Int,
        clientName: String?,
        protocolVersion: Int = MCPBootstrapProtocol.currentVersion
    ) {
        type = "connect"
        self.sessionToken = sessionToken
        self.clientPid = clientPid
        self.clientName = clientName
        self.protocolVersion = protocolVersion
    }
}

// MARK: - Handshake Response

/// Response sent by app after receiving connect request.
/// Bootstrap only establishes the transport; user-facing approval happens later during MCP initialize.
public struct MCPBootstrapResponse: Codable, Sendable {
    /// Response type: "accepted" or "rejected"
    public let type: String

    /// Reason for rejection (if type == "rejected")
    public let reason: String?

    /// Error code for programmatic handling
    public let errorCode: String?

    public init(type: String, reason: String? = nil, errorCode: String? = nil) {
        self.type = type
        self.reason = reason
        self.errorCode = errorCode
    }

    // MARK: Factory Methods

    /// Creates an accepted response.
    public static func accepted() -> MCPBootstrapResponse {
        MCPBootstrapResponse(type: "accepted", reason: nil, errorCode: nil)
    }

    /// Creates a rejected response with reason.
    public static func rejected(reason: String, errorCode: String? = nil) -> MCPBootstrapResponse {
        MCPBootstrapResponse(type: "rejected", reason: reason, errorCode: errorCode)
    }
}

// MARK: - Error Codes

/// Known error codes for programmatic error handling.
public enum MCPBootstrapErrorCode: String {
    case approvalDenied = "approval_denied"
    case protocolVersionMismatch = "protocol_version_mismatch"
    case serverNotReady = "server_not_ready"
    case serverUnavailable = "server_unavailable"
    case connectionLimitReached = "connection_limit_reached"
    case capacityExceeded = "capacity_exceeded"
    case sessionBlocked = "session_blocked"
    case clientCooldown = "client_cooldown"
}

import Foundation

/// Origin of the PID used for app-proxy admission policy.
enum MCPPeerPIDProvenance: Equatable {
    case socketPeer
    case handshakeFallback
}

/// Neutral peer identity produced by the app-proxy transport adapter.
struct MCPPeerIdentity: Equatable {
    let socketObservedPID: Int?
    let handshakeClaimedPID: Int

    /// Trusted process identity for authorization. The handshake PID is diagnostic only.
    var trustedPID: Int? {
        socketObservedPID
    }

    /// Best-effort process identity for diagnostics only. Never use this value for authorization.
    var diagnosticPID: Int {
        socketObservedPID ?? handshakeClaimedPID
    }

    var provenance: MCPPeerPIDProvenance {
        socketObservedPID == nil ? .handshakeFallback : .socketPeer
    }

    static func isValidHandshakeClaimedPID(_ pid: Int) -> Bool {
        pid > 0 && pid <= Int(Int32.max)
    }
}

/// Descriptor-bearing handoff from the macOS app-proxy listener into MCP admission.
/// Raw socket operations remain adapter-owned; policy consumes the normalized identity.
struct MCPAppProxyInboundConnection: Equatable {
    let connectedFileDescriptor: Int32
    let peerIdentity: MCPPeerIdentity
}

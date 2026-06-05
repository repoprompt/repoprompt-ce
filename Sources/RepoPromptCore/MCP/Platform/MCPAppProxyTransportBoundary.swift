import Foundation

/// Origin of the PID used for app-proxy admission policy.
package enum MCPPeerPIDProvenance: Equatable {
    case socketPeer
    case handshakeFallback
}

/// Neutral peer identity produced by the app-proxy transport adapter.
package struct MCPPeerIdentity: Equatable {
    package let socketObservedPID: Int?
    package let handshakeClaimedPID: Int

    package init(socketObservedPID: Int?, handshakeClaimedPID: Int) {
        self.socketObservedPID = socketObservedPID
        self.handshakeClaimedPID = handshakeClaimedPID
    }

    /// Trusted process identity for authorization. The handshake PID is diagnostic only.
    package var trustedPID: Int? {
        socketObservedPID
    }

    /// Best-effort process identity for diagnostics only. Never use this value for authorization.
    package var diagnosticPID: Int {
        socketObservedPID ?? handshakeClaimedPID
    }

    package var provenance: MCPPeerPIDProvenance {
        socketObservedPID == nil ? .handshakeFallback : .socketPeer
    }

    package static func isValidHandshakeClaimedPID(_ pid: Int) -> Bool {
        pid > 0 && pid <= Int(Int32.max)
    }
}

/// Descriptor-bearing handoff from the macOS app-proxy listener into MCP admission.
/// Raw socket operations remain adapter-owned; policy consumes the normalized identity.
package struct MCPAppProxyInboundConnection: Equatable {
    package let connectedFileDescriptor: Int32
    package let peerIdentity: MCPPeerIdentity

    package init(connectedFileDescriptor: Int32, peerIdentity: MCPPeerIdentity) {
        self.connectedFileDescriptor = connectedFileDescriptor
        self.peerIdentity = peerIdentity
    }
}

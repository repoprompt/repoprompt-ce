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

package enum MCPAppProxyAcceptedTransportLeaseState: Equatable {
    case listenerOwned
    case admissionReserved
    case transferred
    case closed
}

/// Opaque accepted transport published synchronously into the host lifecycle ledger.
/// Native descriptors and socket operations remain adapter-owned.
package protocol MCPAppProxyAcceptedTransport: AnyObject, Sendable {
    func close()
}

/// Ownership lease for one accepted app-proxy transport.
///
/// Admission reserves the lease before returning acceptance. After the accepted response is
/// written, the listener transfers the opaque transport into lifecycle-visible storage. Any
/// failed path rolls the lease back and closes the native transport exactly once.
package protocol MCPAppProxyAcceptedTransportLease: AnyObject, Sendable {
    var state: MCPAppProxyAcceptedTransportLeaseState { get }

    func reserveForAdmission() -> Bool
    func transfer(
        publish: @Sendable (any MCPAppProxyAcceptedTransport) -> Bool
    ) -> Bool
    func rollback()
}

/// Opaque handoff from the app-proxy listener into reusable admission policy.
package struct MCPAppProxyInboundConnection {
    package let transportLease: any MCPAppProxyAcceptedTransportLease
    package let peerIdentity: MCPPeerIdentity

    package init(
        transportLease: any MCPAppProxyAcceptedTransportLease,
        peerIdentity: MCPPeerIdentity
    ) {
        self.transportLease = transportLease
        self.peerIdentity = peerIdentity
    }
}

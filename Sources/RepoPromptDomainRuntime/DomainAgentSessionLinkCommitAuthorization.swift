import Foundation

/// One-way revocation fence owned by a single authority link record. It cannot grant authority.
/// The short, synchronous publication body and link revocation use the same lock, so an actor-hop
/// result can never authorize a publication that races behind an already committed revocation.
package final class DomainAgentSessionLinkRevocationFence: @unchecked Sendable {
    private let lock = NSLock()
    private var live = true

    package init() {}

    package func revoke() {
        lock.withLock { live = false }
    }

    fileprivate func withLiveLink<T>(_ body: () throws -> T) throws -> T {
        try lock.withLock {
            guard live else { throw DomainAgentSessionLinkError.linkRevoked }
            return try body()
        }
    }
}

/// Authority-issued proof for synchronous publication after asynchronous preparation. The owning
/// actor alone issues it after validating the exact lease; its link-record fence is never reused
/// for a successor grant. Consent and capability elevation remain live inputs, not cached Bools.
package struct DomainAgentSessionLinkCommitAuthorization {
    package let lease: DomainAgentSessionLinkLease
    private let fence: DomainAgentSessionLinkRevocationFence
    private let grant: DomainAgentSessionLinkGrant
    private let consent: DomainDelegationScopeLinkConsent?
    private let elevation: DomainAgentSessionLinkCapabilityElevation?
    private let now: @Sendable () -> Date

    package init(
        lease: DomainAgentSessionLinkLease,
        fence: DomainAgentSessionLinkRevocationFence,
        grant: DomainAgentSessionLinkGrant,
        consent: DomainDelegationScopeLinkConsent?,
        elevation: DomainAgentSessionLinkCapabilityElevation?,
        now: @escaping @Sendable () -> Date
    ) {
        self.lease = lease
        self.fence = fence
        self.grant = grant
        self.consent = consent
        self.elevation = elevation
        self.now = now
    }

    /// The body must be bounded, synchronous, and must not call back into link authority.
    package func withAuthorization<T>(_ body: () throws -> T) throws -> T {
        try fence.withLiveLink {
            if let scopeID = grant.sourceScopeID {
                guard consent?.permits(scopeID: scopeID, observer: grant.observer.sessionID, target: grant.target.sessionID, at: now()) == true else {
                    throw DomainAgentSessionLinkError.linkRevoked
                }
            }
            guard grant.capabilities.contains(lease.capability)
                || elevation?.isElevated(observer: grant.observer.sessionID) == true
            else {
                throw DomainAgentSessionLinkError.capabilityDenied
            }
            return try body()
        }
    }
}

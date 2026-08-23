import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum PortalNetworkTopology: Sendable, Equatable {
    case directTLS
    case trustedProxy(publicOrigin: String, trustedProxyCIDRs: [String])
}

public struct PortalRequestNetworkIdentity: Sendable, Equatable {
    public let clientAddress: String
    public let publicOrigin: String?
}

public struct PortalNetworkPolicy: Sendable {
    private let topology: PortalNetworkTopology
    private let publicOrigin: URL?
    private let trustedNetworks: [IPNetwork]

    public init(_ topology: PortalNetworkTopology) throws {
        self.topology = topology
        switch topology {
        case .directTLS:
            publicOrigin = nil
            trustedNetworks = []
        case let .trustedProxy(origin, cidrs):
            guard let url = URL(string: origin),
                  url.scheme?.lowercased() == "https",
                  url.host != nil,
                  url.user == nil,
                  url.password == nil,
                  url.path.isEmpty || url.path == "/",
                  url.query == nil,
                  url.fragment == nil
            else {
                throw PortalNetworkPolicyError.invalidPublicOrigin
            }
            guard !cidrs.isEmpty else { throw PortalNetworkPolicyError.missingTrustedProxy }
            publicOrigin = url
            trustedNetworks = try cidrs.map(IPNetwork.init)
        }
    }

    public func resolve(
        immediatePeer: String?,
        forwarded: String?,
        forwardedFor: String?,
        forwardedProto: String?,
        forwardedHost: String?,
        realIP: String?
    ) throws -> PortalRequestNetworkIdentity {
        guard let immediatePeer, IPAddress(immediatePeer) != nil else {
            throw PortalNetworkPolicyError.invalidImmediatePeer
        }
        switch topology {
        case .directTLS:
            guard forwarded == nil, forwardedFor == nil, forwardedProto == nil,
                  forwardedHost == nil, realIP == nil
            else { throw PortalNetworkPolicyError.unexpectedForwardedHeaders }
            return .init(clientAddress: immediatePeer, publicOrigin: nil)
        case .trustedProxy:
            guard trustedNetworks.contains(where: { $0.contains(immediatePeer) }) else {
                throw PortalNetworkPolicyError.untrustedImmediatePeer
            }
            guard forwarded == nil, realIP == nil else {
                throw PortalNetworkPolicyError.ambiguousForwardedHeaders
            }
            let client = try singleValue(forwardedFor)
            let proto = try singleValue(forwardedProto).lowercased()
            let host = try singleValue(forwardedHost).lowercased()
            guard IPAddress(client) != nil else { throw PortalNetworkPolicyError.invalidForwardedClient }
            guard proto == "https" else { throw PortalNetworkPolicyError.invalidForwardedScheme }
            guard let publicOrigin,
                  host == canonicalAuthority(publicOrigin).lowercased()
            else { throw PortalNetworkPolicyError.publicOriginMismatch }
            return .init(clientAddress: client, publicOrigin: canonicalOrigin(publicOrigin))
        }
    }

    private func singleValue(_ value: String?) throws -> String {
        guard let value else { throw PortalNetworkPolicyError.missingForwardedHeaders }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(","), !trimmed.contains(";") else {
            throw PortalNetworkPolicyError.ambiguousForwardedHeaders
        }
        return trimmed
    }

    private func canonicalAuthority(_ url: URL) -> String {
        guard let host = url.host else { return "" }
        if let port = url.port, port != 443 { return "\(host):\(port)" }
        return host
    }

    private func canonicalOrigin(_ url: URL) -> String {
        "https://\(canonicalAuthority(url))"
    }
}

public enum PortalNetworkPolicyError: Error, Sendable, Equatable {
    case invalidPublicOrigin
    case missingTrustedProxy
    case invalidCIDR
    case invalidImmediatePeer
    case unexpectedForwardedHeaders
    case untrustedImmediatePeer
    case ambiguousForwardedHeaders
    case missingForwardedHeaders
    case invalidForwardedClient
    case invalidForwardedScheme
    case publicOriginMismatch
}

private struct IPNetwork: Sendable {
    let address: IPAddress
    let prefix: Int

    init(_ value: String) throws {
        let pieces = value.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count == 2,
              let address = IPAddress(String(pieces[0])),
              let prefix = Int(pieces[1]),
              (0 ... address.bytes.count * 8).contains(prefix)
        else { throw PortalNetworkPolicyError.invalidCIDR }
        self.address = address
        self.prefix = prefix
    }

    func contains(_ value: String) -> Bool {
        guard let candidate = IPAddress(value), candidate.bytes.count == address.bytes.count else { return false }
        let fullBytes = prefix / 8
        let remainingBits = prefix % 8
        guard candidate.bytes.prefix(fullBytes).elementsEqual(address.bytes.prefix(fullBytes)) else { return false }
        guard remainingBits > 0 else { return true }
        let mask = UInt8(0xff << (8 - remainingBits))
        return candidate.bytes[fullBytes] & mask == address.bytes[fullBytes] & mask
    }
}

private struct IPAddress: Sendable {
    let bytes: [UInt8]

    init?(_ value: String) {
        var v4 = in_addr()
        if value.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            bytes = withUnsafeBytes(of: &v4) { Array($0) }
            return
        }
        var v6 = in6_addr()
        if value.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 {
            bytes = withUnsafeBytes(of: &v6) { Array($0) }
            return
        }
        return nil
    }
}

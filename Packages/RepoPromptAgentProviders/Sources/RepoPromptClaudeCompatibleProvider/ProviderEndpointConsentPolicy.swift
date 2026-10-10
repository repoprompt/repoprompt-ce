import Foundation

/// Consent for the intended endpoint only. This does not control redirects, proxies,
/// DNS, or the external provider runtime's networking behavior.
public enum ProviderEndpointConsentPolicy {
    public enum ValidationError: Error, LocalizedError {
        case invalidEndpoint
        case consentRequired

        public var errorDescription: String? {
            switch self {
            case .invalidEndpoint:
                "Provider endpoint must be an HTTP or HTTPS URL without embedded credentials."
            case .consentRequired:
                "Sending credentials to a remote HTTP endpoint requires explicit consent in provider settings. Use HTTPS or acknowledge the cleartext risk for this endpoint."
            }
        }
    }

    public static func endpointIdentity(_ raw: String) -> String? {
        guard var components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty, !host.contains(where: \.isWhitespace),
              components.user == nil, components.password == nil,
              components.fragment == nil
        else { return nil }
        components.scheme = scheme
        components.percentEncodedHost = components.percentEncodedHost?.lowercased()
        while components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        return components.url?.absoluteString
    }

    /// Literal classification preserves local-server compatibility; it is NOT a
    /// guarantee that a request stays local (for example through runtime proxies).
    public static func isLiteralLoopback(_ host: String) -> Bool {
        let host = host.lowercased()
        if host == "localhost" || host == "::1" || host == "[::1]" { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "127" else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isASCII && $0.isNumber }
                && (part.count == 1 || part.first != "0")
                && UInt8(part) != nil
        }
    }

    public static func isRemoteHTTP(_ raw: String) -> Bool {
        guard let identity = endpointIdentity(raw), let url = URL(string: identity),
              url.scheme == "http", let host = url.host
        else { return false }
        return !isLiteralLoopback(host)
    }

    public static func validate(_ raw: String, credentialBearing: Bool, consentEndpoint: String?) throws {
        guard let identity = endpointIdentity(raw) else { throw ValidationError.invalidEndpoint }
        if credentialBearing, isRemoteHTTP(identity), consentEndpoint != identity {
            throw ValidationError.consentRequired
        }
    }
}

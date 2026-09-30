import Foundation

enum ExternalMCPRuntimeConnectionState: String, Codable, Equatable {
    case disconnected
    case connecting
    case connected
    case unavailable
    case failed
}

enum ExternalMCPAuthenticationState: String, Codable, Equatable {
    case unknown
    case unauthenticated
    case authenticated
    case expired
    case providerOwned
    case unsupported
}

/// Transient state safe for presentation. It contains no URL, headers, account identity, raw
/// provider payload, command, argument, or credential fields.
struct ExternalMCPRuntimeSnapshot: Codable, Equatable {
    static let maximumToolCount = 128
    static let maximumToolLabelLength = 80
    static let maximumDiagnosticLength = 240
    static let maximumDiagnosticCount = 8

    let integrationID: ExternalMCPIntegrationID
    let connection: ExternalMCPRuntimeConnectionState
    let authentication: ExternalMCPAuthenticationState
    let verifiedAt: Date?
    let toolCount: Int?
    let toolLabels: [String]
    let diagnostics: [String]

    init(
        integrationID: ExternalMCPIntegrationID,
        connection: ExternalMCPRuntimeConnectionState,
        authentication: ExternalMCPAuthenticationState,
        verifiedAt: Date? = nil,
        toolCount: Int? = nil,
        toolLabels: [String] = [],
        diagnostics: [String] = []
    ) {
        self.integrationID = integrationID
        self.connection = connection
        self.authentication = authentication
        self.verifiedAt = verifiedAt
        self.toolCount = toolCount.map { max(0, min(Self.maximumToolCount, $0)) }
        self.toolLabels = Self.sanitizeLabels(toolLabels)
        self.diagnostics = Self.sanitizeDiagnostics(diagnostics)
    }

    static func disconnected(integrationID: ExternalMCPIntegrationID) -> Self {
        Self(integrationID: integrationID, connection: .disconnected, authentication: .unknown)
    }

    private static func sanitizeLabels(_ labels: [String]) -> [String] {
        var seen = Set<String>()
        return labels.compactMap { raw in
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.count <= maximumToolLabelLength,
                  value.unicodeScalars.allSatisfy({ scalar in
                      scalar == "_" || scalar == "-" || scalar == "."
                          || CharacterSet.alphanumerics.contains(scalar)
                  }), seen.insert(value).inserted
            else { return nil }
            return value
        }.prefix(maximumToolCount).map(\.self)
    }

    private static func sanitizeDiagnostics(_ diagnostics: [String]) -> [String] {
        diagnostics.compactMap { raw in
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.count <= maximumDiagnosticLength,
                  !value.localizedCaseInsensitiveContains("token"),
                  !value.localizedCaseInsensitiveContains("secret"),
                  !value.localizedCaseInsensitiveContains("oauth"),
                  !value.contains("http://"), !value.contains("https://")
            else { return nil }
            return value
        }.prefix(maximumDiagnosticCount).map(\.self)
    }
}

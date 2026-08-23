import Foundation

public enum ProviderSecretRedaction {
    private static let patterns = [
        #"(?i)\bauthorization\s*[:=]\s*(?:bearer|basic)\s+[\"']?[^\s,;}\"']+"#,
        #"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]{8,}"#,
        #"(?i)[\"']?(?:access[_-]?token|auth[_-]?token|api[_-]?key|apikey|secret|password)[\"']?\s*[:=]\s*[\"']?[^\s,;}\"']{8,}"#,
        #"(?i)\b(?:sk-(?:proj-|ant-)?|xai-|cursor-|anthropic-)[A-Za-z0-9._-]{8,}"#,
        #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"#
    ]

    public static func redact(_ value: String, knownSecrets: [String] = []) -> String {
        var result = value
        for secret in knownSecrets.filter({ !$0.isEmpty }).sorted(by: { $0.count > $1.count }) {
            result = result.replacingOccurrences(of: secret, with: "<redacted>")
        }
        for pattern in patterns {
            result = result.replacingOccurrences(of: pattern, with: "<redacted>", options: .regularExpression)
        }
        return result
    }

    public static func containsLikelySecret(_ value: String) -> Bool {
        redact(value) != value
    }
}

public enum ProviderConnectionState: String, Codable, Hashable, Sendable {
    case connected
    case attention
    case disconnected
}

public enum ProviderCredentialTestState: String, Codable, Hashable, Sendable {
    case notTested
    case valid
    case invalid
    case unavailable
}

/// Safe, durable metadata for a provider connection. Credential material and
/// vault references intentionally are not part of this client-facing type.
public struct ProviderConnectionRecord: Codable, Hashable, Sendable {
    public let connectionID: UUID
    public let providerID: ProviderSettingsID
    public let authenticationMethod: ProviderAuthenticationMethod
    public let state: ProviderConnectionState
    public let accountLabel: String?
    public let expiresAt: Date?
    public let lastTestedAt: Date?
    public let testState: ProviderCredentialTestState
    public let detail: String?
    public let keyHelperConfigured: Bool
    public let workloadIdentityConfigured: Bool
    public let createdAt: Date
    public let updatedAt: Date
    public let revision: Int64

    public init(
        connectionID: UUID,
        providerID: ProviderSettingsID,
        authenticationMethod: ProviderAuthenticationMethod,
        state: ProviderConnectionState,
        accountLabel: String? = nil,
        expiresAt: Date? = nil,
        lastTestedAt: Date? = nil,
        testState: ProviderCredentialTestState = .notTested,
        detail: String? = nil,
        keyHelperConfigured: Bool = false,
        workloadIdentityConfigured: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        revision: Int64 = 1
    ) {
        self.connectionID = connectionID
        self.providerID = providerID
        self.authenticationMethod = authenticationMethod
        self.state = state
        self.accountLabel = accountLabel
        self.expiresAt = expiresAt
        self.lastTestedAt = lastTestedAt
        self.testState = testState
        self.detail = detail
        self.keyHelperConfigured = keyHelperConfigured
        self.workloadIdentityConfigured = workloadIdentityConfigured
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.revision = revision
    }
}

/// Explicit enable/disable operation input. Model and control defaults remain
/// unchanged; optimistic concurrency still fences stale administrators.
public struct SetProviderEnabledRequest: Codable, Hashable, Sendable {
    public let expectedRevision: Int64

    public init(expectedRevision: Int64) {
        self.expectedRevision = expectedRevision
    }
}

public enum ProviderAvailabilityReason: String, Codable, Hashable, Sendable {
    case ready
    case disabled
    case deploymentDisabled
    case missingExecutable
    case missingCredential
    case invalidCredential
    case authenticationPending
    case unsupportedModel
    case unsupportedControl
    case runtimeUnavailable
}

public struct ProviderPreflightStatus: Codable, Hashable, Sendable {
    public let ready: Bool
    public let reason: ProviderAvailabilityReason
    public let detail: String

    public init(ready: Bool, reason: ProviderAvailabilityReason, detail: String) {
        self.ready = ready
        self.reason = reason
        self.detail = detail
    }
}

public struct ProviderMutationAttribution: Codable, Hashable, Sendable {
    public let actorID: String
    public let actorLabel: String
    public let channel: String

    public init(actorID: String, actorLabel: String, channel: String) {
        self.actorID = actorID
        self.actorLabel = actorLabel
        self.channel = channel
    }
}

public struct ProviderCredentialTestResult: Codable, Hashable, Sendable {
    public let state: ProviderCredentialTestState
    public let detail: String
    public let accountLabel: String?
    public let expiresAt: Date?
    /// Sanitized discovery result. Credentials, response headers, and raw
    /// provider payloads must never enter this projection.
    public let models: [ProviderModelCatalogEntry]?

    public init(
        state: ProviderCredentialTestState,
        detail: String,
        accountLabel: String? = nil,
        expiresAt: Date? = nil,
        models: [ProviderModelCatalogEntry]? = nil
    ) {
        self.state = state
        self.detail = detail
        self.accountLabel = accountLabel
        self.expiresAt = expiresAt
        self.models = models
    }
}

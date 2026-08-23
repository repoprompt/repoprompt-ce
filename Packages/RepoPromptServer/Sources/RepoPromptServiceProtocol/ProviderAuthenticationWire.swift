import Foundation
import RepoPromptRuntimeModel

/// Write-only credential input owned by the Server wire boundary. Credential
/// material is projected into the runtime input and is never echoed.
public struct ConnectProviderRequest: Codable, Sendable {
    public let authenticationMethod: ProviderAuthenticationMethod
    public let credential: String?
    public let accountLabel: String?
    public let expiresAt: Date?
    public let keyHelperCommand: String?
    public let workloadIdentityProvider: String?
    public let workloadIdentityServiceAccount: String?

    public init(
        authenticationMethod: ProviderAuthenticationMethod,
        credential: String? = nil,
        accountLabel: String? = nil,
        expiresAt: Date? = nil,
        keyHelperCommand: String? = nil,
        workloadIdentityProvider: String? = nil,
        workloadIdentityServiceAccount: String? = nil
    ) {
        self.authenticationMethod = authenticationMethod
        self.credential = credential
        self.accountLabel = accountLabel
        self.expiresAt = expiresAt
        self.keyHelperCommand = keyHelperCommand
        self.workloadIdentityProvider = workloadIdentityProvider
        self.workloadIdentityServiceAccount = workloadIdentityServiceAccount
    }
}

public struct StartProviderAuthFlowRequest: Codable, Hashable, Sendable {
    public let kind: ProviderAuthFlowKind

    public init(kind: ProviderAuthFlowKind) {
        self.kind = kind
    }
}

public enum ProviderAuthTransactionState: String, Codable, Hashable, Sendable {
    case pending
    case completed
    case failed
    case cancelled
    case expired
}

/// Browser-safe transient projection. It intentionally has no generic payload
/// or token-shaped metadata field.
public struct ProviderAuthTransactionStatus: Codable, Hashable, Sendable {
    public let flowID: UUID
    public let providerID: ProviderSettingsID
    public let kind: ProviderAuthFlowKind
    public let state: ProviderAuthTransactionState
    public let userCode: String?
    public let verificationURL: URL?
    public let expiresAt: Date
    public let detail: String?

    public init(
        flowID: UUID,
        providerID: ProviderSettingsID,
        kind: ProviderAuthFlowKind,
        state: ProviderAuthTransactionState,
        userCode: String? = nil,
        verificationURL: URL? = nil,
        expiresAt: Date,
        detail: String? = nil
    ) {
        self.flowID = flowID
        self.providerID = providerID
        self.kind = kind
        self.state = state
        self.userCode = userCode
        self.verificationURL = verificationURL
        self.expiresAt = expiresAt
        self.detail = detail
    }
}

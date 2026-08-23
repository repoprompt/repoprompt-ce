import Foundation
import HTTPTypes

public enum InternalRouteRole: String, Codable, Sendable {
    case app
    case sync
    case operatorRole = "repoprompt-operator"
}

public enum InternalHMACDirection {
    public static let appToRepoPrompt = "app-to-repoprompt-v1"
    public static let syncToRepoPrompt = "sync-to-repoprompt-v1"
    public static let operatorToRepoPrompt = "repoprompt-operator-to-repoprompt-v1"
    public static let repoPromptToClient = "repoprompt-to-client-v1"
}

public struct InternalSigningKey: Sendable {
    public let keyID: String
    public let role: InternalRouteRole
    public let direction: String
    public let secret: Data
    public let active: Bool

    public init(
        keyID: String,
        role: InternalRouteRole,
        direction: String,
        secret: Data,
        active: Bool = true
    ) {
        self.keyID = keyID
        self.role = role
        self.direction = direction
        self.secret = secret
        self.active = active
    }
}

public extension HTTPField.Name {
    static let internalKeyID = Self("x-internal-key-id")!
    static let internalTimestamp = Self("x-internal-timestamp")!
    static let internalNonce = Self("x-internal-nonce")!
    static let internalBodyDigest = Self("x-internal-body-digest")!
    static let internalAuthorizationDigest = Self("x-internal-authorization-digest")!
    static let internalSignature = Self("x-internal-signature")!
    static let authorizationDecision = Self("X-RepoPrompt-Authorization-Decision")!
    static let idempotencyKey = Self("Idempotency-Key")!
}

import Foundation

public struct ServiceCursor: Codable, Hashable, Sendable, Comparable {
    public let storeID: UUID
    public let globalSequence: Int64

    private enum CodingKeys: String, CodingKey {
        case storeID = "storeId"
        case globalSequence
    }

    public init(storeID: UUID, globalSequence: Int64) {
        self.storeID = storeID
        self.globalSequence = globalSequence
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        precondition(lhs.storeID == rhs.storeID, "cursors from different stores are not comparable")
        return lhs.globalSequence < rhs.globalSequence
    }
}

public struct ExternalActor: Codable, Hashable, Sendable {
    public let userID: String
    public let username: String
    public let displayName: String

    private enum CodingKeys: String, CodingKey {
        case userID = "userId"
        case username, displayName
    }

    public init(userID: String, username: String, displayName: String) {
        self.userID = userID
        self.username = username
        self.displayName = displayName
    }
}

public enum Visibility: String, Codable, Sendable { case privateSession = "private", collaborative }
public enum ProviderKind: String, Codable, CaseIterable, Sendable { case codex, claudeCompatible, openCodeACP, cursorACP, grokBuildACP, headlessAdapter, mcp }
public enum SessionLifecycleState: String, Codable, Sendable { case preparing, idle, running, waiting, completed, failed, canceled, interrupted, archived }
public enum ProjectLifecycleState: String, Codable, Sendable { case active, degraded, archived }

public struct AuthorizationDecision: Codable, Hashable, Sendable {
    public struct AttributionLabels: Codable, Hashable, Sendable {
        public let creatorUserID: String?
        public let controllerUserID: String?
        public let visibility: Visibility?

        public init(creatorUserID: String? = nil, controllerUserID: String? = nil, visibility: Visibility? = nil) {
            self.creatorUserID = creatorUserID
            self.controllerUserID = controllerUserID
            self.visibility = visibility
        }

        private enum CodingKeys: String, CodingKey {
            case creatorUserID = "creatorUserId"
            case controllerUserID = "controllerUserId"
            case visibility
        }
    }

    public let schemaVersion: Int
    public let decisionID: UUID
    public let actor: ExternalActor
    public let sessionID: UUID?
    public let projectID: UUID?
    public let operation: String
    public let requestDigest: String
    public let policyRevision: Int64
    public let controllerRevision: Int64
    public let membershipRevision: Int64
    public let attributionLabels: AttributionLabels?
    public let issuedAt: Date
    public let expiresAt: Date
    public let requestID: UUID
    public let correlationID: UUID
    public let keyID: String
    public let signature: String

    public init(
        decisionID: UUID,
        actor: ExternalActor,
        sessionID: UUID? = nil,
        projectID: UUID? = nil,
        operation: String,
        requestDigest: String,
        policyRevision: Int64,
        controllerRevision: Int64,
        membershipRevision: Int64,
        attributionLabels: AttributionLabels? = nil,
        issuedAt: Date,
        expiresAt: Date,
        requestID: UUID,
        correlationID: UUID,
        keyID: String,
        signature: String
    ) {
        schemaVersion = 1
        self.decisionID = decisionID
        self.actor = actor
        self.sessionID = sessionID
        self.projectID = projectID
        self.operation = operation
        self.requestDigest = requestDigest
        self.policyRevision = policyRevision
        self.controllerRevision = controllerRevision
        self.membershipRevision = membershipRevision
        self.attributionLabels = attributionLabels
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.requestID = requestID
        self.correlationID = correlationID
        self.keyID = keyID
        self.signature = signature
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case decisionID = "decisionId"
        case actor
        case sessionID = "sessionId"
        case projectID = "projectId"
        case operation, requestDigest, policyRevision, controllerRevision, membershipRevision, attributionLabels, issuedAt, expiresAt
        case requestID = "requestId"
        case correlationID = "correlationId"
        case keyID = "keyId"
        case signature
    }
}

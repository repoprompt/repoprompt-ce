import Foundation
import HTTPTypes
import Hummingbird
import RepoPromptServiceHTTP
import RepoPromptServicePersistence
import RepoPromptServiceProtocol

public struct SignedInternalRequest: Sendable {
    public let method: String
    public let pathAndQuery: String
    public let timestamp: String
    public let nonce: String
    public let body: Data
    public let bodyDigest: String
    public let authorizationDecisionData: Data?
    public let authorizationDecisionDigest: String?
    public let keyID: String
    public let signature: String
    public init(method: String, pathAndQuery: String, timestamp: String, nonce: String, body: Data, bodyDigest: String, authorizationDecisionData: Data?, authorizationDecisionDigest: String?, keyID: String, signature: String) {
        self.method = method
        self.pathAndQuery = pathAndQuery
        self.timestamp = timestamp
        self.nonce = nonce
        self.body = body
        self.bodyDigest = bodyDigest
        self.authorizationDecisionData = authorizationDecisionData
        self.authorizationDecisionDigest = authorizationDecisionDigest
        self.keyID = keyID
        self.signature = signature
    }
}

public struct AuthenticatedInternalRequest: Sendable {
    public let role: InternalRouteRole
    public let keyID: String
    public let decision: AuthorizationDecision?
}

public actor InternalRequestAuthenticator {
    private let keys: [String: InternalSigningKey]
    private let store: SQLiteServiceStore
    private let now: @Sendable () -> Date

    public init(keys: [InternalSigningKey], store: SQLiteServiceStore, now: @escaping @Sendable () -> Date = Date.init) {
        self.keys = Dictionary(uniqueKeysWithValues: keys.map { ($0.keyID, $0) })
        self.store = store
        self.now = now
    }

    public func verify(_ request: SignedInternalRequest, allowedRoles: Set<InternalRouteRole>, operation: String, projectID: UUID? = nil, sessionID: UUID? = nil) async throws -> AuthenticatedInternalRequest {
        guard let key = keys[request.keyID], allowedRoles.contains(key.role) else { throw ServiceAPIError(code: .internalAuthFailed, message: "Signing identity is not allowed for this route") }
        guard request.nonce.range(of: "^[A-Za-z0-9_-]{16,128}$", options: .regularExpression) != nil else { throw ServiceAPIError(code: .internalAuthFailed, message: "Nonce format is invalid") }
        guard let signedAt = CanonicalSigning.parseISO8601(request.timestamp) else { throw ServiceAPIError(code: .internalAuthFailed, message: "Timestamp is invalid") }
        let observed = now()
        guard abs(observed.timeIntervalSince(signedAt)) <= 5 else { throw ServiceAPIError(code: .internalAuthFailed, message: "Timestamp is outside the allowed skew") }
        let computedBodyDigest = CanonicalSigning.bodyDigest(request.body)
        guard request.bodyDigest == computedBodyDigest else { throw ServiceAPIError(code: .internalAuthFailed, message: "Body digest does not match") }
        let decisionDigest = CanonicalSigning.bodyDigest(request.authorizationDecisionData ?? Data())
        guard (request.authorizationDecisionDigest ?? CanonicalSigning.bodyDigest(Data())) == decisionDigest else { throw ServiceAPIError(code: .internalAuthFailed, message: "Authorization decision digest does not match") }
        let canonical = CanonicalSigning.requestString(method: request.method, pathAndQuery: request.pathAndQuery, timestamp: request.timestamp, nonce: request.nonce, bodyDigest: request.bodyDigest, authorizationDecisionDigest: decisionDigest, keyID: request.keyID)
        let expected = CanonicalSigning.hmacSHA256(message: canonical, key: key.secret)
        guard CanonicalSigning.secureEquals(expected, request.signature) else { throw ServiceAPIError(code: .internalAuthFailed, message: "Request signature is invalid") }
        try await store.consumeNonce(direction: key.direction, keyID: key.keyID, nonce: request.nonce, observedAt: observed, expiresAt: observed.addingTimeInterval(60))

        if key.role == .app {
            guard let data = request.authorizationDecisionData else { throw ServiceAPIError(code: .authorizationDecisionRejected, message: "An authorization decision is required") }
            let decision = try JSONDecoder.serviceDecoder.decode(AuthorizationDecision.self, from: data)
            guard decision.schemaVersion == 1, decision.operation == operation, decision.projectID == projectID, decision.sessionID == sessionID else { throw ServiceAPIError(code: .authorizationDecisionRejected, message: "Authorization decision target or operation does not match") }
            guard decision.requestDigest == CanonicalSigning.bodyDigest(request.body), decision.expiresAt >= observed, decision.issuedAt <= observed, decision.expiresAt.timeIntervalSince(decision.issuedAt) <= 30 else { throw ServiceAPIError(code: .authorizationDecisionRejected, message: "Authorization decision is stale or request-mismatched") }
            let unsigned = try CanonicalSigning.canonicalJSONObject(data, removingTopLevelKeys: ["signature"])
            let decisionSignature = CanonicalSigning.hmacSHA256(message: unsigned, key: key.secret)
            guard decision.keyID == key.keyID, CanonicalSigning.secureEquals(decisionSignature, decision.signature) else { throw ServiceAPIError(code: .authorizationDecisionRejected, message: "Authorization decision signature is invalid") }
            try await store.consumeAuthorizationDecision(decision)
            return AuthenticatedInternalRequest(role: key.role, keyID: key.keyID, decision: decision)
        }
        return AuthenticatedInternalRequest(role: key.role, keyID: key.keyID, decision: nil)
    }
}

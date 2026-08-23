import Foundation
import Hummingbird
import RepoPromptServiceProtocol

public struct InternalResponseSigner: Sendable {
    private let key: InternalSigningKey
    private let now: @Sendable () -> Date
    private let nonce: @Sendable () -> String

    public init(
        key: InternalSigningKey,
        now: @escaping @Sendable () -> Date = Date.init,
        nonce: @escaping @Sendable () -> String = { CanonicalSigning.randomNonce() }
    ) {
        self.key = key
        self.now = now
        self.nonce = nonce
    }

    public func sign(_ response: Response, requestPathAndQuery: String) -> Response {
        var response = response
        let bodyDigest = response.headers[.internalBodyDigest] ?? CanonicalSigning.bodyDigest(Data())
        let timestamp = CanonicalSigning.iso8601String(now())
        let nonce = nonce()
        let canonical = CanonicalSigning.requestString(
            method: "RESPONSE",
            pathAndQuery: "\(requestPathAndQuery)#\(response.status.code)",
            timestamp: timestamp,
            nonce: nonce,
            bodyDigest: bodyDigest,
            authorizationDecisionDigest: CanonicalSigning.bodyDigest(Data()),
            keyID: key.keyID
        )
        response.headers[.internalTimestamp] = timestamp
        response.headers[.internalNonce] = nonce
        response.headers[.internalKeyID] = key.keyID
        response.headers[.internalSignature] = CanonicalSigning.hmacSHA256(message: canonical, key: key.secret)
        return response
    }
}

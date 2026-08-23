import Foundation

public struct ServiceEventSigningKey: Sendable {
    public let keyID: String
    public let secret: Data

    public init(keyID: String, secret: Data) {
        self.keyID = keyID
        self.secret = secret
    }
}

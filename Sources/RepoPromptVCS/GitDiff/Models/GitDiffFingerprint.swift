import Foundation

public struct GitDiffFingerprint: Codable, Sendable {
    public let headSHA: String
    public let baseRef: String
    public let statusHash: String
    public let generatedAt: Date

    public init(headSHA: String, baseRef: String, statusHash: String, generatedAt: Date) {
        self.headSHA = headSHA
        self.baseRef = baseRef
        self.statusHash = statusHash
        self.generatedAt = generatedAt
    }
}

extension GitDiffFingerprint: Equatable {
    public static func == (lhs: GitDiffFingerprint, rhs: GitDiffFingerprint) -> Bool {
        lhs.headSHA == rhs.headSHA
            && lhs.baseRef == rhs.baseRef
            && lhs.statusHash == rhs.statusHash
    }
}

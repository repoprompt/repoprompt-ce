import Crypto
import Foundation
import RepoPromptRuntimeModel

public struct MigrationSourceEvidence: Codable, Equatable, Sendable {
    public let storeID: UUID
    public let schemaVersion: Int
    public let nextGlobalSequence: Int64
    public let sqliteSHA256: String
    public let migrationLedgerSHA256: String

    public init(
        storeID: UUID,
        schemaVersion: Int,
        nextGlobalSequence: Int64,
        sqliteSHA256: String,
        migrationLedgerSHA256: String
    ) {
        self.storeID = storeID
        self.schemaVersion = schemaVersion
        self.nextGlobalSequence = nextGlobalSequence
        self.sqliteSHA256 = sqliteSHA256
        self.migrationLedgerSHA256 = migrationLedgerSHA256
    }
}

public struct VerifiedMigrationBackup: Sendable {
    public let source: MigrationSourceEvidence
    public let archiveSHA256: String
    public let manifestSHA256: String
    public let verifierFingerprint: String
    public let recipientFingerprints: [String]
    public let sidecarSHA256: String
    public let toolVersion: String
    public let toolDigest: String

    public init(
        source: MigrationSourceEvidence,
        archiveSHA256: String,
        manifestSHA256: String,
        verifierFingerprint: String,
        recipientFingerprints: [String],
        sidecarSHA256: String,
        toolVersion: String,
        toolDigest: String
    ) {
        self.source = source
        self.archiveSHA256 = archiveSHA256
        self.manifestSHA256 = manifestSHA256
        self.verifierFingerprint = verifierFingerprint
        self.recipientFingerprints = recipientFingerprints
        self.sidecarSHA256 = sidecarSHA256
        self.toolVersion = toolVersion
        self.toolDigest = toolDigest
    }
}

enum MigrationEvidenceDigest {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

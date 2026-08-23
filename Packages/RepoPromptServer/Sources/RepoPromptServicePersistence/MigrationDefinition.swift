import Crypto
import Foundation

/// Immutable, data-only migration identity. The ledger digest is derived from
/// the checked-in SQL/transformation program rather than a descriptive label.
struct MigrationDefinition: Sendable {
    let version: Int
    let transformationID: String
    let statements: [String]
    let transformationSteps: [String]

    /// Recomputed identity used to verify the frozen ledger constant in tests.
    /// Production ledger admission uses the checked-in constant, so changing a
    /// historical statement cannot silently redefine accepted history.
    var computedDigest: String {
        var material = "repoprompt-schema-migration-v1\u{0}\(version)\u{0}\(transformationID)"
        for statement in statements {
            material += "\u{0}sql\u{0}\(statement.utf8.count)\u{0}\(statement)"
        }
        for step in transformationSteps {
            material += "\u{0}transform\u{0}\(step.utf8.count)\u{0}\(step)"
        }
        return "sha256:" + SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

enum MigrationLedgerPolicy {
    static var acceptedDigests: [Int: Set<String>] {
        [
            SchemaV1.version: [SchemaV1.digest, SchemaV1.legacyCanonicalDigest, SchemaV1.canonicalDigest],
            SchemaV2.version: [SchemaV2.digest, SchemaV2.canonicalDigest],
            SchemaV3.version: [SchemaV3.digest, SchemaV3.legacyCanonicalDigest, SchemaV3.canonicalDigest],
            SchemaV4.version: [SchemaV4.digest, SchemaV4.legacyCanonicalDigest, SchemaV4.canonicalDigest],
            SchemaV5.version: [SchemaV5.digest, SchemaV5.legacyCanonicalDigest, SchemaV5.canonicalDigest],
            SchemaV6.version: SchemaV7.knownPrototypeV6Digests.union([SchemaV6.legacyCanonicalDigest, SchemaV6.canonicalDigest]),
            SchemaV7.version: [
                SchemaV7.digest,
                SchemaV7.legacyCanonicalDigest,
                SchemaV7.preHistoricalProgramCanonicalDigest,
                SchemaV7.preCollaborationRebuildCanonicalDigest,
                SchemaV7.canonicalDigest,
            ],
        ]
    }

    static func accepts(version: Int, digest: String) -> Bool {
        acceptedDigests[version]?.contains(digest) == true
    }
}

struct LegacyColumnDefinition: Sendable, Equatable {
    let table: String
    let column: String
    let definition: String

    var identity: String {
        "add-column-if-missing:\(table):\(column):\(definition)"
    }
}

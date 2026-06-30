import CryptoKit
import Foundation

struct CodeMapSelectionGraphContribution: Hashable {
    static let currentSchemaVersion: UInt32 = 1
    static let currentPolicyVersion: UInt32 = 1

    private static let digestDomain = "codemap-selection-graph-contribution-v1"

    let schemaVersion: UInt32
    let policyVersion: UInt32
    let artifactKey: CodeMapArtifactKey
    let sortedUniqueDefinitions: [String]
    let sortedUniqueReferences: [String]
    let contributionDigest: CodeMapSHA256Digest

    init(artifactKey: CodeMapArtifactKey, artifact: CodeMapSyntaxArtifact) {
        self.init(
            artifactKey: artifactKey,
            definitions: artifact.definedTypeNames,
            references: artifact.referencedTypes
        )
    }

    init(
        artifactKey: CodeMapArtifactKey,
        definitions: some Sequence<String>,
        references: some Sequence<String>
    ) {
        let definitions = Self.canonicalNames(definitions)
        let references = Self.canonicalNames(references)

        schemaVersion = Self.currentSchemaVersion
        policyVersion = Self.currentPolicyVersion
        self.artifactKey = artifactKey
        sortedUniqueDefinitions = definitions
        sortedUniqueReferences = references
        contributionDigest = Self.digest(
            artifactKey: artifactKey,
            definitions: definitions,
            references: references
        )
    }

    /// Graph names preserve case, normalize to NFC, deduplicate after normalization, and
    /// sort by the normalized UTF-8 bytes. This policy is independent of locale and input order.
    private static func canonicalNames(_ names: some Sequence<String>) -> [String] {
        Set(names.lazy.map(\.precomposedStringWithCanonicalMapping)).sorted { lhs, rhs in
            lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
        }
    }

    private static func digest(
        artifactKey: CodeMapArtifactKey,
        definitions: [String],
        references: [String]
    ) -> CodeMapSHA256Digest {
        var writer = CodeMapSelectionGraphContributionCanonicalWriter()
        writer.appendString(digestDomain)
        writer.append(currentSchemaVersion)
        writer.append(currentPolicyVersion)
        writer.appendData(artifactKey.canonicalBytes)
        writer.appendStrings(definitions)
        writer.appendStrings(references)
        return try! CodeMapSHA256Digest(bytes: Data(SHA256.hash(data: writer.data)))
    }
}

private struct CodeMapSelectionGraphContributionCanonicalWriter {
    private(set) var data = Data()

    mutating func appendStrings(_ values: [String]) {
        precondition(values.count <= Int(UInt32.max))
        append(UInt32(values.count))
        for value in values {
            appendString(value)
        }
    }

    mutating func appendString(_ value: String) {
        appendData(Data(value.utf8))
    }

    mutating func appendData(_ value: Data) {
        precondition(value.count <= Int(UInt32.max))
        append(UInt32(value.count))
        data.append(value)
    }

    mutating func append(_ value: UInt32) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }
}

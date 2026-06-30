import CryptoKit
import Foundation

enum CodeMapRootManifestModelError: Error, Equatable {
    case invalidNamespace
    case invalidWorktreeIdentity
    case invalidRelativePath
    case invalidAuthority
    case invalidMode
    case invalidContribution
    case artifactKeyMismatch
    case inputTooLarge
    case corruptRecord
    case staleAuthority
}

/// A Git-only manifest namespace. The shared repository namespace permits CAS/locator reuse,
/// while the exact worktree and loaded-root prefix deliberately prevent manifest reuse.
struct CodeMapRootManifestNamespace: Hashable {
    static let currentSchemaVersion: UInt32 = 1
    static let currentPolicyVersion: UInt32 = 1
    static let maximumCanonicalByteCount = 64 * 1024

    private static let domain = "codemap-root-manifest-namespace-v1"

    let repositoryNamespace: GitBlobRepositoryNamespace
    let worktreeIdentity: String
    let repositoryRelativeLoadedRootPrefix: String
    let objectFormat: GitObjectFormat
    let schemaVersion: UInt32
    let policyVersion: UInt32
    let pipelineIdentity: CodeMapPipelineIdentity
    let repositoryBindingEpoch: String
    let worktreeBindingEpoch: String

    init(
        repositoryNamespace: GitBlobRepositoryNamespace,
        worktreeIdentity: String,
        repositoryRelativeLoadedRootPrefix: String,
        objectFormat: GitObjectFormat,
        schemaVersion: UInt32 = Self.currentSchemaVersion,
        policyVersion: UInt32 = Self.currentPolicyVersion,
        pipelineIdentity: CodeMapPipelineIdentity,
        repositoryBindingEpoch: String,
        worktreeBindingEpoch: String
    ) throws {
        guard Self.isWorktreeIdentity(worktreeIdentity) else {
            throw CodeMapRootManifestModelError.invalidWorktreeIdentity
        }
        guard Self.isRepositoryRelativePath(repositoryRelativeLoadedRootPrefix, allowEmpty: true) else {
            throw CodeMapRootManifestModelError.invalidRelativePath
        }
        guard schemaVersion > 0,
              policyVersion > 0,
              Self.isBoundedAuthorityString(repositoryBindingEpoch),
              Self.isBoundedAuthorityString(worktreeBindingEpoch)
        else {
            throw CodeMapRootManifestModelError.invalidNamespace
        }
        self.repositoryNamespace = repositoryNamespace
        self.worktreeIdentity = worktreeIdentity
        self.repositoryRelativeLoadedRootPrefix = repositoryRelativeLoadedRootPrefix
        self.objectFormat = objectFormat
        self.schemaVersion = schemaVersion
        self.policyVersion = policyVersion
        self.pipelineIdentity = pipelineIdentity
        self.repositoryBindingEpoch = repositoryBindingEpoch
        self.worktreeBindingEpoch = worktreeBindingEpoch
        guard canonicalBytes.count <= Self.maximumCanonicalByteCount else {
            throw CodeMapRootManifestModelError.inputTooLarge
        }
    }

    init(capability: GitCodemapRootCapability, pipelineIdentity: CodeMapPipelineIdentity) throws {
        try self.init(
            repositoryNamespace: capability.repositoryNamespace,
            worktreeIdentity: capability.worktreeID,
            repositoryRelativeLoadedRootPrefix: capability.repositoryRelativeLoadedRootPrefix,
            objectFormat: capability.objectFormat,
            pipelineIdentity: pipelineIdentity,
            repositoryBindingEpoch: capability.repositoryAuthority.repositoryBindingEpoch,
            worktreeBindingEpoch: capability.repositoryAuthority.worktreeBindingEpoch
        )
    }

    init(canonicalBytes: Data) throws {
        guard canonicalBytes.count <= Self.maximumCanonicalByteCount else {
            throw CodeMapRootManifestModelError.inputTooLarge
        }
        var reader = CodeMapRootManifestReader(data: canonicalBytes)
        guard try reader.readData(count: Self.domain.utf8.count) == Data(Self.domain.utf8) else {
            throw CodeMapRootManifestModelError.corruptRecord
        }
        let repositoryNamespace = try GitBlobRepositoryNamespace(
            rawValue: reader.readData(count: GitBlobRepositoryNamespace.encodedByteCount).lowercaseHex
        )
        let worktreeIdentity = try reader.readString(maximumByteCount: 128)
        let prefix = try reader.readString(maximumByteCount: 4 * 1024, allowEmpty: true)
        let objectFormat = try reader.readObjectFormat()
        let schemaVersion = try reader.readUInt32()
        let policyVersion = try reader.readUInt32()
        let pipelineBytes = try reader.readLengthPrefixedData(maximumByteCount: 32 * 1024)
        let repositoryBindingEpoch = try reader.readString(maximumByteCount: 1024)
        let worktreeBindingEpoch = try reader.readString(maximumByteCount: 1024)
        guard reader.isAtEnd else { throw CodeMapRootManifestModelError.corruptRecord }
        let pipeline: CodeMapPipelineIdentity
        do {
            pipeline = try CodeMapPipelineIdentity(canonicalBytes: pipelineBytes)
        } catch {
            throw CodeMapRootManifestModelError.corruptRecord
        }
        try self.init(
            repositoryNamespace: repositoryNamespace,
            worktreeIdentity: worktreeIdentity,
            repositoryRelativeLoadedRootPrefix: prefix,
            objectFormat: objectFormat,
            schemaVersion: schemaVersion,
            policyVersion: policyVersion,
            pipelineIdentity: pipeline,
            repositoryBindingEpoch: repositoryBindingEpoch,
            worktreeBindingEpoch: worktreeBindingEpoch
        )
        guard canonicalBytes == self.canonicalBytes else {
            throw CodeMapRootManifestModelError.corruptRecord
        }
    }

    var canonicalBytes: Data {
        var writer = CodeMapRootManifestWriter()
        writer.append(Data(Self.domain.utf8))
        writer.append(repositoryNamespace.rawValue.canonicalHexData)
        writer.appendString(worktreeIdentity)
        writer.appendString(repositoryRelativeLoadedRootPrefix)
        writer.append(objectFormat.manifestTag)
        writer.append(schemaVersion)
        writer.append(policyVersion)
        writer.appendLengthPrefixed(pipelineIdentity.canonicalBytes)
        writer.appendString(repositoryBindingEpoch)
        writer.appendString(worktreeBindingEpoch)
        return writer.data
    }

    var storageDigestHex: String {
        Data(SHA256.hash(data: canonicalBytes)).lowercaseHex
    }

    var shard: String {
        String(storageDigestHex.prefix(2))
    }

    var isCurrent: Bool {
        schemaVersion == Self.currentSchemaVersion && policyVersion == Self.currentPolicyVersion
    }

    func contains(repositoryRelativePath: String) -> Bool {
        guard Self.isRepositoryRelativePath(repositoryRelativePath, allowEmpty: false) else { return false }
        if repositoryRelativeLoadedRootPrefix.isEmpty { return true }
        return repositoryRelativePath.hasPrefix(repositoryRelativeLoadedRootPrefix + "/")
    }

    fileprivate static func isRepositoryRelativePath(_ value: String, allowEmpty: Bool) -> Bool {
        guard value.utf8.count <= 4 * 1024,
              !value.contains("\0"),
              !value.hasPrefix("/"),
              !value.hasSuffix("/")
        else { return false }
        if value.isEmpty { return allowEmpty }
        return value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    fileprivate static func isBoundedAuthorityString(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 1024 && !value.contains("\0")
    }

    private static func isWorktreeIdentity(_ value: String) -> Bool {
        let suffix = value.dropFirst(3)
        return value.hasPrefix("wt_") && suffix.utf8.count == 64 && suffix.utf8.allSatisfy { byte in
            (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(byte) ||
                (UInt8(ascii: "a") ... UInt8(ascii: "f")).contains(byte)
        }
    }
}

/// The Git authority required to revalidate every record in one manifest snapshot.
struct CodeMapRootManifestAuthority: Hashable {
    private static let domain = "codemap-root-manifest-authority-v1"

    let authorityGeneration: UInt64
    let repositoryBindingEpoch: String
    let worktreeBindingEpoch: String
    let layoutGeneration: String
    let indexGeneration: String
    let checkoutConfigurationGeneration: String
    let attributeGeneration: String
    let sparseGeneration: String
    let metadataGeneration: String

    init(namespace: CodeMapRootManifestNamespace, token: WorkspaceCodemapRepositoryAuthorityToken) throws {
        guard namespace.repositoryNamespace == token.repositoryNamespace,
              namespace.objectFormat == token.objectFormat,
              namespace.repositoryBindingEpoch == token.repositoryBindingEpoch,
              namespace.worktreeBindingEpoch == token.worktreeBindingEpoch
        else {
            throw CodeMapRootManifestModelError.invalidAuthority
        }
        try self.init(
            authorityGeneration: token.authorityGeneration,
            repositoryBindingEpoch: token.repositoryBindingEpoch,
            worktreeBindingEpoch: token.worktreeBindingEpoch,
            layoutGeneration: token.layoutGeneration,
            indexGeneration: token.indexGeneration,
            checkoutConfigurationGeneration: token.checkoutConfigurationGeneration,
            attributeGeneration: token.attributeGeneration,
            sparseGeneration: token.sparseGeneration,
            metadataGeneration: token.metadataGeneration
        )
    }

    init(
        authorityGeneration: UInt64,
        repositoryBindingEpoch: String,
        worktreeBindingEpoch: String,
        layoutGeneration: String,
        indexGeneration: String,
        checkoutConfigurationGeneration: String,
        attributeGeneration: String,
        sparseGeneration: String,
        metadataGeneration: String
    ) throws {
        let values = [
            repositoryBindingEpoch,
            worktreeBindingEpoch,
            layoutGeneration,
            indexGeneration,
            checkoutConfigurationGeneration,
            attributeGeneration,
            sparseGeneration,
            metadataGeneration
        ]
        guard authorityGeneration > 0,
              values.allSatisfy(CodeMapRootManifestNamespace.isBoundedAuthorityString)
        else {
            throw CodeMapRootManifestModelError.invalidAuthority
        }
        self.authorityGeneration = authorityGeneration
        self.repositoryBindingEpoch = repositoryBindingEpoch
        self.worktreeBindingEpoch = worktreeBindingEpoch
        self.layoutGeneration = layoutGeneration
        self.indexGeneration = indexGeneration
        self.checkoutConfigurationGeneration = checkoutConfigurationGeneration
        self.attributeGeneration = attributeGeneration
        self.sparseGeneration = sparseGeneration
        self.metadataGeneration = metadataGeneration
    }

    fileprivate init(canonicalBytes: Data) throws {
        var reader = CodeMapRootManifestReader(data: canonicalBytes)
        guard try reader.readData(count: Self.domain.utf8.count) == Data(Self.domain.utf8) else {
            throw CodeMapRootManifestModelError.corruptRecord
        }
        try self.init(
            authorityGeneration: reader.readUInt64(),
            repositoryBindingEpoch: reader.readString(maximumByteCount: 1024),
            worktreeBindingEpoch: reader.readString(maximumByteCount: 1024),
            layoutGeneration: reader.readString(maximumByteCount: 1024),
            indexGeneration: reader.readString(maximumByteCount: 1024),
            checkoutConfigurationGeneration: reader.readString(maximumByteCount: 1024),
            attributeGeneration: reader.readString(maximumByteCount: 1024),
            sparseGeneration: reader.readString(maximumByteCount: 1024),
            metadataGeneration: reader.readString(maximumByteCount: 1024)
        )
        guard reader.isAtEnd, canonicalBytes == self.canonicalBytes else {
            throw CodeMapRootManifestModelError.corruptRecord
        }
    }

    fileprivate var canonicalBytes: Data {
        var writer = CodeMapRootManifestWriter()
        writer.append(Data(Self.domain.utf8))
        writer.append(authorityGeneration)
        writer.appendString(repositoryBindingEpoch)
        writer.appendString(worktreeBindingEpoch)
        writer.appendString(layoutGeneration)
        writer.appendString(indexGeneration)
        writer.appendString(checkoutConfigurationGeneration)
        writer.appendString(attributeGeneration)
        writer.appendString(sparseGeneration)
        writer.appendString(metadataGeneration)
        return writer.data
    }

    var digest: CodeMapSHA256Digest {
        try! CodeMapSHA256Digest(bytes: Data(SHA256.hash(data: canonicalBytes)))
    }
}

enum CodeMapRootManifestGitMode: UInt8, Hashable {
    case regular = 1
    case executable = 2

    var gitValue: String {
        switch self {
        case .regular: "100644"
        case .executable: "100755"
        }
    }

    init(gitValue: String) throws {
        switch gitValue {
        case "100644": self = .regular
        case "100755": self = .executable
        default: throw CodeMapRootManifestModelError.invalidMode
        }
    }
}

enum CodeMapRootManifestOutcome: UInt8, Hashable {
    case ready = 1
    case readyNoSymbols = 2
    case terminalOversize = 3
    case terminalDecodeFailure = 4
    case terminalParseFailure = 5
}

struct CodeMapRootManifestContributionIdentity: Hashable {
    let schemaVersion: UInt32
    let policyVersion: UInt32
    let digest: CodeMapSHA256Digest

    init(_ contribution: CodeMapSelectionGraphContribution) {
        schemaVersion = contribution.schemaVersion
        policyVersion = contribution.policyVersion
        digest = contribution.contributionDigest
    }

    fileprivate init(schemaVersion: UInt32, policyVersion: UInt32, digest: CodeMapSHA256Digest) throws {
        guard schemaVersion > 0, policyVersion > 0 else {
            throw CodeMapRootManifestModelError.invalidContribution
        }
        self.schemaVersion = schemaVersion
        self.policyVersion = policyVersion
        self.digest = digest
    }
}

/// Persisted, path-free symbol metadata used only to plan bounded automatic-selection demand.
/// A matching envelope never authorizes publication; normal locator/CAS/demand validation still does.
struct CodeMapRootManifestContributionEnvelope: Hashable {
    static let maximumNameCount = 16384
    static let maximumNameByteCount = 16 * 1024

    let identity: CodeMapRootManifestContributionIdentity
    let sortedUniqueDefinitions: [String]
    let sortedUniqueReferences: [String]

    init(_ contribution: CodeMapSelectionGraphContribution) {
        identity = CodeMapRootManifestContributionIdentity(contribution)
        sortedUniqueDefinitions = contribution.sortedUniqueDefinitions
        sortedUniqueReferences = contribution.sortedUniqueReferences
    }

    fileprivate init(
        identity: CodeMapRootManifestContributionIdentity,
        artifactKey: CodeMapArtifactKey,
        definitions: [String],
        references: [String]
    ) throws {
        guard definitions.count <= Self.maximumNameCount,
              references.count <= Self.maximumNameCount,
              definitions.allSatisfy({ $0.utf8.count <= Self.maximumNameByteCount }),
              references.allSatisfy({ $0.utf8.count <= Self.maximumNameByteCount })
        else { throw CodeMapRootManifestModelError.invalidContribution }
        let contribution = CodeMapSelectionGraphContribution(
            artifactKey: artifactKey,
            definitions: definitions,
            references: references
        )
        guard identity == CodeMapRootManifestContributionIdentity(contribution),
              definitions == contribution.sortedUniqueDefinitions,
              references == contribution.sortedUniqueReferences
        else { throw CodeMapRootManifestModelError.invalidContribution }
        self.identity = identity
        sortedUniqueDefinitions = definitions
        sortedUniqueReferences = references
    }
}

/// A clean Git binding. Construction requires the existing clean-source/CAS association proof.
struct CodeMapRootManifestRecord: Hashable {
    private enum Construction: Equatable {
        case verifiedAssociation
        case decodedCanonical
    }

    let repositoryRelativePath: String
    let locatorIdentity: GitBlobCodeMapLocatorIdentity
    let artifactKey: CodeMapArtifactKey
    let gitMode: CodeMapRootManifestGitMode
    let outcome: CodeMapRootManifestOutcome
    let contributionEnvelope: CodeMapRootManifestContributionEnvelope?
    let legacyContributionIdentity: CodeMapRootManifestContributionIdentity?
    let bindingGeneration: UInt64

    var contribution: CodeMapRootManifestContributionIdentity? {
        contributionEnvelope?.identity ?? legacyContributionIdentity
    }

    let sourceAuthorityGeneration: UInt64
    let sourceAuthorityDigest: CodeMapSHA256Digest
    private let construction: Construction

    var isVerifiedForPublication: Bool {
        construction == .verifiedAssociation
    }

    static func verifiedClean(
        namespace: CodeMapRootManifestNamespace,
        repositoryRelativePath: String,
        gitMode: CodeMapRootManifestGitMode,
        association: VerifiedGitBlobCodeMapLocatorAssociation,
        contribution: CodeMapSelectionGraphContribution?,
        authority: CodeMapRootManifestAuthority,
        bindingGeneration: UInt64
    ) throws -> Self {
        guard namespace.contains(repositoryRelativePath: repositoryRelativePath) else {
            throw CodeMapRootManifestModelError.invalidRelativePath
        }
        guard association.identity.repositoryNamespace == namespace.repositoryNamespace,
              association.identity.objectFormat == namespace.objectFormat,
              association.identity.pipelineIdentity == namespace.pipelineIdentity,
              association.artifactKey.pipelineIdentity == namespace.pipelineIdentity
        else {
            throw CodeMapRootManifestModelError.artifactKeyMismatch
        }
        let expectedContribution: CodeMapSelectionGraphContribution?
        let outcome: CodeMapRootManifestOutcome
        switch association.outcome {
        case let .ready(artifact):
            outcome = .ready
            expectedContribution = CodeMapSelectionGraphContribution(
                artifactKey: association.artifactKey,
                artifact: artifact
            )
        case .readyNoSymbols:
            outcome = .readyNoSymbols
            expectedContribution = CodeMapSelectionGraphContribution(
                artifactKey: association.artifactKey,
                definitions: [],
                references: []
            )
        case .oversize:
            outcome = .terminalOversize
            expectedContribution = nil
        case .decodeFailed:
            outcome = .terminalDecodeFailure
            expectedContribution = nil
        case .parseFailed:
            outcome = .terminalParseFailure
            expectedContribution = nil
        }
        guard contribution == expectedContribution else {
            throw CodeMapRootManifestModelError.invalidContribution
        }
        return try Self(
            namespace: namespace,
            repositoryRelativePath: repositoryRelativePath,
            locatorIdentity: association.identity,
            artifactKey: association.artifactKey,
            gitMode: gitMode,
            outcome: outcome,
            contributionEnvelope: contribution.map(CodeMapRootManifestContributionEnvelope.init),
            legacyContributionIdentity: nil,
            authority: authority,
            bindingGeneration: bindingGeneration,
            construction: .verifiedAssociation
        )
    }

    private init(
        namespace: CodeMapRootManifestNamespace,
        repositoryRelativePath: String,
        locatorIdentity: GitBlobCodeMapLocatorIdentity,
        artifactKey: CodeMapArtifactKey,
        gitMode: CodeMapRootManifestGitMode,
        outcome: CodeMapRootManifestOutcome,
        contributionEnvelope: CodeMapRootManifestContributionEnvelope?,
        legacyContributionIdentity: CodeMapRootManifestContributionIdentity?,
        authority: CodeMapRootManifestAuthority,
        bindingGeneration: UInt64,
        construction: Construction
    ) throws {
        guard namespace.contains(repositoryRelativePath: repositoryRelativePath),
              bindingGeneration > 0
        else {
            throw CodeMapRootManifestModelError.invalidRelativePath
        }
        guard locatorIdentity.repositoryNamespace == namespace.repositoryNamespace,
              locatorIdentity.objectFormat == namespace.objectFormat,
              locatorIdentity.pipelineIdentity == namespace.pipelineIdentity,
              artifactKey.pipelineIdentity == namespace.pipelineIdentity
        else {
            throw CodeMapRootManifestModelError.artifactKeyMismatch
        }
        guard authority.repositoryBindingEpoch == namespace.repositoryBindingEpoch,
              authority.worktreeBindingEpoch == namespace.worktreeBindingEpoch
        else {
            throw CodeMapRootManifestModelError.invalidAuthority
        }
        let contributionIdentity = contributionEnvelope?.identity ?? legacyContributionIdentity
        guard contributionEnvelope == nil || legacyContributionIdentity == nil else {
            throw CodeMapRootManifestModelError.invalidContribution
        }
        switch outcome {
        case .ready, .readyNoSymbols:
            guard contributionIdentity != nil else { throw CodeMapRootManifestModelError.invalidContribution }
        case .terminalOversize, .terminalDecodeFailure, .terminalParseFailure:
            guard contributionIdentity == nil else { throw CodeMapRootManifestModelError.invalidContribution }
        }
        self.repositoryRelativePath = repositoryRelativePath
        self.locatorIdentity = locatorIdentity
        self.artifactKey = artifactKey
        self.gitMode = gitMode
        self.outcome = outcome
        self.contributionEnvelope = contributionEnvelope
        self.legacyContributionIdentity = legacyContributionIdentity
        self.bindingGeneration = bindingGeneration
        sourceAuthorityGeneration = authority.authorityGeneration
        sourceAuthorityDigest = authority.digest
        self.construction = construction
    }

    fileprivate static func decodeCanonical(
        from reader: inout CodeMapRootManifestReader,
        namespace: CodeMapRootManifestNamespace,
        authority: CodeMapRootManifestAuthority,
        codecVersion: UInt32
    ) throws -> Self {
        let path = try reader.readString(maximumByteCount: 4 * 1024)
        let locatorBytes = try reader.readLengthPrefixedData(maximumByteCount: 32 * 1024)
        let keyBytes = try reader.readLengthPrefixedData(maximumByteCount: 32 * 1024)
        let locator: GitBlobCodeMapLocatorIdentity
        let key: CodeMapArtifactKey
        do {
            locator = try GitBlobCodeMapLocatorIdentity(canonicalBytes: locatorBytes)
            key = try CodeMapArtifactKey(canonicalBytes: keyBytes)
        } catch {
            throw CodeMapRootManifestModelError.corruptRecord
        }
        guard let mode = try CodeMapRootManifestGitMode(rawValue: reader.readUInt8()),
              let outcome = try CodeMapRootManifestOutcome(rawValue: reader.readUInt8())
        else {
            throw CodeMapRootManifestModelError.corruptRecord
        }
        let contributionIdentity: CodeMapRootManifestContributionIdentity?
        switch try reader.readUInt8() {
        case 0:
            contributionIdentity = nil
        case 1:
            contributionIdentity = try CodeMapRootManifestContributionIdentity(
                schemaVersion: reader.readUInt32(),
                policyVersion: reader.readUInt32(),
                digest: CodeMapSHA256Digest(
                    bytes: reader.readData(count: CodeMapSHA256Digest.byteCount)
                )
            )
        default:
            throw CodeMapRootManifestModelError.corruptRecord
        }
        let contributionEnvelope: CodeMapRootManifestContributionEnvelope?
        if codecVersion >= 2, let contributionIdentity {
            let definitionCount = try Int(reader.readUInt32())
            guard definitionCount <= CodeMapRootManifestContributionEnvelope.maximumNameCount else {
                throw CodeMapRootManifestModelError.invalidContribution
            }
            var definitions: [String] = []
            definitions.reserveCapacity(definitionCount)
            for _ in 0 ..< definitionCount {
                try definitions.append(reader.readString(
                    maximumByteCount: CodeMapRootManifestContributionEnvelope.maximumNameByteCount
                ))
            }
            let referenceCount = try Int(reader.readUInt32())
            guard referenceCount <= CodeMapRootManifestContributionEnvelope.maximumNameCount else {
                throw CodeMapRootManifestModelError.invalidContribution
            }
            var references: [String] = []
            references.reserveCapacity(referenceCount)
            for _ in 0 ..< referenceCount {
                try references.append(reader.readString(
                    maximumByteCount: CodeMapRootManifestContributionEnvelope.maximumNameByteCount
                ))
            }
            contributionEnvelope = try CodeMapRootManifestContributionEnvelope(
                identity: contributionIdentity,
                artifactKey: key,
                definitions: definitions,
                references: references
            )
        } else {
            contributionEnvelope = nil
        }
        let bindingGeneration = try reader.readUInt64()
        let sourceAuthorityGeneration = try reader.readUInt64()
        let sourceAuthorityDigest = try CodeMapSHA256Digest(
            bytes: reader.readData(count: CodeMapSHA256Digest.byteCount)
        )
        let record = try Self(
            namespace: namespace,
            repositoryRelativePath: path,
            locatorIdentity: locator,
            artifactKey: key,
            gitMode: mode,
            outcome: outcome,
            contributionEnvelope: contributionEnvelope,
            legacyContributionIdentity: contributionEnvelope == nil ? contributionIdentity : nil,
            authority: authority,
            bindingGeneration: bindingGeneration,
            construction: .decodedCanonical
        )
        guard record.sourceAuthorityGeneration == sourceAuthorityGeneration,
              record.sourceAuthorityDigest == sourceAuthorityDigest
        else {
            throw CodeMapRootManifestModelError.corruptRecord
        }
        return record
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.repositoryRelativePath == rhs.repositoryRelativePath &&
            lhs.locatorIdentity == rhs.locatorIdentity &&
            lhs.artifactKey == rhs.artifactKey &&
            lhs.gitMode == rhs.gitMode &&
            lhs.outcome == rhs.outcome &&
            lhs.contributionEnvelope == rhs.contributionEnvelope &&
            lhs.legacyContributionIdentity == rhs.legacyContributionIdentity &&
            lhs.bindingGeneration == rhs.bindingGeneration &&
            lhs.sourceAuthorityGeneration == rhs.sourceAuthorityGeneration &&
            lhs.sourceAuthorityDigest == rhs.sourceAuthorityDigest
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(repositoryRelativePath)
        hasher.combine(locatorIdentity)
        hasher.combine(artifactKey)
        hasher.combine(gitMode)
        hasher.combine(outcome)
        hasher.combine(contributionEnvelope)
        hasher.combine(legacyContributionIdentity)
        hasher.combine(bindingGeneration)
        hasher.combine(sourceAuthorityGeneration)
        hasher.combine(sourceAuthorityDigest)
    }
}

struct CodeMapRootManifestSnapshot: Hashable {
    let namespace: CodeMapRootManifestNamespace
    let authority: CodeMapRootManifestAuthority
    let manifestGeneration: UInt64
    let lastAccessEpochSeconds: UInt64
    let records: [CodeMapRootManifestRecord]

    init(
        namespace: CodeMapRootManifestNamespace,
        authority: CodeMapRootManifestAuthority,
        manifestGeneration: UInt64,
        lastAccessEpochSeconds: UInt64,
        records: [CodeMapRootManifestRecord]
    ) throws {
        guard namespace.isCurrent,
              manifestGeneration > 0,
              authority.repositoryBindingEpoch == namespace.repositoryBindingEpoch,
              authority.worktreeBindingEpoch == namespace.worktreeBindingEpoch
        else {
            throw CodeMapRootManifestModelError.invalidAuthority
        }
        let sorted = records.sorted { lhs, rhs in
            lhs.repositoryRelativePath.utf8.lexicographicallyPrecedes(rhs.repositoryRelativePath.utf8)
        }
        guard sorted == records,
              Set(records.map(\.repositoryRelativePath)).count == records.count,
              records.allSatisfy({
                  namespace.contains(repositoryRelativePath: $0.repositoryRelativePath) &&
                      $0.locatorIdentity.repositoryNamespace == namespace.repositoryNamespace &&
                      $0.locatorIdentity.objectFormat == namespace.objectFormat &&
                      $0.locatorIdentity.pipelineIdentity == namespace.pipelineIdentity &&
                      $0.artifactKey.pipelineIdentity == namespace.pipelineIdentity &&
                      $0.sourceAuthorityGeneration == authority.authorityGeneration &&
                      $0.sourceAuthorityDigest == authority.digest
              })
        else {
            throw CodeMapRootManifestModelError.corruptRecord
        }
        self.namespace = namespace
        self.authority = authority
        self.manifestGeneration = manifestGeneration
        self.lastAccessEpochSeconds = lastAccessEpochSeconds
        self.records = records
    }
}

enum CodeMapRootManifestCodec {
    static let magic = Data("RPCMRMF1".utf8)
    static let version: UInt32 = 2
    private static let legacyVersion: UInt32 = 1
    static let maximumRecordCount = 100_000
    static let maximumEncodedByteCount = 32 * 1024 * 1024

    private static let checksumByteCount = 32
    private static let minimumEncodedRecordByteCount = 64

    static func encode(snapshot: CodeMapRootManifestSnapshot) throws -> Data {
        guard snapshot.records.count <= maximumRecordCount else {
            throw CodeMapRootManifestModelError.inputTooLarge
        }
        var writer = CodeMapRootManifestWriter()
        writer.append(magic)
        writer.append(version)
        writer.appendLengthPrefixed(snapshot.namespace.canonicalBytes)
        writer.appendLengthPrefixed(snapshot.authority.canonicalBytes)
        writer.append(snapshot.manifestGeneration)
        writer.append(snapshot.lastAccessEpochSeconds)
        writer.append(UInt32(snapshot.records.count))
        for record in snapshot.records {
            writer.appendString(record.repositoryRelativePath)
            writer.appendLengthPrefixed(record.locatorIdentity.canonicalBytes)
            writer.appendLengthPrefixed(record.artifactKey.canonicalBytes)
            writer.append(record.gitMode.rawValue)
            writer.append(record.outcome.rawValue)
            if let contribution = record.contribution {
                writer.append(UInt8(1))
                writer.append(contribution.schemaVersion)
                writer.append(contribution.policyVersion)
                writer.append(contribution.digest.bytes)
                guard let envelope = record.contributionEnvelope else {
                    throw CodeMapRootManifestModelError.invalidContribution
                }
                writer.append(UInt32(envelope.sortedUniqueDefinitions.count))
                for name in envelope.sortedUniqueDefinitions {
                    writer.appendString(name)
                }
                writer.append(UInt32(envelope.sortedUniqueReferences.count))
                for name in envelope.sortedUniqueReferences {
                    writer.appendString(name)
                }
            } else {
                writer.append(UInt8(0))
            }
            writer.append(record.bindingGeneration)
            writer.append(record.sourceAuthorityGeneration)
            writer.append(record.sourceAuthorityDigest.bytes)
        }
        var data = writer.data
        data.append(Data(SHA256.hash(data: data)))
        guard data.count <= maximumEncodedByteCount else {
            throw CodeMapRootManifestModelError.inputTooLarge
        }
        return data
    }

    static func decode(
        _ data: Data,
        expectedNamespace: CodeMapRootManifestNamespace,
        filenameDigest: String
    ) throws -> CodeMapRootManifestSnapshot {
        let snapshot = try decodeStored(data, filenameDigest: filenameDigest)
        guard snapshot.namespace == expectedNamespace else {
            throw CodeMapRootManifestModelError.corruptRecord
        }
        return snapshot
    }

    static func decodeStored(
        _ data: Data,
        filenameDigest: String
    ) throws -> CodeMapRootManifestSnapshot {
        guard data.count <= maximumEncodedByteCount,
              data.count >= magic.count + 4 + checksumByteCount,
              filenameDigest.utf8.count == 64
        else {
            throw CodeMapRootManifestModelError.corruptRecord
        }
        let payloadEnd = data.count - checksumByteCount
        guard Data(SHA256.hash(data: data.prefix(payloadEnd))) == data.suffix(checksumByteCount) else {
            throw CodeMapRootManifestModelError.corruptRecord
        }
        var reader = CodeMapRootManifestReader(data: data.prefix(payloadEnd))
        guard try reader.readData(count: magic.count) == magic else {
            throw CodeMapRootManifestModelError.corruptRecord
        }
        let codecVersion = try reader.readUInt32()
        guard codecVersion == version || codecVersion == legacyVersion else {
            throw CodeMapRootManifestModelError.corruptRecord
        }
        let namespaceBytes = try reader.readLengthPrefixedData(
            maximumByteCount: CodeMapRootManifestNamespace.maximumCanonicalByteCount
        )
        let authorityBytes = try reader.readLengthPrefixedData(maximumByteCount: 16 * 1024)
        let manifestGeneration = try reader.readUInt64()
        let lastAccessEpochSeconds = try reader.readUInt64()
        let recordCount = try reader.readUInt32()
        guard recordCount <= UInt32(maximumRecordCount),
              Int(recordCount) <= reader.remainingByteCount / minimumEncodedRecordByteCount
        else {
            throw CodeMapRootManifestModelError.inputTooLarge
        }
        let namespace: CodeMapRootManifestNamespace
        let authority: CodeMapRootManifestAuthority
        do {
            namespace = try CodeMapRootManifestNamespace(canonicalBytes: namespaceBytes)
            authority = try CodeMapRootManifestAuthority(canonicalBytes: authorityBytes)
        } catch {
            throw CodeMapRootManifestModelError.corruptRecord
        }
        guard namespace.storageDigestHex == filenameDigest else {
            throw CodeMapRootManifestModelError.corruptRecord
        }
        var records: [CodeMapRootManifestRecord] = []
        records.reserveCapacity(Int(recordCount))
        for _ in 0 ..< recordCount {
            try records.append(
                CodeMapRootManifestRecord.decodeCanonical(
                    from: &reader,
                    namespace: namespace,
                    authority: authority,
                    codecVersion: codecVersion
                )
            )
        }
        guard reader.isAtEnd else { throw CodeMapRootManifestModelError.corruptRecord }
        let snapshot = try CodeMapRootManifestSnapshot(
            namespace: namespace,
            authority: authority,
            manifestGeneration: manifestGeneration,
            lastAccessEpochSeconds: lastAccessEpochSeconds,
            records: records
        )
        if codecVersion == version {
            guard try encode(snapshot: snapshot) == data else {
                throw CodeMapRootManifestModelError.corruptRecord
            }
        }
        return snapshot
    }
}

private extension GitObjectFormat {
    var manifestTag: UInt8 {
        switch self {
        case .sha1: 1
        case .sha256: 2
        }
    }
}

private struct CodeMapRootManifestWriter {
    private(set) var data = Data()

    mutating func append(_ value: UInt8) {
        data.append(value)
    }

    mutating func append(_ value: UInt32) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    mutating func append(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((value >> UInt64(shift)) & 0xFF))
        }
    }

    mutating func append(_ value: Data) {
        data.append(value)
    }

    mutating func appendLengthPrefixed(_ value: Data) {
        precondition(value.count <= Int(UInt32.max))
        append(UInt32(value.count))
        append(value)
    }

    mutating func appendString(_ value: String) {
        appendLengthPrefixed(Data(value.utf8))
    }
}

private struct CodeMapRootManifestReader {
    let data: Data
    private(set) var offset = 0

    var isAtEnd: Bool {
        offset == data.count
    }

    var remainingByteCount: Int {
        data.count - offset
    }

    mutating func readUInt8() throws -> UInt8 {
        guard offset < data.count else { throw CodeMapRootManifestModelError.corruptRecord }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readUInt32() throws -> UInt32 {
        let bytes = try readData(count: 4)
        return bytes.reduce(into: UInt32(0)) { $0 = ($0 << 8) | UInt32($1) }
    }

    mutating func readUInt64() throws -> UInt64 {
        let bytes = try readData(count: 8)
        return bytes.reduce(into: UInt64(0)) { $0 = ($0 << 8) | UInt64($1) }
    }

    mutating func readData(count: Int) throws -> Data {
        guard count >= 0, count <= data.count - offset else {
            throw CodeMapRootManifestModelError.corruptRecord
        }
        defer { offset += count }
        return data.subdata(in: offset ..< offset + count)
    }

    mutating func readLengthPrefixedData(maximumByteCount: Int) throws -> Data {
        let count = try readUInt32()
        guard count <= UInt32(maximumByteCount) else {
            throw CodeMapRootManifestModelError.inputTooLarge
        }
        return try readData(count: Int(count))
    }

    mutating func readString(maximumByteCount: Int, allowEmpty: Bool = false) throws -> String {
        let bytes = try readLengthPrefixedData(maximumByteCount: maximumByteCount)
        guard allowEmpty || !bytes.isEmpty, let value = String(data: bytes, encoding: .utf8) else {
            throw CodeMapRootManifestModelError.corruptRecord
        }
        return value
    }

    mutating func readObjectFormat() throws -> GitObjectFormat {
        switch try readUInt8() {
        case 1: .sha1
        case 2: .sha256
        default: throw CodeMapRootManifestModelError.corruptRecord
        }
    }
}

private extension String {
    var canonicalHexData: Data {
        var data = Data()
        data.reserveCapacity(utf8.count / 2)
        let bytes = Array(utf8)
        for index in stride(from: 0, to: bytes.count, by: 2) {
            data.append((Self.hexNibble(bytes[index]) << 4) | Self.hexNibble(bytes[index + 1]))
        }
        return data
    }

    static func hexNibble(_ byte: UInt8) -> UInt8 {
        switch byte {
        case UInt8(ascii: "0") ... UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        default: byte - UInt8(ascii: "a") + 10
        }
    }
}

private extension Data {
    var lowercaseHex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

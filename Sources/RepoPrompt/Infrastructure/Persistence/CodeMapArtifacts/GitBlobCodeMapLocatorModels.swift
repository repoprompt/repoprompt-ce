import CryptoKit
import Foundation

enum GitBlobCodeMapLocatorModelError: Error, Equatable {
    case invalidNamespaceSalt
    case invalidCommonDirectory
    case invalidNamespace
    case unsupportedObjectFormat
    case invalidObjectID
    case inputTooLarge
    case invalidEncoding
    case identityMismatch
    case artifactKeyMismatch
    case corruptRecord
}

enum VerifiedGitBlobCodeMapLocatorAssociationError: Error, Equatable {
    case sourceProvenanceMismatch
    case repositoryNamespaceMismatch
    case objectFormatMismatch
    case rawByteCountMismatch
    case rawDigestMismatch
    case pipelineMismatch
    case gitBlobOIDMismatch
    case casHandleMismatch
}

/// A path-free, installation-scoped repository identifier.
///
/// Callers must supply a stable, private 32-byte installation salt. Hashing the resolved
/// shared Git common directory means a primary checkout and its linked worktrees reuse the
/// same namespace without persisting the common-directory path.
struct GitBlobRepositoryNamespace: Hashable {
    static let saltByteCount = 32
    static let encodedByteCount = 32

    let rawValue: String

    init(rawValue: String) throws {
        guard Self.isCanonicalHex(rawValue, byteCount: Self.encodedByteCount) else {
            throw GitBlobCodeMapLocatorModelError.invalidNamespace
        }
        self.rawValue = rawValue
    }

    init(commonDirectory: URL, salt: Data) throws {
        guard salt.count == Self.saltByteCount else {
            throw GitBlobCodeMapLocatorModelError.invalidNamespaceSalt
        }
        guard commonDirectory.isFileURL,
              commonDirectory.path.hasPrefix("/"),
              !commonDirectory.path.contains("\0"),
              (try? commonDirectory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        else {
            throw GitBlobCodeMapLocatorModelError.invalidCommonDirectory
        }

        let resolvedPath = commonDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        let pathBytes = Data(resolvedPath.utf8)
        guard !pathBytes.isEmpty, pathBytes.count <= Int(UInt32.max) else {
            throw GitBlobCodeMapLocatorModelError.invalidCommonDirectory
        }
        var canonical = Data("git-blob-repository-namespace-v1".utf8)
        canonical.append(salt)
        canonical.appendBigEndian(UInt32(pathBytes.count))
        canonical.append(pathBytes)
        rawValue = Data(SHA256.hash(data: canonical)).lowercaseHex
    }

    init(repositoryLayout: GitRepositoryLayout, salt: Data) throws {
        try self.init(commonDirectory: repositoryLayout.commonDir, salt: salt)
    }

    fileprivate var bytes: Data {
        // Construction guarantees canonical hexadecimal input.
        try! Data(canonicalLowercaseHex: rawValue)
    }

    private static func isCanonicalHex(_ value: String, byteCount: Int) -> Bool {
        value.utf8.count == byteCount * 2 && value.utf8.allSatisfy { byte in
            (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(byte) ||
                (UInt8(ascii: "a") ... UInt8(ascii: "f")).contains(byte)
        }
    }
}

struct GitBlobCodeMapLocatorIdentity: Hashable {
    static let domain = "git-blob-codemap-locator-identity-v1"
    static let maximumCanonicalByteCount = 32 * 1024

    let repositoryNamespace: GitBlobRepositoryNamespace
    let blobOID: GitBlobOID
    let pipelineIdentity: CodeMapPipelineIdentity

    var objectFormat: GitObjectFormat {
        blobOID.objectFormat
    }

    init(
        repositoryNamespace: GitBlobRepositoryNamespace,
        objectFormat: GitObjectFormat,
        blobOID: String,
        pipelineIdentity: CodeMapPipelineIdentity
    ) throws {
        let validatedOID: GitBlobOID
        do {
            validatedOID = try GitBlobOID(objectFormat: objectFormat, lowercaseHex: blobOID)
        } catch {
            throw GitBlobCodeMapLocatorModelError.invalidObjectID
        }
        self.repositoryNamespace = repositoryNamespace
        self.blobOID = validatedOID
        self.pipelineIdentity = pipelineIdentity
    }

    init(
        repositoryNamespace: GitBlobRepositoryNamespace,
        blobOID: GitBlobOID,
        pipelineIdentity: CodeMapPipelineIdentity
    ) {
        self.repositoryNamespace = repositoryNamespace
        self.blobOID = blobOID
        self.pipelineIdentity = pipelineIdentity
    }

    init(canonicalBytes: Data) throws {
        guard canonicalBytes.count <= Self.maximumCanonicalByteCount else {
            throw GitBlobCodeMapLocatorModelError.inputTooLarge
        }
        var reader = GitBlobLocatorCanonicalReader(data: canonicalBytes)
        try reader.readDomain(Self.domain)
        let namespaceBytes = try reader.readData(count: GitBlobRepositoryNamespace.encodedByteCount)
        let namespace = try GitBlobRepositoryNamespace(rawValue: namespaceBytes.lowercaseHex)
        let format: GitObjectFormat
        switch try reader.readByte() {
        case 1: format = .sha1
        case 2: format = .sha256
        default:
            throw GitBlobCodeMapLocatorModelError.unsupportedObjectFormat
        }
        let objectID = try reader.readData(count: format.locatorObjectIDByteCount).lowercaseHex
        let pipelineByteCount = try reader.readUInt32()
        guard pipelineByteCount <= UInt32(Self.maximumCanonicalByteCount) else {
            throw GitBlobCodeMapLocatorModelError.inputTooLarge
        }
        let pipelineBytes = try reader.readData(count: Int(pipelineByteCount))
        guard reader.isAtEnd else {
            throw GitBlobCodeMapLocatorModelError.invalidEncoding
        }
        let pipeline: CodeMapPipelineIdentity
        do {
            pipeline = try CodeMapPipelineIdentity(canonicalBytes: pipelineBytes)
        } catch {
            throw GitBlobCodeMapLocatorModelError.invalidEncoding
        }
        try self.init(
            repositoryNamespace: namespace,
            objectFormat: format,
            blobOID: objectID,
            pipelineIdentity: pipeline
        )
        guard canonicalBytes == self.canonicalBytes else {
            throw GitBlobCodeMapLocatorModelError.invalidEncoding
        }
    }

    var canonicalBytes: Data {
        let pipelineBytes = pipelineIdentity.canonicalBytes
        precondition(pipelineBytes.count <= Int(UInt32.max))
        var data = Data(Self.domain.utf8)
        data.append(repositoryNamespace.bytes)
        data.append(objectFormat.locatorTag)
        data.append(try! Data(canonicalLowercaseHex: blobOID.lowercaseHex))
        data.appendBigEndian(UInt32(pipelineBytes.count))
        data.append(pipelineBytes)
        return data
    }

    var storageDigestHex: String {
        Data(SHA256.hash(data: canonicalBytes)).lowercaseHex
    }

    var shard: String {
        String(storageDigestHex.prefix(2))
    }
}

/// An opaque proof that clean Git provenance, a locator identity, and an artifact key describe
/// the same raw bytes, and that the exact key and outcome came from a verified CAS handle.
///
/// The private initializer prevents locator persistence and clean-blob binding from accepting
/// independently constructed identity/key/outcome values. Callers must present a validated clean
/// source snapshot and a verified CAS handle.
struct VerifiedGitBlobCodeMapLocatorAssociation: @unchecked Sendable, Equatable {
    private let verifiedIdentity: GitBlobCodeMapLocatorIdentity
    private let verifiedArtifactKey: CodeMapArtifactKey
    private let verifiedOutcome: CodeMapSyntaxArtifactOutcome

    var identity: GitBlobCodeMapLocatorIdentity {
        verifiedIdentity
    }

    var artifactKey: CodeMapArtifactKey {
        verifiedArtifactKey
    }

    var outcome: CodeMapSyntaxArtifactOutcome {
        verifiedOutcome
    }

    private init(
        identity: GitBlobCodeMapLocatorIdentity,
        artifactKey: CodeMapArtifactKey,
        outcome: CodeMapSyntaxArtifactOutcome
    ) {
        verifiedIdentity = identity
        verifiedArtifactKey = artifactKey
        verifiedOutcome = outcome
    }

    static func verify(
        source: CodeMapSourceSnapshot,
        identity: GitBlobCodeMapLocatorIdentity,
        artifactKey: CodeMapArtifactKey,
        casHandle: CodeMapArtifactHandle
    ) throws -> Self {
        guard case let .cleanGitBlob(repositoryNamespace, blobOID) = source.provenance else {
            throw VerifiedGitBlobCodeMapLocatorAssociationError.sourceProvenanceMismatch
        }
        guard repositoryNamespace == identity.repositoryNamespace else {
            throw VerifiedGitBlobCodeMapLocatorAssociationError.repositoryNamespaceMismatch
        }
        guard blobOID.objectFormat == identity.objectFormat else {
            throw VerifiedGitBlobCodeMapLocatorAssociationError.objectFormatMismatch
        }
        guard blobOID == identity.blobOID,
              GitBlobOID.blob(bytes: source.rawBytes, objectFormat: blobOID.objectFormat) == blobOID
        else {
            throw VerifiedGitBlobCodeMapLocatorAssociationError.gitBlobOIDMismatch
        }
        guard UInt64(source.rawByteCount) == artifactKey.rawByteCount else {
            throw VerifiedGitBlobCodeMapLocatorAssociationError.rawByteCountMismatch
        }
        guard source.rawSHA256 == artifactKey.rawSHA256 else {
            throw VerifiedGitBlobCodeMapLocatorAssociationError.rawDigestMismatch
        }
        guard identity.pipelineIdentity == artifactKey.pipelineIdentity else {
            throw VerifiedGitBlobCodeMapLocatorAssociationError.pipelineMismatch
        }
        guard casHandle.key == artifactKey else {
            throw VerifiedGitBlobCodeMapLocatorAssociationError.casHandleMismatch
        }
        return Self(
            identity: identity,
            artifactKey: artifactKey,
            outcome: casHandle.outcome
        )
    }

    /// Reconstitutes the proof carried by a securely decoded locator or current-authority manifest.
    /// The persistence layer already admitted the identity/key association; the verified CAS handle
    /// supplies the exact current outcome. This path intentionally avoids source materialization.
    static func revalidatePersisted(
        identity: GitBlobCodeMapLocatorIdentity,
        artifactKey: CodeMapArtifactKey,
        casHandle: CodeMapArtifactHandle
    ) throws -> Self {
        guard identity.pipelineIdentity == artifactKey.pipelineIdentity else {
            throw VerifiedGitBlobCodeMapLocatorAssociationError.pipelineMismatch
        }
        guard casHandle.key == artifactKey else {
            throw VerifiedGitBlobCodeMapLocatorAssociationError.casHandleMismatch
        }
        return Self(
            identity: identity,
            artifactKey: artifactKey,
            outcome: casHandle.outcome
        )
    }
}

private extension GitObjectFormat {
    var locatorTag: UInt8 {
        switch self {
        case .sha1: 1
        case .sha256: 2
        }
    }

    var locatorObjectIDByteCount: Int {
        oidHexCount / 2
    }
}

enum GitBlobCodeMapLocatorRecordCodec {
    static let magic = Data("RPGBLOC1".utf8)
    static let version: UInt32 = 1
    static let maximumRecordByteCount = 64 * 1024
    private static let checksumByteCount = 32

    static func encode(
        association: VerifiedGitBlobCodeMapLocatorAssociation
    ) throws -> Data {
        try encode(identity: association.identity, artifactKey: association.artifactKey)
    }

    private static func encode(
        identity: GitBlobCodeMapLocatorIdentity,
        artifactKey: CodeMapArtifactKey
    ) throws -> Data {
        try validate(artifactKey: artifactKey, for: identity)
        let identityBytes = identity.canonicalBytes
        let keyBytes = artifactKey.canonicalBytes
        guard identityBytes.count <= GitBlobCodeMapLocatorIdentity.maximumCanonicalByteCount,
              keyBytes.count <= GitBlobCodeMapLocatorIdentity.maximumCanonicalByteCount
        else {
            throw GitBlobCodeMapLocatorModelError.inputTooLarge
        }
        var data = magic
        data.appendBigEndian(version)
        data.appendBigEndian(UInt32(identityBytes.count))
        data.appendBigEndian(UInt32(keyBytes.count))
        data.append(identityBytes)
        data.append(keyBytes)
        data.append(Data(SHA256.hash(data: data)))
        guard data.count <= maximumRecordByteCount else {
            throw GitBlobCodeMapLocatorModelError.inputTooLarge
        }
        return data
    }

    static func decode(
        _ data: Data,
        expectedIdentity: GitBlobCodeMapLocatorIdentity,
        filenameDigest: String
    ) throws -> CodeMapArtifactKey {
        let decoded = try decodeStored(data, filenameDigest: filenameDigest)
        guard decoded.identity == expectedIdentity else {
            throw GitBlobCodeMapLocatorModelError.identityMismatch
        }
        return decoded.artifactKey
    }

    static func decodeStored(
        _ data: Data,
        filenameDigest: String
    ) throws -> (identity: GitBlobCodeMapLocatorIdentity, artifactKey: CodeMapArtifactKey) {
        guard data.count <= maximumRecordByteCount,
              data.count >= magic.count + 12 + checksumByteCount,
              filenameDigest.utf8.count == 64
        else {
            throw GitBlobCodeMapLocatorModelError.corruptRecord
        }
        let payloadEnd = data.count - checksumByteCount
        guard Data(SHA256.hash(data: data.prefix(payloadEnd))) == data.suffix(checksumByteCount) else {
            throw GitBlobCodeMapLocatorModelError.corruptRecord
        }

        var reader = GitBlobLocatorCanonicalReader(data: data.prefix(payloadEnd))
        guard try reader.readData(count: magic.count) == magic,
              try reader.readUInt32() == version
        else {
            throw GitBlobCodeMapLocatorModelError.corruptRecord
        }
        let identityByteCount = try reader.readUInt32()
        let keyByteCount = try reader.readUInt32()
        guard identityByteCount <= UInt32(GitBlobCodeMapLocatorIdentity.maximumCanonicalByteCount),
              keyByteCount <= UInt32(GitBlobCodeMapLocatorIdentity.maximumCanonicalByteCount)
        else {
            throw GitBlobCodeMapLocatorModelError.inputTooLarge
        }
        let identityBytes = try reader.readData(count: Int(identityByteCount))
        let keyBytes = try reader.readData(count: Int(keyByteCount))
        guard reader.isAtEnd else {
            throw GitBlobCodeMapLocatorModelError.corruptRecord
        }

        let decodedIdentity: GitBlobCodeMapLocatorIdentity
        let artifactKey: CodeMapArtifactKey
        do {
            decodedIdentity = try GitBlobCodeMapLocatorIdentity(canonicalBytes: identityBytes)
            artifactKey = try CodeMapArtifactKey(canonicalBytes: keyBytes)
        } catch {
            throw GitBlobCodeMapLocatorModelError.corruptRecord
        }
        guard decodedIdentity.storageDigestHex == filenameDigest else {
            throw GitBlobCodeMapLocatorModelError.identityMismatch
        }
        try validate(artifactKey: artifactKey, for: decodedIdentity)
        guard try encode(identity: decodedIdentity, artifactKey: artifactKey) == data else {
            throw GitBlobCodeMapLocatorModelError.corruptRecord
        }
        return (decodedIdentity, artifactKey)
    }

    static func validate(
        artifactKey: CodeMapArtifactKey,
        for identity: GitBlobCodeMapLocatorIdentity
    ) throws {
        guard artifactKey.pipelineIdentity == identity.pipelineIdentity else {
            throw GitBlobCodeMapLocatorModelError.artifactKeyMismatch
        }
        do {
            guard try CodeMapArtifactKey(canonicalBytes: artifactKey.canonicalBytes) == artifactKey else {
                throw GitBlobCodeMapLocatorModelError.artifactKeyMismatch
            }
        } catch let error as GitBlobCodeMapLocatorModelError {
            throw error
        } catch {
            throw GitBlobCodeMapLocatorModelError.artifactKeyMismatch
        }
    }
}

private struct GitBlobLocatorCanonicalReader {
    let data: Data
    private(set) var offset = 0

    var isAtEnd: Bool {
        offset == data.count
    }

    mutating func readDomain(_ domain: String) throws {
        guard try readData(count: domain.utf8.count) == Data(domain.utf8) else {
            throw GitBlobCodeMapLocatorModelError.invalidEncoding
        }
    }

    mutating func readByte() throws -> UInt8 {
        guard offset < data.count else { throw GitBlobCodeMapLocatorModelError.invalidEncoding }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readUInt32() throws -> UInt32 {
        let bytes = try readData(count: 4)
        return bytes.reduce(into: UInt32(0)) { $0 = ($0 << 8) | UInt32($1) }
    }

    mutating func readData(count: Int) throws -> Data {
        guard count >= 0, count <= data.count - offset else {
            throw GitBlobCodeMapLocatorModelError.invalidEncoding
        }
        defer { offset += count }
        return data.subdata(in: offset ..< offset + count)
    }
}

private extension Data {
    init(canonicalLowercaseHex value: String) throws {
        guard value.utf8.count.isMultiple(of: 2) else {
            throw GitBlobCodeMapLocatorModelError.invalidEncoding
        }
        var result = Data()
        result.reserveCapacity(value.utf8.count / 2)
        let bytes = Array(value.utf8)
        for index in stride(from: 0, to: bytes.count, by: 2) {
            guard let high = Self.hexNibble(bytes[index]),
                  let low = Self.hexNibble(bytes[index + 1])
            else {
                throw GitBlobCodeMapLocatorModelError.invalidEncoding
            }
            result.append((high << 4) | low)
        }
        self = result
    }

    var lowercaseHex: String {
        map { String(format: "%02x", $0) }.joined()
    }

    mutating func appendBigEndian(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    static func hexNibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0") ... UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "a") ... UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        default: nil
        }
    }
}

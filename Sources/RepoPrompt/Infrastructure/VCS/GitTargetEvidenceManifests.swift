import CryptoKit
import Darwin
import Foundation

enum GitTargetEvidenceFamily: UInt8, Equatable {
    case treeDelta = 1
    case index = 2
    case porcelainV2Status = 3
}

struct GitTargetEvidenceFileSystemIdentity: Equatable {
    let canonicalPathBytes: Data
    let device: UInt64
    let inode: UInt64

    init(canonicalPathBytes: Data, device: UInt64, inode: UInt64) {
        self.canonicalPathBytes = canonicalPathBytes
        self.device = device
        self.inode = inode
    }

    init(url: URL) throws {
        let physicalURL = url.resolvingSymlinksInPath().standardizedFileURL
        var status = stat()
        guard lstat(physicalURL.path, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
        else { throw GitTargetEvidenceManifestError.io(operation: "identity-lstat", code: errno) }
        guard let pathBytes = physicalURL.withUnsafeFileSystemRepresentation({ pointer in
            pointer.map { Data(bytes: $0, count: strlen($0)) }
        }), !pathBytes.isEmpty else {
            throw GitTargetEvidenceManifestError.invalidConfiguration
        }
        canonicalPathBytes = pathBytes
        device = UInt64(status.st_dev)
        inode = UInt64(status.st_ino)
    }
}

struct GitTargetEvidenceAuthorityIdentity: Equatable {
    let authorityGeneration: UInt64
    let invalidationGeneration: UInt64
    let acceptedMetadataWatermark: UInt64
    let attemptID: UUID
    let snapshotDigestBytes: Data
}

/// Complete ephemeral identity of one Git target-evidence artifact. Every field
/// is serialized into the authenticated header; artifacts are never reopened
/// through a persistence-compatibility path.
struct GitTargetEvidenceArtifactIdentity: Equatable {
    let physicalWorktree: GitTargetEvidenceFileSystemIdentity
    let repositoryCommonDirectory: GitTargetEvidenceFileSystemIdentity
    let repositoryGitDirectory: GitTargetEvidenceFileSystemIdentity
    let authority: GitTargetEvidenceAuthorityIdentity
    let commandArguments: [Data]
    let commandFormatBytes: Data
    /// SHA-256 over the canonical, service-owned Git environment actually
    /// passed to the evidence subprocess.
    let environmentIdentityBytes: Data
    /// SHA-256 over the exact raw stdout spool consumed by the parser.
    let commandOutputDigestBytes: Data
    let repositoryRelativeRootPrefixBytes: Data
    let objectFormatBytes: Data
    let baseObjectIDBytes: Data?
    let targetObjectIDBytes: Data?
    /// Opaque caller-supplied provenance used only to require bundle coherence.
    /// It is authenticated as supplied metadata, never as observed Git authority.
    let suppliedCreationCutProvenanceBytes: Data?
    /// Required for index evidence and nil for the other command families.
    let sparseCheckoutEnabled: Bool?
}

struct GitTargetEvidenceManifestHeader: Equatable {
    static let currentSchemaVersion: UInt32 = 2

    let schemaVersion: UInt32
    let family: GitTargetEvidenceFamily
    let identity: GitTargetEvidenceArtifactIdentity

    init(
        schemaVersion: UInt32 = Self.currentSchemaVersion,
        family: GitTargetEvidenceFamily,
        identity: GitTargetEvidenceArtifactIdentity
    ) {
        self.schemaVersion = schemaVersion
        self.family = family
        self.identity = identity
    }
}

struct GitTargetEvidenceManifestFooter: Equatable {
    let recordCount: UInt64
    let recordPayloadByteCount: UInt64
    let pathPayloadByteCount: UInt64
    let digest: Data
}

struct GitTargetEvidenceManifestStatistics: Equatable {
    let initialRunCount: Int
    let mergePassCount: Int
    let peakBufferedRecordBytes: Int
    let recordCount: UInt64
    let finalByteCount: UInt64
}

enum GitTargetEvidenceManifestError: Error, Equatable {
    case invalidConfiguration
    case invalidRecord(String)
    case duplicateRecord
    case outOfOrder
    case resourceAdmission
    case closed
    case corrupt(String)
    case io(operation: String, code: Int32)
}

enum GitTargetEvidenceProcessCaptureFailure: Equatable {
    case stdoutLimitExceeded
    case stderrLimitExceeded
}

enum GitTargetEvidenceCollectionError: Error, Equatable {
    case authorityChanged
    case admission(GitProcessAdmissionError)
    case processLaunch(domain: String, code: Int)
    case processCapture(GitTargetEvidenceProcessCaptureFailure)
    case spool(GitRawOutputSpoolError)
    case resourceAdmission
    case activityTimeout
    case malformedGitOutput(String)
    case gitInitialization(GitWorktreeInitializationError)
    case gitFailure(exitCode: Int32, stderr: Data)
    case gitSignal(signal: Int32, stderr: Data)
    case artifact(GitTargetEvidenceManifestError)
    case io(operation: String, code: Int32)
}

enum GitTargetEvidenceReaderValidationState: Equatable {
    case reading
    case verified
    case failed
}

enum GitTargetTreeDeltaEvidenceStatus: UInt8, Equatable {
    case added = 1
    case deleted = 2
    case modified = 3
    case typeChanged = 4
    /// Removal operation emitted at a rename's source path.
    case renamedSource = 5
    /// Upsert operation emitted at a rename's destination path.
    case renamed = 6
    case copied = 7
    case unmerged = 8
}

struct GitTargetTreeDeltaEvidenceRecord: Equatable {
    let oldModeBytes: Data?
    let newModeBytes: Data?
    let oldObjectIDBytes: Data?
    let newObjectIDBytes: Data?
    let status: GitTargetTreeDeltaEvidenceStatus
    let similarityScore: UInt16?
    let sourceRepositoryRelativePathBytes: Data?
    let repositoryRelativePathBytes: Data

    init(
        oldModeBytes: Data?,
        newModeBytes: Data?,
        oldObjectIDBytes: Data?,
        newObjectIDBytes: Data?,
        status: GitTargetTreeDeltaEvidenceStatus,
        similarityScore: UInt16? = nil,
        sourceRepositoryRelativePathBytes: Data? = nil,
        repositoryRelativePathBytes: Data
    ) {
        self.oldModeBytes = oldModeBytes
        self.newModeBytes = newModeBytes
        self.oldObjectIDBytes = oldObjectIDBytes
        self.newObjectIDBytes = newObjectIDBytes
        self.status = status
        self.similarityScore = similarityScore
        self.sourceRepositoryRelativePathBytes = sourceRepositoryRelativePathBytes
        self.repositoryRelativePathBytes = repositoryRelativePathBytes
    }
}

struct GitTargetIndexEvidenceRecord: Equatable {
    let modeBytes: Data
    let objectIDBytes: Data
    let stage: UInt8
    let repositoryRelativePathBytes: Data
    let assumeUnchanged: Bool
    let skipWorktree: Bool
}

enum GitTargetStatusEvidenceKind: UInt8, Equatable {
    case ordinary = 1
    case renamed = 2
    case copied = 3
    case unmerged = 4
    case untracked = 5
    case ignored = 6
}

struct GitTargetStatusEvidenceRecord: Equatable {
    let kind: GitTargetStatusEvidenceKind
    let repositoryRelativePathBytes: Data
    let sourceRepositoryRelativePathBytes: Data?
    let similarityScore: UInt16?
    /// Porcelain-v2 may suffix untracked/ignored directory markers with `/`.
    /// The slash is removed from the path sort key and retained here exactly.
    let isDirectoryMarker: Bool
    let indexStatus: UInt8?
    let workTreeStatus: UInt8?
    let submoduleStateBytes: Data?
    let headModeBytes: Data?
    let indexModeBytes: Data?
    let workTreeModeBytes: Data?
    let headObjectIDBytes: Data?
    let indexObjectIDBytes: Data?
    let conflictStage1ModeBytes: Data?
    let conflictStage2ModeBytes: Data?
    let conflictStage3ModeBytes: Data?
    let conflictStage1ObjectIDBytes: Data?
    let conflictStage2ObjectIDBytes: Data?
    let conflictStage3ObjectIDBytes: Data?

    init(
        kind: GitTargetStatusEvidenceKind,
        repositoryRelativePathBytes: Data,
        sourceRepositoryRelativePathBytes: Data? = nil,
        similarityScore: UInt16? = nil,
        isDirectoryMarker: Bool = false,
        indexStatus: UInt8? = nil,
        workTreeStatus: UInt8? = nil,
        submoduleStateBytes: Data? = nil,
        headModeBytes: Data? = nil,
        indexModeBytes: Data? = nil,
        workTreeModeBytes: Data? = nil,
        headObjectIDBytes: Data? = nil,
        indexObjectIDBytes: Data? = nil,
        conflictStage1ModeBytes: Data? = nil,
        conflictStage2ModeBytes: Data? = nil,
        conflictStage3ModeBytes: Data? = nil,
        conflictStage1ObjectIDBytes: Data? = nil,
        conflictStage2ObjectIDBytes: Data? = nil,
        conflictStage3ObjectIDBytes: Data? = nil
    ) {
        self.kind = kind
        self.repositoryRelativePathBytes = repositoryRelativePathBytes
        self.sourceRepositoryRelativePathBytes = sourceRepositoryRelativePathBytes
        self.similarityScore = similarityScore
        self.isDirectoryMarker = isDirectoryMarker
        self.indexStatus = indexStatus
        self.workTreeStatus = workTreeStatus
        self.submoduleStateBytes = submoduleStateBytes
        self.headModeBytes = headModeBytes
        self.indexModeBytes = indexModeBytes
        self.workTreeModeBytes = workTreeModeBytes
        self.headObjectIDBytes = headObjectIDBytes
        self.indexObjectIDBytes = indexObjectIDBytes
        self.conflictStage1ModeBytes = conflictStage1ModeBytes
        self.conflictStage2ModeBytes = conflictStage2ModeBytes
        self.conflictStage3ModeBytes = conflictStage3ModeBytes
        self.conflictStage1ObjectIDBytes = conflictStage1ObjectIDBytes
        self.conflictStage2ObjectIDBytes = conflictStage2ObjectIDBytes
        self.conflictStage3ObjectIDBytes = conflictStage3ObjectIDBytes
    }
}

protocol GitTargetEvidenceRecordCodec: Sendable {
    associatedtype Record: Equatable, Sendable

    static var family: GitTargetEvidenceFamily { get }
    static var fileExtension: String { get }
    static func validate(_ record: Record) throws
    static func validate(_ record: Record, objectFormatBytes: Data) throws
    static func encode(_ record: Record) throws -> Data
    static func decode(_ payload: Data) throws -> Record
    static func ordering(_ lhs: Record, _ rhs: Record) -> SpillBackedSortedArtifactOrdering
    static func duplicateResolution(
        _ existing: Record,
        _ candidate: Record
    ) throws -> SpillBackedSortedArtifactDuplicateResolution
    static func pathPayloadByteCount(_ record: Record) throws -> UInt64
}

extension GitTargetEvidenceRecordCodec {
    static func validate(_ record: Record, objectFormatBytes _: Data) throws {
        try validate(record)
    }

    static func duplicateResolution(
        _: Record,
        _: Record
    ) throws -> SpillBackedSortedArtifactDuplicateResolution {
        .reject
    }
}

enum GitTargetEvidenceManifestCodec {
    static let magic = Data("RPGITEV1".utf8)
    static let recordMarker: UInt8 = 0x52
    static let footerMarker: UInt8 = 0x46
    static let footerPayloadByteCount = 8 * 3 + SHA256.byteCount
    static let maximumHeaderPayloadByteCount = 4 * 1024 * 1024
    static let maximumRecordPayloadByteCount = SpillBackedSortedArtifactChecked.maximumFrameByteCount - 5

    struct DecodedHeaderFrame {
        let header: GitTargetEvidenceManifestHeader
        let encodedFrame: Data
    }

    static func validatePath(_ path: Data, label: String) throws {
        guard !path.isEmpty,
              path.count <= maximumRecordPayloadByteCount,
              path.first != UInt8(ascii: "/"),
              !path.contains(0)
        else {
            throw GitTargetEvidenceManifestError.invalidRecord("invalid \(label)")
        }
        let components = path.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false)
        guard !components.contains(where: {
            $0.isEmpty || $0.elementsEqual([UInt8(ascii: ".")]) ||
                $0.elementsEqual([UInt8(ascii: "."), UInt8(ascii: ".")])
        }) else { throw GitTargetEvidenceManifestError.invalidRecord("invalid \(label)") }
    }

    static func validateMode(_ mode: Data?, label: String) throws {
        guard let mode else { return }
        guard mode.count == 6, mode.allSatisfy({ (UInt8(ascii: "0") ... UInt8(ascii: "7")).contains($0) }) else {
            throw GitTargetEvidenceManifestError.invalidRecord("invalid \(label)")
        }
    }

    static func validateOID(_ oid: Data?, label: String) throws {
        guard let oid else { return }
        guard [40, 64].contains(oid.count), oid.allSatisfy({
            (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains($0) ||
                (UInt8(ascii: "a") ... UInt8(ascii: "f")).contains($0)
        }) else { throw GitTargetEvidenceManifestError.invalidRecord("invalid \(label)") }
    }

    static func encodeHeader(_ header: GitTargetEvidenceManifestHeader) throws -> Data {
        let identity = header.identity
        let headerDataFields = [
            identity.physicalWorktree.canonicalPathBytes,
            identity.repositoryCommonDirectory.canonicalPathBytes,
            identity.repositoryGitDirectory.canonicalPathBytes,
            identity.authority.snapshotDigestBytes,
            identity.commandFormatBytes,
            identity.environmentIdentityBytes,
            identity.commandOutputDigestBytes,
            identity.repositoryRelativeRootPrefixBytes,
            identity.objectFormatBytes,
            identity.baseObjectIDBytes ?? Data(),
            identity.targetObjectIDBytes ?? Data(),
            identity.suppliedCreationCutProvenanceBytes ?? Data()
        ] + identity.commandArguments
        guard headerDataFields.allSatisfy({ $0.count <= maximumHeaderPayloadByteCount }),
              identity.commandArguments.count <= Int(UInt32.max)
        else { throw GitTargetEvidenceManifestError.invalidConfiguration }
        var payload = Data([header.family.rawValue])
        appendFileSystemIdentity(identity.physicalWorktree, to: &payload)
        appendFileSystemIdentity(identity.repositoryCommonDirectory, to: &payload)
        appendFileSystemIdentity(identity.repositoryGitDirectory, to: &payload)
        append(identity.authority.authorityGeneration, to: &payload)
        append(identity.authority.invalidationGeneration, to: &payload)
        append(identity.authority.acceptedMetadataWatermark, to: &payload)
        append(Data(identity.authority.attemptID.uuidString.lowercased().utf8), to: &payload)
        append(identity.authority.snapshotDigestBytes, to: &payload)
        append(UInt32(identity.commandArguments.count), to: &payload)
        for argument in identity.commandArguments {
            append(argument, to: &payload)
        }
        append(identity.commandFormatBytes, to: &payload)
        append(identity.environmentIdentityBytes, to: &payload)
        append(identity.commandOutputDigestBytes, to: &payload)
        append(identity.repositoryRelativeRootPrefixBytes, to: &payload)
        append(identity.objectFormatBytes, to: &payload)
        appendOptional(identity.baseObjectIDBytes, to: &payload)
        appendOptional(identity.targetObjectIDBytes, to: &payload)
        appendOptional(identity.suppliedCreationCutProvenanceBytes, to: &payload)
        payload.append(identity.sparseCheckoutEnabled == nil ? 0 : 1)
        if let sparseCheckoutEnabled = identity.sparseCheckoutEnabled {
            payload.append(sparseCheckoutEnabled ? 1 : 0)
        }
        guard !identity.physicalWorktree.canonicalPathBytes.isEmpty,
              !identity.repositoryCommonDirectory.canonicalPathBytes.isEmpty,
              !identity.repositoryGitDirectory.canonicalPathBytes.isEmpty,
              !identity.commandArguments.isEmpty,
              !identity.commandFormatBytes.isEmpty,
              identity.environmentIdentityBytes.count == SHA256.byteCount,
              identity.commandOutputDigestBytes.count == SHA256.byteCount,
              [Data("sha1".utf8), Data("sha256".utf8)].contains(identity.objectFormatBytes),
              identity.authority.snapshotDigestBytes.count == SHA256.byteCount,
              validAbsolutePath(identity.physicalWorktree.canonicalPathBytes),
              validAbsolutePath(identity.repositoryCommonDirectory.canonicalPathBytes),
              validAbsolutePath(identity.repositoryGitDirectory.canonicalPathBytes),
              payload.count <= maximumHeaderPayloadByteCount,
              let payloadCount = UInt32(exactly: payload.count)
        else { throw GitTargetEvidenceManifestError.invalidConfiguration }

        var frame = magic
        append(header.schemaVersion, to: &frame)
        append(payloadCount, to: &frame)
        frame.append(payload)
        frame.append(Data(SHA256.hash(data: payload)))
        return frame
    }

    static func readHeaderFrame(from descriptor: Int32) throws -> DecodedHeaderFrame {
        let prefixCount = magic.count + 8
        let prefix = try readExact(descriptor, count: prefixCount)
        guard prefix.prefix(magic.count) == magic else {
            throw GitTargetEvidenceManifestError.corrupt("invalid magic")
        }
        var prefixCursor = GitTargetEvidenceByteCursor(Data(prefix.dropFirst(magic.count)))
        let schema = try prefixCursor.readUInt32()
        let payloadCount = try prefixCursor.readUInt32()
        guard schema == GitTargetEvidenceManifestHeader.currentSchemaVersion,
              payloadCount > 0, payloadCount <= maximumHeaderPayloadByteCount
        else { throw GitTargetEvidenceManifestError.corrupt("unsupported header") }
        let payload = try readExact(descriptor, count: Int(payloadCount))
        let checksum = try readExact(descriptor, count: SHA256.byteCount)
        guard checksum == Data(SHA256.hash(data: payload)) else {
            throw GitTargetEvidenceManifestError.corrupt("header checksum")
        }
        var encoded = prefix
        encoded.append(payload)
        encoded.append(checksum)
        return try DecodedHeaderFrame(
            header: decodeHeader(schemaVersion: schema, payload: payload),
            encodedFrame: encoded
        )
    }

    static func recordFrame(_ payload: Data) throws -> Data {
        guard !payload.isEmpty, payload.count <= maximumRecordPayloadByteCount,
              let count = UInt32(exactly: payload.count)
        else { throw GitTargetEvidenceManifestError.invalidRecord("record payload size") }
        var frame = Data([recordMarker])
        append(count, to: &frame)
        frame.append(payload)
        return frame
    }

    static func encodeFooter(_ footer: GitTargetEvidenceManifestFooter) throws -> Data {
        guard footer.digest.count == SHA256.byteCount else {
            throw GitTargetEvidenceManifestError.corrupt("invalid footer digest")
        }
        var frame = Data([footerMarker])
        append(footer.recordCount, to: &frame)
        append(footer.recordPayloadByteCount, to: &frame)
        append(footer.pathPayloadByteCount, to: &frame)
        frame.append(footer.digest)
        return frame
    }

    static func decodeFooter(_ payload: Data) throws -> GitTargetEvidenceManifestFooter {
        guard payload.count == footerPayloadByteCount else {
            throw GitTargetEvidenceManifestError.corrupt("invalid footer size")
        }
        var cursor = GitTargetEvidenceByteCursor(payload)
        let footer = try GitTargetEvidenceManifestFooter(
            recordCount: cursor.readUInt64(),
            recordPayloadByteCount: cursor.readUInt64(),
            pathPayloadByteCount: cursor.readUInt64(),
            digest: cursor.readData(count: SHA256.byteCount)
        )
        guard cursor.remaining == 0 else {
            throw GitTargetEvidenceManifestError.corrupt("invalid footer")
        }
        return footer
    }

    static func readExact(_ descriptor: Int32, count: Int) throws -> Data {
        guard count >= 0 else { throw GitTargetEvidenceManifestError.corrupt("negative read") }
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let amount = data.withUnsafeMutableBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                return Darwin.read(descriptor, base.advanced(by: offset), count - offset)
            }
            if amount > 0 { offset += amount }
            else if amount == 0 { throw GitTargetEvidenceManifestError.corrupt("truncated file") }
            else if errno != EINTR { throw GitTargetEvidenceManifestError.io(operation: "read", code: errno) }
        }
        return data
    }

    static func append(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    static func append(_ value: UInt32, to data: inout Data) {
        for shift in stride(from: 0, to: 32, by: 8) {
            data.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
    }

    static func append(_ value: UInt64, to data: inout Data) {
        for shift in stride(from: 0, to: 64, by: 8) {
            data.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    static func append(_ value: Data, to data: inout Data) {
        append(UInt32(value.count), to: &data)
        data.append(value)
    }

    static func appendOptional(_ value: Data?, to data: inout Data) {
        data.append(value == nil ? 0 : 1)
        if let value { append(value, to: &data) }
    }

    static func appendOptional(_ value: UInt8?, to data: inout Data) {
        data.append(value == nil ? 0 : 1)
        if let value { data.append(value) }
    }

    static func appendOptional(_ value: UInt16?, to data: inout Data) {
        data.append(value == nil ? 0 : 1)
        if let value { append(value, to: &data) }
    }

    private static func appendFileSystemIdentity(
        _ identity: GitTargetEvidenceFileSystemIdentity,
        to data: inout Data
    ) {
        append(identity.canonicalPathBytes, to: &data)
        append(identity.device, to: &data)
        append(identity.inode, to: &data)
    }

    private static func validAbsolutePath(_ path: Data) -> Bool {
        !path.isEmpty && path.first == UInt8(ascii: "/") && !path.contains(0)
    }

    private static func decodeHeader(
        schemaVersion: UInt32,
        payload: Data
    ) throws -> GitTargetEvidenceManifestHeader {
        var cursor = GitTargetEvidenceByteCursor(payload)
        guard let family = try GitTargetEvidenceFamily(rawValue: cursor.readUInt8()) else {
            throw GitTargetEvidenceManifestError.corrupt("invalid evidence family")
        }
        let physical = try cursor.readFileSystemIdentity()
        let common = try cursor.readFileSystemIdentity()
        let gitDirectory = try cursor.readFileSystemIdentity()
        let authorityGeneration = try cursor.readUInt64()
        let invalidationGeneration = try cursor.readUInt64()
        let watermark = try cursor.readUInt64()
        let attemptBytes = try cursor.readLengthPrefixedData()
        guard let attemptString = String(data: attemptBytes, encoding: .utf8),
              let attemptID = UUID(uuidString: attemptString)
        else { throw GitTargetEvidenceManifestError.corrupt("invalid attempt ID") }
        let snapshotDigest = try cursor.readLengthPrefixedData()
        let argumentCount = try cursor.readUInt32()
        var arguments: [Data] = []
        guard argumentCount > 0, argumentCount <= 65536 else {
            throw GitTargetEvidenceManifestError.corrupt("invalid argument count")
        }
        arguments.reserveCapacity(Int(argumentCount))
        for _ in 0 ..< argumentCount {
            try arguments.append(cursor.readLengthPrefixedData())
        }
        let commandFormat = try cursor.readLengthPrefixedData()
        let environmentIdentity = try cursor.readLengthPrefixedData()
        let commandOutputDigest = try cursor.readLengthPrefixedData()
        let rootPrefix = try cursor.readLengthPrefixedData()
        let objectFormat = try cursor.readLengthPrefixedData()
        let base = try cursor.readOptionalData()
        let target = try cursor.readOptionalData()
        let suppliedProvenance = try cursor.readOptionalData()
        let sparsePresent = try cursor.readUInt8()
        guard sparsePresent <= 1 else {
            throw GitTargetEvidenceManifestError.corrupt("invalid sparse-checkout optional")
        }
        let sparseCheckoutEnabled = sparsePresent == 1 ? try cursor.readBool() : nil
        guard cursor.remaining == 0,
              !physical.canonicalPathBytes.isEmpty,
              !common.canonicalPathBytes.isEmpty,
              !gitDirectory.canonicalPathBytes.isEmpty,
              !commandFormat.isEmpty,
              environmentIdentity.count == SHA256.byteCount,
              commandOutputDigest.count == SHA256.byteCount,
              !objectFormat.isEmpty,
              !snapshotDigest.isEmpty
        else { throw GitTargetEvidenceManifestError.corrupt("invalid header identity") }
        return GitTargetEvidenceManifestHeader(
            schemaVersion: schemaVersion,
            family: family,
            identity: GitTargetEvidenceArtifactIdentity(
                physicalWorktree: physical,
                repositoryCommonDirectory: common,
                repositoryGitDirectory: gitDirectory,
                authority: GitTargetEvidenceAuthorityIdentity(
                    authorityGeneration: authorityGeneration,
                    invalidationGeneration: invalidationGeneration,
                    acceptedMetadataWatermark: watermark,
                    attemptID: attemptID,
                    snapshotDigestBytes: snapshotDigest
                ),
                commandArguments: arguments,
                commandFormatBytes: commandFormat,
                environmentIdentityBytes: environmentIdentity,
                commandOutputDigestBytes: commandOutputDigest,
                repositoryRelativeRootPrefixBytes: rootPrefix,
                objectFormatBytes: objectFormat,
                baseObjectIDBytes: base,
                targetObjectIDBytes: target,
                suppliedCreationCutProvenanceBytes: suppliedProvenance,
                sparseCheckoutEnabled: sparseCheckoutEnabled
            )
        )
    }
}

struct GitTargetEvidenceByteCursor {
    let data: Data
    var offset = 0

    init(_ data: Data) {
        self.data = data
    }

    var remaining: Int {
        data.count - offset
    }

    mutating func readData(count: Int) throws -> Data {
        guard count >= 0, count <= remaining else {
            throw GitTargetEvidenceManifestError.corrupt("truncated payload")
        }
        defer { offset += count }
        return Data(data[offset ..< offset + count])
    }

    mutating func readUInt8() throws -> UInt8 {
        guard remaining >= 1 else { throw GitTargetEvidenceManifestError.corrupt("truncated integer") }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readUInt16() throws -> UInt16 {
        try UInt16(readUInt8()) | UInt16(readUInt8()) << 8
    }

    mutating func readUInt32() throws -> UInt32 {
        var value: UInt32 = 0
        for shift in stride(from: 0, to: 32, by: 8) {
            try value |= UInt32(readUInt8()) << UInt32(shift)
        }
        return value
    }

    mutating func readUInt64() throws -> UInt64 {
        var value: UInt64 = 0
        for shift in stride(from: 0, to: 64, by: 8) {
            try value |= UInt64(readUInt8()) << UInt64(shift)
        }
        return value
    }

    mutating func readBool() throws -> Bool {
        let byte = try readUInt8()
        guard byte <= 1 else { throw GitTargetEvidenceManifestError.corrupt("invalid boolean") }
        return byte == 1
    }

    mutating func readLengthPrefixedData() throws -> Data {
        try readData(count: Int(readUInt32()))
    }

    mutating func readOptionalData() throws -> Data? {
        let present = try readUInt8()
        guard present <= 1 else { throw GitTargetEvidenceManifestError.corrupt("invalid optional") }
        return present == 1 ? try readLengthPrefixedData() : nil
    }

    mutating func readOptionalUInt8() throws -> UInt8? {
        let present = try readUInt8()
        guard present <= 1 else { throw GitTargetEvidenceManifestError.corrupt("invalid optional") }
        return present == 1 ? try readUInt8() : nil
    }

    mutating func readOptionalUInt16() throws -> UInt16? {
        let present = try readUInt8()
        guard present <= 1 else { throw GitTargetEvidenceManifestError.corrupt("invalid optional") }
        return present == 1 ? try readUInt16() : nil
    }

    mutating func readFileSystemIdentity() throws -> GitTargetEvidenceFileSystemIdentity {
        try GitTargetEvidenceFileSystemIdentity(
            canonicalPathBytes: readLengthPrefixedData(),
            device: readUInt64(),
            inode: readUInt64()
        )
    }
}

struct GitTargetTreeDeltaRecordCodec: GitTargetEvidenceRecordCodec {
    static let family = GitTargetEvidenceFamily.treeDelta
    static let fileExtension = "tree-delta-evidence"

    static func validate(_ record: GitTargetTreeDeltaEvidenceRecord) throws {
        try GitTargetEvidenceManifestCodec.validatePath(record.repositoryRelativePathBytes, label: "target path")
        try record.sourceRepositoryRelativePathBytes.map {
            try GitTargetEvidenceManifestCodec.validatePath($0, label: "source path")
        }
        try GitTargetEvidenceManifestCodec.validateMode(record.oldModeBytes, label: "old mode")
        try GitTargetEvidenceManifestCodec.validateMode(record.newModeBytes, label: "new mode")
        try GitTargetEvidenceManifestCodec.validateOID(record.oldObjectIDBytes, label: "old object ID")
        try GitTargetEvidenceManifestCodec.validateOID(record.newObjectIDBytes, label: "new object ID")
        switch record.status {
        case .added:
            guard record.oldModeBytes == nil, record.oldObjectIDBytes == nil,
                  record.newModeBytes != nil, record.newObjectIDBytes != nil,
                  record.sourceRepositoryRelativePathBytes == nil,
                  record.similarityScore == nil
            else { throw GitTargetEvidenceManifestError.invalidRecord("incomplete add") }
        case .deleted, .renamedSource:
            guard record.oldModeBytes != nil, record.oldObjectIDBytes != nil,
                  record.newModeBytes == nil, record.newObjectIDBytes == nil,
                  record.sourceRepositoryRelativePathBytes == nil,
                  record.similarityScore == nil
            else { throw GitTargetEvidenceManifestError.invalidRecord("incomplete removal") }
        case .renamed, .copied:
            guard record.sourceRepositoryRelativePathBytes != nil,
                  let score = record.similarityScore, score <= 100,
                  record.oldModeBytes != nil, record.oldObjectIDBytes != nil,
                  record.newModeBytes != nil, record.newObjectIDBytes != nil
            else { throw GitTargetEvidenceManifestError.invalidRecord("incomplete rename/copy") }
        case .modified, .typeChanged, .unmerged:
            guard record.oldModeBytes != nil, record.oldObjectIDBytes != nil,
                  record.newModeBytes != nil, record.newObjectIDBytes != nil
            else {
                throw GitTargetEvidenceManifestError.invalidRecord("incomplete delta change")
            }
            guard record.sourceRepositoryRelativePathBytes == nil, record.similarityScore == nil else {
                throw GitTargetEvidenceManifestError.invalidRecord("unexpected rename/copy fields")
            }
        }
    }

    static func validate(
        _ record: GitTargetTreeDeltaEvidenceRecord,
        objectFormatBytes: Data
    ) throws {
        try validate(record)
        try validateObjectFormat(
            objectFormatBytes,
            objectIDs: [record.oldObjectIDBytes, record.newObjectIDBytes]
        )
    }

    static func encode(_ record: GitTargetTreeDeltaEvidenceRecord) throws -> Data {
        try validate(record)
        var data = Data([record.status.rawValue])
        GitTargetEvidenceManifestCodec.appendOptional(record.similarityScore, to: &data)
        GitTargetEvidenceManifestCodec.appendOptional(record.oldModeBytes, to: &data)
        GitTargetEvidenceManifestCodec.appendOptional(record.newModeBytes, to: &data)
        GitTargetEvidenceManifestCodec.appendOptional(record.oldObjectIDBytes, to: &data)
        GitTargetEvidenceManifestCodec.appendOptional(record.newObjectIDBytes, to: &data)
        GitTargetEvidenceManifestCodec.appendOptional(record.sourceRepositoryRelativePathBytes, to: &data)
        GitTargetEvidenceManifestCodec.append(record.repositoryRelativePathBytes, to: &data)
        return data
    }

    static func decode(_ payload: Data) throws -> GitTargetTreeDeltaEvidenceRecord {
        var cursor = GitTargetEvidenceByteCursor(payload)
        guard let status = try GitTargetTreeDeltaEvidenceStatus(rawValue: cursor.readUInt8()) else {
            throw GitTargetEvidenceManifestError.corrupt("invalid delta status")
        }
        let similarityScore = try cursor.readOptionalUInt16()
        let decoded = try GitTargetTreeDeltaEvidenceRecord(
            oldModeBytes: cursor.readOptionalData(),
            newModeBytes: cursor.readOptionalData(),
            oldObjectIDBytes: cursor.readOptionalData(),
            newObjectIDBytes: cursor.readOptionalData(),
            status: status,
            similarityScore: similarityScore,
            sourceRepositoryRelativePathBytes: cursor.readOptionalData(),
            repositoryRelativePathBytes: cursor.readLengthPrefixedData()
        )
        guard cursor.remaining == 0 else { throw GitTargetEvidenceManifestError.corrupt("trailing delta payload") }
        try validate(decoded)
        return decoded
    }

    static func ordering(
        _ lhs: GitTargetTreeDeltaEvidenceRecord,
        _ rhs: GitTargetTreeDeltaEvidenceRecord
    ) -> SpillBackedSortedArtifactOrdering {
        let pathOrder = compare(lhs.repositoryRelativePathBytes, rhs.repositoryRelativePathBytes)
        guard pathOrder == .same else { return pathOrder }
        let lhsOrder = operationOrder(lhs.status)
        let rhsOrder = operationOrder(rhs.status)
        if lhsOrder == rhsOrder { return .same }
        return lhsOrder < rhsOrder ? .ascending : .descending
    }

    static func pathPayloadByteCount(_ record: GitTargetTreeDeltaEvidenceRecord) throws -> UInt64 {
        try exactPathCount(record.repositoryRelativePathBytes.count + (record.sourceRepositoryRelativePathBytes?.count ?? 0))
    }
}

struct GitTargetIndexRecordCodec: GitTargetEvidenceRecordCodec {
    static let family = GitTargetEvidenceFamily.index
    static let fileExtension = "index-evidence"

    static func validate(_ record: GitTargetIndexEvidenceRecord) throws {
        guard record.stage <= 3 else { throw GitTargetEvidenceManifestError.invalidRecord("invalid stage") }
        try GitTargetEvidenceManifestCodec.validatePath(record.repositoryRelativePathBytes, label: "index path")
        try GitTargetEvidenceManifestCodec.validateMode(record.modeBytes, label: "index mode")
        try GitTargetEvidenceManifestCodec.validateOID(record.objectIDBytes, label: "index object ID")
    }

    static func validate(
        _ record: GitTargetIndexEvidenceRecord,
        objectFormatBytes: Data
    ) throws {
        try validate(record)
        try validateObjectFormat(objectFormatBytes, objectIDs: [record.objectIDBytes])
    }

    static func encode(_ record: GitTargetIndexEvidenceRecord) throws -> Data {
        try validate(record)
        var data = Data([record.stage, record.assumeUnchanged ? 1 : 0, record.skipWorktree ? 1 : 0])
        GitTargetEvidenceManifestCodec.append(record.modeBytes, to: &data)
        GitTargetEvidenceManifestCodec.append(record.objectIDBytes, to: &data)
        GitTargetEvidenceManifestCodec.append(record.repositoryRelativePathBytes, to: &data)
        return data
    }

    static func decode(_ payload: Data) throws -> GitTargetIndexEvidenceRecord {
        var cursor = GitTargetEvidenceByteCursor(payload)
        let stage = try cursor.readUInt8()
        let assumeUnchanged = try cursor.readBool()
        let skipWorktree = try cursor.readBool()
        let record = try GitTargetIndexEvidenceRecord(
            modeBytes: cursor.readLengthPrefixedData(),
            objectIDBytes: cursor.readLengthPrefixedData(),
            stage: stage,
            repositoryRelativePathBytes: cursor.readLengthPrefixedData(),
            assumeUnchanged: assumeUnchanged,
            skipWorktree: skipWorktree
        )
        guard cursor.remaining == 0 else { throw GitTargetEvidenceManifestError.corrupt("trailing index payload") }
        try validate(record)
        return record
    }

    static func ordering(
        _ lhs: GitTargetIndexEvidenceRecord,
        _ rhs: GitTargetIndexEvidenceRecord
    ) -> SpillBackedSortedArtifactOrdering {
        let pathOrder = compare(lhs.repositoryRelativePathBytes, rhs.repositoryRelativePathBytes)
        guard pathOrder == .same else { return pathOrder }
        if lhs.stage == rhs.stage { return .same }
        return lhs.stage < rhs.stage ? .ascending : .descending
    }

    static func duplicateResolution(
        _ existing: GitTargetIndexEvidenceRecord,
        _ candidate: GitTargetIndexEvidenceRecord
    ) throws -> SpillBackedSortedArtifactDuplicateResolution {
        // Git may repeat an identical stage/path entry, but conflicting
        // semantics for the same key make the index evidence ambiguous.
        existing == candidate ? .coalesce : .reject
    }

    static func pathPayloadByteCount(_ record: GitTargetIndexEvidenceRecord) throws -> UInt64 {
        try exactPathCount(record.repositoryRelativePathBytes.count)
    }
}

struct GitTargetStatusRecordCodec: GitTargetEvidenceRecordCodec {
    static let family = GitTargetEvidenceFamily.porcelainV2Status
    static let fileExtension = "status-evidence"

    static func validate(_ record: GitTargetStatusEvidenceRecord) throws {
        try GitTargetEvidenceManifestCodec.validatePath(record.repositoryRelativePathBytes, label: "status path")
        try record.sourceRepositoryRelativePathBytes.map {
            try GitTargetEvidenceManifestCodec.validatePath($0, label: "status source path")
        }
        for (mode, label) in [
            (record.headModeBytes, "head mode"), (record.indexModeBytes, "index mode"),
            (record.workTreeModeBytes, "worktree mode"), (record.conflictStage1ModeBytes, "stage 1 mode"),
            (record.conflictStage2ModeBytes, "stage 2 mode"), (record.conflictStage3ModeBytes, "stage 3 mode")
        ] {
            try GitTargetEvidenceManifestCodec.validateMode(mode, label: label)
        }
        for (oid, label) in [
            (record.headObjectIDBytes, "head object ID"), (record.indexObjectIDBytes, "index object ID"),
            (record.conflictStage1ObjectIDBytes, "stage 1 object ID"),
            (record.conflictStage2ObjectIDBytes, "stage 2 object ID"),
            (record.conflictStage3ObjectIDBytes, "stage 3 object ID")
        ] {
            try GitTargetEvidenceManifestCodec.validateOID(oid, label: label)
        }
        if let state = record.submoduleStateBytes, state.count != 4 {
            throw GitTargetEvidenceManifestError.invalidRecord("invalid submodule state")
        }
        switch record.kind {
        case .renamed, .copied:
            guard record.sourceRepositoryRelativePathBytes != nil,
                  let score = record.similarityScore, score <= 100,
                  record.indexStatus != nil, record.workTreeStatus != nil,
                  record.submoduleStateBytes != nil, record.headModeBytes != nil,
                  record.indexModeBytes != nil, record.workTreeModeBytes != nil,
                  record.headObjectIDBytes != nil, record.indexObjectIDBytes != nil
            else { throw GitTargetEvidenceManifestError.invalidRecord("incomplete status rename/copy") }
            guard !record.isDirectoryMarker else {
                throw GitTargetEvidenceManifestError.invalidRecord("tracked directory marker")
            }
        case .ordinary:
            guard record.sourceRepositoryRelativePathBytes == nil, record.similarityScore == nil,
                  record.indexStatus != nil, record.workTreeStatus != nil,
                  record.submoduleStateBytes != nil, record.headModeBytes != nil,
                  record.indexModeBytes != nil, record.workTreeModeBytes != nil,
                  record.headObjectIDBytes != nil, record.indexObjectIDBytes != nil
            else { throw GitTargetEvidenceManifestError.invalidRecord("invalid ordinary status") }
            guard !record.isDirectoryMarker else {
                throw GitTargetEvidenceManifestError.invalidRecord("tracked directory marker")
            }
        case .unmerged:
            guard record.sourceRepositoryRelativePathBytes == nil, record.similarityScore == nil,
                  record.indexStatus != nil, record.workTreeStatus != nil,
                  record.conflictStage1ModeBytes != nil, record.conflictStage2ModeBytes != nil,
                  record.conflictStage3ModeBytes != nil, record.conflictStage1ObjectIDBytes != nil,
                  record.conflictStage2ObjectIDBytes != nil, record.conflictStage3ObjectIDBytes != nil
            else { throw GitTargetEvidenceManifestError.invalidRecord("incomplete unmerged status") }
            guard !record.isDirectoryMarker else {
                throw GitTargetEvidenceManifestError.invalidRecord("tracked directory marker")
            }
        case .untracked, .ignored:
            guard record.sourceRepositoryRelativePathBytes == nil, record.similarityScore == nil,
                  record.indexStatus == nil, record.workTreeStatus == nil,
                  record.submoduleStateBytes == nil, record.headModeBytes == nil,
                  record.indexModeBytes == nil, record.workTreeModeBytes == nil,
                  record.headObjectIDBytes == nil, record.indexObjectIDBytes == nil,
                  record.conflictStage1ModeBytes == nil, record.conflictStage2ModeBytes == nil,
                  record.conflictStage3ModeBytes == nil, record.conflictStage1ObjectIDBytes == nil,
                  record.conflictStage2ObjectIDBytes == nil, record.conflictStage3ObjectIDBytes == nil
            else { throw GitTargetEvidenceManifestError.invalidRecord("unexpected untracked metadata") }
        }
    }

    static func validate(
        _ record: GitTargetStatusEvidenceRecord,
        objectFormatBytes: Data
    ) throws {
        try validate(record)
        try validateObjectFormat(objectFormatBytes, objectIDs: [
            record.headObjectIDBytes, record.indexObjectIDBytes,
            record.conflictStage1ObjectIDBytes, record.conflictStage2ObjectIDBytes,
            record.conflictStage3ObjectIDBytes
        ])
    }

    static func encode(_ record: GitTargetStatusEvidenceRecord) throws -> Data {
        try validate(record)
        var data = Data([record.kind.rawValue])
        GitTargetEvidenceManifestCodec.append(record.repositoryRelativePathBytes, to: &data)
        GitTargetEvidenceManifestCodec.appendOptional(record.sourceRepositoryRelativePathBytes, to: &data)
        GitTargetEvidenceManifestCodec.appendOptional(record.similarityScore, to: &data)
        data.append(record.isDirectoryMarker ? 1 : 0)
        GitTargetEvidenceManifestCodec.appendOptional(record.indexStatus, to: &data)
        GitTargetEvidenceManifestCodec.appendOptional(record.workTreeStatus, to: &data)
        let fields = [
            record.submoduleStateBytes,
            record.headModeBytes,
            record.indexModeBytes,
            record.workTreeModeBytes,
            record.headObjectIDBytes,
            record.indexObjectIDBytes,
            record.conflictStage1ModeBytes,
            record.conflictStage2ModeBytes,
            record.conflictStage3ModeBytes,
            record.conflictStage1ObjectIDBytes,
            record.conflictStage2ObjectIDBytes,
            record.conflictStage3ObjectIDBytes
        ]
        for field in fields {
            GitTargetEvidenceManifestCodec.appendOptional(field, to: &data)
        }
        return data
    }

    static func decode(_ payload: Data) throws -> GitTargetStatusEvidenceRecord {
        var cursor = GitTargetEvidenceByteCursor(payload)
        guard let kind = try GitTargetStatusEvidenceKind(rawValue: cursor.readUInt8()) else {
            throw GitTargetEvidenceManifestError.corrupt("invalid status kind")
        }
        let record = try GitTargetStatusEvidenceRecord(
            kind: kind,
            repositoryRelativePathBytes: cursor.readLengthPrefixedData(),
            sourceRepositoryRelativePathBytes: cursor.readOptionalData(),
            similarityScore: cursor.readOptionalUInt16(),
            isDirectoryMarker: cursor.readBool(),
            indexStatus: cursor.readOptionalUInt8(),
            workTreeStatus: cursor.readOptionalUInt8(),
            submoduleStateBytes: cursor.readOptionalData(),
            headModeBytes: cursor.readOptionalData(),
            indexModeBytes: cursor.readOptionalData(),
            workTreeModeBytes: cursor.readOptionalData(),
            headObjectIDBytes: cursor.readOptionalData(),
            indexObjectIDBytes: cursor.readOptionalData(),
            conflictStage1ModeBytes: cursor.readOptionalData(),
            conflictStage2ModeBytes: cursor.readOptionalData(),
            conflictStage3ModeBytes: cursor.readOptionalData(),
            conflictStage1ObjectIDBytes: cursor.readOptionalData(),
            conflictStage2ObjectIDBytes: cursor.readOptionalData(),
            conflictStage3ObjectIDBytes: cursor.readOptionalData()
        )
        guard cursor.remaining == 0 else { throw GitTargetEvidenceManifestError.corrupt("trailing status payload") }
        try validate(record)
        return record
    }

    static func ordering(
        _ lhs: GitTargetStatusEvidenceRecord,
        _ rhs: GitTargetStatusEvidenceRecord
    ) -> SpillBackedSortedArtifactOrdering {
        compare(lhs.repositoryRelativePathBytes, rhs.repositoryRelativePathBytes)
    }

    static func pathPayloadByteCount(_ record: GitTargetStatusEvidenceRecord) throws -> UInt64 {
        try exactPathCount(record.repositoryRelativePathBytes.count + (record.sourceRepositoryRelativePathBytes?.count ?? 0))
    }
}

private func compare(_ lhs: Data, _ rhs: Data) -> SpillBackedSortedArtifactOrdering {
    if lhs == rhs { return .same }
    return lhs.lexicographicallyPrecedes(rhs) ? .ascending : .descending
}

private func operationOrder(_ status: GitTargetTreeDeltaEvidenceStatus) -> UInt8 {
    switch status {
    case .deleted, .renamedSource: 0
    case .added, .modified, .typeChanged, .renamed, .copied, .unmerged: 1
    }
}

private func exactPathCount(_ value: Int) throws -> UInt64 {
    guard let result = UInt64(exactly: value) else {
        throw GitTargetEvidenceManifestError.corrupt("path byte count overflow")
    }
    return result
}

private func validateObjectFormat(_ objectFormatBytes: Data, objectIDs: [Data?]) throws {
    let expectedCount: Int
    switch objectFormatBytes {
    case Data("sha1".utf8): expectedCount = 40
    case Data("sha256".utf8): expectedCount = 64
    default: throw GitTargetEvidenceManifestError.invalidConfiguration
    }
    guard objectIDs.compactMap(\.self).allSatisfy({ $0.count == expectedCount }) else {
        throw GitTargetEvidenceManifestError.invalidRecord("object ID format mismatch")
    }
}

/// Forward-only typed reader. Records are provisional until `next()` returns
/// nil and `validationState` becomes `.verified` on the same descriptor.
final class GitTargetEvidenceManifestReader<Codec: GitTargetEvidenceRecordCodec>: @unchecked Sendable {
    let header: GitTargetEvidenceManifestHeader
    private(set) var footer: GitTargetEvidenceManifestFooter?
    private(set) var validationState = GitTargetEvidenceReaderValidationState.reading

    private let descriptor: Int32
    private let retainedLease: GitTargetEvidenceManifestLease<Codec>
    private var digest: SHA256
    private var previousRecord: Codec.Record?
    private var recordCount: UInt64 = 0
    private var recordPayloadByteCount: UInt64 = 0
    private var pathPayloadByteCount: UInt64 = 0
    private let lock = NSLock()

    init(descriptor: Int32, lease: GitTargetEvidenceManifestLease<Codec>) throws {
        self.descriptor = descriptor
        retainedLease = lease
        let headerFrame = try GitTargetEvidenceManifestCodec.readHeaderFrame(from: descriptor)
        guard headerFrame.header == lease.header, headerFrame.header.family == Codec.family else {
            throw GitTargetEvidenceManifestError.corrupt("lease header mismatch")
        }
        var digest = SHA256()
        digest.update(data: headerFrame.encodedFrame)
        self.digest = digest
        header = headerFrame.header
        try lease.validateOpenDescriptor(descriptor)
    }

    deinit { Darwin.close(descriptor) }

    func next() throws -> Codec.Record? {
        lock.lock()
        defer { lock.unlock() }
        switch validationState {
        case .verified: return nil
        case .failed: throw GitTargetEvidenceManifestError.corrupt("reader validation already failed")
        case .reading: break
        }
        do { return try readNext() }
        catch {
            validationState = .failed
            throw error
        }
    }

    private func readNext() throws -> Codec.Record? {
        try retainedLease.validateOpenDescriptor(descriptor)
        let marker = try GitTargetEvidenceManifestCodec.readExact(descriptor, count: 1)
        guard let byte = marker.first else { throw GitTargetEvidenceManifestError.corrupt("missing footer") }
        switch byte {
        case GitTargetEvidenceManifestCodec.recordMarker:
            let lengthData = try GitTargetEvidenceManifestCodec.readExact(descriptor, count: 4)
            var cursor = GitTargetEvidenceByteCursor(lengthData)
            let length = try cursor.readUInt32()
            guard length > 0, length <= GitTargetEvidenceManifestCodec.maximumRecordPayloadByteCount else {
                throw GitTargetEvidenceManifestError.corrupt("invalid record length")
            }
            let payload = try GitTargetEvidenceManifestCodec.readExact(descriptor, count: Int(length))
            var frame = marker
            frame.append(lengthData)
            frame.append(payload)
            digest.update(data: frame)
            let record = try Codec.decode(payload)
            try Codec.validate(record, objectFormatBytes: header.identity.objectFormatBytes)
            if let previousRecord {
                switch Codec.ordering(previousRecord, record) {
                case .ascending: break
                case .same: throw GitTargetEvidenceManifestError.duplicateRecord
                case .descending: throw GitTargetEvidenceManifestError.outOfOrder
                }
            }
            previousRecord = record
            recordCount = try adding(recordCount, 1, label: "record count")
            recordPayloadByteCount = try adding(
                recordPayloadByteCount, UInt64(payload.count), label: "record payload byte count"
            )
            pathPayloadByteCount = try adding(
                pathPayloadByteCount, Codec.pathPayloadByteCount(record), label: "path payload byte count"
            )
            return record

        case GitTargetEvidenceManifestCodec.footerMarker:
            let payload = try GitTargetEvidenceManifestCodec.readExact(
                descriptor, count: GitTargetEvidenceManifestCodec.footerPayloadByteCount
            )
            let parsed = try GitTargetEvidenceManifestCodec.decodeFooter(payload)
            guard parsed.recordCount == recordCount,
                  parsed.recordPayloadByteCount == recordPayloadByteCount,
                  parsed.pathPayloadByteCount == pathPayloadByteCount,
                  parsed.digest == Data(digest.finalize())
            else { throw GitTargetEvidenceManifestError.corrupt("footer mismatch") }
            var trailing: UInt8 = 0
            let trailingCount = Darwin.read(descriptor, &trailing, 1)
            if trailingCount < 0 { throw GitTargetEvidenceManifestError.io(operation: "trailing-read", code: errno) }
            guard trailingCount == 0 else { throw GitTargetEvidenceManifestError.corrupt("trailing bytes") }
            try retainedLease.validateOpenDescriptor(descriptor)
            footer = parsed
            validationState = .verified
            return nil

        default:
            throw GitTargetEvidenceManifestError.corrupt("invalid frame marker")
        }
    }

    private func adding(_ lhs: UInt64, _ rhs: UInt64, label: String) throws -> UInt64 {
        let (result, overflowed) = lhs.addingReportingOverflow(rhs)
        guard !overflowed else { throw GitTargetEvidenceManifestError.corrupt("\(label) overflow") }
        return result
    }
}

typealias GitTargetTreeDeltaEvidenceReader = GitTargetEvidenceManifestReader<GitTargetTreeDeltaRecordCodec>
typealias GitTargetIndexEvidenceReader = GitTargetEvidenceManifestReader<GitTargetIndexRecordCodec>
typealias GitTargetStatusEvidenceReader = GitTargetEvidenceManifestReader<GitTargetStatusRecordCodec>

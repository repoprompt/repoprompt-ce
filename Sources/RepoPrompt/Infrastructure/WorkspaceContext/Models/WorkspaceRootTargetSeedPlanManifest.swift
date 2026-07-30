import CryptoKit
import Darwin
import Foundation

extension WorkspaceRootNamespaceManifestIdentity: @unchecked Sendable {}
extension GitTargetEvidenceAuthorityIdentity: @unchecked Sendable {}

enum WorkspaceRootTargetSeedPlanDisposition: UInt8, Equatable {
    case ordinaryFile = 1
    case ordinaryDirectory = 2
    case policyIgnoredTrackedFile = 3
    case baseTombstone = 4
}

enum WorkspaceRootTargetSeedPlanBaseAction: UInt8, Equatable {
    case none = 0
    case reuse = 1
    case overlay = 2
    case tombstone = 3
}

/// One byte-exact target namespace entry, or one explicit searchable-base
/// tombstone. Directory records are first-class and therefore preserve empty
/// directory topology without inferring it from file ancestors.
struct WorkspaceRootTargetSeedPlanRecord: Equatable {
    let relativePathBytes: Data
    let disposition: WorkspaceRootTargetSeedPlanDisposition
    let baseAction: WorkspaceRootTargetSeedPlanBaseAction
    let fileSystemMode: UInt16
    let baseOrdinal: UInt64?
    let targetModeBytes: Data?
    let targetObjectIDBytes: Data?

    init(
        relativePathBytes: Data,
        disposition: WorkspaceRootTargetSeedPlanDisposition,
        baseAction: WorkspaceRootTargetSeedPlanBaseAction,
        fileSystemMode: UInt16 = 0,
        baseOrdinal: UInt64? = nil,
        targetModeBytes: Data? = nil,
        targetObjectIDBytes: Data? = nil
    ) {
        self.relativePathBytes = relativePathBytes
        self.disposition = disposition
        self.baseAction = baseAction
        self.fileSystemMode = fileSystemMode
        self.baseOrdinal = baseOrdinal
        self.targetModeBytes = targetModeBytes
        self.targetObjectIDBytes = targetObjectIDBytes
    }
}

struct WorkspaceRootTargetSeedPlanManifestHeader: Equatable {
    static let currentSchemaVersion: UInt32 = 1

    let schemaVersion: UInt32
    let snapshotIdentityBytes: Data
    let targetTreeOIDBytes: Data
    let objectFormatBytes: Data
    let repositoryRelativeRootPrefixBytes: Data
    let namespaceIdentity: WorkspaceRootNamespaceManifestIdentity
    let namespaceDigest: Data
    let treeDeltaDigest: Data
    let indexDigest: Data
    let statusDigest: Data
    let authorityIdentity: GitTargetEvidenceAuthorityIdentity
    let suppliedCreationCutProvenanceBytes: Data?

    init(
        schemaVersion: UInt32 = Self.currentSchemaVersion,
        snapshotIdentityBytes: Data,
        targetTreeOIDBytes: Data,
        objectFormatBytes: Data,
        repositoryRelativeRootPrefixBytes: Data,
        namespaceIdentity: WorkspaceRootNamespaceManifestIdentity,
        namespaceDigest: Data,
        treeDeltaDigest: Data,
        indexDigest: Data,
        statusDigest: Data,
        authorityIdentity: GitTargetEvidenceAuthorityIdentity,
        suppliedCreationCutProvenanceBytes: Data?
    ) {
        self.schemaVersion = schemaVersion
        self.snapshotIdentityBytes = snapshotIdentityBytes
        self.targetTreeOIDBytes = targetTreeOIDBytes
        self.objectFormatBytes = objectFormatBytes
        self.repositoryRelativeRootPrefixBytes = repositoryRelativeRootPrefixBytes
        self.namespaceIdentity = namespaceIdentity
        self.namespaceDigest = namespaceDigest
        self.treeDeltaDigest = treeDeltaDigest
        self.indexDigest = indexDigest
        self.statusDigest = statusDigest
        self.authorityIdentity = authorityIdentity
        self.suppliedCreationCutProvenanceBytes = suppliedCreationCutProvenanceBytes
    }
}

struct WorkspaceRootTargetSeedPlanManifestFooter: Equatable {
    let recordCount: UInt64
    let ordinaryFileCount: UInt64
    let ordinaryDirectoryCount: UInt64
    let policyIgnoredTrackedFileCount: UInt64
    let baseTombstoneCount: UInt64
    let reusedBaseFileCount: UInt64
    let overlayFileCount: UInt64
    let recordPayloadByteCount: UInt64
    let digest: Data
}

struct WorkspaceRootTargetSeedPlanManifestStatistics: Equatable {
    let initialRunCount: Int
    let mergePassCount: Int
    let peakBufferedRecordBytes: Int
    let recordCount: UInt64
    let finalByteCount: UInt64
}

enum WorkspaceRootTargetSeedPlanManifestError: Error, Equatable {
    case invalidConfiguration
    case invalidRecord(String)
    case duplicatePath
    case outOfOrder
    case resourceAdmission
    case closed
    case corrupt(String)
    case io(operation: String, code: Int32)
}

enum WorkspaceRootTargetSeedPlanReaderValidationState: Equatable {
    case reading
    case verified
    case failed
}

struct WorkspaceRootTargetSeedPlanResourcePolicy: Equatable {
    static let `default` = WorkspaceRootTargetSeedPlanResourcePolicy()

    let maximumBufferedRecordBytes: Int
    let maximumRecordsPerBatch: Int
    let maximumRecordByteCount: Int
    let maximumOpenRuns: Int
    let minimumFreeDiskBytes: UInt64

    init(
        maximumBufferedRecordBytes: Int = 16 * 1024 * 1024,
        maximumRecordsPerBatch: Int = 32768,
        maximumRecordByteCount: Int = 1024 * 1024,
        maximumOpenRuns: Int = 32,
        minimumFreeDiskBytes: UInt64 = 256 * 1024 * 1024
    ) {
        self.maximumBufferedRecordBytes = maximumBufferedRecordBytes
        self.maximumRecordsPerBatch = maximumRecordsPerBatch
        self.maximumRecordByteCount = maximumRecordByteCount
        self.maximumOpenRuns = maximumOpenRuns
        self.minimumFreeDiskBytes = minimumFreeDiskBytes
    }

    fileprivate var isValid: Bool {
        maximumBufferedRecordBytes > 0 && maximumRecordsPerBatch > 0 &&
            maximumRecordByteCount > 0 &&
            maximumRecordByteCount <= WorkspaceRootTargetSeedPlanCodec.maximumRecordPayloadByteCount &&
            maximumOpenRuns >= 2
    }

    fileprivate var spillPolicy: SpillBackedSortedArtifactResourcePolicy {
        SpillBackedSortedArtifactResourcePolicy(
            maximumBufferedRecordBytes: maximumBufferedRecordBytes,
            maximumRecordsPerBatch: maximumRecordsPerBatch,
            maximumRecordByteCount: maximumRecordByteCount,
            maximumOpenRuns: maximumOpenRuns,
            minimumFreeDiskBytes: minimumFreeDiskBytes
        )
    }
}

private struct WorkspaceRootTargetSeedPlanAccumulator {
    var recordCount: UInt64 = 0
    var ordinaryFileCount: UInt64 = 0
    var ordinaryDirectoryCount: UInt64 = 0
    var policyIgnoredTrackedFileCount: UInt64 = 0
    var baseTombstoneCount: UInt64 = 0
    var reusedBaseFileCount: UInt64 = 0
    var overlayFileCount: UInt64 = 0
    var recordPayloadByteCount: UInt64 = 0
}

private enum WorkspaceRootTargetSeedPlanCodec {
    static let magic = Data("RPTGPLN1".utf8)
    static let recordMarker: UInt8 = 0x52
    static let footerMarker: UInt8 = 0x46
    static let digestByteCount = SHA256.byteCount
    static let maximumHeaderPayloadByteCount = 4 * 1024 * 1024
    static let maximumRecordPayloadByteCount = SpillBackedSortedArtifactChecked.maximumFrameByteCount - 5
    static let footerPayloadByteCount = 8 * 8 + digestByteCount

    struct DecodedHeaderFrame {
        let header: WorkspaceRootTargetSeedPlanManifestHeader
        let encodedFrame: Data
    }

    static func validate(_ record: WorkspaceRootTargetSeedPlanRecord) throws {
        try GitTargetEvidenceManifestCodec.validatePath(record.relativePathBytes, label: "plan path")
        if let mode = record.targetModeBytes {
            try GitTargetEvidenceManifestCodec.validateMode(mode, label: "plan target mode")
        }
        if let objectID = record.targetObjectIDBytes {
            try GitTargetEvidenceManifestCodec.validateOID(objectID, label: "plan target object ID")
        }
        switch record.disposition {
        case .ordinaryFile:
            guard record.baseAction == .reuse || record.baseAction == .overlay,
                  (record.targetModeBytes == nil) == (record.targetObjectIDBytes == nil),
                  record.baseAction != .reuse || record.targetModeBytes != nil
            else { throw WorkspaceRootTargetSeedPlanManifestError.invalidRecord("ordinary file metadata") }
        case .ordinaryDirectory:
            guard record.baseAction == .none || record.baseAction == .tombstone,
                  record.targetModeBytes == nil,
                  record.targetObjectIDBytes == nil
            else { throw WorkspaceRootTargetSeedPlanManifestError.invalidRecord("ordinary directory metadata") }
        case .policyIgnoredTrackedFile:
            guard record.baseAction == .none || record.baseAction == .tombstone,
                  record.targetModeBytes != nil,
                  record.targetObjectIDBytes != nil
            else { throw WorkspaceRootTargetSeedPlanManifestError.invalidRecord("policy-ignored metadata") }
        case .baseTombstone:
            guard record.baseAction == .tombstone,
                  record.fileSystemMode == 0,
                  record.targetModeBytes == nil,
                  record.targetObjectIDBytes == nil,
                  record.baseOrdinal != nil
            else { throw WorkspaceRootTargetSeedPlanManifestError.invalidRecord("base tombstone metadata") }
        }
        guard (record.baseAction == .reuse || record.baseAction == .tombstone) == (record.baseOrdinal != nil) else {
            throw WorkspaceRootTargetSeedPlanManifestError.invalidRecord("base action ordinal")
        }
    }

    static func encodeRecord(_ record: WorkspaceRootTargetSeedPlanRecord) throws -> Data {
        try validate(record)
        var data = Data([record.disposition.rawValue, record.baseAction.rawValue])
        append(record.fileSystemMode, to: &data)
        appendOptional(record.baseOrdinal, to: &data)
        appendOptional(record.targetModeBytes, to: &data)
        appendOptional(record.targetObjectIDBytes, to: &data)
        append(record.relativePathBytes, to: &data)
        guard data.count <= maximumRecordPayloadByteCount else {
            throw WorkspaceRootTargetSeedPlanManifestError.invalidRecord("record too large")
        }
        return data
    }

    static func decodeRecord(_ payload: Data) throws -> WorkspaceRootTargetSeedPlanRecord {
        var cursor = ByteCursor(payload)
        guard let disposition = try WorkspaceRootTargetSeedPlanDisposition(rawValue: cursor.readUInt8()),
              let baseAction = try WorkspaceRootTargetSeedPlanBaseAction(rawValue: cursor.readUInt8())
        else { throw WorkspaceRootTargetSeedPlanManifestError.corrupt("invalid plan enum") }
        let fileSystemMode = try cursor.readUInt16()
        let baseOrdinal = try cursor.readOptionalUInt64()
        let targetModeBytes = try cursor.readOptionalData()
        let targetObjectIDBytes = try cursor.readOptionalData()
        let relativePathBytes = try cursor.readData()
        let record = WorkspaceRootTargetSeedPlanRecord(
            relativePathBytes: relativePathBytes,
            disposition: disposition,
            baseAction: baseAction,
            fileSystemMode: fileSystemMode,
            baseOrdinal: baseOrdinal,
            targetModeBytes: targetModeBytes,
            targetObjectIDBytes: targetObjectIDBytes
        )
        guard cursor.isAtEnd else {
            throw WorkspaceRootTargetSeedPlanManifestError.corrupt("trailing plan record bytes")
        }
        try validate(record)
        return record
    }

    static func encodeHeader(_ header: WorkspaceRootTargetSeedPlanManifestHeader) throws -> Data {
        let policy = header.namespaceIdentity.catalogPolicy
        let fields = [
            header.snapshotIdentityBytes,
            header.targetTreeOIDBytes,
            header.objectFormatBytes,
            header.repositoryRelativeRootPrefixBytes,
            header.namespaceIdentity.root.canonicalPathBytes,
            Data(policy.mandatoryIgnorePolicyIdentity.utf8),
            Data(policy.globalIgnoreDefaultsDigest.utf8),
            header.namespaceDigest,
            header.treeDeltaDigest,
            header.indexDigest,
            header.statusDigest,
            header.authorityIdentity.snapshotDigestBytes,
            header.suppliedCreationCutProvenanceBytes ?? Data()
        ]
        guard header.schemaVersion == WorkspaceRootTargetSeedPlanManifestHeader.currentSchemaVersion,
              !header.snapshotIdentityBytes.isEmpty,
              policy.schemaVersion >= 0,
              policy.schemaVersion <= Int(UInt32.max),
              [Data("sha1".utf8), Data("sha256".utf8)].contains(header.objectFormatBytes),
              header.namespaceDigest.count == digestByteCount,
              header.treeDeltaDigest.count == digestByteCount,
              header.indexDigest.count == digestByteCount,
              header.statusDigest.count == digestByteCount,
              header.authorityIdentity.snapshotDigestBytes.count == digestByteCount,
              fields.allSatisfy({ $0.count <= maximumHeaderPayloadByteCount })
        else { throw WorkspaceRootTargetSeedPlanManifestError.invalidConfiguration }

        var payload = Data()
        for field in fields.prefix(5) {
            append(field, to: &payload)
        }
        append(header.namespaceIdentity.root.device, to: &payload)
        append(header.namespaceIdentity.root.inode, to: &payload)
        append(UInt32(policy.schemaVersion), to: &payload)
        append(fields[5], to: &payload)
        append(fields[6], to: &payload)
        payload.append(policy.respectRepoIgnore ? 1 : 0)
        payload.append(policy.respectCursorignore ? 1 : 0)
        payload.append(policy.enableHierarchicalIgnores ? 1 : 0)
        payload.append(policy.skipSymlinks ? 1 : 0)
        for field in fields.dropFirst(7).prefix(5) {
            append(field, to: &payload)
        }
        append(header.authorityIdentity.authorityGeneration, to: &payload)
        append(header.authorityIdentity.invalidationGeneration, to: &payload)
        append(header.authorityIdentity.acceptedMetadataWatermark, to: &payload)
        append(Data(header.authorityIdentity.attemptID.uuidString.lowercased().utf8), to: &payload)
        append(fields[12], to: &payload)
        payload.append(header.suppliedCreationCutProvenanceBytes == nil ? 0 : 1)
        guard payload.count <= maximumHeaderPayloadByteCount,
              let payloadCount = UInt32(exactly: payload.count)
        else { throw WorkspaceRootTargetSeedPlanManifestError.invalidConfiguration }
        var frame = magic
        append(header.schemaVersion, to: &frame)
        append(payloadCount, to: &frame)
        frame.append(payload)
        frame.append(Data(SHA256.hash(data: payload)))
        return frame
    }

    static func readHeaderFrame(from descriptor: Int32) throws -> DecodedHeaderFrame {
        let prefix = try readExact(descriptor, count: magic.count + 8)
        guard prefix.prefix(magic.count) == magic else {
            throw WorkspaceRootTargetSeedPlanManifestError.corrupt("invalid magic")
        }
        var prefixCursor = ByteCursor(Data(prefix.dropFirst(magic.count)))
        let schema = try prefixCursor.readUInt32()
        let payloadCount = try prefixCursor.readUInt32()
        guard schema == WorkspaceRootTargetSeedPlanManifestHeader.currentSchemaVersion,
              payloadCount <= maximumHeaderPayloadByteCount
        else { throw WorkspaceRootTargetSeedPlanManifestError.corrupt("unsupported header") }
        let payload = try readExact(descriptor, count: Int(payloadCount))
        let checksum = try readExact(descriptor, count: digestByteCount)
        guard checksum == Data(SHA256.hash(data: payload)) else {
            throw WorkspaceRootTargetSeedPlanManifestError.corrupt("header checksum")
        }
        let header = try decodeHeader(payload, schema: schema)
        var frame = prefix
        frame.append(payload)
        frame.append(checksum)
        return DecodedHeaderFrame(header: header, encodedFrame: frame)
    }

    private static func decodeHeader(
        _ payload: Data,
        schema: UInt32
    ) throws -> WorkspaceRootTargetSeedPlanManifestHeader {
        var cursor = ByteCursor(payload)
        let snapshot = try cursor.readData()
        let treeOID = try cursor.readData()
        let objectFormat = try cursor.readData()
        let prefix = try cursor.readData()
        let rootPath = try cursor.readData()
        let rootDevice = try cursor.readUInt64()
        let rootInode = try cursor.readUInt64()
        guard let policySchema = try Int(exactly: cursor.readUInt32()) else {
            throw WorkspaceRootTargetSeedPlanManifestError.corrupt("policy schema overflow")
        }
        let policyName = try cursor.readString()
        let globalIgnore = try cursor.readString()
        let respectRepo = try cursor.readBool()
        let respectCursor = try cursor.readBool()
        let hierarchical = try cursor.readBool()
        let skipSymlinks = try cursor.readBool()
        let namespaceDigest = try cursor.readData()
        let treeDigest = try cursor.readData()
        let indexDigest = try cursor.readData()
        let statusDigest = try cursor.readData()
        let authorityDigest = try cursor.readData()
        let authorityGeneration = try cursor.readUInt64()
        let invalidationGeneration = try cursor.readUInt64()
        let watermark = try cursor.readUInt64()
        let attemptBytes = try cursor.readData()
        guard let attemptString = String(data: attemptBytes, encoding: .utf8),
              let attemptID = UUID(uuidString: attemptString)
        else { throw WorkspaceRootTargetSeedPlanManifestError.corrupt("invalid attempt ID") }
        let provenanceBytes = try cursor.readData()
        let provenancePresent = try cursor.readBool()
        guard cursor.isAtEnd, provenancePresent || provenanceBytes.isEmpty else {
            throw WorkspaceRootTargetSeedPlanManifestError.corrupt("invalid header tail")
        }
        let header = WorkspaceRootTargetSeedPlanManifestHeader(
            schemaVersion: schema,
            snapshotIdentityBytes: snapshot,
            targetTreeOIDBytes: treeOID,
            objectFormatBytes: objectFormat,
            repositoryRelativeRootPrefixBytes: prefix,
            namespaceIdentity: WorkspaceRootNamespaceManifestIdentity(
                root: WorkspaceRootNamespaceRootIdentity(
                    canonicalPathBytes: rootPath,
                    device: rootDevice,
                    inode: rootInode
                ),
                catalogPolicy: WorkspaceRootCatalogPolicyIdentity(
                    schemaVersion: policySchema,
                    mandatoryIgnorePolicyIdentity: policyName,
                    globalIgnoreDefaultsDigest: globalIgnore,
                    respectRepoIgnore: respectRepo,
                    respectCursorignore: respectCursor,
                    enableHierarchicalIgnores: hierarchical,
                    skipSymlinks: skipSymlinks
                )
            ),
            namespaceDigest: namespaceDigest,
            treeDeltaDigest: treeDigest,
            indexDigest: indexDigest,
            statusDigest: statusDigest,
            authorityIdentity: GitTargetEvidenceAuthorityIdentity(
                authorityGeneration: authorityGeneration,
                invalidationGeneration: invalidationGeneration,
                acceptedMetadataWatermark: watermark,
                attemptID: attemptID,
                snapshotDigestBytes: authorityDigest
            ),
            suppliedCreationCutProvenanceBytes: provenancePresent ? provenanceBytes : nil
        )
        _ = try encodeHeader(header)
        return header
    }

    static func recordFrame(_ payload: Data) throws -> Data {
        guard let count = UInt32(exactly: payload.count), count > 0 else {
            throw WorkspaceRootTargetSeedPlanManifestError.invalidRecord("payload size")
        }
        var frame = Data([recordMarker])
        append(count, to: &frame)
        frame.append(payload)
        return frame
    }

    static func encodeFooter(_ footer: WorkspaceRootTargetSeedPlanManifestFooter) throws -> Data {
        guard footer.digest.count == digestByteCount else {
            throw WorkspaceRootTargetSeedPlanManifestError.corrupt("footer digest")
        }
        var payload = Data()
        for value in [
            footer.recordCount, footer.ordinaryFileCount, footer.ordinaryDirectoryCount,
            footer.policyIgnoredTrackedFileCount, footer.baseTombstoneCount,
            footer.reusedBaseFileCount, footer.overlayFileCount, footer.recordPayloadByteCount
        ] {
            append(value, to: &payload)
        }
        payload.append(footer.digest)
        return Data([footerMarker]) + payload
    }

    static func decodeFooter(_ payload: Data) throws -> WorkspaceRootTargetSeedPlanManifestFooter {
        guard payload.count == footerPayloadByteCount else {
            throw WorkspaceRootTargetSeedPlanManifestError.corrupt("footer size")
        }
        var cursor = ByteCursor(payload)
        let footer = try WorkspaceRootTargetSeedPlanManifestFooter(
            recordCount: cursor.readUInt64(),
            ordinaryFileCount: cursor.readUInt64(),
            ordinaryDirectoryCount: cursor.readUInt64(),
            policyIgnoredTrackedFileCount: cursor.readUInt64(),
            baseTombstoneCount: cursor.readUInt64(),
            reusedBaseFileCount: cursor.readUInt64(),
            overlayFileCount: cursor.readUInt64(),
            recordPayloadByteCount: cursor.readUInt64(),
            digest: cursor.readRaw(count: digestByteCount)
        )
        guard cursor.isAtEnd else { throw WorkspaceRootTargetSeedPlanManifestError.corrupt("footer tail") }
        return footer
    }

    static func readExact(_ descriptor: Int32, count: Int) throws -> Data {
        guard count >= 0 else { throw WorkspaceRootTargetSeedPlanManifestError.corrupt("negative read") }
        var data = Data(count: count)
        var offset = 0
        try data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            while offset < count {
                let amount = Darwin.read(descriptor, base.advanced(by: offset), count - offset)
                if amount > 0 { offset += amount }
                else if amount == 0 { throw WorkspaceRootTargetSeedPlanManifestError.corrupt("truncated file") }
                else if errno != EINTR { throw WorkspaceRootTargetSeedPlanManifestError.io(operation: "read", code: errno) }
            }
        }
        return data
    }

    static func append(_ value: UInt16, to data: inout Data) {
        var big = value.bigEndian
        withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
    }

    static func append(_ value: UInt32, to data: inout Data) {
        var big = value.bigEndian
        withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
    }

    static func append(_ value: UInt64, to data: inout Data) {
        var big = value.bigEndian
        withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
    }

    static func append(_ value: Data, to data: inout Data) {
        append(UInt32(value.count), to: &data)
        data.append(value)
    }

    static func appendOptional(_ value: UInt64?, to data: inout Data) {
        data.append(value == nil ? 0 : 1)
        if let value { append(value, to: &data) }
    }

    static func appendOptional(_ value: Data?, to data: inout Data) {
        data.append(value == nil ? 0 : 1)
        if let value { append(value, to: &data) }
    }

    fileprivate struct ByteCursor {
        let data: Data
        var offset = 0

        init(_ data: Data) {
            self.data = data
        }

        var isAtEnd: Bool {
            offset == data.count
        }

        mutating func readUInt8() throws -> UInt8 {
            guard offset < data.count else { throw WorkspaceRootTargetSeedPlanManifestError.corrupt("truncated integer") }
            defer { offset += 1 }
            return data[offset]
        }

        mutating func readUInt16() throws -> UInt16 {
            let bytes = try readRaw(count: 2)
            return bytes.reduce(UInt16(0)) { ($0 << 8) | UInt16($1) }
        }

        mutating func readUInt32() throws -> UInt32 {
            let bytes = try readRaw(count: 4)
            return bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }

        mutating func readUInt64() throws -> UInt64 {
            let bytes = try readRaw(count: 8)
            return bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        }

        mutating func readData() throws -> Data {
            let count = try readUInt32()
            return try readRaw(count: Int(count))
        }

        mutating func readString() throws -> String {
            let bytes = try readData()
            guard let value = String(data: bytes, encoding: .utf8) else {
                throw WorkspaceRootTargetSeedPlanManifestError.corrupt("invalid UTF-8")
            }
            return value
        }

        mutating func readBool() throws -> Bool {
            let value = try readUInt8()
            guard value <= 1 else { throw WorkspaceRootTargetSeedPlanManifestError.corrupt("invalid boolean") }
            return value == 1
        }

        mutating func readOptionalUInt64() throws -> UInt64? {
            try readBool() ? readUInt64() : nil
        }

        mutating func readOptionalData() throws -> Data? {
            try readBool() ? readData() : nil
        }

        mutating func readRaw(count: Int) throws -> Data {
            guard count >= 0, offset <= data.count, count <= data.count - offset else {
                throw WorkspaceRootTargetSeedPlanManifestError.corrupt("truncated payload")
            }
            defer { offset += count }
            return Data(data[offset ..< offset + count])
        }
    }
}

private struct WorkspaceRootTargetSeedPlanSpillFormat: SpillBackedSortedArtifactFormat {
    typealias Record = WorkspaceRootTargetSeedPlanRecord
    typealias Header = WorkspaceRootTargetSeedPlanManifestHeader
    typealias Footer = WorkspaceRootTargetSeedPlanManifestFooter
    typealias FinalAccumulator = WorkspaceRootTargetSeedPlanAccumulator

    let fileExtension = "target-seed-plan"
    let maximumEncodedHeaderByteCount = WorkspaceRootTargetSeedPlanCodec.magic.count + 8 +
        WorkspaceRootTargetSeedPlanCodec.maximumHeaderPayloadByteCount + SHA256.byteCount
    let maximumEncodedFooterByteCount = 1 + WorkspaceRootTargetSeedPlanCodec.footerPayloadByteCount

    func error(_ failure: SpillBackedSortedArtifactFailure) -> any Error {
        switch failure {
        case .invalidConfiguration: WorkspaceRootTargetSeedPlanManifestError.invalidConfiguration
        case .duplicateRecord: WorkspaceRootTargetSeedPlanManifestError.duplicatePath
        case .outOfOrder: WorkspaceRootTargetSeedPlanManifestError.outOfOrder
        case .resourceAdmission: WorkspaceRootTargetSeedPlanManifestError.resourceAdmission
        case .closed: WorkspaceRootTargetSeedPlanManifestError.closed
        case let .corrupt(message): WorkspaceRootTargetSeedPlanManifestError.corrupt(message)
        case let .io(operation, code): WorkspaceRootTargetSeedPlanManifestError.io(operation: operation, code: code)
        }
    }

    func validate(_ record: Record, maximumRecordByteCount: Int) throws {
        try WorkspaceRootTargetSeedPlanCodec.validate(record)
        guard try WorkspaceRootTargetSeedPlanCodec.encodeRecord(record).count <= maximumRecordByteCount else {
            throw WorkspaceRootTargetSeedPlanManifestError.resourceAdmission
        }
    }

    func encodeRecord(_ record: Record) throws -> Data {
        try WorkspaceRootTargetSeedPlanCodec.encodeRecord(record)
    }

    func decodeRecord(_ payload: Data) throws -> Record {
        try WorkspaceRootTargetSeedPlanCodec.decodeRecord(payload)
    }

    func maximumEncodedRecordByteCount(maximumRecordByteCount: Int) -> Int {
        maximumRecordByteCount
    }

    func maximumEncodedFinalRecordByteCount(maximumRecordByteCount: Int) -> Int {
        maximumRecordByteCount + 5
    }

    func ordering(_ lhs: Record, _ rhs: Record) -> SpillBackedSortedArtifactOrdering {
        if lhs.relativePathBytes == rhs.relativePathBytes { return .same }
        return lhs.relativePathBytes.lexicographicallyPrecedes(rhs.relativePathBytes) ? .ascending : .descending
    }

    func encodeFinalHeader(_ header: Header) throws -> Data {
        try WorkspaceRootTargetSeedPlanCodec.encodeHeader(header)
    }

    func encodeFinalRecord(_: Record, encodedRecord: Data) throws -> Data {
        try WorkspaceRootTargetSeedPlanCodec.recordFrame(encodedRecord)
    }

    func makeFinalAccumulator() -> FinalAccumulator {
        FinalAccumulator()
    }

    func accumulateFinalRecord(
        _ record: Record,
        encodedRecordByteCount: Int,
        into accumulator: inout FinalAccumulator
    ) throws {
        accumulator.recordCount = try add(accumulator.recordCount, 1)
        guard let byteCount = UInt64(exactly: encodedRecordByteCount) else {
            throw WorkspaceRootTargetSeedPlanManifestError.corrupt("record byte count overflow")
        }
        accumulator.recordPayloadByteCount = try add(accumulator.recordPayloadByteCount, byteCount)
        switch record.disposition {
        case .ordinaryFile: accumulator.ordinaryFileCount = try add(accumulator.ordinaryFileCount, 1)
        case .ordinaryDirectory: accumulator.ordinaryDirectoryCount = try add(accumulator.ordinaryDirectoryCount, 1)
        case .policyIgnoredTrackedFile:
            accumulator.policyIgnoredTrackedFileCount = try add(accumulator.policyIgnoredTrackedFileCount, 1)
        case .baseTombstone: accumulator.baseTombstoneCount = try add(accumulator.baseTombstoneCount, 1)
        }
        switch record.baseAction {
        case .reuse: accumulator.reusedBaseFileCount = try add(accumulator.reusedBaseFileCount, 1)
        case .overlay: accumulator.overlayFileCount = try add(accumulator.overlayFileCount, 1)
        case .none, .tombstone: break
        }
    }

    func makeFinalFooter(accumulator: FinalAccumulator, digest: Data) throws -> Footer {
        Footer(
            recordCount: accumulator.recordCount,
            ordinaryFileCount: accumulator.ordinaryFileCount,
            ordinaryDirectoryCount: accumulator.ordinaryDirectoryCount,
            policyIgnoredTrackedFileCount: accumulator.policyIgnoredTrackedFileCount,
            baseTombstoneCount: accumulator.baseTombstoneCount,
            reusedBaseFileCount: accumulator.reusedBaseFileCount,
            overlayFileCount: accumulator.overlayFileCount,
            recordPayloadByteCount: accumulator.recordPayloadByteCount,
            digest: digest
        )
    }

    func encodeFinalFooter(_ footer: Footer) throws -> Data {
        try WorkspaceRootTargetSeedPlanCodec.encodeFooter(footer)
    }

    private func add(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw WorkspaceRootTargetSeedPlanManifestError.corrupt("footer count overflow") }
        return value
    }
}

final class WorkspaceRootTargetSeedPlanManifestStore: @unchecked Sendable {
    private let spillStore: SpillBackedSortedArtifactStore

    init(directoryURL: URL? = nil) throws {
        do {
            spillStore = try SpillBackedSortedArtifactStore(
                directoryURL: directoryURL,
                defaultDirectoryStem: "repoprompt-target-seed-plans"
            )
        } catch let error as SpillBackedSortedArtifactStoreError {
            switch error {
            case .resourceAdmission: throw WorkspaceRootTargetSeedPlanManifestError.resourceAdmission
            case let .io(operation, code):
                throw WorkspaceRootTargetSeedPlanManifestError.io(operation: operation, code: code)
            }
        }
    }

    func makeWriter(
        header: WorkspaceRootTargetSeedPlanManifestHeader,
        resourcePolicy: WorkspaceRootTargetSeedPlanResourcePolicy = .default
    ) throws -> WorkspaceRootTargetSeedPlanManifestWriter {
        guard resourcePolicy.isValid else { throw WorkspaceRootTargetSeedPlanManifestError.invalidConfiguration }
        _ = try WorkspaceRootTargetSeedPlanCodec.encodeHeader(header)
        let writer = try spillStore.makeWriter(
            format: WorkspaceRootTargetSeedPlanSpillFormat(),
            header: header,
            resourcePolicy: resourcePolicy.spillPolicy
        )
        return WorkspaceRootTargetSeedPlanManifestWriter(writer: writer)
    }

    var activeArtifactURLs: [URL] {
        spillStore.activeArtifactURLs
    }

    func cleanup() throws {
        try spillStore.cleanup()
    }
}

actor WorkspaceRootTargetSeedPlanManifestWriter {
    private let writer: SpillBackedSortedArtifactWriter<WorkspaceRootTargetSeedPlanSpillFormat>
    private var closed = false

    fileprivate init(writer: SpillBackedSortedArtifactWriter<WorkspaceRootTargetSeedPlanSpillFormat>) {
        self.writer = writer
    }

    func append(_ record: WorkspaceRootTargetSeedPlanRecord) async throws {
        guard !closed else { throw WorkspaceRootTargetSeedPlanManifestError.closed }
        do { try await writer.append(record) }
        catch {
            closed = true
            throw error
        }
    }

    func append(contentsOf records: [WorkspaceRootTargetSeedPlanRecord]) async throws {
        guard !closed else { throw WorkspaceRootTargetSeedPlanManifestError.closed }
        do { try await writer.append(contentsOf: records) }
        catch {
            closed = true
            throw error
        }
    }

    func finish() async throws -> WorkspaceRootTargetSeedPlanManifestLease {
        guard !closed else { throw WorkspaceRootTargetSeedPlanManifestError.closed }
        closed = true
        return try await WorkspaceRootTargetSeedPlanManifestLease(spillLease: writer.finish())
    }

    func cancel() async {
        guard !closed else { return }
        closed = true
        await writer.cancel()
    }
}

final class WorkspaceRootTargetSeedPlanManifestLease: @unchecked Sendable {
    let fileURL: URL
    let header: WorkspaceRootTargetSeedPlanManifestHeader
    let footer: WorkspaceRootTargetSeedPlanManifestFooter
    let statistics: WorkspaceRootTargetSeedPlanManifestStatistics

    private let spillLease: SpillBackedSortedArtifactLease<WorkspaceRootTargetSeedPlanSpillFormat>

    fileprivate init(spillLease: SpillBackedSortedArtifactLease<WorkspaceRootTargetSeedPlanSpillFormat>) {
        self.spillLease = spillLease
        fileURL = spillLease.fileURL
        header = spillLease.header
        footer = spillLease.footer
        statistics = WorkspaceRootTargetSeedPlanManifestStatistics(
            initialRunCount: spillLease.statistics.initialRunCount,
            mergePassCount: spillLease.statistics.mergePassCount,
            peakBufferedRecordBytes: spillLease.statistics.peakBufferedRecordBytes,
            recordCount: spillLease.statistics.recordCount,
            finalByteCount: spillLease.statistics.finalByteCount
        )
    }

    func makeReader() throws -> WorkspaceRootTargetSeedPlanManifestReader {
        let descriptor = try spillLease.openValidatedDescriptor()
        do { return try WorkspaceRootTargetSeedPlanManifestReader(descriptor: descriptor, lease: self) }
        catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    func makeLookupReader(
        startingAtValidatedRecordOffset offset: Int64
    ) throws -> WorkspaceRootTargetSeedPlanManifestLookupReader {
        let descriptor = try spillLease.openValidatedDescriptor()
        do {
            return try WorkspaceRootTargetSeedPlanManifestLookupReader(
                descriptor: descriptor,
                lease: self,
                startingOffset: offset
            )
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    fileprivate func validateOpenDescriptor(_ descriptor: Int32) throws {
        try spillLease.validateOpenDescriptor(descriptor)
    }
}

final class WorkspaceRootTargetSeedPlanManifestReader: @unchecked Sendable {
    let header: WorkspaceRootTargetSeedPlanManifestHeader
    private(set) var footer: WorkspaceRootTargetSeedPlanManifestFooter?
    private(set) var validationState = WorkspaceRootTargetSeedPlanReaderValidationState.reading

    private let descriptor: Int32
    private let retainedLease: WorkspaceRootTargetSeedPlanManifestLease
    private var digest: SHA256
    private var previousPath: Data?
    private var accumulator = WorkspaceRootTargetSeedPlanAccumulator()
    private let lock = NSLock()

    fileprivate init(descriptor: Int32, lease: WorkspaceRootTargetSeedPlanManifestLease) throws {
        self.descriptor = descriptor
        retainedLease = lease
        let headerFrame = try WorkspaceRootTargetSeedPlanCodec.readHeaderFrame(from: descriptor)
        guard headerFrame.header == lease.header else {
            throw WorkspaceRootTargetSeedPlanManifestError.corrupt("lease header mismatch")
        }
        var digest = SHA256()
        digest.update(data: headerFrame.encodedFrame)
        self.digest = digest
        header = headerFrame.header
        try lease.validateOpenDescriptor(descriptor)
    }

    deinit { Darwin.close(descriptor) }

    func nextRecordFileOffset() throws -> Int64 {
        let offset = Darwin.lseek(descriptor, 0, SEEK_CUR)
        guard offset >= 0 else {
            throw WorkspaceRootTargetSeedPlanManifestError.io(operation: "record-offset", code: errno)
        }
        return offset
    }

    func next() throws -> WorkspaceRootTargetSeedPlanRecord? {
        lock.lock()
        defer { lock.unlock() }
        switch validationState {
        case .verified: return nil
        case .failed: throw WorkspaceRootTargetSeedPlanManifestError.corrupt("reader validation already failed")
        case .reading: break
        }
        do { return try readNext() }
        catch {
            validationState = .failed
            throw error
        }
    }

    private func readNext() throws -> WorkspaceRootTargetSeedPlanRecord? {
        try retainedLease.validateOpenDescriptor(descriptor)
        let marker = try WorkspaceRootTargetSeedPlanCodec.readExact(descriptor, count: 1)
        guard let byte = marker.first else {
            throw WorkspaceRootTargetSeedPlanManifestError.corrupt("missing footer")
        }
        switch byte {
        case WorkspaceRootTargetSeedPlanCodec.recordMarker:
            let lengthBytes = try WorkspaceRootTargetSeedPlanCodec.readExact(descriptor, count: 4)
            var lengthCursor = WorkspaceRootTargetSeedPlanCodec.ByteCursor(lengthBytes)
            let length = try lengthCursor.readUInt32()
            guard length > 0, length <= WorkspaceRootTargetSeedPlanCodec.maximumRecordPayloadByteCount else {
                throw WorkspaceRootTargetSeedPlanManifestError.corrupt("record length")
            }
            let payload = try WorkspaceRootTargetSeedPlanCodec.readExact(descriptor, count: Int(length))
            var frame = marker
            frame.append(lengthBytes)
            frame.append(payload)
            digest.update(data: frame)
            let record = try WorkspaceRootTargetSeedPlanCodec.decodeRecord(payload)
            if let previousPath {
                guard previousPath.lexicographicallyPrecedes(record.relativePathBytes) else {
                    throw previousPath == record.relativePathBytes
                        ? WorkspaceRootTargetSeedPlanManifestError.duplicatePath
                        : WorkspaceRootTargetSeedPlanManifestError.outOfOrder
                }
            }
            previousPath = record.relativePathBytes
            let format = WorkspaceRootTargetSeedPlanSpillFormat()
            try format.accumulateFinalRecord(record, encodedRecordByteCount: payload.count, into: &accumulator)
            return record

        case WorkspaceRootTargetSeedPlanCodec.footerMarker:
            let payload = try WorkspaceRootTargetSeedPlanCodec.readExact(
                descriptor,
                count: WorkspaceRootTargetSeedPlanCodec.footerPayloadByteCount
            )
            let parsed = try WorkspaceRootTargetSeedPlanCodec.decodeFooter(payload)
            let expected = WorkspaceRootTargetSeedPlanManifestFooter(
                recordCount: accumulator.recordCount,
                ordinaryFileCount: accumulator.ordinaryFileCount,
                ordinaryDirectoryCount: accumulator.ordinaryDirectoryCount,
                policyIgnoredTrackedFileCount: accumulator.policyIgnoredTrackedFileCount,
                baseTombstoneCount: accumulator.baseTombstoneCount,
                reusedBaseFileCount: accumulator.reusedBaseFileCount,
                overlayFileCount: accumulator.overlayFileCount,
                recordPayloadByteCount: accumulator.recordPayloadByteCount,
                digest: Data(digest.finalize())
            )
            guard parsed == expected else { throw WorkspaceRootTargetSeedPlanManifestError.corrupt("footer mismatch") }
            var trailing: UInt8 = 0
            let trailingCount = Darwin.read(descriptor, &trailing, 1)
            if trailingCount < 0 { throw WorkspaceRootTargetSeedPlanManifestError.io(operation: "trailing-read", code: errno) }
            guard trailingCount == 0 else { throw WorkspaceRootTargetSeedPlanManifestError.corrupt("trailing bytes") }
            try retainedLease.validateOpenDescriptor(descriptor)
            footer = parsed
            validationState = .verified
            return nil

        default:
            throw WorkspaceRootTargetSeedPlanManifestError.corrupt("invalid frame marker")
        }
    }
}

/// Random-access reader used only after a complete authenticated pass has
/// validated the immutable lease. Sparse callers retain bounded path/offset
/// checkpoints and scan forward within one ordinal segment.
final class WorkspaceRootTargetSeedPlanManifestLookupReader: @unchecked Sendable {
    private let descriptor: Int32
    private let retainedLease: WorkspaceRootTargetSeedPlanManifestLease

    fileprivate init(
        descriptor: Int32,
        lease: WorkspaceRootTargetSeedPlanManifestLease,
        startingOffset: Int64
    ) throws {
        self.descriptor = descriptor
        retainedLease = lease
        _ = try WorkspaceRootTargetSeedPlanCodec.readHeaderFrame(from: descriptor)
        guard Darwin.lseek(descriptor, startingOffset, SEEK_SET) == startingOffset else {
            throw WorkspaceRootTargetSeedPlanManifestError.io(operation: "lookup-seek", code: errno)
        }
        try lease.validateOpenDescriptor(descriptor)
    }

    deinit { Darwin.close(descriptor) }

    func next() throws -> WorkspaceRootTargetSeedPlanRecord? {
        try retainedLease.validateOpenDescriptor(descriptor)
        let marker = try WorkspaceRootTargetSeedPlanCodec.readExact(descriptor, count: 1)
        guard let byte = marker.first else {
            throw WorkspaceRootTargetSeedPlanManifestError.corrupt("missing lookup record")
        }
        switch byte {
        case WorkspaceRootTargetSeedPlanCodec.recordMarker:
            let lengthBytes = try WorkspaceRootTargetSeedPlanCodec.readExact(descriptor, count: 4)
            var cursor = WorkspaceRootTargetSeedPlanCodec.ByteCursor(lengthBytes)
            let length = try cursor.readUInt32()
            guard length > 0, length <= WorkspaceRootTargetSeedPlanCodec.maximumRecordPayloadByteCount else {
                throw WorkspaceRootTargetSeedPlanManifestError.corrupt("lookup record length")
            }
            return try WorkspaceRootTargetSeedPlanCodec.decodeRecord(
                WorkspaceRootTargetSeedPlanCodec.readExact(descriptor, count: Int(length))
            )
        case WorkspaceRootTargetSeedPlanCodec.footerMarker:
            return nil
        default:
            throw WorkspaceRootTargetSeedPlanManifestError.corrupt("invalid lookup frame marker")
        }
    }
}

/// Private, non-serving result of one exact target evidence/planning attempt.
/// It deliberately exposes no target-sized arrays or sets.
final class WorkspaceRootTargetSeedPlanHandle: WorkspaceRootTargetEvidenceHandle, @unchecked Sendable {
    let snapshot: WorkspaceRootReusableSnapshot
    let namespaceManifest: WorkspaceRootNamespaceManifestLease
    let gitEvidence: GitTargetEvidenceBundleLease
    let planManifest: WorkspaceRootTargetSeedPlanManifestLease

    var snapshotIdentity: WorkspaceRootReusableSnapshotIdentity {
        snapshot.identity
    }

    var targetTreeOIDBytes: Data {
        planManifest.header.targetTreeOIDBytes
    }

    init(
        snapshot: WorkspaceRootReusableSnapshot,
        namespaceManifest: WorkspaceRootNamespaceManifestLease,
        gitEvidence: GitTargetEvidenceBundleLease,
        planManifest: WorkspaceRootTargetSeedPlanManifestLease
    ) throws {
        guard planManifest.header.snapshotIdentityBytes == Data(snapshot.identity.sha256.utf8),
              planManifest.header.namespaceIdentity == namespaceManifest.header.identity,
              planManifest.header.namespaceDigest == namespaceManifest.digest,
              planManifest.header.treeDeltaDigest == gitEvidence.treeDelta.digest,
              planManifest.header.indexDigest == gitEvidence.index.digest,
              planManifest.header.statusDigest == gitEvidence.status.digest
        else { throw WorkspaceRootTargetSeedPlanManifestError.corrupt("incoherent target seed handle") }
        self.snapshot = snapshot
        self.namespaceManifest = namespaceManifest
        self.gitEvidence = gitEvidence
        self.planManifest = planManifest
    }

    func makeReader() throws -> WorkspaceRootTargetSeedPlanManifestReader {
        try planManifest.makeReader()
    }
}

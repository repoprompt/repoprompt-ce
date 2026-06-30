import CryptoKit
import Darwin
import Foundation

extension WorkspaceRootCatalogPolicyIdentity: @unchecked Sendable {}

enum WorkspaceRootNamespaceEntryKind: UInt8 {
    case file = 1
    case directory = 2
}

struct WorkspaceRootNamespaceRecord: Equatable {
    let relativePathBytes: Data
    let kind: WorkspaceRootNamespaceEntryKind
    let isSymbolicLink: Bool
    /// The low sixteen bits returned by `lstat`. This preserves executable and
    /// filesystem-kind metadata without requiring a later path lookup.
    let fileSystemMode: UInt16

    init(
        relativePathBytes: Data,
        kind: WorkspaceRootNamespaceEntryKind,
        isSymbolicLink: Bool,
        fileSystemMode: UInt16 = 0
    ) {
        self.relativePathBytes = relativePathBytes
        self.kind = kind
        self.isSymbolicLink = isSymbolicLink
        self.fileSystemMode = fileSystemMode
    }

    init(
        relativePath: String,
        kind: WorkspaceRootNamespaceEntryKind,
        isSymbolicLink: Bool,
        fileSystemMode: UInt16 = 0
    ) {
        self.init(
            relativePathBytes: Data(relativePath.utf8),
            kind: kind,
            isSymbolicLink: isSymbolicLink,
            fileSystemMode: fileSystemMode
        )
    }

    var hierarchy: Int {
        relativePathBytes.reduce(into: 0) { count, byte in
            if byte == UInt8(ascii: "/") { count += 1 }
        }
    }

    var isExecutable: Bool {
        fileSystemMode & 0o111 != 0
    }
}

struct WorkspaceRootNamespaceRootIdentity: Hashable {
    let canonicalPathBytes: Data
    let device: UInt64
    let inode: UInt64

    init(canonicalPathBytes: Data, device: UInt64, inode: UInt64) {
        self.canonicalPathBytes = canonicalPathBytes
        self.device = device
        self.inode = inode
    }

    init(rootURL: URL) throws {
        let canonicalURL = rootURL.resolvingSymlinksInPath().standardizedFileURL
        var status = stat()
        guard lstat(canonicalURL.path, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
        else {
            throw WorkspaceRootNamespaceManifestError.io(operation: "root-lstat", code: errno)
        }
        canonicalPathBytes = canonicalURL.withUnsafeFileSystemRepresentation { pointer in
            pointer.map { Data(bytes: $0, count: strlen($0)) } ?? Data()
        }
        device = UInt64(status.st_dev)
        inode = UInt64(status.st_ino)
    }
}

struct WorkspaceRootNamespaceManifestIdentity: Hashable {
    let root: WorkspaceRootNamespaceRootIdentity
    let catalogPolicy: WorkspaceRootCatalogPolicyIdentity
}

struct WorkspaceRootNamespaceManifestHeader: Equatable {
    static let currentSchemaVersion: UInt32 = 1

    let schemaVersion: UInt32
    let identity: WorkspaceRootNamespaceManifestIdentity

    init(
        schemaVersion: UInt32 = Self.currentSchemaVersion,
        identity: WorkspaceRootNamespaceManifestIdentity
    ) {
        self.schemaVersion = schemaVersion
        self.identity = identity
    }
}

struct WorkspaceRootNamespaceManifestFooter: Equatable {
    let recordCount: UInt64
    let fileCount: UInt64
    let directoryCount: UInt64
    let recordPayloadByteCount: UInt64
    let digest: Data
}

struct WorkspaceRootNamespaceManifestStatistics: Equatable {
    let initialRunCount: Int
    let mergePassCount: Int
    let peakBufferedRecordBytes: Int
    let recordCount: UInt64
    let finalByteCount: UInt64
}

enum WorkspaceRootNamespaceManifestError: Error, Equatable {
    case invalidConfiguration
    case invalidRecord
    case duplicatePath
    case outOfOrder
    case resourceAdmission
    case closed
    case corrupt(String)
    case io(operation: String, code: Int32)
}

enum WorkspaceRootNamespaceManifestReaderValidationState: Equatable {
    case reading
    case verified
    case failed
}

struct WorkspaceRootNamespaceManifestReaderConsumptionToken: Equatable {
    fileprivate let id: UUID
}

/// A forward-only reader over one identity-validated descriptor. Yielded
/// records remain provisional until `next()` returns `nil`, at which point the
/// footer, counts, ordering, artifact identity, and exact EOF are verified.
final class WorkspaceRootNamespaceManifestReader: @unchecked Sendable {
    let header: WorkspaceRootNamespaceManifestHeader
    private(set) var footer: WorkspaceRootNamespaceManifestFooter?
    private(set) var validationState: WorkspaceRootNamespaceManifestReaderValidationState = .reading

    private let descriptor: Int32
    private let retainedLease: WorkspaceRootNamespaceManifestLease
    private var digest: SHA256
    private var previousPath: Data?
    private var recordCount: UInt64 = 0
    private var fileCount: UInt64 = 0
    private var directoryCount: UInt64 = 0
    private var payloadByteCount: UInt64 = 0
    private var exclusiveConsumerID: UUID?
    private let lock = NSLock()

    init(descriptor: Int32, lease: WorkspaceRootNamespaceManifestLease) throws {
        self.descriptor = descriptor
        retainedLease = lease
        var digest = SHA256()
        let headerFrame = try WorkspaceRootNamespaceManifestCodec.readHeaderFrame(from: descriptor)
        guard headerFrame.header == lease.header else {
            throw WorkspaceRootNamespaceManifestError.corrupt("lease identity mismatch")
        }
        digest.update(data: headerFrame.encodedFrame)
        self.digest = digest
        header = headerFrame.header
        try retainedLease.validateOpenDescriptor(descriptor)
    }

    deinit {
        Darwin.close(descriptor)
    }

    func next() throws -> WorkspaceRootNamespaceRecord? {
        lock.lock()
        defer { lock.unlock() }
        guard exclusiveConsumerID == nil else {
            throw WorkspaceRootNamespaceManifestError.corrupt(
                "reader is owned by an exclusive transaction"
            )
        }
        return try nextLocked()
    }

    func beginExclusiveConsumption() throws -> WorkspaceRootNamespaceManifestReaderConsumptionToken {
        lock.lock()
        defer { lock.unlock() }
        guard exclusiveConsumerID == nil else {
            throw WorkspaceRootNamespaceManifestError.corrupt(
                "reader is owned by an exclusive transaction"
            )
        }
        guard validationState == .reading,
              recordCount == 0,
              previousPath == nil
        else {
            throw WorkspaceRootNamespaceManifestError.corrupt(
                "reader transaction requires a pristine source"
            )
        }
        let token = WorkspaceRootNamespaceManifestReaderConsumptionToken(id: UUID())
        exclusiveConsumerID = token.id
        return token
    }

    func next(
        exclusive token: WorkspaceRootNamespaceManifestReaderConsumptionToken
    ) throws -> WorkspaceRootNamespaceRecord? {
        lock.lock()
        defer { lock.unlock() }
        guard exclusiveConsumerID == token.id else {
            throw WorkspaceRootNamespaceManifestError.corrupt(
                "invalid reader transaction ownership"
            )
        }
        return try nextLocked()
    }

    func completeExclusiveConsumption(
        _ token: WorkspaceRootNamespaceManifestReaderConsumptionToken
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard exclusiveConsumerID == token.id else {
            throw WorkspaceRootNamespaceManifestError.corrupt(
                "invalid reader transaction ownership"
            )
        }
        guard validationState == .verified else {
            throw WorkspaceRootNamespaceManifestError.corrupt(
                "source reader did not reach verified EOF"
            )
        }
        exclusiveConsumerID = nil
    }

    func abandonExclusiveConsumption(
        _ token: WorkspaceRootNamespaceManifestReaderConsumptionToken
    ) {
        lock.lock()
        defer { lock.unlock() }
        if exclusiveConsumerID == token.id {
            exclusiveConsumerID = nil
        }
    }

    private func nextLocked() throws -> WorkspaceRootNamespaceRecord? {
        switch validationState {
        case .verified:
            return nil
        case .failed:
            throw WorkspaceRootNamespaceManifestError.corrupt("reader validation already failed")
        case .reading:
            break
        }

        do {
            return try readNext()
        } catch {
            validationState = .failed
            throw error
        }
    }

    private func readNext() throws -> WorkspaceRootNamespaceRecord? {
        try retainedLease.validateOpenDescriptor(descriptor)

        let marker = try WorkspaceRootNamespaceManifestCodec.readExact(descriptor, count: 1)
        guard let byte = marker.first else {
            throw WorkspaceRootNamespaceManifestError.corrupt("missing footer")
        }
        switch byte {
        case WorkspaceRootNamespaceManifestCodec.recordMarker:
            let lengthData = try WorkspaceRootNamespaceManifestCodec.readExact(descriptor, count: 4)
            let length = try WorkspaceRootNamespaceManifestCodec.decodeUInt32(lengthData)
            guard length > 0,
                  length <= UInt32(WorkspaceRootNamespaceManifestCodec.maximumEncodedRecordPayloadByteCount)
            else {
                throw WorkspaceRootNamespaceManifestError.corrupt("invalid record length")
            }
            let payload = try WorkspaceRootNamespaceManifestCodec.readExact(descriptor, count: Int(length))
            var frame = marker
            frame.append(lengthData)
            frame.append(payload)
            digest.update(data: frame)
            let record = try WorkspaceRootNamespaceManifestCodec.decodeRecord(payload)
            try WorkspaceRootNamespaceManifestCodec.validate(
                record,
                maximumByteCount: WorkspaceRootNamespaceManifestCodec.maximumPathByteCount
            )
            if let previousPath {
                if previousPath == record.relativePathBytes {
                    throw WorkspaceRootNamespaceManifestError.duplicatePath
                }
                guard WorkspaceRootNamespaceManifestCodec.lexicallyPrecedes(
                    previousPath,
                    record.relativePathBytes
                ) else { throw WorkspaceRootNamespaceManifestError.outOfOrder }
            }
            previousPath = record.relativePathBytes
            recordCount &+= 1
            payloadByteCount &+= UInt64(payload.count)
            switch record.kind {
            case .file: fileCount &+= 1
            case .directory: directoryCount &+= 1
            }
            return record

        case WorkspaceRootNamespaceManifestCodec.footerMarker:
            let payload = try WorkspaceRootNamespaceManifestCodec.readExact(
                descriptor,
                count: WorkspaceRootNamespaceManifestCodec.footerPayloadByteCount
            )
            let parsed = try WorkspaceRootNamespaceManifestCodec.decodeFooter(payload)
            let expectedDigest = Data(digest.finalize())
            guard parsed.recordCount == recordCount,
                  parsed.fileCount == fileCount,
                  parsed.directoryCount == directoryCount,
                  parsed.recordPayloadByteCount == payloadByteCount,
                  parsed.digest == expectedDigest
            else { throw WorkspaceRootNamespaceManifestError.corrupt("footer mismatch") }
            var trailingByte: UInt8 = 0
            let trailing = Darwin.read(descriptor, &trailingByte, 1)
            if trailing < 0 {
                throw WorkspaceRootNamespaceManifestError.io(operation: "trailing-read", code: errno)
            }
            guard trailing == 0 else {
                throw WorkspaceRootNamespaceManifestError.corrupt("trailing bytes")
            }
            try retainedLease.validateOpenDescriptor(descriptor)
            footer = parsed
            validationState = .verified
            return nil

        default:
            throw WorkspaceRootNamespaceManifestError.corrupt("invalid frame marker")
        }
    }
}

enum WorkspaceRootNamespaceManifestCodec {
    static let magic = Data("RPNAMES1".utf8)
    static let recordMarker: UInt8 = 0x52
    static let footerMarker: UInt8 = 0x46
    static let footerPayloadByteCount = 8 * 4 + SHA256.byteCount
    static let maximumPathByteCount = 1024 * 1024
    static let maximumEncodedRecordPayloadByteCount = maximumPathByteCount + 8

    struct DecodedHeaderFrame {
        let header: WorkspaceRootNamespaceManifestHeader
        let encodedFrame: Data
    }

    static func validate(_ record: WorkspaceRootNamespaceRecord, maximumByteCount: Int) throws {
        let path = record.relativePathBytes
        guard !path.isEmpty,
              path.count <= maximumByteCount,
              path.first != UInt8(ascii: "/"),
              !path.contains(0)
        else { throw WorkspaceRootNamespaceManifestError.invalidRecord }
        let components = path.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false)
        guard !components.contains(where: { component in
            component.isEmpty || component.elementsEqual([UInt8(ascii: ".")]) ||
                component.elementsEqual([UInt8(ascii: "."), UInt8(ascii: ".")])
        }) else { throw WorkspaceRootNamespaceManifestError.invalidRecord }
    }

    static func lexicallyPrecedes(_ lhs: Data, _ rhs: Data) -> Bool {
        lhs.lexicographicallyPrecedes(rhs)
    }

    static func encodeHeader(_ header: WorkspaceRootNamespaceManifestHeader) -> Data {
        var payload = Data()
        append(header.identity.root.canonicalPathBytes, to: &payload)
        append(header.identity.root.device, to: &payload)
        append(header.identity.root.inode, to: &payload)
        let policy = header.identity.catalogPolicy
        append(UInt32(policy.schemaVersion), to: &payload)
        append(Data(policy.mandatoryIgnorePolicyIdentity.utf8), to: &payload)
        append(Data(policy.globalIgnoreDefaultsDigest.utf8), to: &payload)
        payload.append(policy.respectRepoIgnore ? 1 : 0)
        payload.append(policy.respectCursorignore ? 1 : 0)
        payload.append(policy.enableHierarchicalIgnores ? 1 : 0)
        payload.append(policy.skipSymlinks ? 1 : 0)

        var frame = magic
        append(header.schemaVersion, to: &frame)
        append(UInt32(payload.count), to: &frame)
        frame.append(payload)
        frame.append(Data(SHA256.hash(data: payload)))
        return frame
    }

    static func readHeaderFrame(from descriptor: Int32) throws -> DecodedHeaderFrame {
        let prefixCount = magic.count + 8
        let prefix = try readExact(descriptor, count: prefixCount)
        guard prefix.prefix(magic.count) == magic else {
            throw WorkspaceRootNamespaceManifestError.corrupt("invalid magic")
        }
        let schema = try decodeUInt32(Data(prefix[magic.count ..< magic.count + 4]))
        guard schema == WorkspaceRootNamespaceManifestHeader.currentSchemaVersion else {
            throw WorkspaceRootNamespaceManifestError.corrupt("unsupported schema")
        }
        let payloadLength = try decodeUInt32(Data(prefix[(magic.count + 4) ..< prefixCount]))
        guard payloadLength > 0, payloadLength <= 1024 * 1024 else {
            throw WorkspaceRootNamespaceManifestError.corrupt("invalid header length")
        }
        let payload = try readExact(descriptor, count: Int(payloadLength))
        let checksum = try readExact(descriptor, count: SHA256.byteCount)
        guard checksum == Data(SHA256.hash(data: payload)) else {
            throw WorkspaceRootNamespaceManifestError.corrupt("header checksum")
        }
        var encoded = prefix
        encoded.append(payload)
        encoded.append(checksum)
        return try DecodedHeaderFrame(header: decodeHeader(schema: schema, payload: payload), encodedFrame: encoded)
    }

    static func encodeRecord(_ record: WorkspaceRootNamespaceRecord) throws -> Data {
        guard record.relativePathBytes.count <= Int(UInt32.max) else {
            throw WorkspaceRootNamespaceManifestError.invalidRecord
        }
        var payload = Data([record.kind.rawValue, record.isSymbolicLink ? 1 : 0])
        append(record.fileSystemMode, to: &payload)
        append(UInt32(record.relativePathBytes.count), to: &payload)
        payload.append(record.relativePathBytes)
        return payload
    }

    static func decodeRecord(_ payload: Data) throws -> WorkspaceRootNamespaceRecord {
        var cursor = ByteCursor(payload)
        guard let kind = try WorkspaceRootNamespaceEntryKind(rawValue: cursor.readUInt8()) else {
            throw WorkspaceRootNamespaceManifestError.corrupt("invalid record kind")
        }
        let symlink = try cursor.readUInt8()
        guard symlink <= 1 else {
            throw WorkspaceRootNamespaceManifestError.corrupt("invalid symlink flag")
        }
        let mode = try cursor.readUInt16()
        let pathCount = try cursor.readUInt32()
        guard pathCount > 0, Int(pathCount) == cursor.remaining else {
            throw WorkspaceRootNamespaceManifestError.corrupt("invalid path length")
        }
        return try WorkspaceRootNamespaceRecord(
            relativePathBytes: cursor.readData(count: Int(pathCount)),
            kind: kind,
            isSymbolicLink: symlink == 1,
            fileSystemMode: mode
        )
    }

    static func recordFrame(_ record: WorkspaceRootNamespaceRecord) throws -> Data {
        let payload = try encodeRecord(record)
        var frame = Data([recordMarker])
        append(UInt32(payload.count), to: &frame)
        frame.append(payload)
        return frame
    }

    static func encodeFooter(_ footer: WorkspaceRootNamespaceManifestFooter) -> Data {
        var payload = Data()
        append(footer.recordCount, to: &payload)
        append(footer.fileCount, to: &payload)
        append(footer.directoryCount, to: &payload)
        append(footer.recordPayloadByteCount, to: &payload)
        payload.append(footer.digest)
        var frame = Data([footerMarker])
        frame.append(payload)
        return frame
    }

    static func decodeFooter(_ payload: Data) throws -> WorkspaceRootNamespaceManifestFooter {
        guard payload.count == footerPayloadByteCount else {
            throw WorkspaceRootNamespaceManifestError.corrupt("invalid footer size")
        }
        var cursor = ByteCursor(payload)
        let result = try WorkspaceRootNamespaceManifestFooter(
            recordCount: cursor.readUInt64(),
            fileCount: cursor.readUInt64(),
            directoryCount: cursor.readUInt64(),
            recordPayloadByteCount: cursor.readUInt64(),
            digest: cursor.readData(count: SHA256.byteCount)
        )
        let (classifiedCount, overflowed) = result.fileCount.addingReportingOverflow(result.directoryCount)
        guard cursor.remaining == 0,
              !overflowed,
              classifiedCount == result.recordCount
        else {
            throw WorkspaceRootNamespaceManifestError.corrupt("invalid footer counts")
        }
        return result
    }

    static func readExact(_ descriptor: Int32, count: Int) throws -> Data {
        guard count >= 0 else { throw WorkspaceRootNamespaceManifestError.corrupt("negative read") }
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let amount = data.withUnsafeMutableBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                return Darwin.read(descriptor, base.advanced(by: offset), count - offset)
            }
            if amount > 0 {
                offset += amount
            } else if amount == 0 {
                throw WorkspaceRootNamespaceManifestError.corrupt("truncated file")
            } else if errno != EINTR {
                throw WorkspaceRootNamespaceManifestError.io(operation: "read", code: errno)
            }
        }
        return data
    }

    static func writeAll(_ data: Data, to descriptor: Int32) throws {
        var offset = 0
        while offset < data.count {
            let amount = data.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                return Darwin.write(descriptor, base.advanced(by: offset), data.count - offset)
            }
            if amount > 0 {
                offset += amount
            } else if amount == 0 {
                throw WorkspaceRootNamespaceManifestError.io(operation: "write", code: EIO)
            } else if amount < 0, errno != EINTR {
                throw WorkspaceRootNamespaceManifestError.io(operation: "write", code: errno)
            }
        }
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

    static func append(_ bytes: Data, to data: inout Data) {
        append(UInt32(bytes.count), to: &data)
        data.append(bytes)
    }

    static func decodeUInt32(_ data: Data) throws -> UInt32 {
        var cursor = ByteCursor(data)
        let value = try cursor.readUInt32()
        guard cursor.remaining == 0 else {
            throw WorkspaceRootNamespaceManifestError.corrupt("invalid integer")
        }
        return value
    }

    private static func decodeHeader(
        schema: UInt32,
        payload: Data
    ) throws -> WorkspaceRootNamespaceManifestHeader {
        var cursor = ByteCursor(payload)
        let path = try cursor.readLengthPrefixedData()
        let device = try cursor.readUInt64()
        let inode = try cursor.readUInt64()
        let policySchema = try cursor.readUInt32()
        let mandatory = try cursor.readLengthPrefixedString()
        let defaultsDigest = try cursor.readLengthPrefixedString()
        let repo = try cursor.readBool()
        let cursorIgnore = try cursor.readBool()
        let hierarchical = try cursor.readBool()
        let symlinks = try cursor.readBool()
        guard !path.isEmpty, cursor.remaining == 0 else {
            throw WorkspaceRootNamespaceManifestError.corrupt("invalid header")
        }
        return WorkspaceRootNamespaceManifestHeader(
            schemaVersion: schema,
            identity: WorkspaceRootNamespaceManifestIdentity(
                root: WorkspaceRootNamespaceRootIdentity(
                    canonicalPathBytes: path,
                    device: device,
                    inode: inode
                ),
                catalogPolicy: WorkspaceRootCatalogPolicyIdentity(
                    schemaVersion: Int(policySchema),
                    mandatoryIgnorePolicyIdentity: mandatory,
                    globalIgnoreDefaultsDigest: defaultsDigest,
                    respectRepoIgnore: repo,
                    respectCursorignore: cursorIgnore,
                    enableHierarchicalIgnores: hierarchical,
                    skipSymlinks: symlinks
                )
            )
        )
    }

    struct ByteCursor {
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
                throw WorkspaceRootNamespaceManifestError.corrupt("truncated payload")
            }
            defer { offset += count }
            return Data(data[offset ..< offset + count])
        }

        mutating func readUInt8() throws -> UInt8 {
            guard remaining >= 1 else {
                throw WorkspaceRootNamespaceManifestError.corrupt("truncated integer")
            }
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
            guard byte <= 1 else {
                throw WorkspaceRootNamespaceManifestError.corrupt("invalid boolean")
            }
            return byte == 1
        }

        mutating func readLengthPrefixedData() throws -> Data {
            try readData(count: Int(readUInt32()))
        }

        mutating func readLengthPrefixedString() throws -> String {
            let bytes = try readLengthPrefixedData()
            guard let value = String(data: bytes, encoding: .utf8) else {
                throw WorkspaceRootNamespaceManifestError.corrupt("invalid string")
            }
            return value
        }
    }
}

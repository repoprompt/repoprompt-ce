import CryptoKit
import Darwin
import Foundation

struct GitPrefixControlEvidenceResourcePolicy: Equatable {
    static let `default` = GitPrefixControlEvidenceResourcePolicy()

    let maximumBufferedRecordBytes: Int
    let maximumRecordsPerBatch: Int
    let maximumRecordByteCount: Int
    let maximumOpenRuns: Int
    let minimumFreeDiskBytes: UInt64
    let maximumAggregateArtifactBytes: UInt64?
    let maximumAggregateControlBytes: UInt64

    init(
        maximumBufferedRecordBytes: Int = 16 * 1024 * 1024,
        maximumRecordsPerBatch: Int = 32768,
        maximumRecordByteCount: Int = 1024 * 1024,
        maximumOpenRuns: Int = 32,
        minimumFreeDiskBytes: UInt64 = 256 * 1024 * 1024,
        maximumAggregateArtifactBytes: UInt64? = 4 * 1024 * 1024 * 1024,
        maximumAggregateControlBytes: UInt64 = 64 * 1024 * 1024
    ) {
        self.maximumBufferedRecordBytes = maximumBufferedRecordBytes
        self.maximumRecordsPerBatch = maximumRecordsPerBatch
        self.maximumRecordByteCount = maximumRecordByteCount
        self.maximumOpenRuns = maximumOpenRuns
        self.minimumFreeDiskBytes = minimumFreeDiskBytes
        self.maximumAggregateArtifactBytes = maximumAggregateArtifactBytes
        self.maximumAggregateControlBytes = maximumAggregateControlBytes
    }

    var spillPolicy: SpillBackedSortedArtifactResourcePolicy {
        SpillBackedSortedArtifactResourcePolicy(
            maximumBufferedRecordBytes: maximumBufferedRecordBytes,
            maximumRecordsPerBatch: maximumRecordsPerBatch,
            maximumRecordByteCount: maximumRecordByteCount,
            maximumOpenRuns: maximumOpenRuns,
            minimumFreeDiskBytes: minimumFreeDiskBytes,
            maximumAggregateArtifactBytes: maximumAggregateArtifactBytes
        )
    }
}

struct GitPrefixControlEvidenceManifestHeader: Equatable {
    static let currentSchemaVersion: UInt32 = 1
    let schemaVersion: UInt32
    let rootPrefixBytes: Data
    let digestDomainBytes: Data

    init(schemaVersion: UInt32 = Self.currentSchemaVersion, rootPrefixBytes: Data, digestDomainBytes: Data) {
        self.schemaVersion = schemaVersion
        self.rootPrefixBytes = rootPrefixBytes
        self.digestDomainBytes = digestDomainBytes
    }
}

struct GitPrefixControlEvidenceRecord: Equatable {
    let repositoryRelativePathBytes: Data
    let kind: GitWorkspacePrefixControlKind
    let content: GitWorkspaceAuthorityContentIdentity
}

struct GitPrefixControlEvidenceManifestFooter: Equatable {
    let recordCount: UInt64
    let recordPayloadByteCount: UInt64
    let pathPayloadByteCount: UInt64
    let ignoreControlDigest: Data
    let attributeControlDigest: Data
    let artifactDigest: Data
}

enum GitPrefixControlEvidenceManifestError: Error, Equatable {
    case invalidConfiguration
    case invalidRecord
    case duplicateRecord
    case outOfOrder
    case resourceAdmission
    case closed
    case corrupt(String)
    case io(operation: String, code: Int32)
}

enum GitPrefixControlEvidenceReaderValidationState: Equatable { case reading, verified, failed }

private final class GitPrefixControlDigestBox: @unchecked Sendable {
    var digest = SHA256()
}

private struct GitPrefixControlAccumulator: @unchecked Sendable {
    var recordCount: UInt64 = 0
    var recordPayloadByteCount: UInt64 = 0
    var pathPayloadByteCount: UInt64 = 0
    let ignore = GitPrefixControlDigestBox()
    let attributes = GitPrefixControlDigestBox()
}

private struct GitPrefixControlEvidenceSpillFormat: SpillBackedSortedArtifactFormat {
    typealias Record = GitPrefixControlEvidenceRecord
    typealias Header = GitPrefixControlEvidenceManifestHeader
    typealias Footer = GitPrefixControlEvidenceManifestFooter
    typealias FinalAccumulator = GitPrefixControlAccumulator

    let fileExtension = "prefix-controls"
    let maximumEncodedHeaderByteCount = 64 * 1024
    let maximumEncodedFooterByteCount = 1 + 24 + SHA256.byteCount * 3

    func error(_ failure: SpillBackedSortedArtifactFailure) -> any Error {
        switch failure {
        case .invalidConfiguration: GitPrefixControlEvidenceManifestError.invalidConfiguration
        case .duplicateRecord: GitPrefixControlEvidenceManifestError.duplicateRecord
        case .outOfOrder: GitPrefixControlEvidenceManifestError.outOfOrder
        case .resourceAdmission: GitPrefixControlEvidenceManifestError.resourceAdmission
        case .closed: GitPrefixControlEvidenceManifestError.closed
        case let .corrupt(message): GitPrefixControlEvidenceManifestError.corrupt(message)
        case let .io(operation, code): GitPrefixControlEvidenceManifestError.io(operation: operation, code: code)
        }
    }

    func validate(_ record: Record, maximumRecordByteCount: Int) throws {
        guard !record.repositoryRelativePathBytes.isEmpty,
              record.repositoryRelativePathBytes.count <= 16 * 1024,
              !record.repositoryRelativePathBytes.contains(0),
              String(data: record.repositoryRelativePathBytes, encoding: .utf8) != nil,
              record.content.byteCount >= 0,
              record.content.sha256.utf8.count == 64,
              try encodeRecord(record).count <= maximumRecordByteCount
        else { throw GitPrefixControlEvidenceManifestError.invalidRecord }
    }

    func encodeRecord(_ record: Record) throws -> Data {
        try GitPrefixControlEvidenceCodec.encode(record)
    }

    func decodeRecord(_ payload: Data) throws -> Record {
        try GitPrefixControlEvidenceCodec.decode(payload)
    }

    func maximumEncodedRecordByteCount(maximumRecordByteCount: Int) -> Int {
        maximumRecordByteCount
    }

    func maximumEncodedFinalRecordByteCount(maximumRecordByteCount: Int) -> Int {
        maximumRecordByteCount + 5
    }

    func ordering(_ lhs: Record, _ rhs: Record) -> SpillBackedSortedArtifactOrdering {
        let path = GitPrefixControlEvidenceCodec.compare(lhs.repositoryRelativePathBytes, rhs.repositoryRelativePathBytes)
        guard path == .same else { return path }
        return GitPrefixControlEvidenceCodec.compare(Data(lhs.kind.rawValue.utf8), Data(rhs.kind.rawValue.utf8))
    }

    func duplicateResolution(_ existing: Record, _ candidate: Record) throws -> SpillBackedSortedArtifactDuplicateResolution {
        existing == candidate ? .coalesce : .reject
    }

    func encodeFinalHeader(_ header: Header) throws -> Data {
        try GitPrefixControlEvidenceCodec.encode(header)
    }

    func encodeFinalRecord(_: Record, encodedRecord: Data) throws -> Data {
        var frame = Data([GitPrefixControlEvidenceCodec.recordMarker])
        GitPrefixControlEvidenceCodec.append(UInt32(encodedRecord.count), to: &frame)
        frame.append(encodedRecord)
        return frame
    }

    func makeFinalAccumulator() -> FinalAccumulator {
        FinalAccumulator()
    }

    func accumulateFinalRecord(_ record: Record, encodedRecordByteCount: Int, into accumulator: inout FinalAccumulator) throws {
        accumulator.recordCount = try GitPrefixControlEvidenceCodec.add(accumulator.recordCount, 1)
        accumulator.recordPayloadByteCount = try GitPrefixControlEvidenceCodec.add(accumulator.recordPayloadByteCount, UInt64(encodedRecordByteCount))
        accumulator.pathPayloadByteCount = try GitPrefixControlEvidenceCodec.add(accumulator.pathPayloadByteCount, UInt64(record.repositoryRelativePathBytes.count))
        let canonical = GitPrefixControlEvidenceCodec.canonicalDigestRecord(record)
        if record.kind == .gitAttributes { accumulator.attributes.digest.update(data: canonical) }
        else { accumulator.ignore.digest.update(data: canonical) }
    }

    func makeFinalFooter(accumulator: FinalAccumulator, digest: Data) throws -> Footer {
        Footer(
            recordCount: accumulator.recordCount,
            recordPayloadByteCount: accumulator.recordPayloadByteCount,
            pathPayloadByteCount: accumulator.pathPayloadByteCount,
            ignoreControlDigest: Data(accumulator.ignore.digest.finalize()),
            attributeControlDigest: Data(accumulator.attributes.digest.finalize()),
            artifactDigest: digest
        )
    }

    func encodeFinalFooter(_ footer: Footer) throws -> Data {
        try GitPrefixControlEvidenceCodec.encode(footer)
    }
}

final class GitPrefixControlEvidenceManifestStore: @unchecked Sendable {
    private let spillStore: SpillBackedSortedArtifactStore
    var activeArtifactURLs: [URL] {
        spillStore.activeArtifactURLs
    }

    var directoryURL: URL {
        spillStore.directoryURL
    }

    init(directoryURL: URL? = nil) throws {
        spillStore = try SpillBackedSortedArtifactStore(
            directoryURL: directoryURL,
            defaultDirectoryStem: "repoprompt-prefix-controls"
        )
    }

    func makeWriter(
        rootPrefixBytes: Data,
        digestDomainBytes: Data = Data("git-prefix-control-identities-v1".utf8),
        resourcePolicy: GitPrefixControlEvidenceResourcePolicy = .default
    ) throws -> GitPrefixControlEvidenceManifestWriter {
        let header = GitPrefixControlEvidenceManifestHeader(
            rootPrefixBytes: rootPrefixBytes,
            digestDomainBytes: digestDomainBytes
        )
        let writer = try spillStore.makeWriter(
            format: GitPrefixControlEvidenceSpillFormat(),
            header: header,
            resourcePolicy: resourcePolicy.spillPolicy
        )
        return GitPrefixControlEvidenceManifestWriter(writer)
    }

    func cleanup() throws {
        try spillStore.cleanup()
    }
}

actor GitPrefixControlEvidenceManifestWriter {
    private let writer: SpillBackedSortedArtifactWriter<GitPrefixControlEvidenceSpillFormat>
    private var closed = false
    fileprivate init(_ writer: SpillBackedSortedArtifactWriter<GitPrefixControlEvidenceSpillFormat>) {
        self.writer = writer
    }

    func append(_ record: GitPrefixControlEvidenceRecord) async throws {
        guard !closed else { throw GitPrefixControlEvidenceManifestError.closed }
        do { try await writer.append(record) } catch { closed = true
            throw error
        }
    }

    func finish() async throws -> GitPrefixControlEvidenceManifestLease {
        guard !closed else { throw GitPrefixControlEvidenceManifestError.closed }
        closed = true
        return try await GitPrefixControlEvidenceManifestLease(writer.finish())
    }

    func cancel() async {
        guard !closed else { return }
        closed = true
        await writer.cancel()
    }
}

final class GitPrefixControlEvidenceManifestLease: @unchecked Sendable {
    let fileURL: URL
    let header: GitPrefixControlEvidenceManifestHeader
    let footer: GitPrefixControlEvidenceManifestFooter
    let statistics: SpillBackedSortedArtifactStatistics
    private let lease: SpillBackedSortedArtifactLease<GitPrefixControlEvidenceSpillFormat>
    fileprivate init(_ lease: SpillBackedSortedArtifactLease<GitPrefixControlEvidenceSpillFormat>) {
        self.lease = lease
        fileURL = lease.fileURL
        header = lease.header
        footer = lease.footer
        statistics = lease.statistics
    }

    func makeReader() throws -> GitPrefixControlEvidenceManifestReader {
        let descriptor = try lease.openValidatedDescriptor()
        do { return try GitPrefixControlEvidenceManifestReader(descriptor: descriptor, lease: self) }
        catch { Darwin.close(descriptor)
            throw error
        }
    }

    fileprivate func validate(_ descriptor: Int32) throws {
        try lease.validateOpenDescriptor(descriptor)
    }
}

actor GitPrefixControlEvidenceManifestReader {
    private let descriptor: Int32
    private let lease: GitPrefixControlEvidenceManifestLease
    private var digest = SHA256()
    private var accumulator = GitPrefixControlAccumulator()
    private var previous: GitPrefixControlEvidenceRecord?
    private(set) var validationState: GitPrefixControlEvidenceReaderValidationState = .reading

    fileprivate init(descriptor: Int32, lease: GitPrefixControlEvidenceManifestLease) throws {
        self.descriptor = descriptor
        self.lease = lease
        let expected = try GitPrefixControlEvidenceCodec.encode(lease.header)
        let actual = try GitPrefixControlEvidenceCodec.readExact(descriptor, count: expected.count)
        guard actual == expected else { throw GitPrefixControlEvidenceManifestError.corrupt("header mismatch") }
        digest.update(data: actual)
        try lease.validate(descriptor)
    }

    deinit { Darwin.close(descriptor) }

    func next() throws -> GitPrefixControlEvidenceRecord? {
        guard validationState == .reading else { return nil }
        do {
            try lease.validate(descriptor)
            let marker = try GitPrefixControlEvidenceCodec.readExact(descriptor, count: 1)
            if marker.first == GitPrefixControlEvidenceCodec.footerMarker {
                let payload = try GitPrefixControlEvidenceCodec.readExact(descriptor, count: GitPrefixControlEvidenceCodec.footerPayloadByteCount)
                let footer = try GitPrefixControlEvidenceCodec.decodeFooter(payload)
                let expected = GitPrefixControlEvidenceManifestFooter(
                    recordCount: accumulator.recordCount,
                    recordPayloadByteCount: accumulator.recordPayloadByteCount,
                    pathPayloadByteCount: accumulator.pathPayloadByteCount,
                    ignoreControlDigest: Data(accumulator.ignore.digest.finalize()),
                    attributeControlDigest: Data(accumulator.attributes.digest.finalize()),
                    artifactDigest: Data(digest.finalize())
                )
                guard footer == expected, footer == lease.footer else { throw GitPrefixControlEvidenceManifestError.corrupt("footer mismatch") }
                try GitPrefixControlEvidenceCodec.requireEOF(descriptor)
                try lease.validate(descriptor)
                validationState = .verified
                return nil
            }
            guard marker.first == GitPrefixControlEvidenceCodec.recordMarker else { throw GitPrefixControlEvidenceManifestError.corrupt("invalid marker") }
            let lengthData = try GitPrefixControlEvidenceCodec.readExact(descriptor, count: 4)
            let length = Int(GitPrefixControlEvidenceCodec.decodeUInt32(lengthData))
            guard length > 0, length <= SpillBackedSortedArtifactChecked.maximumFrameByteCount else { throw GitPrefixControlEvidenceManifestError.corrupt("invalid length") }
            let payload = try GitPrefixControlEvidenceCodec.readExact(descriptor, count: length)
            var frame = marker
            frame.append(lengthData)
            frame.append(payload)
            digest.update(data: frame)
            let record = try GitPrefixControlEvidenceCodec.decode(payload)
            if let previous {
                let ordering = GitPrefixControlEvidenceSpillFormat().ordering(previous, record)
                guard ordering == .ascending else { throw GitPrefixControlEvidenceManifestError.outOfOrder }
            }
            previous = record
            accumulator.recordCount = try GitPrefixControlEvidenceCodec.add(accumulator.recordCount, 1)
            accumulator.recordPayloadByteCount = try GitPrefixControlEvidenceCodec.add(accumulator.recordPayloadByteCount, UInt64(length))
            accumulator.pathPayloadByteCount = try GitPrefixControlEvidenceCodec.add(accumulator.pathPayloadByteCount, UInt64(record.repositoryRelativePathBytes.count))
            let canonical = GitPrefixControlEvidenceCodec.canonicalDigestRecord(record)
            if record.kind == .gitAttributes { accumulator.attributes.digest.update(data: canonical) }
            else { accumulator.ignore.digest.update(data: canonical) }
            return record
        } catch { validationState = .failed
            throw error
        }
    }
}

private enum GitPrefixControlEvidenceCodec {
    static let magic = Data("RPPCTRL1".utf8)
    static let recordMarker: UInt8 = 0x52
    static let footerMarker: UInt8 = 0x46
    static let footerPayloadByteCount = 24 + SHA256.byteCount * 3

    static func encode(_ header: GitPrefixControlEvidenceManifestHeader) throws -> Data {
        guard header.schemaVersion == GitPrefixControlEvidenceManifestHeader.currentSchemaVersion,
              header.rootPrefixBytes.count <= 16 * 1024,
              header.digestDomainBytes.count <= 4096
        else { throw GitPrefixControlEvidenceManifestError.invalidConfiguration }
        var payload = Data()
        append(header.schemaVersion, to: &payload)
        try append(header.rootPrefixBytes, to: &payload)
        try append(header.digestDomainBytes, to: &payload)
        var result = magic
        append(UInt32(payload.count), to: &result)
        result.append(payload)
        result.append(Data(SHA256.hash(data: payload)))
        return result
    }

    static func encode(_ record: GitPrefixControlEvidenceRecord) throws -> Data {
        var data = Data()
        try append(record.repositoryRelativePathBytes, to: &data)
        try append(Data(record.kind.rawValue.utf8), to: &data)
        data.append(record.content.exists ? 1 : 0)
        try append(Data(record.content.sha256.utf8), to: &data)
        append(UInt64(record.content.byteCount), to: &data)
        return data
    }

    static func decode(_ payload: Data) throws -> GitPrefixControlEvidenceRecord {
        var c = Cursor(payload)
        let path = try c.data()
        let kindData = try c.data()
        guard let kind = GitWorkspacePrefixControlKind(rawValue: String(decoding: kindData, as: UTF8.self)) else { throw GitPrefixControlEvidenceManifestError.corrupt("kind") }
        let exists = try c.byte()
        let sha = try c.data()
        let count = try c.u64()
        guard c.remaining == 0, exists == 0 || exists == 1, let byteCount = Int(exactly: count) else { throw GitPrefixControlEvidenceManifestError.corrupt("record") }
        return GitPrefixControlEvidenceRecord(repositoryRelativePathBytes: path, kind: kind, content: GitWorkspaceAuthorityContentIdentity(exists: exists == 1, sha256: String(decoding: sha, as: UTF8.self), byteCount: byteCount))
    }

    static func encode(_ footer: GitPrefixControlEvidenceManifestFooter) throws -> Data {
        guard footer.ignoreControlDigest.count == SHA256.byteCount, footer.attributeControlDigest.count == SHA256.byteCount, footer.artifactDigest.count == SHA256.byteCount else { throw GitPrefixControlEvidenceManifestError.corrupt("digest") }
        var data = Data([footerMarker])
        append(footer.recordCount, to: &data)
        append(footer.recordPayloadByteCount, to: &data)
        append(footer.pathPayloadByteCount, to: &data)
        data.append(footer.ignoreControlDigest)
        data.append(footer.attributeControlDigest)
        data.append(footer.artifactDigest)
        return data
    }

    static func decodeFooter(_ payload: Data) throws -> GitPrefixControlEvidenceManifestFooter {
        var c = Cursor(payload)
        let value = try GitPrefixControlEvidenceManifestFooter(recordCount: c.u64(), recordPayloadByteCount: c.u64(), pathPayloadByteCount: c.u64(), ignoreControlDigest: c.fixed(SHA256.byteCount), attributeControlDigest: c.fixed(SHA256.byteCount), artifactDigest: c.fixed(SHA256.byteCount))
        guard c.remaining == 0 else { throw GitPrefixControlEvidenceManifestError.corrupt("footer") }
        return value
    }

    static func canonicalDigestRecord(_ record: GitPrefixControlEvidenceRecord) -> Data {
        var data = Data()
        appendLength(record.repositoryRelativePathBytes, to: &data)
        appendLength(Data(record.kind.rawValue.utf8), to: &data)
        var content = Data()
        appendLength(Data(record.content.exists ? "present".utf8 : "missing".utf8), to: &content)
        appendLength(Data(record.content.sha256.utf8), to: &content)
        append(UInt64(record.content.byteCount), to: &content)
        appendLength(content, to: &data)
        return data
    }

    static func compare(_ lhs: Data, _ rhs: Data) -> SpillBackedSortedArtifactOrdering {
        if lhs == rhs { return .same }
        return lhs.lexicographicallyPrecedes(rhs) ? .ascending : .descending
    }

    static func add(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let (v, o) = lhs.addingReportingOverflow(rhs)
        guard !o else { throw GitPrefixControlEvidenceManifestError.corrupt("overflow") }
        return v
    }

    static func append(_ value: UInt32, to data: inout Data) {
        var v = value.bigEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    static func append(_ value: UInt64, to data: inout Data) {
        var v = value.bigEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    static func append(_ value: Data, to data: inout Data) throws {
        guard let count = UInt32(exactly: value.count) else { throw GitPrefixControlEvidenceManifestError.resourceAdmission }
        append(count, to: &data)
        data.append(value)
    }

    static func appendLength(_ value: Data, to data: inout Data) {
        var count = UInt64(value.count).bigEndian
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
        data.append(value)
    }

    static func decodeUInt32(_ data: Data) -> UInt32 {
        data.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    static func readExact(_ descriptor: Int32, count: Int) throws -> Data {
        var result = Data()
        result.reserveCapacity(count)
        while result.count < count {
            var buffer = Data(count: count - result.count)
            let n = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if n > 0 { buffer.removeSubrange(n ..< buffer.count)
                result.append(buffer)
            } else if n < 0, errno == EINTR { continue } else { throw GitPrefixControlEvidenceManifestError.corrupt("truncated") }
        }
        return result
    }

    static func requireEOF(_ descriptor: Int32) throws {
        var byte: UInt8 = 0
        let n = Darwin.read(descriptor, &byte, 1)
        guard n == 0 else { throw GitPrefixControlEvidenceManifestError.corrupt("trailing bytes") }
    }

    private struct Cursor { let dataValue: Data
        var index = 0
        init(_ data: Data) {
            dataValue = data
        }

        var remaining: Int {
            dataValue.count - index
        }

        mutating func fixed(_ count: Int) throws -> Data {
            guard count >= 0, remaining >= count else { throw GitPrefixControlEvidenceManifestError.corrupt("truncated") }
            defer { index += count }
            return dataValue.subdata(in: index ..< (index + count))
        }

        mutating func byte() throws -> UInt8 {
            try fixed(1)[0]
        }

        mutating func u32() throws -> UInt32 {
            try decodeUInt32(fixed(4))
        }

        mutating func u64() throws -> UInt64 {
            try fixed(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        }

        mutating func data() throws -> Data {
            let count = try Int(u32())
            return try fixed(count)
        }
    }
}

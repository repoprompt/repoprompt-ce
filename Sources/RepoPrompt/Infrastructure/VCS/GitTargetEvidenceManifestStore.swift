import CryptoKit
import Darwin
import Foundation

struct GitTargetEvidenceResourcePolicy: Equatable {
    static let `default` = GitTargetEvidenceResourcePolicy()

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

    var isValid: Bool {
        maximumBufferedRecordBytes > 0 && maximumRecordsPerBatch > 0 &&
            maximumRecordByteCount > 0 &&
            maximumRecordByteCount <= GitTargetEvidenceManifestCodec.maximumRecordPayloadByteCount &&
            maximumOpenRuns >= 2
    }

    var spillPolicy: SpillBackedSortedArtifactResourcePolicy {
        SpillBackedSortedArtifactResourcePolicy(
            maximumBufferedRecordBytes: maximumBufferedRecordBytes,
            maximumRecordsPerBatch: maximumRecordsPerBatch,
            maximumRecordByteCount: maximumRecordByteCount,
            maximumOpenRuns: maximumOpenRuns,
            minimumFreeDiskBytes: minimumFreeDiskBytes
        )
    }
}

struct GitTargetEvidenceFinalAccumulator {
    var recordCount: UInt64 = 0
    var recordPayloadByteCount: UInt64 = 0
    var pathPayloadByteCount: UInt64 = 0
}

struct GitTargetEvidenceSpillFormat<Codec: GitTargetEvidenceRecordCodec>:
    SpillBackedSortedArtifactFormat
{
    typealias Record = Codec.Record
    typealias Header = GitTargetEvidenceManifestHeader
    typealias Footer = GitTargetEvidenceManifestFooter
    typealias FinalAccumulator = GitTargetEvidenceFinalAccumulator

    let fileExtension = Codec.fileExtension
    let maximumEncodedHeaderByteCount = GitTargetEvidenceManifestCodec.magic.count + 8 +
        GitTargetEvidenceManifestCodec.maximumHeaderPayloadByteCount + SHA256.byteCount
    let maximumEncodedFooterByteCount = 1 + GitTargetEvidenceManifestCodec.footerPayloadByteCount
    let objectFormatBytes: Data

    func error(_ failure: SpillBackedSortedArtifactFailure) -> any Error {
        switch failure {
        case .invalidConfiguration: GitTargetEvidenceManifestError.invalidConfiguration
        case .duplicateRecord: GitTargetEvidenceManifestError.duplicateRecord
        case .outOfOrder: GitTargetEvidenceManifestError.outOfOrder
        case .resourceAdmission: GitTargetEvidenceManifestError.resourceAdmission
        case .closed: GitTargetEvidenceManifestError.closed
        case let .corrupt(message): GitTargetEvidenceManifestError.corrupt(message)
        case let .io(operation, code): GitTargetEvidenceManifestError.io(operation: operation, code: code)
        }
    }

    func validate(_ record: Codec.Record, maximumRecordByteCount: Int) throws {
        try Codec.validate(record, objectFormatBytes: objectFormatBytes)
        guard try Codec.encode(record).count <= maximumRecordByteCount else {
            throw GitTargetEvidenceManifestError.resourceAdmission
        }
    }

    func encodeRecord(_ record: Codec.Record) throws -> Data {
        try Codec.encode(record)
    }

    func decodeRecord(_ payload: Data) throws -> Codec.Record {
        try Codec.decode(payload)
    }

    func maximumEncodedRecordByteCount(maximumRecordByteCount: Int) -> Int {
        maximumRecordByteCount
    }

    func maximumEncodedFinalRecordByteCount(maximumRecordByteCount: Int) -> Int {
        maximumRecordByteCount + 5
    }

    func ordering(
        _ lhs: Codec.Record,
        _ rhs: Codec.Record
    ) -> SpillBackedSortedArtifactOrdering {
        Codec.ordering(lhs, rhs)
    }

    func duplicateResolution(
        _ existing: Codec.Record,
        _ candidate: Codec.Record
    ) throws -> SpillBackedSortedArtifactDuplicateResolution {
        try Codec.duplicateResolution(existing, candidate)
    }

    func encodeFinalHeader(_ header: GitTargetEvidenceManifestHeader) throws -> Data {
        guard header.family == Codec.family else {
            throw GitTargetEvidenceManifestError.invalidConfiguration
        }
        return try GitTargetEvidenceManifestCodec.encodeHeader(header)
    }

    func encodeFinalRecord(_: Codec.Record, encodedRecord: Data) throws -> Data {
        try GitTargetEvidenceManifestCodec.recordFrame(encodedRecord)
    }

    func makeFinalAccumulator() -> GitTargetEvidenceFinalAccumulator {
        GitTargetEvidenceFinalAccumulator()
    }

    func accumulateFinalRecord(
        _ record: Codec.Record,
        encodedRecordByteCount: Int,
        into accumulator: inout GitTargetEvidenceFinalAccumulator
    ) throws {
        accumulator.recordCount = try adding(accumulator.recordCount, 1, label: "record count")
        guard let encodedCount = UInt64(exactly: encodedRecordByteCount) else {
            throw GitTargetEvidenceManifestError.corrupt("record byte count overflow")
        }
        accumulator.recordPayloadByteCount = try adding(
            accumulator.recordPayloadByteCount, encodedCount, label: "record payload byte count"
        )
        accumulator.pathPayloadByteCount = try adding(
            accumulator.pathPayloadByteCount,
            Codec.pathPayloadByteCount(record),
            label: "path payload byte count"
        )
    }

    func makeFinalFooter(
        accumulator: GitTargetEvidenceFinalAccumulator,
        digest: Data
    ) throws -> GitTargetEvidenceManifestFooter {
        GitTargetEvidenceManifestFooter(
            recordCount: accumulator.recordCount,
            recordPayloadByteCount: accumulator.recordPayloadByteCount,
            pathPayloadByteCount: accumulator.pathPayloadByteCount,
            digest: digest
        )
    }

    func encodeFinalFooter(_ footer: GitTargetEvidenceManifestFooter) throws -> Data {
        try GitTargetEvidenceManifestCodec.encodeFooter(footer)
    }

    private func adding(_ lhs: UInt64, _ rhs: UInt64, label: String) throws -> UInt64 {
        let (result, overflowed) = lhs.addingReportingOverflow(rhs)
        guard !overflowed else { throw GitTargetEvidenceManifestError.corrupt("\(label) overflow") }
        return result
    }
}

final class GitTargetEvidenceManifestStore: @unchecked Sendable {
    private let spillStore: SpillBackedSortedArtifactStore

    var directoryURL: URL {
        spillStore.directoryURL
    }

    init(directoryURL: URL? = nil) throws {
        do {
            spillStore = try SpillBackedSortedArtifactStore(
                directoryURL: directoryURL,
                defaultDirectoryStem: "repoprompt-git-target-evidence"
            )
        } catch let error as SpillBackedSortedArtifactStoreError {
            switch error {
            case .resourceAdmission: throw GitTargetEvidenceManifestError.resourceAdmission
            case let .io(operation, code):
                throw GitTargetEvidenceManifestError.io(operation: operation, code: code)
            }
        }
    }

    func makeTreeDeltaWriter(
        identity: GitTargetEvidenceArtifactIdentity,
        resourcePolicy: GitTargetEvidenceResourcePolicy = .default
    ) throws -> GitTargetTreeDeltaEvidenceWriter {
        guard identity.baseObjectIDBytes != nil, identity.targetObjectIDBytes != nil,
              identity.sparseCheckoutEnabled == nil
        else { throw GitTargetEvidenceManifestError.invalidConfiguration }
        return try makeWriter(codec: GitTargetTreeDeltaRecordCodec.self, identity: identity, policy: resourcePolicy)
    }

    func makeIndexWriter(
        identity: GitTargetEvidenceArtifactIdentity,
        resourcePolicy: GitTargetEvidenceResourcePolicy = .default
    ) throws -> GitTargetIndexEvidenceWriter {
        guard identity.baseObjectIDBytes == nil, identity.targetObjectIDBytes != nil,
              identity.sparseCheckoutEnabled != nil
        else { throw GitTargetEvidenceManifestError.invalidConfiguration }
        return try makeWriter(codec: GitTargetIndexRecordCodec.self, identity: identity, policy: resourcePolicy)
    }

    func makeStatusWriter(
        identity: GitTargetEvidenceArtifactIdentity,
        resourcePolicy: GitTargetEvidenceResourcePolicy = .default
    ) throws -> GitTargetStatusEvidenceWriter {
        guard identity.baseObjectIDBytes == nil, identity.targetObjectIDBytes != nil,
              identity.sparseCheckoutEnabled == nil
        else { throw GitTargetEvidenceManifestError.invalidConfiguration }
        return try makeWriter(codec: GitTargetStatusRecordCodec.self, identity: identity, policy: resourcePolicy)
    }

    var activeArtifactURLs: [URL] {
        spillStore.activeArtifactURLs
    }

    func cleanup() throws {
        try spillStore.cleanup()
    }

    private func makeWriter<Codec: GitTargetEvidenceRecordCodec>(
        codec _: Codec.Type,
        identity: GitTargetEvidenceArtifactIdentity,
        policy: GitTargetEvidenceResourcePolicy
    ) throws -> GitTargetEvidenceManifestWriter<Codec> {
        guard policy.isValid else { throw GitTargetEvidenceManifestError.invalidConfiguration }
        let header = GitTargetEvidenceManifestHeader(family: Codec.family, identity: identity)
        _ = try GitTargetEvidenceManifestCodec.encodeHeader(header)
        let writer = try spillStore.makeWriter(
            format: GitTargetEvidenceSpillFormat<Codec>(
                objectFormatBytes: identity.objectFormatBytes
            ),
            header: header,
            resourcePolicy: policy.spillPolicy
        )
        return GitTargetEvidenceManifestWriter(writer: writer)
    }
}

actor GitTargetEvidenceManifestWriter<Codec: GitTargetEvidenceRecordCodec> {
    private let writer: SpillBackedSortedArtifactWriter<GitTargetEvidenceSpillFormat<Codec>>
    private var closed = false

    fileprivate init(
        writer: SpillBackedSortedArtifactWriter<GitTargetEvidenceSpillFormat<Codec>>
    ) {
        self.writer = writer
    }

    func append(_ record: Codec.Record) async throws {
        guard !closed else { throw GitTargetEvidenceManifestError.closed }
        do { try await writer.append(record) }
        catch {
            closed = true
            throw error
        }
    }

    func append(contentsOf records: [Codec.Record]) async throws {
        guard !closed else { throw GitTargetEvidenceManifestError.closed }
        do { try await writer.append(contentsOf: records) }
        catch {
            closed = true
            throw error
        }
    }

    func finish() async throws -> GitTargetEvidenceManifestLease<Codec> {
        guard !closed else { throw GitTargetEvidenceManifestError.closed }
        closed = true
        return try await GitTargetEvidenceManifestLease(spillLease: writer.finish())
    }

    func cancel() async {
        guard !closed else { return }
        closed = true
        await writer.cancel()
    }
}

final class GitTargetEvidenceManifestLease<Codec: GitTargetEvidenceRecordCodec>:
    @unchecked Sendable
{
    let fileURL: URL
    let header: GitTargetEvidenceManifestHeader
    let footer: GitTargetEvidenceManifestFooter
    let statistics: GitTargetEvidenceManifestStatistics
    let peakResidentScheduledRunCount: Int

    var digest: Data {
        footer.digest
    }

    private let spillLease: SpillBackedSortedArtifactLease<GitTargetEvidenceSpillFormat<Codec>>

    fileprivate init(
        spillLease: SpillBackedSortedArtifactLease<GitTargetEvidenceSpillFormat<Codec>>
    ) {
        self.spillLease = spillLease
        fileURL = spillLease.fileURL
        header = spillLease.header
        footer = spillLease.footer
        statistics = GitTargetEvidenceManifestStatistics(
            initialRunCount: spillLease.statistics.initialRunCount,
            mergePassCount: spillLease.statistics.mergePassCount,
            peakBufferedRecordBytes: spillLease.statistics.peakBufferedRecordBytes,
            recordCount: spillLease.statistics.recordCount,
            finalByteCount: spillLease.statistics.finalByteCount
        )
        peakResidentScheduledRunCount = spillLease.peakResidentScheduledRunCount
    }

    func makeReader() throws -> GitTargetEvidenceManifestReader<Codec> {
        let descriptor = try spillLease.openValidatedDescriptor()
        do { return try GitTargetEvidenceManifestReader(descriptor: descriptor, lease: self) }
        catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    func validateOpenDescriptor(_ descriptor: Int32) throws {
        try spillLease.validateOpenDescriptor(descriptor)
    }
}

typealias GitTargetTreeDeltaEvidenceWriter = GitTargetEvidenceManifestWriter<GitTargetTreeDeltaRecordCodec>
typealias GitTargetIndexEvidenceWriter = GitTargetEvidenceManifestWriter<GitTargetIndexRecordCodec>
typealias GitTargetStatusEvidenceWriter = GitTargetEvidenceManifestWriter<GitTargetStatusRecordCodec>
typealias GitTargetTreeDeltaEvidenceLease = GitTargetEvidenceManifestLease<GitTargetTreeDeltaRecordCodec>
typealias GitTargetIndexEvidenceLease = GitTargetEvidenceManifestLease<GitTargetIndexRecordCodec>
typealias GitTargetStatusEvidenceLease = GitTargetEvidenceManifestLease<GitTargetStatusRecordCodec>

/// Strongly owns one coherent target-evidence set. Readers independently retain
/// their constituent lease, so dropping the bundle cannot unlink an artifact
/// until the final live reader releases it.
final class GitTargetEvidenceBundleLease: @unchecked Sendable {
    let treeDelta: GitTargetTreeDeltaEvidenceLease
    let index: GitTargetIndexEvidenceLease
    let status: GitTargetStatusEvidenceLease

    init(
        treeDelta: GitTargetTreeDeltaEvidenceLease,
        index: GitTargetIndexEvidenceLease,
        status: GitTargetStatusEvidenceLease
    ) throws {
        let treeIdentity = treeDelta.header.identity
        guard Self.sameAttempt(treeIdentity, index.header.identity),
              Self.sameAttempt(treeIdentity, status.header.identity)
        else { throw GitTargetEvidenceManifestError.corrupt("incoherent evidence bundle") }
        self.treeDelta = treeDelta
        self.index = index
        self.status = status
    }

    func makeTreeDeltaReader() throws -> GitTargetTreeDeltaEvidenceReader {
        try treeDelta.makeReader()
    }

    func makeIndexReader() throws -> GitTargetIndexEvidenceReader {
        try index.makeReader()
    }

    func makeStatusReader() throws -> GitTargetStatusEvidenceReader {
        try status.makeReader()
    }

    private static func sameAttempt(
        _ lhs: GitTargetEvidenceArtifactIdentity,
        _ rhs: GitTargetEvidenceArtifactIdentity
    ) -> Bool {
        lhs.physicalWorktree == rhs.physicalWorktree &&
            lhs.repositoryCommonDirectory == rhs.repositoryCommonDirectory &&
            lhs.repositoryGitDirectory == rhs.repositoryGitDirectory &&
            lhs.authority == rhs.authority &&
            lhs.environmentIdentityBytes == rhs.environmentIdentityBytes &&
            lhs.repositoryRelativeRootPrefixBytes == rhs.repositoryRelativeRootPrefixBytes &&
            lhs.objectFormatBytes == rhs.objectFormatBytes &&
            lhs.targetObjectIDBytes == rhs.targetObjectIDBytes &&
            lhs.suppliedCreationCutProvenanceBytes == rhs.suppliedCreationCutProvenanceBytes
    }
}

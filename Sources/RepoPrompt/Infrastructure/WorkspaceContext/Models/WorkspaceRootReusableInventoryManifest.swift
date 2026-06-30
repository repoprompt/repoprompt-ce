import CryptoKit
import Darwin
import Foundation

struct WorkspaceRootReusableInventoryResourcePolicy: Equatable {
    static let `default` = WorkspaceRootReusableInventoryResourcePolicy()

    let maximumBufferedRecordBytes: Int
    let maximumRecordsPerBatch: Int
    let maximumRecordByteCount: Int
    let maximumOpenRuns: Int
    let minimumFreeDiskBytes: UInt64
    let maximumAggregateArtifactBytes: UInt64?

    init(
        maximumBufferedRecordBytes: Int = 16 * 1024 * 1024,
        maximumRecordsPerBatch: Int = 32768,
        maximumRecordByteCount: Int = 1024 * 1024,
        maximumOpenRuns: Int = 32,
        minimumFreeDiskBytes: UInt64 = 256 * 1024 * 1024,
        maximumAggregateArtifactBytes: UInt64? = 4 * 1024 * 1024 * 1024
    ) {
        self.maximumBufferedRecordBytes = maximumBufferedRecordBytes
        self.maximumRecordsPerBatch = maximumRecordsPerBatch
        self.maximumRecordByteCount = maximumRecordByteCount
        self.maximumOpenRuns = maximumOpenRuns
        self.minimumFreeDiskBytes = minimumFreeDiskBytes
        self.maximumAggregateArtifactBytes = maximumAggregateArtifactBytes
    }

    var isValid: Bool {
        maximumBufferedRecordBytes > 0 && maximumRecordsPerBatch > 0 &&
            maximumRecordByteCount > 0 &&
            maximumRecordByteCount <= WorkspaceRootReusableInventoryManifestCodec.maximumRecordPayloadByteCount &&
            maximumOpenRuns >= 2 && maximumAggregateArtifactBytes.map { $0 > 0 } != false
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

struct WorkspaceRootReusableInventoryManifestHeader: Equatable {
    static let currentSchemaVersion: UInt32 = 1

    let schemaVersion: UInt32
    let compatibilityDomain: String
    let compatibilityDigest: Data
    let treeOID: GitObjectID
    let objectFormat: GitObjectFormat
    let repositoryRelativeRootPrefix: GitRepositoryRelativeRootPrefix
    let commandFormat: String
    let rawStandardOutputDigest: Data
    let catalogPolicyDigest: Data

    init(
        schemaVersion: UInt32 = Self.currentSchemaVersion,
        compatibilityDomain: String,
        compatibilityDigest: Data,
        treeOID: GitObjectID,
        objectFormat: GitObjectFormat,
        repositoryRelativeRootPrefix: GitRepositoryRelativeRootPrefix,
        commandFormat: String,
        rawStandardOutputDigest: Data,
        catalogPolicyDigest: Data
    ) {
        self.schemaVersion = schemaVersion
        self.compatibilityDomain = compatibilityDomain
        self.compatibilityDigest = compatibilityDigest
        self.treeOID = treeOID
        self.objectFormat = objectFormat
        self.repositoryRelativeRootPrefix = repositoryRelativeRootPrefix
        self.commandFormat = commandFormat
        self.rawStandardOutputDigest = rawStandardOutputDigest
        self.catalogPolicyDigest = catalogPolicyDigest
    }
}

struct WorkspaceRootReusableInventoryManifestRecord: Equatable {
    let rootRelativePathBytes: Data
    let mode: String
    let kind: GitTreeEntryKind
    let objectID: GitObjectID
    let provenance: RootNeutralTreeInventoryEntry.Provenance
    let catalogProjection: RootNeutralTreeInventoryEntry.CatalogProjection

    init(
        rootRelativePathBytes: Data,
        mode: String,
        kind: GitTreeEntryKind,
        objectID: GitObjectID,
        provenance: RootNeutralTreeInventoryEntry.Provenance = .committedTree,
        catalogProjection: RootNeutralTreeInventoryEntry.CatalogProjection
    ) {
        self.rootRelativePathBytes = rootRelativePathBytes
        self.mode = mode
        self.kind = kind
        self.objectID = objectID
        self.provenance = provenance
        self.catalogProjection = catalogProjection
    }

    init(
        rootRelativePath: String,
        mode: String,
        kind: GitTreeEntryKind,
        objectID: GitObjectID,
        provenance: RootNeutralTreeInventoryEntry.Provenance = .committedTree,
        catalogProjection: RootNeutralTreeInventoryEntry.CatalogProjection
    ) {
        self.init(
            rootRelativePathBytes: Data(rootRelativePath.utf8),
            mode: mode,
            kind: kind,
            objectID: objectID,
            provenance: provenance,
            catalogProjection: catalogProjection
        )
    }
}

struct WorkspaceRootReusableInventoryManifestFooter: Equatable {
    let totalRecordCount: UInt64
    let searchableRegularFileCount: UInt64
    let policyIgnoredRegularFileCount: UInt64
    let nonRegularTopologyCount: UInt64
    let recordPayloadByteCount: UInt64
    let pathPayloadByteCount: UInt64
    let manifestDigest: Data
}

struct WorkspaceRootReusableInventoryManifestStatistics: Equatable {
    let initialRunCount: Int
    let mergePassCount: Int
    let peakBufferedRecordBytes: Int
    let recordCount: UInt64
    let finalByteCount: UInt64
    let peakResidentScheduledRunCount: Int
    let peakWorkspaceByteCount: UInt64
    let peakAggregateArtifactByteCount: UInt64
}

enum WorkspaceRootReusableInventoryManifestError: Error, Equatable {
    case invalidConfiguration
    case invalidRecord(String)
    case duplicateRecord
    case canonicalPathCollision
    case outOfOrder
    case resourceAdmission
    case closed
    case corrupt(String)
    case io(operation: String, code: Int32)
}

enum WorkspaceRootReusableInventoryReaderValidationState: Equatable {
    case reading
    case verified
    case failed
}

private struct WorkspaceRootReusableInventoryAccumulator {
    var totalRecordCount: UInt64 = 0
    var searchableRegularFileCount: UInt64 = 0
    var policyIgnoredRegularFileCount: UInt64 = 0
    var nonRegularTopologyCount: UInt64 = 0
    var recordPayloadByteCount: UInt64 = 0
    var pathPayloadByteCount: UInt64 = 0
}

private struct WorkspaceRootReusableInventorySpillFormat: SpillBackedSortedArtifactFormat {
    typealias Record = WorkspaceRootReusableInventoryManifestRecord
    typealias Header = WorkspaceRootReusableInventoryManifestHeader
    typealias Footer = WorkspaceRootReusableInventoryManifestFooter
    typealias FinalAccumulator = WorkspaceRootReusableInventoryAccumulator

    let fileExtension = "root-inventory"
    let maximumEncodedHeaderByteCount = WorkspaceRootReusableInventoryManifestCodec.maximumHeaderFrameByteCount
    let maximumEncodedFooterByteCount = WorkspaceRootReusableInventoryManifestCodec.footerFrameByteCount
    let objectFormat: GitObjectFormat

    func error(_ failure: SpillBackedSortedArtifactFailure) -> any Error {
        switch failure {
        case .invalidConfiguration: WorkspaceRootReusableInventoryManifestError.invalidConfiguration
        case .duplicateRecord: WorkspaceRootReusableInventoryManifestError.duplicateRecord
        case .outOfOrder: WorkspaceRootReusableInventoryManifestError.outOfOrder
        case .resourceAdmission: WorkspaceRootReusableInventoryManifestError.resourceAdmission
        case .closed: WorkspaceRootReusableInventoryManifestError.closed
        case let .corrupt(message): WorkspaceRootReusableInventoryManifestError.corrupt(message)
        case let .io(operation, code): WorkspaceRootReusableInventoryManifestError.io(operation: operation, code: code)
        }
    }

    func validate(
        _ record: WorkspaceRootReusableInventoryManifestRecord,
        maximumRecordByteCount: Int
    ) throws {
        try WorkspaceRootReusableInventoryManifestCodec.validate(record, objectFormat: objectFormat)
        guard try WorkspaceRootReusableInventoryManifestCodec.encode(record).count <= maximumRecordByteCount else {
            throw WorkspaceRootReusableInventoryManifestError.resourceAdmission
        }
    }

    func encodeRecord(_ record: WorkspaceRootReusableInventoryManifestRecord) throws -> Data {
        try WorkspaceRootReusableInventoryManifestCodec.encode(record)
    }

    func decodeRecord(_ payload: Data) throws -> WorkspaceRootReusableInventoryManifestRecord {
        try WorkspaceRootReusableInventoryManifestCodec.decodeRecord(payload, objectFormat: objectFormat)
    }

    func maximumEncodedRecordByteCount(maximumRecordByteCount: Int) -> Int {
        maximumRecordByteCount
    }

    func maximumEncodedFinalRecordByteCount(maximumRecordByteCount: Int) -> Int {
        maximumRecordByteCount + 5
    }

    func ordering(
        _ lhs: WorkspaceRootReusableInventoryManifestRecord,
        _ rhs: WorkspaceRootReusableInventoryManifestRecord
    ) -> SpillBackedSortedArtifactOrdering {
        WorkspaceRootReusableInventoryManifestCodec.compare(
            lhs.rootRelativePathBytes,
            rhs.rootRelativePathBytes
        )
    }

    func duplicateResolution(
        _ existing: WorkspaceRootReusableInventoryManifestRecord,
        _ candidate: WorkspaceRootReusableInventoryManifestRecord
    ) throws -> SpillBackedSortedArtifactDuplicateResolution {
        existing == candidate ? .coalesce : .reject
    }

    func encodeFinalHeader(_ header: WorkspaceRootReusableInventoryManifestHeader) throws -> Data {
        try WorkspaceRootReusableInventoryManifestCodec.encodeHeader(header)
    }

    func encodeFinalRecord(
        _: WorkspaceRootReusableInventoryManifestRecord,
        encodedRecord: Data
    ) throws -> Data {
        try WorkspaceRootReusableInventoryManifestCodec.recordFrame(encodedRecord)
    }

    func makeFinalAccumulator() -> WorkspaceRootReusableInventoryAccumulator {
        WorkspaceRootReusableInventoryAccumulator()
    }

    func accumulateFinalRecord(
        _ record: WorkspaceRootReusableInventoryManifestRecord,
        encodedRecordByteCount: Int,
        into accumulator: inout WorkspaceRootReusableInventoryAccumulator
    ) throws {
        accumulator.totalRecordCount = try add(accumulator.totalRecordCount, 1, "record count")
        let encodedCount = try exactUInt64(encodedRecordByteCount, "record payload byte count")
        let pathCount = try exactUInt64(record.rootRelativePathBytes.count, "path payload byte count")
        accumulator.recordPayloadByteCount = try add(
            accumulator.recordPayloadByteCount, encodedCount, "record payload byte count"
        )
        accumulator.pathPayloadByteCount = try add(
            accumulator.pathPayloadByteCount, pathCount, "path payload byte count"
        )
        switch record.catalogProjection {
        case .searchableRegularFile:
            accumulator.searchableRegularFileCount = try add(
                accumulator.searchableRegularFileCount, 1, "searchable count"
            )
        case .policyIgnoredRegularFile:
            accumulator.policyIgnoredRegularFileCount = try add(
                accumulator.policyIgnoredRegularFileCount, 1, "ignored count"
            )
        case .nonRegularTopology:
            accumulator.nonRegularTopologyCount = try add(
                accumulator.nonRegularTopologyCount, 1, "topology count"
            )
        }
    }

    func makeFinalFooter(
        accumulator: WorkspaceRootReusableInventoryAccumulator,
        digest: Data
    ) throws -> WorkspaceRootReusableInventoryManifestFooter {
        WorkspaceRootReusableInventoryManifestFooter(
            totalRecordCount: accumulator.totalRecordCount,
            searchableRegularFileCount: accumulator.searchableRegularFileCount,
            policyIgnoredRegularFileCount: accumulator.policyIgnoredRegularFileCount,
            nonRegularTopologyCount: accumulator.nonRegularTopologyCount,
            recordPayloadByteCount: accumulator.recordPayloadByteCount,
            pathPayloadByteCount: accumulator.pathPayloadByteCount,
            manifestDigest: digest
        )
    }

    func encodeFinalFooter(_ footer: WorkspaceRootReusableInventoryManifestFooter) throws -> Data {
        try WorkspaceRootReusableInventoryManifestCodec.encodeFooter(footer)
    }

    private func add(_ lhs: UInt64, _ rhs: UInt64, _ label: String) throws -> UInt64 {
        let (result, overflowed) = lhs.addingReportingOverflow(rhs)
        guard !overflowed else { throw WorkspaceRootReusableInventoryManifestError.corrupt("\(label) overflow") }
        return result
    }

    private func exactUInt64(_ value: Int, _ label: String) throws -> UInt64 {
        guard let result = UInt64(exactly: value) else {
            throw WorkspaceRootReusableInventoryManifestError.corrupt("\(label) overflow")
        }
        return result
    }
}

private struct WorkspaceRootReusableInventoryCanonicalRecord: Equatable {
    let normalizedPathBytes: Data
    let rawPathBytes: Data
}

private struct WorkspaceRootReusableInventoryCanonicalFooter {
    let count: UInt64
    let digest: Data
}

/// A temporary sorted index makes canonical-equivalence rejection bounded too.
/// Its equal-key policy distinguishes an identical duplicate from two distinct
/// raw paths that Foundation normalizes to the same NFC spelling.
private struct WorkspaceRootReusableInventoryCanonicalFormat: SpillBackedSortedArtifactFormat {
    typealias Record = WorkspaceRootReusableInventoryCanonicalRecord
    typealias Header = Data
    typealias Footer = WorkspaceRootReusableInventoryCanonicalFooter
    typealias FinalAccumulator = UInt64

    let fileExtension = "root-inventory-nfc-index"
    let maximumEncodedHeaderByteCount = 40
    let maximumEncodedFooterByteCount = 41

    func error(_ failure: SpillBackedSortedArtifactFailure) -> any Error {
        switch failure {
        case .invalidConfiguration: WorkspaceRootReusableInventoryManifestError.invalidConfiguration
        case .duplicateRecord: WorkspaceRootReusableInventoryManifestError.canonicalPathCollision
        case .outOfOrder: WorkspaceRootReusableInventoryManifestError.outOfOrder
        case .resourceAdmission: WorkspaceRootReusableInventoryManifestError.resourceAdmission
        case .closed: WorkspaceRootReusableInventoryManifestError.closed
        case let .corrupt(message): WorkspaceRootReusableInventoryManifestError.corrupt(message)
        case let .io(operation, code): WorkspaceRootReusableInventoryManifestError.io(operation: operation, code: code)
        }
    }

    func validate(_ record: Record, maximumRecordByteCount: Int) throws {
        guard !record.normalizedPathBytes.isEmpty, !record.rawPathBytes.isEmpty,
              !record.normalizedPathBytes.contains(0), !record.rawPathBytes.contains(0),
              try encodeRecord(record).count <= maximumRecordByteCount
        else { throw WorkspaceRootReusableInventoryManifestError.invalidRecord("invalid canonical path key") }
    }

    func encodeRecord(_ record: Record) throws -> Data {
        var data = Data()
        try WorkspaceRootReusableInventoryManifestCodec.append(record.normalizedPathBytes, to: &data)
        try WorkspaceRootReusableInventoryManifestCodec.append(record.rawPathBytes, to: &data)
        return data
    }

    func decodeRecord(_ payload: Data) throws -> Record {
        var cursor = WorkspaceRootReusableInventoryByteCursor(payload)
        let record = try Record(
            normalizedPathBytes: cursor.readLengthPrefixedData(),
            rawPathBytes: cursor.readLengthPrefixedData()
        )
        guard cursor.remaining == 0 else {
            throw WorkspaceRootReusableInventoryManifestError.corrupt("canonical index trailing bytes")
        }
        return record
    }

    func maximumEncodedRecordByteCount(maximumRecordByteCount: Int) -> Int {
        maximumRecordByteCount
    }

    func maximumEncodedFinalRecordByteCount(maximumRecordByteCount: Int) -> Int {
        maximumRecordByteCount + 5
    }

    func ordering(_ lhs: Record, _ rhs: Record) -> SpillBackedSortedArtifactOrdering {
        WorkspaceRootReusableInventoryManifestCodec.compare(lhs.normalizedPathBytes, rhs.normalizedPathBytes)
    }

    func duplicateResolution(
        _ existing: Record,
        _ candidate: Record
    ) throws -> SpillBackedSortedArtifactDuplicateResolution {
        existing.rawPathBytes == candidate.rawPathBytes ? .coalesce : .reject
    }

    func encodeFinalHeader(_ header: Data) throws -> Data {
        guard header.count == SHA256.byteCount else {
            throw WorkspaceRootReusableInventoryManifestError.invalidConfiguration
        }
        var data = Data("RPRINFC1".utf8)
        data.append(header)
        return data
    }

    func encodeFinalRecord(_: Record, encodedRecord: Data) throws -> Data {
        try WorkspaceRootReusableInventoryManifestCodec.recordFrame(encodedRecord)
    }

    func makeFinalAccumulator() -> UInt64 {
        0
    }

    func accumulateFinalRecord(_: Record, encodedRecordByteCount _: Int, into accumulator: inout UInt64) throws {
        guard accumulator != UInt64.max else {
            throw WorkspaceRootReusableInventoryManifestError.corrupt("canonical index count overflow")
        }
        accumulator += 1
    }

    func makeFinalFooter(accumulator: UInt64, digest: Data) throws -> Footer {
        Footer(count: accumulator, digest: digest)
    }

    func encodeFinalFooter(_ footer: Footer) throws -> Data {
        guard footer.digest.count == SHA256.byteCount else {
            throw WorkspaceRootReusableInventoryManifestError.corrupt("canonical index digest")
        }
        var data = Data([WorkspaceRootReusableInventoryManifestCodec.footerMarker])
        WorkspaceRootReusableInventoryManifestCodec.append(footer.count, to: &data)
        data.append(footer.digest)
        return data
    }
}

final class WorkspaceRootReusableInventoryManifestStore: @unchecked Sendable {
    private let spillStore: SpillBackedSortedArtifactStore

    var directoryURL: URL {
        spillStore.directoryURL
    }

    var activeArtifactURLs: [URL] {
        spillStore.activeArtifactURLs
    }

    init(directoryURL: URL? = nil) throws {
        do {
            spillStore = try SpillBackedSortedArtifactStore(
                directoryURL: directoryURL,
                defaultDirectoryStem: "repoprompt-root-reusable-inventory"
            )
        } catch let error as SpillBackedSortedArtifactStoreError {
            switch error {
            case .resourceAdmission:
                throw WorkspaceRootReusableInventoryManifestError.resourceAdmission
            case let .io(operation, code):
                throw WorkspaceRootReusableInventoryManifestError.io(operation: operation, code: code)
            }
        }
    }

    func makeWriter(
        header: WorkspaceRootReusableInventoryManifestHeader,
        resourcePolicy: WorkspaceRootReusableInventoryResourcePolicy = .default
    ) throws -> WorkspaceRootReusableInventoryManifestWriter {
        guard resourcePolicy.isValid else {
            throw WorkspaceRootReusableInventoryManifestError.invalidConfiguration
        }
        _ = try WorkspaceRootReusableInventoryManifestCodec.encodeHeader(header)
        let primary = try spillStore.makeWriter(
            format: WorkspaceRootReusableInventorySpillFormat(objectFormat: header.objectFormat),
            header: header,
            resourcePolicy: resourcePolicy.spillPolicy
        )
        do {
            let canonical = try spillStore.makeWriter(
                format: WorkspaceRootReusableInventoryCanonicalFormat(),
                header: header.compatibilityDigest,
                resourcePolicy: resourcePolicy.spillPolicy
            )
            return WorkspaceRootReusableInventoryManifestWriter(primary: primary, canonical: canonical)
        } catch {
            Task { await primary.cancel() }
            throw error
        }
    }

    func cleanup() throws {
        try spillStore.cleanup()
    }
}

actor WorkspaceRootReusableInventoryManifestWriter {
    private let primary: SpillBackedSortedArtifactWriter<WorkspaceRootReusableInventorySpillFormat>
    private let canonical: SpillBackedSortedArtifactWriter<WorkspaceRootReusableInventoryCanonicalFormat>
    private var closed = false

    fileprivate init(
        primary: SpillBackedSortedArtifactWriter<WorkspaceRootReusableInventorySpillFormat>,
        canonical: SpillBackedSortedArtifactWriter<WorkspaceRootReusableInventoryCanonicalFormat>
    ) {
        self.primary = primary
        self.canonical = canonical
    }

    func append(_ record: WorkspaceRootReusableInventoryManifestRecord) async throws {
        guard !closed else { throw WorkspaceRootReusableInventoryManifestError.closed }
        do {
            guard let path = String(data: record.rootRelativePathBytes, encoding: .utf8) else {
                throw WorkspaceRootReusableInventoryManifestError.invalidRecord("path is not UTF-8")
            }
            try await primary.append(record)
            try await canonical.append(
                WorkspaceRootReusableInventoryCanonicalRecord(
                    normalizedPathBytes: Data(path.precomposedStringWithCanonicalMapping.utf8),
                    rawPathBytes: record.rootRelativePathBytes
                )
            )
        } catch {
            closed = true
            await primary.cancel()
            await canonical.cancel()
            throw error
        }
    }

    func append(contentsOf records: [WorkspaceRootReusableInventoryManifestRecord]) async throws {
        for record in records {
            try await append(record)
        }
    }

    func finish() async throws -> WorkspaceRootReusableInventoryManifestLease {
        guard !closed else { throw WorkspaceRootReusableInventoryManifestError.closed }
        closed = true
        do {
            // Finishing the temporary index performs the bounded NFC collision
            // check. Discarding its lease immediately unlinks the index.
            _ = try await canonical.finish()
            let lease = try await primary.finish()
            return WorkspaceRootReusableInventoryManifestLease(spillLease: lease)
        } catch {
            await primary.cancel()
            await canonical.cancel()
            throw error
        }
    }

    func cancel() async {
        guard !closed else { return }
        closed = true
        await primary.cancel()
        await canonical.cancel()
    }
}

final class WorkspaceRootReusableInventoryManifestLease: @unchecked Sendable {
    let fileURL: URL
    let header: WorkspaceRootReusableInventoryManifestHeader
    let footer: WorkspaceRootReusableInventoryManifestFooter
    let statistics: WorkspaceRootReusableInventoryManifestStatistics

    var manifestDigest: Data {
        footer.manifestDigest
    }

    var artifactByteCount: UInt64 {
        statistics.finalByteCount
    }

    private let spillLease: SpillBackedSortedArtifactLease<WorkspaceRootReusableInventorySpillFormat>

    fileprivate init(spillLease: SpillBackedSortedArtifactLease<WorkspaceRootReusableInventorySpillFormat>) {
        self.spillLease = spillLease
        fileURL = spillLease.fileURL
        header = spillLease.header
        footer = spillLease.footer
        statistics = WorkspaceRootReusableInventoryManifestStatistics(
            initialRunCount: spillLease.statistics.initialRunCount,
            mergePassCount: spillLease.statistics.mergePassCount,
            peakBufferedRecordBytes: spillLease.statistics.peakBufferedRecordBytes,
            recordCount: spillLease.statistics.recordCount,
            finalByteCount: spillLease.statistics.finalByteCount,
            peakResidentScheduledRunCount: spillLease.peakResidentScheduledRunCount,
            peakWorkspaceByteCount: spillLease.statistics.peakWorkspaceByteCount,
            peakAggregateArtifactByteCount: spillLease.statistics.peakAggregateArtifactByteCount
        )
    }

    func makeReader() throws -> WorkspaceRootReusableInventoryManifestReader {
        let descriptor = try spillLease.openValidatedDescriptor()
        do { return try WorkspaceRootReusableInventoryManifestReader(descriptor: descriptor, lease: self) }
        catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    fileprivate func validateOpenDescriptor(_ descriptor: Int32) throws {
        try spillLease.validateOpenDescriptor(descriptor)
    }

    #if DEBUG
        func materializeForTesting(maximumRecordCount: Int = 100_000) throws -> [RootNeutralTreeInventoryEntry] {
            guard maximumRecordCount >= 0 else {
                throw WorkspaceRootReusableInventoryManifestError.invalidConfiguration
            }
            let reader = try makeReader()
            var result: [RootNeutralTreeInventoryEntry] = []
            result.reserveCapacity(min(maximumRecordCount, Int(statistics.recordCount)))
            while let entry = try reader.next() {
                guard result.count < maximumRecordCount else {
                    throw WorkspaceRootReusableInventoryManifestError.resourceAdmission
                }
                result.append(entry)
            }
            guard reader.validationState == .verified else {
                throw WorkspaceRootReusableInventoryManifestError.corrupt("reader did not verify")
            }
            return result
        }
    #endif
}

/// Forward-only validating reader. Returned entries remain provisional until
/// `next()` returns nil and `validationState` is `.verified`.
final class WorkspaceRootReusableInventoryManifestReader: @unchecked Sendable {
    let header: WorkspaceRootReusableInventoryManifestHeader
    private(set) var footer: WorkspaceRootReusableInventoryManifestFooter?
    private(set) var validationState = WorkspaceRootReusableInventoryReaderValidationState.reading

    private struct Ancestor {
        let path: Data
        let ordinal: Int
        let kind: GitTreeEntryKind
    }

    private let descriptor: Int32
    private let retainedLease: WorkspaceRootReusableInventoryManifestLease
    private let lock = NSLock()
    private var digest: SHA256
    private var previousRecord: WorkspaceRootReusableInventoryManifestRecord?
    private var accumulator = WorkspaceRootReusableInventoryAccumulator()
    private var ancestors: [Ancestor] = []

    fileprivate init(descriptor: Int32, lease: WorkspaceRootReusableInventoryManifestLease) throws {
        self.descriptor = descriptor
        retainedLease = lease
        let headerFrame = try WorkspaceRootReusableInventoryManifestCodec.readHeaderFrame(from: descriptor)
        guard headerFrame.header == lease.header else {
            throw WorkspaceRootReusableInventoryManifestError.corrupt("lease header mismatch")
        }
        var digest = SHA256()
        digest.update(data: headerFrame.encodedFrame)
        self.digest = digest
        header = headerFrame.header
        try lease.validateOpenDescriptor(descriptor)
    }

    deinit { Darwin.close(descriptor) }

    func next() throws -> RootNeutralTreeInventoryEntry? {
        lock.lock()
        defer { lock.unlock() }
        switch validationState {
        case .verified: return nil
        case .failed:
            throw WorkspaceRootReusableInventoryManifestError.corrupt("reader validation already failed")
        case .reading: break
        }
        do { return try readNext() }
        catch {
            validationState = .failed
            throw error
        }
    }

    private func readNext() throws -> RootNeutralTreeInventoryEntry? {
        try retainedLease.validateOpenDescriptor(descriptor)
        let marker = try WorkspaceRootReusableInventoryManifestCodec.readExact(descriptor, count: 1)
        guard let byte = marker.first else {
            throw WorkspaceRootReusableInventoryManifestError.corrupt("missing footer")
        }
        switch byte {
        case WorkspaceRootReusableInventoryManifestCodec.recordMarker:
            let lengthBytes = try WorkspaceRootReusableInventoryManifestCodec.readExact(descriptor, count: 4)
            var lengthCursor = WorkspaceRootReusableInventoryByteCursor(lengthBytes)
            let length = try lengthCursor.readUInt32()
            guard length > 0, length <= WorkspaceRootReusableInventoryManifestCodec.maximumRecordPayloadByteCount else {
                throw WorkspaceRootReusableInventoryManifestError.corrupt("invalid record length")
            }
            let payload = try WorkspaceRootReusableInventoryManifestCodec.readExact(
                descriptor, count: Int(length)
            )
            var frame = marker
            frame.append(lengthBytes)
            frame.append(payload)
            digest.update(data: frame)
            let record = try WorkspaceRootReusableInventoryManifestCodec.decodeRecord(
                payload, objectFormat: header.objectFormat
            )
            if let previousRecord {
                switch WorkspaceRootReusableInventoryManifestCodec.compare(
                    previousRecord.rootRelativePathBytes, record.rootRelativePathBytes
                ) {
                case .ascending: break
                case .same: throw WorkspaceRootReusableInventoryManifestError.duplicateRecord
                case .descending: throw WorkspaceRootReusableInventoryManifestError.outOfOrder
                }
            }
            previousRecord = record

            guard let ordinal = Int(exactly: accumulator.totalRecordCount),
                  let relativePath = String(data: record.rootRelativePathBytes, encoding: .utf8)
            else { throw WorkspaceRootReusableInventoryManifestError.corrupt("record ordinal or path overflow") }
            let parentPath = WorkspaceRootReusableInventoryManifestCodec.parentPath(of: record.rootRelativePathBytes)
            while let last = ancestors.last,
                  !WorkspaceRootReusableInventoryManifestCodec.isDescendant(
                      record.rootRelativePathBytes, of: last.path
                  )
            {
                ancestors.removeLast()
            }
            let parentOrdinal: Int?
            if let parentPath, let last = ancestors.last, last.path == parentPath {
                guard last.kind == .tree else {
                    throw WorkspaceRootReusableInventoryManifestError.corrupt("non-tree path has descendants")
                }
                parentOrdinal = last.ordinal
            } else {
                parentOrdinal = nil
            }
            let encodedCount = try exactUInt64(payload.count, "record payload byte count")
            accumulator.totalRecordCount = try add(accumulator.totalRecordCount, 1, "record count")
            accumulator.recordPayloadByteCount = try add(
                accumulator.recordPayloadByteCount, encodedCount, "record payload byte count"
            )
            accumulator.pathPayloadByteCount = try add(
                accumulator.pathPayloadByteCount,
                exactUInt64(record.rootRelativePathBytes.count, "path payload byte count"),
                "path payload byte count"
            )
            switch record.catalogProjection {
            case .searchableRegularFile:
                accumulator.searchableRegularFileCount = try add(
                    accumulator.searchableRegularFileCount, 1, "searchable count"
                )
            case .policyIgnoredRegularFile:
                accumulator.policyIgnoredRegularFileCount = try add(
                    accumulator.policyIgnoredRegularFileCount, 1, "ignored count"
                )
            case .nonRegularTopology:
                accumulator.nonRegularTopologyCount = try add(
                    accumulator.nonRegularTopologyCount, 1, "topology count"
                )
            }
            ancestors.append(Ancestor(path: record.rootRelativePathBytes, ordinal: ordinal, kind: record.kind))
            guard ancestors.count <= WorkspaceRootReusableInventoryManifestCodec.maximumPathDepth else {
                throw WorkspaceRootReusableInventoryManifestError.corrupt("ancestor depth exceeded")
            }
            return RootNeutralTreeInventoryEntry(
                ordinal: ordinal,
                parentOrdinal: parentOrdinal,
                relativePath: relativePath,
                mode: record.mode,
                kind: record.kind,
                objectID: record.objectID,
                provenance: record.provenance,
                catalogProjection: record.catalogProjection
            )

        case WorkspaceRootReusableInventoryManifestCodec.footerMarker:
            let payload = try WorkspaceRootReusableInventoryManifestCodec.readExact(
                descriptor,
                count: WorkspaceRootReusableInventoryManifestCodec.footerPayloadByteCount
            )
            let parsed = try WorkspaceRootReusableInventoryManifestCodec.decodeFooter(payload)
            guard parsed.totalRecordCount == accumulator.totalRecordCount,
                  parsed.searchableRegularFileCount == accumulator.searchableRegularFileCount,
                  parsed.policyIgnoredRegularFileCount == accumulator.policyIgnoredRegularFileCount,
                  parsed.nonRegularTopologyCount == accumulator.nonRegularTopologyCount,
                  parsed.recordPayloadByteCount == accumulator.recordPayloadByteCount,
                  parsed.pathPayloadByteCount == accumulator.pathPayloadByteCount,
                  parsed.manifestDigest == Data(digest.finalize()), parsed == retainedLease.footer
            else { throw WorkspaceRootReusableInventoryManifestError.corrupt("footer mismatch") }
            try WorkspaceRootReusableInventoryManifestCodec.requireEndOfFile(descriptor)
            try retainedLease.validateOpenDescriptor(descriptor)
            footer = parsed
            validationState = .verified
            ancestors.removeAll(keepingCapacity: false)
            return nil

        default:
            throw WorkspaceRootReusableInventoryManifestError.corrupt("invalid frame marker")
        }
    }

    private func add(_ lhs: UInt64, _ rhs: UInt64, _ label: String) throws -> UInt64 {
        let (result, overflowed) = lhs.addingReportingOverflow(rhs)
        guard !overflowed else { throw WorkspaceRootReusableInventoryManifestError.corrupt("\(label) overflow") }
        return result
    }

    private func exactUInt64(_ value: Int, _ label: String) throws -> UInt64 {
        guard let result = UInt64(exactly: value) else {
            throw WorkspaceRootReusableInventoryManifestError.corrupt("\(label) overflow")
        }
        return result
    }
}

private enum WorkspaceRootReusableInventoryManifestCodec {
    static let magic = Data("RPWRINV1".utf8)
    static let recordMarker: UInt8 = 0x52
    static let footerMarker: UInt8 = 0x46
    static let maximumHeaderPayloadByteCount = 1024 * 1024
    static let maximumHeaderFrameByteCount = magic.count + 8 + maximumHeaderPayloadByteCount + SHA256.byteCount
    static let maximumRecordPayloadByteCount = SpillBackedSortedArtifactChecked.maximumFrameByteCount - 5
    static let footerPayloadByteCount = 6 * 8 + SHA256.byteCount
    static let footerFrameByteCount = 1 + footerPayloadByteCount
    static let maximumPathByteCount = 16 * 1024
    static let maximumPathDepth = 512

    struct HeaderFrame {
        let header: WorkspaceRootReusableInventoryManifestHeader
        let encodedFrame: Data
    }

    static func validate(
        _ record: WorkspaceRootReusableInventoryManifestRecord,
        objectFormat: GitObjectFormat
    ) throws {
        try validatePath(record.rootRelativePathBytes)
        let modeBytes = Data(record.mode.utf8)
        guard modeBytes.count == 6,
              modeBytes.allSatisfy({ (UInt8(ascii: "0") ... UInt8(ascii: "7")).contains($0) }),
              record.objectID.objectFormat == objectFormat,
              record.provenance == .committedTree
        else { throw WorkspaceRootReusableInventoryManifestError.invalidRecord("invalid inventory metadata") }
        let isRegular = record.kind == .blob && (record.mode == "100644" || record.mode == "100755")
        switch (isRegular, record.catalogProjection) {
        case (true, .searchableRegularFile), (true, .policyIgnoredRegularFile), (false, .nonRegularTopology):
            break
        default:
            throw WorkspaceRootReusableInventoryManifestError.invalidRecord("invalid catalog projection")
        }
    }

    static func validatePath(_ path: Data) throws {
        guard !path.isEmpty, path.count <= maximumPathByteCount,
              path.first != UInt8(ascii: "/"), !path.contains(0),
              String(data: path, encoding: .utf8) != nil
        else { throw WorkspaceRootReusableInventoryManifestError.invalidRecord("invalid root-relative path") }
        let components = path.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false)
        guard components.count <= maximumPathDepth,
              components.allSatisfy({
                  !$0.isEmpty && !$0.elementsEqual([UInt8(ascii: ".")]) &&
                      !$0.elementsEqual([UInt8(ascii: "."), UInt8(ascii: ".")])
              })
        else { throw WorkspaceRootReusableInventoryManifestError.invalidRecord("invalid root-relative path") }
    }

    static func encode(_ record: WorkspaceRootReusableInventoryManifestRecord) throws -> Data {
        var data = Data()
        try append(record.rootRelativePathBytes, to: &data)
        try append(Data(record.mode.utf8), to: &data)
        data.append(kindByte(record.kind))
        try append(Data(record.objectID.lowercaseHex.utf8), to: &data)
        data.append(provenanceByte(record.provenance))
        data.append(projectionByte(record.catalogProjection))
        return data
    }

    static func decodeRecord(
        _ payload: Data,
        objectFormat: GitObjectFormat
    ) throws -> WorkspaceRootReusableInventoryManifestRecord {
        var cursor = WorkspaceRootReusableInventoryByteCursor(payload)
        let path = try cursor.readLengthPrefixedData()
        let modeBytes = try cursor.readLengthPrefixedData()
        guard let mode = String(data: modeBytes, encoding: .utf8),
              let kind = try decodeKind(cursor.readUInt8()),
              let oidString = try String(data: cursor.readLengthPrefixedData(), encoding: .utf8),
              let provenance = try decodeProvenance(cursor.readUInt8()),
              let projection = try decodeProjection(cursor.readUInt8()),
              cursor.remaining == 0
        else { throw WorkspaceRootReusableInventoryManifestError.corrupt("invalid record payload") }
        let objectID: GitObjectID
        do { objectID = try GitObjectID(objectFormat: objectFormat, lowercaseHex: oidString) }
        catch { throw WorkspaceRootReusableInventoryManifestError.corrupt("invalid record object ID") }
        let record = WorkspaceRootReusableInventoryManifestRecord(
            rootRelativePathBytes: path,
            mode: mode,
            kind: kind,
            objectID: objectID,
            provenance: provenance,
            catalogProjection: projection
        )
        try validate(record, objectFormat: objectFormat)
        return record
    }

    static func encodeHeader(_ header: WorkspaceRootReusableInventoryManifestHeader) throws -> Data {
        let compatibilityDomain = Data(header.compatibilityDomain.utf8)
        let commandFormat = Data(header.commandFormat.utf8)
        let prefix = Data(header.repositoryRelativeRootPrefix.value.utf8)
        guard header.schemaVersion == WorkspaceRootReusableInventoryManifestHeader.currentSchemaVersion,
              !compatibilityDomain.isEmpty, compatibilityDomain.count <= maximumHeaderPayloadByteCount,
              header.compatibilityDigest.count == SHA256.byteCount,
              header.rawStandardOutputDigest.count == SHA256.byteCount,
              header.catalogPolicyDigest.count == SHA256.byteCount,
              !commandFormat.isEmpty, commandFormat.count <= maximumHeaderPayloadByteCount,
              header.treeOID.objectFormat == header.objectFormat
        else { throw WorkspaceRootReusableInventoryManifestError.invalidConfiguration }
        var payload = Data()
        try append(compatibilityDomain, to: &payload)
        try append(header.compatibilityDigest, to: &payload)
        try append(Data(header.treeOID.lowercaseHex.utf8), to: &payload)
        try append(Data(header.objectFormat.rawValue.utf8), to: &payload)
        try append(prefix, to: &payload)
        try append(commandFormat, to: &payload)
        try append(header.rawStandardOutputDigest, to: &payload)
        try append(header.catalogPolicyDigest, to: &payload)
        guard payload.count <= maximumHeaderPayloadByteCount, let count = UInt32(exactly: payload.count) else {
            throw WorkspaceRootReusableInventoryManifestError.invalidConfiguration
        }
        var frame = magic
        append(header.schemaVersion, to: &frame)
        append(count, to: &frame)
        frame.append(payload)
        frame.append(Data(SHA256.hash(data: payload)))
        return frame
    }

    static func readHeaderFrame(from descriptor: Int32) throws -> HeaderFrame {
        let prefix = try readExact(descriptor, count: magic.count + 8)
        guard prefix.prefix(magic.count) == magic else {
            throw WorkspaceRootReusableInventoryManifestError.corrupt("invalid magic")
        }
        var cursor = WorkspaceRootReusableInventoryByteCursor(Data(prefix.dropFirst(magic.count)))
        let schema = try cursor.readUInt32()
        let count = try cursor.readUInt32()
        guard schema == WorkspaceRootReusableInventoryManifestHeader.currentSchemaVersion,
              count > 0, count <= maximumHeaderPayloadByteCount
        else { throw WorkspaceRootReusableInventoryManifestError.corrupt("unsupported header") }
        let payload = try readExact(descriptor, count: Int(count))
        let checksum = try readExact(descriptor, count: SHA256.byteCount)
        guard checksum == Data(SHA256.hash(data: payload)) else {
            throw WorkspaceRootReusableInventoryManifestError.corrupt("header checksum")
        }
        var encoded = prefix
        encoded.append(payload)
        encoded.append(checksum)
        return try HeaderFrame(header: decodeHeader(schema: schema, payload: payload), encodedFrame: encoded)
    }

    static func decodeHeader(
        schema: UInt32,
        payload: Data
    ) throws -> WorkspaceRootReusableInventoryManifestHeader {
        var cursor = WorkspaceRootReusableInventoryByteCursor(payload)
        let domainBytes = try cursor.readLengthPrefixedData()
        let compatibilityDigest = try cursor.readLengthPrefixedData()
        let oidBytes = try cursor.readLengthPrefixedData()
        let formatBytes = try cursor.readLengthPrefixedData()
        let prefixBytes = try cursor.readLengthPrefixedData()
        let commandBytes = try cursor.readLengthPrefixedData()
        let stdoutDigest = try cursor.readLengthPrefixedData()
        let catalogDigest = try cursor.readLengthPrefixedData()
        guard cursor.remaining == 0,
              let domain = String(data: domainBytes, encoding: .utf8), !domain.isEmpty,
              compatibilityDigest.count == SHA256.byteCount,
              let oid = String(data: oidBytes, encoding: .utf8),
              let formatString = String(data: formatBytes, encoding: .utf8),
              let format = GitObjectFormat(rawValue: formatString),
              let prefixString = String(data: prefixBytes, encoding: .utf8),
              let command = String(data: commandBytes, encoding: .utf8), !command.isEmpty,
              stdoutDigest.count == SHA256.byteCount, catalogDigest.count == SHA256.byteCount
        else { throw WorkspaceRootReusableInventoryManifestError.corrupt("invalid header payload") }
        do {
            return try WorkspaceRootReusableInventoryManifestHeader(
                schemaVersion: schema,
                compatibilityDomain: domain,
                compatibilityDigest: compatibilityDigest,
                treeOID: GitObjectID(objectFormat: format, lowercaseHex: oid),
                objectFormat: format,
                repositoryRelativeRootPrefix: GitRepositoryRelativeRootPrefix(prefixString),
                commandFormat: command,
                rawStandardOutputDigest: stdoutDigest,
                catalogPolicyDigest: catalogDigest
            )
        } catch {
            throw WorkspaceRootReusableInventoryManifestError.corrupt("invalid header identity")
        }
    }

    static func recordFrame(_ payload: Data) throws -> Data {
        guard !payload.isEmpty, payload.count <= maximumRecordPayloadByteCount,
              let count = UInt32(exactly: payload.count)
        else { throw WorkspaceRootReusableInventoryManifestError.resourceAdmission }
        var frame = Data([recordMarker])
        append(count, to: &frame)
        frame.append(payload)
        return frame
    }

    static func encodeFooter(_ footer: WorkspaceRootReusableInventoryManifestFooter) throws -> Data {
        guard footer.manifestDigest.count == SHA256.byteCount else {
            throw WorkspaceRootReusableInventoryManifestError.corrupt("invalid footer digest")
        }
        let sumA = try add(footer.searchableRegularFileCount, footer.policyIgnoredRegularFileCount)
        let sum = try add(sumA, footer.nonRegularTopologyCount)
        guard sum == footer.totalRecordCount else {
            throw WorkspaceRootReusableInventoryManifestError.corrupt("footer category mismatch")
        }
        var frame = Data([footerMarker])
        for value in [
            footer.totalRecordCount,
            footer.searchableRegularFileCount,
            footer.policyIgnoredRegularFileCount,
            footer.nonRegularTopologyCount,
            footer.recordPayloadByteCount,
            footer.pathPayloadByteCount
        ] {
            append(value, to: &frame)
        }
        frame.append(footer.manifestDigest)
        return frame
    }

    static func decodeFooter(_ payload: Data) throws -> WorkspaceRootReusableInventoryManifestFooter {
        guard payload.count == footerPayloadByteCount else {
            throw WorkspaceRootReusableInventoryManifestError.corrupt("invalid footer size")
        }
        var cursor = WorkspaceRootReusableInventoryByteCursor(payload)
        let footer = try WorkspaceRootReusableInventoryManifestFooter(
            totalRecordCount: cursor.readUInt64(),
            searchableRegularFileCount: cursor.readUInt64(),
            policyIgnoredRegularFileCount: cursor.readUInt64(),
            nonRegularTopologyCount: cursor.readUInt64(),
            recordPayloadByteCount: cursor.readUInt64(),
            pathPayloadByteCount: cursor.readUInt64(),
            manifestDigest: cursor.readData(count: SHA256.byteCount)
        )
        guard cursor.remaining == 0 else {
            throw WorkspaceRootReusableInventoryManifestError.corrupt("invalid footer")
        }
        return footer
    }

    static func readExact(_ descriptor: Int32, count: Int) throws -> Data {
        guard count >= 0 else { throw WorkspaceRootReusableInventoryManifestError.corrupt("negative read") }
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let amount = data.withUnsafeMutableBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                return Darwin.read(descriptor, base.advanced(by: offset), count - offset)
            }
            if amount > 0 { offset += amount }
            else if amount == 0 { throw WorkspaceRootReusableInventoryManifestError.corrupt("truncated file") }
            else if errno != EINTR {
                throw WorkspaceRootReusableInventoryManifestError.io(operation: "read", code: errno)
            }
        }
        return data
    }

    static func requireEndOfFile(_ descriptor: Int32) throws {
        var byte: UInt8 = 0
        while true {
            let count = Darwin.read(descriptor, &byte, 1)
            if count == 0 { return }
            if count > 0 { throw WorkspaceRootReusableInventoryManifestError.corrupt("trailing bytes") }
            guard errno == EINTR else {
                throw WorkspaceRootReusableInventoryManifestError.io(operation: "trailing-read", code: errno)
            }
        }
    }

    static func append(_ value: Data, to data: inout Data) throws {
        guard let count = UInt32(exactly: value.count) else {
            throw WorkspaceRootReusableInventoryManifestError.resourceAdmission
        }
        append(count, to: &data)
        data.append(value)
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

    static func compare(_ lhs: Data, _ rhs: Data) -> SpillBackedSortedArtifactOrdering {
        if lhs == rhs { return .same }
        return lhs.lexicographicallyPrecedes(rhs) ? .ascending : .descending
    }

    static func parentPath(of path: Data) -> Data? {
        guard let slash = path.lastIndex(of: UInt8(ascii: "/")), slash > path.startIndex else { return nil }
        return Data(path[..<slash])
    }

    static func isDescendant(_ path: Data, of ancestor: Data) -> Bool {
        guard path.count > ancestor.count, path.starts(with: ancestor) else { return false }
        return path[path.index(path.startIndex, offsetBy: ancestor.count)] == UInt8(ascii: "/")
    }

    private static func add(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let (value, overflowed) = lhs.addingReportingOverflow(rhs)
        guard !overflowed else { throw WorkspaceRootReusableInventoryManifestError.corrupt("footer count overflow") }
        return value
    }

    private static func kindByte(_ kind: GitTreeEntryKind) -> UInt8 {
        switch kind { case .blob: 1
        case .tree: 2
        case .commit: 3 }
    }

    private static func decodeKind(_ byte: UInt8) throws -> GitTreeEntryKind? {
        switch byte { case 1: .blob
        case 2: .tree
        case 3: .commit
        default: nil }
    }

    private static func provenanceByte(_ value: RootNeutralTreeInventoryEntry.Provenance) -> UInt8 {
        switch value { case .committedTree: 1 }
    }

    private static func decodeProvenance(
        _ byte: UInt8
    ) throws -> RootNeutralTreeInventoryEntry.Provenance? {
        byte == 1 ? .committedTree : nil
    }

    private static func projectionByte(_ value: RootNeutralTreeInventoryEntry.CatalogProjection) -> UInt8 {
        switch value {
        case .searchableRegularFile: 1
        case .policyIgnoredRegularFile: 2
        case .nonRegularTopology: 3
        }
    }

    private static func decodeProjection(
        _ byte: UInt8
    ) throws -> RootNeutralTreeInventoryEntry.CatalogProjection? {
        switch byte {
        case 1: .searchableRegularFile
        case 2: .policyIgnoredRegularFile
        case 3: .nonRegularTopology
        default: nil
        }
    }
}

private struct WorkspaceRootReusableInventoryByteCursor {
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
            throw WorkspaceRootReusableInventoryManifestError.corrupt("truncated payload")
        }
        defer { offset += count }
        return Data(data[offset ..< offset + count])
    }

    mutating func readUInt8() throws -> UInt8 {
        guard remaining >= 1 else {
            throw WorkspaceRootReusableInventoryManifestError.corrupt("truncated integer")
        }
        defer { offset += 1 }
        return data[offset]
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

    mutating func readLengthPrefixedData() throws -> Data {
        try readData(count: Int(readUInt32()))
    }
}

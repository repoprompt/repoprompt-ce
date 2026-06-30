import CryptoKit
import Darwin
import Foundation

struct WorkspaceRootNamespaceManifestResourcePolicy: Equatable {
    static let `default` = WorkspaceRootNamespaceManifestResourcePolicy()

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
            maximumRecordByteCount <= WorkspaceRootNamespaceManifestCodec.maximumPathByteCount &&
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

struct WorkspaceRootNamespaceFinalAccumulator {
    var recordCount: UInt64 = 0
    var fileCount: UInt64 = 0
    var directoryCount: UInt64 = 0
    var recordPayloadByteCount: UInt64 = 0
}

struct WorkspaceRootNamespaceSpillFormat: SpillBackedSortedArtifactFormat {
    let fileExtension = "manifest"
    let maximumEncodedHeaderByteCount = WorkspaceRootNamespaceManifestCodec.magic.count + 8 +
        1024 * 1024 + SHA256.byteCount
    let maximumEncodedFooterByteCount = 1 + WorkspaceRootNamespaceManifestCodec.footerPayloadByteCount

    func error(_ failure: SpillBackedSortedArtifactFailure) -> any Error {
        switch failure {
        case .invalidConfiguration:
            WorkspaceRootNamespaceManifestError.invalidConfiguration
        case .duplicateRecord:
            WorkspaceRootNamespaceManifestError.duplicatePath
        case .outOfOrder:
            WorkspaceRootNamespaceManifestError.outOfOrder
        case .resourceAdmission:
            WorkspaceRootNamespaceManifestError.resourceAdmission
        case .closed:
            WorkspaceRootNamespaceManifestError.closed
        case let .corrupt(message):
            WorkspaceRootNamespaceManifestError.corrupt(message)
        case let .io(operation, code):
            WorkspaceRootNamespaceManifestError.io(operation: operation, code: code)
        }
    }

    func validate(
        _ record: WorkspaceRootNamespaceRecord,
        maximumRecordByteCount: Int
    ) throws {
        try WorkspaceRootNamespaceManifestCodec.validate(
            record,
            maximumByteCount: maximumRecordByteCount
        )
    }

    func encodeRecord(_ record: WorkspaceRootNamespaceRecord) throws -> Data {
        try WorkspaceRootNamespaceManifestCodec.encodeRecord(record)
    }

    func decodeRecord(_ payload: Data) throws -> WorkspaceRootNamespaceRecord {
        try WorkspaceRootNamespaceManifestCodec.decodeRecord(payload)
    }

    func maximumEncodedRecordByteCount(maximumRecordByteCount: Int) -> Int {
        maximumRecordByteCount + 8
    }

    func maximumEncodedFinalRecordByteCount(maximumRecordByteCount: Int) -> Int {
        maximumRecordByteCount + 8 + 5
    }

    func ordering(
        _ lhs: WorkspaceRootNamespaceRecord,
        _ rhs: WorkspaceRootNamespaceRecord
    ) -> SpillBackedSortedArtifactOrdering {
        if lhs.relativePathBytes == rhs.relativePathBytes { return .same }
        return WorkspaceRootNamespaceManifestCodec.lexicallyPrecedes(
            lhs.relativePathBytes,
            rhs.relativePathBytes
        ) ? .ascending : .descending
    }

    func encodeFinalHeader(_ header: WorkspaceRootNamespaceManifestHeader) throws -> Data {
        WorkspaceRootNamespaceManifestCodec.encodeHeader(header)
    }

    func encodeFinalRecord(
        _: WorkspaceRootNamespaceRecord,
        encodedRecord: Data
    ) throws -> Data {
        guard encodedRecord.count <= Int(UInt32.max) else {
            throw WorkspaceRootNamespaceManifestError.invalidRecord
        }
        var frame = Data([WorkspaceRootNamespaceManifestCodec.recordMarker])
        WorkspaceRootNamespaceManifestCodec.append(UInt32(encodedRecord.count), to: &frame)
        frame.append(encodedRecord)
        return frame
    }

    func makeFinalAccumulator() -> WorkspaceRootNamespaceFinalAccumulator {
        WorkspaceRootNamespaceFinalAccumulator()
    }

    func accumulateFinalRecord(
        _ record: WorkspaceRootNamespaceRecord,
        encodedRecordByteCount: Int,
        into accumulator: inout WorkspaceRootNamespaceFinalAccumulator
    ) throws {
        accumulator.recordCount = try addingOne(
            accumulator.recordCount,
            field: "record count"
        )
        accumulator.recordPayloadByteCount = try adding(
            exactUInt64(encodedRecordByteCount),
            to: accumulator.recordPayloadByteCount,
            field: "record payload byte count"
        )
        switch record.kind {
        case .file:
            accumulator.fileCount = try addingOne(accumulator.fileCount, field: "file count")
        case .directory:
            accumulator.directoryCount = try addingOne(
                accumulator.directoryCount,
                field: "directory count"
            )
        }
    }

    func makeFinalFooter(
        accumulator: WorkspaceRootNamespaceFinalAccumulator,
        digest: Data
    ) throws -> WorkspaceRootNamespaceManifestFooter {
        WorkspaceRootNamespaceManifestFooter(
            recordCount: accumulator.recordCount,
            fileCount: accumulator.fileCount,
            directoryCount: accumulator.directoryCount,
            recordPayloadByteCount: accumulator.recordPayloadByteCount,
            digest: digest
        )
    }

    func encodeFinalFooter(_ footer: WorkspaceRootNamespaceManifestFooter) throws -> Data {
        WorkspaceRootNamespaceManifestCodec.encodeFooter(footer)
    }

    private func addingOne(_ value: UInt64, field: String) throws -> UInt64 {
        try adding(1, to: value, field: field)
    }

    private func adding(_ increment: UInt64, to value: UInt64, field: String) throws -> UInt64 {
        let (result, overflowed) = value.addingReportingOverflow(increment)
        guard !overflowed else {
            throw WorkspaceRootNamespaceManifestError.corrupt("\(field) overflow")
        }
        return result
    }

    private func exactUInt64(_ value: Int) throws -> UInt64 {
        guard let converted = UInt64(exactly: value) else {
            throw WorkspaceRootNamespaceManifestError.corrupt(
                "record payload byte count conversion overflow"
            )
        }
        return converted
    }
}

final class WorkspaceRootNamespaceManifestStore: @unchecked Sendable {
    private let spillStore: SpillBackedSortedArtifactStore

    var directoryURL: URL {
        spillStore.directoryURL
    }

    init(directoryURL: URL? = nil) throws {
        do {
            spillStore = try SpillBackedSortedArtifactStore(
                directoryURL: directoryURL,
                defaultDirectoryStem: "repoprompt-namespace-manifests"
            )
        } catch let error as SpillBackedSortedArtifactStoreError {
            switch error {
            case .resourceAdmission:
                throw WorkspaceRootNamespaceManifestError.resourceAdmission
            case let .io(operation, code):
                throw WorkspaceRootNamespaceManifestError.io(operation: operation, code: code)
            }
        }
    }

    func makeWriter(
        identity: WorkspaceRootNamespaceManifestIdentity,
        resourcePolicy: WorkspaceRootNamespaceManifestResourcePolicy = .default
    ) throws -> WorkspaceRootNamespaceManifestWriter {
        guard resourcePolicy.isValid else {
            throw WorkspaceRootNamespaceManifestError.invalidConfiguration
        }
        let policy = identity.catalogPolicy
        guard !identity.root.canonicalPathBytes.isEmpty,
              identity.root.canonicalPathBytes.count <= 512 * 1024,
              policy.schemaVersion >= 0,
              policy.schemaVersion <= Int(UInt32.max),
              policy.mandatoryIgnorePolicyIdentity.utf8.count +
              policy.globalIgnoreDefaultsDigest.utf8.count <= 256 * 1024
        else { throw WorkspaceRootNamespaceManifestError.invalidConfiguration }

        let writer = try spillStore.makeWriter(
            format: WorkspaceRootNamespaceSpillFormat(),
            header: WorkspaceRootNamespaceManifestHeader(identity: identity),
            resourcePolicy: resourcePolicy.spillPolicy
        )
        return WorkspaceRootNamespaceManifestWriter(writer: writer)
    }

    var activeArtifactURLs: [URL] {
        spillStore.activeArtifactURLs
    }

    func cleanup() throws {
        try spillStore.cleanup()
    }

    #if DEBUG
        func setCleanupWillEnumerateHandlerForTesting(_ handler: (@Sendable () -> Void)?) {
            spillStore.setCleanupWillEnumerateHandlerForTesting(handler)
        }
    #endif
}

final class WorkspaceRootNamespaceManifestLease: @unchecked Sendable {
    let fileURL: URL
    let header: WorkspaceRootNamespaceManifestHeader
    let footer: WorkspaceRootNamespaceManifestFooter
    let statistics: WorkspaceRootNamespaceManifestStatistics
    let peakResidentScheduledRunCount: Int

    var digest: Data {
        footer.digest
    }

    private let spillLease: SpillBackedSortedArtifactLease<WorkspaceRootNamespaceSpillFormat>

    fileprivate init(
        spillLease: SpillBackedSortedArtifactLease<WorkspaceRootNamespaceSpillFormat>
    ) {
        self.spillLease = spillLease
        fileURL = spillLease.fileURL
        header = spillLease.header
        footer = spillLease.footer
        statistics = WorkspaceRootNamespaceManifestStatistics(
            initialRunCount: spillLease.statistics.initialRunCount,
            mergePassCount: spillLease.statistics.mergePassCount,
            peakBufferedRecordBytes: spillLease.statistics.peakBufferedRecordBytes,
            recordCount: spillLease.statistics.recordCount,
            finalByteCount: spillLease.statistics.finalByteCount
        )
        peakResidentScheduledRunCount = spillLease.peakResidentScheduledRunCount
    }

    func makeReader() throws -> WorkspaceRootNamespaceManifestReader {
        let descriptor = try spillLease.openValidatedDescriptor()
        do {
            return try WorkspaceRootNamespaceManifestReader(descriptor: descriptor, lease: self)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    func validateOpenDescriptor(_ descriptor: Int32) throws {
        try spillLease.validateOpenDescriptor(descriptor)
    }
}

actor WorkspaceRootNamespaceManifestWriter {
    private enum State {
        case open
        case directMutationActive
        case transactionActive
        case transactionVerified(SpillBackedSortedArtifactWriter<WorkspaceRootNamespaceSpillFormat>)
        case closed
    }

    private let writer: SpillBackedSortedArtifactWriter<WorkspaceRootNamespaceSpillFormat>
    private var state: State = .open
    private var hasDirectRecords = false
    #if DEBUG
        private var transactionDidAcquireSourceHandlerForTesting: (@Sendable () async -> Void)?
        private var transactionDidStageRecordHandlerForTesting: (@Sendable () async -> Void)?
    #endif

    fileprivate init(
        writer: SpillBackedSortedArtifactWriter<WorkspaceRootNamespaceSpillFormat>
    ) {
        self.writer = writer
    }

    func append(_ record: WorkspaceRootNamespaceRecord) async throws {
        guard case .open = state else {
            throw WorkspaceRootNamespaceManifestError.closed
        }
        state = .directMutationActive
        do {
            try await writer.append(record)
            hasDirectRecords = true
            state = .open
        } catch {
            state = .closed
            throw error
        }
    }

    func append(contentsOf records: [WorkspaceRootNamespaceRecord]) async throws {
        guard case .open = state else {
            throw WorkspaceRootNamespaceManifestError.closed
        }
        state = .directMutationActive
        do {
            try await writer.append(contentsOf: records)
            hasDirectRecords = hasDirectRecords || !records.isEmpty
            state = .open
        } catch {
            state = .closed
            throw error
        }
    }

    /// Transactionally derives a namespace artifact from one pristine forward
    /// reader. The reader is exclusively owned until authenticated EOF, and all
    /// provisional records remain in an isolated, unpublishable spill writer.
    func appendValidatedContents(
        from reader: WorkspaceRootNamespaceManifestReader
    ) async throws {
        guard case .open = state, !hasDirectRecords else {
            throw WorkspaceRootNamespaceManifestError.closed
        }
        state = .transactionActive

        let token: WorkspaceRootNamespaceManifestReaderConsumptionToken
        do {
            token = try reader.beginExclusiveConsumption()
        } catch {
            state = .open
            throw error
        }

        var stagingWriter: SpillBackedSortedArtifactWriter<WorkspaceRootNamespaceSpillFormat>?
        do {
            let staging = try await writer.makeIsolatedWriter()
            stagingWriter = staging
            await writer.cancel()

            #if DEBUG
                if let transactionDidAcquireSourceHandlerForTesting {
                    await transactionDidAcquireSourceHandlerForTesting()
                }
            #endif

            while let record = try reader.next(exclusive: token) {
                try await staging.append(record)
                #if DEBUG
                    if let transactionDidStageRecordHandlerForTesting {
                        await transactionDidStageRecordHandlerForTesting()
                    }
                #endif
            }
            try reader.completeExclusiveConsumption(token)
            state = .transactionVerified(staging)
        } catch {
            reader.abandonExclusiveConsumption(token)
            if let stagingWriter {
                await stagingWriter.cancel()
            }
            await writer.cancel()
            state = .closed
            throw error
        }
    }

    func finish() async throws -> WorkspaceRootNamespaceManifestLease {
        let publishingWriter: SpillBackedSortedArtifactWriter<WorkspaceRootNamespaceSpillFormat>
        switch state {
        case .open:
            publishingWriter = writer
        case let .transactionVerified(stagingWriter):
            publishingWriter = stagingWriter
        case .directMutationActive, .transactionActive, .closed:
            throw WorkspaceRootNamespaceManifestError.closed
        }
        state = .closed
        return try await WorkspaceRootNamespaceManifestLease(
            spillLease: publishingWriter.finish()
        )
    }

    func cancel() async {
        let writerToCancel: SpillBackedSortedArtifactWriter<WorkspaceRootNamespaceSpillFormat>
        switch state {
        case .open:
            writerToCancel = writer
        case let .transactionVerified(stagingWriter):
            writerToCancel = stagingWriter
        case .directMutationActive, .transactionActive, .closed:
            return
        }
        state = .closed
        await writerToCancel.cancel()
    }

    #if DEBUG
        func setTransactionDidAcquireSourceHandlerForTesting(
            _ handler: (@Sendable () async -> Void)?
        ) {
            transactionDidAcquireSourceHandlerForTesting = handler
        }

        func setTransactionDidStageRecordHandlerForTesting(
            _ handler: (@Sendable () async -> Void)?
        ) {
            transactionDidStageRecordHandlerForTesting = handler
        }
    #endif
}

import CryptoKit
import Darwin
import Foundation

enum SpillBackedSortedArtifactOrdering {
    case ascending
    case same
    case descending
}

enum SpillBackedSortedArtifactDuplicateResolution {
    case reject
    case coalesce
}

enum SpillBackedSortedArtifactFailure: Equatable {
    case invalidConfiguration
    case duplicateRecord
    case outOfOrder
    case resourceAdmission
    case closed
    case corrupt(String)
    case io(operation: String, code: Int32)
}

struct SpillBackedSortedArtifactResourcePolicy: Equatable {
    let maximumBufferedRecordBytes: Int
    let maximumRecordsPerBatch: Int
    let maximumRecordByteCount: Int
    let maximumOpenRuns: Int
    let minimumFreeDiskBytes: UInt64
    /// Optional store-wide quota for published artifacts plus bytes reserved by
    /// active writers. `nil` preserves the legacy behavior for existing users.
    let maximumAggregateArtifactBytes: UInt64?

    init(
        maximumBufferedRecordBytes: Int,
        maximumRecordsPerBatch: Int,
        maximumRecordByteCount: Int,
        maximumOpenRuns: Int,
        minimumFreeDiskBytes: UInt64,
        maximumAggregateArtifactBytes: UInt64? = nil
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
            maximumRecordByteCount > 0 && maximumOpenRuns >= 2
            && maximumAggregateArtifactBytes.map { $0 > 0 } != false
    }
}

struct SpillBackedSortedArtifactStatistics: Equatable {
    let initialRunCount: Int
    let mergePassCount: Int
    let peakBufferedRecordBytes: Int
    let recordCount: UInt64
    let finalByteCount: UInt64
    let peakWorkspaceByteCount: UInt64
    let peakAggregateArtifactByteCount: UInt64
}

struct SpillBackedSortedArtifactDescriptorIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
    let byteCount: UInt64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let statusChangeSeconds: Int64
    let statusChangeNanoseconds: Int64
}

enum SpillBackedSortedArtifactStoreError: Error {
    case resourceAdmission
    case io(operation: String, code: Int32)
}

protocol SpillBackedSortedArtifactFormat: Sendable {
    associatedtype Record: Sendable
    associatedtype Header: Sendable
    associatedtype Footer: Sendable
    associatedtype FinalAccumulator: Sendable

    var fileExtension: String { get }

    func error(_ failure: SpillBackedSortedArtifactFailure) -> any Error
    func validate(_ record: Record, maximumRecordByteCount: Int) throws
    func encodeRecord(_ record: Record) throws -> Data
    func decodeRecord(_ payload: Data) throws -> Record
    func maximumEncodedRecordByteCount(maximumRecordByteCount: Int) -> Int
    func maximumEncodedFinalRecordByteCount(maximumRecordByteCount: Int) -> Int
    var maximumEncodedHeaderByteCount: Int { get }
    var maximumEncodedFooterByteCount: Int { get }
    func ordering(_ lhs: Record, _ rhs: Record) -> SpillBackedSortedArtifactOrdering
    /// Called only when `ordering` returns `.same`. The format owns
    /// same-key equivalence; coalescing retains `existing` and drops `candidate`.
    /// The decision must be deterministic for every equal-key pair.
    func duplicateResolution(
        _ existing: Record,
        _ candidate: Record
    ) throws -> SpillBackedSortedArtifactDuplicateResolution

    func encodeFinalHeader(_ header: Header) throws -> Data
    func encodeFinalRecord(_ record: Record, encodedRecord: Data) throws -> Data
    func makeFinalAccumulator() -> FinalAccumulator
    func accumulateFinalRecord(
        _ record: Record,
        encodedRecordByteCount: Int,
        into accumulator: inout FinalAccumulator
    ) throws
    func makeFinalFooter(accumulator: FinalAccumulator, digest: Data) throws -> Footer
    func encodeFinalFooter(_ footer: Footer) throws -> Data
}

extension SpillBackedSortedArtifactFormat {
    func duplicateResolution(
        _: Record,
        _: Record
    ) throws -> SpillBackedSortedArtifactDuplicateResolution {
        .reject
    }
}

struct SpillBackedSortedArtifactFormatBounds {
    let record: Int
    let finalRecord: Int
    let header: Int
    let footer: Int
}

enum SpillBackedSortedArtifactChecked {
    static let maximumFrameByteCount = 16 * 1024 * 1024

    static func formatBounds(
        format: some SpillBackedSortedArtifactFormat,
        maximumRecordByteCount: Int
    ) throws -> SpillBackedSortedArtifactFormatBounds {
        let bounds = SpillBackedSortedArtifactFormatBounds(
            record: format.maximumEncodedRecordByteCount(
                maximumRecordByteCount: maximumRecordByteCount
            ),
            finalRecord: format.maximumEncodedFinalRecordByteCount(
                maximumRecordByteCount: maximumRecordByteCount
            ),
            header: format.maximumEncodedHeaderByteCount,
            footer: format.maximumEncodedFooterByteCount
        )
        guard bounds.record > 0,
              bounds.record < Int(UInt32.max),
              bounds.record <= maximumFrameByteCount,
              bounds.finalRecord > 0,
              bounds.finalRecord <= maximumFrameByteCount,
              bounds.header >= 0,
              bounds.header <= maximumFrameByteCount,
              bounds.footer >= 0,
              bounds.footer <= maximumFrameByteCount
        else { throw format.error(.invalidConfiguration) }
        return bounds
    }

    static func validate(
        byteCount: Int,
        maximum: Int,
        label: String,
        format: some SpillBackedSortedArtifactFormat
    ) throws {
        guard byteCount >= 0, byteCount <= maximum else {
            throw format.error(.corrupt("\(label) exceeds configured bound"))
        }
    }

    static func uint32Length(
        _ count: Int,
        label: String,
        format: some SpillBackedSortedArtifactFormat
    ) throws -> UInt32 {
        guard count >= 0,
              let value = UInt32(exactly: count),
              value != UInt32.max
        else { throw format.error(.corrupt("\(label) length overflow")) }
        return value
    }

    static func uint64(
        _ value: Int,
        label: String,
        format: some SpillBackedSortedArtifactFormat
    ) throws -> UInt64 {
        guard let converted = UInt64(exactly: value) else {
            throw format.error(.corrupt("\(label) conversion overflow"))
        }
        return converted
    }

    static func int(
        _ value: UInt64,
        label: String,
        format: some SpillBackedSortedArtifactFormat
    ) throws -> Int {
        guard let converted = Int(exactly: value) else {
            throw format.error(.corrupt("\(label) conversion overflow"))
        }
        return converted
    }

    static func add(
        _ lhs: Int,
        _ rhs: Int,
        label: String,
        format: some SpillBackedSortedArtifactFormat
    ) throws -> Int {
        let (result, overflowed) = lhs.addingReportingOverflow(rhs)
        guard !overflowed else {
            throw format.error(.corrupt("\(label) overflow"))
        }
        return result
    }

    static func add(
        _ lhs: UInt64,
        _ rhs: UInt64,
        label: String,
        format: some SpillBackedSortedArtifactFormat
    ) throws -> UInt64 {
        let (result, overflowed) = lhs.addingReportingOverflow(rhs)
        guard !overflowed else {
            throw format.error(.corrupt("\(label) overflow"))
        }
        return result
    }
}

/// Generic secure spill storage for byte-bounded sorted artifacts. Formats own
/// their public header/record/footer bytes; this engine owns private runs,
/// authenticated run catalogs, bounded fan-in merge, publication, and leases.
final class SpillBackedSortedArtifactStore: @unchecked Sendable {
    let directoryURL: URL

    private struct Artifact {
        let url: URL
        let identity: SpillBackedSortedArtifactDescriptorIdentity
        var leaseCount: Int
    }

    private let lock = NSLock()
    private var artifacts: [UUID: Artifact] = [:]
    private var activeWorkspaces: Set<String> = []
    private var reservedBytesByWorkspace: [String: UInt64] = [:]
    private var peakReservedBytesByWorkspace: [String: UInt64] = [:]
    private var peakAggregateBytesByWorkspace: [String: UInt64] = [:]
    #if DEBUG
        private var cleanupWillEnumerateHandlerForTesting: (@Sendable () -> Void)?
    #endif

    init(directoryURL: URL? = nil, defaultDirectoryStem: String) throws {
        let chosen = directoryURL ?? FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(defaultDirectoryStem)-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        self.directoryURL = chosen
        try Self.ensureSecureDirectory(chosen)
    }

    deinit {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    func makeWriter<Format: SpillBackedSortedArtifactFormat>(
        format: Format,
        header: Format.Header,
        resourcePolicy: SpillBackedSortedArtifactResourcePolicy
    ) throws -> SpillBackedSortedArtifactWriter<Format> {
        guard resourcePolicy.isValid else {
            throw format.error(.invalidConfiguration)
        }
        let formatBounds = try SpillBackedSortedArtifactChecked.formatBounds(
            format: format,
            maximumRecordByteCount: resourcePolicy.maximumRecordByteCount
        )
        try admit(resourcePolicy, format: format)
        let workspaceName = ".work.\(UUID().uuidString.lowercased())"
        let workspaceURL = directoryURL.appendingPathComponent(workspaceName, isDirectory: true)
        try lock.withArtifactLock {
            guard mkdir(workspaceURL.path, 0o700) == 0 else {
                throw format.error(.io(operation: "workspace-mkdir", code: errno))
            }
            activeWorkspaces.insert(workspaceName)
            reservedBytesByWorkspace[workspaceName] = 0
            peakReservedBytesByWorkspace[workspaceName] = 0
            peakAggregateBytesByWorkspace[workspaceName] = 0
        }
        return SpillBackedSortedArtifactWriter(
            store: self,
            format: format,
            header: header,
            policy: resourcePolicy,
            formatBounds: formatBounds,
            workspaceName: workspaceName,
            workspaceURL: workspaceURL
        )
    }

    var activeArtifactURLs: [URL] {
        lock.withArtifactLock { artifacts.values.map(\.url).sorted { $0.path < $1.path } }
    }

    func cleanup() throws {
        try lock.withArtifactLock {
            let retainedNames = Set(artifacts.values.map(\.url.lastPathComponent)).union(activeWorkspaces)
            #if DEBUG
                cleanupWillEnumerateHandlerForTesting?()
            #endif
            let children = try FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsSubdirectoryDescendants]
            )
            for child in children where !retainedNames.contains(child.lastPathComponent) {
                try FileManager.default.removeItem(at: child)
            }
        }
    }

    #if DEBUG
        func setCleanupWillEnumerateHandlerForTesting(_ handler: (@Sendable () -> Void)?) {
            lock.withArtifactLock { cleanupWillEnumerateHandlerForTesting = handler }
        }
    #endif

    fileprivate func admit(
        _ policy: SpillBackedSortedArtifactResourcePolicy,
        format: some SpillBackedSortedArtifactFormat
    ) throws {
        var information = statfs()
        guard statfs(directoryURL.path, &information) == 0 else {
            throw format.error(.io(operation: "statfs", code: errno))
        }
        let available = UInt64(information.f_bavail) * UInt64(information.f_bsize)
        guard available >= policy.minimumFreeDiskBytes else {
            throw format.error(.resourceAdmission)
        }
    }

    fileprivate func reserve(
        _ byteCount: UInt64,
        workspaceName: String,
        policy: SpillBackedSortedArtifactResourcePolicy,
        format: some SpillBackedSortedArtifactFormat
    ) throws {
        guard byteCount > 0, policy.maximumAggregateArtifactBytes != nil else { return }
        try lock.withArtifactLock {
            guard activeWorkspaces.contains(workspaceName),
                  let current = reservedBytesByWorkspace[workspaceName]
            else { throw format.error(.closed) }
            let (workspaceTotal, workspaceOverflow) = current.addingReportingOverflow(byteCount)
            guard !workspaceOverflow else { throw format.error(.resourceAdmission) }
            if let maximum = policy.maximumAggregateArtifactBytes {
                let artifactBytes = artifacts.values.reduce(UInt64(0)) { partial, artifact in
                    let (sum, overflow) = partial.addingReportingOverflow(artifact.identity.byteCount)
                    return overflow ? UInt64.max : sum
                }
                let otherReservations = reservedBytesByWorkspace.reduce(UInt64(0)) { partial, item in
                    let value = item.key == workspaceName ? workspaceTotal : item.value
                    let (sum, overflow) = partial.addingReportingOverflow(value)
                    return overflow ? UInt64.max : sum
                }
                let (aggregate, overflow) = artifactBytes.addingReportingOverflow(otherReservations)
                guard !overflow, aggregate <= maximum else {
                    throw format.error(.resourceAdmission)
                }
                peakAggregateBytesByWorkspace[workspaceName] = max(
                    peakAggregateBytesByWorkspace[workspaceName] ?? 0,
                    aggregate
                )
            }
            reservedBytesByWorkspace[workspaceName] = workspaceTotal
            peakReservedBytesByWorkspace[workspaceName] = max(
                peakReservedBytesByWorkspace[workspaceName] ?? 0,
                workspaceTotal
            )
        }
    }

    fileprivate func resourceHighWaterMarks(
        workspaceName: String
    ) -> (workspaceBytes: UInt64, aggregateBytes: UInt64) {
        lock.withArtifactLock {
            (
                peakReservedBytesByWorkspace[workspaceName] ?? 0,
                peakAggregateBytesByWorkspace[workspaceName] ?? 0
            )
        }
    }

    fileprivate func publish<Format: SpillBackedSortedArtifactFormat>(
        temporaryURL: URL,
        workspaceName: String,
        format: Format,
        header: Format.Header,
        footer: Format.Footer,
        statistics: SpillBackedSortedArtifactStatistics,
        peakResidentScheduledRunCount: Int
    ) throws -> SpillBackedSortedArtifactLease<Format> {
        let token = UUID()
        let suffix = format.fileExtension.isEmpty ? "artifact" : format.fileExtension
        let finalURL = directoryURL.appendingPathComponent("\(token.uuidString.lowercased()).\(suffix)")
        let identity = try lock.withArtifactLock { () throws -> SpillBackedSortedArtifactDescriptorIdentity in
            guard rename(temporaryURL.path, finalURL.path) == 0 else {
                throw format.error(.io(operation: "artifact-rename", code: errno))
            }
            do {
                try synchronizeDirectory(format: format)
                let descriptor = try Self.openSecureRegularFile(at: finalURL, format: format)
                defer { Darwin.close(descriptor) }
                let identity = try Self.descriptorIdentity(descriptor, format: format)
                guard identity.byteCount == statistics.finalByteCount else {
                    throw format.error(.corrupt("published artifact size mismatch"))
                }
                artifacts[token] = Artifact(url: finalURL, identity: identity, leaseCount: 1)
                activeWorkspaces.remove(workspaceName)
                reservedBytesByWorkspace.removeValue(forKey: workspaceName)
                peakReservedBytesByWorkspace.removeValue(forKey: workspaceName)
                peakAggregateBytesByWorkspace.removeValue(forKey: workspaceName)
                try? FileManager.default.removeItem(
                    at: directoryURL.appendingPathComponent(workspaceName, isDirectory: true)
                )
                return identity
            } catch {
                try? FileManager.default.removeItem(at: finalURL)
                throw error
            }
        }
        return SpillBackedSortedArtifactLease(
            store: self,
            token: token,
            fileURL: finalURL,
            artifactIdentity: identity,
            header: header,
            footer: footer,
            statistics: statistics,
            peakResidentScheduledRunCount: peakResidentScheduledRunCount,
            format: format
        )
    }

    fileprivate func discardWorkspace(name: String) {
        lock.withArtifactLock {
            activeWorkspaces.remove(name)
            reservedBytesByWorkspace.removeValue(forKey: name)
            peakReservedBytesByWorkspace.removeValue(forKey: name)
            peakAggregateBytesByWorkspace.removeValue(forKey: name)
            try? FileManager.default.removeItem(
                at: directoryURL.appendingPathComponent(name, isDirectory: true)
            )
        }
    }

    fileprivate func release(token: UUID) {
        lock.withArtifactLock {
            guard var artifact = artifacts[token] else { return }
            artifact.leaseCount -= 1
            if artifact.leaseCount > 0 {
                artifacts[token] = artifact
                return
            }
            artifacts.removeValue(forKey: token)
            if Self.pathIdentity(at: artifact.url) == artifact.identity {
                try? FileManager.default.removeItem(at: artifact.url)
                try? synchronizeDirectoryWithoutFormat()
            }
        }
    }

    fileprivate func openArtifact(
        at url: URL,
        expectedIdentity: SpillBackedSortedArtifactDescriptorIdentity,
        format: some SpillBackedSortedArtifactFormat
    ) throws -> Int32 {
        let descriptor = try Self.openSecureRegularFile(at: url, format: format)
        do {
            try validateArtifact(
                descriptor: descriptor,
                at: url,
                expectedIdentity: expectedIdentity,
                format: format
            )
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    fileprivate func validateArtifact(
        descriptor: Int32,
        at url: URL,
        expectedIdentity: SpillBackedSortedArtifactDescriptorIdentity,
        format: some SpillBackedSortedArtifactFormat
    ) throws {
        try Self.validateSecureRegularFile(descriptor, format: format)
        let descriptorIdentity = try Self.descriptorIdentity(descriptor, format: format)
        guard descriptorIdentity == expectedIdentity,
              Self.pathIdentity(at: url) == expectedIdentity
        else { throw format.error(.corrupt("artifact identity changed")) }
    }

    fileprivate static func createSecureFile(
        at url: URL,
        format: some SpillBackedSortedArtifactFormat
    ) throws -> Int32 {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw format.error(.io(operation: "file-create", code: errno))
        }
        return descriptor
    }

    fileprivate static func openRun(
        at url: URL,
        format: some SpillBackedSortedArtifactFormat
    ) throws -> Int32 {
        try openSecureRegularFile(at: url, format: format)
    }

    private static func openSecureRegularFile(
        at url: URL,
        format: some SpillBackedSortedArtifactFormat
    ) throws -> Int32 {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw format.error(.io(operation: "file-open", code: errno))
        }
        do {
            try validateSecureRegularFile(descriptor, format: format)
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func ensureSecureDirectory(_ url: URL) throws {
        if mkdir(url.path, 0o700) != 0, errno != EEXIST {
            throw SpillBackedSortedArtifactStoreError.io(operation: "store-mkdir", code: errno)
        }
        var status = stat()
        guard lstat(url.path, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              status.st_uid == getuid(),
              status.st_mode & 0o7777 == 0o700
        else { throw SpillBackedSortedArtifactStoreError.resourceAdmission }
    }

    private static func validateSecureRegularFile(
        _ descriptor: Int32,
        format: some SpillBackedSortedArtifactFormat
    ) throws {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw format.error(.io(operation: "file-fstat", code: errno))
        }
        guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              status.st_uid == getuid(),
              status.st_mode & 0o7777 == 0o600
        else { throw format.error(.resourceAdmission) }
    }

    private static func descriptorIdentity(
        _ descriptor: Int32,
        format: some SpillBackedSortedArtifactFormat
    ) throws -> SpillBackedSortedArtifactDescriptorIdentity {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw format.error(.io(operation: "artifact-fstat", code: errno))
        }
        guard status.st_size >= 0 else {
            throw format.error(.corrupt("negative artifact size"))
        }
        return SpillBackedSortedArtifactDescriptorIdentity(
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino),
            byteCount: UInt64(status.st_size),
            modificationSeconds: Int64(status.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(status.st_mtimespec.tv_nsec),
            statusChangeSeconds: Int64(status.st_ctimespec.tv_sec),
            statusChangeNanoseconds: Int64(status.st_ctimespec.tv_nsec)
        )
    }

    private static func pathIdentity(at url: URL) -> SpillBackedSortedArtifactDescriptorIdentity? {
        var status = stat()
        guard lstat(url.path, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              status.st_uid == getuid(),
              status.st_mode & 0o7777 == 0o600,
              status.st_nlink == 1,
              status.st_size >= 0
        else { return nil }
        return SpillBackedSortedArtifactDescriptorIdentity(
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino),
            byteCount: UInt64(status.st_size),
            modificationSeconds: Int64(status.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(status.st_mtimespec.tv_nsec),
            statusChangeSeconds: Int64(status.st_ctimespec.tv_sec),
            statusChangeNanoseconds: Int64(status.st_ctimespec.tv_nsec)
        )
    }

    private func synchronizeDirectory(format: some SpillBackedSortedArtifactFormat) throws {
        let descriptor = open(directoryURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw format.error(.io(operation: "directory-open", code: errno))
        }
        defer { Darwin.close(descriptor) }
        while fsync(descriptor) != 0 {
            guard errno == EINTR else {
                throw format.error(.io(operation: "directory-fsync", code: errno))
            }
        }
    }

    private func synchronizeDirectoryWithoutFormat() throws {
        let descriptor = open(directoryURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { Darwin.close(descriptor) }
        while fsync(descriptor) != 0 {
            guard errno == EINTR else { throw CocoaError(.fileWriteUnknown) }
        }
    }
}

final class SpillBackedSortedArtifactLease<Format: SpillBackedSortedArtifactFormat>: @unchecked Sendable {
    let fileURL: URL
    let artifactIdentity: SpillBackedSortedArtifactDescriptorIdentity
    let header: Format.Header
    let footer: Format.Footer
    let statistics: SpillBackedSortedArtifactStatistics
    let peakResidentScheduledRunCount: Int

    private let store: SpillBackedSortedArtifactStore
    private let token: UUID
    private let format: Format

    fileprivate init(
        store: SpillBackedSortedArtifactStore,
        token: UUID,
        fileURL: URL,
        artifactIdentity: SpillBackedSortedArtifactDescriptorIdentity,
        header: Format.Header,
        footer: Format.Footer,
        statistics: SpillBackedSortedArtifactStatistics,
        peakResidentScheduledRunCount: Int,
        format: Format
    ) {
        self.store = store
        self.token = token
        self.fileURL = fileURL
        self.artifactIdentity = artifactIdentity
        self.header = header
        self.footer = footer
        self.statistics = statistics
        self.peakResidentScheduledRunCount = peakResidentScheduledRunCount
        self.format = format
    }

    deinit {
        store.release(token: token)
    }

    func openValidatedDescriptor() throws -> Int32 {
        try store.openArtifact(at: fileURL, expectedIdentity: artifactIdentity, format: format)
    }

    func validateOpenDescriptor(_ descriptor: Int32) throws {
        try store.validateArtifact(
            descriptor: descriptor,
            at: fileURL,
            expectedIdentity: artifactIdentity,
            format: format
        )
    }
}

actor SpillBackedSortedArtifactWriter<Format: SpillBackedSortedArtifactFormat> {
    private let store: SpillBackedSortedArtifactStore
    private let format: Format
    private let header: Format.Header
    private let policy: SpillBackedSortedArtifactResourcePolicy
    private let formatBounds: SpillBackedSortedArtifactFormatBounds
    private let workspaceName: String
    private let workspaceURL: URL

    private var bufferedRecords: [Format.Record] = []
    private var bufferedRecordBytes = 0
    private var peakBufferedRecordBytes = 0
    private var initialRunCatalogWriter: SpillRunCatalogWriter<Format>?
    private var nextRunNumber: UInt64 = 0
    private var nextCatalogNumber: UInt64 = 0
    private var initialRunCount = 0
    private var mergePassCount = 0
    private var peakResidentScheduledRunCount = 0
    private var isClosed = false

    fileprivate init(
        store: SpillBackedSortedArtifactStore,
        format: Format,
        header: Format.Header,
        policy: SpillBackedSortedArtifactResourcePolicy,
        formatBounds: SpillBackedSortedArtifactFormatBounds,
        workspaceName: String,
        workspaceURL: URL
    ) {
        self.store = store
        self.format = format
        self.header = header
        self.policy = policy
        self.formatBounds = formatBounds
        self.workspaceName = workspaceName
        self.workspaceURL = workspaceURL
    }

    deinit {
        store.discardWorkspace(name: workspaceName)
    }

    func append(_ record: Format.Record) async throws {
        try await append(contentsOf: [record])
    }

    func append(contentsOf records: [Format.Record]) async throws {
        guard !isClosed else { throw format.error(.closed) }
        do {
            for record in records {
                try Task.checkCancellation()
                let byteCount = try encodedRecord(record).count
                guard byteCount <= policy.maximumBufferedRecordBytes else {
                    throw format.error(.resourceAdmission)
                }
                let proposedBufferedBytes = try SpillBackedSortedArtifactChecked.add(
                    bufferedRecordBytes,
                    byteCount,
                    label: "buffered record byte count",
                    format: format
                )
                if !bufferedRecords.isEmpty,
                   proposedBufferedBytes > policy.maximumBufferedRecordBytes ||
                   bufferedRecords.count >= policy.maximumRecordsPerBatch
                {
                    try flushRun()
                }
                bufferedRecords.append(record)
                bufferedRecordBytes = bufferedRecords.count == 1 ? byteCount : proposedBufferedBytes
                peakBufferedRecordBytes = max(peakBufferedRecordBytes, bufferedRecordBytes)
                if bufferedRecordBytes >= policy.maximumBufferedRecordBytes ||
                    bufferedRecords.count >= policy.maximumRecordsPerBatch
                {
                    try flushRun()
                }
            }
        } catch {
            abort()
            throw error
        }
    }

    func finish() async throws -> SpillBackedSortedArtifactLease<Format> {
        guard !isClosed else { throw format.error(.closed) }
        do {
            try Task.checkCancellation()
            try flushRun()
            var catalog = try finishInitialRunCatalog()
            initialRunCount = try SpillBackedSortedArtifactChecked.int(
                catalog.count,
                label: "initial run count",
                format: format
            )
            try store.admit(policy, format: format)
            let maximumOpenRuns = try SpillBackedSortedArtifactChecked.uint64(
                policy.maximumOpenRuns,
                label: "maximum open runs",
                format: format
            )

            while catalog.count > maximumOpenRuns {
                try Task.checkCancellation()
                catalog = try mergePass(catalog)
                mergePassCount = try SpillBackedSortedArtifactChecked.add(
                    mergePassCount,
                    1,
                    label: "merge pass count",
                    format: format
                )
            }

            let finalRuns = try readRunGroup(from: catalog, maximumCount: policy.maximumOpenRuns)
            peakResidentScheduledRunCount = max(peakResidentScheduledRunCount, finalRuns.count)
            if finalRuns.count > 1 {
                mergePassCount = try SpillBackedSortedArtifactChecked.add(
                    mergePassCount,
                    1,
                    label: "merge pass count",
                    format: format
                )
            }
            let result = try writeFinalArtifact(from: finalRuns)
            remove(finalRuns)
            try? FileManager.default.removeItem(at: catalog.url)
            let highWaterMarks = store.resourceHighWaterMarks(workspaceName: workspaceName)
            let statistics = SpillBackedSortedArtifactStatistics(
                initialRunCount: initialRunCount,
                mergePassCount: mergePassCount,
                peakBufferedRecordBytes: peakBufferedRecordBytes,
                recordCount: result.recordCount,
                finalByteCount: result.byteCount,
                peakWorkspaceByteCount: highWaterMarks.workspaceBytes,
                peakAggregateArtifactByteCount: highWaterMarks.aggregateBytes
            )
            let lease = try store.publish(
                temporaryURL: result.url,
                workspaceName: workspaceName,
                format: format,
                header: header,
                footer: result.footer,
                statistics: statistics,
                peakResidentScheduledRunCount: peakResidentScheduledRunCount
            )
            isClosed = true
            return lease
        } catch {
            abort()
            throw error
        }
    }

    func cancel() {
        abort()
    }

    func makeIsolatedWriter() throws -> SpillBackedSortedArtifactWriter<Format> {
        guard !isClosed else { throw format.error(.closed) }
        return try store.makeWriter(
            format: format,
            header: header,
            resourcePolicy: policy
        )
    }

    private func flushRun() throws {
        guard !bufferedRecords.isEmpty else { return }
        try store.admit(policy, format: format)
        bufferedRecords.sort { format.ordering($0, $1) == .ascending }
        // Apply the format's same-key policy before run publication so
        // duplicate behavior is invariant across batch boundaries.
        var uniqueRecords: [Format.Record] = []
        uniqueRecords.reserveCapacity(bufferedRecords.count)
        for record in bufferedRecords {
            if let existing = uniqueRecords.last,
               format.ordering(existing, record) == .same
            {
                switch try format.duplicateResolution(existing, record) {
                case .reject:
                    throw format.error(.duplicateRecord)
                case .coalesce:
                    continue
                }
            }
            uniqueRecords.append(record)
        }
        bufferedRecords = uniqueRecords
        var reservedRunBytes = UInt64(4 + 8 + SHA256.byteCount)
        for record in bufferedRecords {
            let payloadCount = try encodedRecord(record).count
            let frameCount = try SpillBackedSortedArtifactChecked.add(
                payloadCount,
                4,
                label: "reserved run frame byte count",
                format: format
            )
            reservedRunBytes = try SpillBackedSortedArtifactChecked.add(
                reservedRunBytes,
                SpillBackedSortedArtifactChecked.uint64(
                    frameCount,
                    label: "reserved run frame byte count",
                    format: format
                ),
                label: "reserved run byte count",
                format: format
            )
        }
        try store.reserve(
            reservedRunBytes,
            workspaceName: workspaceName,
            policy: policy,
            format: format
        )
        let run = try makeRunReference()
        let descriptor = try SpillBackedSortedArtifactStore.createSecureFile(at: run.url, format: format)
        var descriptorIsOpen = true
        var digest = SHA256()
        var recordCount: UInt64 = 0
        var runByteCount: UInt64 = 0
        do {
            for record in bufferedRecords {
                let payload = try encodedRecord(record)
                let frameByteCount = try SpillBackedSortedArtifactChecked.add(
                    4,
                    payload.count,
                    label: "run record frame byte count",
                    format: format
                )
                runByteCount = try SpillBackedSortedArtifactChecked.add(
                    runByteCount,
                    SpillBackedSortedArtifactChecked.uint64(
                        frameByteCount,
                        label: "run record frame byte count",
                        format: format
                    ),
                    label: "run byte count",
                    format: format
                )
                var length = Data()
                try SpillBackedSortedArtifactIO.append(
                    SpillBackedSortedArtifactChecked.uint32Length(
                        payload.count,
                        label: "run record",
                        format: format
                    ),
                    to: &length
                )
                try SpillBackedSortedArtifactIO.writeAll(length, to: descriptor, format: format)
                try SpillBackedSortedArtifactIO.writeAll(payload, to: descriptor, format: format)
                digest.update(data: length)
                digest.update(data: payload)
                recordCount = try SpillBackedSortedArtifactChecked.add(
                    recordCount,
                    1,
                    label: "run record count",
                    format: format
                )
            }
            runByteCount = try SpillBackedSortedArtifactChecked.add(
                runByteCount,
                UInt64(4 + 8 + SHA256.byteCount),
                label: "run byte count",
                format: format
            )
            try writeRunFooter(recordCount: recordCount, digest: Data(digest.finalize()), to: descriptor)
            try validateFileSize(descriptor, expected: runByteCount, operation: "run-fstat")
            try synchronize(descriptor)
            let closeResult = Darwin.close(descriptor)
            descriptorIsOpen = false
            guard closeResult == 0 else {
                throw format.error(.io(operation: "file-close", code: errno))
            }
        } catch {
            if descriptorIsOpen { Darwin.close(descriptor) }
            try? FileManager.default.removeItem(at: run.url)
            throw error
        }
        do {
            try store.reserve(8, workspaceName: workspaceName, policy: policy, format: format)
            try initialCatalogWriter().append(run.id)
        } catch {
            try? FileManager.default.removeItem(at: run.url)
            throw error
        }
        bufferedRecords.removeAll(keepingCapacity: true)
        bufferedRecordBytes = 0
    }

    private func mergeRunsToRun(_ input: [URL]) throws -> SpillRunReference {
        try store.admit(policy, format: format)
        let maximumOutputBytes = try input.reduce(UInt64(0)) { partial, url in
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard let fileSize = values.fileSize, fileSize >= 0 else {
                throw format.error(.io(operation: "merged-run-size", code: EIO))
            }
            return try SpillBackedSortedArtifactChecked.add(
                partial,
                UInt64(fileSize),
                label: "reserved merged run byte count",
                format: format
            )
        }
        try store.reserve(
            maximumOutputBytes,
            workspaceName: workspaceName,
            policy: policy,
            format: format
        )
        let output = try makeRunReference()
        let descriptor = try SpillBackedSortedArtifactStore.createSecureFile(at: output.url, format: format)
        var descriptorIsOpen = true
        var digest = SHA256()
        var recordCount: UInt64 = 0
        var runByteCount: UInt64 = 0
        do {
            try merge(input) { record in
                try Task.checkCancellation()
                let payload = try encodedRecord(record)
                let frameByteCount = try SpillBackedSortedArtifactChecked.add(
                    4,
                    payload.count,
                    label: "merged run record frame byte count",
                    format: format
                )
                runByteCount = try SpillBackedSortedArtifactChecked.add(
                    runByteCount,
                    SpillBackedSortedArtifactChecked.uint64(
                        frameByteCount,
                        label: "merged run record frame byte count",
                        format: format
                    ),
                    label: "merged run byte count",
                    format: format
                )
                var length = Data()
                try SpillBackedSortedArtifactIO.append(
                    SpillBackedSortedArtifactChecked.uint32Length(
                        payload.count,
                        label: "merged run record",
                        format: format
                    ),
                    to: &length
                )
                try SpillBackedSortedArtifactIO.writeAll(length, to: descriptor, format: format)
                try SpillBackedSortedArtifactIO.writeAll(payload, to: descriptor, format: format)
                digest.update(data: length)
                digest.update(data: payload)
                recordCount = try SpillBackedSortedArtifactChecked.add(
                    recordCount,
                    1,
                    label: "merged run record count",
                    format: format
                )
            }
            runByteCount = try SpillBackedSortedArtifactChecked.add(
                runByteCount,
                UInt64(4 + 8 + SHA256.byteCount),
                label: "merged run byte count",
                format: format
            )
            try writeRunFooter(recordCount: recordCount, digest: Data(digest.finalize()), to: descriptor)
            try validateFileSize(descriptor, expected: runByteCount, operation: "merged-run-fstat")
            try synchronize(descriptor)
            let closeResult = Darwin.close(descriptor)
            descriptorIsOpen = false
            guard closeResult == 0 else {
                throw format.error(.io(operation: "file-close", code: errno))
            }
            return output
        } catch {
            if descriptorIsOpen { Darwin.close(descriptor) }
            try? FileManager.default.removeItem(at: output.url)
            throw error
        }
    }

    private func writeFinalArtifact(from input: [URL]) throws -> (
        url: URL,
        footer: Format.Footer,
        recordCount: UInt64,
        byteCount: UInt64
    ) {
        let inputBytes = try input.reduce(UInt64(0)) { partial, inputURL in
            let values = try inputURL.resourceValues(forKeys: [.fileSizeKey])
            guard let fileSize = values.fileSize, fileSize >= 0 else {
                throw format.error(.io(operation: "final-input-size", code: EIO))
            }
            return try SpillBackedSortedArtifactChecked.add(
                partial,
                UInt64(fileSize),
                label: "reserved final input byte count",
                format: format
            )
        }
        let doubledInput = try SpillBackedSortedArtifactChecked.add(
            inputBytes,
            inputBytes,
            label: "reserved final artifact byte count",
            format: format
        )
        let framingAllowance = UInt64(formatBounds.header + formatBounds.footer)
        let maximumOutputBytes = try SpillBackedSortedArtifactChecked.add(
            doubledInput,
            framingAllowance,
            label: "reserved final artifact byte count",
            format: format
        )
        try store.reserve(
            maximumOutputBytes,
            workspaceName: workspaceName,
            policy: policy,
            format: format
        )
        let url = workspaceURL.appendingPathComponent("artifact.incomplete")
        let descriptor = try SpillBackedSortedArtifactStore.createSecureFile(at: url, format: format)
        var descriptorIsOpen = true
        var digest = SHA256()
        var accumulator = format.makeFinalAccumulator()
        var recordCount: UInt64 = 0
        do {
            let headerFrame = try format.encodeFinalHeader(header)
            try SpillBackedSortedArtifactChecked.validate(
                byteCount: headerFrame.count,
                maximum: formatBounds.header,
                label: "encoded header",
                format: format
            )
            try SpillBackedSortedArtifactIO.writeAll(headerFrame, to: descriptor, format: format)
            digest.update(data: headerFrame)
            try merge(input) { record in
                try Task.checkCancellation()
                let payload = try encodedRecord(record)
                let frame = try format.encodeFinalRecord(record, encodedRecord: payload)
                try SpillBackedSortedArtifactChecked.validate(
                    byteCount: frame.count,
                    maximum: formatBounds.finalRecord,
                    label: "encoded final record",
                    format: format
                )
                try SpillBackedSortedArtifactIO.writeAll(frame, to: descriptor, format: format)
                digest.update(data: frame)
                try format.accumulateFinalRecord(
                    record,
                    encodedRecordByteCount: payload.count,
                    into: &accumulator
                )
                recordCount = try SpillBackedSortedArtifactChecked.add(
                    recordCount,
                    1,
                    label: "final record count",
                    format: format
                )
            }
            let footer = try format.makeFinalFooter(
                accumulator: accumulator,
                digest: Data(digest.finalize())
            )
            let footerFrame = try format.encodeFinalFooter(footer)
            try SpillBackedSortedArtifactChecked.validate(
                byteCount: footerFrame.count,
                maximum: formatBounds.footer,
                label: "encoded footer",
                format: format
            )
            try SpillBackedSortedArtifactIO.writeAll(
                footerFrame,
                to: descriptor,
                format: format
            )
            try synchronize(descriptor)
            var status = stat()
            guard fstat(descriptor, &status) == 0, status.st_size >= 0 else {
                throw format.error(.io(operation: "artifact-fstat", code: errno))
            }
            let byteCount = UInt64(status.st_size)
            let closeResult = Darwin.close(descriptor)
            descriptorIsOpen = false
            guard closeResult == 0 else {
                throw format.error(.io(operation: "file-close", code: errno))
            }
            return (url, footer, recordCount, byteCount)
        } catch {
            if descriptorIsOpen { Darwin.close(descriptor) }
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private func merge(_ urls: [URL], consume: (Format.Record) throws -> Void) throws {
        let cursors = try urls.map {
            try SpillRunCursor(
                url: $0,
                maximumRecordByteCount: policy.maximumRecordByteCount,
                format: format
            )
        }
        var previous: Format.Record?
        while true {
            try Task.checkCancellation()
            var selected: Int?
            for index in cursors.indices where cursors[index].record != nil {
                guard let current = cursors[index].record else { continue }
                if let selectedIndex = selected,
                   let selectedRecord = cursors[selectedIndex].record,
                   format.ordering(current, selectedRecord) != .ascending
                {
                    continue
                }
                selected = index
            }
            guard let selected, let record = cursors[selected].record else { return }
            if let previous {
                switch format.ordering(previous, record) {
                case .same:
                    // This must mirror flushRun: run partitioning cannot change
                    // whether equal-key records are rejected or coalesced.
                    switch try format.duplicateResolution(previous, record) {
                    case .reject:
                        throw format.error(.duplicateRecord)
                    case .coalesce:
                        try cursors[selected].advance()
                        continue
                    }
                case .descending: throw format.error(.outOfOrder)
                case .ascending: break
                }
            }
            try consume(record)
            previous = record
            try cursors[selected].advance()
        }
    }

    private func makeRunReference() throws -> SpillRunReference {
        guard nextRunNumber != UInt64.max else {
            throw format.error(.corrupt("run identifier overflow"))
        }
        defer {
            nextRunNumber += 1
        }
        return SpillRunReference(
            id: nextRunNumber,
            url: workspaceURL.appendingPathComponent("run.\(nextRunNumber)")
        )
    }

    private func runReference(id: UInt64) -> SpillRunReference {
        SpillRunReference(id: id, url: workspaceURL.appendingPathComponent("run.\(id)"))
    }

    private func makeCatalogWriter() throws -> SpillRunCatalogWriter<Format> {
        guard nextCatalogNumber != UInt64.max else {
            throw format.error(.corrupt("catalog identifier overflow"))
        }
        defer {
            nextCatalogNumber += 1
        }
        let stem = "catalog.\(nextCatalogNumber)"
        return try SpillRunCatalogWriter(
            incompleteURL: workspaceURL.appendingPathComponent("\(stem).incomplete"),
            finalURL: workspaceURL.appendingPathComponent(stem),
            format: format
        )
    }

    private func initialCatalogWriter() throws -> SpillRunCatalogWriter<Format> {
        if let initialRunCatalogWriter { return initialRunCatalogWriter }
        let writer = try makeCatalogWriter()
        initialRunCatalogWriter = writer
        return writer
    }

    private func finishInitialRunCatalog() throws -> SpillRunCatalog {
        let writer = try initialCatalogWriter()
        try store.reserve(64, workspaceName: workspaceName, policy: policy, format: format)
        let catalog = try writer.finish()
        initialRunCatalogWriter = nil
        return catalog
    }

    private func mergePass(_ inputCatalog: SpillRunCatalog) throws -> SpillRunCatalog {
        let outputWriter = try makeCatalogWriter()
        do {
            let cursor = try SpillRunCatalogCursor(url: inputCatalog.url, format: format)
            while true {
                try Task.checkCancellation()
                var group: [URL] = []
                group.reserveCapacity(policy.maximumOpenRuns)
                while group.count < policy.maximumOpenRuns, let id = try cursor.next() {
                    group.append(runReference(id: id).url)
                }
                guard !group.isEmpty else { break }
                peakResidentScheduledRunCount = max(peakResidentScheduledRunCount, group.count)
                let output = try mergeRunsToRun(group)
                try store.reserve(8, workspaceName: workspaceName, policy: policy, format: format)
                try outputWriter.append(output.id)
                remove(group)
            }
            guard cursor.recordCount == inputCatalog.count else {
                throw format.error(.corrupt("catalog count mismatch"))
            }
            try store.reserve(64, workspaceName: workspaceName, policy: policy, format: format)
            let outputCatalog = try outputWriter.finish()
            try? FileManager.default.removeItem(at: inputCatalog.url)
            return outputCatalog
        } catch {
            outputWriter.cancel()
            throw error
        }
    }

    private func readRunGroup(from catalog: SpillRunCatalog, maximumCount: Int) throws -> [URL] {
        let cursor = try SpillRunCatalogCursor(url: catalog.url, format: format)
        var result: [URL] = []
        let catalogCount = try SpillBackedSortedArtifactChecked.int(
            catalog.count,
            label: "run catalog count",
            format: format
        )
        result.reserveCapacity(min(maximumCount, catalogCount))
        while let id = try cursor.next() {
            guard result.count < maximumCount else {
                throw format.error(.corrupt("catalog exceeds merge fan-in"))
            }
            result.append(runReference(id: id).url)
        }
        guard try SpillBackedSortedArtifactChecked.uint64(
            result.count,
            label: "resident run count",
            format: format
        ) == catalog.count else {
            throw format.error(.corrupt("catalog count mismatch"))
        }
        return result
    }

    private func remove(_ urls: [URL]) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func writeRunFooter(recordCount: UInt64, digest: Data, to descriptor: Int32) throws {
        var footer = Data()
        SpillBackedSortedArtifactIO.append(UInt32.max, to: &footer)
        SpillBackedSortedArtifactIO.append(recordCount, to: &footer)
        footer.append(digest)
        try SpillBackedSortedArtifactIO.writeAll(footer, to: descriptor, format: format)
    }

    private func synchronize(_ descriptor: Int32) throws {
        while fsync(descriptor) != 0 {
            guard errno == EINTR else {
                throw format.error(.io(operation: "file-fsync", code: errno))
            }
        }
    }

    private func validateFileSize(
        _ descriptor: Int32,
        expected: UInt64,
        operation: String
    ) throws {
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_size >= 0 else {
            throw format.error(.io(operation: operation, code: errno))
        }
        guard UInt64(status.st_size) == expected else {
            throw format.error(.corrupt("spill file size mismatch"))
        }
    }

    private func encodedRecord(_ record: Format.Record) throws -> Data {
        try format.validate(record, maximumRecordByteCount: policy.maximumRecordByteCount)
        let payload = try format.encodeRecord(record)
        try SpillBackedSortedArtifactChecked.validate(
            byteCount: payload.count,
            maximum: formatBounds.record,
            label: "encoded record",
            format: format
        )
        _ = try SpillBackedSortedArtifactChecked.uint32Length(
            payload.count,
            label: "encoded record",
            format: format
        )
        guard payload.count <= policy.maximumBufferedRecordBytes else {
            throw format.error(.resourceAdmission)
        }
        return payload
    }

    private func abort() {
        guard !isClosed else { return }
        isClosed = true
        bufferedRecords.removeAll()
        bufferedRecordBytes = 0
        initialRunCatalogWriter?.cancel()
        initialRunCatalogWriter = nil
        store.discardWorkspace(name: workspaceName)
    }
}

private struct SpillRunReference {
    let id: UInt64
    let url: URL
}

private struct SpillRunCatalog {
    let url: URL
    let count: UInt64
}

private final class SpillRunCatalogWriter<Format: SpillBackedSortedArtifactFormat> {
    private static var magic: Data {
        Data("RPRUNCAT".utf8)
    }

    private let incompleteURL: URL
    private let finalURL: URL
    private let format: Format
    private var descriptor: Int32
    private var digest = SHA256()
    private var count: UInt64 = 0
    private var byteCount: UInt64 = 8
    private var isClosed = false

    init(incompleteURL: URL, finalURL: URL, format: Format) throws {
        self.incompleteURL = incompleteURL
        self.finalURL = finalURL
        self.format = format
        descriptor = try SpillBackedSortedArtifactStore.createSecureFile(at: incompleteURL, format: format)
        do {
            try SpillBackedSortedArtifactIO.writeAll(Self.magic, to: descriptor, format: format)
        } catch {
            Darwin.close(descriptor)
            try? FileManager.default.removeItem(at: incompleteURL)
            throw error
        }
    }

    deinit { cancel() }

    func append(_ runID: UInt64) throws {
        guard !isClosed, runID != UInt64.max, count != UInt64.max else {
            throw format.error(.corrupt("invalid run catalog record"))
        }
        var frame = Data()
        SpillBackedSortedArtifactIO.append(runID, to: &frame)
        byteCount = try SpillBackedSortedArtifactChecked.add(
            byteCount,
            8,
            label: "run catalog byte count",
            format: format
        )
        try SpillBackedSortedArtifactIO.writeAll(frame, to: descriptor, format: format)
        digest.update(data: frame)
        count = try SpillBackedSortedArtifactChecked.add(
            count,
            1,
            label: "run catalog record count",
            format: format
        )
    }

    func finish() throws -> SpillRunCatalog {
        guard !isClosed else { throw format.error(.closed) }
        do {
            byteCount = try SpillBackedSortedArtifactChecked.add(
                byteCount,
                UInt64(8 + 8 + SHA256.byteCount),
                label: "run catalog byte count",
                format: format
            )
            var footer = Data()
            SpillBackedSortedArtifactIO.append(UInt64.max, to: &footer)
            SpillBackedSortedArtifactIO.append(count, to: &footer)
            footer.append(Data(digest.finalize()))
            try SpillBackedSortedArtifactIO.writeAll(footer, to: descriptor, format: format)
            var status = stat()
            guard fstat(descriptor, &status) == 0, status.st_size >= 0 else {
                throw format.error(.io(operation: "catalog-fstat", code: errno))
            }
            guard UInt64(status.st_size) == byteCount else {
                throw format.error(.corrupt("run catalog size mismatch"))
            }
            try synchronizeFile(descriptor)
            let closeResult = Darwin.close(descriptor)
            descriptor = -1
            guard closeResult == 0 else {
                throw format.error(.io(operation: "catalog-close", code: errno))
            }
            guard rename(incompleteURL.path, finalURL.path) == 0 else {
                throw format.error(.io(operation: "catalog-rename", code: errno))
            }
            try synchronizeDirectory(finalURL.deletingLastPathComponent())
            isClosed = true
            return SpillRunCatalog(url: finalURL, count: count)
        } catch {
            cancel()
            throw error
        }
    }

    func cancel() {
        guard !isClosed else { return }
        isClosed = true
        if descriptor >= 0 {
            Darwin.close(descriptor)
            descriptor = -1
        }
        try? FileManager.default.removeItem(at: incompleteURL)
        try? FileManager.default.removeItem(at: finalURL)
    }

    private func synchronizeFile(_ descriptor: Int32) throws {
        while fsync(descriptor) != 0 {
            guard errno == EINTR else {
                throw format.error(.io(operation: "catalog-fsync", code: errno))
            }
        }
    }

    private func synchronizeDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw format.error(.io(operation: "catalog-directory-open", code: errno))
        }
        defer { Darwin.close(descriptor) }
        while fsync(descriptor) != 0 {
            guard errno == EINTR else {
                throw format.error(.io(operation: "catalog-directory-fsync", code: errno))
            }
        }
    }
}

private final class SpillRunCatalogCursor<Format: SpillBackedSortedArtifactFormat> {
    private static var magic: Data {
        Data("RPRUNCAT".utf8)
    }

    private let descriptor: Int32
    private let format: Format
    private var digest = SHA256()
    private var previousRunID: UInt64?
    private var reachedFooter = false
    private(set) var recordCount: UInt64 = 0

    init(url: URL, format: Format) throws {
        self.format = format
        descriptor = try SpillBackedSortedArtifactStore.openRun(at: url, format: format)
        do {
            let magic = try SpillBackedSortedArtifactIO.readExact(
                descriptor,
                count: Self.magic.count,
                format: format
            )
            guard magic == Self.magic else {
                throw format.error(.corrupt("invalid run catalog header"))
            }
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    deinit { Darwin.close(descriptor) }

    func next() throws -> UInt64? {
        if reachedFooter { return nil }
        let frame = try SpillBackedSortedArtifactIO.readExact(descriptor, count: 8, format: format)
        let value = try SpillBackedSortedArtifactIO.decodeUInt64(frame, format: format)
        if value == UInt64.max {
            let footer = try SpillBackedSortedArtifactIO.readExact(
                descriptor,
                count: 8 + SHA256.byteCount,
                format: format
            )
            let expectedCount = try SpillBackedSortedArtifactIO.decodeUInt64(
                Data(footer.prefix(8)),
                format: format
            )
            let expectedDigest = Data(footer.dropFirst(8))
            guard expectedCount == recordCount,
                  expectedDigest == Data(digest.finalize())
            else { throw format.error(.corrupt("run catalog footer mismatch")) }
            try SpillBackedSortedArtifactIO.requireEndOfFile(
                descriptor,
                operation: "catalog-trailing-read",
                trailingMessage: "run catalog trailing bytes",
                format: format
            )
            reachedFooter = true
            return nil
        }
        if let previousRunID, value <= previousRunID {
            throw format.error(.corrupt("unordered run catalog"))
        }
        previousRunID = value
        digest.update(data: frame)
        recordCount = try SpillBackedSortedArtifactChecked.add(
            recordCount,
            1,
            label: "run catalog cursor record count",
            format: format
        )
        return value
    }
}

private final class SpillRunCursor<Format: SpillBackedSortedArtifactFormat> {
    private let descriptor: Int32
    private let maximumRecordByteCount: Int
    private let maximumEncodedRecordByteCount: Int
    private let format: Format
    private(set) var record: Format.Record?
    private var digest = SHA256()
    private var recordCount: UInt64 = 0
    private var reachedFooter = false

    init(url: URL, maximumRecordByteCount: Int, format: Format) throws {
        descriptor = try SpillBackedSortedArtifactStore.openRun(at: url, format: format)
        self.maximumRecordByteCount = maximumRecordByteCount
        self.format = format
        do {
            maximumEncodedRecordByteCount = try SpillBackedSortedArtifactChecked.formatBounds(
                format: format,
                maximumRecordByteCount: maximumRecordByteCount
            ).record
            try advance()
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    deinit { Darwin.close(descriptor) }

    func advance() throws {
        guard !reachedFooter else {
            throw format.error(.corrupt("run read after footer"))
        }
        var first: UInt8 = 0
        let readCount = Darwin.read(descriptor, &first, 1)
        if readCount == 0 { throw format.error(.corrupt("run missing footer")) }
        if readCount < 0 {
            if errno == EINTR { return try advance() }
            throw format.error(.io(operation: "run-read", code: errno))
        }
        var lengthBytes = Data([first])
        try lengthBytes.append(SpillBackedSortedArtifactIO.readExact(
            descriptor,
            count: 3,
            format: format
        ))
        let length = try SpillBackedSortedArtifactIO.decodeUInt32(lengthBytes, format: format)
        if length == UInt32.max {
            let footer = try SpillBackedSortedArtifactIO.readExact(
                descriptor,
                count: 8 + SHA256.byteCount,
                format: format
            )
            let expectedCount = try SpillBackedSortedArtifactIO.decodeUInt64(
                Data(footer.prefix(8)),
                format: format
            )
            let expectedDigest = Data(footer.dropFirst(8))
            guard expectedCount == recordCount,
                  expectedDigest == Data(digest.finalize())
            else { throw format.error(.corrupt("run footer mismatch")) }
            try SpillBackedSortedArtifactIO.requireEndOfFile(
                descriptor,
                operation: "run-trailing-read",
                trailingMessage: "run trailing bytes",
                format: format
            )
            reachedFooter = true
            record = nil
            return
        }
        guard length > 0,
              let payloadLength = Int(exactly: length),
              payloadLength <= maximumEncodedRecordByteCount
        else {
            throw format.error(.corrupt("invalid run record length"))
        }
        let payload = try SpillBackedSortedArtifactIO.readExact(
            descriptor,
            count: payloadLength,
            format: format
        )
        let decoded = try format.decodeRecord(payload)
        try format.validate(decoded, maximumRecordByteCount: maximumRecordByteCount)
        digest.update(data: lengthBytes)
        digest.update(data: payload)
        recordCount = try SpillBackedSortedArtifactChecked.add(
            recordCount,
            1,
            label: "run cursor record count",
            format: format
        )
        record = decoded
    }
}

private enum SpillBackedSortedArtifactIO {
    static func readExact(
        _ descriptor: Int32,
        count: Int,
        format: some SpillBackedSortedArtifactFormat
    ) throws -> Data {
        guard count >= 0 else { throw format.error(.corrupt("negative read")) }
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
                throw format.error(.corrupt("truncated file"))
            } else if errno != EINTR {
                throw format.error(.io(operation: "read", code: errno))
            }
        }
        return data
    }

    static func writeAll(
        _ data: Data,
        to descriptor: Int32,
        format: some SpillBackedSortedArtifactFormat
    ) throws {
        var offset = 0
        while offset < data.count {
            let amount = data.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                return Darwin.write(descriptor, base.advanced(by: offset), data.count - offset)
            }
            if amount > 0 {
                offset += amount
            } else if amount == 0 {
                throw format.error(.io(operation: "write", code: EIO))
            } else if errno != EINTR {
                throw format.error(.io(operation: "write", code: errno))
            }
        }
    }

    static func requireEndOfFile(
        _ descriptor: Int32,
        operation: String,
        trailingMessage: String,
        format: some SpillBackedSortedArtifactFormat
    ) throws {
        var byte: UInt8 = 0
        while true {
            let count = Darwin.read(descriptor, &byte, 1)
            if count == 0 { return }
            if count > 0 { throw format.error(.corrupt(trailingMessage)) }
            guard errno == EINTR else {
                throw format.error(.io(operation: operation, code: errno))
            }
        }
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

    static func decodeUInt32(
        _ data: Data,
        format: some SpillBackedSortedArtifactFormat
    ) throws -> UInt32 {
        guard data.count == 4 else { throw format.error(.corrupt("invalid integer")) }
        return data.enumerated().reduce(into: UInt32(0)) { value, pair in
            value |= UInt32(pair.element) << UInt32(pair.offset * 8)
        }
    }

    static func decodeUInt64(
        _ data: Data,
        format: some SpillBackedSortedArtifactFormat
    ) throws -> UInt64 {
        guard data.count == 8 else { throw format.error(.corrupt("invalid integer")) }
        return data.enumerated().reduce(into: UInt64(0)) { value, pair in
            value |= UInt64(pair.element) << UInt64(pair.offset * 8)
        }
    }
}

private extension NSLock {
    func withArtifactLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

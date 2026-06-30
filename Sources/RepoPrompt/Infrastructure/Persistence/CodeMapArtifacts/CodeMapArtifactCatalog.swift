import CryptoKit
import Darwin
import Foundation

enum CodeMapArtifactCatalogError: Error, Equatable {
    case invalidLayout
    case insecureEntry
    case boundedScanExceeded
    case invalidMetadata
    case ioFailure(operation: String, code: Int32)
}

enum CodeMapArtifactCatalogOutcomeClass: UInt8, Equatable {
    case positive = 1
    case negative = 2

    init(outcome: CodeMapSyntaxArtifactOutcome) {
        self = if case .ready = outcome { .positive } else { .negative }
    }
}

enum CodeMapArtifactCatalogState: UInt8, Equatable {
    case live = 1
    case quarantined = 2
}

enum CodeMapArtifactQuarantineReason: UInt8, Equatable, Hashable {
    case quota = 1
    case age = 2
    case corruptPayload = 3
    case corruptMetadata = 4
    case missingPayload = 5
    case orphanArtifact = 6
    case recoveredArtifactOnly = 7
    case recoveredMetadataOnly = 8
}

struct CodeMapArtifactQuarantineTombstone: Equatable {
    let epochSeconds: UInt64
    let digest: String
    let token: String
    let reason: CodeMapArtifactQuarantineReason
    let key: CodeMapArtifactKey?
    let containerByteCount: UInt64
    let payloadByteCount: UInt64
    let outcomeClass: CodeMapArtifactCatalogOutcomeClass?
    let hasArtifact: Bool

    var shard: String {
        String(digest.prefix(2))
    }

    var metadataName: String {
        "\(digest).tomb.\(token)"
    }

    var artifactName: String? {
        hasArtifact ? "\(digest).\(token)" : nil
    }
}

enum CodeMapArtifactCatalogLiveRecordResult: Equatable {
    case missing
    case corrupt
    case record(CodeMapArtifactCatalogRecord)
}

enum CodeMapArtifactCatalogScanNamespace: Equatable {
    case liveCatalog
    case liveArtifacts
    case quarantineCatalog
    case quarantineArtifacts
}

struct CodeMapArtifactCatalogScanHooks {
    let afterMetadataAdmission: (@Sendable (Int32, String, UInt64) throws -> Void)?

    init(afterMetadataAdmission: (@Sendable (Int32, String, UInt64) throws -> Void)? = nil) {
        self.afterMetadataAdmission = afterMetadataAdmission
    }
}

enum CodeMapArtifactCatalogScanVisit: Equatable {
    case boundary
    case junk
    case temporary(removed: Bool)
    case privateDeletion(removed: Bool, storedByteCount: UInt64?)
    case liveRecord(CodeMapArtifactCatalogRecord, metadataByteCount: UInt64)
    case corruptLiveMetadata(
        shard: String,
        name: String,
        metadataByteCount: UInt64,
        writtenByteCount: UInt64
    )
    case liveArtifact(
        CodeMapArtifactOrphanCandidate,
        containerByteCount: UInt64,
        verificationReadByteCount: UInt64
    )
    case quarantineTombstone(
        CodeMapArtifactQuarantineCandidate,
        metadataByteCount: UInt64,
        readByteCount: UInt64,
        writtenByteCount: UInt64
    )
    case corruptQuarantineMetadata(epochSeconds: UInt64, shard: String, name: String, metadataByteCount: UInt64)
    case quarantineArtifact(epochSeconds: UInt64, shard: String, name: String, storedByteCount: UInt64)

    var readByteCount: UInt64 {
        switch self {
        case let .liveRecord(_, count), let .corruptLiveMetadata(_, _, count, _),
             let .quarantineTombstone(_, _, count, _), let .corruptQuarantineMetadata(_, _, _, count):
            count
        case let .liveArtifact(_, _, count):
            count
        case .quarantineArtifact:
            0
        case .boundary, .junk, .temporary, .privateDeletion:
            0
        }
    }
}

enum CodeMapArtifactCatalogScanStep: Equatable {
    case visit(CodeMapArtifactCatalogScanVisit, chargeEntry: Bool)
    case needsMoreBytes(UInt64, chargeEntry: Bool)
    case complete
}

enum CodeMapArtifactQuarantineRecoveryResult: Equatable {
    case written(metadataByteCount: Int, writtenByteCount: Int, readByteCount: Int)
    case existing(metadataByteCount: Int)
    case leased
    case missingOrChanged
}

/// Actor-confined, descriptor-backed traversal state. Each call advances at
/// most one non-dot directory entry. Directory streams remain open across
/// calls, so a continuation never re-enumerates or sorts a prior prefix.
final class CodeMapArtifactCatalogScanSession {
    fileprivate final class Level {
        let directory: CatalogDirectory
        let components: [String]
        let stream: UnsafeMutablePointer<DIR>
        let parent: CatalogDirectory?
        let componentName: String?

        init(
            directory: CatalogDirectory,
            components: [String],
            ownsDescriptor _: Bool,
            parent: CatalogDirectory? = nil,
            componentName: String? = nil
        ) throws {
            self.components = components
            self.directory = directory
            self.parent = parent
            self.componentName = componentName
            let scanDescriptor = openat(
                directory.rawValue,
                ".",
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard scanDescriptor >= 0 else {
                throw CodeMapArtifactCatalogError.ioFailure(operation: "scan-root-reopen", code: errno)
            }
            guard let stream = fdopendir(scanDescriptor) else {
                Darwin.close(scanDescriptor)
                throw CodeMapArtifactCatalogError.ioFailure(operation: "scan-directory-stream", code: errno)
            }
            self.stream = stream
        }

        deinit {
            closedir(stream)
        }
    }

    fileprivate struct Pending {
        let parent: CatalogDirectory
        let components: [String]
        let name: String
        let charged: Bool
    }

    fileprivate let namespace: CodeMapArtifactCatalogScanNamespace
    fileprivate var levels: [Level]
    fileprivate var pending: Pending?
    fileprivate var visitedEntryCount = 0
    fileprivate var visitedEpochCount = 0
    fileprivate var completed = false

    fileprivate init(namespace: CodeMapArtifactCatalogScanNamespace, root: CatalogDirectory) throws {
        self.namespace = namespace
        levels = try [Level(directory: root, components: [], ownsDescriptor: false)]
    }
}

struct CodeMapArtifactCatalogRecord: Equatable {
    let key: CodeMapArtifactKey
    let containerByteCount: UInt64
    let payloadByteCount: UInt64
    let outcomeClass: CodeMapArtifactCatalogOutcomeClass
    let creationEpochSeconds: UInt64
    var lastAccessEpochSeconds: UInt64
    var lastAccessSequence: UInt64
    var state: CodeMapArtifactCatalogState

    var digest: String {
        key.storageDigestHex
    }
}

struct CodeMapArtifactCatalogScanDiagnostics: Equatable {
    var corruptMetadataCount = 0
    var ignoredTemporaryCount = 0
    var removedTemporaryCount = 0
    var retainedPrivateDeletionCount = 0
    var retainedPrivateDeletionBytes: UInt64 = 0
    var recoveredPrivateDeletionCount = 0
    var recoveredPrivateDeletionBytes: UInt64 = 0
    var orphanArtifactCount = 0
    var quarantineRecordCount = 0
    var quarantineContainerBytes: UInt64 = 0
    var quarantineOrphanCount = 0
}

struct CodeMapArtifactQuarantineCandidate: Equatable {
    let tombstone: CodeMapArtifactQuarantineTombstone

    var epochSeconds: UInt64 {
        tombstone.epochSeconds
    }

    var shard: String {
        tombstone.shard
    }

    var metadataName: String {
        tombstone.metadataName
    }

    var artifactName: String? {
        tombstone.artifactName
    }

    var record: CodeMapArtifactCatalogRecord? {
        guard let key = tombstone.key, let outcomeClass = tombstone.outcomeClass else { return nil }
        return CodeMapArtifactCatalogRecord(
            key: key,
            containerByteCount: tombstone.containerByteCount,
            payloadByteCount: tombstone.payloadByteCount,
            outcomeClass: outcomeClass,
            creationEpochSeconds: tombstone.epochSeconds,
            lastAccessEpochSeconds: tombstone.epochSeconds,
            lastAccessSequence: 0,
            state: .quarantined
        )
    }
}

enum CodeMapArtifactCatalogMutationResult: Equatable {
    case completed
    case missingOrChanged
    case leased
}

/// `descriptor` is the only mutable field and every read/claim is serialized by
/// `lock`. A descriptor-backed shared inter-process lease closes synchronously;
/// `deinit` exists only as a last-resort safety net.
final class CodeMapArtifactDiskLease: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32?

    fileprivate init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    func close() {
        let claimed = lock.withLock { () -> Int32? in
            defer { descriptor = nil }
            return descriptor
        }
        guard let claimed else { return }
        _ = flock(claimed, LOCK_UN)
        Darwin.close(claimed)
    }

    deinit {
        close()
    }
}

/// Independent sharded catalog. It owns no timers, tasks, or global state.
/// Every payload returned by the actor store is separately verified by
/// `CodeMapArtifactFileStore`; metadata is never an authority for an outcome.
struct CodeMapArtifactCatalog {
    private static let metadataMagic = Data("RPCMAPCASMETA01".utf8)
    private static let metadataVersion: UInt32 = 1
    private static let tombstoneMagic = Data("RPCMAPCASTOMB01".utf8)
    private static let tombstoneVersion: UInt32 = 1
    private static let directoryMode = mode_t(0o700)
    private static let fileMode = mode_t(0o600)
    private static let maximumPublishAttempts = 8

    private let layout: CatalogLayout
    private let policy: CodeMapArtifactStorePolicy
    private let removalHooks: CodeMapSecureFileRemovalHooks?
    private let scanHooks: CodeMapArtifactCatalogScanHooks?

    init(
        rootURL: URL,
        policy: CodeMapArtifactStorePolicy,
        removalHooks: CodeMapSecureFileRemovalHooks? = nil,
        scanHooks: CodeMapArtifactCatalogScanHooks? = nil
    ) throws {
        self.policy = policy
        self.removalHooks = removalHooks
        self.scanHooks = scanHooks
        layout = try Self.openLayout(rootURL: rootURL)
    }

    func beginScan(_ namespace: CodeMapArtifactCatalogScanNamespace) throws -> CodeMapArtifactCatalogScanSession {
        let root: CatalogDirectory = switch namespace {
        case .liveCatalog: layout.catalog
        case .liveArtifacts: layout.artifacts
        case .quarantineCatalog, .quarantineArtifacts: layout.quarantine
        }
        return try CodeMapArtifactCatalogScanSession(namespace: namespace, root: root)
    }

    /// Advances a retained descriptor traversal by exactly one non-dot entry.
    /// If a leaf cannot fit the caller's remaining byte allowance, it remains
    /// pending and the directory cursor is not advanced again until resumed.
    func nextScanStep(
        _ session: CodeMapArtifactCatalogScanSession,
        maximumReadByteCount: UInt64,
        epochSeconds: UInt64
    ) throws -> CodeMapArtifactCatalogScanStep {
        if session.completed { return .complete }
        if let pending = session.pending {
            return try processPendingScanEntry(
                pending,
                session: session,
                maximumReadByteCount: maximumReadByteCount,
                epochSeconds: epochSeconds
            )
        }

        while let level = session.levels.last {
            try validateScanLevel(level)
            errno = 0
            guard let entry = readdir(level.stream) else {
                guard errno == 0 else { throw Self.ioError("paged-directory-read") }
                session.levels.removeLast()
                continue
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            guard name != ".", name != ".." else { continue }
            session.visitedEntryCount += 1
            let maximum = session.namespace == .liveArtifacts || session.namespace == .quarantineArtifacts
                ? policy.maximumArtifactScanCount
                : policy.maximumCatalogRecordCount
            guard session.visitedEntryCount <= maximum else {
                throw CodeMapArtifactCatalogError.boundedScanExceeded
            }

            let components = level.components
            if components.isEmpty,
               session.namespace == .quarantineCatalog || session.namespace == .quarantineArtifacts,
               Self.canonicalEpoch(name) != nil
            {
                session.visitedEpochCount += 1
                guard session.visitedEpochCount <= policy.maximumQuarantineEpochCount else {
                    throw CodeMapArtifactCatalogError.boundedScanExceeded
                }
            }
            if shouldDescend(namespace: session.namespace, components: components, name: name) {
                guard let child = try openDirectory(parent: level.directory, name: name, create: false) else {
                    return .visit(.junk, chargeEntry: true)
                }
                try session.levels.append(.init(
                    directory: child,
                    components: components + [name],
                    ownsDescriptor: true,
                    parent: level.directory,
                    componentName: name
                ))
                return .visit(.boundary, chargeEntry: true)
            }
            guard isLeaf(namespace: session.namespace, components: components) else {
                return .visit(.junk, chargeEntry: true)
            }

            if let pid = CodeMapSecureFileRemoval.privateRemovalPID(name) {
                let recovery = try recoverPrivateDeletion(
                    parent: level.directory,
                    name: name,
                    pid: pid
                )
                return .visit(
                    .privateDeletion(
                        removed: recovery.removed,
                        storedByteCount: recovery.storedByteCount
                    ),
                    chargeEntry: true
                )
            }
            if let pid = Self.temporaryPID(name) {
                var removed = false
                if !Self.processIsActive(pid) {
                    removed = try withMaintenanceLock {
                        try removeRecoverableRegularFile(parent: level.directory, name: name)?.removed ?? false
                    }
                }
                return .visit(.temporary(removed: removed), chargeEntry: true)
            }

            let pending = CodeMapArtifactCatalogScanSession.Pending(
                parent: level.directory,
                components: components,
                name: name,
                charged: false
            )
            session.pending = pending
            return try processPendingScanEntry(
                pending,
                session: session,
                maximumReadByteCount: maximumReadByteCount,
                epochSeconds: epochSeconds
            )
        }
        session.completed = true
        return .complete
    }

    private func validateScanLevel(_ level: CodeMapArtifactCatalogScanSession.Level) throws {
        guard try Self.directoryIdentity(level.directory.rawValue) == level.directory.identity else {
            throw CodeMapArtifactCatalogError.insecureEntry
        }
        guard let parent = level.parent, let componentName = level.componentName else { return }
        var status = stat()
        guard fstatat(parent.rawValue, componentName, &status, AT_SYMLINK_NOFOLLOW) == 0,
              CatalogDirectoryIdentity(status) == level.directory.identity
        else { throw CodeMapArtifactCatalogError.insecureEntry }
    }

    private func shouldDescend(
        namespace: CodeMapArtifactCatalogScanNamespace,
        components: [String],
        name: String
    ) -> Bool {
        switch (namespace, components.count) {
        case (.liveCatalog, 0), (.liveArtifacts, 0):
            Self.isCanonicalShard(name)
        case (.quarantineCatalog, 0), (.quarantineArtifacts, 0):
            Self.canonicalEpoch(name) != nil
        case (.quarantineCatalog, 1):
            name == "catalog"
        case (.quarantineArtifacts, 1):
            name == "artifacts"
        case (.quarantineCatalog, 2), (.quarantineArtifacts, 2):
            Self.isCanonicalShard(name)
        default:
            false
        }
    }

    private func isLeaf(namespace: CodeMapArtifactCatalogScanNamespace, components: [String]) -> Bool {
        switch namespace {
        case .liveCatalog, .liveArtifacts: components.count == 1
        case .quarantineCatalog, .quarantineArtifacts: components.count == 3
        }
    }

    private func processPendingScanEntry(
        _ pending: CodeMapArtifactCatalogScanSession.Pending,
        session: CodeMapArtifactCatalogScanSession,
        maximumReadByteCount: UInt64,
        epochSeconds: UInt64
    ) throws -> CodeMapArtifactCatalogScanStep {
        let components = pending.components
        let name = pending.name
        let shard = components.last ?? ""
        let chargeEntry = !pending.charged
        guard let file = try openSecureScanFile(parent: pending.parent, name: name) else {
            session.pending = nil
            return .visit(.junk, chargeEntry: chargeEntry)
        }
        let byteCount = UInt64(file.identity.size)
        func deferForBytes(_ required: UInt64) -> CodeMapArtifactCatalogScanStep {
            if chargeEntry {
                session.pending = .init(
                    parent: pending.parent,
                    components: pending.components,
                    name: pending.name,
                    charged: true
                )
            }
            return .needsMoreBytes(required, chargeEntry: chargeEntry)
        }
        switch session.namespace {
        case .liveCatalog:
            guard let digest = Self.digestFromMetadataName(name), digest.hasPrefix(shard) else {
                session.pending = nil
                return .visit(.junk, chargeEntry: chargeEntry)
            }
            guard byteCount <= UInt64(policy.maximumMetadataRecordByteCount) else {
                let written = try quarantineUnknownMetadata(
                    parent: pending.parent,
                    shardName: shard,
                    name: name,
                    epochSeconds: epochSeconds
                )
                session.pending = nil
                return .visit(
                    .corruptLiveMetadata(
                        shard: shard,
                        name: name,
                        metadataByteCount: 0,
                        writtenByteCount: written
                    ),
                    chargeEntry: chargeEntry
                )
            }
            guard byteCount <= maximumReadByteCount else { return deferForBytes(byteCount) }
            do {
                try scanHooks?.afterMetadataAdmission?(pending.parent.rawValue, name, byteCount)
                let data = try readSecureFile(
                    file: file,
                    parent: pending.parent,
                    name: name,
                    maximumByteCount: policy.maximumMetadataRecordByteCount
                )
                let record = try Self.decodeRecord(data)
                guard record.state == .live, record.digest == digest, record.key.shard == shard else {
                    throw CodeMapArtifactCatalogError.invalidMetadata
                }
                session.pending = nil
                return .visit(
                    .liveRecord(record, metadataByteCount: UInt64(data.count)),
                    chargeEntry: chargeEntry
                )
            } catch let error as CodeMapArtifactCatalogError
                where error == .ioFailure(operation: "file-open", code: ENOENT)
            {
                session.pending = nil
                return .visit(.junk, chargeEntry: chargeEntry)
            } catch {
                let written = (try? quarantineUnknownMetadata(
                    parent: pending.parent,
                    shardName: shard,
                    name: name,
                    epochSeconds: epochSeconds
                )) ?? 0
                session.pending = nil
                return .visit(
                    .corruptLiveMetadata(
                        shard: shard,
                        name: name,
                        metadataByteCount: byteCount,
                        writtenByteCount: written
                    ),
                    chargeEntry: chargeEntry
                )
            }

        case .liveArtifacts:
            guard Self.isCanonicalDigest(name), name.hasPrefix(shard) else {
                session.pending = nil
                return .visit(.junk, chargeEntry: chargeEntry)
            }
            let verificationBytes = CodeMapArtifactFileStore.maintenanceOrphanReadByteCount(
                containerByteCount: byteCount,
                containerPolicy: policy.containerPolicy
            )
            let repeatedVerification = CodeMapArtifactFileStore.maintenanceVerificationReadByteCount(
                containerByteCount: byteCount
            )
            let (requiredBytes, overflow) = verificationBytes.addingReportingOverflow(repeatedVerification)
            let boundedRequiredBytes = overflow ? UInt64.max : requiredBytes
            guard boundedRequiredBytes <= maximumReadByteCount else { return deferForBytes(boundedRequiredBytes) }
            session.pending = nil
            return .visit(
                .liveArtifact(
                    CodeMapArtifactOrphanCandidate(shard: shard, digest: name),
                    containerByteCount: byteCount,
                    verificationReadByteCount: verificationBytes
                ),
                chargeEntry: chargeEntry
            )

        case .quarantineCatalog:
            guard components.count == 3, let epoch = Self.canonicalEpoch(components[0]) else {
                session.pending = nil
                return .visit(.junk, chargeEntry: chargeEntry)
            }
            guard let parts = Self.quarantineTombstoneParts(name), parts.digest.hasPrefix(shard) else {
                session.pending = nil
                return .visit(.junk, chargeEntry: chargeEntry)
            }
            guard byteCount <= UInt64(policy.maximumMetadataRecordByteCount) else {
                if let repaired = try repairCorruptQuarantineMetadata(
                    parent: pending.parent,
                    epochSeconds: epoch,
                    shard: shard,
                    name: name,
                    parts: parts
                ) {
                    session.pending = nil
                    return .visit(
                        .quarantineTombstone(
                            CodeMapArtifactQuarantineCandidate(tombstone: repaired.tombstone),
                            metadataByteCount: UInt64(repaired.metadataByteCount),
                            readByteCount: 0,
                            writtenByteCount: UInt64(repaired.metadataByteCount)
                        ),
                        chargeEntry: chargeEntry
                    )
                }
                session.pending = nil
                return .visit(
                    .corruptQuarantineMetadata(
                        epochSeconds: epoch,
                        shard: shard,
                        name: name,
                        metadataByteCount: 0
                    ),
                    chargeEntry: chargeEntry
                )
            }
            guard byteCount <= maximumReadByteCount else { return deferForBytes(byteCount) }
            do {
                try scanHooks?.afterMetadataAdmission?(pending.parent.rawValue, name, byteCount)
                let data = try readSecureFile(
                    file: file,
                    parent: pending.parent,
                    name: name,
                    maximumByteCount: policy.maximumMetadataRecordByteCount
                )
                let tombstone = try Self.decodeTombstone(data)
                guard tombstone.epochSeconds == epoch,
                      tombstone.digest == parts.digest,
                      tombstone.token == parts.token,
                      tombstone.shard == shard
                else { throw CodeMapArtifactCatalogError.invalidMetadata }
                session.pending = nil
                return .visit(
                    .quarantineTombstone(
                        CodeMapArtifactQuarantineCandidate(tombstone: tombstone),
                        metadataByteCount: UInt64(data.count),
                        readByteCount: UInt64(data.count),
                        writtenByteCount: 0
                    ),
                    chargeEntry: chargeEntry
                )
            } catch let error as CodeMapArtifactCatalogError
                where error == .ioFailure(operation: "file-open", code: ENOENT)
            {
                session.pending = nil
                return .visit(.junk, chargeEntry: chargeEntry)
            } catch {
                if let repaired = try repairCorruptQuarantineMetadata(
                    parent: pending.parent,
                    epochSeconds: epoch,
                    shard: shard,
                    name: name,
                    parts: parts
                ) {
                    session.pending = nil
                    return .visit(
                        .quarantineTombstone(
                            CodeMapArtifactQuarantineCandidate(tombstone: repaired.tombstone),
                            metadataByteCount: UInt64(repaired.metadataByteCount),
                            readByteCount: byteCount,
                            writtenByteCount: UInt64(repaired.metadataByteCount)
                        ),
                        chargeEntry: chargeEntry
                    )
                }
                session.pending = nil
                return .visit(
                    .corruptQuarantineMetadata(
                        epochSeconds: epoch,
                        shard: shard,
                        name: name,
                        metadataByteCount: byteCount
                    ),
                    chargeEntry: chargeEntry
                )
            }

        case .quarantineArtifacts:
            guard components.count == 3, let epoch = Self.canonicalEpoch(components[0]),
                  Self.quarantineArtifactParts(name) != nil
            else {
                session.pending = nil
                return .visit(.junk, chargeEntry: chargeEntry)
            }
            session.pending = nil
            return .visit(
                .quarantineArtifact(
                    epochSeconds: epoch,
                    shard: shard,
                    name: name,
                    storedByteCount: byteCount
                ),
                chargeEntry: chargeEntry
            )
        }
    }

    private func repairCorruptQuarantineMetadata(
        parent: CatalogDirectory,
        epochSeconds: UInt64,
        shard: String,
        name: String,
        parts: (digest: String, token: String)
    ) throws -> (tombstone: CodeMapArtifactQuarantineTombstone, metadataByteCount: Int)? {
        do {
            return try withMaintenanceAndExclusiveLease(shard: shard, digest: parts.digest) {
                guard let identity = try? secureFileIdentity(parent: parent, name: name),
                      identity.isSecureRegular(in: parent.identity.device)
                else { return nil }
                let tombstone = CodeMapArtifactQuarantineTombstone(
                    epochSeconds: epochSeconds,
                    digest: parts.digest,
                    token: parts.token,
                    reason: .recoveredMetadataOnly,
                    key: nil,
                    containerByteCount: 0,
                    payloadByteCount: 0,
                    outcomeClass: nil,
                    hasArtifact: true
                )
                let epoch = try requireDirectory(parent: layout.quarantine, name: String(epochSeconds))
                let quarantineCatalog = try requireDirectory(parent: epoch, name: "catalog")
                guard try removeSecureRegularFile(parent: parent, name: name) else { return nil }
                let written = try writeTombstone(
                    tombstone,
                    quarantineCatalog: quarantineCatalog
                )
                return (tombstone, written)
            }
        } catch let error as CodeMapArtifactCatalogError
            where error == .ioFailure(operation: "lease-busy", code: EWOULDBLOCK)
        {
            return nil
        }
    }

    func acquireSharedLease(key: CodeMapArtifactKey) throws -> CodeMapArtifactDiskLease {
        let descriptor = try openLeaseDescriptor(key: key)
        do {
            guard flock(descriptor, LOCK_SH | LOCK_NB) == 0 else {
                if errno == EWOULDBLOCK {
                    throw CodeMapArtifactCatalogError.ioFailure(
                        operation: "lease-busy",
                        code: EWOULDBLOCK
                    )
                }
                throw Self.ioError("lease-shared-lock")
            }
            try validateLeaseDescriptor(descriptor, key: key)
            return CodeMapArtifactDiskLease(descriptor: descriptor)
        } catch {
            _ = flock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
            throw error
        }
    }

    func withInsertLocks<T>(key: CodeMapArtifactKey, _ body: () throws -> T) throws -> T {
        let descriptor = try openLeaseDescriptor(key: key)
        defer { Darwin.close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else { throw Self.ioError("lease-insert-lock") }
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        try validateLeaseDescriptor(descriptor, key: key)
        return try withMaintenanceLock(body)
    }

    func writeLiveRecord(_ record: CodeMapArtifactCatalogRecord) throws -> CodeMapArtifactCatalogRecord {
        precondition(record.state == .live)
        return try withMaintenanceLock {
            try upsertLiveRecordAssumingMaintenanceLock(record)
        }
    }

    func updateLiveRecordIfPresent(_ record: CodeMapArtifactCatalogRecord) throws -> CodeMapArtifactCatalogRecord? {
        precondition(record.state == .live)
        return try withMaintenanceLock {
            guard let current = try readLiveRecord(key: record.key),
                  current.containerByteCount == record.containerByteCount,
                  current.payloadByteCount == record.payloadByteCount,
                  current.outcomeClass == record.outcomeClass,
                  current.creationEpochSeconds == record.creationEpochSeconds
            else { return nil }
            var merged = current
            if (record.lastAccessEpochSeconds, record.lastAccessSequence) >
                (current.lastAccessEpochSeconds, current.lastAccessSequence)
            {
                merged.lastAccessEpochSeconds = record.lastAccessEpochSeconds
                merged.lastAccessSequence = record.lastAccessSequence
                try writeRecord(merged, parent: layout.catalog, filename: "\(record.digest).meta")
            }
            return merged
        }
    }

    func writeLiveRecordAssumingMaintenanceLock(
        _ record: CodeMapArtifactCatalogRecord
    ) throws -> CodeMapArtifactCatalogRecord {
        precondition(record.state == .live)
        return try upsertLiveRecordAssumingMaintenanceLock(record)
    }

    private func upsertLiveRecordAssumingMaintenanceLock(
        _ incoming: CodeMapArtifactCatalogRecord
    ) throws -> CodeMapArtifactCatalogRecord {
        var merged = incoming
        if let current = try readLiveRecord(key: incoming.key) {
            guard current.containerByteCount == incoming.containerByteCount,
                  current.payloadByteCount == incoming.payloadByteCount,
                  current.outcomeClass == incoming.outcomeClass
            else { throw CodeMapArtifactCatalogError.invalidMetadata }
            merged = current
            merged.lastAccessEpochSeconds = max(current.lastAccessEpochSeconds, incoming.lastAccessEpochSeconds)
            if incoming.lastAccessEpochSeconds > current.lastAccessEpochSeconds ||
                (
                    incoming.lastAccessEpochSeconds == current.lastAccessEpochSeconds &&
                        incoming.lastAccessSequence > current.lastAccessSequence
                )
            {
                merged.lastAccessSequence = incoming.lastAccessSequence
            }
        }
        try writeRecord(merged, parent: layout.catalog, filename: "\(incoming.digest).meta")
        return merged
    }

    func quarantine(
        expectedRecord: CodeMapArtifactCatalogRecord,
        fileStore: CodeMapArtifactFileStore,
        epochSeconds: UInt64,
        reason: CodeMapArtifactQuarantineReason
    ) throws -> CodeMapArtifactCatalogMutationResult {
        try quarantineKnownPayload(
            expectedRecord: expectedRecord,
            fileStore: fileStore,
            epochSeconds: epochSeconds,
            reason: reason,
            requireValidContainer: true
        )
    }

    func quarantineCorruptPayload(
        expectedRecord: CodeMapArtifactCatalogRecord,
        fileStore: CodeMapArtifactFileStore,
        epochSeconds: UInt64
    ) throws -> CodeMapArtifactCatalogMutationResult {
        try quarantineKnownPayload(
            expectedRecord: expectedRecord,
            fileStore: fileStore,
            epochSeconds: epochSeconds,
            reason: .corruptPayload,
            requireValidContainer: false
        )
    }

    private func quarantineKnownPayload(
        expectedRecord: CodeMapArtifactCatalogRecord,
        fileStore: CodeMapArtifactFileStore,
        epochSeconds: UInt64,
        reason: CodeMapArtifactQuarantineReason,
        requireValidContainer: Bool
    ) throws -> CodeMapArtifactCatalogMutationResult {
        try withMaintenanceAndExclusiveLease(key: expectedRecord.key) {
            guard let current = try readLiveRecord(key: expectedRecord.key), current == expectedRecord else {
                return .missingOrChanged
            }
            if requireValidContainer {
                guard case let .hit(verified) = try fileStore.readVerified(
                    key: expectedRecord.key,
                    quarantineCorruption: false
                ),
                    UInt64(verified.containerByteCount) == current.containerByteCount,
                    UInt64(verified.payloadByteCount) == current.payloadByteCount,
                    CodeMapArtifactCatalogOutcomeClass(outcome: verified.outcome) == current.outcomeClass
                else {
                    return .missingOrChanged
                }
            } else {
                guard case .corrupt = try fileStore.readVerified(
                    key: expectedRecord.key,
                    quarantineCorruption: false
                ) else { return .missingOrChanged }
            }

            let token = UUID().uuidString.lowercased()
            let epoch = try requireDirectory(parent: layout.quarantine, name: String(epochSeconds))
            let quarantineArtifacts = try requireDirectory(parent: epoch, name: "artifacts")
            let quarantineCatalog = try requireDirectory(parent: epoch, name: "catalog")
            let destinationArtifacts = try requireDirectory(parent: quarantineArtifacts, name: current.key.shard)
            guard let sourceArtifacts = try openDirectory(
                parent: layout.artifacts,
                name: current.key.shard,
                create: false
            ),
                let sourceCatalog = try openDirectory(parent: layout.catalog, name: current.key.shard, create: false)
            else { return .missingOrChanged }

            let artifactName = current.digest
            let artifactDestination = "\(artifactName).\(token)"
            let sourceArtifact = try Self.openSecureFile(parent: sourceArtifacts, name: artifactName)
            guard renameatx_np(
                sourceArtifacts.rawValue,
                artifactName,
                destinationArtifacts.rawValue,
                artifactDestination,
                UInt32(RENAME_EXCL)
            ) == 0 else {
                if errno == ENOENT { return .missingOrChanged }
                throw Self.ioError("gc-artifact-quarantine")
            }
            guard try Self.fileIdentity(sourceArtifact.rawValue) == sourceArtifact.identity,
                  try secureFileIdentity(parent: destinationArtifacts, name: artifactDestination) == sourceArtifact.identity
            else { throw CodeMapArtifactCatalogError.insecureEntry }
            try Self.synchronize(sourceArtifacts.rawValue, operation: "gc-artifact-source-fsync")
            try Self.synchronize(destinationArtifacts.rawValue, operation: "gc-artifact-destination-fsync")

            _ = try writeTombstone(
                CodeMapArtifactQuarantineTombstone(
                    epochSeconds: epochSeconds,
                    digest: current.digest,
                    token: token,
                    reason: reason,
                    key: current.key,
                    containerByteCount: current.containerByteCount,
                    payloadByteCount: current.payloadByteCount,
                    outcomeClass: current.outcomeClass,
                    hasArtifact: true
                ),
                quarantineCatalog: quarantineCatalog
            )
            _ = try removeSecureRegularFile(parent: sourceCatalog, name: "\(artifactName).meta")
            return .completed
        }
    }

    func quarantineMissingPayload(
        expectedRecord: CodeMapArtifactCatalogRecord,
        epochSeconds: UInt64
    ) throws -> CodeMapArtifactCatalogMutationResult {
        try withMaintenanceAndExclusiveLease(key: expectedRecord.key) {
            guard let current = try readLiveRecord(key: expectedRecord.key), current == expectedRecord else {
                return .missingOrChanged
            }
            let token = UUID().uuidString.lowercased()
            let epoch = try requireDirectory(parent: layout.quarantine, name: String(epochSeconds))
            let quarantineCatalog = try requireDirectory(parent: epoch, name: "catalog")
            _ = try writeTombstone(
                CodeMapArtifactQuarantineTombstone(
                    epochSeconds: epochSeconds,
                    digest: current.digest,
                    token: token,
                    reason: .missingPayload,
                    key: current.key,
                    containerByteCount: 0,
                    payloadByteCount: 0,
                    outcomeClass: current.outcomeClass,
                    hasArtifact: false
                ),
                quarantineCatalog: quarantineCatalog
            )
            guard let source = try openDirectory(parent: layout.catalog, name: current.key.shard, create: false) else {
                return .completed
            }
            _ = try removeSecureRegularFile(parent: source, name: "\(current.digest).meta")
            return .completed
        }
    }

    func quarantineOrphanArtifact(
        _ candidate: CodeMapArtifactOrphanCandidate,
        fileStore: CodeMapArtifactFileStore,
        epochSeconds: UInt64,
        reason: CodeMapArtifactQuarantineReason = .orphanArtifact
    ) throws -> CodeMapArtifactCatalogMutationResult {
        try withMaintenanceAndDigestMutation(shard: candidate.shard, digest: candidate.digest) {
            guard let moved = try fileStore.quarantineOrphanAssumingMaintenanceLock(
                candidate,
                epochSeconds: epochSeconds
            ) else { return .missingOrChanged }
            let epoch = try requireDirectory(parent: layout.quarantine, name: String(epochSeconds))
            let quarantineCatalog = try requireDirectory(parent: epoch, name: "catalog")
            _ = try writeTombstone(
                CodeMapArtifactQuarantineTombstone(
                    epochSeconds: epochSeconds,
                    digest: candidate.digest,
                    token: moved.token,
                    reason: reason,
                    key: nil,
                    containerByteCount: moved.byteCount,
                    payloadByteCount: 0,
                    outcomeClass: nil,
                    hasArtifact: true
                ),
                quarantineCatalog: quarantineCatalog
            )
            return .completed
        }
    }

    func recoverArtifactOnlyTombstone(
        epochSeconds: UInt64,
        shard: String,
        artifactName: String,
        byteCount: UInt64
    ) throws -> CodeMapArtifactQuarantineRecoveryResult {
        guard let parts = Self.quarantineArtifactParts(artifactName),
              parts.digest.hasPrefix(shard)
        else { return .missingOrChanged }
        do {
            return try withMaintenanceAndExclusiveLease(shard: shard, digest: parts.digest) {
                guard let epoch = try openDirectory(
                    parent: layout.quarantine,
                    name: String(epochSeconds),
                    create: false
                ),
                    let artifacts = try openDirectory(parent: epoch, name: "artifacts", create: false),
                    let artifactShard = try openDirectory(parent: artifacts, name: shard, create: false),
                    let identity = try? secureFileIdentity(parent: artifactShard, name: artifactName),
                    identity.isSecureRegular(in: artifactShard.identity.device),
                    identity.size >= 0,
                    UInt64(identity.size) == byteCount
                else { return .missingOrChanged }
                let quarantineCatalog = try requireDirectory(parent: epoch, name: "catalog")
                let catalogShard = try requireDirectory(parent: quarantineCatalog, name: shard)
                let recovered = CodeMapArtifactQuarantineTombstone(
                    epochSeconds: epochSeconds,
                    digest: parts.digest,
                    token: parts.token,
                    reason: .recoveredArtifactOnly,
                    key: nil,
                    containerByteCount: byteCount,
                    payloadByteCount: 0,
                    outcomeClass: nil,
                    hasArtifact: true
                )
                let metadataName = recovered.metadataName
                do {
                    let existingData = try readSecureFile(
                        parent: catalogShard,
                        name: metadataName,
                        maximumByteCount: policy.maximumMetadataRecordByteCount
                    )
                    if let existing = try? Self.decodeTombstone(existingData),
                       existing.epochSeconds == epochSeconds,
                       existing.digest == parts.digest,
                       existing.token == parts.token,
                       existing.artifactName == artifactName
                    {
                        return .existing(metadataByteCount: existingData.count)
                    }
                    guard try removeSecureRegularFile(parent: catalogShard, name: metadataName) else {
                        return .missingOrChanged
                    }
                    let written = try writeTombstone(
                        recovered,
                        quarantineCatalog: quarantineCatalog
                    )
                    return .written(
                        metadataByteCount: written,
                        writtenByteCount: written,
                        readByteCount: existingData.count
                    )
                } catch let error as CodeMapArtifactCatalogError
                    where error == .ioFailure(operation: "file-open", code: ENOENT)
                {
                    let written = try writeTombstone(recovered, quarantineCatalog: quarantineCatalog)
                    return .written(metadataByteCount: written, writtenByteCount: written, readByteCount: 0)
                }
            }
        } catch let error as CodeMapArtifactCatalogError
            where error == .ioFailure(operation: "lease-busy", code: EWOULDBLOCK)
        {
            return .leased
        }
    }

    func sweep(_ candidate: CodeMapArtifactQuarantineCandidate) throws -> CodeMapArtifactCatalogMutationResult {
        try withMaintenanceAndDigestMutation(shard: candidate.shard, digest: candidate.tombstone.digest) {
            guard let epoch = try openDirectory(
                parent: layout.quarantine,
                name: String(candidate.epochSeconds),
                create: false
            ),
                let catalog = try openDirectory(parent: epoch, name: "catalog", create: false),
                let catalogShard = try openDirectory(parent: catalog, name: candidate.shard, create: false)
            else { return .missingOrChanged }
            let data: Data
            do {
                data = try readSecureFile(
                    parent: catalogShard,
                    name: candidate.metadataName,
                    maximumByteCount: policy.maximumMetadataRecordByteCount
                )
            } catch { return .missingOrChanged }
            guard let tombstone = try? Self.decodeTombstone(data), tombstone == candidate.tombstone else {
                return .missingOrChanged
            }
            if let artifactName = candidate.artifactName,
               let artifacts = try openDirectory(parent: epoch, name: "artifacts", create: false),
               let artifactShard = try openDirectory(parent: artifacts, name: candidate.shard, create: false)
            {
                _ = try removeSecureRegularFile(parent: artifactShard, name: artifactName)
            }
            _ = try removeSecureRegularFile(parent: catalogShard, name: candidate.metadataName)
            return .completed
        }
    }

    // MARK: - Metadata framing

    static func encodeRecord(_ record: CodeMapArtifactCatalogRecord) throws -> Data {
        let keyBytes = record.key.canonicalBytes
        guard keyBytes.count <= Int(UInt32.max) else { throw CodeMapArtifactCatalogError.invalidMetadata }
        var body = CatalogWriter(capacity: keyBytes.count + 64)
        body.append(UInt32(keyBytes.count))
        body.append(keyBytes)
        body.append(record.containerByteCount)
        body.append(record.payloadByteCount)
        body.append(record.outcomeClass.rawValue)
        body.append(record.creationEpochSeconds)
        body.append(record.lastAccessEpochSeconds)
        body.append(record.lastAccessSequence)
        body.append(record.state.rawValue)
        var result = CatalogWriter(capacity: body.data.count + 56)
        result.append(metadataMagic)
        result.append(metadataVersion)
        result.append(UInt32(body.data.count))
        result.append(body.data)
        result.append(Data(SHA256.hash(data: body.data)))
        return result.data
    }

    static func decodeRecord(_ data: Data) throws -> CodeMapArtifactCatalogRecord {
        var reader = CatalogReader(data: data)
        guard try reader.readData(count: metadataMagic.count) == metadataMagic else {
            throw CodeMapArtifactCatalogError.invalidMetadata
        }
        guard try reader.readUInt32() == metadataVersion else {
            throw CodeMapArtifactCatalogError.invalidMetadata
        }
        let bodyCount = try Int(reader.readUInt32())
        guard bodyCount >= 4, bodyCount <= data.count - reader.offset - SHA256.byteCount else {
            throw CodeMapArtifactCatalogError.invalidMetadata
        }
        let body = try reader.readData(count: bodyCount)
        let checksum = try reader.readData(count: SHA256.byteCount)
        guard reader.offset == data.count, checksum == Data(SHA256.hash(data: body)) else {
            throw CodeMapArtifactCatalogError.invalidMetadata
        }
        var bodyReader = CatalogReader(data: body)
        let keyCount = try Int(bodyReader.readUInt32())
        guard keyCount > 0, keyCount <= body.count - bodyReader.offset else {
            throw CodeMapArtifactCatalogError.invalidMetadata
        }
        let key: CodeMapArtifactKey
        do {
            key = try CodeMapArtifactKey(canonicalBytes: bodyReader.readData(count: keyCount))
        } catch {
            throw CodeMapArtifactCatalogError.invalidMetadata
        }
        let containerBytes = try bodyReader.readUInt64()
        let payloadBytes = try bodyReader.readUInt64()
        guard payloadBytes <= containerBytes,
              let outcomeClass = try CodeMapArtifactCatalogOutcomeClass(rawValue: bodyReader.readUInt8())
        else { throw CodeMapArtifactCatalogError.invalidMetadata }
        let creation = try bodyReader.readUInt64()
        let access = try bodyReader.readUInt64()
        let sequence = try bodyReader.readUInt64()
        guard let state = try CodeMapArtifactCatalogState(rawValue: bodyReader.readUInt8()),
              bodyReader.offset == body.count,
              access >= creation
        else { throw CodeMapArtifactCatalogError.invalidMetadata }
        let record = CodeMapArtifactCatalogRecord(
            key: key,
            containerByteCount: containerBytes,
            payloadByteCount: payloadBytes,
            outcomeClass: outcomeClass,
            creationEpochSeconds: creation,
            lastAccessEpochSeconds: access,
            lastAccessSequence: sequence,
            state: state
        )
        guard try encodeRecord(record) == data else { throw CodeMapArtifactCatalogError.invalidMetadata }
        return record
    }

    static func encodeTombstone(_ tombstone: CodeMapArtifactQuarantineTombstone) throws -> Data {
        guard isCanonicalDigest(tombstone.digest),
              let uuid = UUID(uuidString: tombstone.token),
              uuid.uuidString.lowercased() == tombstone.token,
              tombstone.payloadByteCount <= tombstone.containerByteCount,
              tombstone.key?.storageDigestHex == tombstone.digest || tombstone.key == nil,
              tombstone.key?.shard == tombstone.shard || tombstone.key == nil,
              (tombstone.key == nil) == (tombstone.outcomeClass == nil)
        else { throw CodeMapArtifactCatalogError.invalidMetadata }
        let keyBytes = tombstone.key?.canonicalBytes ?? Data()
        guard keyBytes.count <= Int(UInt32.max) else { throw CodeMapArtifactCatalogError.invalidMetadata }
        var body = CatalogWriter(capacity: keyBytes.count + 160)
        body.append(tombstone.epochSeconds)
        body.append(Data(tombstone.digest.utf8))
        body.append(Data(tombstone.token.utf8))
        body.append(tombstone.reason.rawValue)
        body.append(UInt32(keyBytes.count))
        body.append(keyBytes)
        body.append(tombstone.containerByteCount)
        body.append(tombstone.payloadByteCount)
        body.append(tombstone.outcomeClass?.rawValue ?? 0)
        body.append(tombstone.hasArtifact ? UInt8(1) : UInt8(0))
        var result = CatalogWriter(capacity: body.data.count + tombstoneMagic.count + 40)
        result.append(tombstoneMagic)
        result.append(tombstoneVersion)
        result.append(UInt32(body.data.count))
        result.append(body.data)
        result.append(Data(SHA256.hash(data: body.data)))
        return result.data
    }

    static func tombstoneByteCount(
        epochSeconds: UInt64,
        record: CodeMapArtifactCatalogRecord?,
        digest: String,
        reason: CodeMapArtifactQuarantineReason,
        containerByteCount: UInt64,
        hasArtifact: Bool
    ) throws -> UInt64 {
        try UInt64(encodeTombstone(CodeMapArtifactQuarantineTombstone(
            epochSeconds: epochSeconds,
            digest: digest,
            token: "00000000-0000-0000-0000-000000000000",
            reason: reason,
            key: record?.key,
            containerByteCount: containerByteCount,
            payloadByteCount: record == nil ? 0 : min(record?.payloadByteCount ?? 0, containerByteCount),
            outcomeClass: record?.outcomeClass,
            hasArtifact: hasArtifact
        )).count)
    }

    static func decodeTombstone(_ data: Data) throws -> CodeMapArtifactQuarantineTombstone {
        var reader = CatalogReader(data: data)
        guard try reader.readData(count: tombstoneMagic.count) == tombstoneMagic,
              try reader.readUInt32() == tombstoneVersion
        else { throw CodeMapArtifactCatalogError.invalidMetadata }
        let bodyCount = try Int(reader.readUInt32())
        guard bodyCount >= 8 + 64 + 36 + 1 + 4 + 8 + 8 + 1 + 1,
              bodyCount <= data.count - reader.offset - SHA256.byteCount
        else { throw CodeMapArtifactCatalogError.invalidMetadata }
        let body = try reader.readData(count: bodyCount)
        let checksum = try reader.readData(count: SHA256.byteCount)
        guard reader.offset == data.count, checksum == Data(SHA256.hash(data: body)) else {
            throw CodeMapArtifactCatalogError.invalidMetadata
        }
        var bodyReader = CatalogReader(data: body)
        let epoch = try bodyReader.readUInt64()
        guard let digest = try String(data: bodyReader.readData(count: 64), encoding: .utf8),
              let token = try String(data: bodyReader.readData(count: 36), encoding: .utf8),
              let reason = try CodeMapArtifactQuarantineReason(rawValue: bodyReader.readUInt8())
        else { throw CodeMapArtifactCatalogError.invalidMetadata }
        let keyCount = try Int(bodyReader.readUInt32())
        guard keyCount >= 0, keyCount <= body.count - bodyReader.offset else {
            throw CodeMapArtifactCatalogError.invalidMetadata
        }
        let key: CodeMapArtifactKey?
        if keyCount == 0 {
            key = nil
        } else {
            do { key = try CodeMapArtifactKey(canonicalBytes: bodyReader.readData(count: keyCount)) }
            catch { throw CodeMapArtifactCatalogError.invalidMetadata }
        }
        let containerBytes = try bodyReader.readUInt64()
        let payloadBytes = try bodyReader.readUInt64()
        let rawOutcome = try bodyReader.readUInt8()
        let outcomeClass = rawOutcome == 0 ? nil : CodeMapArtifactCatalogOutcomeClass(rawValue: rawOutcome)
        let rawHasArtifact = try bodyReader.readUInt8()
        guard rawHasArtifact <= 1, bodyReader.offset == body.count else {
            throw CodeMapArtifactCatalogError.invalidMetadata
        }
        let tombstone = CodeMapArtifactQuarantineTombstone(
            epochSeconds: epoch,
            digest: digest,
            token: token,
            reason: reason,
            key: key,
            containerByteCount: containerBytes,
            payloadByteCount: payloadBytes,
            outcomeClass: outcomeClass,
            hasArtifact: rawHasArtifact == 1
        )
        guard try encodeTombstone(tombstone) == data else {
            throw CodeMapArtifactCatalogError.invalidMetadata
        }
        return tombstone
    }

    // MARK: - Mutation helpers

    func liveRecord(
        key: CodeMapArtifactKey,
        quarantineCorruptionAt epochSeconds: UInt64
    ) throws -> CodeMapArtifactCatalogLiveRecordResult {
        guard let shard = try openDirectory(parent: layout.catalog, name: key.shard, create: false) else {
            return .missing
        }
        let name = "\(key.storageDigestHex).meta"
        do {
            let data = try readSecureFile(
                parent: shard,
                name: name,
                maximumByteCount: policy.maximumMetadataRecordByteCount
            )
            let record = try Self.decodeRecord(data)
            guard record.key == key, record.state == .live else {
                throw CodeMapArtifactCatalogError.invalidMetadata
            }
            return .record(record)
        } catch let error as CodeMapArtifactCatalogError
            where error == .ioFailure(operation: "file-open", code: ENOENT)
        {
            return .missing
        } catch {
            try? quarantineUnknownMetadata(
                parent: shard,
                shardName: key.shard,
                name: name,
                epochSeconds: epochSeconds
            )
            return .corrupt
        }
    }

    private func readLiveRecord(key: CodeMapArtifactKey) throws -> CodeMapArtifactCatalogRecord? {
        guard let shard = try openDirectory(parent: layout.catalog, name: key.shard, create: false) else {
            return nil
        }
        let name = "\(key.storageDigestHex).meta"
        do {
            let data = try readSecureFile(
                parent: shard,
                name: name,
                maximumByteCount: policy.maximumMetadataRecordByteCount
            )
            let record = try Self.decodeRecord(data)
            guard record.key == key, record.state == .live else { return nil }
            return record
        } catch let error as CodeMapArtifactCatalogError where error == .ioFailure(operation: "file-open", code: ENOENT) {
            return nil
        }
    }

    private func writeRecord(
        _ record: CodeMapArtifactCatalogRecord,
        parent: CatalogDirectory,
        filename: String
    ) throws {
        let data = try Self.encodeRecord(record)
        guard data.count <= policy.maximumMetadataRecordByteCount else {
            throw CodeMapArtifactCatalogError.invalidMetadata
        }
        let shard = try requireDirectory(parent: parent, name: record.key.shard)
        let temporaryName = ".tmp.\(getpid()).\(UUID().uuidString.lowercased())"
        let descriptor = openat(
            shard.rawValue,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            Self.fileMode
        )
        guard descriptor >= 0 else { throw Self.ioError("metadata-temp-create") }
        var published = false
        defer {
            if !published {
                _ = try? removeSecureRegularFile(
                    parent: shard,
                    name: temporaryName,
                    heldDescriptor: descriptor
                )
            }
            Darwin.close(descriptor)
        }
        guard fchmod(descriptor, Self.fileMode) == 0 else { throw Self.ioError("metadata-temp-mode") }
        try Self.writeAll(descriptor, data: data)
        try Self.synchronize(descriptor, operation: "metadata-temp-fsync")
        if let existing = try? secureFileIdentity(parent: shard, name: filename) {
            guard existing.isSecureRegular(in: shard.identity.device) else {
                throw CodeMapArtifactCatalogError.insecureEntry
            }
        }
        guard renameat(shard.rawValue, temporaryName, shard.rawValue, filename) == 0 else {
            throw Self.ioError("metadata-rename")
        }
        published = true
        try Self.synchronize(shard.rawValue, operation: "metadata-directory-fsync")
    }

    @discardableResult
    private func writeTombstone(
        _ tombstone: CodeMapArtifactQuarantineTombstone,
        quarantineCatalog: CatalogDirectory
    ) throws -> Int {
        let data = try Self.encodeTombstone(tombstone)
        guard data.count <= policy.maximumMetadataRecordByteCount else {
            throw CodeMapArtifactCatalogError.invalidMetadata
        }
        let shard = try requireDirectory(parent: quarantineCatalog, name: tombstone.shard)
        let temporaryName = ".tmp.\(getpid()).\(UUID().uuidString.lowercased())"
        let descriptor = openat(
            shard.rawValue,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            Self.fileMode
        )
        guard descriptor >= 0 else { throw Self.ioError("tombstone-temp-create") }
        var published = false
        defer {
            if !published {
                _ = try? removeSecureRegularFile(
                    parent: shard,
                    name: temporaryName,
                    heldDescriptor: descriptor
                )
            }
            Darwin.close(descriptor)
        }
        guard fchmod(descriptor, Self.fileMode) == 0 else { throw Self.ioError("tombstone-temp-mode") }
        try Self.writeAll(descriptor, data: data)
        try Self.synchronize(descriptor, operation: "tombstone-temp-fsync")
        let result = renameatx_np(
            shard.rawValue,
            temporaryName,
            shard.rawValue,
            tombstone.metadataName,
            UInt32(RENAME_EXCL)
        )
        if result != 0, errno == EEXIST {
            let existing = try readSecureFile(
                parent: shard,
                name: tombstone.metadataName,
                maximumByteCount: policy.maximumMetadataRecordByteCount
            )
            guard existing == data else { throw CodeMapArtifactCatalogError.invalidMetadata }
            return existing.count
        }
        guard result == 0 else { throw Self.ioError("tombstone-publish") }
        published = true
        try Self.synchronize(shard.rawValue, operation: "tombstone-directory-fsync")
        return data.count
    }

    private func withMaintenanceLock<T>(_ body: () throws -> T) throws -> T {
        while flock(layout.maintenance.rawValue, LOCK_EX) != 0 {
            guard errno == EINTR else { throw Self.ioError("maintenance-lock") }
        }
        defer { _ = flock(layout.maintenance.rawValue, LOCK_UN) }
        try validateMaintenanceLock()
        let result = try body()
        try validateMaintenanceLock()
        return result
    }

    private func withMaintenanceAndExclusiveLease(
        key: CodeMapArtifactKey,
        _ body: () throws -> CodeMapArtifactCatalogMutationResult
    ) throws -> CodeMapArtifactCatalogMutationResult {
        try withMaintenanceAndDigestMutation(shard: key.shard, digest: key.storageDigestHex, body)
    }

    private func withMaintenanceAndDigestMutation(
        shard: String,
        digest: String,
        _ body: () throws -> CodeMapArtifactCatalogMutationResult
    ) throws -> CodeMapArtifactCatalogMutationResult {
        do {
            return try withMaintenanceAndExclusiveLease(shard: shard, digest: digest, body)
        } catch let error as CodeMapArtifactCatalogError
            where error == .ioFailure(operation: "lease-busy", code: EWOULDBLOCK)
        {
            return .leased
        }
    }

    private func withMaintenanceAndExclusiveLease<T>(
        shard: String,
        digest: String,
        _ body: () throws -> T
    ) throws -> T {
        try withMaintenanceLock {
            let descriptor = try openLeaseDescriptor(shard: shard, digest: digest)
            defer { Darwin.close(descriptor) }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                if errno == EWOULDBLOCK { throw CodeMapArtifactCatalogError.ioFailure(operation: "lease-busy", code: EWOULDBLOCK) }
                throw Self.ioError("lease-exclusive-lock")
            }
            defer { _ = flock(descriptor, LOCK_UN) }
            try validateLeaseDescriptor(descriptor, shard: shard, digest: digest)
            return try body()
        }
    }

    private func validateMaintenanceLock() throws {
        let descriptorIdentity = try Self.fileIdentity(layout.maintenance.rawValue)
        let pathIdentity = try secureFileIdentity(parent: layout.version, name: "maintenance.lock")
        guard descriptorIdentity == layout.maintenance.identity,
              pathIdentity == layout.maintenance.identity
        else { throw CodeMapArtifactCatalogError.insecureEntry }
    }

    private func validateLeaseDescriptor(_ descriptor: Int32, key: CodeMapArtifactKey) throws {
        try validateLeaseDescriptor(descriptor, shard: key.shard, digest: key.storageDigestHex)
    }

    private func validateLeaseDescriptor(_ descriptor: Int32, shard shardName: String, digest: String) throws {
        let shard = try requireDirectory(parent: layout.leases, name: shardName)
        let descriptorIdentity = try Self.fileIdentity(descriptor)
        let pathIdentity = try secureFileIdentity(parent: shard, name: "\(digest).lock")
        guard descriptorIdentity == pathIdentity,
              descriptorIdentity.isSecureRegular(in: shard.identity.device),
              descriptorIdentity.size == 0
        else { throw CodeMapArtifactCatalogError.insecureEntry }
    }

    private func openLeaseDescriptor(key: CodeMapArtifactKey) throws -> Int32 {
        try openLeaseDescriptor(shard: key.shard, digest: key.storageDigestHex)
    }

    private func openLeaseDescriptor(shard shardName: String, digest: String) throws -> Int32 {
        guard Self.isCanonicalShard(shardName), Self.isCanonicalDigest(digest), digest.hasPrefix(shardName) else {
            throw CodeMapArtifactCatalogError.invalidMetadata
        }
        let shard = try requireDirectory(parent: layout.leases, name: shardName)
        let name = "\(digest).lock"
        var descriptor = openat(
            shard.rawValue,
            name,
            O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            Self.fileMode
        )
        if descriptor < 0, errno == EEXIST {
            descriptor = openat(shard.rawValue, name, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw Self.ioError("lease-open") }
        do {
            let identity = try Self.fileIdentity(descriptor)
            let path = try secureFileIdentity(parent: shard, name: name)
            guard identity == path, identity.isSecureRegular(in: shard.identity.device), identity.size == 0 else {
                throw CodeMapArtifactCatalogError.insecureEntry
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    // MARK: - Scan helpers

    private func recoverPrivateDeletion(
        parent: CatalogDirectory,
        name: String,
        pid: pid_t
    ) throws -> (removed: Bool, storedByteCount: UInt64?) {
        try withMaintenanceLock {
            if Self.processIsActive(pid) {
                do {
                    guard let file = try openSecureScanFile(parent: parent, name: name) else {
                        return (false, nil)
                    }
                    return (false, UInt64(file.identity.size))
                } catch CodeMapArtifactCatalogError.insecureEntry {
                    return (false, nil)
                } catch let error as CodeMapArtifactCatalogError
                    where error == .ioFailure(operation: "scan-leaf-open", code: ELOOP)
                {
                    return (false, nil)
                }
            }
            guard let recovery = try removeRecoverableRegularFile(parent: parent, name: name) else {
                return (false, nil)
            }
            return (recovery.removed, recovery.removed ? recovery.byteCount : nil)
        }
    }

    private func removeRecoverableRegularFile(
        parent: CatalogDirectory,
        name: String
    ) throws -> (removed: Bool, byteCount: UInt64)? {
        do {
            guard let file = try openSecureScanFile(parent: parent, name: name) else { return nil }
            let byteCount = UInt64(file.identity.size)
            let removed = try removeSecureRegularFile(
                parent: parent,
                name: name,
                heldDescriptor: file.rawValue
            )
            return (removed, byteCount)
        } catch CodeMapArtifactCatalogError.insecureEntry {
            return nil
        } catch let error as CodeMapArtifactCatalogError
            where error == .ioFailure(operation: "scan-leaf-open", code: ELOOP)
        {
            return nil
        }
    }

    private func quarantineUnknownMetadata(
        parent: CatalogDirectory,
        shardName: String,
        name: String,
        epochSeconds: UInt64
    ) throws -> UInt64 {
        guard let digest = Self.digestFromMetadataName(name), digest.hasPrefix(shardName) else { return 0 }
        do {
            return try withMaintenanceAndExclusiveLease(shard: shardName, digest: digest) {
                let identity: CatalogFileIdentity
                do {
                    identity = try secureFileIdentity(parent: parent, name: name)
                } catch let error as CodeMapArtifactCatalogError
                    where error == .ioFailure(operation: "file-path-stat", code: ENOENT)
                {
                    return 0
                }
                guard identity.isSecureRegular(in: parent.identity.device), identity.size >= 0 else {
                    throw CodeMapArtifactCatalogError.insecureEntry
                }
                let token = UUID().uuidString.lowercased()
                let epoch = try requireDirectory(parent: layout.quarantine, name: String(epochSeconds))
                let catalog = try requireDirectory(parent: epoch, name: "catalog")
                let written = try writeTombstone(
                    CodeMapArtifactQuarantineTombstone(
                        epochSeconds: epochSeconds,
                        digest: digest,
                        token: token,
                        reason: .corruptMetadata,
                        key: nil,
                        containerByteCount: 0,
                        payloadByteCount: 0,
                        outcomeClass: nil,
                        hasArtifact: false
                    ),
                    quarantineCatalog: catalog
                )
                _ = try removeSecureRegularFile(parent: parent, name: name)
                return UInt64(written)
            }
        } catch let error as CodeMapArtifactCatalogError
            where error == .ioFailure(operation: "lease-busy", code: EWOULDBLOCK)
        {
            return 0
        }
    }

    // MARK: - Descriptor filesystem

    private static func openLayout(rootURL: URL) throws -> CatalogLayout {
        guard rootURL.isFileURL, rootURL.path.hasPrefix("/"), rootURL.path != "/" else {
            throw CodeMapArtifactCatalogError.invalidLayout
        }
        let root = try openVerifiedDirectoryPath(rootURL)
        let namespace = try requireDirectoryStatic(parent: root, name: "CodeMapArtifacts")
        let version = try requireDirectoryStatic(parent: namespace, name: "v1")
        let artifacts = try requireDirectoryStatic(parent: version, name: "artifacts")
        let catalog = try requireDirectoryStatic(parent: version, name: "catalog")
        let leases = try requireDirectoryStatic(parent: version, name: "leases")
        let quarantine = try requireDirectoryStatic(parent: version, name: "quarantine")
        let maintenance = try openSecureFile(parent: version, name: "maintenance.lock")
        return CatalogLayout(
            version: version,
            artifacts: artifacts,
            catalog: catalog,
            leases: leases,
            quarantine: quarantine,
            maintenance: maintenance
        )
    }

    private func requireDirectory(parent: CatalogDirectory, name: String) throws -> CatalogDirectory {
        try Self.requireDirectoryStatic(parent: parent, name: name)
    }

    private static func requireDirectoryStatic(parent: CatalogDirectory, name: String) throws -> CatalogDirectory {
        guard let directory = try openDirectoryStatic(parent: parent, name: name, create: true) else {
            throw CodeMapArtifactCatalogError.invalidLayout
        }
        return directory
    }

    private func openDirectory(
        parent: CatalogDirectory,
        name: String,
        create: Bool
    ) throws -> CatalogDirectory? {
        try Self.openDirectoryStatic(parent: parent, name: name, create: create)
    }

    private static func openDirectoryStatic(
        parent: CatalogDirectory,
        name: String,
        create: Bool
    ) throws -> CatalogDirectory? {
        guard isSafeComponent(name) else { throw CodeMapArtifactCatalogError.invalidLayout }
        var created = false
        if create {
            if mkdirat(parent.rawValue, name, directoryMode) == 0 {
                created = true
            } else if errno != EEXIST {
                throw ioError("directory-create")
            }
        }
        let descriptor = openat(parent.rawValue, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0, !create, errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw ioError("directory-open") }
        do {
            if created, fchmod(descriptor, directoryMode) != 0 { throw ioError("directory-mode") }
            let identity = try directoryIdentity(descriptor)
            var pathStatus = stat()
            guard fstatat(parent.rawValue, name, &pathStatus, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw ioError("directory-path-stat")
            }
            guard identity == CatalogDirectoryIdentity(pathStatus),
                  identity.type == mode_t(S_IFDIR),
                  identity.owner == getuid(),
                  identity.permissions == directoryMode,
                  identity.device == parent.identity.device
            else { throw CodeMapArtifactCatalogError.insecureEntry }
            if created { try synchronize(parent.rawValue, operation: "directory-parent-fsync") }
            return CatalogDirectory(rawValue: descriptor, identity: identity)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func openVerifiedDirectoryPath(_ url: URL) throws -> CatalogDirectory {
        let components = url.path.split(separator: "/").map(String.init)
        guard !components.isEmpty else { throw CodeMapArtifactCatalogError.invalidLayout }
        let rootFD = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw ioError("root-open") }
        var current = try CatalogDirectory(rawValue: rootFD, identity: directoryIdentity(rootFD))
        for (index, component) in components.enumerated() {
            let descriptor = openat(current.rawValue, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw ioError("root-component-open") }
            let identity = try directoryIdentity(descriptor)
            var pathStatus = stat()
            guard fstatat(current.rawValue, component, &pathStatus, AT_SYMLINK_NOFOLLOW) == 0,
                  identity == CatalogDirectoryIdentity(pathStatus),
                  identity.type == mode_t(S_IFDIR),
                  index != components.count - 1 ||
                  (identity.owner == getuid() && identity.permissions == directoryMode)
            else {
                Darwin.close(descriptor)
                throw CodeMapArtifactCatalogError.insecureEntry
            }
            current = CatalogDirectory(rawValue: descriptor, identity: identity)
        }
        return current
    }

    private func openSecureScanFile(
        parent: CatalogDirectory,
        name: String
    ) throws -> CatalogFile? {
        let descriptor = openat(parent.rawValue, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw Self.ioError("scan-leaf-open") }
        do {
            let identity = try Self.fileIdentity(descriptor)
            guard try identity == secureFileIdentity(parent: parent, name: name),
                  identity.isSecureRegular(in: parent.identity.device),
                  identity.size >= 0
            else { throw CodeMapArtifactCatalogError.insecureEntry }
            return CatalogFile(rawValue: descriptor, identity: identity)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func readSecureFile(
        parent: CatalogDirectory,
        name: String,
        maximumByteCount: Int
    ) throws -> Data {
        guard let file = try openSecureScanFile(parent: parent, name: name) else {
            throw CodeMapArtifactCatalogError.ioFailure(operation: "file-open", code: ENOENT)
        }
        return try readSecureFile(
            file: file,
            parent: parent,
            name: name,
            maximumByteCount: maximumByteCount
        )
    }

    private func readSecureFile(
        file: CatalogFile,
        parent: CatalogDirectory,
        name: String,
        maximumByteCount: Int
    ) throws -> Data {
        let identity = file.identity
        guard try identity == secureFileIdentity(parent: parent, name: name),
              identity.size <= maximumByteCount,
              let byteCount = Int(exactly: identity.size)
        else { throw CodeMapArtifactCatalogError.insecureEntry }
        let data = try Self.readExactly(file.rawValue, byteCount: byteCount)
        guard try Self.fileIdentity(file.rawValue) == identity,
              try secureFileIdentity(parent: parent, name: name) == identity
        else { throw CodeMapArtifactCatalogError.insecureEntry }
        return data
    }

    private func removeSecureRegularFile(
        parent: CatalogDirectory,
        name: String,
        heldDescriptor: Int32? = nil
    ) throws -> Bool {
        do {
            return try CodeMapSecureFileRemoval.remove(
                parentDescriptor: parent.rawValue,
                expectedDevice: parent.identity.device,
                name: name,
                heldDescriptor: heldDescriptor,
                hooks: removalHooks
            )
        } catch let error as CodeMapSecureFileRemovalError {
            switch error {
            case .insecureEntry:
                throw CodeMapArtifactCatalogError.insecureEntry
            case let .ioFailure(operation, code):
                throw CodeMapArtifactCatalogError.ioFailure(
                    operation: "secure-remove-\(operation)",
                    code: code
                )
            }
        }
    }

    private static func openSecureFile(parent: CatalogDirectory, name: String) throws -> CatalogFile {
        let descriptor = openat(parent.rawValue, name, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ioError("secure-file-open") }
        do {
            let identity = try fileIdentity(descriptor)
            var status = stat()
            guard fstatat(parent.rawValue, name, &status, AT_SYMLINK_NOFOLLOW) == 0,
                  identity == CatalogFileIdentity(status),
                  identity.isSecureRegular(in: parent.identity.device)
            else { throw CodeMapArtifactCatalogError.insecureEntry }
            return CatalogFile(rawValue: descriptor, identity: identity)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func secureFileIdentity(parent: CatalogDirectory, name: String) throws -> CatalogFileIdentity {
        var status = stat()
        guard fstatat(parent.rawValue, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw Self.ioError("file-path-stat")
        }
        return CatalogFileIdentity(status)
    }

    private static func directoryIdentity(_ descriptor: Int32) throws -> CatalogDirectoryIdentity {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw ioError("directory-stat") }
        return CatalogDirectoryIdentity(status)
    }

    private static func fileIdentity(_ descriptor: Int32) throws -> CatalogFileIdentity {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw ioError("file-stat") }
        return CatalogFileIdentity(status)
    }

    private static func readExactly(_ descriptor: Int32, byteCount: Int) throws -> Data {
        var data = Data(count: byteCount)
        var completed = 0
        try data.withUnsafeMutableBytes { buffer in
            while completed < byteCount {
                let result = Darwin.read(descriptor, buffer.baseAddress!.advanced(by: completed), byteCount - completed)
                if result > 0 { completed += result }
                else if result == 0 { throw CodeMapArtifactCatalogError.invalidMetadata }
                else if errno != EINTR { throw ioError("file-read") }
            }
        }
        return data
    }

    private static func writeAll(_ descriptor: Int32, data: Data) throws {
        try data.withUnsafeBytes { buffer in
            var completed = 0
            while completed < buffer.count {
                let result = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: completed), buffer.count - completed)
                if result > 0 { completed += result }
                else if result == 0 { throw ioError("file-write-zero") }
                else if errno != EINTR { throw ioError("file-write") }
            }
        }
    }

    private static func synchronize(_ descriptor: Int32, operation: String) throws {
        while fsync(descriptor) != 0 {
            guard errno == EINTR else { throw ioError(operation) }
        }
    }

    private static func adding(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw CodeMapArtifactCatalogError.boundedScanExceeded }
        return value
    }

    private static func digestFromMetadataName(_ value: String) -> String? {
        guard value.hasSuffix(".meta") else { return nil }
        let digest = String(value.dropLast(5))
        return isCanonicalDigest(digest) ? digest : nil
    }

    private static func quarantineTombstoneParts(_ value: String) -> (digest: String, token: String)? {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              components[1] == "tomb",
              isCanonicalDigest(String(components[0]))
        else { return nil }
        let token = String(components[2])
        guard token == token.lowercased(),
              let uuid = UUID(uuidString: token), uuid.uuidString.lowercased() == token
        else { return nil }
        return (String(components[0]), token)
    }

    private static func quarantineArtifactParts(_ value: String) -> (digest: String, token: String)? {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 2, isCanonicalDigest(String(components[0])) else { return nil }
        let token = String(components[1])
        guard token == token.lowercased(),
              let uuid = UUID(uuidString: token), uuid.uuidString.lowercased() == token
        else { return nil }
        return (String(components[0]), token)
    }

    private static func isCanonicalDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(byte) ||
                (UInt8(ascii: "a") ... UInt8(ascii: "f")).contains(byte)
        }
    }

    private static func isCanonicalShard(_ value: String) -> Bool {
        value.count == 2 && isCanonicalDigest(value + String(repeating: "0", count: 62))
    }

    private static func canonicalEpoch(_ value: String) -> UInt64? {
        guard !value.isEmpty, value == "0" || !value.hasPrefix("0"), value.allSatisfy(\.isNumber),
              let result = UInt64(value), String(result) == value
        else { return nil }
        return result
    }

    private static func isSafeComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\0")
    }

    private static func temporaryPID(_ value: String) -> pid_t? {
        let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 4, pieces[0].isEmpty, pieces[1] == "tmp",
              let pid = pid_t(pieces[2]), pid > 0
        else { return nil }
        let token = String(pieces[3])
        guard token == token.lowercased(), let uuid = UUID(uuidString: token),
              uuid.uuidString.lowercased() == token
        else { return nil }
        return pid
    }

    private static func processIsActive(_ pid: pid_t) -> Bool {
        if pid == getpid() { return true }
        if kill(pid, 0) == 0 { return true }
        return errno != ESRCH
    }

    private static func ioError(_ operation: String) -> CodeMapArtifactCatalogError {
        CodeMapArtifactCatalogError.ioFailure(operation: operation, code: errno)
    }
}

private final class CatalogDirectory {
    let rawValue: Int32
    let identity: CatalogDirectoryIdentity

    init(rawValue: Int32, identity: CatalogDirectoryIdentity) {
        self.rawValue = rawValue
        self.identity = identity
    }

    deinit { Darwin.close(rawValue) }
}

private final class CatalogFile {
    let rawValue: Int32
    let identity: CatalogFileIdentity
    init(rawValue: Int32, identity: CatalogFileIdentity) {
        self.rawValue = rawValue
        self.identity = identity
    }

    deinit { Darwin.close(rawValue) }
}

private struct CatalogLayout {
    let version: CatalogDirectory
    let artifacts: CatalogDirectory
    let catalog: CatalogDirectory
    let leases: CatalogDirectory
    let quarantine: CatalogDirectory
    let maintenance: CatalogFile
}

private struct CatalogDirectoryIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
    let owner: uid_t
    let type: mode_t
    let permissions: mode_t

    init(_ status: stat) {
        device = status.st_dev
        inode = status.st_ino
        owner = status.st_uid
        type = status.st_mode & mode_t(S_IFMT)
        permissions = status.st_mode & mode_t(0o777)
    }
}

private struct CatalogFileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
    let owner: uid_t
    let type: mode_t
    let permissions: mode_t
    let links: nlink_t
    let size: off_t

    init(_ status: stat) {
        device = status.st_dev
        inode = status.st_ino
        owner = status.st_uid
        type = status.st_mode & mode_t(S_IFMT)
        permissions = status.st_mode & mode_t(0o777)
        links = status.st_nlink
        size = status.st_size
    }

    func isSecureRegular(in expectedDevice: dev_t) -> Bool {
        device == expectedDevice && owner == getuid() && type == mode_t(S_IFREG) &&
            permissions == mode_t(0o600) && links == 1
    }
}

private struct CatalogWriter {
    private(set) var data: Data
    init(capacity: Int) {
        data = Data(capacity: capacity)
    }

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
}

private struct CatalogReader {
    let data: Data
    private(set) var offset = 0
    mutating func readUInt8() throws -> UInt8 {
        try readData(count: 1)[0]
    }

    mutating func readUInt32() throws -> UInt32 {
        try readData(count: 4).reduce(into: UInt32(0)) { $0 = ($0 << 8) | UInt32($1) }
    }

    mutating func readUInt64() throws -> UInt64 {
        try readData(count: 8).reduce(into: UInt64(0)) { $0 = ($0 << 8) | UInt64($1) }
    }

    mutating func readData(count: Int) throws -> Data {
        guard count >= 0, count <= data.count - offset else { throw CodeMapArtifactCatalogError.invalidMetadata }
        let end = offset + count
        defer { offset = end }
        return data.subdata(in: offset ..< end)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

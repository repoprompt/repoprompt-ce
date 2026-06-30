import Darwin
import Foundation

enum CodeMapRootManifestStoreError: Error, Equatable {
    case invalidRoot
    case insecureDirectory
    case insecureLeaf
    case quotaExceeded
    case staleWriterAuthority
    case simulatedProcessTermination(CodeMapRootManifestStoreFaultPoint)
    case ioFailure(operation: String, code: Int32)
}

struct CodeMapRootManifestWriterSessionToken: Hashable {
    fileprivate let storeID: UUID
    fileprivate let sequence: UInt64
    fileprivate let nonce: UUID
}

struct CodeMapRootManifestWriterAuthorityToken: Hashable {
    fileprivate let storeID: UUID
    fileprivate let writerSession: CodeMapRootManifestWriterSessionToken
    fileprivate let namespace: CodeMapRootManifestNamespace
    fileprivate let authority: CodeMapRootManifestAuthority
    fileprivate let nonce: UUID
}

enum CodeMapRootManifestStoreFaultPoint: String, Equatable {
    case afterTemporaryWrite
    case afterTemporaryFileSync
    case afterManifestRename
    case afterManifestDirectorySync
}

enum CodeMapRootManifestStoreFaultAction {
    case proceed
    case simulateProcessTermination
}

enum CodeMapRootManifestStoreTerminalOperation {
    case removeNamespace
    case accounting
    case maintenance
    case publicationQuota
}

struct CodeMapRootManifestStorePolicy: Equatable {
    let maximumRecordCountPerManifest: Int
    let maximumManifestByteCount: UInt64
    let maximumManifestCount: Int
    let maximumStoreByteCount: UInt64
    let maximumQuarantineCount: Int
    let maintenanceEntryLimit: Int
    let minimumAccessRefreshIntervalSeconds: UInt64

    static let `default` = CodeMapRootManifestStorePolicy(
        maximumRecordCountPerManifest: 100_000,
        maximumManifestByteCount: 32 * 1024 * 1024,
        maximumManifestCount: 256,
        maximumStoreByteCount: 256 * 1024 * 1024,
        maximumQuarantineCount: 64,
        maintenanceEntryLimit: 4096,
        minimumAccessRefreshIntervalSeconds: 60
    )

    init(
        maximumRecordCountPerManifest: Int,
        maximumManifestByteCount: UInt64,
        maximumManifestCount: Int,
        maximumStoreByteCount: UInt64,
        maximumQuarantineCount: Int,
        maintenanceEntryLimit: Int,
        minimumAccessRefreshIntervalSeconds: UInt64 = 60
    ) {
        precondition(maximumRecordCountPerManifest > 0)
        precondition(maximumManifestByteCount > 0)
        precondition(maximumManifestCount > 0)
        precondition(maximumStoreByteCount >= maximumManifestByteCount)
        precondition(maximumQuarantineCount > 0)
        precondition(maintenanceEntryLimit > maximumManifestCount)
        self.maximumRecordCountPerManifest = maximumRecordCountPerManifest
        self.maximumManifestByteCount = maximumManifestByteCount
        self.maximumManifestCount = maximumManifestCount
        self.maximumStoreByteCount = maximumStoreByteCount
        self.maximumQuarantineCount = maximumQuarantineCount
        self.maintenanceEntryLimit = maintenanceEntryLimit
        self.minimumAccessRefreshIntervalSeconds = minimumAccessRefreshIntervalSeconds
    }
}

struct CodeMapRootManifestStoreHooks {
    var afterReadAdmission: @Sendable () async -> Void
    var afterWriteShardAdmission: @Sendable () -> Void
    var beforePublish: @Sendable () -> Void
    var afterPublishRename: @Sendable () -> Void
    var beforeMaintenanceLock: @Sendable () async -> Void
    var beforeTerminalAuthorityCheck: @Sendable (CodeMapRootManifestStoreTerminalOperation) -> Void
    var faultAction: @Sendable (CodeMapRootManifestStoreFaultPoint) -> CodeMapRootManifestStoreFaultAction

    init(
        afterReadAdmission: @escaping @Sendable () async -> Void = {},
        afterWriteShardAdmission: @escaping @Sendable () -> Void = {},
        beforePublish: @escaping @Sendable () -> Void = {},
        afterPublishRename: @escaping @Sendable () -> Void = {},
        beforeMaintenanceLock: @escaping @Sendable () async -> Void = {},
        beforeTerminalAuthorityCheck: @escaping @Sendable (CodeMapRootManifestStoreTerminalOperation) ->
            Void = { _ in },
        faultAction: @escaping @Sendable (CodeMapRootManifestStoreFaultPoint) ->
            CodeMapRootManifestStoreFaultAction = { _ in .proceed }
    ) {
        self.afterReadAdmission = afterReadAdmission
        self.afterWriteShardAdmission = afterWriteShardAdmission
        self.beforePublish = beforePublish
        self.afterPublishRename = afterPublishRename
        self.beforeMaintenanceLock = beforeMaintenanceLock
        self.beforeTerminalAuthorityCheck = beforeTerminalAuthorityCheck
        self.faultAction = faultAction
    }

    static let none = CodeMapRootManifestStoreHooks()
}

enum CodeMapRootManifestLoadResult: Equatable {
    case miss
    case stale(existingAuthority: CodeMapRootManifestAuthority)
    case hit(CodeMapRootManifestSnapshot)
}

enum CodeMapRootManifestWriteResult: Equatable {
    case inserted(manifestGeneration: UInt64)
    case replaced(manifestGeneration: UInt64)
    case unchanged(manifestGeneration: UInt64)
}

struct CodeMapRootManifestAccounting: Equatable {
    let manifestCount: Int
    let manifestByteCount: UInt64
    let recordCount: Int
    let temporaryCount: Int
    let quarantineCount: Int
    let hasMore: Bool
}

struct CodeMapRootManifestMaintenanceResult: Equatable {
    let examinedCount: Int
    let removedTemporaryCount: Int
    let quarantinedCorruptCount: Int
    let removedQuarantineCount: Int
    let evictedManifestCount: Int
    let prunedShardCount: Int
    let accounting: CodeMapRootManifestAccounting
}

private enum ManifestAuthorityReplacementPolicy {
    case unconstrained
    case exactPredecessor(CodeMapRootManifestAuthority?)
}

/// Inert, Git-only root-manifest persistence.
///
/// A whole namespace snapshot is published with one rename, so readers observe either the old
/// complete authority generation or the new complete authority generation. No workspace consumer
/// consults this store until the later binding-engine slice.
actor CodeMapRootManifestStore {
    private static let directoryMode = mode_t(0o700)
    private static let fileMode = mode_t(0o600)

    nonisolated let rootURL: URL
    private let policy: CodeMapRootManifestStorePolicy
    private let hooks: CodeMapRootManifestStoreHooks
    private let lockAnchor: ManifestDirectoryDescriptor
    private let accessEpochSeconds: @Sendable () -> UInt64
    private let writerAuthorityStoreID = UUID()
    private var nextWriterSessionSequence: UInt64? = 1
    private var activeWriterSessions: Set<CodeMapRootManifestWriterSessionToken> = []
    private var currentWriterAuthorities: [
        CodeMapRootManifestNamespace: CodeMapRootManifestWriterAuthorityToken
    ] = [:]
    private var pendingAccessRefreshes: [String: ManifestPendingAccessRefresh] = [:]
    private var accessRefreshTask: Task<Void, Never>?

    init(
        rootURL: URL,
        policy: CodeMapRootManifestStorePolicy = .default,
        hooks: CodeMapRootManifestStoreHooks = .none,
        accessEpochSeconds: @escaping @Sendable () -> UInt64 = {
            UInt64(max(0, Date().timeIntervalSince1970))
        }
    ) throws {
        guard rootURL.isFileURL,
              rootURL.path.hasPrefix("/"),
              rootURL.path != "/",
              !rootURL.path.contains("//"),
              !rootURL.path.contains("\0")
        else {
            throw CodeMapRootManifestStoreError.invalidRoot
        }
        self.rootURL = rootURL
        self.policy = policy
        self.hooks = hooks
        self.accessEpochSeconds = accessEpochSeconds
        let lockAnchor = try Self.openRootParent(rootURL)
        try Self.lock(lockAnchor.rawValue, operation: "manifest-anchor-lock")
        defer { Self.unlock(lockAnchor.rawValue) }
        guard Self.rootParentIsCurrent(lockAnchor, rootURL: rootURL) else {
            throw CodeMapRootManifestStoreError.insecureDirectory
        }
        _ = try Self.openLayout(rootURL: rootURL, create: true)
        self.lockAnchor = lockAnchor
    }

    func registerManifestWriterSession() throws -> CodeMapRootManifestWriterSessionToken {
        guard let sequence = nextWriterSessionSequence else {
            throw CodeMapRootManifestStoreError.quotaExceeded
        }
        let token = CodeMapRootManifestWriterSessionToken(
            storeID: writerAuthorityStoreID,
            sequence: sequence,
            nonce: UUID()
        )
        nextWriterSessionSequence = sequence == .max ? nil : sequence + 1
        activeWriterSessions.insert(token)
        return token
    }

    func endManifestWriterSession(_ token: CodeMapRootManifestWriterSessionToken) {
        guard token.storeID == writerAuthorityStoreID else { return }
        activeWriterSessions.remove(token)
    }

    func claimManifestWriterAuthority(
        namespace: CodeMapRootManifestNamespace,
        authority: CodeMapRootManifestAuthority,
        writerSession: CodeMapRootManifestWriterSessionToken
    ) -> CodeMapRootManifestWriterAuthorityToken? {
        guard writerSession.storeID == writerAuthorityStoreID,
              activeWriterSessions.contains(writerSession)
        else { return nil }
        if let current = currentWriterAuthorities[namespace] {
            if current.writerSession == writerSession {
                return current.authority == authority ? current : nil
            }
            guard current.writerSession.sequence < writerSession.sequence else { return nil }
        }
        let token = CodeMapRootManifestWriterAuthorityToken(
            storeID: writerAuthorityStoreID,
            writerSession: writerSession,
            namespace: namespace,
            authority: authority,
            nonce: UUID()
        )
        currentWriterAuthorities[namespace] = token
        return token
    }

    func manifestWriterAuthorityIsCurrent(
        _ token: CodeMapRootManifestWriterAuthorityToken
    ) -> Bool {
        writerAuthorityIsCurrent(token)
    }

    private func writerAuthorityIsCurrent(
        _ token: CodeMapRootManifestWriterAuthorityToken
    ) -> Bool {
        token.storeID == writerAuthorityStoreID &&
            activeWriterSessions.contains(token.writerSession) &&
            currentWriterAuthorities[token.namespace] == token
    }

    nonisolated func manifestURL(for namespace: CodeMapRootManifestNamespace) -> URL {
        rootURL
            .appendingPathComponent("CodeMapRootManifests", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent("manifests", isDirectory: true)
            .appendingPathComponent(namespace.shard, isDirectory: true)
            .appendingPathComponent(namespace.storageDigestHex, isDirectory: false)
    }

    func loadCurrentManifest(
        namespace: CodeMapRootManifestNamespace,
        currentAuthority: CodeMapRootManifestAuthority
    ) async throws -> CodeMapRootManifestLoadResult {
        guard namespace.isCurrent else { return .miss }
        let layout = try Self.openLayout(rootURL: rootURL, create: false)
        guard let shard = try Self.openOwnedDirectory(
            parent: layout.manifests,
            name: namespace.shard,
            create: false
        ) else {
            return .miss
        }
        let name = namespace.storageDigestHex
        let descriptor = openat(shard.rawValue, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT || errno == ELOOP { return .miss }
            throw Self.ioError("manifest-open")
        }
        defer { Darwin.close(descriptor) }

        let before: ManifestFileIdentity
        do {
            before = try Self.validatedFileIdentity(
                descriptor,
                parent: shard,
                name: name,
                expectedMode: Self.fileMode
            )
        } catch CodeMapRootManifestStoreError.insecureLeaf {
            return .miss
        }
        guard before.size >= 0,
              UInt64(before.size) <= min(policy.maximumManifestByteCount, UInt64(Int.max)),
              before.size <= off_t(CodeMapRootManifestCodec.maximumEncodedByteCount)
        else {
            try await quarantineIfCurrent(layout: layout, shard: shard, name: name, descriptor: descriptor)
            return .miss
        }

        await hooks.afterReadAdmission()
        guard Self.layoutIsCurrent(layout, rootURL: rootURL),
              Self.directoryIsCurrent(
                  shard,
                  parent: layout.manifests,
                  name: namespace.shard
              ),
              let admitted = try? Self.validatedFileIdentity(
                  descriptor,
                  parent: shard,
                  name: name,
                  expectedMode: Self.fileMode
              ),
              admitted == before
        else {
            return .miss
        }
        let data: Data
        do {
            data = try Self.readExactly(descriptor, byteCount: Int(before.size))
        } catch {
            try await quarantineIfCurrent(layout: layout, shard: shard, name: name, descriptor: descriptor)
            return .miss
        }
        guard let after = try? Self.validatedFileIdentity(
            descriptor,
            parent: shard,
            name: name,
            expectedMode: Self.fileMode
        ), before == after else {
            return .miss
        }
        let snapshot: CodeMapRootManifestSnapshot
        do {
            snapshot = try CodeMapRootManifestCodec.decode(
                data,
                expectedNamespace: namespace,
                filenameDigest: name
            )
        } catch {
            try await quarantineIfCurrent(layout: layout, shard: shard, name: name, descriptor: descriptor)
            return .miss
        }
        guard Self.layoutIsCurrent(layout, rootURL: rootURL),
              Self.directoryIsCurrent(
                  shard,
                  parent: layout.manifests,
                  name: namespace.shard
              ),
              let current = try? Self.validatedFileIdentity(
                  descriptor,
                  parent: shard,
                  name: name,
                  expectedMode: Self.fileMode
              ),
              current == after
        else {
            return .miss
        }
        guard snapshot.authority == currentAuthority else {
            return .stale(existingAuthority: snapshot.authority)
        }
        scheduleAccessRefresh(for: snapshot)
        return .hit(snapshot)
    }

    private func scheduleAccessRefresh(for snapshot: CodeMapRootManifestSnapshot) {
        let accessEpoch = accessEpochSeconds()
        guard accessEpoch > snapshot.lastAccessEpochSeconds,
              accessEpoch - snapshot.lastAccessEpochSeconds >= policy.minimumAccessRefreshIntervalSeconds
        else { return }
        let digest = snapshot.namespace.storageDigestHex
        let candidate = ManifestPendingAccessRefresh(snapshot: snapshot, accessEpochSeconds: accessEpoch)
        if let pending = pendingAccessRefreshes[digest] {
            if candidate.snapshot.manifestGeneration > pending.snapshot.manifestGeneration ||
                candidate.snapshot.manifestGeneration == pending.snapshot.manifestGeneration &&
                candidate.accessEpochSeconds > pending.accessEpochSeconds
            {
                pendingAccessRefreshes[digest] = candidate
            }
        } else {
            pendingAccessRefreshes[digest] = candidate
        }
        guard accessRefreshTask == nil else { return }
        accessRefreshTask = Task { [weak self] in
            await self?.drainPendingAccessRefreshes()
        }
    }

    private func drainPendingAccessRefreshes() async {
        while !pendingAccessRefreshes.isEmpty {
            let batch = pendingAccessRefreshes
            pendingAccessRefreshes.removeAll(keepingCapacity: true)
            for digest in batch.keys.sorted() {
                guard let refresh = batch[digest] else { continue }
                _ = try? await publishCurrentManifest(
                    namespace: refresh.snapshot.namespace,
                    authority: refresh.snapshot.authority,
                    records: refresh.snapshot.records,
                    lastAccessEpochSeconds: refresh.accessEpochSeconds,
                    expectedSnapshot: refresh.snapshot,
                    authorityReplacementPolicy: .unconstrained
                )
            }
        }
        accessRefreshTask = nil
    }

    #if DEBUG
        func waitForPendingAccessRefreshesForTesting() async {
            while let task = accessRefreshTask {
                await task.value
            }
        }
    #endif

    func replaceCurrentManifest(
        namespace: CodeMapRootManifestNamespace,
        authority: CodeMapRootManifestAuthority,
        records: [CodeMapRootManifestRecord],
        lastAccessEpochSeconds: UInt64
    ) async throws -> CodeMapRootManifestWriteResult {
        try await updateCurrentManifest(
            namespace: namespace,
            authority: authority,
            records: records,
            lastAccessEpochSeconds: lastAccessEpochSeconds
        )
    }

    /// Atomically replaces the complete namespace snapshot. The name emphasizes that callers must
    /// provide the complete post-update record set; there is no record-at-a-time publication.
    func updateCurrentManifest(
        namespace: CodeMapRootManifestNamespace,
        authority: CodeMapRootManifestAuthority,
        records: [CodeMapRootManifestRecord],
        lastAccessEpochSeconds: UInt64
    ) async throws -> CodeMapRootManifestWriteResult {
        guard records.allSatisfy(\.isVerifiedForPublication) else {
            throw CodeMapRootManifestModelError.corruptRecord
        }
        return try await publishCurrentManifest(
            namespace: namespace,
            authority: authority,
            records: records,
            lastAccessEpochSeconds: lastAccessEpochSeconds,
            expectedSnapshot: nil,
            authorityReplacementPolicy: .unconstrained
        )
    }

    /// Atomically merges namespace-local changes while holding the secure store authority lock.
    /// The on-disk value remains a complete manifest snapshot.
    func mergeCurrentManifest(
        namespace: CodeMapRootManifestNamespace,
        authority: CodeMapRootManifestAuthority,
        replacingPreviouslyObservedAuthority predecessor: CodeMapRootManifestAuthority?,
        upserting records: [CodeMapRootManifestRecord],
        removing repositoryRelativePaths: Set<String>,
        lastAccessEpochSeconds: UInt64
    ) async throws -> CodeMapRootManifestWriteResult {
        let upsertPaths = Set(records.map(\.repositoryRelativePath))
        guard records.allSatisfy(\.isVerifiedForPublication),
              upsertPaths.count == records.count,
              upsertPaths.isDisjoint(with: repositoryRelativePaths),
              upsertPaths.allSatisfy(namespace.contains(repositoryRelativePath:)),
              repositoryRelativePaths.allSatisfy(namespace.contains(repositoryRelativePath:))
        else {
            throw CodeMapRootManifestModelError.corruptRecord
        }
        return try await publishCurrentManifest(
            namespace: namespace,
            authority: authority,
            records: records,
            lastAccessEpochSeconds: lastAccessEpochSeconds,
            expectedSnapshot: nil,
            authorityReplacementPolicy: .exactPredecessor(predecessor),
            mergeExisting: true,
            removingRepositoryRelativePaths: repositoryRelativePaths
        )
    }

    /// Production writer entry point. The opaque token is revalidated after the final suspension
    /// point so an older writer session cannot publish after a newer session claims the namespace.
    func mergeCurrentManifest(
        namespace: CodeMapRootManifestNamespace,
        authority: CodeMapRootManifestAuthority,
        writerAuthority: CodeMapRootManifestWriterAuthorityToken,
        replacingPreviouslyObservedAuthority predecessor: CodeMapRootManifestAuthority?,
        upserting records: [CodeMapRootManifestRecord],
        removing repositoryRelativePaths: Set<String>,
        lastAccessEpochSeconds: UInt64
    ) async throws -> CodeMapRootManifestWriteResult {
        let upsertPaths = Set(records.map(\.repositoryRelativePath))
        guard records.allSatisfy(\.isVerifiedForPublication),
              upsertPaths.count == records.count,
              upsertPaths.isDisjoint(with: repositoryRelativePaths),
              upsertPaths.allSatisfy(namespace.contains(repositoryRelativePath:)),
              repositoryRelativePaths.allSatisfy(namespace.contains(repositoryRelativePath:)),
              writerAuthority.namespace == namespace,
              writerAuthority.authority == authority
        else {
            throw CodeMapRootManifestModelError.corruptRecord
        }
        return try await publishCurrentManifest(
            namespace: namespace,
            authority: authority,
            records: records,
            lastAccessEpochSeconds: lastAccessEpochSeconds,
            expectedSnapshot: nil,
            authorityReplacementPolicy: .exactPredecessor(predecessor),
            writerAuthority: writerAuthority,
            mergeExisting: true,
            removingRepositoryRelativePaths: repositoryRelativePaths
        )
    }

    private func publishCurrentManifest(
        namespace: CodeMapRootManifestNamespace,
        authority: CodeMapRootManifestAuthority,
        records: [CodeMapRootManifestRecord],
        lastAccessEpochSeconds: UInt64,
        expectedSnapshot: CodeMapRootManifestSnapshot?,
        authorityReplacementPolicy: ManifestAuthorityReplacementPolicy,
        writerAuthority: CodeMapRootManifestWriterAuthorityToken? = nil,
        mergeExisting: Bool = false,
        removingRepositoryRelativePaths: Set<String> = []
    ) async throws -> CodeMapRootManifestWriteResult {
        guard namespace.isCurrent else {
            throw CodeMapRootManifestStoreError.quotaExceeded
        }
        let layout = try Self.openLayout(rootURL: rootURL, create: false)
        await hooks.beforeMaintenanceLock()
        try Self.lock(lockAnchor.rawValue, operation: "manifest-anchor-lock")
        defer { Self.unlock(lockAnchor.rawValue) }
        guard Self.rootParentIsCurrent(lockAnchor, rootURL: rootURL),
              Self.layoutIsCurrent(layout, rootURL: rootURL)
        else {
            throw CodeMapRootManifestStoreError.insecureDirectory
        }
        if let writerAuthority, !writerAuthorityIsCurrent(writerAuthority) {
            throw CodeMapRootManifestStoreError.staleWriterAuthority
        }

        let shard = try Self.requireOwnedDirectory(parent: layout.manifests, name: namespace.shard)
        hooks.afterWriteShardAdmission()
        guard Self.layoutIsCurrent(layout, rootURL: rootURL),
              Self.directoryIsCurrent(shard, parent: layout.manifests, name: namespace.shard)
        else {
            throw CodeMapRootManifestStoreError.insecureDirectory
        }
        let name = namespace.storageDigestHex
        let existing = try inspectExisting(shard: shard, namespace: namespace, name: name)
        if let expectedSnapshot {
            guard let current = existing.snapshot,
                  current.manifestGeneration == expectedSnapshot.manifestGeneration,
                  current.authority == expectedSnapshot.authority,
                  current.records == expectedSnapshot.records,
                  current.lastAccessEpochSeconds >= expectedSnapshot.lastAccessEpochSeconds
            else {
                return .unchanged(manifestGeneration: expectedSnapshot.manifestGeneration)
            }
        }
        if case let .exactPredecessor(predecessor) = authorityReplacementPolicy,
           let existingAuthority = existing.snapshot?.authority,
           existingAuthority != authority
        {
            guard existingAuthority == predecessor,
                  existingAuthority.authorityGeneration < authority.authorityGeneration
            else {
                throw CodeMapRootManifestModelError.staleAuthority
            }
        }
        let sortedRecords: [CodeMapRootManifestRecord]
        if mergeExisting {
            var recordsByPath: [String: CodeMapRootManifestRecord] = [:]
            if let snapshot = existing.snapshot, snapshot.authority == authority {
                recordsByPath = Dictionary(
                    uniqueKeysWithValues: snapshot.records.map { ($0.repositoryRelativePath, $0) }
                )
            }
            for path in removingRepositoryRelativePaths {
                recordsByPath.removeValue(forKey: path)
            }
            for record in records {
                recordsByPath[record.repositoryRelativePath] = record
            }
            sortedRecords = recordsByPath.values.sorted {
                $0.repositoryRelativePath.utf8.lexicographicallyPrecedes($1.repositoryRelativePath.utf8)
            }
        } else {
            sortedRecords = records.sorted {
                $0.repositoryRelativePath.utf8.lexicographicallyPrecedes($1.repositoryRelativePath.utf8)
            }
        }
        guard sortedRecords.count <= policy.maximumRecordCountPerManifest,
              sortedRecords.count <= CodeMapRootManifestCodec.maximumRecordCount
        else {
            throw CodeMapRootManifestStoreError.quotaExceeded
        }
        let semanticUnchanged = existing.snapshot.map {
            $0.authority == authority && $0.records == sortedRecords
        } ?? false
        let effectiveAccessEpoch = max(
            existing.snapshot?.lastAccessEpochSeconds ?? 0,
            lastAccessEpochSeconds
        )
        if let current = existing.snapshot,
           semanticUnchanged,
           current.lastAccessEpochSeconds == effectiveAccessEpoch
        {
            return .unchanged(manifestGeneration: current.manifestGeneration)
        }
        let nextGeneration: UInt64 = if semanticUnchanged, let previous = existing.snapshot?.manifestGeneration {
            previous
        } else if let previous = existing.snapshot?.manifestGeneration, previous < UInt64.max {
            previous + 1
        } else {
            1
        }
        let snapshot = try CodeMapRootManifestSnapshot(
            namespace: namespace,
            authority: authority,
            manifestGeneration: nextGeneration,
            lastAccessEpochSeconds: effectiveAccessEpoch,
            records: sortedRecords
        )
        let encoded = try CodeMapRootManifestCodec.encode(snapshot: snapshot)
        guard UInt64(encoded.count) <= policy.maximumManifestByteCount else {
            throw CodeMapRootManifestStoreError.quotaExceeded
        }

        _ = try reconcileLocked(
            layout: layout,
            maximumEntries: nil,
            protectingDigest: name,
            incomingByteCount: UInt64(encoded.count),
            replacedByteCount: existing.snapshot.flatMap { _ in existing.identity }.map { UInt64($0.size) } ?? 0
        )
        guard Self.layoutIsCurrent(layout, rootURL: rootURL),
              Self.directoryIsCurrent(shard, parent: layout.manifests, name: namespace.shard)
        else {
            throw CodeMapRootManifestStoreError.insecureDirectory
        }
        let publicationExistingIdentity = try Self.fileIdentityAt(parent: shard, name: name)
        if let current = publicationExistingIdentity,
           !current.isSecureRegularFile(in: shard.identity.device, expectedMode: Self.fileMode)
        {
            throw CodeMapRootManifestStoreError.insecureLeaf
        }

        let temporaryName = ".tmp.\(getpid()).\(UUID().uuidString.lowercased())"
        let descriptor = openat(
            shard.rawValue,
            temporaryName,
            O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            Self.fileMode
        )
        guard descriptor >= 0 else { throw Self.ioError("temporary-open") }
        var temporaryExists = true
        defer {
            Darwin.close(descriptor)
            if temporaryExists { _ = unlinkat(shard.rawValue, temporaryName, 0) }
        }
        let initial = try Self.validatedFileIdentity(
            descriptor,
            parent: shard,
            name: temporaryName,
            expectedMode: Self.fileMode
        )
        guard initial.size == 0 else { throw CodeMapRootManifestStoreError.insecureLeaf }
        try Self.writeAll(descriptor, data: encoded)
        if hooks.faultAction(.afterTemporaryWrite) == .simulateProcessTermination {
            temporaryExists = false
            throw CodeMapRootManifestStoreError.simulatedProcessTermination(.afterTemporaryWrite)
        }
        try Self.synchronize(descriptor, operation: "temporary-fsync")
        if hooks.faultAction(.afterTemporaryFileSync) == .simulateProcessTermination {
            temporaryExists = false
            throw CodeMapRootManifestStoreError.simulatedProcessTermination(.afterTemporaryFileSync)
        }
        let completed = try Self.validatedFileIdentity(
            descriptor,
            parent: shard,
            name: temporaryName,
            expectedMode: Self.fileMode
        )
        guard initial.sameObject(as: completed), completed.size == off_t(encoded.count) else {
            throw CodeMapRootManifestStoreError.insecureLeaf
        }

        hooks.beforePublish()
        guard Self.rootParentIsCurrent(lockAnchor, rootURL: rootURL),
              Self.layoutIsCurrent(layout, rootURL: rootURL),
              Self.directoryIsCurrent(shard, parent: layout.manifests, name: namespace.shard)
        else {
            throw CodeMapRootManifestStoreError.insecureDirectory
        }
        if let expected = publicationExistingIdentity {
            guard let current = try Self.fileIdentityAt(parent: shard, name: name), current == expected else {
                throw CodeMapRootManifestStoreError.insecureLeaf
            }
        } else if try Self.fileIdentityAt(parent: shard, name: name) != nil {
            throw CodeMapRootManifestStoreError.insecureLeaf
        }
        guard renameat(shard.rawValue, temporaryName, shard.rawValue, name) == 0 else {
            throw Self.ioError("manifest-publish")
        }
        temporaryExists = false
        if hooks.faultAction(.afterManifestRename) == .simulateProcessTermination {
            throw CodeMapRootManifestStoreError.simulatedProcessTermination(.afterManifestRename)
        }
        hooks.afterPublishRename()
        guard Self.rootParentIsCurrent(lockAnchor, rootURL: rootURL),
              Self.layoutIsCurrent(layout, rootURL: rootURL),
              Self.directoryIsCurrent(shard, parent: layout.manifests, name: namespace.shard)
        else {
            throw CodeMapRootManifestStoreError.insecureDirectory
        }
        let published = try Self.validatedFileIdentity(
            descriptor,
            parent: shard,
            name: name,
            expectedMode: Self.fileMode
        )
        guard completed.sameObject(as: published), published.size == completed.size else {
            throw CodeMapRootManifestStoreError.insecureLeaf
        }
        try Self.synchronize(shard.rawValue, operation: "manifest-directory-fsync")
        if hooks.faultAction(.afterManifestDirectorySync) == .simulateProcessTermination {
            throw CodeMapRootManifestStoreError.simulatedProcessTermination(.afterManifestDirectorySync)
        }
        guard Self.rootParentIsCurrent(lockAnchor, rootURL: rootURL),
              Self.layoutIsCurrent(layout, rootURL: rootURL),
              Self.directoryIsCurrent(shard, parent: layout.manifests, name: namespace.shard),
              let committed = try? Self.validatedFileIdentity(
                  descriptor,
                  parent: shard,
                  name: name,
                  expectedMode: Self.fileMode
              ),
              committed == published
        else {
            throw CodeMapRootManifestStoreError.insecureDirectory
        }
        let readBack = try Self.readExactly(descriptor, byteCount: encoded.count)
        guard try CodeMapRootManifestCodec.decode(
            readBack,
            expectedNamespace: namespace,
            filenameDigest: name
        ) == snapshot else {
            throw CodeMapRootManifestStoreError.insecureLeaf
        }
        _ = try reconcileLocked(
            layout: layout,
            maximumEntries: nil,
            protectingDigest: name,
            incomingByteCount: 0,
            replacedByteCount: 0
        )
        if semanticUnchanged {
            return .unchanged(manifestGeneration: nextGeneration)
        }
        return existing.identity == nil
            ? .inserted(manifestGeneration: nextGeneration)
            : .replaced(manifestGeneration: nextGeneration)
    }

    func removeNamespace(_ namespace: CodeMapRootManifestNamespace) async throws -> Bool {
        let layout = try Self.openLayout(rootURL: rootURL, create: false)
        await hooks.beforeMaintenanceLock()
        try Self.lock(lockAnchor.rawValue, operation: "manifest-anchor-lock")
        defer { Self.unlock(lockAnchor.rawValue) }
        guard Self.rootParentIsCurrent(lockAnchor, rootURL: rootURL),
              Self.layoutIsCurrent(layout, rootURL: rootURL),
              let shard = try Self.openOwnedDirectory(
                  parent: layout.manifests,
                  name: namespace.shard,
                  create: false
              )
        else {
            return false
        }
        let name = namespace.storageDigestHex
        let descriptor = openat(shard.rawValue, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT { return false }
            if errno == ELOOP { throw CodeMapRootManifestStoreError.insecureLeaf }
            throw Self.ioError("remove-open")
        }
        defer { Darwin.close(descriptor) }
        _ = try Self.validatedFileIdentity(
            descriptor,
            parent: shard,
            name: name,
            expectedMode: Self.fileMode
        )
        guard Self.directoryIsCurrent(shard, parent: layout.manifests, name: namespace.shard) else {
            throw CodeMapRootManifestStoreError.insecureDirectory
        }
        let removed = try Self.secureRemove(parent: shard, name: name, descriptor: descriptor)
        let shardPruned = try Self.pruneShardIfEmpty(
            parent: layout.manifests,
            shard: shard,
            name: namespace.shard
        )
        hooks.beforeTerminalAuthorityCheck(.removeNamespace)
        guard Self.rootParentIsCurrent(lockAnchor, rootURL: rootURL),
              Self.layoutIsCurrent(layout, rootURL: rootURL),
              Self.removalPathIsCurrent(
                  layout: layout,
                  shard: shard,
                  shardName: namespace.shard,
                  name: name,
                  removed: removed,
                  shardPruned: shardPruned
              )
        else {
            throw CodeMapRootManifestStoreError.insecureDirectory
        }
        return removed
    }

    func accounting(maximumEntries: Int? = nil) async throws -> CodeMapRootManifestAccounting {
        let layout = try Self.openLayout(rootURL: rootURL, create: false)
        await hooks.beforeMaintenanceLock()
        try Self.lock(lockAnchor.rawValue, operation: "manifest-anchor-lock")
        defer { Self.unlock(lockAnchor.rawValue) }
        guard Self.rootParentIsCurrent(lockAnchor, rootURL: rootURL),
              Self.layoutIsCurrent(layout, rootURL: rootURL)
        else {
            throw CodeMapRootManifestStoreError.insecureDirectory
        }
        let scan = try scanLocked(
            layout: layout,
            maximumEntries: maximumEntries,
            mutate: false
        )
        hooks.beforeTerminalAuthorityCheck(.accounting)
        guard scanAuthorityIsCurrent(layout: layout, scan: scan) else {
            throw CodeMapRootManifestStoreError.insecureDirectory
        }
        return scan.accounting
    }

    func maintain(maximumEntries: Int? = nil) async throws -> CodeMapRootManifestMaintenanceResult {
        let layout = try Self.openLayout(rootURL: rootURL, create: false)
        await hooks.beforeMaintenanceLock()
        try Self.lock(lockAnchor.rawValue, operation: "manifest-anchor-lock")
        defer { Self.unlock(lockAnchor.rawValue) }
        guard Self.rootParentIsCurrent(lockAnchor, rootURL: rootURL),
              Self.layoutIsCurrent(layout, rootURL: rootURL)
        else {
            throw CodeMapRootManifestStoreError.insecureDirectory
        }
        let outcome = try reconcileLocked(
            layout: layout,
            maximumEntries: maximumEntries,
            protectingDigest: nil,
            incomingByteCount: 0,
            replacedByteCount: 0
        )
        hooks.beforeTerminalAuthorityCheck(.maintenance)
        guard scanAuthorityIsCurrent(layout: layout, scan: outcome.terminalScan) else {
            throw CodeMapRootManifestStoreError.insecureDirectory
        }
        return outcome.result
    }

    private func inspectExisting(
        shard: ManifestDirectoryDescriptor,
        namespace: CodeMapRootManifestNamespace,
        name: String
    ) throws -> (identity: ManifestFileIdentity?, snapshot: CodeMapRootManifestSnapshot?) {
        let descriptor = openat(shard.rawValue, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT { return (nil, nil) }
            if errno == ELOOP { throw CodeMapRootManifestStoreError.insecureLeaf }
            throw Self.ioError("existing-open")
        }
        defer { Darwin.close(descriptor) }
        let identity = try Self.validatedFileIdentity(
            descriptor,
            parent: shard,
            name: name,
            expectedMode: Self.fileMode
        )
        guard identity.size >= 0,
              identity.size <= off_t(CodeMapRootManifestCodec.maximumEncodedByteCount),
              UInt64(identity.size) <= policy.maximumManifestByteCount
        else {
            return (identity, nil)
        }
        let data = try Self.readExactly(descriptor, byteCount: Int(identity.size))
        let snapshot = try? CodeMapRootManifestCodec.decode(
            data,
            expectedNamespace: namespace,
            filenameDigest: name
        )
        return (identity, snapshot)
    }

    private func quarantineIfCurrent(
        layout: ManifestStoreLayout,
        shard: ManifestDirectoryDescriptor,
        name: String,
        descriptor: Int32
    ) async throws {
        await hooks.beforeMaintenanceLock()
        try Self.lock(lockAnchor.rawValue, operation: "manifest-anchor-lock")
        defer { Self.unlock(lockAnchor.rawValue) }
        guard Self.rootParentIsCurrent(lockAnchor, rootURL: rootURL),
              Self.layoutIsCurrent(layout, rootURL: rootURL),
              Self.directoryIsCurrent(shard, parent: layout.manifests, name: String(name.prefix(2))),
              let held = try? Self.fileIdentity(descriptor),
              let current = try Self.fileIdentityAt(parent: shard, name: name),
              current == held,
              current.isSecureRegularFile(in: shard.identity.device, expectedMode: Self.fileMode)
        else { return }
        let quarantineName = "\(name).corrupt.\(UUID().uuidString.lowercased())"
        guard renameat(shard.rawValue, name, layout.quarantine.rawValue, quarantineName) == 0 else {
            if errno == ENOENT { return }
            throw Self.ioError("quarantine-rename")
        }
        guard let moved = try Self.fileIdentityAt(parent: layout.quarantine, name: quarantineName),
              moved.sameObject(as: held),
              moved.size == held.size
        else {
            throw CodeMapRootManifestStoreError.insecureLeaf
        }
        guard Self.layoutIsCurrent(layout, rootURL: rootURL),
              Self.directoryIsCurrent(shard, parent: layout.manifests, name: String(name.prefix(2)))
        else {
            throw CodeMapRootManifestStoreError.insecureDirectory
        }
        try Self.synchronize(shard.rawValue, operation: "quarantine-source-fsync")
        try Self.synchronize(layout.quarantine.rawValue, operation: "quarantine-destination-fsync")
        guard Self.rootParentIsCurrent(lockAnchor, rootURL: rootURL),
              Self.layoutIsCurrent(layout, rootURL: rootURL),
              Self.directoryIsCurrent(shard, parent: layout.manifests, name: String(name.prefix(2)))
        else {
            throw CodeMapRootManifestStoreError.insecureDirectory
        }
    }

    private func reconcileLocked(
        layout: ManifestStoreLayout,
        maximumEntries: Int?,
        protectingDigest: String?,
        incomingByteCount: UInt64,
        replacedByteCount: UInt64
    ) throws -> ManifestReconciliationOutcome {
        guard Self.rootParentIsCurrent(lockAnchor, rootURL: rootURL),
              Self.layoutIsCurrent(layout, rootURL: rootURL)
        else {
            throw CodeMapRootManifestStoreError.insecureDirectory
        }
        var scan = try scanLocked(layout: layout, maximumEntries: maximumEntries, mutate: true)
        let projectionScan = try scanLocked(layout: layout, maximumEntries: maximumEntries, mutate: false)
        if incomingByteCount > 0 {
            hooks.beforeTerminalAuthorityCheck(.publicationQuota)
            guard scanAuthorityIsCurrent(layout: layout, scan: projectionScan) else {
                throw CodeMapRootManifestStoreError.insecureDirectory
            }
        }
        if projectionScan.accounting.hasMore,
           incomingByteCount > 0 || projectionScan.accounting.manifestCount > policy.maximumManifestCount ||
           projectionScan.accounting.manifestByteCount > policy.maximumStoreByteCount
        {
            throw CodeMapRootManifestStoreError.quotaExceeded
        }
        var projectedCount = try Self.adding(
            projectionScan.accounting.manifestCount,
            replacedByteCount == 0 && incomingByteCount > 0 ? 1 : 0
        )
        var projectedBytes = projectionScan.accounting.manifestByteCount
        projectedBytes = projectedBytes >= replacedByteCount ? projectedBytes - replacedByteCount : 0
        projectedBytes = try Self.adding(projectedBytes, incomingByteCount)

        var evicted = 0
        for entry in projectionScan.validEntries.sorted(by: { lhs, rhs in
            if lhs.lastAccessEpochSeconds != rhs.lastAccessEpochSeconds {
                return lhs.lastAccessEpochSeconds < rhs.lastAccessEpochSeconds
            }
            if lhs.manifestGeneration != rhs.manifestGeneration {
                return lhs.manifestGeneration < rhs.manifestGeneration
            }
            return lhs.digest < rhs.digest
        }) where projectedCount > policy.maximumManifestCount || projectedBytes > policy.maximumStoreByteCount {
            if entry.digest == protectingDigest { continue }
            guard let shard = try Self.openOwnedDirectory(
                parent: layout.manifests,
                name: entry.shard,
                create: false
            ) else { continue }
            let descriptor = openat(shard.rawValue, entry.digest, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { continue }
            defer { Darwin.close(descriptor) }
            guard let current = try? Self.validatedFileIdentity(
                descriptor,
                parent: shard,
                name: entry.digest,
                expectedMode: Self.fileMode
            ), current == entry.identity,
            Self.rootParentIsCurrent(lockAnchor, rootURL: rootURL),
            Self.layoutIsCurrent(layout, rootURL: rootURL),
            Self.directoryIsCurrent(shard, parent: layout.manifests, name: entry.shard)
            else { continue }
            if try Self.secureRemove(parent: shard, name: entry.digest, descriptor: descriptor) {
                projectedCount -= 1
                projectedBytes = projectedBytes >= entry.byteCount ? projectedBytes - entry.byteCount : 0
                evicted = Self.addingSaturating(evicted, 1)
            }
        }
        guard projectedCount <= policy.maximumManifestCount,
              projectedBytes <= policy.maximumStoreByteCount
        else {
            throw CodeMapRootManifestStoreError.quotaExceeded
        }

        let finalScan = try scanLocked(layout: layout, maximumEntries: maximumEntries, mutate: false)
        guard scanAuthorityIsCurrent(layout: layout, scan: finalScan) else {
            throw CodeMapRootManifestStoreError.insecureDirectory
        }
        scan.evictedManifestCount = try Self.adding(scan.evictedManifestCount, evicted)
        return ManifestReconciliationOutcome(
            result: CodeMapRootManifestMaintenanceResult(
                examinedCount: scan.examinedCount,
                removedTemporaryCount: scan.removedTemporaryCount,
                quarantinedCorruptCount: scan.quarantinedCorruptCount,
                removedQuarantineCount: scan.removedQuarantineCount,
                evictedManifestCount: scan.evictedManifestCount,
                prunedShardCount: scan.prunedShardCount,
                accounting: finalScan.accounting
            ),
            terminalScan: finalScan
        )
    }

    private func scanAuthorityIsCurrent(
        layout: ManifestStoreLayout,
        scan: ManifestScanResult
    ) -> Bool {
        guard scan.authorityComplete,
              Self.rootParentIsCurrent(lockAnchor, rootURL: rootURL),
              Self.layoutIsCurrent(layout, rootURL: rootURL)
        else {
            return false
        }
        do {
            guard let manifestsMutation = scan.manifestsMutation,
                  let quarantineMutation = scan.quarantineMutation,
                  try Self.directoryMutationIdentity(layout.manifests.rawValue) == manifestsMutation,
                  try Self.directoryMutationIdentity(layout.quarantine.rawValue) == quarantineMutation
            else {
                return false
            }
            for (name, identity) in scan.observedShards {
                guard try Self.directoryIdentityAt(parent: layout.manifests, name: name) == identity else {
                    return false
                }
            }
            for (name, mutation) in scan.observedShardMutations {
                guard let shard = try Self.openOwnedDirectory(
                    parent: layout.manifests,
                    name: name,
                    create: false
                ), try Self.directoryMutationIdentity(shard.rawValue) == mutation
                else {
                    return false
                }
            }
            for entry in scan.observedShardEntries {
                guard let shard = try Self.openOwnedDirectory(
                    parent: layout.manifests,
                    name: entry.shard,
                    create: false
                ), shard.identity == entry.shardIdentity,
                try Self.fileIdentityAt(parent: shard, name: entry.name) == entry.identity
                else {
                    return false
                }
            }
            for entry in scan.observedQuarantineEntries {
                guard try Self.fileIdentityAt(
                    parent: layout.quarantine,
                    name: entry.name
                ) == entry.identity else {
                    return false
                }
            }
            return true
        } catch {
            return false
        }
    }

    private static func removalPathIsCurrent(
        layout: ManifestStoreLayout,
        shard: ManifestDirectoryDescriptor,
        shardName: String,
        name: String,
        removed: Bool,
        shardPruned: Bool
    ) -> Bool {
        do {
            if shardPruned {
                guard removed else { return false }
                return try directoryIdentityAt(parent: layout.manifests, name: shardName) == nil
            }
            guard directoryIsCurrent(shard, parent: layout.manifests, name: shardName) else {
                return false
            }
            guard removed else { return true }
            return try fileIdentityAt(parent: shard, name: name) == nil
        } catch {
            return false
        }
    }

    private func scanLocked(
        layout: ManifestStoreLayout,
        maximumEntries: Int?,
        mutate: Bool
    ) throws -> ManifestScanResult {
        guard Self.rootParentIsCurrent(lockAnchor, rootURL: rootURL),
              Self.layoutIsCurrent(layout, rootURL: rootURL)
        else {
            throw CodeMapRootManifestStoreError.insecureDirectory
        }
        let limit = max(1, min(maximumEntries ?? policy.maintenanceEntryLimit, policy.maintenanceEntryLimit))
        var result = ManifestScanResult()
        var remaining = limit
        let shardListing = try Self.directoryEntryNames(layout.manifests, maximumCount: remaining + 1)
        result.hasMore = shardListing.truncated
        for shardName in shardListing.names {
            guard remaining > 0 else {
                result.hasMore = true
                break
            }
            guard Self.isCanonicalShard(shardName) else { continue }
            guard let shard = try Self.openOwnedDirectory(
                parent: layout.manifests,
                name: shardName,
                create: false
            ) else {
                result.authorityComplete = false
                continue
            }
            result.observedShards[shardName] = shard.identity
            let listing = try Self.directoryEntryNames(shard, maximumCount: remaining + 1)
            if listing.truncated { result.hasMore = true }
            for name in listing.names {
                guard remaining > 0 else {
                    result.hasMore = true
                    break
                }
                remaining -= 1
                result.examinedCount += 1
                if let identity = try Self.fileIdentityAt(parent: shard, name: name) {
                    result.observedShardEntries.append(
                        ManifestObservedShardEntry(
                            shard: shardName,
                            shardIdentity: shard.identity,
                            name: name,
                            identity: identity
                        )
                    )
                } else {
                    result.authorityComplete = false
                }
                if name.hasPrefix(".tmp.") {
                    result.temporaryCount += 1
                    if mutate,
                       Self.directoryIsCurrent(shard, parent: layout.manifests, name: shardName),
                       try Self.removeNamedSecureFileIfPresent(parent: shard, name: name)
                    {
                        result.removedTemporaryCount += 1
                        result.temporaryCount -= 1
                    }
                    continue
                }
                guard Self.isCanonicalDigest(name) else { continue }
                let descriptor = openat(shard.rawValue, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
                guard descriptor >= 0 else { continue }
                let inspection = inspectManifestDescriptor(
                    descriptor,
                    manifests: layout.manifests,
                    shard: shard,
                    shardName: shardName,
                    name: name
                )
                Darwin.close(descriptor)
                switch inspection {
                case let .valid(snapshot, identity):
                    result.manifestCount = try Self.adding(result.manifestCount, 1)
                    result.manifestByteCount = try Self.adding(result.manifestByteCount, UInt64(identity.size))
                    result.recordCount = Self.addingSaturating(result.recordCount, snapshot.records.count)
                    result.validEntries.append(
                        ManifestMaintenanceEntry(
                            shard: shardName,
                            digest: name,
                            byteCount: UInt64(identity.size),
                            lastAccessEpochSeconds: snapshot.lastAccessEpochSeconds,
                            manifestGeneration: snapshot.manifestGeneration,
                            identity: identity
                        )
                    )
                case .corrupt:
                    if mutate, try Self.quarantineWithoutHeldDescriptor(
                        manifests: layout.manifests,
                        shard: shard,
                        shardName: shardName,
                        name: name,
                        quarantine: layout.quarantine
                    ) {
                        result.quarantinedCorruptCount += 1
                    }
                case .insecure:
                    break
                }
            }
            result.observedShardMutations[shardName] = try Self.directoryMutationIdentity(shard.rawValue)
        }

        let quarantineListing = try Self.directoryEntryNames(layout.quarantine, maximumCount: remaining + 1)
        if quarantineListing.truncated { result.hasMore = true }
        var quarantineEntries: [(String, ManifestFileIdentity)] = []
        for name in quarantineListing.names where remaining > 0 {
            remaining -= 1
            result.examinedCount += 1
            if let identity = try Self.fileIdentityAt(parent: layout.quarantine, name: name) {
                result.observedQuarantineEntries.append(
                    ManifestObservedQuarantineEntry(name: name, identity: identity)
                )
            } else {
                result.authorityComplete = false
            }
            let descriptor = openat(
                layout.quarantine.rawValue,
                name,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
            guard descriptor >= 0 else { continue }
            let identity = try? Self.validatedFileIdentity(
                descriptor,
                parent: layout.quarantine,
                name: name,
                expectedMode: Self.fileMode
            )
            Darwin.close(descriptor)
            if let identity { quarantineEntries.append((name, identity)) }
        }
        result.quarantineCount = quarantineEntries.count
        if mutate, quarantineEntries.count > policy.maximumQuarantineCount {
            let excess = quarantineEntries.count - policy.maximumQuarantineCount
            for (name, identity) in quarantineEntries.sorted(by: { lhs, rhs in
                if lhs.1.modificationSeconds != rhs.1.modificationSeconds {
                    return lhs.1.modificationSeconds < rhs.1.modificationSeconds
                }
                return lhs.1.modificationNanoseconds < rhs.1.modificationNanoseconds
            }).prefix(excess) {
                let descriptor = openat(
                    layout.quarantine.rawValue,
                    name,
                    O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                )
                guard descriptor >= 0 else { continue }
                defer { Darwin.close(descriptor) }
                guard let current = try? Self.validatedFileIdentity(
                    descriptor,
                    parent: layout.quarantine,
                    name: name,
                    expectedMode: Self.fileMode
                ), current == identity,
                Self.rootParentIsCurrent(lockAnchor, rootURL: rootURL),
                Self.layoutIsCurrent(layout, rootURL: rootURL)
                else { continue }
                if try Self.secureRemove(parent: layout.quarantine, name: name, descriptor: descriptor) {
                    result.removedQuarantineCount += 1
                    result.quarantineCount -= 1
                }
            }
        }
        if remaining == 0 { result.hasMore = true }
        result.manifestsMutation = try Self.directoryMutationIdentity(layout.manifests.rawValue)
        result.quarantineMutation = try Self.directoryMutationIdentity(layout.quarantine.rawValue)
        return result
    }

    private func inspectManifestDescriptor(
        _ descriptor: Int32,
        manifests: ManifestDirectoryDescriptor,
        shard: ManifestDirectoryDescriptor,
        shardName: String,
        name: String
    ) -> ManifestInspection {
        do {
            guard Self.directoryIsCurrent(shard, parent: manifests, name: shardName) else {
                return .insecure
            }
            let identity = try Self.validatedFileIdentity(
                descriptor,
                parent: shard,
                name: name,
                expectedMode: Self.fileMode
            )
            guard identity.size >= 0,
                  identity.size <= off_t(CodeMapRootManifestCodec.maximumEncodedByteCount),
                  UInt64(identity.size) <= policy.maximumManifestByteCount
            else { return .corrupt }
            let data = try Self.readExactly(descriptor, byteCount: Int(identity.size))
            guard Self.directoryIsCurrent(shard, parent: manifests, name: shardName),
                  try Self.validatedFileIdentity(
                      descriptor,
                      parent: shard,
                      name: name,
                      expectedMode: Self.fileMode
                  ) == identity
            else {
                return .insecure
            }
            let snapshot = try CodeMapRootManifestCodec.decodeStored(data, filenameDigest: name)
            guard snapshot.namespace.shard == shardName,
                  snapshot.records.count <= policy.maximumRecordCountPerManifest
            else { return .corrupt }
            return .valid(snapshot, identity)
        } catch CodeMapRootManifestStoreError.insecureLeaf {
            return .insecure
        } catch {
            return .corrupt
        }
    }

    private static func openLayout(rootURL: URL, create: Bool) throws -> ManifestStoreLayout {
        let root = try openVerifiedRoot(rootURL)
        guard let namespace = try openOwnedDirectory(parent: root, name: "CodeMapRootManifests", create: create),
              let version = try openOwnedDirectory(parent: namespace, name: "v1", create: create),
              let manifests = try openOwnedDirectory(parent: version, name: "manifests", create: create),
              let quarantine = try openOwnedDirectory(parent: version, name: "quarantine", create: create)
        else {
            throw CodeMapRootManifestStoreError.insecureDirectory
        }
        let maintenance = try openMaintenanceFile(parent: version, create: create)
        return ManifestStoreLayout(
            root: root,
            namespace: namespace,
            version: version,
            manifests: manifests,
            quarantine: quarantine,
            maintenance: maintenance
        )
    }

    private static func openRootParent(_ rootURL: URL) throws -> ManifestDirectoryDescriptor {
        let components = rootURL.path.split(separator: "/").map(String.init)
        guard !components.isEmpty else { throw CodeMapRootManifestStoreError.invalidRoot }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ioError("root-anchor-open") }
        for component in components.dropLast() {
            guard isSafeComponent(component) else {
                Darwin.close(descriptor)
                throw CodeMapRootManifestStoreError.invalidRoot
            }
            let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            Darwin.close(descriptor)
            guard next >= 0 else {
                if errno == ELOOP { throw CodeMapRootManifestStoreError.insecureDirectory }
                throw ioError("root-parent-component-open")
            }
            descriptor = next
        }
        let identity = try directoryIdentity(descriptor)
        guard identity.type == mode_t(S_IFDIR) else {
            Darwin.close(descriptor)
            throw CodeMapRootManifestStoreError.insecureDirectory
        }
        return ManifestDirectoryDescriptor(rawValue: descriptor, identity: identity)
    }

    private static func rootParentIsCurrent(
        _ anchor: ManifestDirectoryDescriptor,
        rootURL: URL
    ) -> Bool {
        do {
            return try openRootParent(rootURL).identity == anchor.identity
        } catch {
            return false
        }
    }

    private static func openVerifiedRoot(_ rootURL: URL) throws -> ManifestDirectoryDescriptor {
        let components = rootURL.path.split(separator: "/").map(String.init)
        guard !components.isEmpty else { throw CodeMapRootManifestStoreError.invalidRoot }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ioError("root-anchor-open") }
        for component in components {
            guard isSafeComponent(component) else {
                Darwin.close(descriptor)
                throw CodeMapRootManifestStoreError.invalidRoot
            }
            let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            Darwin.close(descriptor)
            guard next >= 0 else {
                if errno == ELOOP { throw CodeMapRootManifestStoreError.insecureDirectory }
                throw ioError("root-component-open")
            }
            descriptor = next
        }
        let identity = try directoryIdentity(descriptor)
        guard identity.isPrivateDirectory else {
            Darwin.close(descriptor)
            throw CodeMapRootManifestStoreError.insecureDirectory
        }
        return ManifestDirectoryDescriptor(rawValue: descriptor, identity: identity)
    }

    private static func openOwnedDirectory(
        parent: ManifestDirectoryDescriptor,
        name: String,
        create: Bool
    ) throws -> ManifestDirectoryDescriptor? {
        guard isSafeComponent(name) else { throw CodeMapRootManifestStoreError.insecureDirectory }
        var created = false
        if create {
            if mkdirat(parent.rawValue, name, directoryMode) == 0 {
                created = true
            } else if errno != EEXIST {
                throw ioError("directory-create")
            }
        }
        let descriptor = openat(parent.rawValue, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            if !create, errno == ENOENT { return nil }
            if errno == ELOOP || errno == ENOTDIR { throw CodeMapRootManifestStoreError.insecureDirectory }
            throw ioError("directory-open")
        }
        let identity = try directoryIdentity(descriptor)
        guard identity.isPrivateDirectory,
              identity.device == parent.identity.device,
              let linked = try directoryIdentityAt(parent: parent, name: name),
              linked == identity
        else {
            Darwin.close(descriptor)
            throw CodeMapRootManifestStoreError.insecureDirectory
        }
        let directory = ManifestDirectoryDescriptor(rawValue: descriptor, identity: identity)
        if created {
            try synchronize(directory.rawValue, operation: "directory-fsync")
            try synchronize(parent.rawValue, operation: "directory-parent-fsync")
        }
        return directory
    }

    private static func requireOwnedDirectory(
        parent: ManifestDirectoryDescriptor,
        name: String
    ) throws -> ManifestDirectoryDescriptor {
        guard let directory = try openOwnedDirectory(parent: parent, name: name, create: true) else {
            throw CodeMapRootManifestStoreError.insecureDirectory
        }
        return directory
    }

    private static func openMaintenanceFile(
        parent: ManifestDirectoryDescriptor,
        create: Bool
    ) throws -> ManifestFileDescriptor {
        var created = false
        var descriptor = openat(
            parent.rawValue,
            "maintenance.lock",
            O_RDWR | O_NOFOLLOW | O_CLOEXEC | (create ? O_CREAT | O_EXCL : 0),
            fileMode
        )
        if descriptor < 0, create, errno == EEXIST {
            descriptor = openat(parent.rawValue, "maintenance.lock", O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        } else if descriptor >= 0, create {
            created = true
        }
        guard descriptor >= 0 else {
            if !create, errno == ENOENT { throw CodeMapRootManifestStoreError.insecureDirectory }
            if errno == ELOOP { throw CodeMapRootManifestStoreError.insecureLeaf }
            throw ioError("maintenance-open")
        }
        let identity = try validatedFileIdentity(
            descriptor,
            parent: parent,
            name: "maintenance.lock",
            expectedMode: fileMode
        )
        if created {
            try synchronize(descriptor, operation: "maintenance-file-fsync")
            try synchronize(parent.rawValue, operation: "maintenance-parent-fsync")
        }
        return ManifestFileDescriptor(rawValue: descriptor, identity: identity)
    }

    private static func validatedFileIdentity(
        _ descriptor: Int32,
        parent: ManifestDirectoryDescriptor,
        name: String,
        expectedMode: mode_t
    ) throws -> ManifestFileIdentity {
        let held = try fileIdentity(descriptor)
        guard held.isSecureRegularFile(in: parent.identity.device, expectedMode: expectedMode),
              let linked = try fileIdentityAt(parent: parent, name: name),
              linked == held
        else {
            throw CodeMapRootManifestStoreError.insecureLeaf
        }
        return held
    }

    private static func directoryIdentity(_ descriptor: Int32) throws -> ManifestDirectoryIdentity {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw ioError("directory-fstat") }
        return ManifestDirectoryIdentity(status)
    }

    private static func directoryMutationIdentity(_ descriptor: Int32) throws -> ManifestDirectoryMutationIdentity {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw ioError("directory-mutation-fstat") }
        return ManifestDirectoryMutationIdentity(status)
    }

    private static func directoryIdentityAt(
        parent: ManifestDirectoryDescriptor,
        name: String
    ) throws -> ManifestDirectoryIdentity? {
        var status = stat()
        if fstatat(parent.rawValue, name, &status, AT_SYMLINK_NOFOLLOW) == 0 {
            return ManifestDirectoryIdentity(status)
        }
        if errno == ENOENT { return nil }
        throw ioError("directory-fstatat")
    }

    private static func directoryIsCurrent(
        _ directory: ManifestDirectoryDescriptor,
        parent: ManifestDirectoryDescriptor,
        name: String
    ) -> Bool {
        guard let current = try? directoryIdentityAt(parent: parent, name: name) else { return false }
        return current == directory.identity && current.isPrivateDirectory
    }

    private static func fileIdentity(_ descriptor: Int32) throws -> ManifestFileIdentity {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw ioError("file-fstat") }
        return ManifestFileIdentity(status)
    }

    private static func fileIdentityAt(
        parent: ManifestDirectoryDescriptor,
        name: String
    ) throws -> ManifestFileIdentity? {
        var status = stat()
        if fstatat(parent.rawValue, name, &status, AT_SYMLINK_NOFOLLOW) == 0 {
            return ManifestFileIdentity(status)
        }
        if errno == ENOENT { return nil }
        throw ioError("file-fstatat")
    }

    private static func layoutIsCurrent(_ layout: ManifestStoreLayout, rootURL: URL) -> Bool {
        do {
            let current = try openLayout(rootURL: rootURL, create: false)
            return layout.root.identity == current.root.identity &&
                layout.namespace.identity == current.namespace.identity &&
                layout.version.identity == current.version.identity &&
                layout.manifests.identity == current.manifests.identity &&
                layout.quarantine.identity == current.quarantine.identity &&
                layout.maintenance.identity.sameObject(as: current.maintenance.identity)
        } catch {
            return false
        }
    }

    private static func quarantineWithoutHeldDescriptor(
        manifests: ManifestDirectoryDescriptor,
        shard: ManifestDirectoryDescriptor,
        shardName: String,
        name: String,
        quarantine: ManifestDirectoryDescriptor
    ) throws -> Bool {
        guard directoryIsCurrent(shard, parent: manifests, name: shardName),
              let identity = try fileIdentityAt(parent: shard, name: name),
              identity.isSecureRegularFile(in: shard.identity.device, expectedMode: fileMode)
        else { return false }
        let quarantineName = "\(name).corrupt.\(UUID().uuidString.lowercased())"
        guard renameat(shard.rawValue, name, quarantine.rawValue, quarantineName) == 0 else {
            if errno == ENOENT { return false }
            throw ioError("maintenance-quarantine")
        }
        guard let moved = try fileIdentityAt(parent: quarantine, name: quarantineName),
              moved.sameObject(as: identity),
              moved.size == identity.size,
              directoryIsCurrent(shard, parent: manifests, name: shardName)
        else {
            throw CodeMapRootManifestStoreError.insecureLeaf
        }
        try synchronize(shard.rawValue, operation: "maintenance-quarantine-source-fsync")
        try synchronize(quarantine.rawValue, operation: "maintenance-quarantine-destination-fsync")
        return true
    }

    private static func removeNamedSecureFileIfPresent(
        parent: ManifestDirectoryDescriptor,
        name: String
    ) throws -> Bool {
        let descriptor = openat(parent.rawValue, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 { return false }
        defer { Darwin.close(descriptor) }
        _ = try validatedFileIdentity(descriptor, parent: parent, name: name, expectedMode: fileMode)
        return try secureRemove(parent: parent, name: name, descriptor: descriptor)
    }

    private static func secureRemove(
        parent: ManifestDirectoryDescriptor,
        name: String,
        descriptor: Int32
    ) throws -> Bool {
        do {
            return try CodeMapSecureFileRemoval.remove(
                parentDescriptor: parent.rawValue,
                expectedDevice: parent.identity.device,
                name: name,
                heldDescriptor: descriptor
            )
        } catch CodeMapSecureFileRemovalError.insecureEntry {
            throw CodeMapRootManifestStoreError.insecureLeaf
        } catch let CodeMapSecureFileRemovalError.ioFailure(operation, code) {
            throw CodeMapRootManifestStoreError.ioFailure(operation: operation, code: code)
        }
    }

    private static func pruneShardIfEmpty(
        parent: ManifestDirectoryDescriptor,
        shard: ManifestDirectoryDescriptor,
        name: String
    ) throws -> Bool {
        guard directoryIsCurrent(shard, parent: parent, name: name),
              try directoryEntryNames(shard, maximumCount: 1).names.isEmpty
        else { return false }
        if unlinkat(parent.rawValue, name, AT_REMOVEDIR) == 0 {
            try synchronize(parent.rawValue, operation: "shard-prune-parent-fsync")
            return true
        } else if errno != ENOENT, errno != ENOTEMPTY {
            throw ioError("shard-prune")
        }
        return false
    }

    private static func directoryEntryNames(
        _ directory: ManifestDirectoryDescriptor,
        maximumCount: Int
    ) throws -> (names: [String], truncated: Bool) {
        let duplicate = dup(directory.rawValue)
        guard duplicate >= 0 else { throw ioError("directory-dup") }
        guard let stream = fdopendir(duplicate) else {
            Darwin.close(duplicate)
            throw ioError("directory-open-stream")
        }
        defer { closedir(stream) }
        rewinddir(stream)
        var names: [String] = []
        var truncated = false
        errno = 0
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            if names.count >= maximumCount {
                truncated = true
                break
            }
            names.append(name)
        }
        guard errno == 0 else { throw ioError("directory-read") }
        return (names.sorted(), truncated)
    }

    private static func readExactly(_ descriptor: Int32, byteCount: Int) throws -> Data {
        var data = Data(count: byteCount)
        var completed = 0
        try data.withUnsafeMutableBytes { bytes in
            while completed < byteCount {
                let count = pread(
                    descriptor,
                    bytes.baseAddress!.advanced(by: completed),
                    byteCount - completed,
                    off_t(completed)
                )
                if count > 0 {
                    completed += count
                } else if count == 0 {
                    throw CodeMapRootManifestModelError.corruptRecord
                } else if errno != EINTR {
                    throw ioError("manifest-read")
                }
            }
        }
        return data
    }

    private static func writeAll(_ descriptor: Int32, data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var completed = 0
            while completed < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: completed),
                    bytes.count - completed
                )
                if count > 0 {
                    completed += count
                } else if errno != EINTR {
                    throw ioError("manifest-write")
                }
            }
        }
    }

    private static func synchronize(_ descriptor: Int32, operation: String) throws {
        while fsync(descriptor) != 0 {
            guard errno == EINTR else { throw ioError(operation) }
        }
    }

    private static func lock(_ descriptor: Int32, operation: String) throws {
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else { throw ioError(operation) }
        }
    }

    private static func unlock(_ descriptor: Int32) {
        while flock(descriptor, LOCK_UN) != 0, errno == EINTR {}
    }

    private static func adding(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw CodeMapRootManifestStoreError.quotaExceeded }
        return result
    }

    private static func addingSaturating(_ lhs: Int, _ rhs: Int) -> Int {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : result
    }

    private static func adding(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw CodeMapRootManifestStoreError.quotaExceeded }
        return result
    }

    private static func isCanonicalShard(_ value: String) -> Bool {
        value.utf8.count == 2 && value.utf8.allSatisfy(isLowercaseHex)
    }

    private static func isCanonicalDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy(isLowercaseHex)
    }

    private static func isLowercaseHex(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(byte) ||
            (UInt8(ascii: "a") ... UInt8(ascii: "f")).contains(byte)
    }

    private static func isSafeComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\0")
    }

    private static func ioError(_ operation: String) -> CodeMapRootManifestStoreError {
        CodeMapRootManifestStoreError.ioFailure(operation: operation, code: errno)
    }
}

private final class ManifestDirectoryDescriptor {
    let rawValue: Int32
    let identity: ManifestDirectoryIdentity

    init(rawValue: Int32, identity: ManifestDirectoryIdentity) {
        self.rawValue = rawValue
        self.identity = identity
    }

    deinit { Darwin.close(rawValue) }
}

private final class ManifestFileDescriptor {
    let rawValue: Int32
    let identity: ManifestFileIdentity

    init(rawValue: Int32, identity: ManifestFileIdentity) {
        self.rawValue = rawValue
        self.identity = identity
    }

    deinit { Darwin.close(rawValue) }
}

private struct ManifestStoreLayout {
    let root: ManifestDirectoryDescriptor
    let namespace: ManifestDirectoryDescriptor
    let version: ManifestDirectoryDescriptor
    let manifests: ManifestDirectoryDescriptor
    let quarantine: ManifestDirectoryDescriptor
    let maintenance: ManifestFileDescriptor
}

private struct ManifestDirectoryIdentity: Equatable {
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

    var isPrivateDirectory: Bool {
        type == mode_t(S_IFDIR) && owner == getuid() && permissions == mode_t(0o700)
    }
}

private struct ManifestDirectoryMutationIdentity: Equatable {
    let linkCount: nlink_t
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let statusChangeSeconds: Int64
    let statusChangeNanoseconds: Int64

    init(_ status: stat) {
        linkCount = status.st_nlink
        modificationSeconds = Int64(status.st_mtimespec.tv_sec)
        modificationNanoseconds = Int64(status.st_mtimespec.tv_nsec)
        statusChangeSeconds = Int64(status.st_ctimespec.tv_sec)
        statusChangeNanoseconds = Int64(status.st_ctimespec.tv_nsec)
    }
}

private struct ManifestFileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
    let owner: uid_t
    let type: mode_t
    let permissions: mode_t
    let linkCount: nlink_t
    let size: off_t
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let statusChangeSeconds: Int64
    let statusChangeNanoseconds: Int64

    init(_ status: stat) {
        device = status.st_dev
        inode = status.st_ino
        owner = status.st_uid
        type = status.st_mode & mode_t(S_IFMT)
        permissions = status.st_mode & mode_t(0o777)
        linkCount = status.st_nlink
        size = status.st_size
        modificationSeconds = Int64(status.st_mtimespec.tv_sec)
        modificationNanoseconds = Int64(status.st_mtimespec.tv_nsec)
        statusChangeSeconds = Int64(status.st_ctimespec.tv_sec)
        statusChangeNanoseconds = Int64(status.st_ctimespec.tv_nsec)
    }

    func sameObject(as other: ManifestFileIdentity) -> Bool {
        device == other.device && inode == other.inode
    }

    func isSecureRegularFile(in expectedDevice: dev_t, expectedMode: mode_t) -> Bool {
        type == mode_t(S_IFREG) &&
            owner == getuid() &&
            permissions == expectedMode &&
            linkCount == 1 &&
            device == expectedDevice
    }
}

private struct ManifestMaintenanceEntry {
    let shard: String
    let digest: String
    let byteCount: UInt64
    let lastAccessEpochSeconds: UInt64
    let manifestGeneration: UInt64
    let identity: ManifestFileIdentity
}

private struct ManifestPendingAccessRefresh {
    let snapshot: CodeMapRootManifestSnapshot
    let accessEpochSeconds: UInt64
}

private struct ManifestObservedShardEntry {
    let shard: String
    let shardIdentity: ManifestDirectoryIdentity
    let name: String
    let identity: ManifestFileIdentity
}

private struct ManifestObservedQuarantineEntry {
    let name: String
    let identity: ManifestFileIdentity
}

private struct ManifestReconciliationOutcome {
    let result: CodeMapRootManifestMaintenanceResult
    let terminalScan: ManifestScanResult
}

private enum ManifestInspection {
    case valid(CodeMapRootManifestSnapshot, ManifestFileIdentity)
    case corrupt
    case insecure
}

private struct ManifestScanResult {
    var examinedCount = 0
    var removedTemporaryCount = 0
    var quarantinedCorruptCount = 0
    var removedQuarantineCount = 0
    var evictedManifestCount = 0
    var prunedShardCount = 0
    var manifestCount = 0
    var manifestByteCount: UInt64 = 0
    var recordCount = 0
    var temporaryCount = 0
    var quarantineCount = 0
    var hasMore = false
    var authorityComplete = true
    var observedShards: [String: ManifestDirectoryIdentity] = [:]
    var observedShardMutations: [String: ManifestDirectoryMutationIdentity] = [:]
    var observedShardEntries: [ManifestObservedShardEntry] = []
    var observedQuarantineEntries: [ManifestObservedQuarantineEntry] = []
    var validEntries: [ManifestMaintenanceEntry] = []
    var manifestsMutation: ManifestDirectoryMutationIdentity?
    var quarantineMutation: ManifestDirectoryMutationIdentity?

    var accounting: CodeMapRootManifestAccounting {
        CodeMapRootManifestAccounting(
            manifestCount: manifestCount,
            manifestByteCount: manifestByteCount,
            recordCount: recordCount,
            temporaryCount: temporaryCount,
            quarantineCount: quarantineCount,
            hasMore: hasMore
        )
    }
}

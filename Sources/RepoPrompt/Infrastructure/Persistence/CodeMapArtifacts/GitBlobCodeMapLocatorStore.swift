import Darwin
import Foundation

enum GitBlobCodeMapLocatorStoreError: Error, Equatable {
    case invalidRoot
    case insecureDirectory
    case insecureLeaf
    case integrityCollision
    case quotaExceeded
    case ioFailure(operation: String, code: Int32)
}

struct GitBlobCodeMapLocatorStorePolicy: Equatable {
    let maximumRecordCount: Int
    let maximumByteCount: UInt64
    let maintenanceEntryLimit: Int

    static let `default` = GitBlobCodeMapLocatorStorePolicy(
        maximumRecordCount: 4096,
        maximumByteCount: 16 * 1024 * 1024,
        maintenanceEntryLimit: 8192
    )

    init(maximumRecordCount: Int, maximumByteCount: UInt64, maintenanceEntryLimit: Int) {
        precondition(maximumRecordCount > 0 && maximumByteCount > 0 && maintenanceEntryLimit > 0)
        self.maximumRecordCount = maximumRecordCount
        self.maximumByteCount = maximumByteCount
        self.maintenanceEntryLimit = maintenanceEntryLimit
    }
}

struct GitBlobCodeMapLocatorMaintenanceResult: Equatable {
    let examinedCount: Int
    let removedTemporaryCount: Int
    let removedCorruptCount: Int
    let evictedCount: Int
    let prunedShardCount: Int
    let remainingRecordCount: Int
    let remainingByteCount: UInt64
    let hasMore: Bool
}

struct GitBlobCodeMapLocatorStoreHooks {
    var afterReadAdmission: @Sendable () async -> Void
    var beforePublish: @Sendable () async -> Void
    var beforeMaintenanceLock: @Sendable () async -> Void

    static let none = GitBlobCodeMapLocatorStoreHooks(
        afterReadAdmission: {},
        beforePublish: {}
    )

    init(
        afterReadAdmission: @escaping @Sendable () async -> Void,
        beforePublish: @escaping @Sendable () async -> Void,
        beforeMaintenanceLock: @escaping @Sendable () async -> Void = {}
    ) {
        self.afterReadAdmission = afterReadAdmission
        self.beforePublish = beforePublish
        self.beforeMaintenanceLock = beforeMaintenanceLock
    }
}

enum GitBlobCodeMapLocatorReadResult: Equatable {
    case miss
    case hit(CodeMapArtifactKey)
    case corrupt
}

enum GitBlobCodeMapLocatorWriteResult: Equatable {
    case inserted
    case alreadyPresent
}

/// Inert persistence for Git-blob-to-artifact associations.
///
/// This owner is deliberately independent of `CodeMapArtifactStore` and is not consulted by
/// legacy scanner implementations or workspace consumers. An association only becomes visible after a
/// checksummed, canonical record has been atomically published under its path-free identity digest.
actor GitBlobCodeMapLocatorStore {
    private static let directoryMode = mode_t(0o700)
    private static let fileMode = mode_t(0o600)

    nonisolated let rootURL: URL
    private let policy: GitBlobCodeMapLocatorStorePolicy
    private let hooks: GitBlobCodeMapLocatorStoreHooks

    init(
        rootURL: URL,
        policy: GitBlobCodeMapLocatorStorePolicy = .default,
        hooks: GitBlobCodeMapLocatorStoreHooks = .none
    ) throws {
        guard rootURL.isFileURL,
              rootURL.path.hasPrefix("/"),
              rootURL.path != "/",
              !rootURL.path.contains("//"),
              rootURL.path.split(separator: "/").allSatisfy({ Self.isSafeComponent(String($0)) })
        else {
            throw GitBlobCodeMapLocatorStoreError.invalidRoot
        }
        self.rootURL = rootURL
        self.policy = policy
        self.hooks = hooks
        _ = try Self.openLayout(rootURL: rootURL)
    }

    nonisolated func recordURL(for identity: GitBlobCodeMapLocatorIdentity) -> URL {
        rootURL
            .appendingPathComponent("GitBlobCodeMapLocators", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent("records", isDirectory: true)
            .appendingPathComponent(identity.shard, isDirectory: true)
            .appendingPathComponent(identity.storageDigestHex, isDirectory: false)
    }

    func read(identity: GitBlobCodeMapLocatorIdentity) async throws -> GitBlobCodeMapLocatorReadResult {
        let layout = try Self.openLayout(rootURL: rootURL)
        guard let shard = try Self.openOwnedDirectory(
            parent: layout.records,
            name: identity.shard,
            create: false
        ) else {
            return .miss
        }
        let name = identity.storageDigestHex
        let descriptor = openat(shard.rawValue, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT { return .miss }
            if errno == ELOOP { throw GitBlobCodeMapLocatorStoreError.insecureLeaf }
            throw Self.ioError("record-open")
        }
        defer { Darwin.close(descriptor) }

        let before: GitBlobLocatorFileIdentity
        switch try Self.admitFileForRead(descriptor, parent: shard, name: name) {
        case let .admitted(identity): before = identity
        case .missing: return .miss
        case .mutated: return .corrupt
        }
        guard before.size >= 0,
              before.size <= off_t(GitBlobCodeMapLocatorRecordCodec.maximumRecordByteCount)
        else {
            return .corrupt
        }
        await hooks.afterReadAdmission()
        let data: Data
        do {
            data = try Self.readExactly(descriptor, byteCount: Int(before.size))
        } catch is GitBlobCodeMapLocatorModelError {
            return .corrupt
        }
        switch try Self.validateFileAfterRead(descriptor, parent: shard, name: name) {
        case let .admitted(after) where before == after:
            break
        case .missing:
            return .miss
        case .admitted, .mutated:
            return .corrupt
        }
        do {
            return try .hit(
                GitBlobCodeMapLocatorRecordCodec.decode(
                    data,
                    expectedIdentity: identity,
                    filenameDigest: name
                )
            )
        } catch is GitBlobCodeMapLocatorModelError {
            return .corrupt
        }
    }

    func write(
        association: VerifiedGitBlobCodeMapLocatorAssociation
    ) async throws -> GitBlobCodeMapLocatorWriteResult {
        let identity = association.identity
        let artifactKey = association.artifactKey
        let record = try GitBlobCodeMapLocatorRecordCodec.encode(association: association)
        let name = identity.storageDigestHex
        await hooks.beforePublish()
        return try await Self.withMaintenanceLock(
            rootURL: rootURL,
            beforeLock: hooks.beforeMaintenanceLock
        ) { layout in
            let shard = try Self.requireOwnedDirectory(parent: layout.records, name: identity.shard)
            let temporaryName = ".tmp.\(getpid()).\(UUID().uuidString.lowercased())"
            let descriptor = openat(
                shard.rawValue,
                temporaryName,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                Self.fileMode
            )
            guard descriptor >= 0 else { throw Self.ioError("temporary-open") }
            var temporaryExists = true
            defer {
                Darwin.close(descriptor)
                if temporaryExists {
                    _ = unlinkat(shard.rawValue, temporaryName, 0)
                }
            }

            let initialIdentity = try Self.validatedFileIdentity(
                descriptor,
                parent: shard,
                name: temporaryName,
                expectedMode: Self.fileMode
            )
            guard initialIdentity.size == 0 else {
                throw GitBlobCodeMapLocatorStoreError.insecureLeaf
            }
            try Self.writeAll(descriptor, data: record)
            try Self.synchronize(descriptor, operation: "temporary-fsync")
            let finalIdentity = try Self.validatedFileIdentity(
                descriptor,
                parent: shard,
                name: temporaryName,
                expectedMode: Self.fileMode
            )
            guard initialIdentity.sameObject(as: finalIdentity), finalIdentity.size == off_t(record.count) else {
                throw GitBlobCodeMapLocatorStoreError.insecureLeaf
            }

            if renameatx_np(
                shard.rawValue,
                temporaryName,
                shard.rawValue,
                name,
                UInt32(RENAME_EXCL)
            ) == 0 {
                temporaryExists = false
                let publishedIdentity = try Self.validatedFileIdentity(
                    descriptor,
                    parent: shard,
                    name: name,
                    expectedMode: Self.fileMode
                )
                guard publishedIdentity.sameObject(as: finalIdentity), publishedIdentity.size == finalIdentity.size else {
                    throw GitBlobCodeMapLocatorStoreError.insecureLeaf
                }
                try Self.synchronize(shard.rawValue, operation: "record-directory-fsync")
                guard try Self.recordMatches(
                    identity: identity,
                    artifactKey: artifactKey,
                    shard: shard,
                    name: name
                ) else {
                    throw GitBlobCodeMapLocatorStoreError.integrityCollision
                }
                do {
                    _ = try maintainLocked(layout: layout, maximumEntries: nil, protecting: name)
                } catch GitBlobCodeMapLocatorStoreError.quotaExceeded {
                    _ = try Self.secureRemove(parent: shard, name: name, descriptor: descriptor)
                    throw GitBlobCodeMapLocatorStoreError.quotaExceeded
                }
                return .inserted
            }

            let renameError = errno
            guard renameError == EEXIST else {
                errno = renameError
                throw Self.ioError("record-publish")
            }
            if try Self.recordMatches(
                identity: identity,
                artifactKey: artifactKey,
                shard: shard,
                name: name
            ) {
                guard unlinkat(shard.rawValue, temporaryName, 0) == 0 else {
                    throw Self.ioError("temporary-unlink")
                }
                temporaryExists = false
                _ = try maintainLocked(layout: layout, maximumEntries: nil, protecting: name)
                return .alreadyPresent
            }

            let existingDescriptor = openat(
                shard.rawValue,
                name,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
            guard existingDescriptor >= 0 else {
                if errno == ELOOP { throw GitBlobCodeMapLocatorStoreError.insecureLeaf }
                throw Self.ioError("replacement-open")
            }
            defer { Darwin.close(existingDescriptor) }
            let existingIdentity = try Self.validatedFileIdentity(
                existingDescriptor,
                parent: shard,
                name: name,
                expectedMode: Self.fileMode
            )

            guard renameatx_np(
                shard.rawValue,
                temporaryName,
                shard.rawValue,
                name,
                UInt32(RENAME_SWAP)
            ) == 0 else {
                throw Self.ioError("record-repair-swap")
            }
            temporaryExists = false
            var displacedExists = true
            defer {
                if displacedExists {
                    _ = try? Self.secureRemove(
                        parent: shard,
                        name: temporaryName,
                        descriptor: existingDescriptor
                    )
                }
            }

            let publishedIdentity = try Self.validatedFileIdentity(
                descriptor,
                parent: shard,
                name: name,
                expectedMode: Self.fileMode
            )
            guard publishedIdentity.sameObject(as: finalIdentity),
                  publishedIdentity.size == finalIdentity.size
            else {
                throw GitBlobCodeMapLocatorStoreError.insecureLeaf
            }
            let displacedIdentity = try Self.validatedFileIdentity(
                existingDescriptor,
                parent: shard,
                name: temporaryName,
                expectedMode: Self.fileMode
            )
            guard displacedIdentity.sameObject(as: existingIdentity),
                  displacedIdentity.size == existingIdentity.size
            else {
                throw GitBlobCodeMapLocatorStoreError.insecureLeaf
            }
            try Self.synchronize(shard.rawValue, operation: "record-repair-swap-directory-fsync")
            guard try Self.recordMatches(
                identity: identity,
                artifactKey: artifactKey,
                shard: shard,
                name: name
            ) else {
                throw GitBlobCodeMapLocatorStoreError.integrityCollision
            }
            guard try Self.secureRemove(
                parent: shard,
                name: temporaryName,
                descriptor: existingDescriptor
            ) else {
                throw GitBlobCodeMapLocatorStoreError.insecureLeaf
            }
            displacedExists = false
            try Self.synchronize(shard.rawValue, operation: "record-repair-cleanup-directory-fsync")
            _ = try maintainLocked(layout: layout, maximumEntries: nil, protecting: name)
            return .inserted
        }
    }

    func maintain(maximumEntries: Int? = nil) throws -> GitBlobCodeMapLocatorMaintenanceResult {
        try Self.withMaintenanceLock(rootURL: rootURL) { layout in
            try maintainLocked(layout: layout, maximumEntries: maximumEntries, protecting: nil)
        }
    }

    private func maintainLocked(
        layout: GitBlobLocatorStoreLayout,
        maximumEntries: Int?,
        protecting protectedDigest: String?
    ) throws -> GitBlobCodeMapLocatorMaintenanceResult {
        let limit = max(1, min(maximumEntries ?? policy.maintenanceEntryLimit, policy.maintenanceEntryLimit))
        var examined = 0
        var removedTemporary = 0
        var removedCorrupt = 0
        var evicted = 0
        var pruned = 0
        var hasMore = false
        var entries: [GitBlobLocatorMaintenanceEntry] = []
        var touchedShards = Set<String>()

        let shardListing = try Self.directoryEntryNames(layout.records, maximumCount: limit + 1)
        hasMore = shardListing.truncated
        shardLoop: for shardName in shardListing.names {
            guard examined < limit else {
                hasMore = true
                break
            }
            guard Self.isCanonicalShard(shardName),
                  let shard = try Self.openOwnedDirectory(parent: layout.records, name: shardName, create: false)
            else { continue }
            let remaining = limit - examined
            let fileListing = try Self.directoryEntryNames(shard, maximumCount: remaining + 1)
            if fileListing.truncated { hasMore = true }
            for name in fileListing.names {
                guard examined < limit else {
                    hasMore = true
                    break shardLoop
                }
                examined += 1
                switch try Self.inspectMaintenanceRecord(
                    parent: shard,
                    shardName: shardName,
                    name: name
                ) {
                case .ignored:
                    continue
                case .removedTemporary:
                    removedTemporary += 1
                    touchedShards.insert(shardName)
                case .removedCorrupt:
                    removedCorrupt += 1
                    touchedShards.insert(shardName)
                case let .retained(identity):
                    entries.append(GitBlobLocatorMaintenanceEntry(
                        shard: shardName,
                        name: name,
                        byteCount: UInt64(identity.size),
                        modificationSeconds: identity.modificationSeconds,
                        modificationNanoseconds: identity.modificationNanoseconds
                    ))
                }
            }
        }

        var remainingCount = entries.count
        var remainingBytes = entries.reduce(UInt64(0)) { $0 &+ $1.byteCount }
        let ordered = entries.sorted {
            if $0.modificationSeconds != $1.modificationSeconds {
                return $0.modificationSeconds < $1.modificationSeconds
            }
            if $0.modificationNanoseconds != $1.modificationNanoseconds {
                return $0.modificationNanoseconds < $1.modificationNanoseconds
            }
            return $0.name < $1.name
        }
        for entry in ordered where remainingCount > policy.maximumRecordCount || remainingBytes > policy.maximumByteCount {
            guard entry.name != protectedDigest,
                  let shard = try Self.openOwnedDirectory(parent: layout.records, name: entry.shard, create: false)
            else { continue }
            if try Self.secureRemove(parent: shard, name: entry.name, descriptor: nil) {
                remainingCount -= 1
                remainingBytes = remainingBytes >= entry.byteCount ? remainingBytes - entry.byteCount : 0
                evicted += 1
                touchedShards.insert(entry.shard)
            }
        }
        guard remainingCount <= policy.maximumRecordCount,
              remainingBytes <= policy.maximumByteCount,
              !(hasMore && maximumEntries == nil)
        else {
            throw GitBlobCodeMapLocatorStoreError.quotaExceeded
        }

        for shardName in touchedShards.sorted() {
            if unlinkat(layout.records.rawValue, shardName, AT_REMOVEDIR) == 0 {
                pruned += 1
            } else if errno != ENOTEMPTY, errno != ENOENT {
                throw Self.ioError("maintenance-shard-prune")
            }
        }
        return GitBlobCodeMapLocatorMaintenanceResult(
            examinedCount: examined,
            removedTemporaryCount: removedTemporary,
            removedCorruptCount: removedCorrupt,
            evictedCount: evicted,
            prunedShardCount: pruned,
            remainingRecordCount: remainingCount,
            remainingByteCount: remainingBytes,
            hasMore: hasMore
        )
    }

    private static func recordMatches(
        identity: GitBlobCodeMapLocatorIdentity,
        artifactKey: CodeMapArtifactKey,
        shard: GitBlobLocatorDirectoryDescriptor,
        name: String
    ) throws -> Bool {
        let descriptor = openat(shard.rawValue, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT { return false }
            if errno == ELOOP { throw GitBlobCodeMapLocatorStoreError.insecureLeaf }
            throw Self.ioError("record-open")
        }
        defer { Darwin.close(descriptor) }

        let before: GitBlobLocatorFileIdentity
        switch try Self.admitFileForRead(descriptor, parent: shard, name: name) {
        case let .admitted(identity): before = identity
        case .missing, .mutated: return false
        }
        guard before.size >= 0,
              before.size <= off_t(GitBlobCodeMapLocatorRecordCodec.maximumRecordByteCount)
        else {
            return false
        }
        let data: Data
        do {
            data = try Self.readExactly(descriptor, byteCount: Int(before.size))
        } catch is GitBlobCodeMapLocatorModelError {
            return false
        }
        switch try Self.validateFileAfterRead(descriptor, parent: shard, name: name) {
        case let .admitted(after) where before == after:
            break
        case .admitted, .missing, .mutated:
            return false
        }
        do {
            let existingKey = try GitBlobCodeMapLocatorRecordCodec.decode(
                data,
                expectedIdentity: identity,
                filenameDigest: name
            )
            return existingKey == artifactKey
        } catch is GitBlobCodeMapLocatorModelError {
            return false
        }
    }

    private static func inspectMaintenanceRecord(
        parent: GitBlobLocatorDirectoryDescriptor,
        shardName: String,
        name: String
    ) throws -> GitBlobLocatorMaintenanceRecordInspection {
        let descriptor = openat(
            parent.rawValue,
            name,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        if descriptor < 0 {
            if errno == ENOENT || errno == ELOOP { return .ignored }
            throw Self.ioError("maintenance-record-open")
        }
        defer { Darwin.close(descriptor) }

        let identity: GitBlobLocatorFileIdentity
        do {
            identity = try Self.validatedFileIdentity(
                descriptor,
                parent: parent,
                name: name,
                expectedMode: Self.fileMode
            )
        } catch GitBlobCodeMapLocatorStoreError.insecureLeaf {
            return .ignored
        }
        let isTemporary = name.hasPrefix(".tmp.") || name.hasPrefix(".delete.")
        var isCorrupt = !Self.isCanonicalDigest(name) || !name.hasPrefix(shardName)
        if !isTemporary, !isCorrupt {
            if identity.size < 0 || identity.size > off_t(GitBlobCodeMapLocatorRecordCodec.maximumRecordByteCount) {
                isCorrupt = true
            } else {
                do {
                    let data = try Self.readExactly(descriptor, byteCount: Int(identity.size))
                    _ = try GitBlobCodeMapLocatorRecordCodec.decodeStored(data, filenameDigest: name)
                } catch {
                    isCorrupt = true
                }
            }
        }
        guard isTemporary || isCorrupt else { return .retained(identity) }
        guard try Self.secureRemove(parent: parent, name: name, descriptor: descriptor) else {
            return .ignored
        }
        return isTemporary ? .removedTemporary : .removedCorrupt
    }

    private static func openLayout(rootURL: URL) throws -> GitBlobLocatorStoreLayout {
        let root = try openVerifiedRoot(at: rootURL)
        let namespace = try requireOwnedDirectory(parent: root, name: "GitBlobCodeMapLocators")
        let version = try requireOwnedDirectory(parent: namespace, name: "v1")
        let records = try requireOwnedDirectory(parent: version, name: "records")
        try ensureMaintenanceLock(parent: version)
        return GitBlobLocatorStoreLayout(root: root, namespace: namespace, version: version, records: records)
    }

    private static func openExistingLayout(rootURL: URL) throws -> GitBlobLocatorStoreLayout? {
        let root = try openVerifiedRoot(at: rootURL)
        guard let namespace = try openOwnedDirectory(
            parent: root,
            name: "GitBlobCodeMapLocators",
            create: false
        ) else { return nil }
        guard let version = try openOwnedDirectory(parent: namespace, name: "v1", create: false) else {
            return nil
        }
        guard let records = try openOwnedDirectory(parent: version, name: "records", create: false) else {
            return nil
        }
        return GitBlobLocatorStoreLayout(root: root, namespace: namespace, version: version, records: records)
    }

    private static func ensureMaintenanceLock(parent: GitBlobLocatorDirectoryDescriptor) throws {
        let name = ".maintenance.lock"
        var created = false
        var descriptor = openat(
            parent.rawValue,
            name,
            O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            Self.fileMode
        )
        if descriptor >= 0 {
            created = true
        } else if errno == EEXIST {
            descriptor = openat(parent.rawValue, name, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw ioError("maintenance-lock-open") }
        defer { Darwin.close(descriptor) }
        if created, fchmod(descriptor, Self.fileMode) != 0 {
            throw ioError("maintenance-lock-mode")
        }
        _ = try validatedFileIdentity(
            descriptor,
            parent: parent,
            name: name,
            expectedMode: Self.fileMode
        )
        if created {
            try synchronize(parent.rawValue, operation: "maintenance-lock-directory-fsync")
        }
    }

    private static func requireOwnedDirectory(
        parent: GitBlobLocatorDirectoryDescriptor,
        name: String
    ) throws -> GitBlobLocatorDirectoryDescriptor {
        guard let directory = try openOwnedDirectory(parent: parent, name: name, create: true) else {
            throw GitBlobCodeMapLocatorStoreError.insecureDirectory
        }
        return directory
    }

    private static func openOwnedDirectory(
        parent: GitBlobLocatorDirectoryDescriptor,
        name: String,
        create: Bool
    ) throws -> GitBlobLocatorDirectoryDescriptor? {
        guard isSafeComponent(name) else {
            throw GitBlobCodeMapLocatorStoreError.insecureDirectory
        }
        var descriptor = openat(parent.rawValue, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0, errno == ENOENT, create {
            if mkdirat(parent.rawValue, name, directoryMode) != 0, errno != EEXIST {
                throw ioError("directory-create")
            }
            descriptor = openat(parent.rawValue, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        if descriptor < 0 {
            if errno == ENOENT, !create { return nil }
            if errno == ELOOP { throw GitBlobCodeMapLocatorStoreError.insecureDirectory }
            throw ioError("directory-open")
        }
        do {
            return try validatedDirectoryDescriptor(
                descriptor,
                parent: parent,
                name: name,
                expectedOwner: getuid(),
                expectedMode: directoryMode,
                requireSameDevice: true
            )
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func openVerifiedRoot(at url: URL) throws -> GitBlobLocatorDirectoryDescriptor {
        let components = url.path.split(separator: "/").map(String.init)
        guard !components.isEmpty else { throw GitBlobCodeMapLocatorStoreError.invalidRoot }
        let descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ioError("root-open") }
        var current = try descriptorForAlreadyOpenDirectory(descriptor)
        for (index, component) in components.enumerated() {
            guard isSafeComponent(component) else { throw GitBlobCodeMapLocatorStoreError.invalidRoot }
            let next = openat(current.rawValue, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw ioError("root-component-open") }
            do {
                current = try validatedDirectoryDescriptor(
                    next,
                    parent: current,
                    name: component,
                    expectedOwner: index == components.count - 1 ? getuid() : nil,
                    expectedMode: index == components.count - 1 ? directoryMode : nil,
                    requireSameDevice: false
                )
            } catch {
                Darwin.close(next)
                throw error
            }
        }
        return current
    }

    private static func descriptorForAlreadyOpenDirectory(
        _ descriptor: Int32
    ) throws -> GitBlobLocatorDirectoryDescriptor {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw ioError("root-stat") }
        let identity = GitBlobLocatorDirectoryIdentity(status)
        guard identity.type == mode_t(S_IFDIR) else {
            throw GitBlobCodeMapLocatorStoreError.invalidRoot
        }
        return GitBlobLocatorDirectoryDescriptor(rawValue: descriptor, identity: identity)
    }

    private static func validatedDirectoryDescriptor(
        _ descriptor: Int32,
        parent: GitBlobLocatorDirectoryDescriptor,
        name: String,
        expectedOwner: uid_t?,
        expectedMode: mode_t?,
        requireSameDevice: Bool
    ) throws -> GitBlobLocatorDirectoryDescriptor {
        var descriptorStatus = stat()
        var pathStatus = stat()
        guard fstat(descriptor, &descriptorStatus) == 0,
              fstatat(parent.rawValue, name, &pathStatus, AT_SYMLINK_NOFOLLOW) == 0
        else {
            throw ioError("directory-stat")
        }
        let descriptorIdentity = GitBlobLocatorDirectoryIdentity(descriptorStatus)
        let pathIdentity = GitBlobLocatorDirectoryIdentity(pathStatus)
        guard descriptorIdentity == pathIdentity,
              descriptorIdentity.type == mode_t(S_IFDIR),
              expectedOwner.map({ descriptorIdentity.owner == $0 }) ?? true,
              expectedMode.map({ descriptorIdentity.permissions == $0 }) ?? true,
              !requireSameDevice || descriptorIdentity.device == parent.identity.device
        else {
            throw GitBlobCodeMapLocatorStoreError.insecureDirectory
        }
        return GitBlobLocatorDirectoryDescriptor(rawValue: descriptor, identity: descriptorIdentity)
    }

    private static func validatedFileIdentity(
        _ descriptor: Int32,
        parent: GitBlobLocatorDirectoryDescriptor,
        name: String,
        expectedMode: mode_t
    ) throws -> GitBlobLocatorFileIdentity {
        var descriptorStatus = stat()
        var pathStatus = stat()
        guard fstat(descriptor, &descriptorStatus) == 0,
              fstatat(parent.rawValue, name, &pathStatus, AT_SYMLINK_NOFOLLOW) == 0
        else {
            throw ioError("record-stat")
        }
        let descriptorIdentity = GitBlobLocatorFileIdentity(descriptorStatus)
        let pathIdentity = GitBlobLocatorFileIdentity(pathStatus)
        guard descriptorIdentity == pathIdentity,
              descriptorIdentity.type == mode_t(S_IFREG),
              descriptorIdentity.owner == getuid(),
              descriptorIdentity.permissions == expectedMode,
              descriptorIdentity.linkCount == 1,
              descriptorIdentity.device == parent.identity.device
        else {
            throw GitBlobCodeMapLocatorStoreError.insecureLeaf
        }
        return descriptorIdentity
    }

    private static func admitFileForRead(
        _ descriptor: Int32,
        parent: GitBlobLocatorDirectoryDescriptor,
        name: String
    ) throws -> GitBlobLocatorReadAdmission {
        var descriptorStatus = stat()
        guard fstat(descriptor, &descriptorStatus) == 0 else { throw ioError("record-descriptor-stat") }
        let descriptorIdentity = GitBlobLocatorFileIdentity(descriptorStatus)
        guard descriptorIdentity.isSecureRegularFile(in: parent.identity.device) else {
            throw GitBlobCodeMapLocatorStoreError.insecureLeaf
        }
        var pathStatus = stat()
        guard fstatat(parent.rawValue, name, &pathStatus, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return .missing }
            throw ioError("record-path-stat")
        }
        let pathIdentity = GitBlobLocatorFileIdentity(pathStatus)
        guard pathIdentity.isSecureRegularFile(in: parent.identity.device) else {
            throw GitBlobCodeMapLocatorStoreError.insecureLeaf
        }
        guard descriptorIdentity == pathIdentity else { return .mutated }
        return .admitted(descriptorIdentity)
    }

    private static func validateFileAfterRead(
        _ descriptor: Int32,
        parent: GitBlobLocatorDirectoryDescriptor,
        name: String
    ) throws -> GitBlobLocatorReadAdmission {
        var descriptorStatus = stat()
        guard fstat(descriptor, &descriptorStatus) == 0 else { throw ioError("record-descriptor-stat") }
        let descriptorIdentity = GitBlobLocatorFileIdentity(descriptorStatus)
        var pathStatus = stat()
        guard fstatat(parent.rawValue, name, &pathStatus, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return .missing }
            throw ioError("record-path-stat")
        }
        let pathIdentity = GitBlobLocatorFileIdentity(pathStatus)
        guard descriptorIdentity == pathIdentity else { return .mutated }
        guard descriptorIdentity.isSecureRegularFile(in: parent.identity.device) else {
            throw GitBlobCodeMapLocatorStoreError.insecureLeaf
        }
        return .admitted(descriptorIdentity)
    }

    private static func withMaintenanceLock<T>(
        rootURL: URL,
        _ body: (GitBlobLocatorStoreLayout) throws -> T
    ) throws -> T {
        var refreshedStaleLayout = false
        while true {
            let layout: GitBlobLocatorStoreLayout
            do {
                layout = try openLayout(rootURL: rootURL)
            } catch let GitBlobCodeMapLocatorStoreError.ioFailure(operation, code)
                where operation == "maintenance-lock-open" && code == ENOENT && !refreshedStaleLayout
            {
                refreshedStaleLayout = true
                continue
            }
            do {
                return try withCurrentMaintenanceLock(layout: layout, rootURL: rootURL, body)
            } catch is GitBlobLocatorStaleLayoutError {
                guard !refreshedStaleLayout else {
                    throw GitBlobCodeMapLocatorStoreError.ioFailure(
                        operation: "maintenance-lock-stale-layout",
                        code: ESTALE
                    )
                }
                refreshedStaleLayout = true
                continue
            }
        }
    }

    private static func withMaintenanceLock<T>(
        rootURL: URL,
        beforeLock: @Sendable () async -> Void,
        _ body: (GitBlobLocatorStoreLayout) throws -> T
    ) async throws -> T {
        var refreshedStaleLayout = false
        while true {
            let layout: GitBlobLocatorStoreLayout
            do {
                layout = try openLayout(rootURL: rootURL)
            } catch let GitBlobCodeMapLocatorStoreError.ioFailure(operation, code)
                where operation == "maintenance-lock-open" && code == ENOENT && !refreshedStaleLayout
            {
                refreshedStaleLayout = true
                continue
            }
            await beforeLock()
            do {
                return try withCurrentMaintenanceLock(layout: layout, rootURL: rootURL, body)
            } catch is GitBlobLocatorStaleLayoutError {
                guard !refreshedStaleLayout else {
                    throw GitBlobCodeMapLocatorStoreError.ioFailure(
                        operation: "maintenance-lock-stale-layout",
                        code: ESTALE
                    )
                }
                refreshedStaleLayout = true
                continue
            }
        }
    }

    private static func withCurrentMaintenanceLock<T>(
        layout: GitBlobLocatorStoreLayout,
        rootURL: URL,
        _ body: (GitBlobLocatorStoreLayout) throws -> T
    ) throws -> T {
        let name = ".maintenance.lock"
        let descriptor = openat(
            layout.version.rawValue,
            name,
            O_RDWR | O_NOFOLLOW | O_CLOEXEC
        )
        if descriptor < 0 {
            let openError = errno
            if openError == ENOENT, !layoutIsCurrent(layout, rootURL: rootURL) {
                throw GitBlobLocatorStaleLayoutError()
            }
            if openError == ELOOP { throw GitBlobCodeMapLocatorStoreError.insecureLeaf }
            errno = openError
            throw ioError("maintenance-lock-open")
        }
        defer { Darwin.close(descriptor) }
        let lockIdentity: GitBlobLocatorFileIdentity
        do {
            lockIdentity = try validatedFileIdentity(
                descriptor,
                parent: layout.version,
                name: name,
                expectedMode: Self.fileMode
            )
        } catch let GitBlobCodeMapLocatorStoreError.ioFailure(_, code)
            where code == ENOENT && !layoutIsCurrent(layout, rootURL: rootURL)
        {
            throw GitBlobLocatorStaleLayoutError()
        }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else { throw ioError("maintenance-lock-acquire") }
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        let postLockIdentity: GitBlobLocatorFileIdentity
        do {
            postLockIdentity = try validatedFileIdentity(
                descriptor,
                parent: layout.version,
                name: name,
                expectedMode: Self.fileMode
            )
        } catch let GitBlobCodeMapLocatorStoreError.ioFailure(_, code)
            where code == ENOENT && !layoutIsCurrent(layout, rootURL: rootURL)
        {
            throw GitBlobLocatorStaleLayoutError()
        }
        guard postLockIdentity == lockIdentity
        else {
            throw GitBlobCodeMapLocatorStoreError.insecureLeaf
        }
        guard layoutIsCurrent(layout, rootURL: rootURL) else {
            throw GitBlobLocatorStaleLayoutError()
        }
        return try body(layout)
    }

    private static func directoryEntryNames(
        _ directory: GitBlobLocatorDirectoryDescriptor,
        maximumCount: Int
    ) throws -> (names: [String], truncated: Bool) {
        let duplicate = dup(directory.rawValue)
        guard duplicate >= 0 else { throw ioError("directory-duplicate") }
        guard let stream = fdopendir(duplicate) else {
            Darwin.close(duplicate)
            throw ioError("directory-stream-open")
        }
        defer { closedir(stream) }
        var names: [String] = []
        var truncated = false
        errno = 0
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
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

    private static func layoutIsCurrent(
        _ layout: GitBlobLocatorStoreLayout,
        rootURL: URL
    ) -> Bool {
        do {
            guard let current = try openExistingLayout(rootURL: rootURL) else { return false }
            return layout.root.identity == current.root.identity &&
                layout.namespace.identity == current.namespace.identity &&
                layout.version.identity == current.version.identity &&
                layout.records.identity == current.records.identity
        } catch let GitBlobCodeMapLocatorStoreError.ioFailure(_, code) where code == ENOENT {
            return false
        } catch GitBlobCodeMapLocatorStoreError.invalidRoot {
            return false
        } catch GitBlobCodeMapLocatorStoreError.insecureDirectory {
            return false
        } catch {
            return false
        }
    }

    private static func secureRemove(
        parent: GitBlobLocatorDirectoryDescriptor,
        name: String,
        descriptor: Int32?
    ) throws -> Bool {
        do {
            return try CodeMapSecureFileRemoval.remove(
                parentDescriptor: parent.rawValue,
                expectedDevice: parent.identity.device,
                name: name,
                heldDescriptor: descriptor
            )
        } catch CodeMapSecureFileRemovalError.insecureEntry {
            throw GitBlobCodeMapLocatorStoreError.insecureLeaf
        } catch let CodeMapSecureFileRemovalError.ioFailure(operation, code) {
            throw GitBlobCodeMapLocatorStoreError.ioFailure(
                operation: "maintenance-\(operation)",
                code: code
            )
        }
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
                    throw GitBlobCodeMapLocatorModelError.corruptRecord
                } else if errno != EINTR {
                    throw ioError("record-read")
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
                    throw ioError("record-write")
                }
            }
        }
    }

    private static func synchronize(_ descriptor: Int32, operation: String) throws {
        while fsync(descriptor) != 0 {
            guard errno == EINTR else { throw ioError(operation) }
        }
    }

    private static func isSafeComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\0")
    }

    private static func ioError(_ operation: String) -> GitBlobCodeMapLocatorStoreError {
        GitBlobCodeMapLocatorStoreError.ioFailure(operation: operation, code: errno)
    }
}

private final class GitBlobLocatorDirectoryDescriptor {
    let rawValue: Int32
    let identity: GitBlobLocatorDirectoryIdentity

    init(rawValue: Int32, identity: GitBlobLocatorDirectoryIdentity) {
        self.rawValue = rawValue
        self.identity = identity
    }

    deinit {
        Darwin.close(rawValue)
    }
}

private struct GitBlobLocatorStoreLayout {
    let root: GitBlobLocatorDirectoryDescriptor
    let namespace: GitBlobLocatorDirectoryDescriptor
    let version: GitBlobLocatorDirectoryDescriptor
    let records: GitBlobLocatorDirectoryDescriptor
}

private struct GitBlobLocatorStaleLayoutError: Error {}

private enum GitBlobLocatorReadAdmission {
    case admitted(GitBlobLocatorFileIdentity)
    case missing
    case mutated
}

private enum GitBlobLocatorMaintenanceRecordInspection {
    case ignored
    case removedTemporary
    case removedCorrupt
    case retained(GitBlobLocatorFileIdentity)
}

private struct GitBlobLocatorMaintenanceEntry {
    let shard: String
    let name: String
    let byteCount: UInt64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
}

private struct GitBlobLocatorDirectoryIdentity: Equatable {
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

private struct GitBlobLocatorFileIdentity: Equatable {
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

    func sameObject(as other: GitBlobLocatorFileIdentity) -> Bool {
        device == other.device && inode == other.inode
    }

    func isSecureRegularFile(in expectedDevice: dev_t) -> Bool {
        type == mode_t(S_IFREG) &&
            owner == getuid() &&
            permissions == mode_t(0o600) &&
            linkCount == 1 &&
            device == expectedDevice
    }
}

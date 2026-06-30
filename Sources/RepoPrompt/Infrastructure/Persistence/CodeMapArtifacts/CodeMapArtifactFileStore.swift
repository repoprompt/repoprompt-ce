import CryptoKit
import Darwin
import Foundation

enum CodeMapArtifactFileStoreError: Error, Equatable {
    case invalidRoot
    case insecureDirectory
    case insecureLeaf
    case integrityCollision
    case ioFailure(operation: String, code: Int32)
}

enum CodeMapArtifactFileReadResult: Equatable {
    case miss
    case hit(CodeMapSyntaxArtifactOutcome)
}

struct CodeMapArtifactVerifiedFile: Equatable {
    let outcome: CodeMapSyntaxArtifactOutcome
    let payloadByteCount: Int
    let containerByteCount: Int
}

enum CodeMapArtifactVerifiedFileReadResult: Equatable {
    case miss
    case corrupt
    case hit(CodeMapArtifactVerifiedFile)
}

struct CodeMapArtifactOrphanCandidate: Equatable {
    let shard: String
    let digest: String
}

struct CodeMapArtifactQuarantinedFile: Equatable {
    let token: String
    let artifactName: String
    let byteCount: UInt64
}

enum CodeMapArtifactOrphanReconciliationResult: Equatable {
    case miss
    case corrupt
    case verified(key: CodeMapArtifactKey, file: CodeMapArtifactVerifiedFile)
}

enum CodeMapArtifactFileWriteResult: Equatable {
    case inserted
    case alreadyPresent
}

struct CodeMapArtifactFileStore {
    private static let directoryMode = mode_t(0o700)
    private static let fileMode = mode_t(0o600)
    private static let maximumPublishAttempts = 8
    private static let maximumRecoveryEntries = 4096

    let rootURL: URL
    let containerPolicy: CodeMapArtifactContainerPolicy
    private let removalHooks: CodeMapSecureFileRemovalHooks?

    static func maintenanceVerificationReadByteCount(containerByteCount: UInt64) -> UInt64 {
        let prefix = UInt64(CodeMapArtifactContainer.magic.count + 12)
        let (doubled, overflow) = containerByteCount.multipliedReportingOverflow(by: 2)
        guard !overflow else { return .max }
        let (total, totalOverflow) = doubled.addingReportingOverflow(prefix)
        return totalOverflow ? .max : total
    }

    static func maintenanceOrphanReadByteCount(
        containerByteCount: UInt64,
        containerPolicy: CodeMapArtifactContainerPolicy
    ) -> UInt64 {
        let verified = maintenanceVerificationReadByteCount(containerByteCount: containerByteCount)
        let embeddedKeyMaximum = UInt64((CodeMapArtifactContainer.magic.count + 12) * 2) +
            UInt64(containerPolicy.maximumHeaderByteCount)
        let (total, overflow) = verified.addingReportingOverflow(embeddedKeyMaximum)
        return overflow ? .max : total
    }

    init(
        rootURL: URL,
        containerPolicy: CodeMapArtifactContainerPolicy = .default,
        removalHooks: CodeMapSecureFileRemovalHooks? = nil
    ) throws {
        guard rootURL.isFileURL,
              rootURL.path.hasPrefix("/"),
              rootURL.path != "/",
              !rootURL.path.contains("//"),
              rootURL.path.split(separator: "/").allSatisfy({ Self.isSafeComponent(String($0)) })
        else {
            throw CodeMapArtifactFileStoreError.invalidRoot
        }
        self.rootURL = rootURL
        self.containerPolicy = containerPolicy
        self.removalHooks = removalHooks
        _ = try openLayout()
    }

    func artifactURL(for key: CodeMapArtifactKey) -> URL {
        rootURL
            .appendingPathComponent("CodeMapArtifacts", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent("artifacts", isDirectory: true)
            .appendingPathComponent(key.shard, isDirectory: true)
            .appendingPathComponent(key.storageDigestHex, isDirectory: false)
    }

    func maintenanceVerificationReadByteCount(key: CodeMapArtifactKey) throws -> UInt64? {
        let layout = try openLayout()
        guard let shard = try openOwnedDirectory(parent: layout.artifacts, name: key.shard, create: false) else {
            return nil
        }
        let descriptor = openat(
            shard.rawValue,
            key.storageDigestHex,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw Self.ioError("maintenance-cost-open") }
        defer { Darwin.close(descriptor) }
        let identity = try Self.validatedFileIdentity(
            descriptor,
            parent: shard,
            name: key.storageDigestHex,
            expectedMode: Self.fileMode
        )
        guard identity.size >= 0 else { throw CodeMapArtifactFileStoreError.insecureLeaf }
        return Self.maintenanceVerificationReadByteCount(containerByteCount: UInt64(identity.size))
    }

    func read(key: CodeMapArtifactKey) throws -> CodeMapArtifactFileReadResult {
        switch try readVerified(key: key) {
        case .miss, .corrupt:
            .miss
        case let .hit(file):
            .hit(file.outcome)
        }
    }

    /// Reads through the same descriptor-held key, filename, schema, length, and checksum
    /// verification as `read`. Callers may suppress corruption quarantine only while they
    /// already hold the namespace maintenance lock (for example, paired GC mutation).
    func readVerified(
        key: CodeMapArtifactKey,
        quarantineCorruption: Bool = true
    ) throws -> CodeMapArtifactVerifiedFileReadResult {
        let layout = try openLayout()
        let shard = try openOwnedDirectory(parent: layout.artifacts, name: key.shard, create: false)
        guard let shard else { return .miss }
        switch try readLeaf(parent: shard, key: key) {
        case .missing:
            return .miss
        case let .valid(_, decoded):
            return .hit(CodeMapArtifactVerifiedFile(
                outcome: decoded.outcome,
                payloadByteCount: decoded.payloadByteCount,
                containerByteCount: decoded.containerByteCount
            ))
        case let .corrupt(identity):
            if quarantineCorruption {
                try? withMaintenanceLock(layout: layout) {
                    try quarantine(
                        parent: shard,
                        identity: identity,
                        key: key,
                        layout: layout,
                        epochSeconds: UInt64(max(0, Date().timeIntervalSince1970))
                    )
                }
                return .miss
            }
            return .corrupt
        }
    }

    /// Verifies a metadata-less artifact by recovering its canonical key from
    /// the bounded container header. The filename and shard remain authority
    /// for storage location, and the recovered key must derive both exactly.
    func reconcileOrphan(
        _ candidate: CodeMapArtifactOrphanCandidate,
        quarantineCorruption: Bool = true,
        epochSeconds: UInt64
    ) throws -> CodeMapArtifactOrphanReconciliationResult {
        guard Self.isCanonicalShard(candidate.shard),
              Self.isCanonicalDigest(candidate.digest),
              candidate.digest.hasPrefix(candidate.shard)
        else { throw CodeMapArtifactFileStoreError.invalidRoot }

        let layout = try openLayout()
        guard let shard = try openOwnedDirectory(
            parent: layout.artifacts,
            name: candidate.shard,
            create: false
        ) else { return .miss }
        let descriptor = openat(
            shard.rawValue,
            candidate.digest,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        if descriptor < 0, errno == ENOENT { return .miss }
        guard descriptor >= 0 else { throw Self.ioError("orphan-open") }
        defer { Darwin.close(descriptor) }
        let identity = try Self.validatedFileIdentity(
            descriptor,
            parent: shard,
            name: candidate.digest,
            expectedMode: Self.fileMode
        )

        let result: CodeMapArtifactOrphanReconciliationResult
        do {
            guard identity.size >= 0,
                  identity.size <= Int64(containerPolicy.maximumContainerByteCount),
                  let byteCount = Int(exactly: identity.size)
            else { throw CodeMapArtifactContainerError.invalidPayloadLength }
            let key = try embeddedKey(
                descriptor,
                fileByteCount: byteCount,
                expectedShard: candidate.shard,
                expectedDigest: candidate.digest
            )
            switch try readLeaf(parent: shard, key: key) {
            case .missing:
                result = .miss
            case let .valid(_, decoded):
                result = .verified(
                    key: key,
                    file: CodeMapArtifactVerifiedFile(
                        outcome: decoded.outcome,
                        payloadByteCount: decoded.payloadByteCount,
                        containerByteCount: decoded.containerByteCount
                    )
                )
            case .corrupt:
                result = .corrupt
            }
        } catch is CodeMapArtifactContainerError {
            result = .corrupt
        } catch is CodeMapCanonicalIdentityError {
            result = .corrupt
        }

        if result == .corrupt, quarantineCorruption {
            try? withMaintenanceLock(layout: layout) {
                try quarantineUnknownArtifact(
                    parent: shard,
                    identity: identity,
                    shardName: candidate.shard,
                    artifactName: candidate.digest,
                    layout: layout,
                    epochSeconds: epochSeconds
                )
            }
        }
        return result
    }

    /// Called only while the catalog maintenance lock is held. The returned
    /// token is used to publish the typed tombstone before the mutation is
    /// considered durable.
    func quarantineOrphanAssumingMaintenanceLock(
        _ candidate: CodeMapArtifactOrphanCandidate,
        epochSeconds: UInt64
    ) throws -> CodeMapArtifactQuarantinedFile? {
        guard Self.isCanonicalShard(candidate.shard),
              Self.isCanonicalDigest(candidate.digest),
              candidate.digest.hasPrefix(candidate.shard)
        else { throw CodeMapArtifactFileStoreError.invalidRoot }
        let layout = try openLayout()
        guard let shard = try openOwnedDirectory(parent: layout.artifacts, name: candidate.shard, create: false) else {
            return nil
        }
        let descriptor = openat(
            shard.rawValue,
            candidate.digest,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw Self.ioError("orphan-quarantine-open") }
        defer { Darwin.close(descriptor) }
        let identity = try Self.validatedFileIdentity(
            descriptor,
            parent: shard,
            name: candidate.digest,
            expectedMode: Self.fileMode
        )
        return try quarantineUnknownArtifact(
            parent: shard,
            identity: identity,
            shardName: candidate.shard,
            artifactName: candidate.digest,
            layout: layout,
            epochSeconds: epochSeconds
        )
    }

    func write(
        key: CodeMapArtifactKey,
        outcome: CodeMapSyntaxArtifactOutcome
    ) throws -> CodeMapArtifactFileWriteResult {
        try write(
            key: key,
            outcome: outcome,
            maintenanceAlreadyHeld: false,
            quarantineEpochSeconds: UInt64(max(0, Date().timeIntervalSince1970))
        )
    }

    func writeAssumingMaintenanceLock(
        key: CodeMapArtifactKey,
        encodedContainer: Data,
        quarantineEpochSeconds: UInt64
    ) throws -> CodeMapArtifactFileWriteResult {
        try write(
            key: key,
            encodedContainer: encodedContainer,
            maintenanceAlreadyHeld: true,
            quarantineEpochSeconds: quarantineEpochSeconds
        )
    }

    private func write(
        key: CodeMapArtifactKey,
        outcome: CodeMapSyntaxArtifactOutcome,
        maintenanceAlreadyHeld: Bool,
        quarantineEpochSeconds: UInt64
    ) throws -> CodeMapArtifactFileWriteResult {
        let encodedContainer = try CodeMapArtifactContainer.encode(
            key: key,
            outcome: outcome,
            policy: containerPolicy
        )
        return try write(
            key: key,
            encodedContainer: encodedContainer,
            maintenanceAlreadyHeld: maintenanceAlreadyHeld,
            quarantineEpochSeconds: quarantineEpochSeconds
        )
    }

    private func write(
        key: CodeMapArtifactKey,
        encodedContainer container: Data,
        maintenanceAlreadyHeld: Bool,
        quarantineEpochSeconds: UInt64
    ) throws -> CodeMapArtifactFileWriteResult {
        for _ in 0 ..< Self.maximumPublishAttempts {
            let layout = try openLayout()
            let shard = try requireOwnedDirectory(parent: layout.artifacts, name: key.shard)
            switch try readLeaf(parent: shard, key: key) {
            case .missing:
                if try publish(
                    container,
                    parent: shard,
                    destination: key.storageDigestHex,
                    artifactsParent: layout.artifacts,
                    shardName: key.shard
                ) {
                    return .inserted
                }
            case let .valid(existing, _):
                guard existing == container else {
                    throw CodeMapArtifactFileStoreError.integrityCollision
                }
                return .alreadyPresent
            case let .corrupt(identity):
                if maintenanceAlreadyHeld {
                    try quarantine(
                        parent: shard,
                        identity: identity,
                        key: key,
                        layout: layout,
                        epochSeconds: quarantineEpochSeconds
                    )
                } else {
                    try withMaintenanceLock(layout: layout) {
                        try quarantine(
                            parent: shard,
                            identity: identity,
                            key: key,
                            layout: layout,
                            epochSeconds: quarantineEpochSeconds
                        )
                    }
                }
            }
        }
        throw CodeMapArtifactFileStoreError.ioFailure(operation: "publish-retry", code: EBUSY)
    }

    @discardableResult
    func recoverValidatedTemporaryFiles(maximumEntries: Int = maximumRecoveryEntries) throws -> Int {
        guard maximumEntries >= 0, maximumEntries <= Self.maximumRecoveryEntries else {
            throw CodeMapArtifactFileStoreError.invalidRoot
        }
        let layout = try openLayout()
        return try withMaintenanceLock(layout: layout) {
            try Self.validateDirectoryPath(layout.artifacts, parent: layout.version, name: "artifacts")
            var examined = 0
            var removed = 0
            for shardName in try directoryEntryNames(layout.artifacts, maximumCount: maximumEntries) {
                guard examined < maximumEntries else { break }
                guard Self.isCanonicalShard(shardName) else { continue }
                guard let shard = try openOwnedDirectory(parent: layout.artifacts, name: shardName, create: false) else {
                    continue
                }
                try Self.validateDirectoryPath(shard, parent: layout.artifacts, name: shardName)
                for name in try directoryEntryNames(shard, maximumCount: maximumEntries - examined) {
                    guard examined < maximumEntries else { break }
                    examined += 1
                    guard let pid = Self.validatedTemporaryPID(name)
                        ?? CodeMapSecureFileRemoval.privateRemovalPID(name),
                        !Self.processIsActive(pid)
                    else { continue }
                    if try removeValidatedTemporaryFile(parent: shard, name: name) { removed += 1 }
                }
                try Self.synchronize(shard.rawValue, operation: "temp-directory-fsync")
            }
            return removed
        }
    }

    private func openLayout() throws -> Layout {
        let root = try Self.openVerifiedRoot(at: rootURL)
        let namespace = try requireOwnedDirectory(parent: root, name: "CodeMapArtifacts")
        let version = try requireOwnedDirectory(parent: namespace, name: "v1")
        let artifacts = try requireOwnedDirectory(parent: version, name: "artifacts")
        let quarantine = try requireOwnedDirectory(parent: version, name: "quarantine")
        try ensureMaintenanceLock(parent: version)
        return Layout(root: root, namespace: namespace, version: version, artifacts: artifacts, quarantine: quarantine)
    }

    private func requireOwnedDirectory(parent: DirectoryDescriptor, name: String) throws -> DirectoryDescriptor {
        guard let result = try openOwnedDirectory(parent: parent, name: name, create: true) else {
            throw CodeMapArtifactFileStoreError.insecureDirectory
        }
        return result
    }

    private func openOwnedDirectory(
        parent: DirectoryDescriptor,
        name: String,
        create: Bool
    ) throws -> DirectoryDescriptor? {
        guard Self.isSafeComponent(name) else {
            throw CodeMapArtifactFileStoreError.insecureDirectory
        }
        var created = false
        if create {
            if mkdirat(parent.rawValue, name, Self.directoryMode) == 0 {
                created = true
            } else if errno != EEXIST {
                throw Self.ioError("directory-create")
            }
        }
        let descriptor = openat(parent.rawValue, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0, !create, errno == ENOENT { return nil }
        guard descriptor >= 0 else {
            throw Self.ioError("directory-open")
        }
        do {
            if created, fchmod(descriptor, Self.directoryMode) != 0 {
                throw Self.ioError("directory-mode")
            }
            let result = try Self.validatedDirectoryDescriptor(
                descriptor,
                parent: parent,
                name: name,
                expectedOwner: getuid(),
                expectedMode: Self.directoryMode,
                requireSameDevice: true
            )
            if created {
                try Self.synchronize(parent.rawValue, operation: "directory-parent-fsync")
            }
            return result
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func ensureMaintenanceLock(parent: DirectoryDescriptor) throws {
        let name = "maintenance.lock"
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
        guard descriptor >= 0 else { throw Self.ioError("maintenance-open") }
        defer { Darwin.close(descriptor) }
        if created, fchmod(descriptor, Self.fileMode) != 0 {
            throw Self.ioError("maintenance-mode")
        }
        let identity = try Self.validatedFileIdentity(
            descriptor,
            parent: parent,
            name: name,
            expectedMode: Self.fileMode
        )
        guard identity.linkCount == 1 else {
            throw CodeMapArtifactFileStoreError.insecureLeaf
        }
        if created {
            try Self.synchronize(parent.rawValue, operation: "maintenance-parent-fsync")
        }
    }

    private func withMaintenanceLock<T>(layout: Layout, _ body: () throws -> T) throws -> T {
        let descriptor = openat(
            layout.version.rawValue,
            "maintenance.lock",
            O_RDWR | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw Self.ioError("maintenance-open") }
        defer { Darwin.close(descriptor) }
        let lockIdentity = try Self.validatedFileIdentity(
            descriptor,
            parent: layout.version,
            name: "maintenance.lock",
            expectedMode: Self.fileMode
        )
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else { throw Self.ioError("maintenance-lock") }
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        guard try Self.validatedFileIdentity(
            descriptor,
            parent: layout.version,
            name: "maintenance.lock",
            expectedMode: Self.fileMode
        ) == lockIdentity
        else {
            throw CodeMapArtifactFileStoreError.insecureLeaf
        }
        try Self.validateDirectoryPath(layout.version, parent: layout.namespace, name: "v1")
        return try body()
    }

    private enum LeafRead {
        case missing
        case valid(Data, DecodedCodeMapArtifactContainer)
        case corrupt(FileIdentity)
    }

    private func readLeaf(parent: DirectoryDescriptor, key: CodeMapArtifactKey) throws -> LeafRead {
        let name = key.storageDigestHex
        let descriptor = openat(parent.rawValue, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0, errno == ENOENT { return .missing }
        guard descriptor >= 0 else { throw Self.ioError("artifact-open") }
        defer { Darwin.close(descriptor) }

        let identity = try Self.validatedFileIdentity(
            descriptor,
            parent: parent,
            name: name,
            expectedMode: Self.fileMode
        )
        guard identity.size >= 0,
              identity.size <= Int64(containerPolicy.maximumContainerByteCount),
              let byteCount = Int(exactly: identity.size)
        else {
            return .corrupt(identity)
        }
        do {
            _ = try preflightContainer(descriptor, fileByteCount: byteCount, key: key)
        } catch is CodeMapArtifactContainerError {
            return .corrupt(identity)
        }
        guard try Self.fileIdentity(descriptor) == identity,
              try Self.pathIdentity(parent: parent, name: name) == identity
        else {
            throw CodeMapArtifactFileStoreError.insecureLeaf
        }
        let data: Data
        do {
            data = try Self.readExactly(descriptor, byteCount: byteCount)
        } catch is CodeMapArtifactContainerError {
            return .corrupt(identity)
        }
        guard try Self.fileIdentity(descriptor) == identity,
              try Self.pathIdentity(parent: parent, name: name) == identity
        else {
            throw CodeMapArtifactFileStoreError.insecureLeaf
        }
        do {
            let decoded = try CodeMapArtifactContainer.decode(
                data,
                expectedKey: key,
                filenameDigest: name,
                policy: containerPolicy
            )
            guard try Self.fileIdentity(descriptor) == identity,
                  try Self.pathIdentity(parent: parent, name: name) == identity
            else {
                throw CodeMapArtifactFileStoreError.insecureLeaf
            }
            return .valid(data, decoded)
        } catch is CodeMapArtifactContainerError {
            return .corrupt(identity)
        }
    }

    private func publish(
        _ data: Data,
        parent: DirectoryDescriptor,
        destination: String,
        artifactsParent: DirectoryDescriptor,
        shardName: String
    ) throws -> Bool {
        let temporaryName = ".tmp.\(getpid()).\(UUID().uuidString.lowercased())"
        let descriptor = openat(
            parent.rawValue,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            Self.fileMode
        )
        guard descriptor >= 0 else { throw Self.ioError("temp-create") }
        var temporaryIdentity: FileIdentity?
        var published = false
        defer {
            if !published, let temporaryIdentity {
                _ = try? removeIfIdentityMatches(
                    parent: parent,
                    name: temporaryName,
                    descriptor: descriptor,
                    identity: temporaryIdentity
                )
            }
            Darwin.close(descriptor)
        }
        guard fchmod(descriptor, Self.fileMode) == 0 else { throw Self.ioError("temp-mode") }
        temporaryIdentity = try Self.validatedFileIdentity(
            descriptor,
            parent: parent,
            name: temporaryName,
            expectedMode: Self.fileMode
        )
        try Self.writeAll(descriptor, data: data)
        try Self.synchronize(descriptor, operation: "temp-fsync")
        temporaryIdentity = try Self.validatedFileIdentity(
            descriptor,
            parent: parent,
            name: temporaryName,
            expectedMode: Self.fileMode
        )
        guard let temporaryIdentity,
              try Self.fileIdentity(descriptor) == temporaryIdentity,
              try Self.pathIdentity(parent: parent, name: temporaryName) == temporaryIdentity
        else {
            throw CodeMapArtifactFileStoreError.insecureLeaf
        }
        try Self.validateDirectoryPath(parent, parent: artifactsParent, name: shardName)
        let renameResult = renameatx_np(
            parent.rawValue,
            temporaryName,
            parent.rawValue,
            destination,
            UInt32(RENAME_EXCL)
        )
        guard renameResult == 0 else {
            if errno == EEXIST { return false }
            throw Self.ioError("artifact-rename")
        }
        let publishedIdentity = try Self.validatedFileIdentity(
            descriptor,
            parent: parent,
            name: destination,
            expectedMode: Self.fileMode
        )
        guard publishedIdentity.sameObject(as: temporaryIdentity),
              publishedIdentity.size == temporaryIdentity.size
        else {
            throw CodeMapArtifactFileStoreError.insecureLeaf
        }
        try Self.validateDirectoryPath(parent, parent: artifactsParent, name: shardName)
        published = true
        try Self.synchronize(parent.rawValue, operation: "artifact-directory-fsync")
        return true
    }

    private func quarantine(
        parent: DirectoryDescriptor,
        identity: FileIdentity,
        key: CodeMapArtifactKey,
        layout: Layout,
        epochSeconds: UInt64
    ) throws {
        try Self.validateDirectoryPath(parent, parent: layout.artifacts, name: key.shard)
        let sourceDescriptor = openat(
            parent.rawValue,
            key.storageDigestHex,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        if sourceDescriptor < 0, errno == ENOENT { return }
        guard sourceDescriptor >= 0 else { throw Self.ioError("quarantine-source-open") }
        defer { Darwin.close(sourceDescriptor) }
        guard try Self.validatedFileIdentity(
            sourceDescriptor,
            parent: parent,
            name: key.storageDigestHex,
            expectedMode: Self.fileMode
        ) == identity
        else { return }
        let epochName = String(epochSeconds)
        let epoch = try requireOwnedDirectory(parent: layout.quarantine, name: epochName)
        let artifacts = try requireOwnedDirectory(parent: epoch, name: "artifacts")
        let shard = try requireOwnedDirectory(parent: artifacts, name: key.shard)
        for _ in 0 ..< Self.maximumPublishAttempts {
            let destination = "\(key.storageDigestHex).\(UUID().uuidString.lowercased())"
            if renameatx_np(
                parent.rawValue,
                key.storageDigestHex,
                shard.rawValue,
                destination,
                UInt32(RENAME_EXCL)
            ) == 0 {
                let quarantinedIdentity = try Self.validatedFileIdentity(
                    sourceDescriptor,
                    parent: shard,
                    name: destination,
                    expectedMode: Self.fileMode
                )
                guard quarantinedIdentity.sameObject(as: identity),
                      quarantinedIdentity.size == identity.size
                else {
                    throw CodeMapArtifactFileStoreError.insecureLeaf
                }
                try Self.synchronize(parent.rawValue, operation: "quarantine-source-fsync")
                try Self.synchronize(shard.rawValue, operation: "quarantine-destination-fsync")
                return
            }
            if errno == ENOENT { return }
            if errno != EEXIST { throw Self.ioError("quarantine-rename") }
        }
        throw CodeMapArtifactFileStoreError.ioFailure(operation: "quarantine-retry", code: EBUSY)
    }

    private func quarantineUnknownArtifact(
        parent: DirectoryDescriptor,
        identity: FileIdentity,
        shardName: String,
        artifactName: String,
        layout: Layout,
        epochSeconds: UInt64
    ) throws -> CodeMapArtifactQuarantinedFile? {
        try Self.validateDirectoryPath(parent, parent: layout.artifacts, name: shardName)
        let sourceDescriptor = openat(
            parent.rawValue,
            artifactName,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        if sourceDescriptor < 0, errno == ENOENT { return nil }
        guard sourceDescriptor >= 0 else { throw Self.ioError("orphan-quarantine-source-open") }
        defer { Darwin.close(sourceDescriptor) }
        guard try Self.validatedFileIdentity(
            sourceDescriptor,
            parent: parent,
            name: artifactName,
            expectedMode: Self.fileMode
        ) == identity
        else { return nil }
        let epoch = try requireOwnedDirectory(parent: layout.quarantine, name: String(epochSeconds))
        let artifacts = try requireOwnedDirectory(parent: epoch, name: "artifacts")
        let destinationShard = try requireOwnedDirectory(parent: artifacts, name: shardName)
        for _ in 0 ..< Self.maximumPublishAttempts {
            let destination = "\(artifactName).\(UUID().uuidString.lowercased())"
            if renameatx_np(
                parent.rawValue,
                artifactName,
                destinationShard.rawValue,
                destination,
                UInt32(RENAME_EXCL)
            ) == 0 {
                let quarantined = try Self.validatedFileIdentity(
                    sourceDescriptor,
                    parent: destinationShard,
                    name: destination,
                    expectedMode: Self.fileMode
                )
                guard quarantined.sameObject(as: identity), quarantined.size == identity.size else {
                    throw CodeMapArtifactFileStoreError.insecureLeaf
                }
                try Self.synchronize(parent.rawValue, operation: "orphan-quarantine-source-fsync")
                try Self.synchronize(destinationShard.rawValue, operation: "orphan-quarantine-destination-fsync")
                return CodeMapArtifactQuarantinedFile(
                    token: String(destination.dropFirst(artifactName.count + 1)),
                    artifactName: destination,
                    byteCount: UInt64(identity.size)
                )
            }
            if errno == ENOENT { return nil }
            if errno != EEXIST { throw Self.ioError("orphan-quarantine-rename") }
        }
        throw CodeMapArtifactFileStoreError.ioFailure(operation: "orphan-quarantine-retry", code: EBUSY)
    }

    private func embeddedKey(
        _ descriptor: Int32,
        fileByteCount: Int,
        expectedShard: String,
        expectedDigest: String
    ) throws -> CodeMapArtifactKey {
        let prefixByteCount = CodeMapArtifactContainer.magic.count + 12
        guard fileByteCount >= prefixByteCount else { throw CodeMapArtifactContainerError.truncated }
        let prefix = try Self.preReadExactly(descriptor, byteCount: prefixByteCount, offset: 0)
        guard prefix.prefix(CodeMapArtifactContainer.magic.count) == CodeMapArtifactContainer.magic else {
            throw CodeMapArtifactContainerError.invalidMagic
        }
        let versionOffset = CodeMapArtifactContainer.magic.count
        guard Self.readUInt32(prefix, at: versionOffset) == CodeMapArtifactContainer.containerVersion else {
            throw CodeMapArtifactContainerError.unsupportedContainerVersion
        }
        let headerByteCount = Int(Self.readUInt32(prefix, at: versionOffset + 4))
        let keyByteCount = Int(Self.readUInt32(prefix, at: versionOffset + 8))
        guard headerByteCount >= prefixByteCount,
              headerByteCount <= containerPolicy.maximumHeaderByteCount,
              headerByteCount <= fileByteCount,
              keyByteCount > 0,
              keyByteCount <= headerByteCount - prefixByteCount
        else { throw CodeMapArtifactContainerError.invalidKeyLength }
        let keyPrefix = try Self.preReadExactly(
            descriptor,
            byteCount: prefixByteCount + keyByteCount,
            offset: 0
        )
        let key = try CodeMapArtifactKey(canonicalBytes: keyPrefix.subdata(in: prefixByteCount ..< keyPrefix.count))
        guard key.shard == expectedShard, key.storageDigestHex == expectedDigest else {
            throw CodeMapArtifactContainerError.filenameDigestMismatch
        }
        return key
    }

    private func preflightContainer(
        _ descriptor: Int32,
        fileByteCount: Int,
        key: CodeMapArtifactKey
    ) throws -> CodeMapArtifactContainerPreflight {
        let prefixByteCount = CodeMapArtifactContainer.magic.count + 12
        guard fileByteCount >= prefixByteCount else { throw CodeMapArtifactContainerError.truncated }
        let prefix = try Self.preReadExactly(descriptor, byteCount: prefixByteCount, offset: 0)
        guard prefix.prefix(CodeMapArtifactContainer.magic.count) == CodeMapArtifactContainer.magic else {
            throw CodeMapArtifactContainerError.invalidMagic
        }
        let versionOffset = CodeMapArtifactContainer.magic.count
        guard Self.readUInt32(prefix, at: versionOffset) == CodeMapArtifactContainer.containerVersion else {
            throw CodeMapArtifactContainerError.unsupportedContainerVersion
        }
        let headerByteCount = Int(Self.readUInt32(prefix, at: versionOffset + 4))
        guard headerByteCount >= prefixByteCount,
              headerByteCount <= containerPolicy.maximumHeaderByteCount,
              headerByteCount <= fileByteCount
        else {
            throw CodeMapArtifactContainerError.invalidHeaderLength
        }
        let header = try Self.preReadExactly(
            descriptor,
            byteCount: headerByteCount,
            offset: 0
        )
        let preflight = try CodeMapArtifactContainer.preflightHeader(
            header,
            expectedKey: key,
            filenameDigest: key.storageDigestHex,
            totalFileByteCount: fileByteCount,
            policy: containerPolicy
        )
        let actualChecksum = try Self.streamSHA256(
            descriptor,
            byteCount: preflight.payloadByteCount,
            offset: off_t(preflight.headerByteCount)
        )
        guard actualChecksum == preflight.payloadSHA256 else {
            throw CodeMapArtifactContainerError.checksumMismatch
        }
        return preflight
    }

    private func directoryEntryNames(_ directory: DirectoryDescriptor, maximumCount: Int) throws -> [String] {
        guard maximumCount >= 0 else { return [] }
        let duplicate = dup(directory.rawValue)
        guard duplicate >= 0 else { throw Self.ioError("directory-duplicate") }
        guard let stream = fdopendir(duplicate) else {
            Darwin.close(duplicate)
            throw Self.ioError("directory-stream")
        }
        defer { closedir(stream) }
        var result: [String] = []
        errno = 0
        while result.count < maximumCount, let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != ".", name != ".." { result.append(name) }
            errno = 0
        }
        guard errno == 0 else { throw Self.ioError("directory-read") }
        return result.sorted()
    }

    private static func openVerifiedRoot(at url: URL) throws -> DirectoryDescriptor {
        let components = url.path.split(separator: "/").map(String.init)
        guard !components.isEmpty else { throw CodeMapArtifactFileStoreError.invalidRoot }
        let rootDescriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootDescriptor >= 0 else { throw ioError("root-open") }
        var current = try descriptorForAlreadyOpenDirectory(rootDescriptor)
        for (index, component) in components.enumerated() {
            guard isSafeComponent(component) else { throw CodeMapArtifactFileStoreError.invalidRoot }
            let descriptor = openat(current.rawValue, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw ioError("root-component-open") }
            do {
                current = try validatedDirectoryDescriptor(
                    descriptor,
                    parent: current,
                    name: component,
                    expectedOwner: index == components.count - 1 ? getuid() : nil,
                    expectedMode: index == components.count - 1 ? directoryMode : nil,
                    requireSameDevice: false
                )
            } catch {
                Darwin.close(descriptor)
                throw error
            }
        }
        return current
    }

    private static func descriptorForAlreadyOpenDirectory(_ descriptor: Int32) throws -> DirectoryDescriptor {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw ioError("root-stat") }
        let identity = DirectoryIdentity(status)
        guard identity.type == mode_t(S_IFDIR) else { throw CodeMapArtifactFileStoreError.invalidRoot }
        return DirectoryDescriptor(rawValue: descriptor, identity: identity)
    }

    private static func validatedDirectoryDescriptor(
        _ descriptor: Int32,
        parent: DirectoryDescriptor,
        name: String,
        expectedOwner: uid_t?,
        expectedMode: mode_t?,
        requireSameDevice: Bool
    ) throws -> DirectoryDescriptor {
        var descriptorStatus = stat()
        var pathStatus = stat()
        guard fstat(descriptor, &descriptorStatus) == 0,
              fstatat(parent.rawValue, name, &pathStatus, AT_SYMLINK_NOFOLLOW) == 0
        else {
            throw ioError("directory-stat")
        }
        let descriptorIdentity = DirectoryIdentity(descriptorStatus)
        let pathIdentity = DirectoryIdentity(pathStatus)
        guard descriptorIdentity == pathIdentity,
              descriptorIdentity.type == mode_t(S_IFDIR),
              expectedOwner.map({ descriptorIdentity.owner == $0 }) ?? true,
              expectedMode.map({ descriptorIdentity.permissions == $0 }) ?? true,
              !requireSameDevice || descriptorIdentity.device == parent.identity.device
        else {
            throw CodeMapArtifactFileStoreError.insecureDirectory
        }
        return DirectoryDescriptor(rawValue: descriptor, identity: descriptorIdentity)
    }

    private static func validateDirectoryPath(
        _ directory: DirectoryDescriptor,
        parent: DirectoryDescriptor,
        name: String
    ) throws {
        var status = stat()
        guard fstatat(parent.rawValue, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw ioError("directory-path-stat")
        }
        guard DirectoryIdentity(status) == directory.identity else {
            throw CodeMapArtifactFileStoreError.insecureDirectory
        }
    }

    private static func validatedFileIdentity(
        _ descriptor: Int32,
        parent: DirectoryDescriptor,
        name: String,
        expectedMode: mode_t
    ) throws -> FileIdentity {
        let descriptorIdentity = try fileIdentity(descriptor)
        let pathIdentity = try pathIdentity(parent: parent, name: name)
        guard descriptorIdentity == pathIdentity,
              try descriptorIdentity.isSecureRegularFile(in: parent.identity.device),
              descriptorIdentity.permissions == expectedMode
        else {
            throw CodeMapArtifactFileStoreError.insecureLeaf
        }
        return descriptorIdentity
    }

    private static func fileIdentity(_ descriptor: Int32) throws -> FileIdentity {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw ioError("file-stat") }
        return FileIdentity(status)
    }

    private static func pathIdentity(parent: DirectoryDescriptor, name: String) throws -> FileIdentity {
        var status = stat()
        guard fstatat(parent.rawValue, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw ioError("path-stat")
        }
        return FileIdentity(status)
    }

    private func removeIfIdentityMatches(
        parent: DirectoryDescriptor,
        name: String,
        descriptor: Int32,
        identity: FileIdentity
    ) throws {
        guard try Self.fileIdentity(descriptor) == identity else { return }
        do {
            _ = try CodeMapSecureFileRemoval.remove(
                parentDescriptor: parent.rawValue,
                expectedDevice: parent.identity.device,
                name: name,
                heldDescriptor: descriptor,
                hooks: removalHooks
            )
        } catch let error as CodeMapSecureFileRemovalError {
            throw Self.fileRemovalError(error)
        }
    }

    private func removeValidatedTemporaryFile(
        parent: DirectoryDescriptor,
        name: String
    ) throws -> Bool {
        do {
            return try CodeMapSecureFileRemoval.remove(
                parentDescriptor: parent.rawValue,
                expectedDevice: parent.identity.device,
                name: name,
                hooks: removalHooks
            )
        } catch CodeMapSecureFileRemovalError.insecureEntry {
            return false
        } catch CodeMapSecureFileRemovalError.ioFailure(operation: "open", code: ELOOP) {
            return false
        } catch let error as CodeMapSecureFileRemovalError {
            throw Self.fileRemovalError(error)
        }
    }

    private static func fileRemovalError(_ error: CodeMapSecureFileRemovalError) -> CodeMapArtifactFileStoreError {
        switch error {
        case .insecureEntry:
            .insecureLeaf
        case let .ioFailure(operation, code):
            .ioFailure(operation: "secure-remove-\(operation)", code: code)
        }
    }

    private static func readExactly(_ descriptor: Int32, byteCount: Int) throws -> Data {
        var data = Data(count: byteCount)
        var completed = 0
        try data.withUnsafeMutableBytes { rawBuffer in
            while completed < byteCount {
                let result = Darwin.read(descriptor, rawBuffer.baseAddress!.advanced(by: completed), byteCount - completed)
                if result > 0 {
                    completed += result
                } else if result == 0 {
                    throw CodeMapArtifactContainerError.truncated
                } else if errno != EINTR {
                    throw ioError("artifact-read")
                }
            }
        }
        return data
    }

    private static func preReadExactly(_ descriptor: Int32, byteCount: Int, offset: off_t) throws -> Data {
        var data = Data(count: byteCount)
        var completed = 0
        try data.withUnsafeMutableBytes { rawBuffer in
            while completed < byteCount {
                let result = pread(
                    descriptor,
                    rawBuffer.baseAddress!.advanced(by: completed),
                    byteCount - completed,
                    offset + off_t(completed)
                )
                if result > 0 {
                    completed += result
                } else if result == 0 {
                    throw CodeMapArtifactContainerError.truncated
                } else if errno != EINTR {
                    throw ioError("artifact-pread")
                }
            }
        }
        return data
    }

    private static func streamSHA256(_ descriptor: Int32, byteCount: Int, offset: off_t) throws -> Data {
        var hasher = SHA256()
        var completed = 0
        let chunkByteCount = 64 * 1024
        while completed < byteCount {
            let count = min(chunkByteCount, byteCount - completed)
            let chunk = try preReadExactly(descriptor, byteCount: count, offset: offset + off_t(completed))
            hasher.update(data: chunk)
            completed += count
        }
        return Data(hasher.finalize())
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data[offset ..< offset + 4].reduce(into: UInt32(0)) { result, byte in
            result = (result << 8) | UInt32(byte)
        }
    }

    private static func writeAll(_ descriptor: Int32, data: Data) throws {
        try data.withUnsafeBytes { rawBuffer in
            var completed = 0
            while completed < rawBuffer.count {
                let result = Darwin.write(
                    descriptor,
                    rawBuffer.baseAddress!.advanced(by: completed),
                    rawBuffer.count - completed
                )
                if result > 0 {
                    completed += result
                } else if result == 0 {
                    throw ioError("artifact-write-zero")
                } else if errno != EINTR {
                    throw ioError("artifact-write")
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

    private static func isCanonicalShard(_ value: String) -> Bool {
        value.utf8.count == 2 && value.utf8.allSatisfy { byte in
            (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(byte) ||
                (UInt8(ascii: "a") ... UInt8(ascii: "f")).contains(byte)
        }
    }

    private static func isCanonicalDigest(_ value: String) -> Bool {
        value.count == 64 && value == value.lowercased() && value.utf8.allSatisfy {
            (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains($0) ||
                (UInt8(ascii: "a") ... UInt8(ascii: "f")).contains($0)
        }
    }

    private static func validatedTemporaryPID(_ value: String) -> pid_t? {
        let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 4,
              pieces[0].isEmpty,
              pieces[1] == "tmp",
              let pid = pid_t(pieces[2]),
              pid > 0
        else { return nil }
        let uuidString = String(pieces[3])
        guard uuidString == uuidString.lowercased(),
              let uuid = UUID(uuidString: uuidString),
              uuid.uuidString.lowercased() == uuidString
        else { return nil }
        return pid
    }

    private static func processIsActive(_ pid: pid_t) -> Bool {
        if pid == getpid() { return true }
        if kill(pid, 0) == 0 { return true }
        return errno != ESRCH
    }

    private static func ioError(_ operation: String) -> CodeMapArtifactFileStoreError {
        CodeMapArtifactFileStoreError.ioFailure(operation: operation, code: errno)
    }
}

private final class DirectoryDescriptor {
    let rawValue: Int32
    let identity: DirectoryIdentity

    init(rawValue: Int32, identity: DirectoryIdentity) {
        self.rawValue = rawValue
        self.identity = identity
    }

    deinit {
        Darwin.close(rawValue)
    }
}

private struct Layout {
    let root: DirectoryDescriptor
    let namespace: DirectoryDescriptor
    let version: DirectoryDescriptor
    let artifacts: DirectoryDescriptor
    let quarantine: DirectoryDescriptor
}

private struct DirectoryIdentity: Equatable {
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

private struct FileIdentity: Equatable {
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

    func isSecureRegularFile(in expectedDevice: dev_t) throws -> Bool {
        type == mode_t(S_IFREG) &&
            owner == getuid() &&
            permissions == mode_t(0o600) &&
            linkCount == 1 &&
            device == expectedDevice
    }

    func sameObject(as other: FileIdentity) -> Bool {
        device == other.device && inode == other.inode
    }
}

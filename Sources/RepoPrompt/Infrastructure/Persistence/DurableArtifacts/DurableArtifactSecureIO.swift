import CryptoKit
import Darwin
import Foundation
import Security

enum DurableArtifactCrashPoint: CaseIterable {
    case beforeObjectInstall
    case afterObjectInstallBeforeValidation
    case afterObjectTemporaryWrite
    case afterObjectFileSync
    case afterObjectRename
    case afterObjectDirectorySync
    case beforeCatalogInstall
    case afterCatalogInstallBeforeValidation
    case afterCatalogFileSync
    case afterCatalogRename
    case afterCatalogDirectorySync
    case afterQuarantineRename
    case beforeLockPathRevalidation
    case beforeIdentitySafeRemoval
    case afterFamilyDisableSync
    case afterSaltFileSync
    case afterSaltRename
    case afterObsoleteVersionRename
}

struct DurableArtifactStoreHooks: @unchecked Sendable {
    var now: @Sendable () -> UInt64
    var randomBytes: @Sendable (Int) throws -> Data
    var token: @Sendable () -> String
    var crash: @Sendable (DurableArtifactCrashPoint) throws -> Void
    var transformDigest: @Sendable (Data) throws -> Data

    static let live = DurableArtifactStoreHooks(
        now: { UInt64(max(0, Date().timeIntervalSince1970)) },
        randomBytes: { count in
            var bytes = Data(count: count)
            let status = bytes.withUnsafeMutableBytes { buffer in
                SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
            }
            guard status == errSecSuccess else {
                throw DurableArtifactStoreError.ioFailure(operation: "secure-random", code: Int32(status))
            }
            return bytes
        },
        token: { UUID().uuidString.lowercased() },
        crash: { _ in },
        transformDigest: { $0 }
    )
}

final class DurableArtifactDescriptor: @unchecked Sendable {
    private(set) var rawValue: Int32

    init(_ rawValue: Int32) {
        self.rawValue = rawValue
    }

    func close() {
        guard rawValue >= 0 else { return }
        Darwin.close(rawValue)
        rawValue = -1
    }

    deinit {
        close()
    }
}

struct DurableArtifactFileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
    let owner: uid_t
    let type: mode_t
    let permissions: mode_t
    let linkCount: nlink_t
    let size: off_t
    let modificationSeconds: Int64

    var isRegular: Bool {
        type == S_IFREG
    }

    var isDirectory: Bool {
        type == S_IFDIR
    }

    func isSameSecureDirectory(as other: DurableArtifactFileIdentity) -> Bool {
        device == other.device
            && inode == other.inode
            && owner == other.owner
            && type == other.type
            && permissions == other.permissions
    }
}

final class DurableArtifactDirectory: @unchecked Sendable {
    let descriptor: DurableArtifactDescriptor
    let identity: DurableArtifactFileIdentity

    init(descriptor: Int32, identity: DurableArtifactFileIdentity) {
        self.descriptor = DurableArtifactDescriptor(descriptor)
        self.identity = identity
    }
}

final class DurableArtifactLayout: @unchecked Sendable {
    let rootURL: URL
    let parent: DurableArtifactDirectory
    let rootName: String
    let root: DurableArtifactDirectory
    let version: DurableArtifactDirectory
    let objects: DurableArtifactDirectory
    let locks: DurableArtifactDirectory
    let objectLocks: DurableArtifactDirectory
    let catalogLocks: DurableArtifactDirectory
    let catalogs: DurableArtifactDirectory
    let disabled: DurableArtifactDirectory
    let quarantine: DurableArtifactDirectory
    let work: DurableArtifactDirectory

    init(
        rootURL: URL,
        parent: DurableArtifactDirectory,
        rootName: String,
        root: DurableArtifactDirectory,
        version: DurableArtifactDirectory,
        objects: DurableArtifactDirectory,
        locks: DurableArtifactDirectory,
        objectLocks: DurableArtifactDirectory,
        catalogLocks: DurableArtifactDirectory,
        catalogs: DurableArtifactDirectory,
        disabled: DurableArtifactDirectory,
        quarantine: DurableArtifactDirectory,
        work: DurableArtifactDirectory
    ) {
        self.rootURL = rootURL
        self.parent = parent
        self.rootName = rootName
        self.root = root
        self.version = version
        self.objects = objects
        self.locks = locks
        self.objectLocks = objectLocks
        self.catalogLocks = catalogLocks
        self.catalogs = catalogs
        self.disabled = disabled
        self.quarantine = quarantine
        self.work = work
    }
}

enum DurableArtifactSecureIO {
    static let directoryMode: mode_t = 0o700
    static let fileMode: mode_t = 0o600

    static func openLayout(applicationSupportURL: URL, buildFlavor: String) throws -> DurableArtifactLayout {
        guard isSafeComponent(buildFlavor), !buildFlavor.hasPrefix(".") else {
            throw DurableArtifactStoreError.invalidBuildFlavor
        }
        let parentDescriptor = open(applicationSupportURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentDescriptor >= 0 else { throw ioError("application-support-open") }
        let parentIdentity = try identity(parentDescriptor)
        guard parentIdentity.isDirectory, parentIdentity.owner == geteuid() else {
            Darwin.close(parentDescriptor)
            throw DurableArtifactStoreError.insecureEntry
        }
        let parent = DurableArtifactDirectory(descriptor: parentDescriptor, identity: parentIdentity)
        let rootName = "WorkspaceDurableArtifacts-\(buildFlavor)"
        let root = try ownedDirectory(parent: parent, name: rootName, create: true)
        let version = try ownedDirectory(parent: root, name: "v1", create: true)
        let objects = try ownedDirectory(parent: version, name: "objects", create: true)
        let locks = try ownedDirectory(parent: version, name: "locks", create: true)
        let objectLocks = try ownedDirectory(parent: locks, name: "objects", create: true)
        let catalogLocks = try ownedDirectory(parent: locks, name: "catalogs", create: true)
        let catalogs = try ownedDirectory(parent: version, name: "catalogs", create: true)
        let disabled = try ownedDirectory(parent: version, name: "disabled", create: true)
        let quarantine = try ownedDirectory(parent: version, name: "quarantine", create: true)
        let work = try ownedDirectory(parent: version, name: "work", create: true)
        try ensureStableLock(parent: root, name: ".layout.lock")
        try ensureStableLock(parent: version, name: "maintenance.lock")
        return DurableArtifactLayout(
            rootURL: applicationSupportURL.appendingPathComponent(rootName, isDirectory: true),
            parent: parent,
            rootName: rootName,
            root: root,
            version: version,
            objects: objects,
            locks: locks,
            objectLocks: objectLocks,
            catalogLocks: catalogLocks,
            catalogs: catalogs,
            disabled: disabled,
            quarantine: quarantine,
            work: work
        )
    }

    static func ownedDirectory(
        parent: DurableArtifactDirectory,
        name: String,
        create: Bool
    ) throws -> DurableArtifactDirectory {
        guard isSafeComponent(name) else { throw DurableArtifactStoreError.insecureEntry }
        var created = false
        if create {
            if mkdirat(parent.descriptor.rawValue, name, directoryMode) == 0 {
                created = true
            } else if errno != EEXIST {
                throw ioError("directory-create")
            }
        }
        let descriptor = openat(parent.descriptor.rawValue, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ioError("directory-open") }
        do {
            if created, fchmod(descriptor, directoryMode) != 0 { throw ioError("directory-mode") }
            let value = try identity(descriptor)
            guard value.isDirectory,
                  value.owner == geteuid(),
                  value.permissions == directoryMode,
                  value.device == parent.identity.device,
                  try pathIdentity(parent: parent, name: name) == value
            else { throw DurableArtifactStoreError.insecureEntry }
            if created { try synchronize(parent.descriptor.rawValue, operation: "directory-parent-sync") }
            return DurableArtifactDirectory(descriptor: descriptor, identity: value)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    static func optionalOwnedDirectory(parent: DurableArtifactDirectory, name: String) throws -> DurableArtifactDirectory? {
        guard isSafeComponent(name) else { throw DurableArtifactStoreError.insecureEntry }
        let descriptor = openat(parent.descriptor.rawValue, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw ioError("directory-open") }
        do {
            let value = try identity(descriptor)
            guard value.isDirectory,
                  value.owner == geteuid(),
                  value.permissions == directoryMode,
                  value.device == parent.identity.device,
                  try pathIdentity(parent: parent, name: name) == value
            else { throw DurableArtifactStoreError.insecureEntry }
            return DurableArtifactDirectory(descriptor: descriptor, identity: value)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    static func ensureStableLock(parent: DurableArtifactDirectory, name: String) throws {
        let descriptor = try openOrCreateFile(parent: parent, name: name)
        defer { descriptor.close() }
        _ = try validateRegularFile(descriptor: descriptor.rawValue, parent: parent, name: name)
    }

    static func openOrCreateFile(
        parent: DurableArtifactDirectory,
        name: String,
        beforeLockBindingPublish: (() throws -> Void)? = nil
    ) throws -> DurableArtifactDescriptor {
        guard isSafeComponent(name) else { throw DurableArtifactStoreError.insecureEntry }
        var created = false
        var descriptor = openat(
            parent.descriptor.rawValue,
            name,
            O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            fileMode
        )
        if descriptor >= 0 {
            created = true
        } else if errno == EEXIST {
            descriptor = openat(parent.descriptor.rawValue, name, O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw ioError("file-open-or-create") }
        do {
            if created, fchmod(descriptor, fileMode) != 0 { throw ioError("file-mode") }
            let lockIdentity = try validateRegularFile(descriptor: descriptor, parent: parent, name: name)
            if created { try synchronize(parent.descriptor.rawValue, operation: "file-parent-sync") }
            try ensureStableLockBinding(
                parent: parent,
                lockName: name,
                lockIdentity: lockIdentity,
                beforePublish: beforeLockBindingPublish
            )
            guard try validateRegularFile(descriptor: descriptor, parent: parent, name: name) == lockIdentity else {
                throw DurableArtifactStoreError.insecureEntry
            }
            return DurableArtifactDescriptor(descriptor)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func ensureStableLockBinding(
        parent: DurableArtifactDirectory,
        lockName: String,
        lockIdentity: DurableArtifactFileIdentity,
        beforePublish: (() throws -> Void)?
    ) throws {
        let bindingDigest = SHA256.hash(data: Data(lockName.utf8)).map { String(format: "%02x", $0) }.joined()
        let bindingName = ".lock-binding.\(bindingDigest)"
        var writer = DurableArtifactBinaryWriter()
        writer.append(Data("RPDLOCK1".utf8))
        writer.append(UInt64(bitPattern: Int64(lockIdentity.device)))
        writer.append(UInt64(lockIdentity.inode))
        let expected = writer.data

        func validatePublishedBinding() throws {
            guard let opened = try openRegularFile(parent: parent, name: bindingName) else {
                throw DurableArtifactStoreError.insecureEntry
            }
            defer { opened.0.close() }
            guard opened.1.size == expected.count,
                  try preadExactly(opened.0.rawValue, offset: 0, count: expected.count) == expected,
                  try hasExactEOF(opened.0.rawValue, offset: off_t(expected.count)),
                  try identity(opened.0.rawValue) == opened.1,
                  try pathIdentity(parent: parent, name: bindingName) == opened.1
            else { throw DurableArtifactStoreError.insecureEntry }
        }

        if let existing = try openRegularFile(parent: parent, name: bindingName) {
            existing.0.close()
            try validatePublishedBinding()
            return
        }

        let temporaryName = ".lock-binding.tmp.\(bindingDigest).\(UUID().uuidString.lowercased())"
        let temporary = try createExclusiveFile(parent: parent, name: temporaryName)
        var temporaryIdentity: DurableArtifactFileIdentity?
        defer {
            if let temporaryIdentity {
                _ = try? removeIfSame(
                    parent: parent,
                    name: temporaryName,
                    descriptor: temporary.rawValue,
                    identity: temporaryIdentity
                )
            }
            temporary.close()
        }
        try writeAll(temporary.rawValue, data: expected)
        try synchronize(temporary.rawValue, operation: "lock-binding-temp-sync")
        temporaryIdentity = try validateRegularFile(
            descriptor: temporary.rawValue,
            parent: parent,
            name: temporaryName
        )
        guard temporaryIdentity!.size == expected.count,
              try preadExactly(temporary.rawValue, offset: 0, count: expected.count) == expected,
              try hasExactEOF(temporary.rawValue, offset: off_t(expected.count))
        else { throw DurableArtifactStoreError.insecureEntry }
        try beforePublish?()
        if let installed = try installValidatedDescriptorNoReplace(
            sourceDescriptor: temporary.rawValue,
            sourceIdentity: temporaryIdentity!,
            destinationParent: parent,
            destinationName: bindingName
        ) {
            installed.0.close()
        }
        try validatePublishedBinding()
    }

    static func createExclusiveFile(parent: DurableArtifactDirectory, name: String) throws -> DurableArtifactDescriptor {
        guard isSafeComponent(name) else { throw DurableArtifactStoreError.insecureEntry }
        let descriptor = openat(
            parent.descriptor.rawValue,
            name,
            O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            fileMode
        )
        guard descriptor >= 0 else { throw ioError("exclusive-file-create") }
        do {
            guard fchmod(descriptor, fileMode) == 0 else { throw ioError("exclusive-file-mode") }
            _ = try validateRegularFile(descriptor: descriptor, parent: parent, name: name)
            return DurableArtifactDescriptor(descriptor)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    static func openRegularFile(
        parent: DurableArtifactDirectory,
        name: String,
        writable: Bool = false
    ) throws -> (DurableArtifactDescriptor, DurableArtifactFileIdentity)? {
        guard isSafeComponent(name) else { throw DurableArtifactStoreError.insecureEntry }
        let access = writable ? O_RDWR : O_RDONLY
        let descriptor = openat(parent.descriptor.rawValue, name, access | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw ioError("regular-file-open") }
        do {
            let value = try validateRegularFile(descriptor: descriptor, parent: parent, name: name)
            return (DurableArtifactDescriptor(descriptor), value)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    static func validateRegularFile(
        descriptor: Int32,
        parent: DurableArtifactDirectory,
        name: String
    ) throws -> DurableArtifactFileIdentity {
        let value = try identity(descriptor)
        guard value.isRegular,
              value.owner == geteuid(),
              value.permissions == fileMode,
              value.linkCount == 1,
              value.device == parent.identity.device,
              try pathIdentity(parent: parent, name: name) == value
        else { throw DurableArtifactStoreError.insecureEntry }
        return value
    }

    static func validateDirectoryPath(
        _ directory: DurableArtifactDirectory,
        parent: DurableArtifactDirectory,
        name: String
    ) throws {
        let descriptorIdentity = try identity(directory.descriptor.rawValue)
        let currentPathIdentity = try pathIdentity(parent: parent, name: name)
        guard descriptorIdentity.isSameSecureDirectory(as: directory.identity),
              currentPathIdentity.isSameSecureDirectory(as: descriptorIdentity)
        else { throw DurableArtifactStoreError.insecureEntry }
    }

    static func identity(_ descriptor: Int32) throws -> DurableArtifactFileIdentity {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw ioError("fstat") }
        return identity(status)
    }

    static func pathIdentity(parent: DurableArtifactDirectory, name: String) throws -> DurableArtifactFileIdentity {
        var status = stat()
        guard fstatat(parent.descriptor.rawValue, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw ioError("fstatat")
        }
        return identity(status)
    }

    private static func identity(_ status: stat) -> DurableArtifactFileIdentity {
        DurableArtifactFileIdentity(
            device: status.st_dev,
            inode: status.st_ino,
            owner: status.st_uid,
            type: status.st_mode & S_IFMT,
            permissions: status.st_mode & 0o777,
            linkCount: status.st_nlink,
            size: status.st_size,
            modificationSeconds: Int64(status.st_mtimespec.tv_sec)
        )
    }

    static func withLock<T>(
        _ descriptor: DurableArtifactDescriptor,
        exclusive: Bool,
        nonBlocking: Bool,
        _ body: () throws -> T
    ) throws -> T? {
        let operation = (exclusive ? LOCK_EX : LOCK_SH) | (nonBlocking ? LOCK_NB : 0)
        while flock(descriptor.rawValue, operation) != 0 {
            if errno == EINTR { continue }
            if nonBlocking, errno == EWOULDBLOCK || errno == EAGAIN { return nil }
            throw ioError("flock")
        }
        defer { _ = flock(descriptor.rawValue, LOCK_UN) }
        return try body()
    }

    static func lockDescriptor(
        parent: DurableArtifactDirectory,
        name: String,
        exclusive: Bool,
        nonBlocking: Bool
    ) throws -> DurableArtifactDescriptor? {
        let descriptor = try openOrCreateFile(parent: parent, name: name)
        let lockedIdentity = try validateRegularFile(
            descriptor: descriptor.rawValue,
            parent: parent,
            name: name
        )
        let operation = (exclusive ? LOCK_EX : LOCK_SH) | (nonBlocking ? LOCK_NB : 0)
        while flock(descriptor.rawValue, operation) != 0 {
            if errno == EINTR { continue }
            if nonBlocking, errno == EWOULDBLOCK || errno == EAGAIN {
                descriptor.close()
                return nil
            }
            descriptor.close()
            throw ioError("flock")
        }
        guard try identity(descriptor.rawValue) == lockedIdentity,
              try pathIdentity(parent: parent, name: name) == lockedIdentity
        else {
            _ = flock(descriptor.rawValue, LOCK_UN)
            descriptor.close()
            throw DurableArtifactStoreError.insecureEntry
        }
        return descriptor
    }

    static func writeAll(_ descriptor: Int32, data: Data) throws {
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let result = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { throw ioError("write") }
                offset += result
            }
        }
    }

    static func preadExactly(_ descriptor: Int32, offset: off_t, count: Int) throws -> Data {
        guard count >= 0 else { throw DurableArtifactStoreError.invalidFraming }
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var consumed = 0
            while consumed < count {
                let (position, overflow) = offset.addingReportingOverflow(off_t(consumed))
                guard !overflow else { throw DurableArtifactStoreError.invalidFraming }
                let result = Darwin.pread(descriptor, base.advanced(by: consumed), count - consumed, position)
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { throw DurableArtifactStoreError.invalidFraming }
                consumed += result
            }
        }
        return data
    }

    static func hasExactEOF(_ descriptor: Int32, offset: off_t) throws -> Bool {
        var byte: UInt8 = 0
        while true {
            let result = Darwin.pread(descriptor, &byte, 1, offset)
            if result < 0, errno == EINTR { continue }
            if result < 0 { throw ioError("pread-eof") }
            return result == 0
        }
    }

    static func descriptorsEqual(
        lhs: Int32,
        lhsIdentity: DurableArtifactFileIdentity,
        rhs: Int32,
        rhsIdentity: DurableArtifactFileIdentity,
        bufferByteCount: Int = 64 * 1024
    ) throws -> Bool {
        guard lhsIdentity.size == rhsIdentity.size, lhsIdentity.size >= 0 else { return false }
        var offset: off_t = 0
        while offset < lhsIdentity.size {
            let count = min(max(4096, bufferByteCount), Int(lhsIdentity.size - offset))
            guard try preadExactly(lhs, offset: offset, count: count)
                == preadExactly(rhs, offset: offset, count: count)
            else { return false }
            offset += off_t(count)
        }
        return try hasExactEOF(lhs, offset: lhsIdentity.size)
            && hasExactEOF(rhs, offset: rhsIdentity.size)
    }

    static func synchronize(_ descriptor: Int32, operation: String) throws {
        while fsync(descriptor) != 0 {
            if errno == EINTR { continue }
            throw ioError(operation)
        }
    }

    static func noReplaceRename(
        fromParent: DurableArtifactDirectory,
        from: String,
        toParent: DurableArtifactDirectory,
        to: String
    ) throws -> Bool {
        let result = renameatx_np(
            fromParent.descriptor.rawValue,
            from,
            toParent.descriptor.rawValue,
            to,
            UInt32(RENAME_EXCL)
        )
        if result == 0 { return true }
        if errno == EEXIST { return false }
        throw ioError("rename-no-replace")
    }

    static func installValidatedDescriptorNoReplace(
        sourceDescriptor: Int32,
        sourceIdentity: DurableArtifactFileIdentity,
        destinationParent: DurableArtifactDirectory,
        destinationName: String
    ) throws -> (DurableArtifactDescriptor, DurableArtifactFileIdentity)? {
        guard sourceIdentity.isRegular,
              sourceIdentity.size >= 0,
              try identity(sourceDescriptor) == sourceIdentity
        else { throw DurableArtifactStoreError.insecureEntry }

        return try withDirectoryMutationAuthority(destinationParent) {
            if fclonefileat(sourceDescriptor, destinationParent.descriptor.rawValue, destinationName, 0) != 0 {
                if errno == EEXIST { return nil }
                throw ioError("descriptor-clone-install")
            }

            guard let installed = try openRegularFile(parent: destinationParent, name: destinationName) else {
                throw DurableArtifactStoreError.insecureEntry
            }
            guard try descriptorsEqual(
                lhs: sourceDescriptor,
                lhsIdentity: sourceIdentity,
                rhs: installed.0.rawValue,
                rhsIdentity: installed.1
            ), try identity(sourceDescriptor) == sourceIdentity,
            try identity(installed.0.rawValue) == installed.1,
            try pathIdentity(parent: destinationParent, name: destinationName) == installed.1
            else {
                installed.0.close()
                throw DurableArtifactStoreError.insecureEntry
            }
            try synchronize(installed.0.rawValue, operation: "descriptor-clone-file-sync")
            guard try identity(sourceDescriptor) == sourceIdentity,
                  try identity(installed.0.rawValue) == installed.1,
                  try pathIdentity(parent: destinationParent, name: destinationName) == installed.1
            else {
                installed.0.close()
                throw DurableArtifactStoreError.insecureEntry
            }
            try synchronize(destinationParent.descriptor.rawValue, operation: "descriptor-clone-directory-sync")
            guard try identity(installed.0.rawValue) == installed.1,
                  try pathIdentity(parent: destinationParent, name: destinationName) == installed.1
            else {
                installed.0.close()
                throw DurableArtifactStoreError.insecureEntry
            }
            return installed
        }
    }

    static func swapEntries(
        firstParent: DurableArtifactDirectory,
        firstName: String,
        secondParent: DurableArtifactDirectory,
        secondName: String
    ) throws {
        guard renameatx_np(
            firstParent.descriptor.rawValue,
            firstName,
            secondParent.descriptor.rawValue,
            secondName,
            UInt32(RENAME_SWAP)
        ) == 0 else { throw ioError("rename-swap") }
    }

    static func replacingRename(
        fromParent: DurableArtifactDirectory,
        from: String,
        toParent: DurableArtifactDirectory,
        to: String
    ) throws {
        guard renameat(
            fromParent.descriptor.rawValue,
            from,
            toParent.descriptor.rawValue,
            to
        ) == 0 else { throw ioError("rename-replace") }
    }

    static func removeIfSame(
        parent: DurableArtifactDirectory,
        name: String,
        descriptor: Int32,
        identity expected: DurableArtifactFileIdentity,
        beforeCapturedUnlink: (() throws -> Void)? = nil
    ) throws -> Bool {
        guard try identity(descriptor) == expected else { return false }
        let capturedName = ".captured.\(UUID().uuidString.lowercased()).tombstone"
        do {
            guard try noReplaceRename(
                fromParent: parent,
                from: name,
                toParent: parent,
                to: capturedName
            ) else { return false }
        } catch DurableArtifactStoreError.ioFailure(_, ENOENT) {
            return false
        }
        let captured: (DurableArtifactDescriptor, DurableArtifactFileIdentity)
        do {
            guard let opened = try openRegularFile(parent: parent, name: capturedName) else {
                return false
            }
            captured = opened
        } catch {
            try restoreCapturedEntryIfPossible(
                parent: parent,
                capturedName: capturedName,
                originalName: name
            )
            return false
        }
        defer { captured.0.close() }
        guard try capturedEntryMatches(
            expectedDescriptor: descriptor,
            expectedIdentity: expected,
            capturedDescriptor: captured.0.rawValue,
            capturedIdentity: captured.1,
            parent: parent,
            capturedName: capturedName
        ) else {
            try restoreCapturedEntryIfPossible(
                parent: parent,
                capturedName: capturedName,
                originalName: name
            )
            return false
        }
        try beforeCapturedUnlink?()
        guard try capturedEntryMatches(
            expectedDescriptor: descriptor,
            expectedIdentity: expected,
            capturedDescriptor: captured.0.rawValue,
            capturedIdentity: captured.1,
            parent: parent,
            capturedName: capturedName
        ) else {
            return false
        }
        guard unlinkat(parent.descriptor.rawValue, capturedName, 0) == 0 else {
            if errno == ENOENT { return false }
            throw ioError("captured-unlink")
        }
        try synchronize(parent.descriptor.rawValue, operation: "captured-unlink-parent-sync")
        return try entryIsMissing(parent: parent, name: name)
    }

    static func removeDirectoryIfSame(
        parent: DurableArtifactDirectory,
        name: String,
        directory: DurableArtifactDirectory
    ) throws -> Bool {
        let expected = try identity(directory.descriptor.rawValue)
        guard expected.isSameSecureDirectory(as: directory.identity) else { return false }
        let capturedName = ".captured-directory.\(UUID().uuidString.lowercased()).tombstone"
        do {
            guard try noReplaceRename(
                fromParent: parent,
                from: name,
                toParent: parent,
                to: capturedName
            ) else { return false }
        } catch DurableArtifactStoreError.ioFailure(_, ENOENT) {
            return false
        }
        guard try identity(directory.descriptor.rawValue).isSameSecureDirectory(as: expected),
              try pathIdentity(parent: parent, name: capturedName).isSameSecureDirectory(as: expected)
        else {
            try restoreCapturedEntryIfPossible(
                parent: parent,
                capturedName: capturedName,
                originalName: name
            )
            return false
        }
        guard unlinkat(parent.descriptor.rawValue, capturedName, AT_REMOVEDIR) == 0 else {
            if errno == ENOENT { return false }
            throw ioError("captured-directory-unlink")
        }
        try synchronize(parent.descriptor.rawValue, operation: "captured-directory-parent-sync")
        return try entryIsMissing(parent: parent, name: name)
    }

    private static func capturedEntryMatches(
        expectedDescriptor: Int32,
        expectedIdentity: DurableArtifactFileIdentity,
        capturedDescriptor: Int32,
        capturedIdentity: DurableArtifactFileIdentity,
        parent: DurableArtifactDirectory,
        capturedName: String
    ) throws -> Bool {
        try identity(expectedDescriptor) == expectedIdentity
            && identity(capturedDescriptor) == capturedIdentity
            && capturedIdentity == expectedIdentity
            && pathIdentity(parent: parent, name: capturedName) == capturedIdentity
            && descriptorsEqual(
                lhs: expectedDescriptor,
                lhsIdentity: expectedIdentity,
                rhs: capturedDescriptor,
                rhsIdentity: capturedIdentity
            )
    }

    private static func restoreCapturedEntryIfPossible(
        parent: DurableArtifactDirectory,
        capturedName: String,
        originalName: String
    ) throws {
        do {
            if try noReplaceRename(
                fromParent: parent,
                from: capturedName,
                toParent: parent,
                to: originalName
            ) {
                try synchronize(parent.descriptor.rawValue, operation: "captured-restore-parent-sync")
            }
        } catch DurableArtifactStoreError.ioFailure(_, ENOENT) {
            return
        }
    }

    private static func entryIsMissing(parent: DurableArtifactDirectory, name: String) throws -> Bool {
        var status = stat()
        if fstatat(parent.descriptor.rawValue, name, &status, AT_SYMLINK_NOFOLLOW) == 0 { return false }
        if errno == ENOENT { return true }
        throw ioError("captured-original-check")
    }

    private static func withDirectoryMutationAuthority<T>(
        _ directory: DurableArtifactDirectory,
        _ body: () throws -> T
    ) throws -> T {
        let authority = openat(
            directory.descriptor.rawValue,
            ".",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard authority >= 0 else { throw ioError("directory-authority-open") }
        defer { Darwin.close(authority) }
        guard try identity(authority).isSameSecureDirectory(as: directory.identity) else {
            throw DurableArtifactStoreError.insecureEntry
        }
        while flock(authority, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            throw ioError("directory-authority-flock")
        }
        defer { _ = flock(authority, LOCK_UN) }
        guard try identity(authority).isSameSecureDirectory(as: directory.identity) else {
            throw DurableArtifactStoreError.insecureEntry
        }
        return try body()
    }

    static func forEachEntry(
        in directory: DurableArtifactDirectory,
        _ body: (String) throws -> Void
    ) throws {
        let iterationDescriptor = openat(
            directory.descriptor.rawValue,
            ".",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard iterationDescriptor >= 0 else { throw ioError("directory-iteration-open") }
        let iterationIdentity = try identity(iterationDescriptor)
        guard iterationIdentity.isSameSecureDirectory(as: directory.identity) else {
            Darwin.close(iterationDescriptor)
            throw DurableArtifactStoreError.insecureEntry
        }
        guard let stream = fdopendir(iterationDescriptor) else {
            Darwin.close(iterationDescriptor)
            throw ioError("fdopendir")
        }
        defer { closedir(stream) }
        errno = 0
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            try body(name)
            errno = 0
        }
        guard errno == 0 else { throw ioError("readdir") }
    }

    static func availableBytes(_ directory: DurableArtifactDirectory) throws -> UInt64 {
        var status = statfs()
        guard fstatfs(directory.descriptor.rawValue, &status) == 0 else { throw ioError("fstatfs") }
        guard status.f_bavail >= 0, status.f_bsize > 0 else { return 0 }
        let blocks = UInt64(status.f_bavail)
        let size = UInt64(status.f_bsize)
        let (value, overflow) = blocks.multipliedReportingOverflow(by: size)
        return overflow ? UInt64.max : value
    }

    static func isSafeComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\0")
    }

    static func ioError(_ operation: String) -> DurableArtifactStoreError {
        DurableArtifactStoreError.ioFailure(operation: operation, code: errno)
    }
}

struct DurableArtifactBinaryWriter {
    private(set) var data = Data()

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

struct DurableArtifactBinaryReader {
    let data: Data
    private(set) var offset = 0

    mutating func readUInt8() throws -> UInt8 {
        guard offset < data.count else { throw DurableArtifactStoreError.invalidFraming }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readUInt32() throws -> UInt32 {
        let bytes = try read(count: 4)
        return bytes.reduce(into: UInt32(0)) { $0 = ($0 << 8) | UInt32($1) }
    }

    mutating func readUInt64() throws -> UInt64 {
        let bytes = try read(count: 8)
        return bytes.reduce(into: UInt64(0)) { $0 = ($0 << 8) | UInt64($1) }
    }

    mutating func read(count: Int) throws -> Data {
        guard count >= 0, offset <= data.count, count <= data.count - offset else {
            throw DurableArtifactStoreError.invalidFraming
        }
        defer { offset += count }
        return data.subdata(in: offset ..< offset + count)
    }
}

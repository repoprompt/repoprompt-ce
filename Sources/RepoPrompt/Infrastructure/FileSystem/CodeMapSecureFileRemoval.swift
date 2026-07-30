import Darwin
import Foundation

enum CodeMapSecureFileRemovalError: Error, Equatable {
    case insecureEntry
    case ioFailure(operation: String, code: Int32)
}

struct CodeMapSecureFileRemovalHooks: @unchecked Sendable {
    let beforePrivateRename: ((Int32, String) throws -> Void)?
    let afterPrivateRename: ((Int32, String, String) throws -> Void)?
    let directorySynchronize: ((Int32) -> Int32)?

    init(
        beforePrivateRename: ((Int32, String) throws -> Void)? = nil,
        afterPrivateRename: ((Int32, String, String) throws -> Void)? = nil,
        directorySynchronize: ((Int32) -> Int32)? = nil
    ) {
        self.beforePrivateRename = beforePrivateRename
        self.afterPrivateRename = afterPrivateRename
        self.directorySynchronize = directorySynchronize
    }
}

/// Removes a verified regular file without resolving its public pathname at unlink time.
/// The source is first moved to an operation-private name in the same directory, the moved
/// inode is compared with the held descriptor, and only that private name is unlinked.
enum CodeMapSecureFileRemoval {
    private static let secureFileMode = mode_t(0o600)
    private static let maximumPrivateNameAttempts = 8

    static func privateRemovalPID(_ value: String) -> pid_t? {
        let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 4, pieces[0].isEmpty, pieces[1] == "delete",
              let pid = pid_t(pieces[2]), pid > 0
        else { return nil }
        let token = String(pieces[3])
        guard token == token.lowercased(),
              let uuid = UUID(uuidString: token),
              uuid.uuidString.lowercased() == token
        else { return nil }
        return pid
    }

    @discardableResult
    static func remove(
        parentDescriptor: Int32,
        expectedDevice: dev_t,
        name: String,
        heldDescriptor: Int32? = nil,
        hooks: CodeMapSecureFileRemovalHooks? = nil
    ) throws -> Bool {
        let descriptor: Int32
        let ownsDescriptor: Bool
        if let heldDescriptor {
            descriptor = heldDescriptor
            ownsDescriptor = false
        } else {
            descriptor = openat(parentDescriptor, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            if descriptor < 0, errno == ENOENT { return false }
            guard descriptor >= 0 else { throw ioError("open") }
            ownsDescriptor = true
        }
        defer {
            if ownsDescriptor { Darwin.close(descriptor) }
        }

        let expected = try fileIdentity(descriptor)
        guard expected.isSecureRegular(in: expectedDevice),
              try pathIdentity(parentDescriptor: parentDescriptor, name: name) == expected
        else { throw CodeMapSecureFileRemovalError.insecureEntry }

        try hooks?.beforePrivateRename?(parentDescriptor, name)

        var privateName: String?
        for _ in 0 ..< maximumPrivateNameAttempts {
            let candidate = ".delete.\(getpid()).\(UUID().uuidString.lowercased())"
            if renameatx_np(
                parentDescriptor,
                name,
                parentDescriptor,
                candidate,
                UInt32(RENAME_EXCL)
            ) == 0 {
                privateName = candidate
                break
            }
            if errno == ENOENT { return false }
            guard errno == EEXIST else { throw ioError("private-rename") }
        }
        guard let privateName else {
            throw CodeMapSecureFileRemovalError.ioFailure(operation: "private-rename", code: EBUSY)
        }

        try hooks?.afterPrivateRename?(parentDescriptor, name, privateName)

        let movedDescriptorIdentity = try fileIdentity(descriptor)
        guard movedDescriptorIdentity.sameObject(as: expected),
              movedDescriptorIdentity.isSecureRegular(in: expectedDevice),
              try pathIdentity(parentDescriptor: parentDescriptor, name: privateName) == movedDescriptorIdentity
        else {
            // Never unlink an operation-private pathname whose inode no longer matches
            // the descriptor retained from validation.
            throw CodeMapSecureFileRemovalError.insecureEntry
        }
        guard unlinkat(parentDescriptor, privateName, 0) == 0 else {
            if errno == ENOENT { return false }
            throw ioError("private-unlink")
        }
        try synchronize(parentDescriptor, hook: hooks?.directorySynchronize)
        return true
    }

    private static func synchronize(
        _ descriptor: Int32,
        hook: ((Int32) -> Int32)?
    ) throws {
        while (hook?(descriptor) ?? fsync(descriptor)) != 0 {
            guard errno == EINTR else { throw ioError("directory-fsync") }
        }
    }

    private static func fileIdentity(_ descriptor: Int32) throws -> Identity {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw ioError("descriptor-stat") }
        return Identity(status)
    }

    private static func pathIdentity(parentDescriptor: Int32, name: String) throws -> Identity {
        var status = stat()
        guard fstatat(parentDescriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw ioError("path-stat")
        }
        return Identity(status)
    }

    private static func ioError(_ operation: String) -> CodeMapSecureFileRemovalError {
        CodeMapSecureFileRemovalError.ioFailure(operation: operation, code: errno)
    }

    private struct Identity: Equatable {
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

        func isSecureRegular(in expectedDevice: dev_t) -> Bool {
            device == expectedDevice && owner == getuid() && type == mode_t(S_IFREG) &&
                permissions == CodeMapSecureFileRemoval.secureFileMode && linkCount == 1
        }

        func sameObject(as other: Identity) -> Bool {
            device == other.device && inode == other.inode
        }
    }
}

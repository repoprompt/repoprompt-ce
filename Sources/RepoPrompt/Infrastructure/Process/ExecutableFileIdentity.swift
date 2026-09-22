import Darwin
import Foundation

struct ExecutableFileIdentity: Equatable {
    let canonicalPath: String
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let statusChangeSeconds: Int64
    let statusChangeNanoseconds: Int64

    static func capture(atPath rawPath: String) throws -> ExecutableFileIdentity {
        guard rawPath.hasPrefix("/") else {
            throw ExecutableFileIdentityError.pathMustBeAbsolute(rawPath)
        }

        guard let canonicalPath = FileSystemService.realpathString(rawPath) else {
            throw ExecutableFileIdentityError.unavailable((rawPath as NSString).standardizingPath)
        }
        var info = stat()
        guard stat(canonicalPath, &info) == 0 else {
            throw ExecutableFileIdentityError.unavailable(canonicalPath)
        }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw ExecutableFileIdentityError.notRegularFile(canonicalPath)
        }
        guard access(canonicalPath, X_OK) == 0 else {
            throw ExecutableFileIdentityError.notExecutable(canonicalPath)
        }

        return ExecutableFileIdentity(
            canonicalPath: canonicalPath,
            device: safeDeviceID(info.st_dev),
            inode: UInt64(info.st_ino),
            size: Int64(info.st_size),
            modificationSeconds: Int64(info.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            statusChangeSeconds: Int64(info.st_ctimespec.tv_sec),
            statusChangeNanoseconds: Int64(info.st_ctimespec.tv_nsec)
        )
    }

    static func captureForTrustedPathLaunch(atPath path: String) throws -> ExecutableFileIdentity {
        let identity = try capture(atPath: path)
        try validateTrustedOwnershipAndPermissions(atCanonicalPath: identity.canonicalPath)
        return identity
    }

    func validate(atPath path: String) throws {
        let current = try Self.capture(atPath: path)
        guard current == self else {
            throw ExecutableFileIdentityError.identityChanged(
                expectedPath: canonicalPath,
                actualPath: current.canonicalPath
            )
        }
    }

    /// Revalidates identity and rejects launch paths that an untrusted local user can replace.
    /// Root and the current user are trusted globally; admin-group writes are trusted only for ACL-free
    /// canonical Homebrew Cellar paths.
    func validateForTrustedPathLaunch(atPath path: String) throws {
        try validate(atPath: path)
        try Self.validateTrustedOwnershipAndPermissions(atCanonicalPath: canonicalPath)
    }

    static func permitsHomebrewAdminGroupWritableDirectory(
        canonicalPath: String,
        directoryPath: String,
        mode: mode_t,
        ownerUID: uid_t,
        groupGID: gid_t,
        effectiveUID: uid_t
    ) -> Bool {
        guard mode & mode_t(S_IWGRP) != 0,
              mode & mode_t(S_IWOTH) == 0,
              ownerUID == 0 || ownerUID == effectiveUID,
              groupGID == 80
        else {
            return false
        }

        let homebrewLocations = [
            (prefix: "/opt/homebrew", cellar: "/opt/homebrew/Cellar"),
            (prefix: "/usr/local", cellar: "/usr/local/Cellar")
        ]

        return homebrewLocations.contains { location in
            canonicalPath.hasPrefix(location.cellar + "/")
                && (
                    directoryPath == location.prefix
                        || directoryPath == location.cellar
                        || directoryPath.hasPrefix(location.cellar + "/")
                )
        }
    }

    static func directoryHasNoExtendedACL(atPath directoryPath: String) -> Bool {
        let descriptor = open(directoryPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        errno = 0
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            let aclErrno = errno
            return aclErrno == ENOENT
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }

        guard acl_valid(acl) == 0 else { return false }

        var entry: acl_entry_t?
        errno = 0
        let entryResult = acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry)
        let entryErrno = errno
        return entryResult == -1 && entryErrno == EINVAL
    }

    private static func validateTrustedOwnershipAndPermissions(atCanonicalPath canonicalPath: String) throws {
        let effectiveUID = geteuid()
        let trustedUIDs: Set<uid_t> = [0, effectiveUID]
        var executableInfo = stat()
        guard stat(canonicalPath, &executableInfo) == 0 else {
            throw ExecutableFileIdentityError.unavailable(canonicalPath)
        }
        guard trustedUIDs.contains(executableInfo.st_uid) else {
            throw ExecutableFileIdentityError.untrustedOwner(canonicalPath, executableInfo.st_uid)
        }
        guard executableInfo.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0 else {
            throw ExecutableFileIdentityError.untrustedWritableFile(canonicalPath, executableInfo.st_mode)
        }

        var directoryPath = (canonicalPath as NSString).deletingLastPathComponent
        while true {
            var directoryInfo = stat()
            guard stat(directoryPath, &directoryInfo) == 0,
                  directoryInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
            else {
                throw ExecutableFileIdentityError.unavailable(directoryPath)
            }
            guard trustedUIDs.contains(directoryInfo.st_uid) else {
                throw ExecutableFileIdentityError.untrustedOwner(directoryPath, directoryInfo.st_uid)
            }

            let isGroupOrWorldWritable = directoryInfo.st_mode & mode_t(S_IWGRP | S_IWOTH) != 0
            let isRootOwnedStickyDirectory = directoryInfo.st_uid == 0
                && directoryInfo.st_mode & mode_t(S_ISVTX) != 0
            let isPermittedHomebrewDirectory =
                permitsHomebrewAdminGroupWritableDirectory(
                    canonicalPath: canonicalPath,
                    directoryPath: directoryPath,
                    mode: directoryInfo.st_mode,
                    ownerUID: directoryInfo.st_uid,
                    groupGID: directoryInfo.st_gid,
                    effectiveUID: effectiveUID
                )
                && directoryHasNoExtendedACL(atPath: directoryPath)
            guard !isGroupOrWorldWritable || isRootOwnedStickyDirectory || isPermittedHomebrewDirectory else {
                throw ExecutableFileIdentityError.untrustedWritableDirectory(directoryPath, directoryInfo.st_mode)
            }

            let parent = (directoryPath as NSString).deletingLastPathComponent
            if parent == directoryPath || parent.isEmpty { break }
            directoryPath = parent
        }
    }
}

enum ExecutableFileIdentityError: Error, Equatable, LocalizedError {
    case pathMustBeAbsolute(String)
    case unavailable(String)
    case notRegularFile(String)
    case notExecutable(String)
    case identityChanged(expectedPath: String, actualPath: String)
    case untrustedOwner(String, uid_t)
    case untrustedWritableFile(String, mode_t)
    case untrustedWritableDirectory(String, mode_t)

    var errorDescription: String? {
        switch self {
        case let .pathMustBeAbsolute(path):
            "Executable path must be absolute: \(path)"
        case let .unavailable(path):
            "Executable is unavailable: \(path)"
        case let .notRegularFile(path):
            "Executable path is not a regular file: \(path)"
        case let .notExecutable(path):
            "Executable path is not executable: \(path)"
        case let .identityChanged(expectedPath, actualPath):
            "Executable identity changed before launch. Expected \(expectedPath), found \(actualPath)."
        case let .untrustedOwner(path, uid):
            "Executable launch path has an untrusted owner (uid \(uid)): \(path)"
        case let .untrustedWritableFile(path, mode):
            "Executable is group- or world-writable (mode \(String(mode & 0o7777, radix: 8))): \(path)"
        case let .untrustedWritableDirectory(path, mode):
            "Executable directory is replaceable by another user (mode \(String(mode & 0o7777, radix: 8))): \(path)"
        }
    }
}

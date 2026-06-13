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

        let canonicalPath = URL(fileURLWithPath: rawPath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
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
            device: UInt64(info.st_dev),
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

    /// Revalidates identity and rejects launch paths that another local user can replace.
    /// This narrows pathname-spawn TOCTOU exposure to processes running as this same UID.
    func validateForTrustedPathLaunch(atPath path: String) throws {
        try validate(atPath: path)
        try Self.validateTrustedOwnershipAndPermissions(atCanonicalPath: canonicalPath)
    }

    private static func validateTrustedOwnershipAndPermissions(atCanonicalPath canonicalPath: String) throws {
        let trustedUIDs: Set<uid_t> = [0, geteuid()]
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

        var directory = URL(fileURLWithPath: canonicalPath).deletingLastPathComponent()
        while true {
            var directoryInfo = stat()
            guard stat(directory.path, &directoryInfo) == 0,
                  directoryInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
            else {
                throw ExecutableFileIdentityError.unavailable(directory.path)
            }
            guard trustedUIDs.contains(directoryInfo.st_uid) else {
                throw ExecutableFileIdentityError.untrustedOwner(directory.path, directoryInfo.st_uid)
            }

            let isGroupOrWorldWritable = directoryInfo.st_mode & mode_t(S_IWGRP | S_IWOTH) != 0
            let isRootOwnedStickyDirectory = directoryInfo.st_uid == 0
                && directoryInfo.st_mode & mode_t(S_ISVTX) != 0
            guard !isGroupOrWorldWritable || isRootOwnedStickyDirectory else {
                throw ExecutableFileIdentityError.untrustedWritableDirectory(directory.path, directoryInfo.st_mode)
            }

            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
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

import Darwin
import Foundation

/// Pins the owner-only directory controlling bootstrap socket and lock names.
/// Existing unsafe entries are rejected, never repaired or removed.
public final class MCPBootstrapDirectory: @unchecked Sendable {
    public struct DirectoryError: LocalizedError {
        public let path: String
        public let code: Int32
        public var isMissing: Bool {
            code == ENOENT
        }

        init(path: String, code: Int32 = EACCES) {
            self.path = path
            self.code = code
        }

        public var errorDescription: String? {
            "Bootstrap directory is not a stable owner-only directory: \(path)"
        }
    }

    public let descriptor: Int32
    private let url: URL
    private let originalURL: URL
    private let device: dev_t
    private let inode: ino_t

    public static func open(at url: URL, createIfMissing: Bool = false) throws -> MCPBootstrapDirectory {
        // Resolve system aliases such as /tmp, but never follow the final directory entry.
        let originalParent = url.deletingLastPathComponent()
        guard aliasesAreTrusted(originalParent) else { throw DirectoryError(path: url.path) }
        guard let resolved = realpath(originalParent.path, nil) else { throw DirectoryError(path: url.path, code: errno) }
        defer { free(resolved) }
        // Unlike Foundation's resolver, realpath retains /private on macOS.
        let parent = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        let canonicalURL = parent.appendingPathComponent(url.lastPathComponent, isDirectory: true)
        guard ancestorsAreTrusted(parent) else { throw DirectoryError(path: url.path) }
        if createIfMissing, mkdir(canonicalURL.path, mode_t(0o700)) != 0, errno != EEXIST {
            throw DirectoryError(path: url.path, code: errno)
        }
        let fd = Darwin.open(canonicalURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw DirectoryError(path: url.path, code: errno) }
        var info = stat()
        guard fstat(fd, &info) == 0, isPrivateDirectory(info) else {
            Darwin.close(fd)
            throw DirectoryError(path: url.path)
        }
        let directory = MCPBootstrapDirectory(descriptor: fd, url: canonicalURL, originalURL: url, info: info)
        try directory.validateCurrentPath()
        return directory
    }

    private init(descriptor: Int32, url: URL, originalURL: URL, info: stat) {
        self.descriptor = descriptor
        self.url = url
        self.originalURL = originalURL
        device = info.st_dev
        inode = info.st_ino
    }

    deinit { Darwin.close(descriptor) }

    public func validateCurrentPath() throws {
        var descriptorInfo = stat()
        var pathInfo = stat()
        guard fstat(descriptor, &descriptorInfo) == 0,
              lstat(originalURL.path, &pathInfo) == 0,
              Self.isPrivateDirectory(descriptorInfo), Self.isPrivateDirectory(pathInfo),
              descriptorInfo.st_dev == device, descriptorInfo.st_ino == inode,
              pathInfo.st_dev == device, pathInfo.st_ino == inode,
              Self.ancestorsAreTrusted(url.deletingLastPathComponent()),
              Self.aliasesAreTrusted(originalURL.deletingLastPathComponent())
        else { throw DirectoryError(path: url.path) }
    }

    /// Check before connecting and again before sending any handshake bytes.
    public func validateSocket(at socketURL: URL) throws {
        try validateCurrentPath()
        var info = stat()
        guard socketURL.deletingLastPathComponent().standardizedFileURL.path == originalURL.standardizedFileURL.path else {
            throw DirectoryError(path: socketURL.path)
        }
        guard fstatat(descriptor, socketURL.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw DirectoryError(path: socketURL.path, code: errno)
        }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK),
              info.st_uid == getuid(), info.st_mode & mode_t(0o7777) == mode_t(0o600)
        else { throw DirectoryError(path: socketURL.path) }
    }

    package static func isPrivateDirectory(_ info: stat) -> Bool {
        info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
            && info.st_uid == getuid() && info.st_mode & mode_t(0o7777) == mode_t(0o700)
    }

    /// A pathname alias must itself be controlled by a trusted account and sit
    /// beneath trusted ancestors; resolving an attacker-owned alias is not trust.
    private static func aliasesAreTrusted(_ url: URL) -> Bool {
        var current = url
        while true {
            var info = stat()
            guard lstat(current.path, &info) == 0, info.st_uid == 0 || info.st_uid == getuid() else { return false }
            let type = info.st_mode & mode_t(S_IFMT)
            guard type == mode_t(S_IFDIR) || type == mode_t(S_IFLNK) else { return false }
            if type == mode_t(S_IFDIR), info.st_mode & mode_t(0o022) != 0,
               !(info.st_uid == 0 && info.st_mode & mode_t(S_ISVTX) != 0) { return false }
            if current.path == "/" { return true }
            current.deleteLastPathComponent()
        }
    }

    private static func ancestorsAreTrusted(_ url: URL) -> Bool {
        var current = url
        while true {
            var info = stat()
            guard lstat(current.path, &info) == 0,
                  info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                  info.st_uid == 0 || info.st_uid == getuid()
            else { return false }
            // A root-owned sticky directory (notably /private/tmp) protects our
            // owned child from rename/unlink by other accounts despite write access.
            let writableByOthers = info.st_mode & mode_t(0o022) != 0
            guard !writableByOthers || (info.st_uid == 0 && info.st_mode & mode_t(S_ISVTX) != 0) else { return false }
            if current.path == "/" { return true }
            current.deleteLastPathComponent()
        }
    }
}

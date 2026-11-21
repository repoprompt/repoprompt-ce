import Darwin
import Foundation
import RepoPromptProviderQuota

/// Bounded private files for provider status-line collectors. No credential IO.
enum CLIUsagePrivateFiles {
    static func isPrivateDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_uid == getuid() && info.st_mode & S_IFMT == S_IFDIR && info.st_mode & 0o777 == 0o700
    }

    static func createDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard isPrivateDirectory(url) else { throw ProviderQuotaReadError.invalidResponse }
    }

    static func read(_ url: URL, limit: Int = 4096) -> Data? {
        guard isPrivateDirectory(url.deletingLastPathComponent()) else { return nil }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o777 == 0o600, info.st_size >= 0, info.st_size <= limit else { return nil }
        return try? FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: limit + 1)
    }

    static func write(_ data: Data, to url: URL) throws {
        guard data.count <= 65536, isPrivateDirectory(url.deletingLastPathComponent()) else { throw ProviderQuotaReadError.invalidResponse }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ProviderQuotaReadError.transport }
        defer {
            close(fd)
            unlink(temporary.path)
        }
        try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: data)
        guard rename(temporary.path, url.path) == 0 else { throw ProviderQuotaReadError.transport }
    }

    /// Called before app bootstrap in the collector child, never in the app process.
    static func readStatusLineInput() -> Data? {
        alarm(3)
        defer { alarm(0) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count <= 65536 {
            let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
            if count == 0 { return data }
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        return nil
    }
}

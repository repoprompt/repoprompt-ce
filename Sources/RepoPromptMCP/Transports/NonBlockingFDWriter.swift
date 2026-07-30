//
//  NonBlockingFDWriter.swift
//  repoprompt-mcp
//
//  Bounded no-progress writer for proxy-mode stdout bridging.
//

import Foundation
import RepoPromptShared

#if canImport(Darwin)
    import Darwin

    private let systemWrite = Darwin.write
#elseif canImport(Glibc)
    import Glibc

    private let systemWrite = Glibc.write
#endif

enum NonBlockingFDWriteError: Swift.Error, CustomStringConvertible, Equatable {
    case cancelled(bytesWritten: Int, totalBytes: Int)
    case brokenPipe(bytesWritten: Int, totalBytes: Int)
    case localTimeout(stallTimeout: TimeInterval, bytesWritten: Int, totalBytes: Int)
    case fcntlFailed(errno: Int32)
    case pollFailed(errno: Int32)
    case writeFailed(errno: Int32, bytesWritten: Int, totalBytes: Int)

    var provenance: String {
        switch self {
        case .cancelled:
            "cancelled"
        case .brokenPipe:
            "broken_pipe"
        case .localTimeout:
            "local_timeout"
        case .fcntlFailed:
            "fcntl_failed"
        case .pollFailed:
            "poll_failed"
        case .writeFailed:
            "write_failed"
        }
    }

    var description: String {
        switch self {
        case let .cancelled(bytesWritten, totalBytes):
            "write cancelled after \(bytesWritten)/\(totalBytes) bytes"
        case let .brokenPipe(bytesWritten, totalBytes):
            "stdout broken pipe after \(bytesWritten)/\(totalBytes) bytes"
        case let .localTimeout(stallTimeout, bytesWritten, totalBytes):
            "stdout write made no progress for \(stallTimeout)s after \(bytesWritten)/\(totalBytes) bytes"
        case let .fcntlFailed(errno):
            "failed to set non-blocking output mode: \(errno)"
        case let .pollFailed(errno):
            "stdout poll failed: \(errno)"
        case let .writeFailed(errno, bytesWritten, totalBytes):
            "stdout write failed with errno \(errno) after \(bytesWritten)/\(totalBytes) bytes"
        }
    }
}

enum NonBlockingFDWriter {
    @discardableResult
    static func setNonBlocking(fd: Int32) throws -> Int32 {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0 else {
            throw NonBlockingFDWriteError.fcntlFailed(errno: errno)
        }
        guard flags & O_NONBLOCK == 0 else { return flags }
        guard fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw NonBlockingFDWriteError.fcntlFailed(errno: errno)
        }
        return flags
    }

    static func restoreFlags(fd: Int32, flags: Int32) throws {
        guard fcntl(fd, F_SETFL, flags) >= 0 else {
            throw NonBlockingFDWriteError.fcntlFailed(errno: errno)
        }
    }

    private static func sanitizedPollIntervalMilliseconds(_ value: Int32) -> Int32 {
        max(1, value)
    }

    static func writeAll(
        _ data: Data,
        to fd: Int32,
        stallTimeout: TimeInterval = MCPTimeoutPolicy.transportWriteStallTimeoutSeconds,
        pollIntervalMilliseconds: Int32 = 250,
        setNonBlocking: Bool = true
    ) throws {
        if setNonBlocking {
            try self.setNonBlocking(fd: fd)
        }

        var totalWritten = 0
        var lastProgressAt = Date()

        while totalWritten < data.count {
            if Task.isCancelled {
                throw NonBlockingFDWriteError.cancelled(bytesWritten: totalWritten, totalBytes: data.count)
            }

            if Date().timeIntervalSince(lastProgressAt) >= stallTimeout {
                throw NonBlockingFDWriteError.localTimeout(
                    stallTimeout: stallTimeout,
                    bytesWritten: totalWritten,
                    totalBytes: data.count
                )
            }

            let written = data.withUnsafeBytes { buffer in
                let base = buffer.baseAddress!.advanced(by: totalWritten)
                return systemWrite(fd, base, data.count - totalWritten)
            }

            if written > 0 {
                totalWritten += written
                lastProgressAt = Date()
                continue
            }

            if written == 0 {
                throw NonBlockingFDWriteError.brokenPipe(bytesWritten: totalWritten, totalBytes: data.count)
            }

            let err = errno
            if err == EINTR {
                continue
            }
            if err == EPIPE {
                throw NonBlockingFDWriteError.brokenPipe(bytesWritten: totalWritten, totalBytes: data.count)
            }
            if err == EAGAIN || err == EWOULDBLOCK {
                try waitForWritable(
                    fd: fd,
                    stallTimeout: stallTimeout,
                    pollIntervalMilliseconds: pollIntervalMilliseconds,
                    lastProgressAt: lastProgressAt,
                    bytesWritten: totalWritten,
                    totalBytes: data.count
                )
                continue
            }

            throw NonBlockingFDWriteError.writeFailed(
                errno: err,
                bytesWritten: totalWritten,
                totalBytes: data.count
            )
        }
    }

    private static func waitForWritable(
        fd: Int32,
        stallTimeout: TimeInterval,
        pollIntervalMilliseconds: Int32,
        lastProgressAt: Date,
        bytesWritten: Int,
        totalBytes: Int
    ) throws {
        while true {
            if Task.isCancelled {
                throw NonBlockingFDWriteError.cancelled(bytesWritten: bytesWritten, totalBytes: totalBytes)
            }

            let remainingStallSeconds = stallTimeout - Date().timeIntervalSince(lastProgressAt)
            if remainingStallSeconds <= 0 {
                throw NonBlockingFDWriteError.localTimeout(
                    stallTimeout: stallTimeout,
                    bytesWritten: bytesWritten,
                    totalBytes: totalBytes
                )
            }

            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let remainingMs = max(1, Int32(remainingStallSeconds * 1000))
            let timeoutMs = min(sanitizedPollIntervalMilliseconds(pollIntervalMilliseconds), remainingMs)
            let result = poll(&pfd, 1, timeoutMs)

            if result < 0 {
                if errno == EINTR {
                    continue
                }
                throw NonBlockingFDWriteError.pollFailed(errno: errno)
            }

            if result == 0 {
                continue
            }

            if pfd.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
                throw NonBlockingFDWriteError.brokenPipe(bytesWritten: bytesWritten, totalBytes: totalBytes)
            }

            if pfd.revents & Int16(POLLOUT) != 0 {
                return
            }
        }
    }
}

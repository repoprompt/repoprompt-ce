import Darwin
import Foundation

/// The physical stdout boundary. A blocked write may suspend, but frame ownership stays with the transport.
protocol MCPStdioOutputSink: Sendable {
    func prepare() throws
    func write(_ bytes: UnsafeRawBufferPointer) -> MCPStdioWriteResult
    func awaitWritable() async -> MCPStdioWritableResult
}

enum MCPStdioWriteResult {
    case wrote(Int)
    case interrupted
    case wouldBlock
    case brokenPipe
    case failed(Int32)
}

enum MCPStdioWritableResult {
    case ready
    case failed(Int32)
}

struct MCPStdioFileDescriptorOutputSink: MCPStdioOutputSink {
    let descriptor: Int32
    let pollIntervalMilliseconds: Int32

    func prepare() throws {
        signal(SIGPIPE, SIG_IGN)
        var noSigPipe: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 || errno == ENOTSOCK else {
            throw MCPStdioServerTransport.TerminalError.stdoutWrite(errno: errno, bytesWritten: 0, totalBytes: 0)
        }
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw MCPStdioServerTransport.TerminalError.stdoutWrite(errno: errno, bytesWritten: 0, totalBytes: 0)
        }
    }

    func write(_ bytes: UnsafeRawBufferPointer) -> MCPStdioWriteResult {
        let count = Darwin.write(descriptor, bytes.baseAddress, bytes.count)
        if count > 0 {
            return .wrote(count)
        }
        if count == 0 {
            return .brokenPipe
        }
        switch errno {
        case EINTR: return .interrupted
        case EAGAIN, EWOULDBLOCK: return .wouldBlock
        case EPIPE: return .brokenPipe
        default: return .failed(errno)
        }
    }

    func awaitWritable() async -> MCPStdioWritableResult {
        var descriptor = pollfd(fd: descriptor, events: Int16(POLLOUT | POLLHUP | POLLERR), revents: 0)
        let result = poll(&descriptor, 1, max(1, min(pollIntervalMilliseconds, 50)))
        if result < 0, errno != EINTR {
            return .failed(errno)
        }
        await Task.yield()
        return .ready
    }
}

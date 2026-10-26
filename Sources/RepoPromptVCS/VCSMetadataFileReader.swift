#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif
import Foundation

/// Reads small repository metadata after its caller has checked path authority.
/// Nonblocking open and descriptor validation reject FIFOs and devices before any
/// read can wait on them. Authorized symlinks to regular metadata remain supported.
package enum VCSMetadataFileReader {
    private static let byteLimit = 4096

    package static func contents(of url: URL) throws -> Data {
        let path = url.path
        guard url.isFileURL, !path.utf8.contains(0) else { throw POSIXError(.EINVAL) }
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw ReadError.notRegularFile }

        var bytes = [UInt8](repeating: 0, count: byteLimit + 1)
        var count = 0
        while count < bytes.count {
            let readCount = try bytes.withUnsafeMutableBytes { buffer in
                guard let address = buffer.baseAddress else { throw POSIXError(.EFAULT) }
                return read(descriptor, address.advanced(by: count), buffer.count - count)
            }
            if readCount == 0 { break }
            if readCount < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            count += readCount
        }
        guard count <= byteLimit else { throw ReadError.tooLarge }
        return Data(bytes.prefix(count))
    }

    private enum ReadError: LocalizedError {
        case notRegularFile
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .notRegularFile: "Repository metadata must be a regular file."
            case .tooLarge: "Repository metadata exceeds the 4096-byte limit."
            }
        }
    }
}

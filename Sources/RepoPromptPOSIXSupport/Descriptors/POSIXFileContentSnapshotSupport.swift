import Darwin
import Foundation

package struct POSIXFileContentMetadata: Equatable {
    package let deviceID: UInt64
    package let fileNumber: UInt64
    package let byteSize: Int64
    package let modificationSeconds: Int64
    package let modificationNanoseconds: Int64
    package let statusChangeSeconds: Int64
    package let statusChangeNanoseconds: Int64

    package init(
        deviceID: UInt64,
        fileNumber: UInt64,
        byteSize: Int64,
        modificationSeconds: Int64,
        modificationNanoseconds: Int64,
        statusChangeSeconds: Int64,
        statusChangeNanoseconds: Int64
    ) {
        self.deviceID = deviceID
        self.fileNumber = fileNumber
        self.byteSize = byteSize
        self.modificationSeconds = modificationSeconds
        self.modificationNanoseconds = modificationNanoseconds
        self.statusChangeSeconds = statusChangeSeconds
        self.statusChangeNanoseconds = statusChangeNanoseconds
    }
}

package enum POSIXFileContentSnapshotError: Error, Equatable {
    case operationFailed(errno: Int32)
    case notRegularFile
}

package enum POSIXFileContentSnapshotSupport {
    package static func metadata(atPath path: String) throws -> POSIXFileContentMetadata {
        var info = stat()
        let result = path.withCString { pointer in
            lstat(pointer, &info)
        }
        guard result == 0 else {
            throw POSIXFileContentSnapshotError.operationFailed(errno: errno)
        }
        return try metadata(from: info)
    }

    package static func metadata(fileDescriptor: Int32) throws -> POSIXFileContentMetadata {
        var info = stat()
        guard fstat(fileDescriptor, &info) == 0 else {
            throw POSIXFileContentSnapshotError.operationFailed(errno: errno)
        }
        return try metadata(from: info)
    }

    package static func openReadOnlyFileDescriptor(atPath path: String) throws -> Int32 {
        let descriptor = path.withCString { pointer in
            open(pointer, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw POSIXFileContentSnapshotError.operationFailed(errno: errno)
        }
        return descriptor
    }

    private static func metadata(from info: stat) throws -> POSIXFileContentMetadata {
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw POSIXFileContentSnapshotError.notRegularFile
        }

        return POSIXFileContentMetadata(
            deviceID: UInt64(info.st_dev),
            fileNumber: UInt64(info.st_ino),
            byteSize: Int64(info.st_size),
            modificationSeconds: Int64(info.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            statusChangeSeconds: Int64(info.st_ctimespec.tv_sec),
            statusChangeNanoseconds: Int64(info.st_ctimespec.tv_nsec)
        )
    }
}

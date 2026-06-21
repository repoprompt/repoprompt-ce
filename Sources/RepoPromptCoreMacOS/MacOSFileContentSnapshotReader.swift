import Darwin
import Foundation
import RepoPromptCore

package enum MacOSFileContentSnapshotError: Error, Equatable {
    case notRegularFile
    case operationFailed(errno: Int32)
}

package struct MacOSFileContentSnapshotReader: FileContentSnapshotReading {
    package init() {}

    package func fingerprint(atPath path: String) throws -> FileContentFingerprint {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw MacOSFileContentSnapshotError.operationFailed(errno: errno)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw MacOSFileContentSnapshotError.notRegularFile
        }
        return fingerprint(from: info)
    }

    package func fingerprint(fileDescriptor: Int32) throws -> FileContentFingerprint {
        var info = stat()
        guard fstat(fileDescriptor, &info) == 0 else {
            throw MacOSFileContentSnapshotError.operationFailed(errno: errno)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw MacOSFileContentSnapshotError.notRegularFile
        }
        return fingerprint(from: info)
    }

    package func openReadOnlyFileHandle(atPath path: String) throws -> FileHandle {
        let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw MacOSFileContentSnapshotError.operationFailed(errno: errno)
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private func fingerprint(from info: stat) -> FileContentFingerprint {
        FileContentFingerprint(
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

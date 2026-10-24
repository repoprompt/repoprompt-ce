import Foundation
import RepoPromptFoundation
#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
    import Darwin
#else
    import Glibc
#endif

package struct FileContentFingerprint: Hashable {
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

    package var modificationDate: Date {
        Date(
            timeIntervalSince1970: TimeInterval(modificationSeconds)
                + TimeInterval(modificationNanoseconds) / 1_000_000_000
        )
    }
}

package struct ValidatedRawFileContentSnapshot {
    package let data: Data
    package let modificationDate: Date
    package let fingerprint: FileContentFingerprint
    package init(data: Data, modificationDate: Date, fingerprint: FileContentFingerprint) {
        self.data = data
        self.modificationDate = modificationDate
        self.fingerprint = fingerprint
    }
}

package struct ValidatedFileContentSnapshot {
    package let content: String?
    package let detectedEncodingRawValue: UInt?
    package let modificationDate: Date
    package let fingerprint: FileContentFingerprint

    package var estimatedDecodedCost: Int {
        guard let content else { return 0 }
        return content.utf8.count + content.utf16.count * MemoryLayout<UInt16>.stride
    }
}

package enum FileContentValidationError: Error {
    case fingerprintChanged
}

package enum FileContentFingerprintReader {
    package static func fingerprint(atPath path: String) throws -> FileContentFingerprint {
        var info = stat()
        let result = path.withCString { pointer in
            lstat(pointer, &info)
        }
        guard result == 0 else {
            throw fileSystemError(for: errno)
        }
        return try fingerprint(from: info)
    }

    package static func fingerprint(fileDescriptor: Int32) throws -> FileContentFingerprint {
        var info = stat()
        guard fstat(fileDescriptor, &info) == 0 else {
            throw fileSystemError(for: errno)
        }
        return try fingerprint(from: info)
    }

    package static func openReadOnlyFileHandle(atPath path: String) throws -> FileHandle {
        let descriptor = path.withCString { pointer in
            open(pointer, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw fileSystemError(for: errno)
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private static func fingerprint(from info: stat) throws -> FileContentFingerprint {
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw FileSystemError.invalidRelativePath
        }

        #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
            let modificationTime = info.st_mtimespec
            let statusChangeTime = info.st_ctimespec
        #else
            let modificationTime = info.st_mtim
            let statusChangeTime = info.st_ctim
        #endif

        return FileContentFingerprint(
            deviceID: safeDeviceID(info.st_dev),
            fileNumber: UInt64(info.st_ino),
            byteSize: Int64(info.st_size),
            modificationSeconds: Int64(modificationTime.tv_sec),
            modificationNanoseconds: Int64(modificationTime.tv_nsec),
            statusChangeSeconds: Int64(statusChangeTime.tv_sec),
            statusChangeNanoseconds: Int64(statusChangeTime.tv_nsec)
        )
    }

    private static func fileSystemError(for errorNumber: Int32) -> FileSystemError {
        switch errorNumber {
        case ENOENT, ENOTDIR:
            .fileNotFound
        case ELOOP:
            .invalidRelativePath
        default:
            .failedToReadFile
        }
    }
}

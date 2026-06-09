import Darwin
import Foundation
import RepoPromptCore
import RepoPromptPOSIXSupport

package struct MacOSFileContentSnapshotReader: FileContentSnapshotReading {
    package init() {}

    package func fingerprint(atPath path: String) throws -> FileContentFingerprint {
        do {
            return try fingerprint(from: POSIXFileContentSnapshotSupport.metadata(atPath: path))
        } catch {
            throw map(error)
        }
    }

    package func fingerprint(fileDescriptor: Int32) throws -> FileContentFingerprint {
        do {
            return try fingerprint(from: POSIXFileContentSnapshotSupport.metadata(fileDescriptor: fileDescriptor))
        } catch {
            throw map(error)
        }
    }

    package func openReadOnlyFileHandle(atPath path: String) throws -> FileHandle {
        do {
            let descriptor = try POSIXFileContentSnapshotSupport.openReadOnlyFileDescriptor(atPath: path)
            return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        } catch {
            throw map(error)
        }
    }

    private func fingerprint(from metadata: POSIXFileContentMetadata) -> FileContentFingerprint {
        FileContentFingerprint(
            deviceID: metadata.deviceID,
            fileNumber: metadata.fileNumber,
            byteSize: metadata.byteSize,
            modificationSeconds: metadata.modificationSeconds,
            modificationNanoseconds: metadata.modificationNanoseconds,
            statusChangeSeconds: metadata.statusChangeSeconds,
            statusChangeNanoseconds: metadata.statusChangeNanoseconds
        )
    }

    private func map(_ error: Error) -> FileSystemError {
        guard let error = error as? POSIXFileContentSnapshotError else {
            return .failedToReadFile
        }
        switch error {
        case .notRegularFile:
            return .invalidRelativePath
        case let .operationFailed(errorNumber):
            switch errorNumber {
            case ENOENT, ENOTDIR:
                return .fileNotFound
            case ELOOP:
                return .invalidRelativePath
            default:
                return .failedToReadFile
            }
        }
    }
}

import Foundation
import RepoPromptCore
import RepoPromptCoreMacOS

struct ValidatedFileContentSnapshot {
    let content: String?
    let detectedEncodingRawValue: UInt?
    let modificationDate: Date
    let fingerprint: FileContentFingerprint

    var estimatedDecodedCost: Int {
        guard let content else { return 0 }
        return content.utf8.count + content.utf16.count * MemoryLayout<UInt16>.stride
    }
}

enum FileContentValidationError: Error {
    case fingerprintChanged
}

enum FileContentFingerprintReader {
    private static let reader = MacOSFileContentSnapshotReader()

    static func fingerprint(atPath path: String) throws -> FileContentFingerprint {
        try map { try reader.fingerprint(atPath: path) }
    }

    static func fingerprint(fileDescriptor: Int32) throws -> FileContentFingerprint {
        try map { try reader.fingerprint(fileDescriptor: fileDescriptor) }
    }

    static func openReadOnlyFileHandle(atPath path: String) throws -> FileHandle {
        try map { try reader.openReadOnlyFileHandle(atPath: path) }
    }

    private static func map<T>(_ operation: () throws -> T) throws -> T {
        do {
            return try operation()
        } catch MacOSFileContentSnapshotError.notRegularFile {
            throw FileSystemError.invalidRelativePath
        } catch let MacOSFileContentSnapshotError.operationFailed(errorNumber) {
            switch POSIXErrorCode(rawValue: errorNumber) {
            case .ENOENT?, .ENOTDIR?:
                throw FileSystemError.fileNotFound
            case .ELOOP?:
                throw FileSystemError.invalidRelativePath
            default:
                throw FileSystemError.failedToReadFile
            }
        } catch {
            throw FileSystemError.failedToReadFile
        }
    }
}

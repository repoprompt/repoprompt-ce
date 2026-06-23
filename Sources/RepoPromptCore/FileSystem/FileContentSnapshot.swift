import Foundation

package struct ValidatedFileContentSnapshot {
    package let content: String?
    let detectedEncodingRawValue: UInt?
    package let modificationDate: Date
    let fingerprint: FileContentFingerprint

    var estimatedDecodedCost: Int {
        guard let content else { return 0 }
        return content.utf8.count + content.utf16.count * MemoryLayout<UInt16>.stride
    }

    package init(
        content: String?,
        detectedEncodingRawValue: UInt?,
        modificationDate: Date,
        fingerprint: FileContentFingerprint
    ) {
        self.content = content
        self.detectedEncodingRawValue = detectedEncodingRawValue
        self.modificationDate = modificationDate
        self.fingerprint = fingerprint
    }
}

package enum FileContentValidationError: Error {
    case fingerprintChanged
}

package enum FileContentFingerprintReader {
    static func fingerprint(
        atPath path: String,
        reader: any FileContentSnapshotReading
    ) throws -> FileContentFingerprint {
        try map { try reader.fingerprint(atPath: path) }
    }

    static func fingerprint(
        fileDescriptor: Int32,
        reader: any FileContentSnapshotReading
    ) throws -> FileContentFingerprint {
        try map { try reader.fingerprint(fileDescriptor: fileDescriptor) }
    }

    static func openReadOnlyFileHandle(
        atPath path: String,
        reader: any FileContentSnapshotReading
    ) throws -> FileHandle {
        try map { try reader.openReadOnlyFileHandle(atPath: path) }
    }

    private static func map<T>(_ operation: () throws -> T) throws -> T {
        do {
            return try operation()
        } catch FileContentSnapshotAccessError.notRegularFile {
            throw FileSystemError.invalidRelativePath
        } catch let FileContentSnapshotAccessError.operationFailed(errorNumber) {
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

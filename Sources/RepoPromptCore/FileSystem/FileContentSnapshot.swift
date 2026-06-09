import Foundation

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

    var modificationDate: Date {
        Date(
            timeIntervalSince1970: TimeInterval(modificationSeconds)
                + TimeInterval(modificationNanoseconds) / 1_000_000_000
        )
    }
}

package protocol FileContentSnapshotReading: Sendable {
    func fingerprint(atPath path: String) throws -> FileContentFingerprint
    func fingerprint(fileDescriptor: Int32) throws -> FileContentFingerprint
    func openReadOnlyFileHandle(atPath path: String) throws -> FileHandle
}

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

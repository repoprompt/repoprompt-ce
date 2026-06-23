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

    package var modificationDate: Date {
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

package enum FileContentSnapshotAccessError: Error, Equatable {
    case notRegularFile
    case operationFailed(errorNumber: Int32)
}

package struct DecodedFileContent: Equatable {
    package let string: String
    package let encodingRawValue: UInt

    package init(string: String, encodingRawValue: UInt) {
        self.string = string
        self.encodingRawValue = encodingRawValue
    }
}

package protocol FileContentEncodingDetectionSession: AnyObject {
    func analyzeNextChunk(_ data: Data) -> Bool
    func finishEncodingRawValue() -> UInt?
}

package protocol FileContentDecoding: Sendable {
    func decode(_ data: Data) -> DecodedFileContent?
    func detectEncodingRawValue(in data: Data) -> UInt?
    func isProbablyBinary(_ data: Data) -> Bool
    func makeEncodingDetectionSession() -> any FileContentEncodingDetectionSession
}

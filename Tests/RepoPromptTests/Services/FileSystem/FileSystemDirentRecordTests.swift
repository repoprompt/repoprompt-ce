import Darwin
@testable import RepoPromptApp
import XCTest

final class FileSystemDirentRecordTests: XCTestCase {
    func testVariableLengthRecordDecodesWithoutFullDirentStorage() throws {
        let layout = FileSystemService.direntRecordLayoutForTesting
        let nameBytes = Array("boundary-entry.txt".utf8)
        let record = makeRecord(
            nameBytes: nameBytes,
            declaredNameLength: UInt16(nameBytes.count),
            includesTerminator: true
        )

        XCTAssertLessThan(record.count, layout.fullStructSize)
        let decoded = try XCTUnwrap(FileSystemService.decodeDirentRecordForTesting(record))
        XCTAssertEqual(decoded.name, "boundary-entry.txt")
        XCTAssertEqual(decoded.bytes, Data(nameBytes))
        XCTAssertEqual(decoded.dType, UInt8(DT_REG))
    }

    func testGuardPageRecordDecodesWithoutFullDirentRead() throws {
        let layout = FileSystemService.direntRecordLayoutForTesting
        let nameBytes = Array("boundary-entry.txt".utf8)
        let record = makeRecord(
            nameBytes: nameBytes,
            declaredNameLength: UInt16(nameBytes.count),
            includesTerminator: true
        )
        let pageSize = Int(getpagesize())
        let mappingSize = pageSize * 2

        XCTAssertLessThan(record.count, layout.fullStructSize)
        guard pageSize > layout.fullStructSize else {
            XCTFail("A guard page requires the platform page to exceed the imported dirent size")
            return
        }

        let mapping = mmap(nil, mappingSize, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0)
        guard let mapping, mapping != MAP_FAILED else {
            XCTFail("mmap failed with errno \(errno)")
            return
        }
        defer {
            XCTAssertEqual(munmap(mapping, mappingSize), 0)
        }

        let recordAddress = mapping.advanced(by: pageSize - record.count)
        XCTAssertEqual(Int(bitPattern: recordAddress) % MemoryLayout<dirent>.alignment, 0)
        record.withUnsafeBytes { bytes in
            recordAddress.copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        }
        guard mprotect(mapping.advanced(by: pageSize), pageSize, PROT_NONE) == 0 else {
            XCTFail("mprotect failed with errno \(errno)")
            return
        }

        let entryPtr = UnsafeRawPointer(recordAddress).assumingMemoryBound(to: dirent.self)
        let decoded = try XCTUnwrap(FileSystemService.decodeDirentPointerForTesting(entryPtr))
        XCTAssertEqual(decoded.name, "boundary-entry.txt")
        XCTAssertEqual(decoded.bytes, Data(nameBytes))
        XCTAssertEqual(decoded.dType, UInt8(DT_REG))
    }

    func testDecoderRejectsRecordAndNameLengthsOutsideAvailableBytes() {
        let layout = FileSystemService.direntRecordLayoutForTesting
        let nameBytes = Array("short".utf8)

        var mismatchedRecordLength = makeRecord(
            nameBytes: nameBytes,
            declaredNameLength: UInt16(nameBytes.count),
            includesTerminator: true
        )
        writeNativeUInt16(UInt16(mismatchedRecordLength.count + 1), at: layout.recordLengthOffset, to: &mismatchedRecordLength)

        var oversizedNameLength = makeRecord(
            nameBytes: nameBytes,
            declaredNameLength: UInt16(nameBytes.count),
            includesTerminator: false
        )
        writeNativeUInt16(
            UInt16(oversizedNameLength.count - layout.nameOffset + 1),
            at: layout.nameLengthOffset,
            to: &oversizedNameLength
        )

        var truncatedRecord = [UInt8](repeating: 0, count: layout.minimumRecordLength - 1)
        writeNativeUInt16(UInt16(truncatedRecord.count), at: layout.recordLengthOffset, to: &truncatedRecord)

        var oversizedRecord = [UInt8](repeating: 0, count: layout.fullStructSize + 1)
        writeNativeUInt16(UInt16(oversizedRecord.count), at: layout.recordLengthOffset, to: &oversizedRecord)

        XCTAssertNil(FileSystemService.decodeDirentRecordForTesting(mismatchedRecordLength))
        XCTAssertNil(FileSystemService.decodeDirentRecordForTesting(oversizedNameLength))
        XCTAssertNil(FileSystemService.decodeDirentRecordForTesting(truncatedRecord))
        XCTAssertNil(FileSystemService.decodeDirentRecordForTesting(oversizedRecord))
    }

    func testZeroNameLengthFallbackRequiresTerminatorWithinRecord() throws {
        let nameBytes = Array("fallback".utf8)
        let terminatedRecord = makeRecord(
            nameBytes: nameBytes,
            declaredNameLength: 0,
            includesTerminator: true
        )
        let unterminatedRecord = makeRecord(
            nameBytes: nameBytes,
            declaredNameLength: 0,
            includesTerminator: false
        )

        let decoded = try XCTUnwrap(FileSystemService.decodeDirentRecordForTesting(terminatedRecord))
        XCTAssertEqual(decoded.name, "fallback")
        XCTAssertEqual(decoded.bytes, Data(nameBytes))
        XCTAssertNil(FileSystemService.decodeDirentRecordForTesting(unterminatedRecord))
    }

    private func makeRecord(
        nameBytes: [UInt8],
        declaredNameLength: UInt16,
        includesTerminator: Bool
    ) -> [UInt8] {
        let layout = FileSystemService.direntRecordLayoutForTesting
        let unpaddedRecordLength = layout.nameOffset + nameBytes.count + (includesTerminator ? 1 : 0)
        let recordLength = (unpaddedRecordLength + 3) & ~3
        precondition(recordLength <= layout.fullStructSize)
        precondition(nameBytes.count <= layout.nameCapacity)

        var record = [UInt8](repeating: 0xA5, count: recordLength)
        writeNativeUInt16(UInt16(recordLength), at: layout.recordLengthOffset, to: &record)
        writeNativeUInt16(declaredNameLength, at: layout.nameLengthOffset, to: &record)
        record[layout.typeOffset] = UInt8(DT_REG)
        record.replaceSubrange(
            layout.nameOffset ..< layout.nameOffset + nameBytes.count,
            with: nameBytes
        )
        if includesTerminator {
            record[layout.nameOffset + nameBytes.count] = 0
        }
        return record
    }

    private func writeNativeUInt16(_ value: UInt16, at offset: Int, to bytes: inout [UInt8]) {
        var value = value
        withUnsafeBytes(of: &value) { valueBytes in
            bytes.replaceSubrange(offset ..< offset + valueBytes.count, with: valueBytes)
        }
    }
}

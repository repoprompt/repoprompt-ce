import Foundation
@testable import RepoPromptVCS
import XCTest

final class GitDiffMachineRecordsTests: XCTestCase {
    func testOrdinaryNamesStayByteExactAcrossBothRecordFormats() throws {
        let names = [" file ", "line\nbreak", "tab\tname", "literal => arrow", "dir/{old => new}/file", "percent%23#?", "caf\u{e9}", "cafe\u{301}"]
        var numstat = Data()
        var statuses = Data()
        for name in names {
            numstat.append(Data("1\t2\t\(name)\0".utf8))
            statuses.append(Data("M\0\(name)\0".utf8))
        }
        let counts = try GitDiffMachineRecords.numstat(numstat)
        let status = try GitDiffMachineRecords.nameStatus(statuses)
        XCTAssertEqual(counts.map(\.path.bytes), names.map { Data($0.utf8) })
        XCTAssertEqual(status.map(\.path.bytes), names.map { Data($0.utf8) })
        XCTAssertEqual(Set(counts.map(\.path)).union(status.map(\.path)).count, names.count)
        XCTAssertTrue(counts.allSatisfy { $0.additions == 1 && $0.deletions == 2 && $0.originalPath == nil })
        XCTAssertTrue(status.allSatisfy { $0.status == "M" && $0.originalPath == nil })
    }

    func testRenamesCopiesAndBinaryCountsUseExplicitFields() throws {
        let old = "old\t => {name}\n"
        let new = " new\t => {name}\n "
        let counts = try XCTUnwrap(GitDiffMachineRecords.numstat(Data("-\t-\t\0\(old)\0\(new)\0".utf8)).first)
        XCTAssertNil(counts.additions)
        XCTAssertNil(counts.deletions)
        XCTAssertEqual(counts.originalPath?.bytes, Data(old.utf8))
        XCTAssertEqual(counts.path.bytes, Data(new.utf8))
        for code in ["R100", "C075"] {
            let status = try XCTUnwrap(GitDiffMachineRecords.nameStatus(Data("\(code)\0\(old)\0\(new)\0".utf8)).first)
            XCTAssertEqual(status.status, code)
            XCTAssertEqual(status.originalPath?.bytes, Data(old.utf8))
            XCTAssertEqual(status.path.bytes, Data(new.utf8))
        }
    }

    func testInvalidUTF8IsRetainedUntilExportAndCannotBecomeEmptySuccess() throws {
        let raw = Data([0xFF, 0xFE])
        var numstat = Data("1\t0\t".utf8)
        numstat.append(raw)
        numstat.append(0)
        let record = try XCTUnwrap(GitDiffMachineRecords.numstat(numstat).first)
        XCTAssertEqual(record.path.bytes, raw)
        XCTAssertThrowsError(try record.path.utf8String()) { error in
            XCTAssertEqual(error as? GitDiffRecordError, .invalidUTF8)
        }
    }

    func testMalformedTruncatedOrOversizedFramesFailInsteadOfReturningPartialSuccess() throws {
        for raw in ["1\t0\tname", "1\t0\t\0old\0", "x\t0\tname\0", "1\t0\t\0\0new\0", "1\t0\tgood\0broken\0"] {
            XCTAssertThrowsError(try GitDiffMachineRecords.numstat(Data(raw.utf8)), raw)
        }
        for raw in ["M\0name", "R100\0old\0", "Z\0name\0", "\0name\0", "M\0\0", "R\0old\0new\0", "R101\0old\0new\0", "A1\0name\0", "M101\0name\0"] {
            XCTAssertThrowsError(try GitDiffMachineRecords.nameStatus(Data(raw.utf8)), raw)
        }
        var cursor = GitDiffNULCursor(Data("1234\0".utf8), maximumFieldBytes: 3)
        XCTAssertThrowsError(try cursor.next()) { error in
            XCTAssertEqual(error as? GitDiffRecordError, .fieldLimitExceeded)
        }
        XCTAssertEqual(try GitDiffMachineRecords.numstat(Data()), [])
        XCTAssertEqual(try GitDiffMachineRecords.nameStatus(Data()), [])
    }
}

import Foundation
@testable import RepoPromptApp
import XCTest

final class HiddenSessionSlicePathIndexTests: XCTestCase {
    func testIndexedMatchesPreserveLegacyPathPredicate() {
        let paths = [
            "file.swift", "Sources/file.swift", "file.swift", "Other/file.swift",
            "a//b", "/leading", "", "é.swift", "日本語/名前.swift",
            "nested/trailing/", ".hidden", "./file.swift", "\u{301}name.swift"
        ]
        let files = Dictionary(uniqueKeysWithValues: paths.enumerated().map { (fileID($0.offset), $0.element) })
        let index = HiddenSessionSlicePathIndex(relativePathsByFileID: files)
        let slices = [
            "file.swift", "Sources/file.swift", "/workspace/Sources/file.swift",
            "root@token//Sources/file.swift", "prefixfile.swift", "Sources/file.swift.backup",
            "other/File.swift", "a//b", "root/a//b", "root/a/b",
            "/leading", "root//leading", "root/leading", "", "root/",
            "e\u{301}.swift", "root/日本語/名前.swift", "root/nested/trailing/",
            "root/.hidden", "root/./file.swift", "root/\u{301}name.swift", "missing.swift"
        ]

        for slice in slices {
            let expected = Set(files.compactMap { fileID, relativePath in
                slice == relativePath || slice.hasSuffix("/" + relativePath) ? fileID : nil
            })
            XCTAssertEqual(index.matchingFileIDs(for: [slice]), expected, "Slice: \(slice)")
        }
        XCTAssertTrue(index.matchingFileIDs(for: []).isEmpty)
    }

    func testLargeIndexPreservesDuplicateRelativePathsAcrossRoots() {
        let count = 2048
        var files: [UUID: String] = [:]
        for value in 0 ..< count {
            let path = "Sources/Feature\(value)/File.swift"
            files[fileID(value * 2)] = path
            files[fileID(value * 2 + 1)] = path
        }
        let index = HiddenSessionSlicePathIndex(relativePathsByFileID: files)
        let slices = (0 ..< count).map { "root@token//Sources/Feature\($0)/File.swift" }

        XCTAssertEqual(index.matchingFileIDs(for: slices), Set(files.keys))
        XCTAssertEqual(index.matchingFileIDs(for: [slices[0], slices[0]]), [fileID(0), fileID(1)])
        XCTAssertTrue(index.matchingFileIDs(for: ["root@token//Sources/Feature0/Other.swift"]).isEmpty)
    }

    private func fileID(_ value: Int) -> UUID {
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, UInt8(value >> 8), UInt8(value & 255)))
    }
}

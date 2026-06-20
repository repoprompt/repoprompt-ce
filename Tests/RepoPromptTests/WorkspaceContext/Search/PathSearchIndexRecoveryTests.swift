@testable import RepoPrompt
import XCTest

final class PathSearchIndexRecoveryTests: XCTestCase {
    func testSearchMatchesFilenameSubpathTokensAndPublishesDeterministicRankMetadata() async {
        let paths = [
            "/Volumes/Repo/Sources/Zeta/Widget.swift",
            "Sources/βeta/Search/Unicode.swift",
            "Sources/App/Search/Alpha.swift",
            "Sources/App/Search/Alpha.swift",
            "Sources/App/Features/SearchPanel.swift",
            "docs/absolute-search-notes.md",
            "Worktree/Sources/CompositeCatalogTarget.rpfixture\n/Volumes/Worktree/Sources/CompositeCatalogTarget.rpfixture"
        ]
        let expectedFilenames = [
            "Widget.swift",
            "Unicode.swift",
            "Alpha.swift",
            "Alpha.swift",
            "SearchPanel.swift",
            "absolute-search-notes.md",
            "CompositeCatalogTarget.rpfixture"
        ]
        let index = PathSearchIndex(paths: paths)

        let duplicateHits = await index.search("Alpha.swift", limit: 10)
        XCTAssertEqual(duplicateHits.map(\.index), [2, 3])
        assertMappings(duplicateHits, in: index, paths: paths, expectedFilenames: expectedFilenames)

        let truncatedDuplicateHits = await index.search("Alpha.swift", limit: 1)
        XCTAssertEqual(truncatedDuplicateHits.map(\.index), [2])
        assertMappings(truncatedDuplicateHits, in: index, paths: paths, expectedFilenames: expectedFilenames)

        let truncatedWildcardHits = await index.search("*.swift", limit: 3)
        XCTAssertEqual(truncatedWildcardHits.map(\.index), [0, 4, 2])
        assertMappings(truncatedWildcardHits, in: index, paths: paths, expectedFilenames: expectedFilenames)

        let wildcardHits = await index.search("*.swift", limit: 20)
        XCTAssertEqual(wildcardHits.map(\.index), [0, 4, 2, 3, 1])
        XCTAssertEqual(wildcardHits.map(\.filename), [
            "Widget.swift",
            "SearchPanel.swift",
            "Alpha.swift",
            "Alpha.swift",
            "Unicode.swift"
        ])
        assertMappings(wildcardHits, in: index, paths: paths, expectedFilenames: expectedFilenames)

        let spaceANDHits = await index.search("App Search", limit: 20)
        XCTAssertEqual(spaceANDHits.map(\.index), [4, 2, 3])
        assertMappings(spaceANDHits, in: index, paths: paths, expectedFilenames: expectedFilenames)

        let unicodeHits = await index.search("βeta", limit: 20)
        XCTAssertEqual(unicodeHits.map(\.index), [1])
        assertMappings(unicodeHits, in: index, paths: paths, expectedFilenames: expectedFilenames)

        let absolutePathHits = await index.search("Volumes Widget", limit: 20)
        XCTAssertEqual(absolutePathHits.map(\.index), [0])
        assertMappings(absolutePathHits, in: index, paths: paths, expectedFilenames: expectedFilenames)

        let compositeHits = await index.search("CompositeCatalogTarget", limit: 20)
        XCTAssertEqual(compositeHits.map(\.index), [6])
        assertMappings(compositeHits, in: index, paths: paths, expectedFilenames: expectedFilenames)

        let zeroLimitHits = await index.search("swift", limit: 0)
        XCTAssertEqual(zeroLimitHits, [])
        XCTAssertEqual(wildcardHits.count, 5)

        for invalidIndex in [-1, index.count, index.count + 10] {
            XCTAssertNil(index.path(at: invalidIndex))
            XCTAssertNil(index.filename(at: invalidIndex))
        }

        let emptyIndex = PathSearchIndex(paths: [])
        XCTAssertEqual(emptyIndex.count, 0)
        XCTAssertNil(emptyIndex.path(at: -1))
        XCTAssertNil(emptyIndex.path(at: 0))
        XCTAssertNil(emptyIndex.filename(at: -1))
        XCTAssertNil(emptyIndex.filename(at: 0))
        let emptyHits = await emptyIndex.search("swift", limit: 20)
        XCTAssertEqual(emptyHits, [])

        for iteration in 0 ..< 64 {
            let replacementPaths = [
                "Loop/Shared.swift",
                "Loop/Shared.swift",
                "/tmp/repoprompt-\(iteration)/Absolute.swift",
                "Loop/βeta/Unicode.swift"
            ]
            let replacementFilenames = [
                "Shared.swift",
                "Shared.swift",
                "Absolute.swift",
                "Unicode.swift"
            ]
            let replacement = PathSearchIndex(paths: replacementPaths)
            let replacementHits = replacement.searchSynchronously("*.swift", limit: 20)
            XCTAssertEqual(replacementHits.count, replacementPaths.count)
            assertMappings(
                replacementHits,
                in: replacement,
                paths: replacementPaths,
                expectedFilenames: replacementFilenames
            )
        }

        // The old immutable generation remains valid after replacements are constructed and released.
        let retainedHits = await index.search("Alpha.swift", limit: 10)
        XCTAssertEqual(retainedHits, duplicateHits)
        assertMappings(retainedHits, in: index, paths: paths, expectedFilenames: expectedFilenames)
    }

    private func assertMappings(
        _ candidates: [PathSearchIndex.Candidate],
        in index: PathSearchIndex,
        paths: [String],
        expectedFilenames: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(expectedFilenames.count, paths.count, file: file, line: line)
        for candidate in candidates {
            XCTAssertTrue(paths.indices.contains(candidate.index), file: file, line: line)
            guard paths.indices.contains(candidate.index) else { continue }
            XCTAssertEqual(candidate.path, paths[candidate.index], file: file, line: line)
            XCTAssertEqual(candidate.filename, expectedFilenames[candidate.index], file: file, line: line)
            XCTAssertEqual(candidate.tieBreakKey, candidate.path, file: file, line: line)
            XCTAssertEqual(index.path(at: candidate.index), candidate.path, file: file, line: line)
            XCTAssertEqual(index.filename(at: candidate.index), expectedFilenames[candidate.index], file: file, line: line)
            XCTAssertEqual(index.filename(at: candidate.index), candidate.filename, file: file, line: line)
            XCTAssertEqual(candidate.score, 1, file: file, line: line)
        }
    }
}

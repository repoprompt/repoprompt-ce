@testable import RepoPrompt
import XCTest

final class PathSearchIndexRecoveryTests: XCTestCase {
    func testSearchMatchesFilenameSubpathTokensAndPublishesDeterministicRankMetadata() async {
        let index = PathSearchIndex(paths: [
            "Sources/App/Search/SearchViewModel.swift",
            "Sources/App/Settings/SearchPreferencesView.swift",
            "Sources/App/Models/UserProfile.swift",
            "Tests/SearchViewModelTests.swift",
            "docs/search-index-notes.md"
        ])

        let filenameHits = await index.search("SearchViewModel", limit: 10)
        XCTAssertEqual(filenameHits.map(\.score), [1, 1])
        XCTAssertEqual(filenameHits.map(\.tieBreakKey), filenameHits.map(\.tieBreakKey).sorted())
        XCTAssertEqual(Set(filenameHits.map(\.path)), [
            "Sources/App/Search/SearchViewModel.swift",
            "Tests/SearchViewModelTests.swift"
        ])

        let subpathHits = await index.search("App SearchViewModel", limit: 10)
        XCTAssertEqual(subpathHits.map(\.path), ["Sources/App/Search/SearchViewModel.swift"])

        guard let firstFilenameHit = filenameHits.first(where: { $0.path == "Sources/App/Search/SearchViewModel.swift" }) else {
            return XCTFail("Expected indexed search result for SearchViewModel.swift")
        }
        XCTAssertEqual(firstFilenameHit.filename, "SearchViewModel.swift")
        XCTAssertEqual(index.path(at: firstFilenameHit.index), firstFilenameHit.path)
        XCTAssertEqual(index.filename(at: firstFilenameHit.index), firstFilenameHit.filename)

        let replacement = PathSearchIndex(paths: [
            "Sources/App/Search/SearchController.swift",
            "Sources/App/Settings/SettingsView.swift"
        ])
        XCTAssertEqual(replacement.count, 2)
        let replacementHits = await replacement.search("Search", limit: 10)
        XCTAssertEqual(replacementHits.map(\.path), [
            "Sources/App/Search/SearchController.swift"
        ])

        // The old immutable generation remains valid while a replacement exists.
        let retainedHits = await index.search("SearchViewModel", limit: 10)
        XCTAssertEqual(retainedHits.map(\.path), filenameHits.map(\.path))
    }
}

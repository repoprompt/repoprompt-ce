@testable import RepoPromptCore
import XCTest

final class PathSearchIndexRecoveryTests: XCTestCase {
    func testSearchMatchesFilenameSubpathTokensAndRebuildsDeterministically() async {
        let index = await PathSearchIndex(paths: [
            "Sources/App/Search/SearchViewModel.swift",
            "Sources/App/Settings/SearchPreferencesView.swift",
            "Sources/App/Models/UserProfile.swift",
            "Tests/SearchViewModelTests.swift",
            "docs/search-index-notes.md"
        ])

        let filenameHits = await index.search("SearchViewModel", limit: 10)
        let filenamePaths = Set(filenameHits.map(\.path))
        XCTAssertEqual(filenamePaths, [
            "Sources/App/Search/SearchViewModel.swift",
            "Tests/SearchViewModelTests.swift"
        ])

        let subpathHits = await index.search("App SearchViewModel", limit: 10)
        let subpathPaths = Set(subpathHits.map(\.path))
        XCTAssertEqual(subpathPaths, ["Sources/App/Search/SearchViewModel.swift"])

        guard let firstFilenameHit = filenameHits.first(where: { $0.path == "Sources/App/Search/SearchViewModel.swift" }) else {
            return XCTFail("Expected indexed search result for SearchViewModel.swift")
        }
        let pathAtIndex = await index.path(at: firstFilenameHit.index)
        let filenameAtIndex = await index.filename(at: firstFilenameHit.index)
        XCTAssertEqual(firstFilenameHit.filename, "SearchViewModel.swift")
        XCTAssertEqual(pathAtIndex, firstFilenameHit.path)
        XCTAssertEqual(filenameAtIndex, firstFilenameHit.filename)

        await index.rebuild(paths: [
            "Sources/App/Search/SearchController.swift",
            "Sources/App/Settings/SettingsView.swift"
        ])

        let rebuiltCount = await index.count
        XCTAssertEqual(rebuiltCount, 2)
        let rebuiltHits = await index.search("Search", limit: 10)
        XCTAssertEqual(rebuiltHits.map(\.path), ["Sources/App/Search/SearchController.swift"])
    }
}

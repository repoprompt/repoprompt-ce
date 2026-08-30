@testable import RepoPromptApp
import XCTest

final class WorkspaceSearchServiceTests: XCTestCase {
    func testWorkspaceSearchServiceSearchesSingleRootCatalog() async throws {
        let root = try makeTemporaryRoot(name: "SingleRootSearch")
        try write("view model", to: root.appendingPathComponent("Sources/App/Search/SearchViewModel.swift"))
        try write("tests", to: root.appendingPathComponent("Tests/SearchViewModelTests.swift"))
        try write("readme", to: root.appendingPathComponent("README.md"))

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let snapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)

        let service = WorkspaceSearchService()
        let indexedGeneration = await service.rebuildIndex(from: snapshot)
        let serviceIndexedGeneration = await service.indexedGeneration
        let indexedPathCount = await service.indexedPathCount
        XCTAssertEqual(indexedGeneration, snapshot.generation)
        XCTAssertEqual(serviceIndexedGeneration, snapshot.generation)
        XCTAssertEqual(indexedPathCount, 3)

        let filenameResult = await service.search("SearchViewModel", limit: 10)
        XCTAssertTrue(filenameResult.isIndexReady)
        XCTAssertEqual(filenameResult.indexedGeneration, snapshot.generation)
        XCTAssertEqual(Set(filenameResult.results.map(\.standardizedRelativePath)), [
            "Sources/App/Search/SearchViewModel.swift",
            "Tests/SearchViewModelTests.swift"
        ])

        let subpathResult = await service.search("App SearchViewModel", limit: 10)
        XCTAssertEqual(subpathResult.results.map(\.standardizedRelativePath), ["Sources/App/Search/SearchViewModel.swift"])
    }

    func testWorkspaceSearchServiceSearchesMultiRootCatalog() async throws {
        let rootA = try makeTemporaryRoot(name: "AlphaRootSearch")
        let rootB = try makeTemporaryRoot(name: "BetaRootSearch")
        try write("alpha", to: rootA.appendingPathComponent("Sources/AlphaTarget.swift"))
        try write("shared alpha", to: rootA.appendingPathComponent("Shared/SharedTarget.swift"))
        try write("beta", to: rootB.appendingPathComponent("Sources/BetaTarget.swift"))
        try write("shared beta", to: rootB.appendingPathComponent("Shared/SharedTarget.swift"))

        let store = WorkspaceFileContextStore()
        let recordA = try await store.loadRoot(path: rootA.path)
        let recordB = try await store.loadRoot(path: rootB.path)
        let snapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        XCTAssertEqual(snapshot.diagnostics.rootCount, 2)
        XCTAssertEqual(snapshot.diagnostics.fileCount, 4)

        let service = WorkspaceSearchService()
        await service.prepareIndex(from: snapshot)

        let sharedResult = await service.search("SharedTarget", limit: 10)
        XCTAssertEqual(Set(sharedResult.results.map(\.rootID)), [recordA.id, recordB.id])
        XCTAssertEqual(sharedResult.results.count(where: { $0.standardizedRelativePath == "Shared/SharedTarget.swift" }), 2)

        let rootQualifiedResult = await service.search("\(rootB.lastPathComponent) BetaTarget", limit: 10)
        XCTAssertEqual(rootQualifiedResult.results.map(\.rootID), [recordB.id])
        XCTAssertEqual(rootQualifiedResult.results.map(\.standardizedRelativePath), ["Sources/BetaTarget.swift"])
    }

    private func makeTemporaryRoot(name: String) throws -> URL {
        try makeTestDirectory(name: name)
    }

    private func write(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}

import Foundation
import RepoPromptVCS
import XCTest

final class GitRepositoryQueryContractTests: XCTestCase {
    func testInjectedRepositoryQueriesRunOffMainActor() async throws {
        let root = URL(fileURLWithPath: "/tmp/vcs-contract/repository")
        let repository = GitRepoDescriptor(rootURL: root)
        let queries = RepositoryQueries(repository: repository)
        let resolver = GitRepoTargetResolver(queries: queries)
        let visibleRoot = VCSRepositoryRoot(
            name: "repository",
            fullPath: root.path
        )

        let resolved = try await Task.detached {
            try await resolver.resolveRepoRootToken(
                "repository",
                allRepos: [repository],
                visibleRoots: [visibleRoot],
                defaultRepo: repository
            )
        }.value

        XCTAssertEqual(resolved, repository)
        let requestedPaths = await queries.requestedPaths
        XCTAssertEqual(requestedPaths, [root.path])
    }

    func testBlobValuesAreAvailableWithoutAppImport() throws {
        let format = try GitObjectFormat(gitValue: "sha1")
        let oid = GitBlobOID.blob(bytes: Data(), objectFormat: format)
        XCTAssertEqual(oid.lowercaseHex, "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391")
        XCTAssertEqual(oid.objectFormat, format)
        XCTAssertEqual(format.oidHexCount, 40)
    }
}

private actor RepositoryQueries: GitRepositoryQuerying {
    private let repository: GitRepoDescriptor
    private(set) var requestedPaths: [String] = []

    init(repository: GitRepoDescriptor) {
        self.repository = repository
    }

    func resolveRepository(from url: URL) -> GitRepoDescriptor? {
        requestedPaths.append(url.path)
        return repository
    }

    func listWorktrees(in repository: GitRepoDescriptor) -> [GitWorktreeDescriptor] {
        []
    }
}

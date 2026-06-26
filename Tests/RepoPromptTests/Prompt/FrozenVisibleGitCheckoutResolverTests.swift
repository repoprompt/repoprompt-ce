@testable import RepoPrompt
import XCTest

final class FrozenVisibleGitCheckoutResolverTests: XCTestCase {
    func testResolvesOnlyExactLoadedCanonicalAndLinkedRootsAndExcludesBoundRoots() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: "FrozenVisibleGitCheckoutResolver")
        defer { fixture.cleanup() }

        let canonical = try fixture.makeRepository(named: "canonical")
        let linked = try fixture.makeLinkedWorktree(
            from: canonical,
            named: "linked",
            branch: "feature/visible-checkout"
        )
        let sibling = try fixture.makeLinkedWorktree(
            from: canonical,
            named: "sibling",
            branch: "feature/sibling-checkout"
        )
        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: canonical.path, kind: .primaryWorkspace)
        _ = try await store.loadRoot(path: linked.path, kind: .primaryWorkspace)
        _ = try await store.loadRoot(path: sibling.path, kind: .primaryWorkspace)

        let resolver = FrozenVisibleGitCheckoutResolver(vcsService: VCSService())
        let canonicalIdentities = await resolver.resolve(
            workspaceRootPaths: [canonical.path],
            bindings: [],
            store: store
        )
        XCTAssertEqual(canonicalIdentities.count, 1)
        XCTAssertEqual(canonicalIdentities.first?.kind, .canonical)
        XCTAssertEqual(
            canonicalIdentities.first?.visibleRootPath,
            GitRepoRootAuthorization.canonicalPath(canonical.path)
        )

        let linkedIdentities = await resolver.resolve(
            workspaceRootPaths: [linked.path, linked.path],
            bindings: [],
            store: store
        )
        let linkedIdentity = try XCTUnwrap(linkedIdentities.first)
        XCTAssertEqual(linkedIdentities.count, 1)
        XCTAssertEqual(linkedIdentity.kind, .linkedWorktree)
        XCTAssertEqual(
            linkedIdentity.visibleRootPath,
            GitRepoRootAuthorization.canonicalPath(linked.path)
        )
        XCTAssertNotEqual(
            linkedIdentity.worktreeRootPath,
            GitRepoRootAuthorization.canonicalPath(sibling.path)
        )

        let binding = AgentSessionWorktreeBinding(
            id: "visible-resolver-bound",
            repositoryID: linkedIdentity.repositoryID,
            repoKey: GitRepoDescriptor(rootURL: canonical).repoKey,
            logicalRootPath: linked.path,
            logicalRootName: "linked",
            worktreeID: linkedIdentity.worktreeID,
            worktreeRootPath: linked.path,
            worktreeName: "linked",
            branch: "feature/visible-checkout",
            source: "test"
        )
        let boundIdentities = await resolver.resolve(
            workspaceRootPaths: [linked.path],
            bindings: [binding],
            store: store
        )
        XCTAssertEqual(boundIdentities, [])
    }

    func testOmitsNonGitAndNotLoadedRoots() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: "FrozenVisibleNonGit")
        defer { fixture.cleanup() }

        let nonGit = fixture.sandbox.appendingPathComponent("non-git", isDirectory: true)
        try FileManager.default.createDirectory(at: nonGit, withIntermediateDirectories: true)
        let unlisted = try fixture.makeRepository(named: "not-loaded")
        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: nonGit.path, kind: .primaryWorkspace)

        let identities = await FrozenVisibleGitCheckoutResolver(vcsService: VCSService()).resolve(
            workspaceRootPaths: [nonGit.path, unlisted.path],
            bindings: [],
            store: store
        )
        XCTAssertTrue(identities.isEmpty)
    }
}

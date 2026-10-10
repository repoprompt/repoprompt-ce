import Foundation
import RepoPromptVCS
import XCTest

final class GitReadRootAuthorizationTests: XCTestCase {
    func testNestedWorkspaceDoesNotAdoptEnclosingRepository() throws {
        let root = try fixture()
        let nested = root.appendingPathComponent("nested")
        try directory(root.appendingPathComponent(".git"))
        try directory(nested)
        XCTAssertNil(GitRepositoryLayoutResolver.resolveForRead(atWorkTreeRoot: nested, authorizedRoots: [nested]))
        XCTAssertNil(GitRepositoryLayoutResolver.resolveForRead(atWorkTreeRoot: root, authorizedRoots: [nested]))
        XCTAssertNotNil(GitRepositoryLayoutResolver.resolveForRead(atWorkTreeRoot: root, authorizedRoots: [root]))
    }

    func testUnregisteredExternalGitfileAndSymlinkAreRejected() throws {
        let base = try fixture()
        let root = base.appendingPathComponent("root")
        let external = base.appendingPathComponent("external")
        try directory(root)
        try directory(external)
        let dotGit = root.appendingPathComponent(".git")
        try write("gitdir: \(external.path)\n", to: dotGit)
        XCTAssertNil(GitRepositoryLayoutResolver.resolveForRead(atWorkTreeRoot: root, authorizedRoots: [root]))
        try FileManager.default.removeItem(at: dotGit)
        try FileManager.default.createSymbolicLink(at: dotGit, withDestinationURL: external)
        XCTAssertNil(GitRepositoryLayoutResolver.resolveForRead(atWorkTreeRoot: root, authorizedRoots: [root]))
    }

    func testExternalCommonDirectoryIsRejectedForInternalMetadata() throws {
        let base = try fixture()
        let root = base.appendingPathComponent("root")
        let external = base.appendingPathComponent("external")
        let gitDir = root.appendingPathComponent("metadata")
        try directory(gitDir)
        try directory(external)
        try write("gitdir: metadata\n", to: root.appendingPathComponent(".git"))
        try write("\(external.path)\n", to: gitDir.appendingPathComponent("commondir"))
        XCTAssertNil(GitRepositoryLayoutResolver.resolveForRead(atWorkTreeRoot: root, authorizedRoots: [root]))
        XCTAssertNotNil(GitRepositoryLayoutResolver.resolveForRead(atWorkTreeRoot: root, authorizedRoots: [root, external]))
    }

    func testDirectoryCommonPointerCannotExpandAuthority() throws {
        let base = try fixture()
        let root = base.appendingPathComponent("root")
        let gitDir = root.appendingPathComponent(".git")
        try directory(gitDir)
        try write("../../external\n", to: gitDir.appendingPathComponent("commondir"))
        XCTAssertNil(GitRepositoryLayoutResolver.resolveForRead(atWorkTreeRoot: root, authorizedRoots: [root]))
    }

    func testLinkedMetadataRequiresMatchingBackpointerAndConventionalCommonDirectory() throws {
        let base = try fixture()
        let root = base.appendingPathComponent("linked")
        let common = base.appendingPathComponent("main/.git")
        let gitDir = common.appendingPathComponent("worktrees/linked")
        try directory(root)
        try directory(gitDir)
        let dotGit = root.appendingPathComponent(".git")
        try write("gitdir: \(gitDir.path)\n", to: dotGit)
        try write("../..\n", to: gitDir.appendingPathComponent("commondir"))
        XCTAssertNil(GitRepositoryLayoutResolver.resolveForRead(atWorkTreeRoot: root, authorizedRoots: [root]))
        try write("\(dotGit.path)\n", to: gitDir.appendingPathComponent("gitdir"))
        let layout = try XCTUnwrap(GitRepositoryLayoutResolver.resolveForRead(atWorkTreeRoot: root, authorizedRoots: [root]))
        XCTAssertEqual(layout.commonDir.resolvingSymlinksInPath().path, common.resolvingSymlinksInPath().path)
        XCTAssertNil(GitRepositoryLayoutResolver.resolveForRead(atWorkTreeRoot: base.appendingPathComponent("main"), authorizedRoots: [root]))
        try write("../../../unrelated\n", to: gitDir.appendingPathComponent("commondir"))
        XCTAssertNil(GitRepositoryLayoutResolver.resolveForRead(atWorkTreeRoot: root, authorizedRoots: [root]))
    }

    func testGitfileRejectsTruncatedAndNULTerminatedPaths() throws {
        let base = try fixture()
        let root = base.appendingPathComponent("root")
        try directory(root)
        for path in [
            String(repeating: "./", count: 260) + "../external/.git",
            "../external\0/../root",
            String(repeating: "./", count: 2100)
        ] {
            try write("gitdir: \(path)\n", to: root.appendingPathComponent(".git"))
            XCTAssertNil(GitRepositoryLayoutResolver.resolveForRead(atWorkTreeRoot: root, authorizedRoots: [root]))
        }
    }

    func testExplicitPathAndRootNameCannotAdoptEnclosingRepository() async throws {
        let base = try fixture()
        let nested = base.appendingPathComponent("nested")
        let safe = base.appendingPathComponent("safe")
        try directory(nested)
        try directory(safe)
        let enclosingRepo = GitRepoDescriptor(rootURL: base)
        let safeRepo = GitRepoDescriptor(rootURL: safe)
        let resolver = GitRepoTargetResolver(dependencies: .init(
            resolveRepo: { _ in enclosingRepo },
            listWorktrees: { _ in [] }
        ))
        let roots = [VCSRepositoryRoot(name: "nested", fullPath: nested.path), VCSRepositoryRoot(name: "safe", fullPath: safe.path)]
        for token in [nested.path, "nested"] {
            do {
                _ = try await resolver.resolveRepoRoots(explicitRootTokens: [token], allRepos: [safeRepo], visibleRoots: roots, defaultRepo: safeRepo)
                XCTFail("An explicit loaded-root selector must not grant its parent")
            } catch is GitRepoTargetResolverError {}
        }
    }

    func testExplicitTreeSelectorCannotGrantUnrelatedMetadata() async throws {
        let base = try fixture()
        let root = base.appendingPathComponent("root")
        let external = base.appendingPathComponent("external/.git")
        try directory(root)
        try directory(external)
        try write("gitdir: \(external.path)\n", to: root.appendingPathComponent(".git"))
        let repo = GitRepoDescriptor(rootURL: root)
        let resolver = GitRepoTargetResolver(dependencies: .init(resolveRepo: { _ in repo }, listWorktrees: { _ in [] }))
        do {
            _ = try await resolver.resolveRepoRootToken("root@main", allRepos: [], visibleRoots: [VCSRepositoryRoot(name: "root", fullPath: root.path)], defaultRepo: repo)
            XCTFail("A tree selector must not grant unrelated metadata")
        } catch is GitRepoTargetResolverError {}
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("git-read-root-\(UUID().uuidString)")
        try directory(root)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func directory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }
}

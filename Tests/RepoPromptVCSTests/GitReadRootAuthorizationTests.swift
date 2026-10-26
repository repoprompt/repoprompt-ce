import Foundation
import RepoPromptVCS
import XCTest

final class GitReadRootAuthorizationTests: XCTestCase {
    func testOwnershipProbeUsesFilesystemIdentityWithoutAcceptingAnotherDirectory() throws {
        let base = try fixture()
        let root = base.appendingPathComponent("MixedCaseRoot")
        let dotGit = root.appendingPathComponent(".git")
        try directory(dotGit)
        let layout = try XCTUnwrap(GitRepositoryLayoutResolver.resolveForRead(atWorkTreeRoot: root, authorizedRoots: [root]))
        let binding = try GitReadRepositoryBinding(layout: layout)
        try binding.validateOwnershipProbe(dotGit.path + "\n")
        let alternateCase = base.appendingPathComponent("mixedcaseroot/.git")
        if FileManager.default.fileExists(atPath: alternateCase.path) {
            try binding.validateOwnershipProbe(alternateCase.path + "\n")
        } else {
            // On a case-sensitive volume, the same spelling after lowercasing
            // may name a different directory and must never satisfy the probe.
            try directory(alternateCase)
            XCTAssertThrowsError(try binding.validateOwnershipProbe(alternateCase.path + "\n"))
        }
        let other = base.appendingPathComponent("other/.git")
        try directory(other)
        XCTAssertThrowsError(try binding.validateOwnershipProbe(other.path + "\n"))
        for output in [dotGit.path, dotGit.path + "\nextra\n", dotGit.path + "\0\n", ".git\n"] {
            XCTAssertThrowsError(try binding.validateOwnershipProbe(output))
        }
    }

    func testOwnershipProbeAcceptsAuthorizedMetadataSymlinkTarget() throws {
        let base = try fixture()
        let root = base.appendingPathComponent("root")
        let metadata = root.appendingPathComponent("metadata")
        try directory(metadata)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".git"), withDestinationURL: metadata)
        let layout = try XCTUnwrap(GitRepositoryLayoutResolver.resolveForRead(atWorkTreeRoot: root, authorizedRoots: [root]))
        let binding = try GitReadRepositoryBinding(layout: layout)
        try binding.validateOwnershipProbe(metadata.path + "\n")
        let outside = base.appendingPathComponent("outside")
        try directory(outside)
        try FileManager.default.removeItem(at: root.appendingPathComponent(".git"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".git"), withDestinationURL: outside)
        XCTAssertThrowsError(try binding.revalidate())
        XCTAssertThrowsError(try binding.validateOwnershipProbe(outside.path + "\n"))
    }

    func testNormalBindingIgnoresIrrelevantBackpointer() throws {
        let base = try fixture()
        let root = base.appendingPathComponent("root")
        let dotGit = root.appendingPathComponent(".git")
        let outside = base.appendingPathComponent("synthetic-outside")
        try directory(dotGit)
        // Not Git metadata for a normal checkout; even an oversized unrelated
        // file must not become a snapshot input merely because of its name.
        try write(String(repeating: "synthetic", count: 600), to: outside)
        try FileManager.default.createSymbolicLink(at: dotGit.appendingPathComponent("gitdir"), withDestinationURL: outside)
        let layout = try XCTUnwrap(GitRepositoryLayoutResolver.resolveForRead(atWorkTreeRoot: root, authorizedRoots: [root]))
        let binding = try GitReadRepositoryBinding(layout: layout)
        try binding.revalidate()
    }

    func testCommonPointerFileSymlinkCannotExpandCapturedMetadataAuthority() throws {
        let base = try fixture()
        for usesGitfile in [false, true] {
            let root = base.appendingPathComponent(usesGitfile ? "gitfile" : "normal")
            let gitDir = root.appendingPathComponent(usesGitfile ? "metadata" : ".git")
            let commonFile = gitDir.appendingPathComponent("commondir")
            try directory(gitDir)
            if usesGitfile { try write("gitdir: metadata\n", to: root.appendingPathComponent(".git")) }
            try write(".\n", to: commonFile)
            let layout = try XCTUnwrap(GitRepositoryLayoutResolver.resolveForRead(atWorkTreeRoot: root, authorizedRoots: [root]))
            let binding = try GitReadRepositoryBinding(layout: layout)
            let outside = base.appendingPathComponent(usesGitfile ? "outside-gitfile" : "outside-normal")
            // The declared directory remains legitimate; only the file read escapes.
            try write(".\n", to: outside)
            try FileManager.default.removeItem(at: commonFile)
            try FileManager.default.createSymbolicLink(at: commonFile, withDestinationURL: outside)
            XCTAssertNil(GitRepositoryLayoutResolver.resolveForRead(atWorkTreeRoot: root, authorizedRoots: [root]))
            XCTAssertThrowsError(try binding.revalidate())
            XCTAssertThrowsError(try GitReadRepositoryBinding(layout: layout))
        }
    }

    func testLinkedPointerFileTargetsStayWithinCapturedMetadataAuthority() throws {
        let base = try fixture()
        let root = base.appendingPathComponent("linked")
        let common = base.appendingPathComponent("main/.git")
        let gitDir = common.appendingPathComponent("worktrees/linked")
        let dotGit = root.appendingPathComponent(".git")
        try directory(root)
        try directory(gitDir)
        try write("gitdir: \(gitDir.path)\n", to: dotGit)
        for (name, text) in [("commondir", "../..\n"), ("gitdir", "\(dotGit.path)\n")] {
            let pointer = gitDir.appendingPathComponent(name)
            let inside = gitDir.appendingPathComponent("\(name)-inside")
            try write(text, to: inside)
            try FileManager.default.createSymbolicLink(at: pointer, withDestinationURL: inside)
        }
        let layout = try XCTUnwrap(GitRepositoryLayoutResolver.resolveForRead(atWorkTreeRoot: root, authorizedRoots: [root]))
        let binding = try GitReadRepositoryBinding(layout: layout)
        try binding.revalidate()
        for (name, text) in [("commondir", "../..\n"), ("gitdir", "\(dotGit.path)\n")] {
            let pointer = gitDir.appendingPathComponent(name)
            let outside = base.appendingPathComponent("synthetic-outside-\(name)")
            try write(text, to: outside)
            try FileManager.default.removeItem(at: pointer)
            try FileManager.default.createSymbolicLink(at: pointer, withDestinationURL: outside)
            XCTAssertNil(GitRepositoryLayoutResolver.resolveForRead(atWorkTreeRoot: root, authorizedRoots: [root]))
            XCTAssertThrowsError(try binding.revalidate())
            XCTAssertThrowsError(try GitReadRepositoryBinding(layout: layout))
            try FileManager.default.removeItem(at: pointer)
            try FileManager.default.createSymbolicLink(at: pointer, withDestinationURL: gitDir.appendingPathComponent("\(name)-inside"))
            try binding.revalidate()
        }
    }

    func testNormalCheckoutUnderWorktreesDirectoryDoesNotInferLinkedCommonDirectory() throws {
        let base = try fixture()
        let root = base.appendingPathComponent("worktrees/normal")
        let dotGit = root.appendingPathComponent(".git")
        try directory(dotGit)
        let layout = try XCTUnwrap(GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: root))
        XCTAssertEqual(layout.commonDir.path, dotGit.path)
        XCTAssertFalse(layout.isLinkedWorktree)
        XCTAssertEqual(layout.knownMainWorktreeRoot?.path, root.path)
        let common = root.appendingPathComponent("shared")
        try directory(common)
        try write("../shared\n", to: dotGit.appendingPathComponent("commondir"))
        let pointed = try XCTUnwrap(GitRepositoryLayoutResolver.resolveForRead(atWorkTreeRoot: root, authorizedRoots: [root]))
        XCTAssertEqual(pointed.commonDir.path, common.path)

        let separateRoot = base.appendingPathComponent("worktrees/separate")
        let metadata = separateRoot.appendingPathComponent("metadata")
        try directory(metadata)
        try write("gitdir: metadata\n", to: separateRoot.appendingPathComponent(".git"))
        let separate = try XCTUnwrap(GitRepositoryLayoutResolver.resolveForRead(atWorkTreeRoot: separateRoot, authorizedRoots: [separateRoot]))
        XCTAssertEqual(separate.commonDir.path, metadata.path)
        XCTAssertFalse(separate.isLinkedWorktree)
        XCTAssertEqual(separate.knownMainWorktreeRoot?.path, separateRoot.path)
    }

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

    func testMetadataPathsDoNotTrimWhitespaceIntoLoadedRootAuthority() throws {
        let base = try fixture()
        let root = base.appendingPathComponent("root")
        let whitespaceSibling = base.appendingPathComponent("root ")
        try directory(root)
        try directory(whitespaceSibling)
        let dotGit = root.appendingPathComponent(".git")
        for pointer in [whitespaceSibling.path, "../root "] {
            try write("gitdir: \(pointer)\n", to: dotGit)
            XCTAssertNil(GitRepositoryLayoutResolver.resolveForRead(atWorkTreeRoot: root, authorizedRoots: [root]))
            XCTAssertNotNil(GitRepositoryLayoutResolver.resolveForRead(atWorkTreeRoot: root, authorizedRoots: [root, whitespaceSibling]))
        }
        try FileManager.default.removeItem(at: dotGit)
        try FileManager.default.createSymbolicLink(at: dotGit, withDestinationURL: whitespaceSibling)
        XCTAssertNil(GitRepositoryLayoutResolver.resolveForRead(atWorkTreeRoot: root, authorizedRoots: [root]))
        try FileManager.default.removeItem(at: dotGit)
        try directory(dotGit)
        try write(whitespaceSibling.path + "\n", to: dotGit.appendingPathComponent("commondir"))
        XCTAssertNil(GitRepositoryLayoutResolver.resolveForRead(atWorkTreeRoot: root, authorizedRoots: [root]))
        XCTAssertNotNil(GitRepositoryLayoutResolver.resolveForRead(atWorkTreeRoot: root, authorizedRoots: [root, whitespaceSibling]))
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

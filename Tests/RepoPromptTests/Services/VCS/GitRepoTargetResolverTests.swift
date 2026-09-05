import Foundation
@testable import RepoPromptApp
import XCTest

final class GitRepoTargetResolverTests: XCTestCase {
    func testRejectsSamePathWhenFinalExternalResolutionUsesDifferentRepositoryIdentity() async throws {
        let loadedRootPath = "/tmp/issue-860/loaded"
        let worktreePath = "/tmp/issue-860/advertised"
        let advertisedIdentity = Self.identity(
            repositoryID: "repo-a",
            commonGitDir: "/tmp/repository-a/.git",
            worktreeID: "worktree-a",
            worktreeRootPath: worktreePath,
            mainWorktreeRoot: loadedRootPath
        )
        let replacementIdentity = Self.identity(
            repositoryID: "repo-b",
            commonGitDir: "/tmp/repository-b/.git",
            worktreeID: "worktree-b",
            worktreeRootPath: worktreePath,
            mainWorktreeRoot: "/tmp/repository-b"
        )
        let advertisedWorktree = Self.worktree(from: advertisedIdentity, path: worktreePath)
        let resolver = Self.resolver(
            advertisedWorktree: advertisedWorktree,
            finalDescriptor: Self.repoDescriptor(from: replacementIdentity, path: worktreePath)
        )

        do {
            _ = try await resolver.resolveWorktree(
                selector: "@id:\(advertisedWorktree.worktreeID)",
                repo: Self.loadedRepo(path: loadedRootPath),
                allRepos: [Self.loadedRepo(path: loadedRootPath)],
                authorizedRoots: [Self.root(path: loadedRootPath)]
            )
            XCTFail("A same-path resolution with a different repository identity must be rejected")
        } catch let error as GitRepoTargetResolverError {
            XCTAssertTrue(error.message.contains("worktree path must be inside a loaded root"))
        }
    }

    func testRejectsSamePathWhenFinalExternalResolutionHasNoGitIdentity() async throws {
        let loadedRootPath = "/tmp/issue-860/loaded"
        let worktreePath = "/tmp/issue-860/advertised"
        let identity = Self.identity(
            repositoryID: "repo-a",
            commonGitDir: "/tmp/repository-a/.git",
            worktreeID: "worktree-a",
            worktreeRootPath: worktreePath,
            mainWorktreeRoot: loadedRootPath
        )
        let advertisedWorktree = Self.worktree(from: identity, path: worktreePath)
        let finalDescriptor = GitRepoDescriptor(
            rootURL: URL(fileURLWithPath: worktreePath),
            rootPath: worktreePath,
            repoKey: "replacement-repo",
            displayName: "replacement"
        )
        let resolver = Self.resolver(advertisedWorktree: advertisedWorktree, finalDescriptor: finalDescriptor)

        do {
            _ = try await resolver.resolveWorktree(
                selector: "@id:\(advertisedWorktree.worktreeID)",
                repo: Self.loadedRepo(path: loadedRootPath),
                allRepos: [Self.loadedRepo(path: loadedRootPath)],
                authorizedRoots: [Self.root(path: loadedRootPath)]
            )
            XCTFail("An external resolution without Git identity must be rejected")
        } catch let error as GitRepoTargetResolverError {
            XCTAssertTrue(error.message.contains("worktree path must be inside a loaded root"))
        }
    }

    func testAllowsSamePathWhenFinalExternalResolutionMatchesRepositoryAndWorktreeIdentity() async throws {
        let loadedRootPath = "/tmp/issue-860/loaded"
        let worktreePath = "/tmp/issue-860/advertised"
        let identity = Self.identity(
            repositoryID: "repo-a",
            commonGitDir: "/tmp/repository-a/.git",
            worktreeID: "worktree-a",
            worktreeRootPath: worktreePath,
            mainWorktreeRoot: loadedRootPath
        )
        let advertisedWorktree = Self.worktree(from: identity, path: worktreePath)
        let resolver = Self.resolver(
            advertisedWorktree: advertisedWorktree,
            finalDescriptor: Self.repoDescriptor(from: identity, path: worktreePath)
        )

        let resolved = try await resolver.resolveWorktree(
            selector: "@id:\(advertisedWorktree.worktreeID)",
            repo: Self.loadedRepo(path: loadedRootPath),
            allRepos: [Self.loadedRepo(path: loadedRootPath)],
            authorizedRoots: [Self.root(path: loadedRootPath)]
        )

        XCTAssertEqual(resolved, advertisedWorktree)
    }

    func testPreservesInRootWorktreeWithoutExternalReresolution() async throws {
        let loadedRootPath = "/tmp/issue-860/loaded"
        let worktreePath = "/tmp/issue-860/loaded/feature"
        let identity = Self.identity(
            repositoryID: "repo-a",
            commonGitDir: "/tmp/repository-a/.git",
            worktreeID: "worktree-a",
            worktreeRootPath: worktreePath,
            mainWorktreeRoot: loadedRootPath
        )
        let advertisedWorktree = Self.worktree(from: identity, path: worktreePath)
        let resolver = GitRepoTargetResolver(
            dependencies: .init(
                resolveRepo: { _ in nil },
                listWorktrees: { _ in [advertisedWorktree] }
            )
        )

        let resolved = try await resolver.resolveWorktree(
            selector: "@id:\(advertisedWorktree.worktreeID)",
            repo: Self.loadedRepo(path: loadedRootPath),
            allRepos: [Self.loadedRepo(path: loadedRootPath)],
            authorizedRoots: [Self.root(path: loadedRootPath)]
        )

        XCTAssertEqual(resolved, advertisedWorktree)
    }

    func testRejectsSamePathReplacementForRepoRootSelectorsAndExplicitPath() async throws {
        let loadedRootPath = "/tmp/issue-860/loaded"
        let worktreePath = "/tmp/issue-860/advertised"
        let identity = Self.identity(
            repositoryID: "repo-a",
            commonGitDir: "/tmp/repository-a/.git",
            worktreeID: "worktree-a",
            worktreeRootPath: worktreePath,
            mainWorktreeRoot: loadedRootPath
        )
        let advertisedWorktree = Self.worktree(from: identity, path: worktreePath)
        let replacementIdentity = Self.identity(
            repositoryID: "repo-b",
            commonGitDir: "/tmp/repository-b/.git",
            worktreeID: "worktree-b",
            worktreeRootPath: worktreePath,
            mainWorktreeRoot: "/tmp/repository-b"
        )
        let tokens = [
            "@id:\(advertisedWorktree.worktreeID)",
            "@branch:feature",
            "feature",
            worktreePath
        ]

        for token in tokens {
            let resolver = Self.resolver(
                advertisedWorktree: advertisedWorktree,
                finalDescriptor: Self.repoDescriptor(from: replacementIdentity, path: worktreePath)
            )
            do {
                _ = try await resolver.resolveRepoRoots(
                    explicitRootTokens: [token],
                    allRepos: [Self.loadedRepo(path: loadedRootPath)],
                    visibleRoots: [Self.root(path: loadedRootPath)],
                    defaultRepo: Self.loadedRepo(path: loadedRootPath)
                )
                XCTFail("A replaced external worktree must be rejected for repo_root=\(token)")
            } catch let error as GitRepoTargetResolverError {
                XCTAssertTrue(error.message.contains("worktree path must be inside a loaded root"))
            }
        }
    }

    func testAllowsValidExternalLinkedRepoRootSelectorsAndExplicitPath() async throws {
        let loadedRootPath = "/tmp/issue-860/loaded"
        let worktreePath = "/tmp/issue-860/advertised"
        let identity = Self.identity(
            repositoryID: "repo-a",
            commonGitDir: "/tmp/repository-a/.git",
            worktreeID: "worktree-a",
            worktreeRootPath: worktreePath,
            mainWorktreeRoot: loadedRootPath
        )
        let advertisedWorktree = Self.worktree(from: identity, path: worktreePath)
        let tokens = [
            "@id:\(advertisedWorktree.worktreeID)",
            "@branch:feature",
            "feature",
            worktreePath
        ]

        for token in tokens {
            let resolver = Self.resolver(
                advertisedWorktree: advertisedWorktree,
                finalDescriptor: Self.repoDescriptor(from: identity, path: worktreePath)
            )
            let resolved = try await resolver.resolveRepoRoots(
                explicitRootTokens: [token],
                allRepos: [Self.loadedRepo(path: loadedRootPath)],
                visibleRoots: [Self.root(path: loadedRootPath)],
                defaultRepo: Self.loadedRepo(path: loadedRootPath)
            )
            XCTAssertEqual(resolved.count, 1)
            XCTAssertEqual(resolved.first?.rootPath, worktreePath)
            XCTAssertEqual(resolved.first?.worktreeIdentity, identity)
        }
    }

    func testAllowsValidMainRepoRootSelector() async throws {
        let mainPath = "/tmp/issue-860/loaded"
        let linkedPath = "/tmp/issue-860/advertised"
        let repository = GitWorktreeRepositoryIdentity(
            repositoryID: "repo-a",
            repoKey: "repo-key-repo-a",
            displayName: "repository",
            commonGitDir: "/tmp/repository-a/.git",
            mainWorktreeRoot: mainPath
        )
        let main = GitWorktreeDescriptor(
            worktreeID: "worktree-main",
            repository: repository,
            path: mainPath,
            gitDir: nil,
            name: "loaded",
            branch: "main",
            head: "abc123",
            isMain: true,
            isCurrent: true,
            isDetached: false,
            isLocked: false,
            lockReason: nil,
            isPrunable: false,
            prunableReason: nil
        )
        let linked = Self.worktree(
            from: Self.identity(
                repositoryID: repository.repositoryID,
                commonGitDir: repository.commonGitDir,
                worktreeID: "worktree-linked",
                worktreeRootPath: linkedPath,
                mainWorktreeRoot: mainPath
            ),
            path: linkedPath
        )
        let resolverWithBothWorktrees = GitRepoTargetResolver(
            dependencies: .init(
                resolveRepo: { _ in nil },
                listWorktrees: { _ in [main, linked] }
            )
        )

        let resolved = try await resolverWithBothWorktrees.resolveRepoRoots(
            explicitRootTokens: ["@main"],
            allRepos: [Self.loadedRepo(path: mainPath)],
            visibleRoots: [Self.root(path: mainPath)],
            defaultRepo: Self.loadedRepo(path: mainPath)
        )

        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.rootPath, mainPath)
    }

    func testRejectsSamePathReplacementForMainSelectorAliases() async throws {
        let fixture = Self.externalMainSelectorFixture()
        let scenarios: [(selector: String, target: GitWorktreeDescriptor, replacement: GitWorktreeIdentitySnapshot)] = [
            ("@main", fixture.mainWorktree, fixture.replacementMainIdentity),
            ("@primary", fixture.mainWorktree, fixture.replacementMainIdentity),
            ("@main:feature", fixture.branchWorktree, fixture.replacementBranchIdentity),
            ("@primary:feature", fixture.branchWorktree, fixture.replacementBranchIdentity)
        ]

        for scenario in scenarios {
            let resolver = Self.resolver(
                worktrees: fixture.worktrees,
                finalDescriptor: Self.repoDescriptor(from: scenario.replacement, path: scenario.target.path)
            )
            do {
                _ = try await resolver.resolveRepoRoots(
                    explicitRootTokens: [scenario.selector],
                    allRepos: [fixture.defaultRepo],
                    visibleRoots: [fixture.visibleRoot],
                    defaultRepo: fixture.defaultRepo
                )
                XCTFail("A replaced external worktree must be rejected for repo_root=\(scenario.selector)")
            } catch let error as GitRepoTargetResolverError {
                XCTAssertTrue(error.message.contains("worktree path must be inside a loaded root"), error.message)
            }
        }
    }

    func testAllowsValidExternalMainSelectorAliases() async throws {
        let fixture = Self.externalMainSelectorFixture()
        let scenarios: [(selector: String, target: GitWorktreeDescriptor, identity: GitWorktreeIdentitySnapshot)] = [
            ("@main", fixture.mainWorktree, fixture.mainIdentity),
            ("@primary", fixture.mainWorktree, fixture.mainIdentity),
            ("@main:feature", fixture.branchWorktree, fixture.branchIdentity),
            ("@primary:feature", fixture.branchWorktree, fixture.branchIdentity)
        ]

        for scenario in scenarios {
            let resolver = Self.resolver(
                worktrees: fixture.worktrees,
                finalDescriptor: Self.repoDescriptor(from: scenario.identity, path: scenario.target.path)
            )
            let resolved = try await resolver.resolveRepoRoots(
                explicitRootTokens: [scenario.selector],
                allRepos: [fixture.defaultRepo],
                visibleRoots: [fixture.visibleRoot],
                defaultRepo: fixture.defaultRepo
            )

            XCTAssertEqual(resolved.count, 1)
            XCTAssertEqual(resolved.first?.rootPath, scenario.target.path)
            XCTAssertEqual(resolved.first?.worktreeIdentity, scenario.identity)
        }
    }

    private static func resolver(
        advertisedWorktree: GitWorktreeDescriptor,
        finalDescriptor: GitRepoDescriptor?
    ) -> GitRepoTargetResolver {
        resolver(worktrees: [advertisedWorktree], finalDescriptor: finalDescriptor)
    }

    private static func resolver(
        worktrees: [GitWorktreeDescriptor],
        finalDescriptor: GitRepoDescriptor?
    ) -> GitRepoTargetResolver {
        GitRepoTargetResolver(
            dependencies: .init(
                resolveRepo: { _ in finalDescriptor },
                listWorktrees: { _ in worktrees }
            )
        )
    }

    private struct ExternalMainSelectorFixture {
        let defaultRepo: GitRepoDescriptor
        let visibleRoot: WorkspaceRootRef
        let worktrees: [GitWorktreeDescriptor]
        let mainWorktree: GitWorktreeDescriptor
        let branchWorktree: GitWorktreeDescriptor
        let mainIdentity: GitWorktreeIdentitySnapshot
        let branchIdentity: GitWorktreeIdentitySnapshot
        let replacementMainIdentity: GitWorktreeIdentitySnapshot
        let replacementBranchIdentity: GitWorktreeIdentitySnapshot
    }

    private static func externalMainSelectorFixture() -> ExternalMainSelectorFixture {
        let loadedPath = "/tmp/issue-860/loaded-linked"
        let mainPath = "/tmp/issue-860/external-main"
        let branchPath = "/tmp/issue-860/external-feature"
        let mainWorktreeRoot = mainPath
        let commonGitDir = "/tmp/repository-a/.git"
        let loadedIdentity = Self.identity(
            repositoryID: "repo-a",
            commonGitDir: commonGitDir,
            worktreeID: "worktree-loaded",
            worktreeRootPath: loadedPath,
            mainWorktreeRoot: mainWorktreeRoot
        )
        let mainIdentity = Self.identity(
            repositoryID: "repo-a",
            commonGitDir: commonGitDir,
            worktreeID: "worktree-main",
            worktreeRootPath: mainPath,
            mainWorktreeRoot: mainWorktreeRoot,
            isMain: true
        )
        let branchIdentity = Self.identity(
            repositoryID: "repo-a",
            commonGitDir: commonGitDir,
            worktreeID: "worktree-feature",
            worktreeRootPath: branchPath,
            mainWorktreeRoot: mainWorktreeRoot
        )
        let replacementMainIdentity = Self.identity(
            repositoryID: "repo-b",
            commonGitDir: "/tmp/repository-b/.git",
            worktreeID: "replacement-main",
            worktreeRootPath: mainPath,
            mainWorktreeRoot: "/tmp/repository-b",
            isMain: true
        )
        let replacementBranchIdentity = Self.identity(
            repositoryID: "repo-b",
            commonGitDir: "/tmp/repository-b/.git",
            worktreeID: "replacement-feature",
            worktreeRootPath: branchPath,
            mainWorktreeRoot: "/tmp/repository-b"
        )
        let loadedWorktree = Self.worktree(
            from: loadedIdentity,
            path: loadedPath,
            name: "loaded-linked",
            branch: "loaded"
        )
        let mainWorktree = Self.worktree(
            from: mainIdentity,
            path: mainPath,
            name: "external-main",
            branch: "main"
        )
        let branchWorktree = Self.worktree(
            from: branchIdentity,
            path: branchPath,
            name: "external-feature",
            branch: "feature"
        )

        return ExternalMainSelectorFixture(
            defaultRepo: Self.repoDescriptor(from: loadedIdentity, path: loadedPath),
            visibleRoot: Self.root(path: loadedPath),
            worktrees: [loadedWorktree, mainWorktree, branchWorktree],
            mainWorktree: mainWorktree,
            branchWorktree: branchWorktree,
            mainIdentity: mainIdentity,
            branchIdentity: branchIdentity,
            replacementMainIdentity: replacementMainIdentity,
            replacementBranchIdentity: replacementBranchIdentity
        )
    }

    private static func root(path: String) -> WorkspaceRootRef {
        WorkspaceRootRef(id: UUID(), name: URL(fileURLWithPath: path).lastPathComponent, fullPath: path)
    }

    private static func loadedRepo(path: String) -> GitRepoDescriptor {
        GitRepoDescriptor(
            rootURL: URL(fileURLWithPath: path),
            rootPath: path,
            repoKey: "loaded-repo",
            displayName: URL(fileURLWithPath: path).lastPathComponent
        )
    }

    private static func identity(
        repositoryID: String,
        commonGitDir: String,
        worktreeID: String,
        worktreeRootPath: String,
        mainWorktreeRoot: String,
        isMain: Bool = false
    ) -> GitWorktreeIdentitySnapshot {
        GitWorktreeIdentitySnapshot(
            repository: GitWorktreeRepositoryIdentity(
                repositoryID: repositoryID,
                repoKey: "repo-key-\(repositoryID)",
                displayName: "repository",
                commonGitDir: commonGitDir,
                mainWorktreeRoot: mainWorktreeRoot
            ),
            worktreeID: worktreeID,
            worktreeRootPath: worktreeRootPath,
            isMain: isMain
        )
    }

    private static func repoDescriptor(
        from identity: GitWorktreeIdentitySnapshot,
        path: String
    ) -> GitRepoDescriptor {
        GitRepoDescriptor(
            rootURL: URL(fileURLWithPath: path),
            rootPath: path,
            repoKey: identity.repository.repoKey,
            displayName: identity.repository.displayName,
            worktreeIdentity: identity
        )
    }

    private static func worktree(
        from identity: GitWorktreeIdentitySnapshot,
        path: String,
        name: String = "feature",
        branch: String? = "feature"
    ) -> GitWorktreeDescriptor {
        GitWorktreeDescriptor(
            worktreeID: identity.worktreeID,
            repository: identity.repository,
            path: path,
            gitDir: identity.isMain ? nil : "/tmp/git/worktrees/\(identity.worktreeID)",
            name: name,
            branch: branch,
            head: "abc123",
            isMain: identity.isMain,
            isCurrent: false,
            isDetached: false,
            isLocked: false,
            lockReason: nil,
            isPrunable: false,
            prunableReason: nil
        )
    }
}

final class AgentWorktreeRuntimeWorkspaceResolverIdentityTests: XCTestCase {
    func testRejectsPersistedBindingWhenFreshIdentityChangesAtTheSamePath() {
        let path = "/tmp/issue-860/advertised"
        let binding = Self.binding(
            path: path,
            repositoryID: "repo-a",
            worktreeID: "worktree-a",
            commonGitDir: "/tmp/repository-a/.git"
        )
        let replacement = Self.identity(
            repositoryID: "repo-b",
            commonGitDir: "/tmp/repository-b/.git",
            worktreeID: "worktree-b",
            worktreeRootPath: path
        )
        let dependencies = AgentWorktreeRuntimeWorkspaceResolver.Dependencies(
            directoryExists: { _ in true },
            resolveIdentity: { _ in replacement }
        )

        XCTAssertThrowsError(
            try AgentWorktreeRuntimeWorkspaceResolver.effectiveWorkspacePath(
                bindings: [binding],
                fallbackWorkspacePath: "/tmp/issue-860/logical",
                dependencies: dependencies
            )
        )
    }

    func testRejectsPersistedBindingWhenCommonGitDirectoryChangesAtTheSamePath() {
        let path = "/tmp/issue-860/advertised"
        let binding = Self.binding(
            path: path,
            repositoryID: "repo-a",
            worktreeID: "worktree-a",
            commonGitDir: "/tmp/repository-a/.git"
        )
        let replacement = Self.identity(
            repositoryID: "repo-a",
            commonGitDir: "/tmp/repository-b/.git",
            worktreeID: "worktree-a",
            worktreeRootPath: path
        )
        let dependencies = AgentWorktreeRuntimeWorkspaceResolver.Dependencies(
            directoryExists: { _ in true },
            resolveIdentity: { _ in replacement }
        )

        XCTAssertThrowsError(
            try AgentWorktreeRuntimeWorkspaceResolver.effectiveWorkspacePath(
                bindings: [binding],
                fallbackWorkspacePath: "/tmp/issue-860/logical",
                dependencies: dependencies
            )
        )
    }

    func testRejectsPersistedBindingWhenFreshIdentityIsUnavailable() {
        let path = "/tmp/issue-860/advertised"
        let binding = Self.binding(
            path: path,
            repositoryID: "repo-a",
            worktreeID: "worktree-a",
            commonGitDir: "/tmp/repository-a/.git"
        )
        let dependencies = AgentWorktreeRuntimeWorkspaceResolver.Dependencies(
            directoryExists: { _ in true },
            resolveIdentity: { _ in nil }
        )

        XCTAssertThrowsError(
            try AgentWorktreeRuntimeWorkspaceResolver.effectiveWorkspacePath(
                bindings: [binding],
                fallbackWorkspacePath: "/tmp/issue-860/logical",
                dependencies: dependencies
            )
        )
    }

    func testAllowsPersistedBindingWhenFreshIdentityMatchesRepositoryAndWorktree() throws {
        let path = "/tmp/issue-860/advertised"
        let identity = Self.identity(
            repositoryID: "repo-a",
            commonGitDir: "/tmp/repository-a/.git",
            worktreeID: "worktree-a",
            worktreeRootPath: path
        )
        let binding = Self.binding(
            path: path,
            repositoryID: identity.repository.repositoryID,
            worktreeID: identity.worktreeID,
            commonGitDir: identity.repository.commonGitDir
        )
        let dependencies = AgentWorktreeRuntimeWorkspaceResolver.Dependencies(
            directoryExists: { _ in true },
            resolveIdentity: { _ in identity }
        )

        let resolved = try AgentWorktreeRuntimeWorkspaceResolver.effectiveWorkspacePath(
            bindings: [binding],
            fallbackWorkspacePath: "/tmp/issue-860/logical",
            dependencies: dependencies
        )

        XCTAssertEqual(resolved, path)
    }

    private static func binding(
        path: String,
        repositoryID: String,
        worktreeID: String,
        commonGitDir: String
    ) -> AgentSessionWorktreeBinding {
        AgentSessionWorktreeBinding(
            id: "binding",
            repositoryID: repositoryID,
            repoKey: "repo-key-\(repositoryID)",
            logicalRootPath: "/tmp/issue-860/logical",
            worktreeID: worktreeID,
            worktreeRootPath: path,
            commonGitDir: commonGitDir,
            isMainWorktree: false,
            source: "test"
        )
    }

    private static func identity(
        repositoryID: String,
        commonGitDir: String,
        worktreeID: String,
        worktreeRootPath: String
    ) -> GitWorktreeIdentitySnapshot {
        GitWorktreeIdentitySnapshot(
            repository: GitWorktreeRepositoryIdentity(
                repositoryID: repositoryID,
                repoKey: "repo-key-\(repositoryID)",
                displayName: "repository",
                commonGitDir: commonGitDir,
                mainWorktreeRoot: "/tmp/issue-860/loaded"
            ),
            worktreeID: worktreeID,
            worktreeRootPath: worktreeRootPath,
            isMain: false
        )
    }
}

import Foundation
@testable import RepoPromptApp
import RepoPromptVCS
import XCTest

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

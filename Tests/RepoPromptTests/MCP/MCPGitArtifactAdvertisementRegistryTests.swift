@testable import RepoPromptApp
import XCTest

@MainActor
final class MCPGitArtifactAdvertisementRegistryTests: XCTestCase {
    func testExactAliasGrantIsScopedReplacedAndDoesNotIncludeManifest() throws {
        let registry = MCPGitArtifactAdvertisementRegistry()
        let workspaceID = UUID()
        let tabID = UUID()
        let sessionID = UUID()
        let capability = makeCapability(
            workspaceID: workspaceID,
            tabID: tabID,
            sessionID: sessionID
        )
        let identity = WorkspaceSelectionIdentity(workspaceID: workspaceID, tabID: tabID)
        let map = makeArtifact(
            relativePath: "repos/repo/2026-06-20/0100/MAP.txt",
            kind: .map,
            disposition: .primaryAutoSelect,
            root: capability.gitDataRoot
        )
        let patch = makeArtifact(
            relativePath: "repos/repo/2026-06-20/0100/diff/file.patch",
            kind: .perFilePatch,
            disposition: .advertisedSelectable,
            root: capability.gitDataRoot
        )
        let manifest = makeArtifact(
            relativePath: "repos/repo/2026-06-20/0100/manifest.json",
            kind: .manifest,
            disposition: .authorizationDependency,
            root: capability.gitDataRoot
        )

        let first = try registry.replace(
            identity: identity,
            capability: capability,
            artifacts: [manifest, map, patch]
        )
        XCTAssertEqual(
            try registry.lookup(
                exactAlias: XCTUnwrap(map.clientAlias),
                identity: identity,
                capability: capability
            ),
            .granted(artifact: map, snapshot: first)
        )
        XCTAssertEqual(
            try registry.lookup(
                exactAlias: XCTUnwrap(patch.clientAlias),
                identity: identity,
                capability: capability
            ),
            .granted(artifact: patch, snapshot: first)
        )
        XCTAssertEqual(
            try registry.lookup(
                exactAlias: XCTUnwrap(manifest.clientAlias),
                identity: identity,
                capability: capability
            ),
            .rejected(.neverAdvertised)
        )

        let mismatchedIdentity = GitDiffPublishedArtifact(
            kind: .map,
            absolutePath: patch.absolutePath,
            gitDataRelativePath: map.gitDataRelativePath,
            clientAlias: map.clientAlias,
            selectionDisposition: .primaryAutoSelect
        )
        _ = try registry.replace(
            identity: identity,
            capability: capability,
            artifacts: [mismatchedIdentity]
        )
        XCTAssertEqual(
            try registry.lookup(
                exactAlias: XCTUnwrap(map.clientAlias),
                identity: identity,
                capability: capability
            ),
            .rejected(.neverAdvertised)
        )

        let second = try registry.replace(
            identity: identity,
            capability: capability,
            artifacts: [map]
        )
        XCTAssertFalse(registry.isCurrent(first))
        XCTAssertTrue(registry.isCurrent(second))
        XCTAssertEqual(
            try registry.lookup(
                exactAlias: XCTUnwrap(patch.clientAlias),
                identity: identity,
                capability: capability
            ),
            .rejected(.neverAdvertised)
        )
    }

    func testSessionRootBindingWorkspaceAndTabMismatchesFailClosed() throws {
        let registry = MCPGitArtifactAdvertisementRegistry()
        let workspaceID = UUID()
        let tabID = UUID()
        let capability = makeCapability(
            workspaceID: workspaceID,
            tabID: tabID,
            sessionID: UUID()
        )
        let identity = WorkspaceSelectionIdentity(workspaceID: workspaceID, tabID: tabID)
        let artifact = makeArtifact(
            relativePath: "repos/repo/2026-06-20/0100/MAP.txt",
            kind: .map,
            disposition: .primaryAutoSelect,
            root: capability.gitDataRoot
        )
        _ = try registry.replace(
            identity: identity,
            capability: capability,
            artifacts: [artifact]
        )
        let alias = try XCTUnwrap(artifact.clientAlias)

        let wrongSession = makeCapability(
            workspaceID: workspaceID,
            tabID: tabID,
            sessionID: UUID(),
            root: capability.gitDataRoot
        )
        XCTAssertEqual(
            registry.lookup(
                exactAlias: alias,
                identity: identity,
                capability: wrongSession
            ),
            .rejected(.sessionMismatch)
        )
        XCTAssertEqual(
            registry.lookup(
                exactAlias: alias,
                identity: identity,
                capability: capability
            ),
            .rejected(.neverAdvertised),
            "A session mismatch revokes rather than temporarily hiding the grant"
        )

        _ = try registry.replace(
            identity: identity,
            capability: capability,
            artifacts: [artifact]
        )
        let wrongRoot = makeCapability(
            workspaceID: workspaceID,
            tabID: tabID,
            sessionID: capability.sessionID,
            root: WorkspaceRootRef(
                id: UUID(),
                name: "_git_data",
                fullPath: capability.gitDataRoot.fullPath
            )
        )
        XCTAssertEqual(
            registry.lookup(
                exactAlias: alias,
                identity: identity,
                capability: wrongRoot
            ),
            .rejected(.checkoutBindingMismatch)
        )

        let visibleRoot = WorkspaceRootRef(
            id: UUID(),
            name: "VisibleLinked",
            fullPath: "/tmp/visible-linked"
        )
        let visibleCheckout = FrozenVisibleGitCheckoutIdentity(
            workspaceRoot: visibleRoot,
            visibleRootPath: visibleRoot.fullPath,
            repositoryRootPath: visibleRoot.fullPath,
            worktreeRootPath: visibleRoot.fullPath,
            commonGitDirectoryPath: "/tmp/repository/.git",
            mainWorktreeRootPath: "/tmp/repository",
            repositoryID: "gitrepo-visible",
            worktreeID: "wt-visible",
            kind: .linkedWorktree
        )
        let visibleCapability = makeCapability(
            workspaceID: workspaceID,
            tabID: tabID,
            sessionID: capability.sessionID,
            root: capability.gitDataRoot,
            visibleRootCheckouts: [visibleCheckout]
        )
        _ = try registry.replace(
            identity: identity,
            capability: visibleCapability,
            artifacts: [artifact]
        )
        let reloadedVisibleCheckout = FrozenVisibleGitCheckoutIdentity(
            workspaceRoot: WorkspaceRootRef(
                id: UUID(),
                name: visibleRoot.name,
                fullPath: visibleRoot.fullPath
            ),
            visibleRootPath: visibleCheckout.visibleRootPath,
            repositoryRootPath: visibleCheckout.repositoryRootPath,
            worktreeRootPath: visibleCheckout.worktreeRootPath,
            commonGitDirectoryPath: visibleCheckout.commonGitDirectoryPath,
            mainWorktreeRootPath: visibleCheckout.mainWorktreeRootPath,
            repositoryID: visibleCheckout.repositoryID,
            worktreeID: visibleCheckout.worktreeID,
            kind: visibleCheckout.kind
        )
        let staleVisibleCapability = makeCapability(
            workspaceID: workspaceID,
            tabID: tabID,
            sessionID: capability.sessionID,
            root: capability.gitDataRoot,
            visibleRootCheckouts: [reloadedVisibleCheckout]
        )
        XCTAssertEqual(
            registry.lookup(
                exactAlias: alias,
                identity: identity,
                capability: staleVisibleCapability
            ),
            .rejected(.checkoutBindingMismatch)
        )

        _ = try registry.replace(
            identity: identity,
            capability: capability,
            artifacts: [artifact]
        )
        XCTAssertEqual(
            registry.lookup(
                exactAlias: alias,
                identity: WorkspaceSelectionIdentity(
                    workspaceID: workspaceID,
                    tabID: UUID()
                ),
                capability: makeCapability(
                    workspaceID: workspaceID,
                    tabID: UUID(),
                    sessionID: capability.sessionID,
                    root: capability.gitDataRoot
                )
            ),
            .rejected(.wrongTab)
        )
        XCTAssertEqual(
            registry.lookup(
                exactAlias: alias,
                identity: WorkspaceSelectionIdentity(
                    workspaceID: UUID(),
                    tabID: tabID
                ),
                capability: makeCapability(
                    workspaceID: UUID(),
                    tabID: tabID,
                    sessionID: capability.sessionID,
                    root: capability.gitDataRoot
                )
            ),
            .rejected(.wrongWorkspace)
        )
    }

    func testWorkspaceRetentionRemovesDeletedWorkspaceGrant() throws {
        let registry = MCPGitArtifactAdvertisementRegistry()
        let workspaceID = UUID()
        let capability = makeCapability(
            workspaceID: workspaceID,
            tabID: UUID(),
            sessionID: nil
        )
        let identity = WorkspaceSelectionIdentity(
            workspaceID: workspaceID,
            tabID: capability.creatorTabID
        )
        let artifact = makeArtifact(
            relativePath: "repos/repo/2026-06-20/0100/MAP.txt",
            kind: .map,
            disposition: .primaryAutoSelect,
            root: capability.gitDataRoot
        )
        _ = try registry.replace(
            identity: identity,
            capability: capability,
            artifacts: [artifact]
        )

        registry.retainWorkspaces([])

        XCTAssertEqual(
            try registry.lookup(
                exactAlias: XCTUnwrap(artifact.clientAlias),
                identity: identity,
                capability: capability
            ),
            .rejected(.neverAdvertised)
        )
    }

    private func makeCapability(
        workspaceID: UUID,
        tabID: UUID,
        sessionID: UUID?,
        root: WorkspaceRootRef? = nil,
        visibleRootCheckouts: [FrozenVisibleGitCheckoutIdentity] = []
    ) -> SelectedGitArtifactCapability {
        let workspacePath = "/tmp/artifact-grant-\(workspaceID.uuidString)"
        return SelectedGitArtifactCapability(
            workspaceID: workspaceID,
            workspaceDirectoryPath: workspacePath,
            gitDataRoot: root ?? WorkspaceRootRef(
                id: UUID(),
                name: "_git_data",
                fullPath: workspacePath + "/_git_data"
            ),
            creatorTabID: tabID,
            sessionID: sessionID,
            boundCheckouts: [],
            visibleRootCheckouts: visibleRootCheckouts,
            canonicalWorkspaceRootPaths: [workspacePath + "/Repo"]
        )
    }

    private func makeArtifact(
        relativePath: String,
        kind: GitDiffPublishedArtifactKind,
        disposition: GitDiffPublishedArtifactSelectionDisposition,
        root: WorkspaceRootRef
    ) -> GitDiffPublishedArtifact {
        GitDiffPublishedArtifact(
            kind: kind,
            absolutePath: root.standardizedFullPath + "/" + relativePath,
            gitDataRelativePath: relativePath,
            clientAlias: "_git_data/" + relativePath,
            selectionDisposition: disposition
        )
    }
}

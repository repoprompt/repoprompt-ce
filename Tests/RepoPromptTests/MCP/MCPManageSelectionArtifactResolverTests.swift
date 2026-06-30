@testable import RepoPrompt
import XCTest

@MainActor
final class MCPManageSelectionArtifactResolverTests: XCTestCase {
    func testExactAdvertisedInsertionAndSelectedRemovalFailClosedForSiblingsAndSlices() async throws {
        let fixture = try await makeFixture()
        defer { fixture.repositoryFixture.cleanup() }

        let registry = MCPGitArtifactAdvertisementRegistry()
        let resolver = MCPManageSelectionArtifactResolver(
            store: fixture.store,
            registry: registry
        )
        let identity = WorkspaceSelectionIdentity(
            workspaceID: fixture.capability.workspaceID,
            tabID: fixture.capability.creatorTabID
        )
        _ = try registry.replace(
            identity: identity,
            capability: fixture.capability,
            artifacts: fixture.published.advertisedSelectionArtifacts
        )
        let patch = try XCTUnwrap(fixture.published.allPatch)
        let patchAlias = try XCTUnwrap(patch.clientAlias)

        let insertion = await resolver.resolve(
            MCPManageSelectionArtifactResolutionRequest(
                paths: ["Sources/App.swift", patchAlias],
                sliceInputs: [],
                use: .insert,
                mode: "full",
                physicalSelection: StoredSelection(),
                identity: identity,
                capability: fixture.capability
            )
        )
        XCTAssertEqual(insertion.ordinaryPaths, ["Sources/App.swift"])
        XCTAssertEqual(insertion.absolutePaths, [patch.absolutePath])
        XCTAssertTrue(insertion.invalidDiagnostics.isEmpty)
        XCTAssertNotNil(insertion.fence?.grantSnapshot)

        let ordinaryPrefix = await resolver.resolve(
            MCPManageSelectionArtifactResolutionRequest(
                paths: ["_git_database/file.swift"],
                sliceInputs: [],
                use: .insert,
                mode: "full",
                physicalSelection: StoredSelection(),
                identity: identity,
                capability: fixture.capability
            )
        )
        XCTAssertEqual(ordinaryPrefix.ordinaryPaths, ["_git_database/file.swift"])
        XCTAssertTrue(ordinaryPrefix.invalidDiagnostics.isEmpty)

        let selected = StoredSelection(
            selectedPaths: ["/ordinary.swift", patch.absolutePath],

            codemapAutoEnabled: false
        )
        let removal = try await resolver.resolve(
            MCPManageSelectionArtifactResolutionRequest(
                paths: [
                    patchAlias,
                    XCTUnwrap(fixture.published.map.clientAlias)
                ],
                sliceInputs: [],
                use: .remove,
                mode: "full",
                physicalSelection: selected,
                identity: identity,
                capability: fixture.capability
            )
        )
        XCTAssertEqual(
            removal.absolutePaths,
            [patch.absolutePath]
        )
        XCTAssertTrue(removal.invalidDiagnostics.contains {
            $0.contains("alias is not selected")
        })
        XCTAssertNil(removal.fence?.grantSnapshot)

        let siblingAlias = patchAlias.replacingOccurrences(
            of: "diff/all.patch",
            with: "diff/unadvertised.patch"
        )
        let rejected = await resolver.resolve(
            MCPManageSelectionArtifactResolutionRequest(
                paths: [
                    siblingAlias,
                    "_git_data/" + fixture.published.manifest.gitDataRelativePath,
                    patchAlias + ".bak"
                ],
                sliceInputs: [
                    WorkspaceSelectionSliceInput(
                        path: patchAlias,
                        ranges: [LineRange(start: 1, end: 1)]
                    )
                ],
                use: .insert,
                mode: "full",
                physicalSelection: selected,
                identity: identity,
                capability: fixture.capability
            )
        )
        XCTAssertTrue(rejected.artifacts.isEmpty)
        XCTAssertEqual(rejected.ordinaryPaths, [])
        XCTAssertEqual(rejected.ordinarySliceInputs, [])
        XCTAssertTrue(rejected.invalidDiagnostics.contains {
            $0.contains("never advertised")
        })
        XCTAssertTrue(rejected.invalidDiagnostics.contains {
            $0.contains("do not support slices")
        })

        let unsupportedMode = await resolver.resolve(
            MCPManageSelectionArtifactResolutionRequest(
                paths: [patchAlias],
                sliceInputs: [],
                use: .insert,
                mode: "codemap_only",
                physicalSelection: selected,
                identity: identity,
                capability: fixture.capability
            )
        )
        XCTAssertTrue(unsupportedMode.artifacts.isEmpty)
        XCTAssertTrue(unsupportedMode.invalidDiagnostics.contains {
            $0.contains("mode 'full' only")
        })

        await fixture.store.unloadRoot(id: fixture.capability.gitDataRoot.id)
        let stale = await resolver.resolve(
            MCPManageSelectionArtifactResolutionRequest(
                paths: [patchAlias],
                sliceInputs: [],
                use: .insert,
                mode: "full",
                physicalSelection: selected,
                identity: identity,
                capability: fixture.capability
            )
        )
        XCTAssertTrue(stale.artifacts.isEmpty)
        XCTAssertTrue(stale.invalidDiagnostics.contains {
            $0.contains("unloaded or reloaded")
        })
    }

    private struct Fixture {
        let repositoryFixture: ReviewGitRepositoryFixture
        let store: WorkspaceFileContextStore
        let capability: SelectedGitArtifactCapability
        let published: GitDiffPublishedArtifactSet
    }

    private func makeFixture() async throws -> Fixture {
        let repositoryFixture = try ReviewGitRepositoryFixture(
            name: "ManageSelectionArtifactResolver"
        )
        let canonicalRepo = try repositoryFixture.makeRepository(
            named: "Repo",
            files: ["Sources/App.swift": "let value = 1\n"]
        )
        let repo = try repositoryFixture.makeLinkedWorktree(
            from: canonicalRepo,
            named: "VisibleLinked",
            branch: "feature/manage-selection-visible"
        )
        let layout = try XCTUnwrap(
            GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: repo)
        )
        let workspace = repositoryFixture.sandbox.appendingPathComponent(
            "workspace",
            isDirectory: true
        )
        let snapshotID = "2026-06-20/0100"
        let repoKey = "repo-key"
        let tabID = UUID()
        let manifest = GitDiffSnapshotManifest(
            snapshotID: snapshotID,
            generatedAt: Date(timeIntervalSince1970: 1),
            mode: .deep,
            compare: "HEAD",
            compareInput: nil,
            scope: .selected,
            requestedPaths: ["Sources/App.swift"],
            fingerprint: GitDiffFingerprint(
                headSHA: "abc",
                baseRef: "HEAD",
                statusHash: "status",
                generatedAt: Date(timeIntervalSince1970: 1)
            ),
            contextLines: 3,
            detectRenames: false,
            summary: GitDiffSnapshotManifest.Summary(
                files: 1,
                insertions: 1,
                deletions: 0
            ),
            files: [
                GitDiffSnapshotManifest.FileEntry(
                    gitPath: "Sources/App.swift",
                    status: "M",
                    additions: 1,
                    deletions: 0,
                    patchPath: "diff/per-file/Sources-App.swift.patch",
                    bytes: 12,
                    lines: 1,
                    hunks: nil
                )
            ],
            repoKey: repoKey,
            repoRoot: repo.path,
            isWorktree: true,
            worktreeName: "VisibleLinked",
            worktreeRoot: repo.path,
            mainWorktreeRoot: layout.knownMainWorktreeRoot?.path,
            commonGitDir: layout.commonDir.path,
            tabID: tabID
        )
        let snapshotDirectory = workspace.appendingPathComponent(
            "_git_data/repos/\(repoKey)/\(snapshotID)",
            isDirectory: true
        )
        let published = try GitDiffPublishedArtifactSet(
            snapshotDirectoryURL: snapshotDirectory,
            snapshotRef: GitDiffSnapshotStore.GitDiffSnapshotRef(
                repoKey: repoKey,
                snapshotID: snapshotID
            ),
            manifest: manifest,
            allPatchRelativePath: "diff/all.patch"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let manifestContent = try XCTUnwrap(
            String(data: encoder.encode(manifest), encoding: .utf8)
        )
        for artifact in published.orderedArtifacts {
            let content: String = switch artifact.kind {
            case .manifest:
                manifestContent
            case .map:
                "map context"
            case .allPatch:
                "diff --git a/Sources/App.swift b/Sources/App.swift"
            case .perFilePatch:
                "per-file patch"
            }
            try FileSystemTestSupport.write(
                content,
                to: URL(fileURLWithPath: artifact.absolutePath)
            )
        }

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(
            path: workspace.appendingPathComponent("_git_data").path,
            kind: .workspaceGitData
        )
        let rootValue = await store.exactRootRef(
            path: workspace.appendingPathComponent("_git_data").path,
            kind: .workspaceGitData
        )
        let root = try XCTUnwrap(rootValue)
        _ = try await store.loadRoot(path: repo.path, kind: .primaryWorkspace)
        let ingress = await store.ingressPublishedGitArtifacts(
            WorkspacePublishedGitArtifactIngressRequest(
                root: root,
                artifacts: published.orderedArtifacts
            )
        )
        XCTAssertEqual(
            ingress.advertisementReadyArtifacts(for: published),
            published.advertisedSelectionArtifacts
        )
        let visibleRootCheckouts = await FrozenVisibleGitCheckoutResolver(
            vcsService: VCSService()
        ).resolve(
            workspaceRootPaths: [repo.path],
            bindings: [],
            store: store
        )
        XCTAssertEqual(visibleRootCheckouts.map(\.kind), [.linkedWorktree])
        let capability = SelectedGitArtifactCapability(
            workspaceID: UUID(),
            workspaceDirectoryPath: workspace.path,
            gitDataRoot: root,
            creatorTabID: tabID,
            sessionID: UUID(),
            boundCheckouts: [],
            visibleRootCheckouts: visibleRootCheckouts,
            canonicalWorkspaceRootPaths: [repo.path]
        )
        return Fixture(
            repositoryFixture: repositoryFixture,
            store: store,
            capability: capability,
            published: published
        )
    }
}

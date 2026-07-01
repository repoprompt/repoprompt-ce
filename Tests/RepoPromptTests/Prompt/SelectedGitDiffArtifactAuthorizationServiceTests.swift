@testable import RepoPrompt
import XCTest

final class SelectedGitDiffArtifactAuthorizationServiceTests: XCTestCase {
    private struct Fixture {
        let workspace: URL
        let gitDataRoot: URL
        let repoRoot: URL
        let store: WorkspaceFileContextStore
        let capability: SelectedGitArtifactCapability
        let mapURL: URL
        let allPatchURL: URL
        let listedPatchURL: URL
        let unlistedPatchURL: URL
        let manifestURL: URL
    }

    private var temporaryRoots = FileSystemTemporaryRoots()

    override func tearDownWithError() throws {
        temporaryRoots.removeAll()
        try super.tearDownWithError()
    }

    func testCompareIntentFreezesMechanicalHeadCompatibilityRule() {
        XCTAssertEqual(ReviewGitCompareIntent(base: nil), .uncommittedHEAD)
        XCTAssertEqual(ReviewGitCompareIntent(base: ""), .uncommittedHEAD)
        XCTAssertEqual(ReviewGitCompareIntent(base: "  hEaD\n"), .uncommittedHEAD)
        XCTAssertEqual(
            ReviewGitCompareIntent(base: "  origin/main  "),
            .uncommittedMergeBase(symbolicBase: "origin/main")
        )
    }

    @MainActor
    func testFrozenReviewWorkspaceMismatchDoesNotSubstituteActiveWorkspace() {
        let activeWorkspace = WorkspaceModel(
            id: UUID(),
            name: "Active",
            repoPaths: ["/active/repository"]
        )

        let mismatched = PromptViewModel.workspaceForFrozenPromptGitReviewContext(
            requestedWorkspaceID: UUID(),
            workspaces: [activeWorkspace],
            activeWorkspace: activeWorkspace
        )
        let implicit = PromptViewModel.workspaceForFrozenPromptGitReviewContext(
            requestedWorkspaceID: nil,
            workspaces: [activeWorkspace],
            activeWorkspace: activeWorkspace
        )

        XCTAssertNil(mismatched)
        XCTAssertEqual(implicit?.id, activeWorkspace.id)
    }

    func testAuthorizesMapAllPatchAndManifestListedPatchInSelectionOrder() async throws {
        let fixture = try await makeUnboundFixture()
        let result = await authorize(
            fixture,
            selectedPaths: [
                fixture.mapURL.path,
                fixture.allPatchURL.path,
                fixture.listedPatchURL.path,
                fixture.allPatchURL.path
            ]
        )

        XCTAssertEqual(
            result.entries.map(\.file.standardizedFullPath),
            [fixture.mapURL.path, fixture.allPatchURL.path, fixture.listedPatchURL.path]
        )
        XCTAssertEqual(result.entries.first?.loadedContent, "ordinary map context")
        XCTAssertEqual(result.entries.first?.mode, .fullFile)
        XCTAssertEqual(
            result.entries.map(\.role),
            [.ordinary, .authorizedGitDiffArtifact, .authorizedGitDiffArtifact]
        )
        XCTAssertEqual(
            result.consumedSelectionPaths,
            Set([fixture.mapURL.path, fixture.allPatchURL.path, fixture.listedPatchURL.path])
        )
        XCTAssertEqual(result.dispositions, [
            .authorized(path: fixture.mapURL.path, kind: .map, readability: .readable),
            .authorized(path: fixture.allPatchURL.path, kind: .patch, readability: .readable),
            .authorized(path: fixture.listedPatchURL.path, kind: .patch, readability: .readable)
        ])
        XCTAssertEqual(
            result.displayAliasesByAbsolutePath[fixture.mapURL.path],
            "_git_data/repos/repo-storage/2026-06-19/1851/MAP.txt"
        )
        XCTAssertEqual(
            result.displayAliasesByAbsolutePath[fixture.allPatchURL.path],
            "_git_data/repos/repo-storage/2026-06-19/1851/diff/all.patch"
        )
    }

    func testExactPathAuthorizationMatchesSelectedPathAuthorization() async throws {
        let fixture = try await makeUnboundFixture()
        let paths = [
            fixture.mapURL.path,
            fixture.allPatchURL.path,
            fixture.listedPatchURL.path
        ]
        let selected = await authorize(fixture, selectedPaths: paths)
        let exact = await SelectedGitDiffArtifactAuthorizationService()
            .authorizeExactPaths(
                ExactSelectedGitArtifactAuthorizationRequest(
                    exactAbsolutePaths: paths,
                    capability: fixture.capability,
                    store: fixture.store
                )
            )

        XCTAssertEqual(
            exact.entries.map(\.file.standardizedFullPath),
            selected.entries.map(\.file.standardizedFullPath)
        )
        XCTAssertEqual(exact.dispositions, selected.dispositions)
        XCTAssertEqual(
            Set(exact.dispositionsByAbsolutePath.keys),
            Set(paths)
        )
    }

    func testRejectsUnlistedPatchAndNonArtifactWithoutRawFallback() async throws {
        let fixture = try await makeUnboundFixture()
        let result = await authorize(
            fixture,
            selectedPaths: [fixture.unlistedPatchURL.path, fixture.manifestURL.path]
        )

        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertEqual(result.dispositions, [
            .rejected(path: fixture.unlistedPatchURL.path, reason: .unlistedPatch),
            .rejected(path: fixture.manifestURL.path, reason: .unsupportedArtifactPath)
        ])
        XCTAssertEqual(
            result.consumedSelectionPaths,
            Set([fixture.unlistedPatchURL.path, fixture.manifestURL.path])
        )
        XCTAssertEqual(result.rejectedDisplayDiagnostics.count, 2)
        XCTAssertTrue(result.rejectedDisplayDiagnostics.allSatisfy {
            $0.hasPrefix("_git_data/")
        })
        XCTAssertTrue(result.rejectedDisplayDiagnostics.contains {
            $0.contains("patch is not listed")
        })
    }

    func testRejectsMismatchedTabRepoKeyAndSnapshotIdentity() async throws {
        let wrongTab = try await makeUnboundFixture(tabMatches: false)
        let wrongTabResult = await authorize(wrongTab, selectedPaths: [wrongTab.allPatchURL.path])
        XCTAssertEqual(
            wrongTabResult.dispositions,
            [.rejected(path: wrongTab.allPatchURL.path, reason: .tabMismatch)]
        )

        let wrongRepoKey = try await makeUnboundFixture(manifestRepoKey: "different-repo")
        let wrongRepoResult = await authorize(wrongRepoKey, selectedPaths: [wrongRepoKey.allPatchURL.path])
        XCTAssertEqual(
            wrongRepoResult.dispositions,
            [.rejected(path: wrongRepoKey.allPatchURL.path, reason: .manifestIdentityMismatch)]
        )

        let wrongSnapshot = try await makeUnboundFixture(manifestSnapshotID: "different/snapshot")
        let wrongSnapshotResult = await authorize(
            wrongSnapshot,
            selectedPaths: [wrongSnapshot.allPatchURL.path]
        )
        XCTAssertEqual(
            wrongSnapshotResult.dispositions,
            [.rejected(path: wrongSnapshot.allPatchURL.path, reason: .manifestIdentityMismatch)]
        )
    }

    func testLegacyNilTabIsAllowedOnlyForUnboundCanonicalCheckout() async throws {
        let unbound = try await makeUnboundFixture(omitManifestTab: true)
        let unboundResult = await authorize(unbound, selectedPaths: [unbound.allPatchURL.path])
        XCTAssertEqual(
            unboundResult.dispositions,
            [.authorized(path: unbound.allPatchURL.path, kind: .patch, readability: .readable)]
        )

        let bound = try await makeBoundFixture(omitManifestTab: true)
        let boundResult = await authorize(bound, selectedPaths: [bound.allPatchURL.path])
        XCTAssertEqual(
            boundResult.dispositions,
            [.rejected(path: bound.allPatchURL.path, reason: .legacyTabNotAllowed)]
        )
    }

    func testVisibleLinkedWorktreeRequiresExactLiveRootIdentityAndTabProvenance() async throws {
        let fixture = try await makeVisibleLinkedFixture()
        XCTAssertTrue(fixture.capability.boundCheckouts.isEmpty)
        XCTAssertEqual(fixture.capability.visibleRootCheckouts.count, 1)
        XCTAssertEqual(fixture.capability.visibleRootCheckouts.first?.kind, .linkedWorktree)

        let authorized = await authorize(fixture, selectedPaths: [fixture.allPatchURL.path])
        XCTAssertEqual(
            authorized.dispositions,
            [.authorized(path: fixture.allPatchURL.path, kind: .patch, readability: .readable)]
        )

        let legacy = try await makeVisibleLinkedFixture(omitManifestTab: true)
        let legacyResult = await authorize(legacy, selectedPaths: [legacy.allPatchURL.path])
        XCTAssertEqual(
            legacyResult.dispositions,
            [.rejected(path: legacy.allPatchURL.path, reason: .legacyTabNotAllowed)]
        )

        let consumer = makeDelegationConsumer(workspaceID: fixture.capability.workspaceID)
        let delegated = makeDelegatedCapability(
            fixture,
            consumer: consumer,
            selectedPaths: [fixture.allPatchURL.path]
        )
        XCTAssertEqual(delegated.visibleRootCheckouts, fixture.capability.visibleRootCheckouts)
        let delegatedResult = await authorize(
            fixture,
            selectedPaths: [fixture.allPatchURL.path],
            capability: delegated,
            delegationConsumer: consumer
        )
        XCTAssertEqual(
            delegatedResult.dispositions,
            [.authorized(path: fixture.allPatchURL.path, kind: .patch, readability: .readable)]
        )
    }

    func testVisibleLinkedWorktreeRejectsSiblingIdentityAndReloadedRootGeneration() async throws {
        let fixture = try await makeVisibleLinkedFixture()
        let layout = try XCTUnwrap(
            GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: fixture.repoRoot)
        )
        let siblingRoot = fixture.workspace.appendingPathComponent("SiblingWorktree", isDirectory: true)
        let siblingGitDir = layout.commonDir.appendingPathComponent("worktrees/sibling", isDirectory: true)
        try FileManager.default.createDirectory(at: siblingGitDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: siblingRoot, withIntermediateDirectories: true)
        try FileSystemTestSupport.write(
            "gitdir: \(siblingGitDir.path)\n",
            to: siblingRoot.appendingPathComponent(".git")
        )
        try writeMinimalLinkedWorktreeGitMetadata(commonGitDir: layout.commonDir, gitDir: siblingGitDir)
        _ = try await fixture.store.loadRoot(path: siblingRoot.path, kind: .primaryWorkspace)
        let siblingIdentities = await FrozenVisibleGitCheckoutResolver(vcsService: VCSService()).resolve(
            workspaceRootPaths: [siblingRoot.path],
            bindings: [],
            store: fixture.store
        )
        let siblingCapability = SelectedGitArtifactCapability(
            workspaceID: fixture.capability.workspaceID,
            workspaceDirectoryPath: fixture.workspace.path,
            gitDataRoot: fixture.capability.gitDataRoot,
            creatorTabID: fixture.capability.creatorTabID,
            sessionID: fixture.capability.sessionID,
            boundCheckouts: [],
            visibleRootCheckouts: siblingIdentities,
            canonicalWorkspaceRootPaths: [siblingRoot.path]
        )
        let siblingResult = await authorize(
            fixture,
            selectedPaths: [fixture.allPatchURL.path],
            capability: siblingCapability
        )
        XCTAssertEqual(
            siblingResult.dispositions,
            [.rejected(path: fixture.allPatchURL.path, reason: .checkoutProvenanceMismatch)]
        )

        let lifetimeService = SelectedGitDiffArtifactAuthorizationService()
        let wasCurrent = await lifetimeService.visibleRootCheckoutsAreCurrent(
            capability: fixture.capability,
            store: fixture.store
        )
        XCTAssertTrue(wasCurrent)
        let frozenRoot = try XCTUnwrap(fixture.capability.visibleRootCheckouts.first?.workspaceRoot)
        await fixture.store.unloadRoot(id: frozenRoot.id)
        _ = try await fixture.store.loadRoot(path: fixture.repoRoot.path, kind: .primaryWorkspace)
        let remainsCurrent = await lifetimeService.visibleRootCheckoutsAreCurrent(
            capability: fixture.capability,
            store: fixture.store
        )
        XCTAssertFalse(remainsCurrent)
        let staleResult = await authorize(fixture, selectedPaths: [fixture.allPatchURL.path])
        XCTAssertEqual(
            staleResult.dispositions,
            [.rejected(path: fixture.allPatchURL.path, reason: .checkoutProvenanceMismatch)]
        )
    }

    func testBoundWorktreeRequiresMatchingManifestLayoutRepositoryAndWorktreeIdentity() async throws {
        let fixture = try await makeBoundFixture()
        let authorized = await authorize(fixture, selectedPaths: [fixture.allPatchURL.path])
        XCTAssertEqual(
            authorized.dispositions,
            [.authorized(path: fixture.allPatchURL.path, kind: .patch, readability: .readable)]
        )

        let badBinding = FrozenBoundCheckoutIdentity(
            logicalRootPath: fixture.repoRoot.path,
            logicalRootName: "Repo",
            physicalWorktreeRootPath: fixture.repoRoot.path,
            repositoryID: "wrong-repository",
            worktreeID: fixture.capability.boundCheckouts[0].worktreeID
        )
        let mismatchedCapability = SelectedGitArtifactCapability(
            workspaceID: fixture.capability.workspaceID,
            workspaceDirectoryPath: fixture.workspace.path,
            gitDataRoot: fixture.capability.gitDataRoot,
            creatorTabID: fixture.capability.creatorTabID,
            sessionID: fixture.capability.sessionID,
            boundCheckouts: [badBinding],
            canonicalWorkspaceRootPaths: []
        )
        let mismatched = await SelectedGitDiffArtifactAuthorizationService().authorize(
            SelectedGitArtifactAuthorizationRequest(
                physicalSelection: StoredSelection(
                    selectedPaths: [fixture.allPatchURL.path],
                    codemapAutoEnabled: false
                ),
                capability: mismatchedCapability,
                store: fixture.store
            )
        )
        XCTAssertEqual(
            mismatched.dispositions,
            [.rejected(path: fixture.allPatchURL.path, reason: .checkoutProvenanceMismatch)]
        )
    }

    func testDelegatedCanonicalAuthorizationRequiresExactLaunchSelectionAndConsumer() async throws {
        let fixture = try await makeUnboundFixture()
        let consumer = makeDelegationConsumer(workspaceID: fixture.capability.workspaceID)
        let delegated = makeDelegatedCapability(
            fixture,
            consumer: consumer,
            selectedPaths: [fixture.mapURL.path, fixture.allPatchURL.path]
        )

        let authorized = await authorize(
            fixture,
            selectedPaths: [fixture.mapURL.path, fixture.allPatchURL.path],
            capability: delegated,
            delegationConsumer: consumer
        )
        XCTAssertEqual(authorized.dispositions, [
            .authorized(path: fixture.mapURL.path, kind: .map, readability: .readable),
            .authorized(path: fixture.allPatchURL.path, kind: .patch, readability: .readable)
        ])

        let unselected = await authorize(
            fixture,
            selectedPaths: [fixture.listedPatchURL.path],
            capability: delegated,
            delegationConsumer: consumer
        )
        XCTAssertEqual(
            unselected.dispositions,
            [.rejected(path: fixture.listedPatchURL.path, reason: .notInDelegatedSelection)]
        )

        let wrongRun = SelectedGitArtifactDelegationConsumer(
            workspaceID: consumer.workspaceID,
            tabID: consumer.tabID,
            agentSessionID: consumer.agentSessionID,
            agentRunID: UUID(),
            boundCheckouts: consumer.boundCheckouts
        )
        let mismatchedConsumer = await authorize(
            fixture,
            selectedPaths: [fixture.allPatchURL.path],
            capability: delegated,
            delegationConsumer: wrongRun
        )
        XCTAssertEqual(
            mismatchedConsumer.dispositions,
            [.rejected(path: fixture.allPatchURL.path, reason: .delegationConsumerMismatch)]
        )

        let wrongTab = SelectedGitArtifactDelegationConsumer(
            workspaceID: consumer.workspaceID,
            tabID: UUID(),
            agentSessionID: consumer.agentSessionID,
            agentRunID: consumer.agentRunID,
            boundCheckouts: consumer.boundCheckouts
        )
        let wrongTabResult = await authorize(
            fixture,
            selectedPaths: [fixture.allPatchURL.path],
            capability: delegated,
            delegationConsumer: wrongTab
        )
        XCTAssertEqual(
            wrongTabResult.dispositions,
            [.rejected(path: fixture.allPatchURL.path, reason: .delegationConsumerMismatch)]
        )

        let wrongSession = SelectedGitArtifactDelegationConsumer(
            workspaceID: consumer.workspaceID,
            tabID: consumer.tabID,
            agentSessionID: UUID(),
            agentRunID: consumer.agentRunID,
            boundCheckouts: consumer.boundCheckouts
        )
        let wrongSessionResult = await authorize(
            fixture,
            selectedPaths: [fixture.allPatchURL.path],
            capability: delegated,
            delegationConsumer: wrongSession
        )
        XCTAssertEqual(
            wrongSessionResult.dispositions,
            [.rejected(path: fixture.allPatchURL.path, reason: .delegationConsumerMismatch)]
        )

        let wrongWorkspace = SelectedGitArtifactDelegationConsumer(
            workspaceID: UUID(),
            tabID: consumer.tabID,
            agentSessionID: consumer.agentSessionID,
            agentRunID: consumer.agentRunID,
            boundCheckouts: consumer.boundCheckouts
        )
        let wrongWorkspaceResult = await authorize(
            fixture,
            selectedPaths: [fixture.allPatchURL.path],
            capability: delegated,
            delegationConsumer: wrongWorkspace
        )
        XCTAssertEqual(
            wrongWorkspaceResult.dispositions,
            [.rejected(path: fixture.allPatchURL.path, reason: .delegationWorkspaceMismatch)]
        )

        let wrongSource = makeDelegatedCapability(
            fixture,
            consumer: consumer,
            selectedPaths: [fixture.allPatchURL.path],
            sourceTabID: UUID()
        )
        let wrongSourceResult = await authorize(
            fixture,
            selectedPaths: [fixture.allPatchURL.path],
            capability: wrongSource,
            delegationConsumer: consumer
        )
        XCTAssertEqual(
            wrongSourceResult.dispositions,
            [.rejected(path: fixture.allPatchURL.path, reason: .delegationConsumerMismatch)]
        )

        let directWithDelegatedConsumer = await authorize(
            fixture,
            selectedPaths: [fixture.allPatchURL.path],
            capability: fixture.capability,
            delegationConsumer: consumer
        )
        XCTAssertEqual(
            directWithDelegatedConsumer.dispositions,
            [.rejected(path: fixture.allPatchURL.path, reason: .delegationConsumerMismatch)]
        )
    }

    func testDelegatedCanonicalLegacyManifestFailsClosedWithoutChangingDirectCompatibility() async throws {
        let fixture = try await makeUnboundFixture(omitManifestTab: true)
        let direct = await authorize(fixture, selectedPaths: [fixture.allPatchURL.path])
        XCTAssertEqual(
            direct.dispositions,
            [.authorized(path: fixture.allPatchURL.path, kind: .patch, readability: .readable)]
        )

        let consumer = makeDelegationConsumer(workspaceID: fixture.capability.workspaceID)
        let delegated = makeDelegatedCapability(
            fixture,
            consumer: consumer,
            selectedPaths: [fixture.allPatchURL.path]
        )
        let delegatedResult = await authorize(
            fixture,
            selectedPaths: [fixture.allPatchURL.path],
            capability: delegated,
            delegationConsumer: consumer
        )
        XCTAssertEqual(
            delegatedResult.dispositions,
            [.rejected(path: fixture.allPatchURL.path, reason: .legacyArtifactNotDelegable)]
        )
    }

    func testDelegatedLinkedWorktreeAllowsDifferentTargetBindingAndRejectsConsumerDrift() async throws {
        let fixture = try await makeBoundFixture()
        let consumer = makeDelegationConsumer(
            workspaceID: fixture.capability.workspaceID,
            boundCheckouts: []
        )
        let delegated = makeDelegatedCapability(
            fixture,
            consumer: consumer,
            selectedPaths: [fixture.allPatchURL.path]
        )
        let authorized = await authorize(
            fixture,
            selectedPaths: [fixture.allPatchURL.path],
            capability: delegated,
            delegationConsumer: consumer
        )
        XCTAssertEqual(
            authorized.dispositions,
            [.authorized(path: fixture.allPatchURL.path, kind: .patch, readability: .readable)]
        )
        XCTAssertFalse(fixture.capability.boundCheckouts.isEmpty)
        XCTAssertTrue(consumer.boundCheckouts.isEmpty)
        let provenance = try XCTUnwrap(
            authorized.checkoutProvenanceByAbsolutePath[fixture.allPatchURL.path]
        )
        XCTAssertEqual(provenance.repositoryID, fixture.capability.boundCheckouts[0].repositoryID)
        XCTAssertEqual(provenance.worktreeID, fixture.capability.boundCheckouts[0].worktreeID)
        XCTAssertEqual(provenance.kind, .linkedWorktree)

        let siblingBinding = FrozenBoundCheckoutIdentity(
            logicalRootPath: fixture.capability.boundCheckouts[0].logicalRootPath,
            logicalRootName: fixture.capability.boundCheckouts[0].logicalRootName,
            physicalWorktreeRootPath: fixture.capability.boundCheckouts[0].physicalWorktreeRootPath,
            repositoryID: fixture.capability.boundCheckouts[0].repositoryID,
            worktreeID: "sibling-worktree"
        )
        let siblingConsumer = SelectedGitArtifactDelegationConsumer(
            workspaceID: consumer.workspaceID,
            tabID: consumer.tabID,
            agentSessionID: consumer.agentSessionID,
            agentRunID: consumer.agentRunID,
            boundCheckouts: [siblingBinding]
        )
        let rejected = await authorize(
            fixture,
            selectedPaths: [fixture.allPatchURL.path],
            capability: delegated,
            delegationConsumer: siblingConsumer
        )
        XCTAssertEqual(
            rejected.dispositions,
            [.rejected(path: fixture.allPatchURL.path, reason: .delegationBindingMismatch)]
        )
    }

    func testLinkedWorktreeCannotUseUnboundRouteByOmittingManifestMetadata() async throws {
        let fixture = try await makeBoundFixture(
            omitWorktreeMetadata: true,
            includeBinding: false
        )
        let result = await authorize(fixture, selectedPaths: [fixture.allPatchURL.path])

        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertEqual(
            result.dispositions,
            [.rejected(path: fixture.allPatchURL.path, reason: .checkoutProvenanceMismatch)]
        )
    }

    func testWrongWorkspaceRootTraversalAndStaleCapabilityFailClosed() async throws {
        let fixture = try await makeUnboundFixture()
        let otherWorkspace = try temporaryRoots.makeRoot(suiteName: "SelectedGitArtifactOtherWorkspace")
        let otherPatch = otherWorkspace
            .appendingPathComponent("_git_data/repos/repo-storage/2026-06-19/1851/diff/all.patch")
        try FileSystemTestSupport.write("other", to: otherPatch)
        _ = try await fixture.store.loadRoot(
            path: otherWorkspace.appendingPathComponent("_git_data").path,
            kind: .workspaceGitData
        )

        let wrongWorkspace = await authorize(fixture, selectedPaths: [otherPatch.path])
        XCTAssertTrue(wrongWorkspace.entries.isEmpty)
        XCTAssertTrue(wrongWorkspace.dispositions.isEmpty)
        XCTAssertTrue(wrongWorkspace.consumedSelectionPaths.isEmpty)

        let traversal = fixture.gitDataRoot
            .appendingPathComponent("repos/repo-storage/2026-06-19/1851/diff/../diff/all.patch")
            .path
        let traversalResult = await authorize(fixture, selectedPaths: [traversal])
        XCTAssertEqual(
            traversalResult.dispositions,
            [.rejected(path: traversal, reason: .invalidAbsolutePath)]
        )
        XCTAssertEqual(traversalResult.consumedSelectionPaths, [traversal])

        let loadedRoots = await fixture.store.roots()
        let gitDataRecord = try XCTUnwrap(loadedRoots.first { $0.kind == .workspaceGitData })
        await fixture.store.unloadRoot(id: gitDataRecord.id)
        let stale = await authorize(fixture, selectedPaths: [fixture.allPatchURL.path])
        XCTAssertEqual(
            stale.dispositions,
            [.rejected(path: fixture.allPatchURL.path, reason: .capabilityRootUnavailable)]
        )
    }

    func testEmptyPatchRemainsDistinctAndDeletedPatchIsUnreadable() async throws {
        let empty = try await makeUnboundFixture(allPatchContent: "")
        let emptyResult = await authorize(empty, selectedPaths: [empty.allPatchURL.path])
        XCTAssertEqual(emptyResult.entries.count, 1)
        XCTAssertEqual(
            emptyResult.dispositions,
            [.authorized(path: empty.allPatchURL.path, kind: .patch, readability: .empty)]
        )

        let deleted = try await makeUnboundFixture()
        try FileManager.default.removeItem(at: deleted.allPatchURL)
        let deletedResult = await authorize(deleted, selectedPaths: [deleted.allPatchURL.path])
        XCTAssertTrue(deletedResult.entries.isEmpty)
        XCTAssertEqual(
            deletedResult.dispositions,
            [.rejected(path: deleted.allPatchURL.path, reason: .contentUnreadable)]
        )
    }

    private func authorize(
        _ fixture: Fixture,
        selectedPaths: [String],
        capability: SelectedGitArtifactCapability? = nil,
        delegationConsumer: SelectedGitArtifactDelegationConsumer? = nil
    ) async -> SelectedGitArtifactAuthorizationResult {
        await SelectedGitDiffArtifactAuthorizationService().authorize(
            SelectedGitArtifactAuthorizationRequest(
                physicalSelection: StoredSelection(
                    selectedPaths: selectedPaths,
                    codemapAutoEnabled: false
                ),
                capability: capability ?? fixture.capability,
                store: fixture.store,
                delegationConsumer: delegationConsumer
            )
        )
    }

    private func makeDelegationConsumer(
        workspaceID: UUID,
        boundCheckouts: [FrozenBoundCheckoutIdentity] = []
    ) -> SelectedGitArtifactDelegationConsumer {
        SelectedGitArtifactDelegationConsumer(
            workspaceID: workspaceID,
            tabID: UUID(),
            agentSessionID: UUID(),
            agentRunID: UUID(),
            boundCheckouts: boundCheckouts
        )
    }

    private func makeDelegatedCapability(
        _ fixture: Fixture,
        consumer: SelectedGitArtifactDelegationConsumer,
        selectedPaths: Set<String>,
        sourceTabID: UUID? = nil
    ) -> SelectedGitArtifactCapability {
        SelectedGitArtifactCapability(
            workspaceID: fixture.capability.workspaceID,
            workspaceDirectoryPath: fixture.capability.workspaceDirectoryPath,
            gitDataRoot: fixture.capability.gitDataRoot,
            creatorTabID: fixture.capability.creatorTabID,
            sessionID: fixture.capability.sessionID,
            boundCheckouts: fixture.capability.boundCheckouts,
            visibleRootCheckouts: fixture.capability.visibleRootCheckouts,
            canonicalWorkspaceRootPaths: fixture.capability.canonicalWorkspaceRootPaths,
            access: .delegated(
                SelectedGitArtifactDelegation(
                    delegationID: UUID(),
                    sourceWorkspaceID: fixture.capability.workspaceID,
                    sourceTabID: sourceTabID ?? fixture.capability.creatorTabID,
                    sourceAgentSessionID: fixture.capability.sessionID,
                    sourceAgentRunID: UUID(),
                    targetWorkspaceID: consumer.workspaceID,
                    targetTabID: consumer.tabID,
                    targetAgentSessionID: consumer.agentSessionID,
                    targetAgentRunID: consumer.agentRunID,
                    exactSelectedArtifactPaths: selectedPaths,
                    targetBoundCheckouts: consumer.boundCheckouts
                )
            )
        )
    }

    private func makeUnboundFixture(
        tabMatches: Bool = true,
        omitManifestTab: Bool = false,
        manifestRepoKey: String? = nil,
        manifestSnapshotID: String? = nil,
        allPatchContent: String = "all patch"
    ) async throws -> Fixture {
        let workspace = try temporaryRoots.makeRoot(suiteName: "SelectedGitArtifactUnbound")
        let repoRoot = workspace.appendingPathComponent("Repo", isDirectory: true)
        try FileManager.default.createDirectory(
            at: repoRoot.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        let creatorTabID = UUID()
        let snapshotID = "2026-06-19/1851"
        let repoKey = "repo-storage"
        let manifest = makeManifest(
            snapshotID: manifestSnapshotID ?? snapshotID,
            repoKey: manifestRepoKey ?? repoKey,
            repoRoot: repoRoot.path,
            tabID: omitManifestTab ? nil : (tabMatches ? creatorTabID : UUID())
        )
        return try await makeFixture(
            workspace: workspace,
            repoRoot: repoRoot,
            repoKey: repoKey,
            snapshotID: snapshotID,
            manifest: manifest,
            creatorTabID: creatorTabID,
            boundCheckouts: [],
            canonicalWorkspaceRootPaths: [repoRoot.path],
            allPatchContent: allPatchContent
        )
    }

    private func writeMinimalLinkedWorktreeGitMetadata(commonGitDir: URL, gitDir: URL) throws {
        try FileSystemTestSupport.write("../..\n", to: gitDir.appendingPathComponent("commondir"))
        try FileSystemTestSupport.write("ref: refs/heads/main\n", to: gitDir.appendingPathComponent("HEAD"))
        try FileSystemTestSupport.write("[core]\n\trepositoryformatversion = 0\n", to: commonGitDir.appendingPathComponent("config"))
        try FileManager.default.createDirectory(
            at: commonGitDir.appendingPathComponent("objects", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    private func makeBoundFixture(
        omitManifestTab: Bool = false,
        omitWorktreeMetadata: Bool = false,
        includeBinding: Bool = true
    ) async throws -> Fixture {
        let workspace = try temporaryRoots.makeRoot(suiteName: "SelectedGitArtifactBound")
        let mainRoot = workspace.appendingPathComponent("Main", isDirectory: true)
        let commonGitDir = mainRoot.appendingPathComponent(".git", isDirectory: true)
        let gitDir = commonGitDir.appendingPathComponent("worktrees/review", isDirectory: true)
        let worktreeRoot = workspace.appendingPathComponent("ReviewWorktree", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktreeRoot, withIntermediateDirectories: true)
        try FileSystemTestSupport.write(
            "gitdir: \(gitDir.path)\n",
            to: worktreeRoot.appendingPathComponent(".git")
        )
        try writeMinimalLinkedWorktreeGitMetadata(commonGitDir: commonGitDir, gitDir: gitDir)

        let layout = try XCTUnwrap(
            GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: worktreeRoot)
        )
        let repositoryIdentity = GitWorktreeIdentity.repositoryIdentity(
            commonGitDir: layout.commonDir,
            mainWorktreeRoot: layout.knownMainWorktreeRoot
        )
        let worktreeID = GitWorktreeIdentity.worktreeID(
            repositoryID: repositoryIdentity.repositoryID,
            gitDir: layout.gitDir,
            isMain: false,
            path: layout.workTreeRoot
        )
        let binding = FrozenBoundCheckoutIdentity(
            logicalRootPath: mainRoot.path,
            logicalRootName: "Main",
            physicalWorktreeRootPath: worktreeRoot.path,
            repositoryID: repositoryIdentity.repositoryID,
            worktreeID: worktreeID
        )
        let creatorTabID = UUID()
        let snapshotID = "2026-06-19/1851"
        let repoKey = "repo-storage"
        let manifest = makeManifest(
            snapshotID: snapshotID,
            repoKey: repoKey,
            repoRoot: worktreeRoot.path,
            isWorktree: omitWorktreeMetadata ? nil : true,
            worktreeRoot: omitWorktreeMetadata ? nil : worktreeRoot.path,
            mainWorktreeRoot: omitWorktreeMetadata ? nil : mainRoot.path,
            commonGitDir: omitWorktreeMetadata ? nil : commonGitDir.path,
            tabID: omitManifestTab ? nil : creatorTabID
        )
        return try await makeFixture(
            workspace: workspace,
            repoRoot: worktreeRoot,
            repoKey: repoKey,
            snapshotID: snapshotID,
            manifest: manifest,
            creatorTabID: creatorTabID,
            sessionID: UUID(),
            boundCheckouts: includeBinding ? [binding] : [],
            canonicalWorkspaceRootPaths: includeBinding ? [] : [worktreeRoot.path],
            allPatchContent: "bound patch"
        )
    }

    private func makeVisibleLinkedFixture(
        omitManifestTab: Bool = false
    ) async throws -> Fixture {
        let workspace = try temporaryRoots.makeRoot(suiteName: "SelectedGitArtifactVisibleLinked")
        let mainRoot = workspace.appendingPathComponent("Main", isDirectory: true)
        let commonGitDir = mainRoot.appendingPathComponent(".git", isDirectory: true)
        let gitDir = commonGitDir.appendingPathComponent("worktrees/visible", isDirectory: true)
        let worktreeRoot = workspace.appendingPathComponent("VisibleWorktree", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktreeRoot, withIntermediateDirectories: true)
        try FileSystemTestSupport.write(
            "gitdir: \(gitDir.path)\n",
            to: worktreeRoot.appendingPathComponent(".git")
        )
        try writeMinimalLinkedWorktreeGitMetadata(commonGitDir: commonGitDir, gitDir: gitDir)

        let creatorTabID = UUID()
        let snapshotID = "2026-06-20/0900"
        let repoKey = "visible-linked"
        let manifest = makeManifest(
            snapshotID: snapshotID,
            repoKey: repoKey,
            repoRoot: worktreeRoot.path,
            isWorktree: true,
            worktreeRoot: worktreeRoot.path,
            mainWorktreeRoot: mainRoot.path,
            commonGitDir: commonGitDir.path,
            tabID: omitManifestTab ? nil : creatorTabID
        )
        return try await makeFixture(
            workspace: workspace,
            repoRoot: worktreeRoot,
            repoKey: repoKey,
            snapshotID: snapshotID,
            manifest: manifest,
            creatorTabID: creatorTabID,
            boundCheckouts: [],
            visibleWorkspaceRootPaths: [worktreeRoot.path],
            canonicalWorkspaceRootPaths: [worktreeRoot.path],
            allPatchContent: "visible linked patch"
        )
    }

    private func makeFixture(
        workspace: URL,
        repoRoot: URL,
        repoKey: String,
        snapshotID: String,
        manifest: GitDiffSnapshotManifest,
        creatorTabID: UUID,
        sessionID: UUID? = nil,
        boundCheckouts: [FrozenBoundCheckoutIdentity],
        visibleWorkspaceRootPaths: [String] = [],
        canonicalWorkspaceRootPaths: [String],
        allPatchContent: String
    ) async throws -> Fixture {
        let gitDataRoot = workspace.appendingPathComponent("_git_data", isDirectory: true)
        let snapshotRoot = gitDataRoot
            .appendingPathComponent("repos", isDirectory: true)
            .appendingPathComponent(repoKey, isDirectory: true)
            .appendingPathComponent(snapshotID, isDirectory: true)
        let mapURL = snapshotRoot.appendingPathComponent("MAP.txt")
        let allPatchURL = snapshotRoot.appendingPathComponent("diff/all.patch")
        let listedPatchURL = snapshotRoot.appendingPathComponent("diff/per-file/listed.patch")
        let unlistedPatchURL = snapshotRoot.appendingPathComponent("diff/per-file/unlisted.patch")
        let manifestURL = snapshotRoot.appendingPathComponent("manifest.json")

        try FileSystemTestSupport.write("ordinary map context", to: mapURL)
        try FileSystemTestSupport.write(allPatchContent, to: allPatchURL)
        try FileSystemTestSupport.write("listed patch", to: listedPatchURL)
        try FileSystemTestSupport.write("unlisted patch", to: unlistedPatchURL)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData = try encoder.encode(manifest)
        try FileSystemTestSupport.write(
            XCTUnwrap(String(data: manifestData, encoding: .utf8)),
            to: manifestURL
        )

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: gitDataRoot.path, kind: .workspaceGitData)
        let gitDataRootRefValue = await store.exactRootRef(
            path: gitDataRoot.path,
            kind: .workspaceGitData
        )
        let gitDataRootRef = try XCTUnwrap(gitDataRootRefValue)
        for visibleRootPath in visibleWorkspaceRootPaths {
            _ = try await store.loadRoot(path: visibleRootPath, kind: .primaryWorkspace)
        }
        let visibleRootCheckouts = await FrozenVisibleGitCheckoutResolver(
            vcsService: VCSService()
        ).resolve(
            workspaceRootPaths: visibleWorkspaceRootPaths,
            bindings: [],
            store: store
        )
        let capability = SelectedGitArtifactCapability(
            workspaceID: UUID(),
            workspaceDirectoryPath: workspace.path,
            gitDataRoot: gitDataRootRef,
            creatorTabID: creatorTabID,
            sessionID: sessionID,
            boundCheckouts: boundCheckouts,
            visibleRootCheckouts: visibleRootCheckouts,
            canonicalWorkspaceRootPaths: canonicalWorkspaceRootPaths
        )
        return Fixture(
            workspace: workspace,
            gitDataRoot: gitDataRoot,
            repoRoot: repoRoot,
            store: store,
            capability: capability,
            mapURL: mapURL,
            allPatchURL: allPatchURL,
            listedPatchURL: listedPatchURL,
            unlistedPatchURL: unlistedPatchURL,
            manifestURL: manifestURL
        )
    }

    private func makeManifest(
        snapshotID: String,
        repoKey: String,
        repoRoot: String,
        isWorktree: Bool? = nil,
        worktreeRoot: String? = nil,
        mainWorktreeRoot: String? = nil,
        commonGitDir: String? = nil,
        tabID: UUID?
    ) -> GitDiffSnapshotManifest {
        GitDiffSnapshotManifest(
            snapshotID: snapshotID,
            generatedAt: Date(timeIntervalSince1970: 1),
            mode: .standard,
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
                    patchPath: "diff/per-file/listed.patch",
                    bytes: 12,
                    lines: 1,
                    hunks: nil
                )
            ],
            repoKey: repoKey,
            repoRoot: repoRoot,
            isWorktree: isWorktree,
            worktreeName: isWorktree == true ? "review" : nil,
            worktreeRoot: worktreeRoot,
            mainWorktreeRoot: mainWorktreeRoot,
            commonGitDir: commonGitDir,
            tabID: tabID
        )
    }
}

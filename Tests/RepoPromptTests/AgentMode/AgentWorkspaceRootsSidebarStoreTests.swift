import Combine
import Foundation
@testable import RepoPrompt
import XCTest

@MainActor
final class AgentWorkspaceRootsSidebarStoreTests: XCTestCase {
    func testRowsMarkPrimaryAndMovementForMultipleRoots() {
        let rootA = makeProjection(name: "A", path: "/tmp/A")
        let rootB = makeProjection(name: "B", path: "/tmp/B")
        let rootC = makeProjection(name: "C", path: "/tmp/C")

        let rows = AgentWorkspaceRootsSidebarStore.rows(from: [rootA, rootB, rootC])

        XCTAssertEqual(rows.map(\.id), [rootA.id, rootB.id, rootC.id])
        XCTAssertEqual(rows.map(\.name), ["A", "B", "C"])
        XCTAssertEqual(rows.map(\.fullPath), ["/tmp/A", "/tmp/B", "/tmp/C"])
        XCTAssertEqual(rows.map(\.isPrimary), [true, false, false])
        XCTAssertEqual(rows.filter(\.isPrimary).map(\.id), [rootA.id])
        XCTAssertEqual(rows.map(\.canMoveUp), [false, true, true])
        XCTAssertEqual(rows.map(\.canMoveDown), [true, true, false])
        XCTAssertEqual(rows.map(\.standardizedFullPath), [rootA.standardizedFullPath, rootB.standardizedFullPath, rootC.standardizedFullPath])
        XCTAssertEqual(rows.map(\.worktree), [nil, nil, nil])
        XCTAssertEqual(rows.map(\.gitContext), [nil, nil, nil])
    }

    func testRowsDoNotMarkSingleRootAsPrimaryOrMovable() {
        let root = makeProjection(name: "Only", path: "/tmp/Only")

        let rows = AgentWorkspaceRootsSidebarStore.rows(from: [root])

        XCTAssertEqual(rows, [
            AgentWorkspaceRootRow(
                id: root.id,
                name: "Only",
                fullPath: "/tmp/Only",
                standardizedFullPath: root.standardizedFullPath,
                isPrimary: false,
                canMoveUp: false,
                canMoveDown: false
            )
        ])
        XCTAssertTrue(rows.filter(\.isPrimary).isEmpty)
    }

    func testRowsDoNotMarkPrimaryWhenWorkspaceHasNoRoots() {
        let rows = AgentWorkspaceRootsSidebarStore.rows(from: [])

        XCTAssertTrue(rows.isEmpty)
        XCTAssertEqual(rows.filter(\.isPrimary).count, 0)
    }

    func testRowsMarkExactlyFirstRootAsPrimaryAcrossMultiRootCounts() {
        for rootCount in 2 ... 5 {
            let projections = (0 ..< rootCount).map { index in
                makeProjection(name: "Root\(index)", path: "/tmp/Root\(index)")
            }

            let rows = AgentWorkspaceRootsSidebarStore.rows(from: projections)

            XCTAssertEqual(rows.filter(\.isPrimary).map(\.id), [projections[0].id])
            XCTAssertEqual(rows.dropFirst().filter(\.isPrimary).count, 0)
        }
    }

    func testRowsAttachGitContextByStandardizedRootPathWithoutChangingOrder() {
        let rootA = makeProjection(name: "A", path: "/tmp/A")
        let rootB = makeProjection(name: "B", path: "/tmp/B")
        let contextB = makeGitContext(repository: "Repo", worktree: "B", branch: "feature/b")

        let rows = AgentWorkspaceRootsSidebarStore.rows(from: [rootA, rootB]) { path in
            path == rootB.standardizedFullPath ? contextB : nil
        }

        XCTAssertEqual(rows.map(\.id), [rootA.id, rootB.id])
        XCTAssertEqual(rows.map(\.isPrimary), [true, false])
        XCTAssertNil(rows[0].gitContext)
        XCTAssertEqual(rows[1].gitContext, contextB)
        XCTAssertEqual(rows[1].gitContext?.breadcrumbText, "Repo / B / feature/b")
        XCTAssertTrue(rows[1].gitContext?.isMain == true)
    }

    func testWorkspaceManagerChangesDoNotRefreshRootRows() async {
        let rootA = makeProjection(name: "A", path: "/tmp/A")
        let rootB = makeProjection(name: "B", path: "/tmp/B")
        var projections = [rootA]
        let rootChanges = PassthroughSubject<Void, Never>()
        let manager = makeWorkspaceManager()
        let store = AgentWorkspaceRootsSidebarStore(
            rootProjections: { projections },
            rootChanges: rootChanges.eraseToAnyPublisher(),
            workspaceManager: manager,
            windowID: -1
        )
        XCTAssertEqual(store.rootRows.map(\.id), [rootA.id])

        projections = [rootB]
        let metadataWorkspace = WorkspaceModel(name: "Manager Metadata Only", repoPaths: [])
        manager.workspaces = [metadataWorkspace]
        manager.activeWorkspace = metadataWorkspace
        await waitUntil { store.workspaceLabel.hasPrefix("Manager Metadata") }

        XCTAssertEqual(store.rootRows.map(\.id), [rootA.id])

        rootChanges.send(())
        await waitUntil { store.rootRows.map(\.id) == [rootB.id] }

        XCTAssertEqual(store.rootRows.map(\.id), [rootB.id])
    }

    // MARK: - Codemap progress (per-root scanning indicator)

    func testWorkspaceRootCodemapActivityMapsAcceptedProgressEvents() {
        let rootEpoch = WorkspaceCodemapRootEpoch(rootID: UUID(), rootLifetimeID: UUID())

        let determinate = WorkspaceRootCodemapActivity(event: WorkspaceCodemapRootProjectionProgressEvent(
            rootEpoch: rootEpoch,
            progress: makeProjectionProgress(
                rootEpoch: rootEpoch,
                phase: .publishingProjectionSegment,
                processed: 42,
                total: 120
            ),
            isSealed: false
        ))
        XCTAssertEqual(determinate, .scanning(processed: 42, total: 120))

        let indeterminate = WorkspaceRootCodemapActivity(event: WorkspaceCodemapRootProjectionProgressEvent(
            rootEpoch: rootEpoch,
            progress: makeProjectionProgress(
                rootEpoch: rootEpoch,
                phase: .publishingProjectionSegment,
                processed: 7,
                total: nil
            ),
            isSealed: false
        ))
        XCTAssertEqual(indeterminate, .scanning(processed: 7, total: nil))

        let sealed = WorkspaceRootCodemapActivity(event: WorkspaceCodemapRootProjectionProgressEvent(
            rootEpoch: rootEpoch,
            progress: makeProjectionProgress(
                rootEpoch: rootEpoch,
                phase: .publishingProjectionSegment,
                processed: 120,
                total: 120
            ),
            isSealed: true
        ))
        XCTAssertEqual(sealed, .ready(processed: 120))

        let completePhase = WorkspaceRootCodemapActivity(event: WorkspaceCodemapRootProjectionProgressEvent(
            rootEpoch: rootEpoch,
            progress: makeProjectionProgress(
                rootEpoch: rootEpoch,
                phase: .complete,
                processed: 120,
                total: 120
            ),
            isSealed: false
        ))
        XCTAssertEqual(completePhase, .ready(processed: 120))
    }

    func testCodemapProgressStatesJoinActivityByRootUUIDOnlyAndDescribeStates() {
        let rootA = makeProjection(name: "A", path: "/tmp/A")
        let rootB = makeProjection(name: "B", path: "/tmp/B")
        // Activity for a hidden physical worktree session root: distinct UUID,
        // must never cross-wire onto a visible logical root row.
        let hiddenPhysicalRootID = UUID()

        let states = AgentWorkspaceRootsSidebarStore.codemapProgressStates(
            for: [rootA, rootB],
            activityByRootID: [
                rootA.id: .scanning(processed: 42, total: 120),
                hiddenPhysicalRootID: .ready(processed: 9)
            ],
            globallyDisabled: false
        )

        XCTAssertEqual(states, [rootA.id: .scanning(processed: 42, total: 120)])
        XCTAssertNil(states[rootB.id], "Idle roots render nothing")
        XCTAssertNil(states[hiddenPhysicalRootID])

        XCTAssertEqual(
            AgentRootCodemapProgressDisplayState.scanning(processed: 42, total: 120).displayText,
            "Codemaps 42/120"
        )
        XCTAssertEqual(
            AgentRootCodemapProgressDisplayState.scanning(processed: 7, total: nil).displayText,
            "Codemaps scanning…"
        )
        XCTAssertEqual(AgentRootCodemapProgressDisplayState.ready.displayText, "Codemaps ready")
        XCTAssertEqual(
            AgentRootCodemapProgressDisplayState.disabledGlobally.displayText,
            "Codemaps disabled globally"
        )
        XCTAssertEqual(
            AgentRootCodemapProgressDisplayState.scanning(processed: 42, total: 120).accessibilityText,
            "Codemaps scanning, 42 of 120 files processed"
        )
    }

    func testCodemapProgressStatesGlobalDisableOverridesActivity() {
        let rootA = makeProjection(name: "A", path: "/tmp/A")
        let rootB = makeProjection(name: "B", path: "/tmp/B")

        let states = AgentWorkspaceRootsSidebarStore.codemapProgressStates(
            for: [rootA, rootB],
            activityByRootID: [
                rootA.id: .scanning(processed: 1, total: 10)
            ],
            globallyDisabled: true
        )

        XCTAssertEqual(states, [
            rootA.id: .disabledGlobally,
            rootB.id: .disabledGlobally
        ])
    }

    func testCodemapProgressInitialGlobalDisableSuppressesActivitySynchronously() {
        let rootA = makeProjection(name: "A", path: "/tmp/A")
        let manager = makeWorkspaceManager()
        let store = AgentWorkspaceRootsSidebarStore(
            rootProjections: { [rootA] },
            rootChanges: Empty<Void, Never>().eraseToAnyPublisher(),
            codemapActivityLookup: { [rootA.id: .scanning(processed: 1, total: 10)] },
            codemapsGloballyDisabled: CurrentValueSubject<Bool, Never>(true).eraseToAnyPublisher(),
            initialCodemapsGloballyDisabled: true,
            codemapActivityThrottleMilliseconds: 1,
            workspaceManager: manager,
            windowID: -1
        )

        XCTAssertEqual(store.codemapProgressByRootID, [rootA.id: .disabledGlobally])
    }

    func testCodemapActivityUpdatesPreserveRowIdentityAndGlobalDisableRoundTrips() async {
        let rootA = makeProjection(name: "A", path: "/tmp/A")
        let rootB = makeProjection(name: "B", path: "/tmp/B")
        var activity: [UUID: WorkspaceRootCodemapActivity] = [:]
        let activityChanges = PassthroughSubject<Void, Never>()
        let globallyDisabled = CurrentValueSubject<Bool, Never>(false)
        let manager = makeWorkspaceManager()
        let store = AgentWorkspaceRootsSidebarStore(
            rootProjections: { [rootA, rootB] },
            rootChanges: Empty<Void, Never>().eraseToAnyPublisher(),
            codemapActivityLookup: { activity },
            codemapActivityChanges: activityChanges.eraseToAnyPublisher(),
            codemapsGloballyDisabled: globallyDisabled.eraseToAnyPublisher(),
            codemapActivityThrottleMilliseconds: 1,
            workspaceManager: manager,
            windowID: -1
        )
        let rowsBefore = store.rootRows
        XCTAssertEqual(rowsBefore.map(\.id), [rootA.id, rootB.id])
        XCTAssertEqual(store.codemapProgressByRootID, [:])

        activity[rootA.id] = .scanning(processed: 3, total: nil)
        activityChanges.send(())
        await waitUntil { store.codemapProgressByRootID == [rootA.id: .scanning(processed: 3, total: nil)] }

        activity[rootA.id] = .scanning(processed: 42, total: 120)
        activity[rootB.id] = .ready(processed: 12)
        activityChanges.send(())
        await waitUntil {
            store.codemapProgressByRootID == [
                rootA.id: .scanning(processed: 42, total: 120),
                rootB.id: .ready
            ]
        }

        // Progress ticks must not rebuild rows or disturb identity/ordering.
        XCTAssertEqual(store.rootRows, rowsBefore)

        globallyDisabled.send(true)
        await waitUntil {
            store.codemapProgressByRootID == [
                rootA.id: .disabledGlobally,
                rootB.id: .disabledGlobally
            ]
        }

        globallyDisabled.send(false)
        await waitUntil {
            store.codemapProgressByRootID == [
                rootA.id: .scanning(processed: 42, total: 120),
                rootB.id: .ready
            ]
        }
        XCTAssertEqual(store.rootRows, rowsBefore)
    }

    private func makeProjectionProgress(
        rootEpoch: WorkspaceCodemapRootEpoch,
        phase: WorkspaceCodemapProjectionPreloadPhase,
        processed: UInt64,
        total: UInt64?
    ) -> WorkspaceCodemapProjectionProgress {
        let completion = total.map { total in
            WorkspaceCodemapProjectionCatalogCompletion(
                token: WorkspaceCodemapProjectionCatalogToken(
                    rootEpoch: rootEpoch,
                    topologyGeneration: 1,
                    appliedIndexGeneration: 1,
                    catalogGeneration: 1,
                    ingressGeneration: 1,
                    projectionInvalidationGeneration: 0
                ),
                finalCursor: nil,
                supportedCandidateCount: total
            )
        }
        return WorkspaceCodemapProjectionProgress(
            phase: phase,
            counts: WorkspaceCodemapProjectionCounts(
                supportedCandidateCount: total ?? processed,
                processedCandidateCount: processed,
                contributedCount: processed,
                emptyCount: 0,
                terminalArtifactCount: 0,
                terminalExcludedCount: 0,
                transientCount: 0
            ),
            catalogPageCount: 1,
            catalogPathByteCount: 1,
            publishedSegmentCount: 1,
            publishedSegmentByteCount: 1,
            catalogCompletion: completion
        )
    }

    // MARK: - Root context actions

    func testRootContextActionCopiesRawBranchInsteadOfDisplayText() {
        let context = makeGitContext(
            repository: "Repo",
            worktree: "repo",
            branch: "feature/full-branch-name",
            head: "1234567890abcdef1234567890abcdef12345678"
        )

        XCTAssertEqual(
            AgentWorkspaceRootContextValues.rootCheckout(for: context),
            .branch("feature/full-branch-name")
        )
    }

    func testRootContextActionCopiesFullRawHeadInsteadOfDecoratedShortHead() {
        let fullHead = "abcdef1234567890abcdef1234567890abcdef12"
        let context = makeGitContext(
            repository: "Repo",
            worktree: "repo",
            branch: nil,
            head: fullHead,
            isDetached: true
        )

        XCTAssertEqual(context.branchDisplayText, "detached @ abcdef1")
        XCTAssertEqual(
            AgentWorkspaceRootContextValues.rootCheckout(for: context),
            .head(fullHead)
        )
    }

    func testRootContextActionOmitsCheckoutWithoutRawBranchOrHead() {
        let context = makeGitContext(
            repository: "Repo",
            worktree: "repo",
            branch: nil,
            head: nil
        )

        XCTAssertNil(AgentWorkspaceRootContextValues.rootCheckout(for: context))
    }

    func testWorktreeContextActionsUsePersistedRawValues() {
        let indicator = AgentWorktreeIndicator.make(
            summary: makeSummary(
                worktreeName: "  wt-raw  ",
                branch: "  feature/raw  ",
                worktreeRootPath: "  /tmp/Repo-wt  "
            ),
            resolvedIdentity: WorktreeVisualIdentity(colorHex: "#123456"),
            isAvailable: true
        )

        XCTAssertEqual(AgentWorkspaceRootContextValues.worktreePath(for: indicator), "/tmp/Repo-wt")
        XCTAssertEqual(AgentWorkspaceRootContextValues.worktreeName(for: indicator), "wt-raw")
        XCTAssertEqual(AgentWorkspaceRootContextValues.worktreeBranch(for: indicator), "feature/raw")
    }

    func testUnavailableWorktreeContextActionPreservesTrimmedRecoveryPath() {
        let indicator = AgentWorktreeIndicator.make(
            summary: makeSummary(worktreeRootPath: "  /tmp/Repo-missing  \n"),
            resolvedIdentity: WorktreeVisualIdentity(colorHex: "#123456"),
            isAvailable: false
        )

        XCTAssertEqual(AgentWorkspaceRootContextValues.worktreePath(for: indicator), "/tmp/Repo-missing")
    }

    func testUnavailableWorktreeContextActionOmitsBlankRecoveryPath() {
        let indicator = AgentWorktreeIndicator.make(
            summary: makeSummary(worktreeRootPath: "  \n\t  "),
            resolvedIdentity: WorktreeVisualIdentity(colorHex: "#123456"),
            isAvailable: false
        )

        XCTAssertNil(AgentWorkspaceRootContextValues.worktreePath(for: indicator))
    }

    // MARK: - Worktree indicators (Item 10)

    func testWithWorktreeAttachesIndicatorWithoutMutatingOtherFields() {
        let base = AgentWorkspaceRootRow(
            id: UUID(),
            name: "Repo",
            fullPath: "/tmp/Repo",
            isPrimary: true,
            canMoveUp: false,
            canMoveDown: true
        )
        let indicator = makeIndicator()

        let enriched = base.withWorktree(indicator)

        XCTAssertNil(base.worktree)
        XCTAssertEqual(enriched.worktree, indicator)
        XCTAssertEqual(enriched.id, base.id)
        XCTAssertEqual(enriched.name, base.name)
        XCTAssertEqual(enriched.fullPath, base.fullPath)
        XCTAssertEqual(enriched.standardizedFullPath, base.standardizedFullPath)
        XCTAssertEqual(enriched.isPrimary, base.isPrimary)
        XCTAssertEqual(enriched.canMoveUp, base.canMoveUp)
        XCTAssertEqual(enriched.canMoveDown, base.canMoveDown)
        XCTAssertEqual(enriched.gitContext, base.gitContext)
    }

    func testWithWorktreePreservesGitContext() {
        let context = makeGitContext(repository: "Repo", worktree: "repo", branch: "main")
        let base = AgentWorkspaceRootRow(
            id: UUID(),
            name: "Repo",
            fullPath: "/tmp/Repo",
            isPrimary: true,
            canMoveUp: false,
            canMoveDown: true,
            gitContext: context
        )
        let indicator = makeIndicator()

        let enriched = base.withWorktree(indicator)

        XCTAssertEqual(enriched.gitContext, context)
        XCTAssertEqual(enriched.worktree, indicator)
    }

    func testIndicatorMakePrefersBindingColorAndLabel() {
        let summary = makeSummary(visualLabel: "feature-x", visualColorHex: "#1a2b3c")
        let identity = WorktreeVisualIdentity(
            label: "global-label",
            colorHex: "#FFFFFF",
            iconName: "leaf.fill",
            markerStyle: .ring
        )

        let indicator = AgentWorktreeIndicator.make(
            summary: summary,
            resolvedIdentity: identity,
            isAvailable: true
        )

        XCTAssertEqual(indicator.label, "feature-x")
        // Binding color wins and is normalized to uppercase.
        XCTAssertEqual(indicator.colorHex, "#1A2B3C")
        // Icon/marker are sourced from the resolved global identity.
        XCTAssertEqual(indicator.iconName, "leaf.fill")
        XCTAssertEqual(indicator.markerStyle, .ring)
        XCTAssertTrue(indicator.isAvailable)
        XCTAssertEqual(indicator.capsuleText, "WT feature-x")
        XCTAssertTrue(indicator.allowsCompactCapsule)
        XCTAssertNil(indicator.missingWorktreePath)
    }

    func testIndicatorMakeFallsBackToResolvedIdentityForMissingOrInvalidFields() {
        let summary = makeSummary(
            visualLabel: nil,
            visualColorHex: "not-a-color",
            worktreeName: nil,
            branch: "rp/agent/abc-feature"
        )
        let identity = WorktreeVisualIdentity(
            label: nil,
            colorHex: "#0A0B0C",
            iconName: "circle.fill",
            markerStyle: .dot
        )

        let indicator = AgentWorktreeIndicator.make(
            summary: summary,
            resolvedIdentity: identity,
            isAvailable: true
        )

        // Invalid binding color falls back to the resolved identity color.
        XCTAssertEqual(indicator.colorHex, "#0A0B0C")
        // Label falls through to the branch when no labels are set.
        XCTAssertEqual(indicator.label, "rp/agent/abc-feature")
    }

    func testIndicatorLabelFallsBackToWorktreeIDTail() {
        let summary = makeSummary(
            visualLabel: nil,
            visualColorHex: nil,
            worktreeName: nil,
            branch: nil
        )
        let identity = WorktreeVisualIdentity(colorHex: "#101112")

        let indicator = AgentWorktreeIndicator.make(
            summary: summary,
            resolvedIdentity: identity,
            isAvailable: true
        )

        XCTAssertEqual(indicator.label, "89abcdef")
    }

    func testIndicatorUnavailableSurfacesStaleStateInTooltipAndAccessibility() {
        let summary = makeSummary(
            visualLabel: "feature-x",
            visualColorHex: "#112233",
            worktreeRootPath: "  /tmp/Repo-missing  \n"
        )
        let identity = WorktreeVisualIdentity(colorHex: "#112233")

        let indicator = AgentWorktreeIndicator.make(
            summary: summary,
            resolvedIdentity: identity,
            isAvailable: false
        )

        XCTAssertFalse(indicator.isAvailable)
        XCTAssertEqual(indicator.capsuleText, "WT feature-x")
        XCTAssertFalse(indicator.allowsCompactCapsule)
        XCTAssertEqual(indicator.missingWorktreePath, "/tmp/Repo-missing")
        XCTAssertTrue(indicator.tooltipText.contains("unavailable"))
        XCTAssertTrue(indicator.tooltipText.contains("feature-x"))
        XCTAssertTrue(indicator.accessibilityText.contains("unavailable"))
    }

    func testUnavailableIndicatorOmitsBlankRecoveryPath() {
        let indicator = AgentWorktreeIndicator.make(
            summary: makeSummary(worktreeRootPath: "  \n\t  "),
            resolvedIdentity: WorktreeVisualIdentity(colorHex: "#112233"),
            isAvailable: false
        )

        XCTAssertFalse(indicator.allowsCompactCapsule)
        XCTAssertNil(indicator.missingWorktreePath)
    }

    private func makeSummary(
        visualLabel: String? = "feature-x",
        visualColorHex: String? = "#123456",
        worktreeName: String? = "wt-name",
        branch: String? = "main",
        worktreeRootPath: String = "/tmp/Repo-wt"
    ) -> AgentSessionWorktreeBindingSummary {
        AgentSessionWorktreeBindingSummary(
            id: "binding-1",
            repositoryID: "gitrepo_abc",
            repoKey: "repo",
            logicalRootPath: "/tmp/Repo",
            logicalRootName: "Repo",
            worktreeID: "wt_0123456789abcdef",
            worktreeRootPath: worktreeRootPath,
            worktreeName: worktreeName,
            branch: branch,
            visualLabel: visualLabel,
            visualColorHex: visualColorHex,
            boundAt: Date()
        )
    }

    private func makeGitContext(
        repository: String,
        worktree: String,
        branch: String?,
        head: String? = "1234567890abcdef",
        isDetached: Bool = false,
        isMain: Bool = true
    ) -> GitWorktreeContextSummary {
        GitWorktreeContextSummary(
            repositoryID: "gitrepo-test",
            repoKey: "repo-test",
            repositoryDisplayName: repository,
            worktreeID: "wt-test",
            worktreePath: "/tmp/\(worktree)",
            worktreeName: worktree,
            isMain: isMain,
            branch: branch,
            head: head,
            isDetached: isDetached
        )
    }

    private func makeIndicator() -> AgentWorktreeIndicator {
        AgentWorktreeIndicator.make(
            summary: makeSummary(),
            resolvedIdentity: WorktreeVisualIdentity(colorHex: "#123456"),
            isAvailable: true
        )
    }

    private func makeWorkspaceManager() -> WorkspaceManagerViewModel {
        let fileManager = WorkspaceFilesViewModel()
        let keyManager = KeyManager(
            secureService: SecureKeysService(secureStorage: TestSecureStorageBackend())
        )
        let apiSettings = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )
        let prompt = PromptViewModel(
            fileManager: fileManager,
            apiSettingsViewModel: apiSettings,
            windowID: -1,
            settingsManager: WindowSettingsManager(windowID: -1)
        )
        return WorkspaceManagerViewModel(
            fileManager: fileManager,
            promptViewModel: prompt,
            performInitialWorkspaceActivation: false
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for condition")
    }

    private func makeProjection(
        id: UUID = UUID(),
        name: String,
        path: String,
        isSystemRoot: Bool = false
    ) -> WorkspaceRootShellProjection {
        WorkspaceRootShellProjection(
            id: id,
            name: name,
            fullPath: path,
            standardizedFullPath: URL(fileURLWithPath: path).standardizedFileURL.path,
            isSystemRoot: isSystemRoot
        )
    }
}

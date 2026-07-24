import Combine
import Foundation
@testable import RepoPromptApp
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

    func testRowsMapCompactCodemapProgressAndUnavailableState() {
        let rootA = makeProjection(name: "A", path: "/tmp/A")
        let rootB = makeProjection(name: "B", path: "/tmp/B")
        let snapshots = [
            rootA.id: WorkspaceCodemapRootStatusSnapshot(
                rootEpoch: WorkspaceCodemapRootEpoch(rootID: rootA.id, rootLifetimeID: UUID()),
                state: .generating,
                processedCandidateCount: 7,
                totalCandidateCount: 12
            ),
            rootB.id: WorkspaceCodemapRootStatusSnapshot(
                rootEpoch: WorkspaceCodemapRootEpoch(rootID: rootB.id, rootLifetimeID: UUID()),
                state: .unavailable,
                processedCandidateCount: 0,
                totalCandidateCount: nil
            )
        ]

        let rows = AgentWorkspaceRootsSidebarStore.rows(
            from: [rootA, rootB],
            codemapStatusLookup: { snapshots[$0] }
        )

        XCTAssertEqual(rows[0].codemap.state, .mapping)
        XCTAssertEqual(rows[0].codemap.percentageText, "58%")
        XCTAssertTrue(rows[0].codemap.canToggle)
        XCTAssertEqual(rows[1].codemap.state, .unavailable)
        XCTAssertNil(rows[1].codemap.progressFraction)
        XCTAssertFalse(rows[1].codemap.canToggle)

        let localOnly = AgentWorkspaceCodemapPresentation.make(WorkspaceCodemapRootStatusSnapshot(
            rootEpoch: WorkspaceCodemapRootEpoch(rootID: rootA.id, rootLifetimeID: UUID()),
            state: .generating,
            processedCandidateCount: 0,
            locallyResolvedCandidateCountThroughRoot: 17,
            totalCandidateCount: 64
        ))
        XCTAssertEqual(localOnly.processedCandidateCount, 0)
        XCTAssertEqual(localOnly.displayProcessedCandidateCount, 17)
        XCTAssertEqual(localOnly.percentageText, "26%")
        XCTAssertEqual(localOnly.progressFraction ?? 0, 17.0 / 64.0, accuracy: 0.000_001)
        XCTAssertTrue(localOnly.tooltip.contains("processed for mapping"))

        let belowOnePercent = AgentWorkspaceCodemapPresentation.make(WorkspaceCodemapRootStatusSnapshot(
            rootEpoch: WorkspaceCodemapRootEpoch(rootID: rootA.id, rootLifetimeID: UUID()),
            state: .generating,
            processedCandidateCount: 1,
            totalCandidateCount: 1000
        ))
        XCTAssertEqual(belowOnePercent.progressFraction ?? 0, 0.001, accuracy: 0.000_001)
        XCTAssertEqual(belowOnePercent.percentageText, "<1%")
        XCTAssertEqual(belowOnePercent.statusText, "Mapping <1%")

        let acceptedAndLocal = AgentWorkspaceCodemapPresentation.make(WorkspaceCodemapRootStatusSnapshot(
            rootEpoch: WorkspaceCodemapRootEpoch(rootID: rootA.id, rootLifetimeID: UUID()),
            state: .generating,
            processedCandidateCount: 12,
            locallyResolvedCandidateCountThroughRoot: 17,
            totalCandidateCount: 64
        ))
        XCTAssertEqual(acceptedAndLocal.displayProcessedCandidateCount, 17)

        let locallyResolvedAll = AgentWorkspaceCodemapPresentation.make(WorkspaceCodemapRootStatusSnapshot(
            rootEpoch: WorkspaceCodemapRootEpoch(rootID: rootA.id, rootLifetimeID: UUID()),
            state: .generating,
            processedCandidateCount: 0,
            locallyResolvedCandidateCountThroughRoot: 64,
            totalCandidateCount: 64
        ))
        XCTAssertEqual(locallyResolvedAll.progressFraction, 0.99)
        XCTAssertEqual(locallyResolvedAll.percentageText, "99%")

        let nearlyComplete = AgentWorkspaceCodemapPresentation.make(WorkspaceCodemapRootStatusSnapshot(
            rootEpoch: WorkspaceCodemapRootEpoch(rootID: rootA.id, rootLifetimeID: UUID()),
            state: .generating,
            processedCandidateCount: 199,
            totalCandidateCount: 200
        ))
        XCTAssertEqual(nearlyComplete.percentageText, "99%")
        let complete = AgentWorkspaceCodemapPresentation.make(WorkspaceCodemapRootStatusSnapshot(
            rootEpoch: WorkspaceCodemapRootEpoch(rootID: rootA.id, rootLifetimeID: UUID()),
            state: .ready,
            processedCandidateCount: 200,
            totalCandidateCount: 200
        ))
        XCTAssertEqual(complete.percentageText, "100%")
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

    func testCodemapStatusNotificationsCoalesceRootRowResnapshots() async {
        let root = makeProjection(name: "A", path: "/tmp/A")
        let manager = makeWorkspaceManager()
        let codemapChanges = PassthroughSubject<Void, Never>()
        var lookupCount = 0
        let snapshot = WorkspaceCodemapRootStatusSnapshot(
            rootEpoch: WorkspaceCodemapRootEpoch(rootID: root.id, rootLifetimeID: UUID()),
            state: .generating,
            processedCandidateCount: 1,
            totalCandidateCount: 2
        )
        let store = AgentWorkspaceRootsSidebarStore(
            rootProjections: { [root] },
            rootChanges: Empty<Void, Never>().eraseToAnyPublisher(),
            codemapStatusLookup: { _ in
                lookupCount += 1
                return snapshot
            },
            codemapStatusChanges: codemapChanges.eraseToAnyPublisher(),
            workspaceManager: manager,
            windowID: -1
        )
        XCTAssertEqual(lookupCount, 1)

        codemapChanges.send(())
        codemapChanges.send(())
        await waitUntil { lookupCount >= 2 }

        XCTAssertEqual(lookupCount, 2)
        XCTAssertEqual(store.rootRows.first?.codemap.displayProcessedCandidateCount, 1)
    }

    func testCodemapToggleResnapshotsAuthoritativeStateBeforeClearingPending() async {
        let root = makeProjection(name: "A", path: "/tmp/A")
        let manager = makeWorkspaceManager()
        var snapshot = WorkspaceCodemapRootStatusSnapshot(
            rootEpoch: WorkspaceCodemapRootEpoch(rootID: root.id, rootLifetimeID: UUID()),
            state: .paused,
            processedCandidateCount: 0,
            totalCandidateCount: nil
        )
        var actions: [(UUID, Bool)] = []
        let store = AgentWorkspaceRootsSidebarStore(
            rootProjections: { [root] },
            rootChanges: Empty<Void, Never>().eraseToAnyPublisher(),
            codemapStatusLookup: { _ in snapshot },
            setCodemapSuspended: { rootID, suspended in
                actions.append((rootID, suspended))
                snapshot = WorkspaceCodemapRootStatusSnapshot(
                    rootEpoch: snapshot.rootEpoch,
                    state: suspended ? .paused : .generating,
                    processedCandidateCount: 0,
                    totalCandidateCount: nil
                )
            },
            workspaceManager: manager,
            windowID: -1
        )

        await store.toggleCodemapGeneration(rowID: root.id)
        XCTAssertEqual(actions.map(\.0), [root.id])
        XCTAssertEqual(actions.map(\.1), [false])
        XCTAssertFalse(store.rootRows[0].codemap.isPaused)

        await store.toggleCodemapGeneration(rowID: root.id)

        XCTAssertEqual(actions.map(\.1), [false, true])
        XCTAssertTrue(store.rootRows[0].codemap.isPaused)
        XCTAssertTrue(store.codemapActionRootIDs.isEmpty)
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
        XCTAssertEqual(enriched.codemap, base.codemap)
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

    func testWorktreeDisplayLabelHumanizesAppManagedAgentNames() {
        let cases: [(raw: String, expected: String)] = [
            ("rp-agent-1a98df1a-agent", "1a98df1a"),
            ("rp-agent-1a98df1a-fix-login", "fix-login"),
            ("rp-agent-1a98df1a-fix-login-abcdef12", "fix-login"),
            ("rp-agent-1a98df1a-fix-login-abcdef12-2", "fix-login"),
            ("rp/agent/1a98df1a-fix-login", "fix-login"),
            ("team-feature-worktree", "team-feature-worktree")
        ]

        for testCase in cases {
            XCTAssertEqual(
                GitWorktreeDisplayLabelHumanizer.displayLabel(for: testCase.raw),
                testCase.expected,
                testCase.raw
            )
        }
    }

    func testIndicatorHumanizesMachineFallbackWhileKeepingRawNameAccessible() {
        let indicator = AgentWorktreeIndicator.make(
            summary: makeSummary(
                visualLabel: nil,
                visualColorHex: nil,
                worktreeName: "rp-agent-1a98df1a-agent",
                branch: nil
            ),
            resolvedIdentity: WorktreeVisualIdentity(colorHex: "#112233"),
            isAvailable: true
        )

        XCTAssertEqual(indicator.label, "1a98df1a")
        XCTAssertEqual(indicator.rawLabel, "rp-agent-1a98df1a-agent")
        XCTAssertEqual(indicator.capsuleText, "WT 1a98df1a")
        XCTAssertTrue(indicator.tooltipText.contains("rp-agent-1a98df1a-agent"))
        XCTAssertTrue(indicator.accessibilityText.contains("rp-agent-1a98df1a-agent"))
    }

    func testWorktreeVisualIdentitySeedPrefersMeaningfulSessionNameThenHumanizedWorktreeFallback() {
        XCTAssertEqual(
            GitWorktreeDisplayLabelHumanizer.seededVisualIdentityLabel(
                sessionName: "  Implement login polish for sidebar  ",
                worktreeName: "rp-agent-1a98df1a-agent",
                branch: nil,
                isMain: false
            ),
            "Implement login polish"
        )
        XCTAssertEqual(
            GitWorktreeDisplayLabelHumanizer.seededVisualIdentityLabel(
                sessionName: "New Chat",
                worktreeName: "rp-agent-1a98df1a-fix-login-abcdef12-3",
                branch: nil,
                isMain: false
            ),
            "fix-login"
        )
        XCTAssertEqual(
            GitWorktreeDisplayLabelHumanizer.seededVisualIdentityLabel(
                sessionName: nil,
                worktreeName: nil,
                branch: "rp/agent/1a98df1a-agent",
                isMain: false
            ),
            "1a98df1a"
        )
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

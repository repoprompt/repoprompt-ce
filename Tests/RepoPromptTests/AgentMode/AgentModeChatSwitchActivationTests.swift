import Combine
import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

@MainActor
final class AgentModeChatSwitchActivationTests: XCTestCase {
    func testHandoffRebindsComposerAndRejectsStaleSourceSubmitTarget() async throws {
        try await withFixture { fixture in
            let sourceTarget = try XCTUnwrap(fixture.viewModel.ui.composer.props.submitTarget)
            XCTAssertEqual(sourceTarget.tabID, fixture.tabAID)
            let cutoffItemID = try XCTUnwrap(fixture.sessionA.items.last?.id)

            let destinationTabID = try await fixture.viewModel.prepareHandoffToNewTab(
                upToItemID: cutoffItemID,
                destinationAgent: fixture.sessionA.selectedAgent,
                destinationModelRaw: fixture.sessionA.selectedModelRaw,
                destinationReasoningEffortRaw: fixture.sessionA.selectedReasoningEffortRaw
            )

            let destinationSession = try XCTUnwrap(fixture.viewModel.sessions[destinationTabID])
            let destinationSessionID = try XCTUnwrap(destinationSession.activeAgentSessionID)
            XCTAssertEqual(fixture.window.promptManager.activeComposeTabID, destinationTabID)
            XCTAssertEqual(fixture.window.workspaceManager.activeAgentSessionID(forTabID: destinationTabID), destinationSessionID)
            XCTAssertNotEqual(destinationSessionID, fixture.sessionAID)
            XCTAssertEqual(destinationSession.items.map(\.text), fixture.tabATexts)
            XCTAssertTrue(destinationSession.pendingHandoff.hasPayload)
            XCTAssertEqual(destinationSession.pendingHandoff.sourceItemID, cutoffItemID)

            let composerProps = fixture.viewModel.ui.composer.props
            XCTAssertEqual(composerProps.currentTabID, destinationTabID)
            let destinationTarget = try XCTUnwrap(composerProps.submitTarget)
            XCTAssertEqual(destinationTarget.tabID, destinationTabID)
            XCTAssertEqual(destinationTarget.expectedSourceAgentSessionID, destinationSessionID)
            XCTAssertEqual(
                destinationTarget.expectedSourceTabSessionIdentity,
                ObjectIdentifier(destinationSession)
            )

            let staleAttempt = AgentComposerSubmitAttempt(
                id: UUID(),
                target: sourceTarget,
                inputRevision: 0,
                noticeRevision: 0,
                rawDraftSnapshot: "must not reach the source"
            )
            switch fixture.viewModel.claimComposerSubmitAttempt(staleAttempt) {
            case .claimed:
                XCTFail("The source composer target must not survive destination activation")
            case let .rejected(rejection):
                XCTAssertEqual(
                    rejection,
                    .targetRejected(reason: "inactive_composer_tab")
                )
            }
            XCTAssertNil(fixture.sessionA.activeComposerSubmitAttempt)
            XCTAssertEqual(fixture.viewModel.ui.composer.props.currentTabID, destinationTabID)

            let destinationAttempt = try AgentComposerSubmitAttempt(
                id: UUID(),
                target: XCTUnwrap(fixture.viewModel.ui.composer.props.submitTarget),
                inputRevision: 0,
                noticeRevision: 0,
                rawDraftSnapshot: "destination draft"
            )
            let destinationClaim: AgentModeViewModel.AgentComposerSubmitClaim
            switch fixture.viewModel.claimComposerSubmitAttempt(destinationAttempt) {
            case let .claimed(claim):
                destinationClaim = claim
            case let .rejected(rejection):
                return XCTFail("Expected destination composer recovery, got \(rejection)")
            }
            XCTAssertTrue(fixture.viewModel.releaseComposerSubmitClaim(destinationClaim))
            XCTAssertNotNil(fixture.viewModel.ui.composer.props.submitTarget)
        }
    }

    func testTokenMetricsCompletionWhileInitialModelLoadsSupersedesObsoleteGeneration() async throws {
        let fileID = UUID()
        let tabID = UUID()
        let source = AgentContextExportSource(
            tabID: tabID,
            promptText: "Metrics.swift",
            selection: StoredSelection(selectedPaths: ["Sources/Metrics.swift"]),
            selectedMetaPromptIDs: [],
            tabName: "Metrics",
            activeAgentSessionID: nil,
            worktreeBindings: []
        )
        let initialRequest = AgentSelectedFilesModelRequest(
            identity: AgentSelectedFilesModelIdentity(
                exportContextIdentity: source.exportContextIdentity,
                filePathDisplay: .relative,
                codeMapUsage: .none
            ),
            source: source,
            store: WorkspaceFileContextStore(),
            filePathDisplay: .relative,
            codeMapUsage: CodeMapUsage.none,
            entryMetricsSnapshot: nil
        )
        let metricsSnapshot = PromptContextEntryMetricsSnapshot(
            totalSelectedDisplayTokens: 73,
            metrics: [
                PromptContextEntryMetric(
                    fileID: fileID,
                    standardizedFullPath: "/tmp/RepoPromptTests/Sources/Metrics.swift",
                    renderedDisplayPath: "Sources/Metrics.swift",
                    renderMode: .full,
                    displayTokenCount: 73,
                    displayPercentage: 1,
                    includedLineCount: 8
                )
            ]
        )
        func publishedSnapshot(refreshPending: Bool) -> TokenCountingViewModel.PublishedTokenSnapshot {
            TokenCountingViewModel.PublishedTokenSnapshot(
                breakdown: TokenCountingViewModel.TokenBreakdown(
                    total: 73,
                    files: 73,
                    prompt: 0,
                    meta: 0,
                    fileTree: 0,
                    git: 0,
                    other: 0
                ),
                filesContentTokens: 73,
                codeMapTokens: 0,
                entryMetricsSnapshot: metricsSnapshot,
                codeMapUsage: CodeMapUsage.none,
                filePathDisplay: .relative,
                isComplete: true,
                isStale: false,
                refreshPending: refreshPending
            )
        }

        XCTAssertNil(
            AgentSelectedFilesRequestMetricsSnapshotResolver.activeTokenMetricsSnapshot(
                source: source,
                activeComposeTabID: tabID,
                codeMapUsage: .none,
                filePathDisplay: .relative,
                published: publishedSnapshot(refreshPending: true)
            )
        )
        let completedMetrics = try XCTUnwrap(
            AgentSelectedFilesRequestMetricsSnapshotResolver.activeTokenMetricsSnapshot(
                source: source,
                activeComposeTabID: tabID,
                codeMapUsage: .none,
                filePathDisplay: .relative,
                published: publishedSnapshot(refreshPending: false)
            )
        )
        let completionRequest = AgentSelectedFilesModelRequest(
            identity: initialRequest.identity,
            source: source,
            store: initialRequest.store,
            filePathDisplay: .relative,
            codeMapUsage: .none,
            entryMetricsSnapshot: completedMetrics
        )
        let resolver = ActivationTokenMetricsModelResolver(fileID: fileID)
        let coordinator = AgentSelectedFilesModelCoordinator { request in
            await resolver.resolve(request)
        }

        XCTAssertNil(
            refreshSelectedFilesModelAfterTokenMetricsCompletion(
                request: completionRequest,
                coordinator: coordinator
            )
        )
        XCTAssertEqual(coordinator.refreshIfNeeded(initialRequest), .started)
        let didStartInitialLoad = await resolver.waitUntilStartCount(1)
        XCTAssertTrue(didStartInitialLoad)
        XCTAssertEqual(initialRequest.identity, completionRequest.identity)

        XCTAssertNil(
            refreshSelectedFilesModelAfterTokenMetricsCompletion(
                request: initialRequest,
                coordinator: coordinator
            )
        )
        let startCountAfterPendingCompletion = await resolver.startCount()
        XCTAssertEqual(startCountAfterPendingCompletion, 1)

        XCTAssertEqual(
            refreshSelectedFilesModelAfterTokenMetricsCompletion(
                request: completionRequest,
                coordinator: coordinator
            ),
            .started
        )
        let didStartCompletionRefresh = await resolver.waitUntilStartCount(2)
        XCTAssertTrue(didStartCompletionRefresh)
        XCTAssertEqual(coordinator.debugStats.cancellations, 1)
        XCTAssertNil(coordinator.model)
        XCTAssertTrue(coordinator.isLoading)

        await resolver.releaseNext()
        let didReturnObsoleteModel = await resolver.waitUntilCompletionCount(1)
        XCTAssertTrue(didReturnObsoleteModel)
        XCTAssertNil(coordinator.model)
        XCTAssertTrue(coordinator.isLoading)
        XCTAssertEqual(coordinator.debugStats.resolverCompletions, 0)

        await resolver.releaseNext()
        let enrichedMetrics = AgentContextExportRow.Metrics.known(
            tokenCount: 73,
            tokenPercentage: 1,
            lineCount: 8
        )
        let didDisplayEnrichedMetrics = await waitUntilTokenMetricsModel(
            coordinator,
            expectedMetrics: enrichedMetrics
        )
        let startCount = await resolver.startCount()
        XCTAssertTrue(didDisplayEnrichedMetrics)
        XCTAssertEqual(startCount, 2)
        XCTAssertEqual(coordinator.debugStats.refreshRequests, 2)
        XCTAssertEqual(coordinator.debugStats.resolverCompletions, 1)
    }

    func testChatSwitchBlankingHidesInterimSelectionTotalAndResolvedEmptyRendersZero() {
        XCTAssertNil(
            presentedSelectedContextCount(
                authoritativeRowCount: 7,
                isSwitchBlankingRows: true
            )
        )
        XCTAssertNil(
            presentedSelectedContextCount(
                authoritativeRowCount: nil,
                isSwitchBlankingRows: false
            )
        )
        XCTAssertEqual(
            presentedSelectedContextCount(
                authoritativeRowCount: 0,
                isSwitchBlankingRows: false
            ),
            0
        )
    }

    func testToggleComposeShortcutOutsideAgentModeDoesNotArmPresentation() async throws {
        try await withFixture { fixture in
            let drawerStore = fixture.viewModel.ui.contextDrawer
            XCTAssertFalse(drawerStore.isPresented)

            fixture.viewModel.setAgentModeActive(false)
            GlobalKeyboardShortcutsCoordinator.shared.test_toggleComposeInspector(in: fixture.window)
            XCTAssertFalse(drawerStore.isPresented)

            fixture.viewModel.setAgentModeActive(true)
            GlobalKeyboardShortcutsCoordinator.shared.test_toggleComposeInspector(in: fixture.window)
            XCTAssertTrue(drawerStore.isPresented)

            GlobalKeyboardShortcutsCoordinator.shared.test_toggleComposeInspector(in: fixture.window)
            XCTAssertFalse(drawerStore.isPresented)
        }
    }

    func testWarmSwitchPublishesDestinationTranscriptBeforeSwitchReturns() async throws {
        try await withFixture { fixture in
            assertPresentation(
                fixture.viewModel.activeTranscriptPresentation,
                tabID: fixture.tabAID,
                sessionID: fixture.sessionAID,
                session: fixture.sessionA,
                expectedTexts: fixture.tabATexts
            )

            await fixture.window.promptManager.switchComposeTab(fixture.tabBID)

            XCTAssertEqual(fixture.window.promptManager.activeComposeTabID, fixture.tabBID)
            assertPresentation(
                fixture.viewModel.activeTranscriptPresentation,
                tabID: fixture.tabBID,
                sessionID: fixture.sessionBID,
                session: fixture.sessionB,
                expectedTexts: fixture.tabBTexts
            )
            XCTAssertNil(fixture.viewModel.activeSessionLoadInProgressTabID)
        }
    }

    func testWarmSwitchPublishesDestinationTabOnlyWhileSwitchingFlagIsRaised() async throws {
        try await withFixture { fixture in
            var observations: [(tabID: UUID?, isSwitching: Bool)] = []
            let cancellable = fixture.window.promptManager.$activeComposeTabID.sink { tabID in
                observations.append((tabID, fixture.window.promptManager.isSwitchingComposeTab))
            }
            defer { cancellable.cancel() }

            await fixture.window.promptManager.switchComposeTab(fixture.tabBID)

            let destinationObservation = try XCTUnwrap(observations.first { $0.tabID == fixture.tabBID })
            XCTAssertTrue(destinationObservation.isSwitching)
            XCTAssertFalse(fixture.window.promptManager.isSwitchingComposeTab)
        }
    }

    func testBackToBackWarmSwitchesPublishLatestDestination() async throws {
        try await withFixture { fixture in
            await fixture.window.promptManager.switchComposeTab(fixture.tabBID)
            assertPresentation(
                fixture.viewModel.activeTranscriptPresentation,
                tabID: fixture.tabBID,
                sessionID: fixture.sessionBID,
                session: fixture.sessionB,
                expectedTexts: fixture.tabBTexts
            )

            await fixture.window.promptManager.switchComposeTab(fixture.tabAID)

            XCTAssertEqual(fixture.window.promptManager.activeComposeTabID, fixture.tabAID)
            assertPresentation(
                fixture.viewModel.activeTranscriptPresentation,
                tabID: fixture.tabAID,
                sessionID: fixture.sessionAID,
                session: fixture.sessionA,
                expectedTexts: fixture.tabATexts
            )
            XCTAssertNil(fixture.viewModel.activeSessionLoadInProgressTabID)
        }
    }

    func testWarmSwitchNotificationIsWindowScoped() async throws {
        try await withFixture { fixtureA in
            let initialPresentation = fixtureA.viewModel.activeTranscriptPresentation

            try await withFixture { fixtureB in
                XCTAssertEqual(fixtureA.viewModel.activeTranscriptPresentation, initialPresentation)

                await fixtureB.window.promptManager.switchComposeTab(fixtureB.tabBID)

                XCTAssertEqual(fixtureB.window.promptManager.activeComposeTabID, fixtureB.tabBID)
                assertPresentation(
                    fixtureB.viewModel.activeTranscriptPresentation,
                    tabID: fixtureB.tabBID,
                    sessionID: fixtureB.sessionBID,
                    session: fixtureB.sessionB,
                    expectedTexts: fixtureB.tabBTexts
                )
                XCTAssertEqual(fixtureA.window.promptManager.activeComposeTabID, fixtureA.tabAID)
                XCTAssertEqual(fixtureA.viewModel.activeTranscriptPresentation, initialPresentation)
                XCTAssertNil(fixtureA.viewModel.activeSessionLoadInProgressTabID)
            }
        }
    }

    private func waitUntilTokenMetricsModel(
        _ coordinator: AgentSelectedFilesModelCoordinator,
        expectedMetrics: AgentContextExportRow.Metrics
    ) async -> Bool {
        for _ in 0 ..< 500 {
            if coordinator.rowSplit.fileRows.first?.metrics == expectedMetrics, !coordinator.isLoading {
                return true
            }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return coordinator.rowSplit.fileRows.first?.metrics == expectedMetrics && !coordinator.isLoading
    }

    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let fixture = try await makeFixture()
        do {
            try await body(fixture)
        } catch {
            await cleanup(fixture)
            throw error
        }
        await cleanup(fixture)
    }

    private func makeFixture() async throws -> Fixture {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentModeChatSwitchActivationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        await window.workspaceManager.awaitInitialized()

        do {
            let workspace = window.workspaceManager.createWorkspace(
                name: "Agent Mode Chat Switch \(UUID().uuidString.prefix(8))",
                repoPaths: [rootURL.path],
                ephemeral: true
            )
            await window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "agentModeChatSwitchActivationTests"
            )
            let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
            XCTAssertEqual(activeWorkspace.id, workspace.id)

            let tabAID = UUID()
            let tabBID = UUID()
            let sessionAID = UUID()
            let sessionBID = UUID()
            let tabA = ComposeTabState(id: tabAID, name: "A", activeAgentSessionID: sessionAID)
            let tabB = ComposeTabState(id: tabBID, name: "B", activeAgentSessionID: sessionBID)

            let workspaceIndex = try XCTUnwrap(
                window.workspaceManager.workspaces.firstIndex(where: { $0.id == workspace.id })
            )
            window.workspaceManager.workspaces[workspaceIndex].composeTabs = [tabA, tabB]
            window.workspaceManager.workspaces[workspaceIndex].activeComposeTabID = tabAID
            window.promptManager.loadComposeTabsFromWorkspace(
                window.workspaceManager.workspaces[workspaceIndex],
                syncPromptText: true
            )

            let viewModel = window.agentModeViewModel
            let sessionA = viewModel.session(for: tabAID)
            let sessionB = viewModel.session(for: tabBID)
            XCTAssertEqual(sessionA.activeAgentSessionID, sessionAID)
            XCTAssertEqual(sessionB.activeAgentSessionID, sessionBID)
            XCTAssertEqual(window.workspaceManager.activeAgentSessionID(forTabID: tabAID), sessionAID)
            XCTAssertEqual(window.workspaceManager.activeAgentSessionID(forTabID: tabBID), sessionBID)

            let tabATexts = ["A user", "A assistant"]
            let tabBTexts = ["B user", "B assistant"]
            sessionA.hasLoadedPersistedState = true
            sessionA.setItemsSilently(
                [
                    .user(tabATexts[0], sequenceIndex: 0),
                    .assistant(tabATexts[1], sequenceIndex: 1)
                ],
                reason: .testOverride
            )
            viewModel.refreshDerivedTranscriptState(for: sessionA)

            sessionB.hasLoadedPersistedState = true
            sessionB.setItemsSilently(
                [
                    .user(tabBTexts[0], sequenceIndex: 0),
                    .assistant(tabBTexts[1], sequenceIndex: 1)
                ],
                reason: .testOverride
            )
            viewModel.refreshDerivedTranscriptState(for: sessionB)

            viewModel.setAgentModeActive(true)

            return Fixture(
                window: window,
                rootURL: rootURL,
                viewModel: viewModel,
                tabAID: tabAID,
                tabBID: tabBID,
                sessionAID: sessionAID,
                sessionBID: sessionBID,
                sessionA: sessionA,
                sessionB: sessionB,
                tabATexts: tabATexts,
                tabBTexts: tabBTexts
            )
        } catch {
            window.beginClose()
            await window.tearDown()
            WindowStatesManager.shared.unregisterWindowState(window)
            try? FileManager.default.removeItem(at: rootURL)
            throw error
        }
    }

    private func cleanup(_ fixture: Fixture) async {
        fixture.window.beginClose()
        await fixture.window.tearDown()
        WindowStatesManager.shared.unregisterWindowState(fixture.window)
        try? FileManager.default.removeItem(at: fixture.rootURL)
    }

    private func assertPresentation(
        _ presentation: AgentTranscriptPresentationSnapshot,
        tabID: UUID,
        sessionID: UUID,
        session: AgentModeViewModel.TabSession,
        expectedTexts: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(presentation.tabID, tabID, file: file, line: line)
        XCTAssertTrue(presentation.bindingsHydrated, file: file, line: line)
        XCTAssertEqual(presentation.hydratedPersistentBinding?.tabID, tabID, file: file, line: line)
        XCTAssertEqual(presentation.hydratedPersistentBinding?.sessionID, sessionID, file: file, line: line)
        XCTAssertEqual(
            presentation.hydratedBindingTransitionGeneration,
            session.bindingTransitionGeneration,
            file: file,
            line: line
        )
        XCTAssertEqual(presentation.visibleRows.map(\.text), expectedTexts, file: file, line: line)
        XCTAssertEqual(presentation.workingRows.map(\.text), expectedTexts, file: file, line: line)
    }

    private struct Fixture {
        let window: WindowState
        let rootURL: URL
        let viewModel: AgentModeViewModel
        let tabAID: UUID
        let tabBID: UUID
        let sessionAID: UUID
        let sessionBID: UUID
        let sessionA: AgentModeViewModel.TabSession
        let sessionB: AgentModeViewModel.TabSession
        let tabATexts: [String]
        let tabBTexts: [String]
    }
}

private actor ActivationTokenMetricsModelResolver {
    private let fileID: UUID
    private let rootID = UUID()
    private var starts = 0
    private var completions = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []

    init(fileID: UUID) {
        self.fileID = fileID
    }

    func resolve(_ request: AgentSelectedFilesModelRequest) async -> AgentContextExportModel {
        starts += 1
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
        completions += 1
        let metric = request.entryMetricsSnapshot?.metric(forFileID: fileID)
        let row = AgentContextExportRow(
            id: ResolvedPromptFileEntryID(fileID: fileID, mode: .fullFile, lineRanges: nil),
            kind: .full,
            rootID: rootID,
            relativePath: "Sources/Metrics.swift",
            displayPath: "Sources/Metrics.swift",
            displayName: "Metrics.swift",
            directoryDisplay: "Sources",
            lineRanges: nil,
            metrics: metric.map {
                AgentContextExportRow.Metrics.known(
                    tokenCount: $0.displayTokenCount,
                    tokenPercentage: $0.displayPercentage,
                    lineCount: $0.includedLineCount
                )
            } ?? .unknown,
            canRemove: true
        )
        return AgentContextExportModel(
            source: request.source,
            lookupContext: WorkspaceLookupContext(rootScope: .allLoaded, bindingProjection: nil),
            rows: [row],
            totalSelectedDisplayTokens: request.entryMetricsSnapshot?.totalSelectedDisplayTokens ?? 0,
            missingPaths: [],
            invalidPaths: [],
            codemapPresentation: .empty
        )
    }

    func waitUntilStartCount(_ count: Int) async -> Bool {
        for _ in 0 ..< 500 {
            if starts >= count { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return starts >= count
    }

    func waitUntilCompletionCount(_ count: Int) async -> Bool {
        for _ in 0 ..< 500 {
            if completions >= count { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return completions >= count
    }

    func releaseNext() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }

    func startCount() -> Int {
        starts
    }
}
